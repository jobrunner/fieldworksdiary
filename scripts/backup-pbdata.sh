#!/usr/bin/env bash
# Online-Backup von `backend/pb_data/` — funktioniert auch, wenn das
# Backend gerade läuft (sqlite3 `.backup` ist transaktional sicher mit
# WAL). Erzeugt einen einzelnen `.tar.gz` mit:
#   - data.db  (online-konsistente Kopie via sqlite3 .backup)
#   - logs.db  (dito)
#   - storage/ (rsync-Schnappschuss; PB schreibt selten dort, kleine
#                Race-Window-Lücke ist akzeptabel)
#
# Default-Ziel: `$HOME/Backups/fieldworksdiary/YYYY-MM-DDTHH-MM-SSZ.tar.gz`
# Überschreibbar mit Argument 1 (Verzeichnis).
#
# Retention: behält die letzten N Backups (Default 30). N via ENV
# `KEEP_LAST=N`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/backend/pb_data"
DEST_DIR="${1:-$HOME/Backups/fieldworksdiary}"
KEEP_LAST="${KEEP_LAST:-30}"

if [ ! -d "$SRC" ]; then
  echo "Source $SRC nicht gefunden — Backend nie gestartet?" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 nicht im PATH (nix develop nutzen)." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
STAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1) Online-Backup der SQLite-DBs (write-safe).
for db in data.db logs.db; do
  if [ -f "$SRC/$db" ]; then
    sqlite3 "$SRC/$db" ".backup '$TMP/$db'"
  fi
done

# 2) storage/ einfach kopieren (idempotent; tar packt es danach).
if [ -d "$SRC/storage" ]; then
  cp -R "$SRC/storage" "$TMP/storage"
fi

# 3) Tar+gzip mit Stamp-Name.
OUT="$DEST_DIR/pbdata-$STAMP.tar.gz"
tar -czf "$OUT" -C "$TMP" .

SIZE=$(du -h "$OUT" | awk '{print $1}')
echo "✓ Backup: $OUT ($SIZE)"

# 4) Retention: ältere als Position $KEEP_LAST löschen.
mapfile -t OLD < <(ls -1t "$DEST_DIR"/pbdata-*.tar.gz 2>/dev/null | tail -n +$((KEEP_LAST + 1)))
for f in "${OLD[@]:-}"; do
  [ -n "$f" ] || continue
  rm -f -- "$f"
  echo "  ↳ retention: gelöscht $(basename "$f")"
done
