#!/usr/bin/env bash
# Claude PostToolUse-Hook: Lint die GERADE geänderte Datei.
#
# Ruft schnelle Format- und Lint-Checks auf .go / .swift-Dateien auf und
# gibt Findings via stdout (Claude-Transcript) aus. Exit-Code ist IMMER 0
# — die User-Entscheidung war "nur warnen, nie blockieren".
#
# Input: PostToolUse-JSON via stdin (Felder: tool_name, tool_input.file_path).

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${TMPDIR:-/tmp}/claude-fwd-hook"
mkdir -p "$STATE_DIR"

# --- jq finden (Nix-Shell hat es; sonst Brew/system) ---
if ! command -v jq >/dev/null 2>&1; then
  # Hook fällt ohne jq aus; einmalig warnen, dann ruhe geben.
  WARN_FILE="$STATE_DIR/no-jq.warn"
  if [ ! -f "$WARN_FILE" ]; then
    echo "claude-post-edit: jq nicht gefunden — Hook übersprungen. (Empfohlen: 'nix develop')" >&2
    touch "$WARN_FILE"
  fi
  exit 0
fi

# --- File-Path extrahieren (Edit/Write haben file_path; MultiEdit auch) ---
JSON="$(cat)"
FILE=$(printf '%s' "$JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  exit 0
fi

# Nur Projekt-Dateien lintet uns — externe Pfade ignorieren.
case "$FILE" in
  "$ROOT"/*) ;;
  *) exit 0 ;;
esac

warn_missing() {
  local tool="$1"
  local wf="$STATE_DIR/missing-$tool.warn"
  if [ ! -f "$wf" ]; then
    echo "claude-post-edit: '$tool' nicht im PATH — überspringe. ('nix develop' liefert es.)" >&2
    touch "$wf"
  fi
}

lint_go() {
  local f="$1"
  local rel="${f#"$ROOT"/}"
  local out

  if command -v gofumpt >/dev/null 2>&1; then
    out=$(gofumpt -d "$f" 2>&1)
    if [ -n "$out" ]; then
      printf '\n--- gofumpt: %s ---\n%s\n' "$rel" "$out"
    fi
  else
    warn_missing gofumpt
  fi

  if command -v golangci-lint >/dev/null 2>&1; then
    # Einzeldatei-Lint braucht den Package-Kontext. Wir laufen vom
    # Backend-Modul-Root und filtern danach auf die geänderte Datei.
    out=$( (cd "$ROOT/backend" && golangci-lint run --path-mode=abs --timeout=120s "$f" 2>&1) )
    # Nur ausgeben, wenn echte Findings drin sind (keine reine Info/Cache-Meldung).
    if printf '%s' "$out" | grep -qE '^[^:]+:[0-9]+:[0-9]+:'; then
      printf '\n--- golangci-lint: %s ---\n%s\n' "$rel" "$out"
    fi
  else
    warn_missing golangci-lint
  fi
}

lint_swift() {
  local f="$1"
  local rel="${f#"$ROOT"/}"
  local out

  if command -v swiftformat >/dev/null 2>&1; then
    out=$(swiftformat --lint --quiet --config "$ROOT/.swiftformat" "$f" 2>&1)
    if [ -n "$out" ]; then
      printf '\n--- swiftformat: %s ---\n%s\n' "$rel" "$out"
    fi
  else
    warn_missing swiftformat
  fi

  if command -v swiftlint >/dev/null 2>&1; then
    out=$(swiftlint lint --config "$ROOT/.swiftlint.yml" --quiet "$f" 2>/dev/null)
    if [ -n "$out" ]; then
      printf '\n--- swiftlint: %s ---\n%s\n' "$rel" "$out"
    fi
  else
    warn_missing swiftlint
  fi
}

case "$FILE" in
  *.go)     lint_go    "$FILE" ;;
  *.swift)  lint_swift "$FILE" ;;
  *) ;;   # andere Dateien still überspringen
esac

# Egal was passiert: nicht blockieren.
exit 0
