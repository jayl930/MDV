#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
include_preview=0

if [[ "${1:-}" == "--include-preview" ]]; then
  include_preview=1
fi

bash "$repo_root/Tests/run-editor-projection-regression.sh"
bash "$repo_root/Tests/run-table-regression.sh"
bash "$repo_root/Tests/run-table-attachment-regression.sh"
bash "$repo_root/Tests/run-semantic-presentation-differential.sh"
bash "$repo_root/Tests/run-editor-coordinator-regression.sh"
bash "$repo_root/Tests/run-coordinator-source-integrity-regression.sh"
bash "$repo_root/Tests/run-glyph-layout-warning-regression.sh"
bash "$repo_root/Tests/run-editing-stability-regression.sh"
bash "$repo_root/Tests/run-layout-performance-regression.sh"
bash "$repo_root/Tests/run-syntax-hider-regression.sh"

if [[ "$include_preview" -eq 1 ]]; then
  bash "$repo_root/Tests/run_quicklook_preview_harness.sh"
fi
