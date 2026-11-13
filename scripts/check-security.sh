#!/usr/bin/env bash
# Security-Suite: Secrets-Scan + Filesystem-Vuln-Scan.
# Container-Image-Scan läuft separat in CI gegen das gebaute Image.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
section() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
missing() { printf '\033[1;33m  ? %s nicht installiert — übersprungen.\033[0m\n' "$*"; }

section "gitleaks (Secrets-Scan)"
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-banner --redact --source "$ROOT" 2>&1; then
    ok "Keine Secrets gefunden"
  else
    bad "Mögliche Secrets im Tree (Output oben)"
  fi
else
  missing "gitleaks"
fi

section "zizmor (GitHub-Actions-Audit)"
if command -v zizmor >/dev/null 2>&1; then
  # Online-Audits brauchen GITHUB_TOKEN; lokal laufen wir offline,
  # was schon einen Großteil der Checks abdeckt (template-injection,
  # artipacked, excessive-permissions, …).
  if zizmor "$ROOT/.github/workflows/" 2>&1; then
    ok "Keine Findings"
  else
    bad "Findings (Output oben)"
  fi
else
  missing "zizmor (nix develop)"
fi

section "trivy fs (vuln + misconfig + secret)"
if command -v trivy >/dev/null 2>&1; then
  # Konfig (severity, scanners, skip-dirs, ignore-unfixed) zentral in
  # ./trivy.yaml — gleiche Quelle wie CI.
  if trivy fs \
      --quiet \
      --config "$ROOT/trivy.yaml" \
      --exit-code 1 \
      "$ROOT"; then
    ok "Keine HIGH/CRITICAL Findings"
  else
    bad "Findings gefunden (Output oben)"
  fi
else
  missing "trivy"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m✔ Security-QA OK\033[0m\n'
  exit 0
else
  printf '\033[1;31m✘ Security-QA: %d Findings\033[0m\n' "$FAIL"
  exit 1
fi
