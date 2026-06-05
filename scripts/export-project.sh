#!/usr/bin/env bash
set -euo pipefail
# Ballad Export Script — Codex plugin entrypoint
# Usage: export-project.sh [project-root] [output-dir] [--layout lua|love]

PROJECT_ROOT="${1:-.}"
OUTPUT_DIR="${2:-dist/ballad}"
LAYOUT="${3:-lua}"

if ! command -v moon > /dev/null 2>&1; then
    echo "Error: moon CLI not found in PATH" >&2
    exit 1
fi

if [ ! -f "$PROJECT_ROOT/moonstone.toml" ]; then
    echo "Error: moonstone.toml not found in $PROJECT_ROOT" >&2
    exit 1
fi

cd "$PROJECT_ROOT"

# Ensure environment is synchronized
moon sync

# Run ballad export
moon exec -- ballad "$PROJECT_ROOT" "$OUTPUT_DIR" --layout "$LAYOUT"

echo "Export complete: $OUTPUT_DIR"
