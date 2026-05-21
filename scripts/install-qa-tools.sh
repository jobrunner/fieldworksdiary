#!/usr/bin/env bash
# Fallback-Installer für Devs ohne Nix. Empfohlener Weg bleibt:
#   nix develop          (oder direnv mit `use flake`)
#
# Dieser Script installiert die QA-Tools über Homebrew/`go install` —
# idempotent (skipped, was schon da ist).

set -uo pipefail

need_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew nicht installiert. Siehe https://brew.sh/" >&2
    exit 1
  fi
}

install_brew() {
  local pkg="$1"
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    echo "  ✓ $pkg bereits installiert"
  else
    echo "  → brew install $pkg"
    brew install "$pkg"
  fi
}

echo "▸ QA-Tools (Homebrew)"
need_brew
install_brew golangci-lint
install_brew swiftlint
install_brew swiftformat
install_brew gofumpt
install_brew jq
install_brew zizmor   # GitHub-Actions-Audit

# Periphery — Swift-Dead-Code-Detection. Liegt als Cask, nicht als Formula.
if brew list --cask periphery >/dev/null 2>&1; then
  echo "  ✓ periphery (Cask) bereits installiert"
else
  echo "  → brew install peripheryapp/periphery/periphery"
  brew install peripheryapp/periphery/periphery
fi

echo
echo "▸ govulncheck (go install)"
if ! command -v go >/dev/null 2>&1; then
  echo "  ! 'go' nicht im PATH — bitte erst Go installieren (z. B. via asdf, Homebrew oder Nix)." >&2
else
  if command -v govulncheck >/dev/null 2>&1; then
    echo "  ✓ govulncheck bereits installiert"
  else
    echo "  → go install golang.org/x/vuln/cmd/govulncheck@latest"
    go install golang.org/x/vuln/cmd/govulncheck@latest
    echo "    (stelle sicher, dass \$GOPATH/bin im PATH ist)"
  fi
fi

echo
echo "✔ Fertig. Volle Suite ausführen: bash scripts/check.sh"
