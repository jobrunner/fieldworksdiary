#!/usr/bin/env bash
# Volle QA-Suite für die iOS-App (SwiftUI).
# Erwartet die Nix-Shell (`nix develop`: swiftlint, swiftformat,
# periphery) und ein installiertes Xcode unter /Applications/Xcode.app
# (für xcodebuild build/test).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
section() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
missing() { printf '\033[1;33m  ? %s nicht installiert — übersprungen (nix develop?).\033[0m\n' "$*"; }

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
  if [ ! -d ios/Legulus.xcodeproj ]; then
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
  missing "periphery"
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
elif [ ! -d ios/Legulus.xcodeproj ]; then
  bad "ios/Legulus.xcodeproj fehlt — 'xcodegen generate' im ios/-Dir ausführen"
else
  BUILD_LOG=$(mktemp)
  # ARCHS=arm64: `generic/platform=iOS Simulator` baut sonst auch x86_64,
  # FliptClients `libfliptengine.a` gibt es aber nur für arm64.
  if xcb \
      -project ios/Legulus.xcodeproj \
      -scheme Legulus \
      -sdk iphonesimulator \
      -destination 'generic/platform=iOS Simulator' \
      build \
      ARCHS=arm64 \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO >"$BUILD_LOG" 2>&1; then
    ok "xcodebuild build SUCCEEDED"
  else
    bad "xcodebuild build FAILED"
    echo "    log: $BUILD_LOG (letzte 20 Zeilen unten)"
    tail -20 "$BUILD_LOG" | sed 's/^/      /'
  fi
fi

section "xcodebuild test (Unit- + UI-Tests, iOS-Matrix)"
# Getestet wird auf zwei Simulatoren: einem iPhone der ältesten und einem
# der neuesten installierten iOS-Runtime (z. B. 18.6 und 26.5). So fallen
# Unterschiede zwischen altem und neuem System-Rendering auf, bevor ein
# Tester sie findet. Override: IOS_TEST_SIM_IDS="<udid> <udid>".
if [ ! -d /Applications/Xcode.app ] || [ ! -d ios/Legulus.xcodeproj ]; then
  missing "Xcode oder Projektdatei fehlt"
else
  if [ -n "${IOS_TEST_SIM_IDS:-}" ]; then
    SIM_IDS="$IOS_TEST_SIM_IDS"
  else
    # Pro iOS-Runtime das erste verfügbare iPhone, sortiert nach
    # Runtime-Version; davon das erste und das letzte.
    SIM_LIST=$(env -i PATH="/usr/bin:/bin" /usr/bin/xcrun simctl list devices available -j 2>/dev/null \
      | jq -r '.devices | to_entries[]
          | select(.key | test("SimRuntime\\.iOS-"))
          | (.key | capture("iOS-(?<maj>[0-9]+)-(?<min>[0-9]+)")) as $v
          | [($v.maj | tonumber), ($v.min | tonumber),
             ([.value[] | select(.isAvailable == true and (.name | startswith("iPhone")))][0].udid // empty)]
          | select(.[2] != null) | @tsv' 2>/dev/null \
      | sort -n -k1,1 -k2,2)
    SIM_IDS=$(printf '%s\n' "$SIM_LIST" | sed -n '1p;$p' | cut -f3 | awk '!seen[$0]++' | tr '\n' ' ')
  fi
  if [ -z "${SIM_IDS// /}" ]; then
    missing "Kein iOS-Simulator verfügbar — Test übersprungen"
  else
    # Die Tests laufen im Scheme `Legulus-Test` gegen die
    # Test-Instanz (localhost:8092). Dessen Pre-Action setzt sie vor
    # jedem Lauf neu auf, meldet einen Fehler aber nicht - deshalb hier
    # einmal sichtbar, und nur wenn auch wirklich getestet wird.
    if bash scripts/reset-test-tabularius.sh; then
      ok "Test-Instanz antwortet auf localhost:8092, Test-Nutzer angelegt"
    else
      bad "Test-Instanz nicht bereit"
    fi
    for SIM_DEST in $SIM_IDS; do
      SIM_NAME=$(env -i PATH="/usr/bin:/bin" /usr/bin/xcrun simctl list devices -j 2>/dev/null \
        | jq -r --arg id "$SIM_DEST" '.devices | to_entries[] | .key as $rt | .value[]
            | select(.udid == $id) | "\(.name) (\($rt | sub(".*SimRuntime\\.iOS-"; "iOS ") | gsub("-"; ".")))"')
      TEST_LOG=$(mktemp)
      if xcb \
          -project ios/Legulus.xcodeproj \
          -scheme Legulus-Test \
          -destination "id=$SIM_DEST" \
          test \
          CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO >"$TEST_LOG" 2>&1; then
        ok "Tests grün auf $SIM_NAME"
      else
        bad "Tests fehlgeschlagen auf $SIM_NAME"
        echo "    log: $TEST_LOG (Fehler unten)"
        grep -E "error:|failed|Failing tests" "$TEST_LOG" | sort -u | head -20 | sed 's/^/      /'
      fi
    done
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
