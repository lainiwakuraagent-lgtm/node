#!/bin/bash
# LOOM CLI — @Lain's task management shell wrapper
# Convenience wrapper around: python3 -m loom.cli
# Usage: loom.sh {queue|context|task|project|...} [args]

set -euo pipefail

LOOM_DIR="${HOME}/.local/share/loom"
LOOM_DB="${LOOM_DIR}/loom.db"
LOOM_SRC="${HOME}/lain/loom"
CONTEXT_FILE="/home/andrii/lain/agent_project/state/loom_context.json"

# Ensure DB directory exists
mkdir -p "$LOOM_DIR"

PYTHONPATH="$LOOM_SRC${PYTHONPATH:+:$PYTHONPATH}" exec "${LOOM_SRC}/.venv/bin/python" -m loom.cli \
    --db "$LOOM_DB" \
    "$@"
