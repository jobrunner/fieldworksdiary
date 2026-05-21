#!/usr/bin/env bash
# Volle QA-Suite für die iOS-App (SwiftUI).
# Erwartet swiftlint + swiftformat im PATH und ein installiertes Xcode
# unter /Applications/Xcode.app (für xcodebuild build/test).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
section() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
missing() { printf '\033[1;33m  ? %s nicht installiert — übersprungen.\033[0m\n' "$*"; }

# xcodebuild verträgt die Nix-Shell-Env nicht (NIX_LDFLAGS / NIX_CFLAGS /
# SDKROOT / MACOSX_DEPLOYMENT_TARGET / LD/CC etc. werden vom Apple-Linker
# als ungültige Flags interpretiert). Wir invoken xcodebuild deshalb in
# einer minimalen, sauberen Umgebung.
xcb() {
  env -i \
    HOME="$HOME" \
    USER="$USER" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
    /usr/bin/xcodebuild "$@"
}

section "SwiftFormat (Lint-Modus)"
if command -v swiftformat >/dev/null 2>&1; then
  if swiftformat --lint --quiet --config .swiftformat ios; then
    ok "Format sauber"
  else
    bad "SwiftFormat-Diff vorhanden — 'swiftformat ios' fixt automatisch"
  fi
else
  missing "swiftformat"
fi

section "Periphery (Dead-Code-Detection, warn-only)"
if command -v periphery >/dev/null 2>&1; then
  if [ ! -d ios/Fieldworksdiary.xcodeproj ]; then
    missing "Xcode-Projekt fehlt — 'xcodegen generate' im ios/-Dir"
  else
    P_OUT=$(periphery scan --config .periphery.yml --quiet 2>&1 || true)
    P_COUNT=$(printf '%s\n' "$P_OUT" | grep -c "warning:" || true)
    if [ "$P_COUNT" -gt 0 ]; then
      printf '%s\n' "$P_OUT" | grep "warning:" | head -20
      printf '\033[1;33m  ! Periphery: %d Findings (nicht blockierend)\033[0m\n' "$P_COUNT"
    else
      ok "Periphery sauber"
    fi
  fi
else
  missing "periphery (Cask: brew install peripheryapp/periphery/periphery)"
fi

section "SwiftLint"
if command -v swiftlint >/dev/null 2>&1; then
  SL_OUT=$(swiftlint lint --config .swiftlint.yml --quiet 2>/dev/null)
  WARNS=$(printf '%s\n' "$SL_OUT" | grep -c ": warning:" || true)
  ERRS=$(printf '%s\n' "$SL_OUT"  | grep -c ": error:"   || true)
  printf '%s\n' "$SL_OUT" | head -50
  if [ "$ERRS" -gt 0 ]; then
    bad "SwiftLint: $ERRS Errors, $WARNS Warnings"
  elif [ "$WARNS" -gt 0 ]; then
    printf '\033[1;33m  ! SwiftLint: %d Warnings (nicht blockierend)\033[0m\n' "$WARNS"
  else
    ok "SwiftLint sauber"
  fi
else
  missing "swiftlint"
fi

section "Xcode-Build"
if [ ! -d /Applications/Xcode.app ]; then
  missing "Xcode (App-Bundle fehlt — 'xcodes install <version>' oder App Store)"
elif [ ! -d ios/Fieldworksdiary.xcodeproj ]; then
  bad "ios/Fieldworksdiary.xcodeproj fehlt — 'xcodegen generate' im ios/-Dir ausführen"
else
  BUILD_LOG=$(mktemp)
  if xcb \
      -project ios/Fieldworksdiary.xcodeproj \
      -scheme Fieldworksdiary \
      -sdk iphonesimulator \
      -destination 'generic/platform=iOS Simulator' \
      build \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO >"$BUILD_LOG" 2>&1; then
    ok "xcodebuild build SUCCEEDED"
  else
    bad "xcodebuild build FAILED"
    echo "    log: $BUILD_LOG (letzte 20 Zeilen unten)"
    tail -20 "$BUILD_LOG" | sed 's/^/      /'
  fi
fi

section "xcodebuild test (Unit-Tests)"
if [ ! -d /Applications/Xcode.app ] || [ ! -d ios/Fieldworksdiary.xcodeproj ]; then
  missing "Xcode oder Projektdatei fehlt"
else
  SIM_DEST=$(env -i PATH="/usr/bin:/bin" /usr/bin/xcrun simctl list devices available -j 2>/dev/null \
    | jq -r '.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.isAvailable==true) | .udid' 2>/dev/null \
    | head -1)
  if [ -z "$SIM_DEST" ]; then
    missing "Kein iOS-Simulator verfügbar — Test übersprungen"
  else
    TEST_LOG=$(mktemp)
    if xcb \
        -project ios/Fieldworksdiary.xcodeproj \
        -scheme Fieldworksdiary \
        -destination "id=$SIM_DEST" \
        test \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO >"$TEST_LOG" 2>&1; then
      ok "Unit-Tests grün"
    else
      bad "Unit-Tests fehlgeschlagen"
      echo "    log: $TEST_LOG (letzte 20 Zeilen unten)"
      tail -20 "$TEST_LOG" | sed 's/^/      /'
    fi
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m✔ iOS-QA OK\033[0m\n'
  exit 0
else
  printf '\033[1;31m✘ iOS-QA: %d Findings\033[0m\n' "$FAIL"
  exit 1
fi
