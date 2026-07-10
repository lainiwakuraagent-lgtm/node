#!/usr/bin/env bash
# goal_switch.sh — Switch the active goal in Loom.
#
# Usage: goal_switch.sh <goal_id>
#
# What it does:
#   1. Activates <goal_id> in the Loom DB (status → active).
#   2. Demotes previously active goals to 'in_progress' (paused).
#   3. Regenerates state/loom_context.json for the new active goal.
#   4. Prints a confirmation.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOM_DIR="/home/andrii/lain/loom"
LOOM_PYTHON="$LOOM_DIR/.venv/bin/python"
STATE_FILE="$PROJECT_DIR/state/loom_context.json"
LOOM_DB="${HOME}/.local/share/loom/loom.db"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <goal_id>" >&2
    exit 1
fi

GOAL_ID="$1"

# Verify loom venv exists
if [[ ! -x "$LOOM_PYTHON" ]]; then
    echo "ERROR: loom venv not found at $LOOM_PYTHON" >&2
    echo "Run: cd $LOOM_DIR && python3 -m venv .venv && .venv/bin/pip install -e ." >&2
    exit 1
fi

loom_cmd() { PYTHONPATH="$LOOM_DIR" "$LOOM_PYTHON" -m loom.cli --db "$LOOM_DB" "$@"; }

echo "[goal_switch] Activating goal $GOAL_ID..."
loom_cmd goal activate "$GOAL_ID" --pause-others

echo "[goal_switch] Generating context snapshot..."
loom_cmd context --goal "$GOAL_ID" --output "$STATE_FILE"

echo "[goal_switch] Done. Active goal: $GOAL_ID"
echo "[goal_switch] Context written to: $STATE_FILE"

# Show last handoff note for this goal (if any) so caller has immediate context.
LAST_HANDOFF=$(python3 -c "
import sqlite3, sys
c = sqlite3.connect('$LOOM_DB')
r = c.execute(
    'SELECT handoff_note, date, session_number FROM loom_sessions '
    'WHERE active_goal_id = ? AND handoff_note IS NOT NULL '
    'ORDER BY id DESC LIMIT 1',
    (int(sys.argv[1]),)
).fetchone()
if r:
    print(f'[goal_switch] Last handoff ({r[1]} #{r[2]}): {r[0]}')
else:
    print('[goal_switch] No prior handoff note for this goal.')
" "$GOAL_ID" 2>/dev/null || echo "[goal_switch] (could not query handoff note)")
echo "$LAST_HANDOFF"
