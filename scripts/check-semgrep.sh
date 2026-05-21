#!/usr/bin/env bash
# Semgrep — Multi-Sprach-SAST mit curated Rule-Packs.
# Wir laufen die Rulesets, die zu unserer Code-Basis passen:
#   - p/golang        : Go-spezifische Security & Best-Practice
#   - p/swift         : Swift-spezifische Findings
#   - p/security-audit: cross-language Security-Patterns (eval, hardcoded
#                       secrets, weak crypto, …)
#   - p/secrets       : Token/Key-Pattern (zusätzlich zu gitleaks)
#
# Semgrep ist als zusätzliche Schicht über golangci-lint+gosec gedacht —
# manche Patterns (z. B. SSRF, Path-Traversal in Go-HTTP-Handlern)
# liefert semgrep zuverlässiger.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
section() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
missing() { printf '\033[1;33m  ? %s nicht installiert — übersprungen.\033[0m\n' "$*"; }

section "Semgrep (Go + Swift + Security-Audit + Secrets)"
if command -v semgrep >/dev/null 2>&1; then
  if semgrep scan \
      --config p/golang \
      --config p/swift \
      --config p/security-audit \
      --config p/secrets \
      --exclude 'backend/pb_data' \
      --exclude 'pb_data_staging' \
      --exclude 'pb_data_prod' \
      --exclude 'dist' \
      --exclude 'ios/Fieldworksdiary.xcodeproj' \
      --exclude 'ios/build' \
      --exclude 'ios/FieldworksdiaryTests/__Snapshots__' \
      --severity ERROR \
      --error \
      --quiet 2>&1; then
    ok "Keine ERROR-Severity-Findings"
  else
    bad "Semgrep-Findings (siehe Output oben)"
  fi
else
  missing "semgrep"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m✔ Semgrep-Scan OK\033[0m\n'
  exit 0
else
  printf '\033[1;31m✘ Semgrep-Scan: %d Findings\033[0m\n' "$FAIL"
  exit 1
fi
