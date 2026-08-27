#!/usr/bin/env bash
# Volle QA-Suite für das Backend (Go/PocketBase).
# Erwartet, dass golangci-lint, govulncheck, gofumpt und go im PATH sind
# (entweder via `nix develop` oder lokaler Install — siehe README).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/backend"

# cgo in der Nix-Shell findet libresolv nicht (Stub-SDK ohne System-
# Libraries). Production-Build im Dockerfile setzt ebenfalls
# CGO_ENABLED=0, lokale Tests laufen aber sonst nur mit asdf-Go grün.
# Pure-Go-Mode passt für unsere Test-Suite (modernc.org/sqlite ist
# pure Go, PocketBase tolerantes Linking).
export CGO_ENABLED=0

FAIL=0
section() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
missing() { printf '\033[1;33m  ? %s nicht installiert — übersprungen.\033[0m\n' "$*"; }

section "gofumpt (Format-Check)"
if command -v gofumpt >/dev/null 2>&1; then
  DIFF=$(gofumpt -l . 2>&1 | grep -v '^migrations/' || true)
  if [ -z "$DIFF" ]; then ok "Format sauber"; else echo "$DIFF"; bad "Format-Diff vorhanden — 'gofumpt -w .' fixt automatisch"; fi
else
  missing "gofumpt"
fi

section "go vet"
if go vet ./...; then ok "go vet sauber"; else bad "go vet meldet Issues"; fi

section "golangci-lint"
if command -v golangci-lint >/dev/null 2>&1; then
  if golangci-lint run ./...; then ok "golangci-lint sauber"; else bad "golangci-lint meldet Issues"; fi
else
  missing "golangci-lint"
fi

section "govulncheck (CVE-Scan, gegen backend/govulncheck-allowlist.txt)"
if command -v govulncheck >/dev/null 2>&1; then
  if "$ROOT/scripts/govulncheck-gate.sh"; then ok "Keine neuen Vulns"; else bad "Neue Vulnerabilities gefunden"; fi
else
  missing "govulncheck"
fi

section "go test (mit Coverage; -race nur in CI mit CGO)"
# -race verlangt CGO_ENABLED=1; in der Nix-Shell läuft Linker mit
# libresolv-Problem. CI (Linux, ohne Nix) setzt -race explizit im
# backend.yml-Workflow.
if go test -cover ./...; then ok "Tests grün"; else bad "Tests fehlgeschlagen"; fi

section "Coverage Kern-Packages (>80 % Vorgabe aus CLAUDE.md)"
for pkg in ./internal/codes ./internal/grouping; do
  COV=$(go test -cover "$pkg" 2>/dev/null | grep -oE 'coverage: [0-9.]+%' | grep -oE '[0-9.]+' || echo "0")
  AWK_RESULT=$(awk -v c="$COV" 'BEGIN { print (c >= 80) ? "ok" : "low" }')
  if [ "$AWK_RESULT" = "ok" ]; then
    ok "$pkg: ${COV}%"
  else
    bad "$pkg: ${COV}% (unter 80 %)"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m✔ Backend-QA OK\033[0m\n'
  exit 0
else
  printf '\033[1;31m✘ Backend-QA: %d Findings\033[0m\n' "$FAIL"
  exit 1
fi
