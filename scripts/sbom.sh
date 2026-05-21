#!/usr/bin/env bash
# Erzeugt eine CycloneDX-SBOM für das Backend-Modul und einen
# License-Report. Beide Artefakte werden in `dist/` abgelegt — der
# Ordner ist gitignored.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"
mkdir -p "$OUT"

section() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; FAIL=1; }
missing() { printf '\033[1;33m  ? %s nicht installiert — übersprungen.\033[0m\n' "$*"; }

FAIL=0

section "CycloneDX-SBOM (Backend)"
if command -v cyclonedx-gomod >/dev/null 2>&1; then
  if (cd "$ROOT/backend" && cyclonedx-gomod mod -json -licenses -output "$OUT/sbom-backend.cdx.json"); then
    ok "$OUT/sbom-backend.cdx.json"
  else
    bad "SBOM-Generierung fehlgeschlagen"
  fi
else
  missing "cyclonedx-gomod"
fi

section "License-Report (go-licenses)"
if command -v go-licenses >/dev/null 2>&1; then
  # CSV: module,license-url,license-name. ALLE Module — Compliance-
  # Entscheidung trifft `check` weiter unten.
  if (cd "$ROOT/backend" && go-licenses report ./... > "$OUT/licenses-backend.csv" 2> "$OUT/licenses-backend.warn"); then
    ok "$OUT/licenses-backend.csv ($(wc -l < "$OUT/licenses-backend.csv") Zeilen)"
  else
    bad "go-licenses report fehlgeschlagen — siehe $OUT/licenses-backend.warn"
  fi

  # Hard-Gate: keine bekannten Forbidden- oder Unknown-Lizenzen.
  # Defaults von go-licenses sind streng (GPL/AGPL/etc. = forbidden).
  # --ignore-Liste:
  #   * eigenes Modul       — privat, kein LICENSE-File nötig
  #   * jmespath/go-jmespath — Apache-2.0 (manuell verifiziert),
  #     go-licenses kann die LICENSE-Datei wegen Modul-Struktur nicht
  #     auflösen.
  if (cd "$ROOT/backend" && go-licenses check ./... \
        --ignore go.mett.io/fwd-backend \
        --ignore github.com/jmespath/go-jmespath \
        2>"$OUT/licenses-check.err"); then
    ok "Keine verbotenen/unbekannten Lizenzen"
  else
    bad "go-licenses check fand Issues:"
    cat "$OUT/licenses-check.err" | sed 's/^/    /'
  fi
else
  missing "go-licenses"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m✔ SBOM + Lizenzen OK\033[0m\n'
  exit 0
else
  printf '\033[1;31m✘ SBOM + Lizenzen: Findings\033[0m\n'
  exit 1
fi
