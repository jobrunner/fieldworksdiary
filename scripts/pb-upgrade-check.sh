#!/usr/bin/env bash
# PocketBase-Upgrade-Check: alte pb_data (PocketBase 0.22) -> neues Binary.
#
# Baut das alte Backend (Git-Ref, Default 6959bd6 = letzter 0.22-Stand)
# und das neue aus dem aktuellen Arbeitsbaum, startet beide auf Kopien
# derselben pb_data und vergleicht, was die iOS-App über die REST-API
# sieht (scripts/pb_upgrade_check.py). Die Quelle wird nie verändert:
# beide Binaries laufen ausschließlich auf Kopien im Arbeitsverzeichnis.
#
# Zwei Modi:
#
#   1. Ohne --pb-data (Default): frische 0.22-DB, Superuser + zwei User,
#      realistische Testdaten über die API (seed), dann Upgrade.
#        scripts/pb-upgrade-check.sh
#
#   2. Mit --pb-data: Kopie einer echten pb_data (z.B. Prod-Backup).
#      Superuser-Zugang des alten Admins nötig; optional ein oder zwei
#      User-Logins für die User-Sicht (Owner-Isolation).
#        SU_EMAIL=... SU_PASSWORD=... \
#        [USER_A=... USER_B=... USER_PASSWORD=...] \
#        scripts/pb-upgrade-check.sh --pb-data /pfad/zur/kopie/pb_data_prod
#      Ablauf: Kopie 1 -> altes Binary (wendet ggf. ausstehende Migrationen
#      mit 0.22-Code an) -> Dump "before". Kopie 2 (unberührt) -> neues
#      Binary direkt (genau der Prod-Pfad) -> Dump "after". Vergleich.
#
# Optionen: --old-ref <git-ref>  --work <dir>  --keep (Server nicht stoppen)
# Ports: PORT_OLD (18090), PORT_NEW (18091), PORT_FRESH (18092).
# Ortus ist abgeschaltet (ORTUS_BASE_URL leer), damit keine asynchrone
# Anreicherung die Daten zwischen den Dumps verändert.
#
# Exit-Code 0 = keine Abweichung außer den bekannten Fehler-JSON-Formaten
# (`code` -> `status`, Meldungstexte; siehe ADR 0008).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/pb_upgrade_check.py"
OLD_REF="6959bd6"
PB_DATA=""
WORK=""
KEEP=0
PORT_OLD="${PORT_OLD:-18090}"
PORT_NEW="${PORT_NEW:-18091}"
PORT_FRESH="${PORT_FRESH:-18092}"

while [ $# -gt 0 ]; do
  case "$1" in
    --pb-data) PB_DATA="$2"; shift 2 ;;
    --old-ref) OLD_REF="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/pb-upgrade-check.XXXXXX")}"
mkdir -p "$WORK"
echo "Arbeitsverzeichnis: $WORK"

for p in "$PORT_OLD" "$PORT_NEW" "$PORT_FRESH"; do
  if lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $p ist belegt (PORT_OLD/PORT_NEW/PORT_FRESH setzen)." >&2
    exit 1
  fi
done

