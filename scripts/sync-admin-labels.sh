#!/usr/bin/env bash
# Copies the canonical admin label table to all consumers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/shared/admin-labels/admin_labels.json"
TARGETS=(
  "$ROOT/backend/internal/adminlabels/admin_labels.json"
  "$ROOT/ios/Packages/FieldworksGeo/Sources/FieldworksGeo/Resources/admin_labels.json"
)
for t in "${TARGETS[@]}"; do
  mkdir -p "$(dirname "$t")"
  cp "$SRC" "$t"
  echo "synced -> ${t#$ROOT/}"
done
