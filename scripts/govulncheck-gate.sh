#!/usr/bin/env bash
# Läuft govulncheck gegen backend/, lässt aber nur tatsächlich neue
# Findings failen — bekannte, bewusst akzeptierte Vulns stehen mit
# Begründung in backend/govulncheck-allowlist.txt (siehe dort).
#
# Genutzt von .github/workflows/backend.yml, .github/workflows/security.yml
# und scripts/check-backend.sh — eine Quelle für die Allow-Logik statt
# drei Kopien.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$ROOT/backend/govulncheck-allowlist.txt"

cd "$ROOT/backend"

if ! command -v govulncheck >/dev/null 2>&1; then
  echo "govulncheck nicht im PATH — 'go install golang.org/x/vuln/cmd/govulncheck@latest'" >&2
  exit 1
fi

OUTPUT="$(govulncheck ./... 2>&1)"
RC=$?
echo "$OUTPUT"

# govulncheck: 0 = sauber, 3 = Findings (die prüft die Allowlist unten),
# alles andere = Scan gescheitert (z.B. govulncheck mit zu altem Go
# gebaut). Das darf nicht als "keine Findings" durchgehen.
if [ "$RC" -ne 0 ] && [ "$RC" -ne 3 ]; then
  echo
  echo "::error::govulncheck ist gescheitert (Exit $RC), Ergebnis unbrauchbar."
  exit 1
fi

FOUND_IDS="$(echo "$OUTPUT" | grep -oE '^Vulnerability #[0-9]+: GO-[0-9]+-[0-9]+' | grep -oE 'GO-[0-9]+-[0-9]+' | sort -u)"
ALLOWED_IDS="$(grep -vE '^\s*#|^\s*$' "$ALLOWLIST" | sort -u)"

NEW_IDS="$(comm -23 <(echo "$FOUND_IDS") <(echo "$ALLOWED_IDS") | grep -v '^$' || true)"
STALE_IDS="$(comm -13 <(echo "$FOUND_IDS") <(echo "$ALLOWED_IDS") | grep -v '^$' || true)"

if [ -n "$STALE_IDS" ]; then
  echo
  echo "::warning::govulncheck-allowlist.txt hat Einträge, die nicht mehr gefunden wurden (aufräumen): $STALE_IDS"
fi

if [ -n "$NEW_IDS" ]; then
  echo
  echo "::error::Neue, nicht akzeptierte govulncheck-Findings: $NEW_IDS"
  echo "Entweder fixen (Dependency-Bump) oder — mit Begründung — in $ALLOWLIST aufnehmen."
  exit 1
fi

echo
echo "✓ govulncheck: keine neuen Findings (Allowlist: ${ALLOWED_IDS:-keine})"