PIDS=()
cleanup() {
  if [ "$KEEP" = 0 ]; then
    for pid in "${PIDS[@]:-}"; do
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT

# --- Binaries ---------------------------------------------------------------
echo "==> baue altes Backend ($OLD_REF)"
rm -rf "$WORK/old-src" && mkdir -p "$WORK/old-src" "$WORK/bin"
git -C "$ROOT" archive "$OLD_REF" backend | tar -x -C "$WORK/old-src"
(cd "$WORK/old-src/backend" && CGO_ENABLED=0 go build -o "$WORK/bin/fwd-old" .)
echo "==> baue neues Backend (Arbeitsbaum)"
(cd "$ROOT/backend" && CGO_ENABLED=0 go build -o "$WORK/bin/fwd-new" .)

start() { # bin dir port log
  ORTUS_BASE_URL= "$1" --dir "$2" serve --http="127.0.0.1:$3" >"$4" 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:$3/api/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "Server auf Port $3 startet nicht, Log: $4" >&2
  tail -50 "$4" >&2
  exit 1
}
stop_last() {
  local pid="${PIDS[${#PIDS[@]}-1]}"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# --- Ausgangsdaten ----------------------------------------------------------
if [ -z "$PB_DATA" ]; then
  SU_EMAIL="admin@example.org"
  SU_PASSWORD="AdminPass-12345"
  USER_A="usera@example.org"
  USER_B="userb@example.org"
  USER_PASSWORD="UserPass-12345"
  echo "==> frische 0.22-DB mit Testdaten"
  rm -rf "$WORK/source"
  ORTUS_BASE_URL= "$WORK/bin/fwd-old" --dir "$WORK/source" migrate up >"$WORK/old-migrate.log" 2>&1
  "$WORK/bin/fwd-old" --dir "$WORK/source" admin create "$SU_EMAIL" "$SU_PASSWORD" >>"$WORK/old-migrate.log" 2>&1
  start "$WORK/bin/fwd-old" "$WORK/source" "$PORT_OLD" "$WORK/old-seed.log"
  python3 -I "$CHECK" seed --base "http://127.0.0.1:$PORT_OLD" \
    --user-a "$USER_A" --user-b "$USER_B" --password "$USER_PASSWORD" >"$WORK/seed.json"
  stop_last
  PB_DATA="$WORK/source"
else
  : "${SU_EMAIL:?SU_EMAIL (alter Admin) setzen}"
  : "${SU_PASSWORD:?SU_PASSWORD setzen}"
  USER_A="${USER_A:-}"
  USER_B="${USER_B:-}"
  USER_PASSWORD="${USER_PASSWORD:-}"
fi
[ -f "$PB_DATA/data.db" ] || { echo "$PB_DATA/data.db fehlt" >&2; exit 1; }

rm -rf "$WORK/before-data" "$WORK/after-data"
cp -a "$PB_DATA" "$WORK/before-data"
cp -a "$PB_DATA" "$WORK/after-data"

USER_ARGS=()
[ -n "$USER_A" ] && USER_ARGS+=(--user-a "$USER_A")
[ -n "$USER_B" ] && USER_ARGS+=(--user-b "$USER_B")
USER_ARGS+=(--password "$USER_PASSWORD")

echo "==> Dump mit altem Binary"
start "$WORK/bin/fwd-old" "$WORK/before-data" "$PORT_OLD" "$WORK/old-serve.log"
python3 -I "$CHECK" dump --base "http://127.0.0.1:$PORT_OLD" "${USER_ARGS[@]}" \
  --su-email "$SU_EMAIL" --su-password "$SU_PASSWORD" \
  --out "$WORK/before.json" --tokens-out "$WORK/tokens-before.json"
stop_last

echo "==> Upgrade: neues Binary auf unberührter Kopie"
start "$WORK/bin/fwd-new" "$WORK/after-data" "$PORT_NEW" "$WORK/new-serve.log"
if grep -Eiq '"level":"(ERROR|FATAL)"|panic' "$WORK/new-serve.log"; then
  echo "Fehler im Start-Log des neuen Binarys:" >&2
  grep -Ei '"level":"(ERROR|FATAL)"|panic' "$WORK/new-serve.log" >&2
fi
python3 -I "$CHECK" dump --base "http://127.0.0.1:$PORT_NEW" "${USER_ARGS[@]}" \
  --su-email "$SU_EMAIL" --su-password "$SU_PASSWORD" \
  --out "$WORK/after.json" --legacy-tokens "$WORK/tokens-before.json"

echo "==> Vergleich vorher/nachher (vollständig: $WORK/diff-full.json)"
python3 -I "$CHECK" compare "$WORK/before.json" "$WORK/after.json" --out "$WORK/diff-full.json" >"$WORK/diff-full.txt" || true
head -1 "$WORK/diff-full.txt"
set +e
python3 -I "$CHECK" compare "$WORK/before.json" "$WORK/after.json" --ignore-error-format --out "$WORK/diff.json"
RC=$?
set -e
python3 -I - "$WORK/after.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for k, u in d.get("users", {}).items():
    lt = u.get("legacy_token")
    if lt:
        print(f"  alter 0.22-Token User {k}: Liste HTTP {lt['list_status']}, auth-refresh HTTP {lt['refresh_status']}")
print("  Superuser-Login (alter Admin):", d.get("superuser", {}).get("login"))
EOF

echo "==> Schema: frische DB (neues Binary) gegen upgegradete DB"
rm -rf "$WORK/fresh-data"
"$WORK/bin/fwd-new" --dir "$WORK/fresh-data" superuser upsert "$SU_EMAIL" "$SU_PASSWORD" >"$WORK/fresh.log" 2>&1
start "$WORK/bin/fwd-new" "$WORK/fresh-data" "$PORT_FRESH" "$WORK/fresh-serve.log"
set +e
python3 -I "$CHECK" schema --base-a "http://127.0.0.1:$PORT_NEW" --base-b "http://127.0.0.1:$PORT_FRESH" \
  --su-email "$SU_EMAIL" --su-password "$SU_PASSWORD" --out "$WORK/schema.json"
set -e

echo
if [ "$RC" = 0 ]; then
  echo "OK: Upgrade ohne API-Abweichung (außer bekanntem Fehler-JSON-Format)."
else
  echo "ABWEICHUNGEN gefunden, siehe $WORK/diff.json" >&2
fi
exit "$RC"
