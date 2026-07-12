#!/usr/bin/env bash
# interactive.sh — Launch an interactive Claude Code session with full agent context.
#
# Usage (from project root or any directory):
#   bash scripts/interactive.sh
#
# What it does:
#   1. Refreshes Loom context snapshot
#   2. Refreshes behavioral context (tone calibration)
#   3. Refreshes Nexus JWT token
#   4. Writes trigger_mode=manual to state/
#   5. Launches claude interactively (no dangerously-skip-permissions — owner is present)
#
# The agent's CLAUDE.md in the project root tells Claude Code who it is
# and what files to read at session start.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# --- Load agent config ---
AGENT_CONFIG="state/agent_config.env"
if [ -f "$AGENT_CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$AGENT_CONFIG"
fi
AGENT_NAME="${AGENT_NAME:-agent}"
NODE_VERSION="${NODE_VERSION:-claude-sonnet-4-6}"
NEXUS_URL="${NEXUS_URL:-http://100.110.36.84:8900}"
LOOM_SRC="${HOME}/lain/loom"
LOOM_DB="${HOME}/.local/share/loom/loom.db"

echo ""
echo "=== ${AGENT_NAME} interactive session ==="
echo "Model  : ${NODE_VERSION}"
echo "Project: ${PROJECT_DIR}"
echo ""

# --- Refresh Loom context snapshot (non-fatal) ---
if [ -d "$LOOM_SRC" ] && [ -f "$LOOM_SRC/.venv/bin/python" ]; then
  ACTIVE_GOAL_ID=$(python3 -c \
    "import sqlite3; c=sqlite3.connect('$LOOM_DB'); r=c.execute(\"SELECT id FROM goals WHERE status='active' LIMIT 1\").fetchone(); print(r[0] if r else '')" \
    2>/dev/null || echo "")
  GOAL_ARG=""
  if [ -n "$ACTIVE_GOAL_ID" ]; then
    GOAL_ARG="--goal $ACTIVE_GOAL_ID"
  fi
  PYTHONPATH="$LOOM_SRC" "$LOOM_SRC/.venv/bin/python" -m loom.cli \
    --db "$LOOM_DB" context $GOAL_ARG --output "state/loom_context.json" > /dev/null 2>&1 \
    && echo "[ok] Loom context refreshed (goal=${ACTIVE_GOAL_ID:-none})" \
    || echo "[warn] Loom context refresh failed (continuing)"
fi

# --- Refresh behavioral context (non-fatal) ---
BEHAVIORAL_PROFILE="memory/work/musubi_data/users/${AGENT_NAME}/andrii.md"
if [ -f "tools/behavioral_adapter.py" ] && [ -f "$BEHAVIORAL_PROFILE" ]; then
  /usr/bin/python3 tools/behavioral_adapter.py \
    --user-file "$BEHAVIORAL_PROFILE" \
    --output state/behavioral_context.txt > /dev/null 2>&1 \
    && echo "[ok] Behavioral context refreshed" \
    || echo "[warn] Behavioral context refresh failed (continuing)"
fi

# --- Refresh Nexus JWT (non-fatal) ---
NEXUS_PASS_FILE="identity/nexus_seed_passwords.txt"
if [ -f "$NEXUS_PASS_FILE" ]; then
  _nexus_pass=$(grep "^# ${AGENT_NAME}" "$NEXUS_PASS_FILE" 2>/dev/null | grep -o '[^ ]*$' | head -1 || echo "")
  if [ -n "$_nexus_pass" ]; then
    _nexus_token=$(curl -s --max-time 5 -X POST "${NEXUS_URL}/auth/token" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${AGENT_NAME}\",\"password\":\"${_nexus_pass}\"}" \
      | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('access_token',''))" \
      2>/dev/null || echo "")
    if [ -n "$_nexus_token" ]; then
      echo "$_nexus_token" > "state/nexus_${AGENT_NAME}_token.txt"
      echo "[ok] Nexus JWT refreshed"
    else
      echo "[warn] Nexus JWT refresh failed (continuing)"
    fi
  fi
fi

# --- Write trigger mode ---
echo "manual" > state/trigger_mode.txt

echo ""
echo "Launching... (type /exit or Ctrl+C to quit)"
echo ""

# --- Launch Claude Code interactively ---
# No --dangerously-skip-permissions: the owner is present and can approve tool calls.
# Claude Code reads CLAUDE.md from this directory on startup for agent context.
claude --model "${NODE_VERSION}"
