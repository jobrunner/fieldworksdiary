#!/usr/bin/env bash
# Tests-only-Runner für iOS, ohne Re-Build.
#
# Hintergrund: Auf macOS 26 ("Tahoe") triggert `xcodebuild build` für
# SwiftPM-Targets (z.B. GRDB) einen Apple-ld-Bug:
#
#     ld: -objc_abi_version '-Xlinker' not supported (expected 2)
#
# Der Fehler entsteht im relocatable Single-Object-Link-Step und tritt
# in jeder Xcode-Version (16.x bis 26.x) auf, wenn sie auf Tahoe läuft.
# CI auf macos-15 ist nicht betroffen.
#
# Workaround-Workflow:
#   1) Im Xcode-26-IDE einmal "Product > Build for Testing" (Cmd+Shift+U).
#      Die IDE umgeht den Bug durch eine andere Driver-Pipeline und
#      legt das fertige Bundle plus eine `.xctestrun`-Datei in
#      DerivedData ab.
#   2) Danach diesen Script aufrufen — er liest die jüngste .xctestrun
#      und führt nur die Tests aus, ohne den problematischen Link-Step
#      erneut zu fahren.
#
# Nach Code-Änderungen → wieder Schritt 1, dann Schritt 2.
# Aufruf:
#   bash scripts/test-ios-no-build.sh [SIM_NAME]
# Default-Simulator: iPhone 17.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIM_NAME="${1:-iPhone 17}"

section() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; }
hint()    { printf '\033[1;33m  ℹ %s\033[0m\n' "$*"; }

# xcodebuild verträgt die Nix-Shell-Env nicht (NIX_LDFLAGS / NIX_CFLAGS
# u.a.); deshalb minimale, kuratierte Umgebung.
xcb() {
  env -i \
    HOME="$HOME" \
    USER="$USER" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
    /usr/bin/xcodebuild "$@"
}

section "Finde jüngste .xctestrun in DerivedData"
XCTESTRUN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*Fieldworksdiary-*/Build/Products/*.xctestrun' \
  -print 2>/dev/null \
  | xargs -I{} stat -f '%m {}' 2>/dev/null \
  | sort -rn \
  | head -1 \
  | cut -d' ' -f2-)"

if [ -z "$XCTESTRUN" ] || [ ! -f "$XCTESTRUN" ]; then
  bad ".xctestrun nicht gefunden."
  hint "Erst in Xcode 26 IDE 'Product > Build for Testing' (Cmd+Shift+U)"
  hint "ausführen, dann diesen Script nochmal aufrufen."
  exit 2
fi
ok "$XCTESTRUN"

section "Wähle Simulator: $SIM_NAME"
SIM_UDID="$(env -i PATH="/usr/bin:/bin" /usr/bin/xcrun simctl list devices available -j 2>/dev/null \
  | jq -r --arg name "$SIM_NAME" \
      '[.devices | to_entries[] | select(.key|contains("iOS"))
        | .value[] | select(.isAvailable==true) | select(.name==$name)] | .[0].udid // empty' \
       2>/dev/null)"

if [ -z "$SIM_UDID" ]; then
  bad "Simulator \"$SIM_NAME\" nicht verfügbar."
  hint "Verfügbar (Auswahl):"
  env -i PATH="/usr/bin:/bin" /usr/bin/xcrun simctl list devices available 2>/dev/null \
    | grep -E '^\s+iPhone ' | head -5
  hint "Aufruf mit anderem Simulator: bash scripts/test-ios-no-build.sh \"iPhone 17 Pro\""
  exit 3
fi
ok "$SIM_UDID"

section "xcodebuild test-without-building"
TEST_LOG=$(mktemp)
if xcb \
    test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "id=$SIM_UDID" >"$TEST_LOG" 2>&1; then
  ok "Tests grün"
  exit 0
else
  bad "Tests fehlgeschlagen"
  hint "Log: $TEST_LOG (letzte 30 Zeilen unten)"
  tail -30 "$TEST_LOG" | sed 's/^/      /'
  exit 1
fi
