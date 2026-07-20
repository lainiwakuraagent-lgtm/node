#!/usr/bin/env bash
# wake.sh
# Invoked by systemd timers or the manual trigger server.
# Supports three launch modes via TRIGGER_MODE env var:
#   nightly   (default) — scheduled night sessions, window + trigger gate enforcement
#   emergency           — emergency/daytime mode, window gates bypassed
#   manual              — owner-initiated trigger, window gates bypassed
#
# Usage: wake.sh <goal_file> [persona_file]

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/home/andrii/lain/agent_project}"
STATE_DIR="$PROJECT_DIR/state"
LOG_DIR="$PROJECT_DIR/logs"
WRAPPER_TEMPLATE="$PROJECT_DIR/prompts/wrapper_prompt.md"
EMERGENCY_FLAG="$STATE_DIR/emergency_mode.active"

# --- Load agent config (parameterize for new node instances) ---
AGENT_CONFIG="$STATE_DIR/agent_config.env"
if [ -f "$AGENT_CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$AGENT_CONFIG"
fi
AGENT_NAME="${AGENT_NAME:-lain}"
OWNER_NAME="${OWNER_NAME:-andrii}"
AGENT_REPO="${AGENT_REPO:-lainiwakuraagent-lgtm/node}"
NODE_VERSION="${NODE_VERSION:-claude-sonnet-4-6}"
NEXUS_URL="${NEXUS_URL:-http://100.110.36.84:8900}"

GOAL_FILE="${1:?Usage: wake.sh <goal_file> [persona_file]}"
PERSONA_FILE="${2:-}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

timestamp() { date '+%Y-%m-%d %H:%M:%S %Z'; }
log_line() { echo "[$(timestamp)] $*" >> "$LOG_DIR/wake.log"; }

# --- Log rotation (non-fatal) ---
# If wake.log exceeds 1MB, rotate it before writing this session's entries.
# Keeps the last 3 rotated files; older ones are removed automatically.
{
  _wake_log="$LOG_DIR/wake.log"
  _wake_log_size=$(stat -c%s "$_wake_log" 2>/dev/null || echo 0)
  if [ "$_wake_log_size" -gt 1048576 ]; then
    _rotated="$LOG_DIR/wake.log.$(date +%Y%m%d_%H%M%S).gz"
    if gzip -c "$_wake_log" > "$_rotated"; then
      > "$_wake_log"
      # Remove all but the 3 most recent rotated files
      # shellcheck disable=SC2012
      ls -t "$LOG_DIR"/wake.log.*.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
      log_line "LOG ROTATED: was $_wake_log_size bytes → $_rotated (keeping last 3)."
    fi
  fi
  unset _wake_log _wake_log_size _rotated
} || true

# --- Determine trigger mode ---
TRIGGER_MODE="${TRIGGER_MODE:-nightly}"
case "$TRIGGER_MODE" in
  nightly|emergency|manual) ;;
  *)
    log_line "ERROR: unknown TRIGGER_MODE '$TRIGGER_MODE'. Defaulting to nightly."
    TRIGGER_MODE="nightly"
    ;;
esac

log_line "Wake called. TRIGGER_MODE=$TRIGGER_MODE"

# --- Night ID (used for log file naming and Loom session recording) ---
hour=$(date +%H); hour=$((10#$hour))
if [ "$hour" -lt 6 ]; then
  night_id=$(date -d "yesterday" +%Y-%m-%d)
else
  night_id=$(date +%Y-%m-%d)
fi

# Session counter — purely informational, no cap enforced.
COUNT_FILE="$STATE_DIR/sessions_tonight.count"
DATE_FILE="$STATE_DIR/sessions_tonight.date"
last_recorded_night=""
if [ -f "$DATE_FILE" ]; then
  last_recorded_night=$(cat "$DATE_FILE")
fi
if [ "$last_recorded_night" != "$night_id" ]; then
  echo "0" > "$COUNT_FILE"
  echo "$night_id" > "$DATE_FILE"
  log_line "New night detected ($night_id). Session counter reset to 0."
fi
current_count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")

# --- Gate 0: subscription usage limits (all modes) ---
# Fail-open on errors so network/auth issues never silently kill the launch.
usage_check_output=$(bash "$PROJECT_DIR/tools/check_usage.sh" 2>&1) \
  || usage_check_output="ACTION: cannot check usage -- treat as unknown, proceed with caution."
usage_action=$(echo "$usage_check_output" | grep '^ACTION:' | head -n1)

if echo "$usage_action" | grep -q 'usage limit exceeded'; then
  log_line "ABORT: subscription usage too high. check_usage.sh output: $usage_check_output"
  exit 0
fi
if echo "$usage_action" | grep -q 'cannot check usage'; then
  log_line "WARNING: could not check usage limits (proceeding). check_usage.sh output: $usage_check_output"
fi

# --- Gate 1 (nightly only): block if emergency mode is active ---
# Emergency mode owns the schedule when active; nightly sessions step aside.
if [ "$TRIGGER_MODE" = "nightly" ]; then
  if [ -f "$EMERGENCY_FLAG" ]; then
    reason=$(head -1 "$EMERGENCY_FLAG")
    log_line "ABORT: emergency mode is active ($reason) — nightly session skipped. Disable emergency mode to resume nightly schedule."
    exit 0
  fi
fi

# --- Gate 2 (nightly only): window + trigger check from session_schedule.json ---
# Emergency and manual modes bypass window checks entirely.
if [ "$TRIGGER_MODE" = "nightly" ]; then
  SCHEDULE_FILE="$PROJECT_DIR/config/session_schedule.json"
  LOCK_FILE_PRE="$STATE_DIR/session.lock"

  window_result=$(python3 -c "
import json, sys, os
from datetime import datetime

schedule_file = sys.argv[1]
lock_file = sys.argv[2]

try:
    with open(schedule_file) as f:
        schedule = json.load(f)
except (FileNotFoundError, json.JSONDecodeError) as e:
    print('ERROR: cannot read schedule: ' + str(e), file=sys.stderr)
    print('LAUNCH: yes')
    print('WINDOW_TYPE: work')
    print('decision=launch reason=schedule_unreadable')
    sys.exit(0)

now = datetime.now()
now_minutes = now.hour * 60 + now.minute
now_seconds = now.hour * 3600 + now.minute * 60 + now.second

TRIGGER_TOLERANCE_SEC = 45

def time_to_minutes(t):
    h, m = map(int, t.split(':'))
    return h * 60 + m

def time_to_seconds(t):
    h, m = map(int, t.split(':'))
    return h * 3600 + m * 60

def in_window(start_str, end_str, now_min):
    start = time_to_minutes(start_str)
    end = time_to_minutes(end_str)
    if start <= end:
        return start <= now_min < end
    else:
        # wraps midnight (e.g., 23:00-05:00)
        return now_min >= start or now_min < end

# --- Validate: windows must not overlap ---
enabled_windows = [w for w in schedule.get('windows', []) if w.get('enabled', True)]

def windows_overlap(a, b):
    \"\"\"Check if two windows overlap. Handles midnight wrapping.\"\"\"
    a_start = time_to_minutes(a['start'])
    a_end = time_to_minutes(a['end'])
    b_start = time_to_minutes(b['start'])
    b_end = time_to_minutes(b['end'])

    # Normalize to ranges on a 0-2880 timeline (two days) to handle midnight wrap
    def expand(s, e):
        if s <= e:
            return [(s, e)]
        else:
            return [(s, 1440), (0, e)]

    a_ranges = expand(a_start, a_end)
    b_ranges = expand(b_start, b_end)

    for ar in a_ranges:
        for br in b_ranges:
            if ar[0] < br[1] and br[0] < ar[1]:
                return True
    return False

for i in range(len(enabled_windows)):
    for j in range(i + 1, len(enabled_windows)):
        if windows_overlap(enabled_windows[i], enabled_windows[j]):
            la = enabled_windows[i]['label']
            lb = enabled_windows[j]['label']
            print(f'ERROR: overlapping windows: {la} and {lb}', file=sys.stderr)
            print('LAUNCH: no')
            print('WINDOW_TYPE: none')
            print(f'decision=abort reason=overlapping_windows windows={la},{lb}')
            sys.exit(0)

# Check all enabled windows
matched_window = None
matched_type = 'work'
trigger_hit = False
consecutive_run = False

for w in enabled_windows:
    if not in_window(w['start'], w['end'], now_minutes):
        continue
    matched_window = w['label']
    matched_type = w.get('type', 'work')

    # Check triggers within +-45s tolerance
    for trigger in w.get('triggers', []):
        trigger_sec = time_to_seconds(trigger)
        diff = abs(now_seconds - trigger_sec)
        # Handle midnight wrap for diff
        if diff > 43200:
            diff = 86400 - diff
        if diff <= TRIGGER_TOLERANCE_SEC:
            trigger_hit = True
            break

    if not trigger_hit:
        # Inside window, no trigger match -- consecutive run if no lock
        if not os.path.exists(lock_file):
            consecutive_run = True
    break

# Check one_off entries (+-45s tolerance, creates implicit window)
one_off_hit = False
one_off_label = ''
one_off_type = 'work'
for entry in schedule.get('one_off', []):
    if entry.get('fired', True):
        continue
    dt_str = entry.get('datetime', '')
    if not dt_str:
        continue
    try:
        dt = datetime.fromisoformat(dt_str)
        diff_sec = abs((now - dt.replace(tzinfo=None)).total_seconds())
        if diff_sec <= TRIGGER_TOLERANCE_SEC:
            one_off_hit = True
            one_off_label = entry.get('label', 'unnamed')
            one_off_type = entry.get('type', 'work')
            # Mark as fired
            entry['fired'] = True
            tmp = schedule_file + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(schedule, f, indent=2)
            os.replace(tmp, schedule_file)
            break
    except (ValueError, TypeError):
        continue

if trigger_hit:
    print('LAUNCH: yes')
    print(f'WINDOW_TYPE: {matched_type}')
    print(f'decision=launch reason=trigger_match window={matched_window}')
elif one_off_hit:
    print('LAUNCH: yes')
    print(f'WINDOW_TYPE: {one_off_type}')
    print(f'decision=launch reason=one_off_match label={one_off_label}')
elif consecutive_run:
    print('LAUNCH: yes')
    print(f'WINDOW_TYPE: {matched_type}')
    print(f'decision=launch reason=consecutive_run window={matched_window}')
elif matched_window:
    # Inside window but lock exists -- another session is running
    print('LAUNCH: no')
    print(f'WINDOW_TYPE: {matched_type}')
    print(f'decision=skip reason=inside_window_but_locked window={matched_window}')
else:
    print('LAUNCH: no')
    print('WINDOW_TYPE: none')
    print('decision=skip reason=outside_all_windows')
" "$SCHEDULE_FILE" "$LOCK_FILE_PRE" 2>&1)

  log_line "Window check result: $window_result"

  window_launch=$(echo "$window_result" | grep '^LAUNCH:' | head -1 | awk '{print $2}')
  WINDOW_TYPE=$(echo "$window_result" | grep '^WINDOW_TYPE:' | head -1 | awk '{print $2}')
  export WINDOW_TYPE
  log_line "Window type: $WINDOW_TYPE"

  if [ "$window_launch" != "yes" ]; then
    log_line "ABORT: window gate denied launch. $window_result"
    exit 0
  fi
else
  log_line "Gate 2 (window check) skipped — TRIGGER_MODE=$TRIGGER_MODE."
fi

# --- Gate 4: no session already running (all modes) ---
LOCK_FILE="$STATE_DIR/session.lock"
if [ -f "$LOCK_FILE" ]; then
  locked_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$locked_pid" ] && kill -0 "$locked_pid" 2>/dev/null; then
    log_line "SKIP: session already running (PID $locked_pid). Skipping this wake."
    exit 0
  else
    log_line "WARNING: stale lock found (PID ${locked_pid:-unknown} is dead). Removing and proceeding."
    rm -f "$LOCK_FILE"
  fi
fi

# --- Pre-launch: clean up any stale temp files from crashed previous sessions ---
# The lock gate above confirms no session is running, so leftover temps are safe to remove.
for _stale_pattern in \
    "$STATE_DIR/session_prompt.*.md" \
    "$STATE_DIR/augmented_goal.*.md" \
    "$STATE_DIR/conv_prompt.*.md" \
    "$STATE_DIR/session_type_result.*.json"; do
  # shellcheck disable=SC2086
  _stale_count=$(ls $_stale_pattern 2>/dev/null | wc -l; exit 0)
  if [ "$_stale_count" -gt 0 ]; then
    # shellcheck disable=SC2086
    rm -f $_stale_pattern
    log_line "Cleaned up $_stale_count stale temp file(s) matching $(basename "$_stale_pattern")."
  fi
done
unset _stale_pattern _stale_count

# --- All gates passed: launch the agent ---
new_count=$((current_count + 1))
log_line "LAUNCHING session #$new_count (mode=$TRIGGER_MODE, night=$night_id). Goal file: $GOAL_FILE"

# Build prompt by splicing goal (and optional persona) into the wrapper template.
session_prompt=$(mktemp "$STATE_DIR/session_prompt.XXXXXX.md")

# If goal.txt has "GOAL_STATUS: complete" on line 1, fall back to default_goal.txt.
GOAL_STATUS=$(awk 'NR==1 && /GOAL_STATUS:/ {print $2; exit}' "$GOAL_FILE")
if [ "$GOAL_STATUS" = "complete" ]; then
  DEFAULT_GOAL="$PROJECT_DIR/prompts/default_goal.txt"
  if [ -f "$DEFAULT_GOAL" ]; then
    log_line "Goal marked complete. Using default_goal.txt for this session."
    GOAL_FILE="$DEFAULT_GOAL"
  else
    log_line "WARNING: goal marked complete but default_goal.txt not found. Using original goal file."
  fi
fi

if [ -n "$PERSONA_FILE" ] && [ -f "$PERSONA_FILE" ]; then
  persona_arg="$PERSONA_FILE"
else
  persona_arg=""
fi

# --- Session type resolution ---
# Priority: SESSION_TYPE env var → Loom queue state → default (maintenance)
# Resolves type, loads type config YAML, assembles context files + type prompt.
SESSION_TYPE_RESULT=$(mktemp "$STATE_DIR/session_type_result.XXXXXX.json")
if [ -f "$PROJECT_DIR/scripts/resolve_session_type.py" ]; then
  _type_stderr=$(python3 "$PROJECT_DIR/scripts/resolve_session_type.py" \
    --project-dir "$PROJECT_DIR" \
    --trigger-mode "$TRIGGER_MODE" \
    --output "$SESSION_TYPE_RESULT" 2>&1) || true
  log_line "Session type resolution: ${_type_stderr:-no output}"

  # Parse resolved type and resolution source; write to state and export for analytics.
  CURRENT_SESSION_TYPE=$(python3 -c \
    "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('session_type','execution'))" \
    "$SESSION_TYPE_RESULT" 2>/dev/null || echo "execution")
  CURRENT_SESSION_TYPE_SOURCE=$(python3 -c \
    "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('resolution_source','default'))" \
    "$SESSION_TYPE_RESULT" 2>/dev/null || echo "default")
  export CURRENT_SESSION_TYPE CURRENT_SESSION_TYPE_SOURCE
  echo "$CURRENT_SESSION_TYPE" > "$STATE_DIR/current_session_type.txt"
  log_line "Session type: $CURRENT_SESSION_TYPE (source: $CURRENT_SESSION_TYPE_SOURCE)"

  # Export maintenance scope if present (scope_id from resolve_session_type.py result).
  MAINTENANCE_SCOPE=$(python3 -c \
    "import json,sys; d=json.load(open(sys.argv[1])); s=d.get('scope_id'); print(s if s else '')" \
    "$SESSION_TYPE_RESULT" 2>/dev/null || echo "")
  export MAINTENANCE_SCOPE
  [ -n "$MAINTENANCE_SCOPE" ] && log_line "Maintenance scope: $MAINTENANCE_SCOPE"

  # Build augmented goal: type prompt + context preload + original goal content.
  # Falls back to original goal if the augmentation step fails.
  AUGMENTED_GOAL=$(mktemp "$STATE_DIR/augmented_goal.XXXXXX.md")
  python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    goal = open(sys.argv[2]).read().strip()
    parts = []
    p = data.get('prompt_content', '').strip()
    c = data.get('assembled_context', '').strip()
    # Substitute maintenance scope placeholders if present
    if p and data.get('scope_id'):
        scope_name = data.get('scope_name', f'Scope {data[\"scope_id\"]}')
        focus_hint = data.get('focus_hint', '')
        p = p.replace('{MAINTENANCE_SCOPE_NAME}', scope_name)
        p = p.replace('{MAINTENANCE_SCOPE_FOCUS}', focus_hint)
    if p:
        parts.append(p)
    if c:
        parts.append('## CONTEXT PRELOAD\n\n' + c)
    parts.append(goal)
    open(sys.argv[3], 'w').write('\n\n---\n\n'.join(parts) + '\n')
except Exception:
    import shutil
    shutil.copy(sys.argv[2], sys.argv[3])
" "$SESSION_TYPE_RESULT" "$GOAL_FILE" "$AUGMENTED_GOAL" 2>/dev/null \
    || cp "$GOAL_FILE" "$AUGMENTED_GOAL"

  rm -f "$SESSION_TYPE_RESULT"
  GOAL_FILE="$AUGMENTED_GOAL"
  log_line "Augmented goal built for session type: $CURRENT_SESSION_TYPE"
else
  log_line "WARNING: resolve_session_type.py not found — skipping type injection."
  CURRENT_SESSION_TYPE="execution"
  CURRENT_SESSION_TYPE_SOURCE="default"
  export CURRENT_SESSION_TYPE CURRENT_SESSION_TYPE_SOURCE
  echo "$CURRENT_SESSION_TYPE" > "$STATE_DIR/current_session_type.txt"
fi

python3 "$PROJECT_DIR/scripts/splice_prompt.py" \
  "$WRAPPER_TEMPLATE" "$GOAL_FILE" "$session_prompt" "$persona_arg"

# --- Generate LOOM context snapshot and record session start (optional, non-fatal) ---
LOOM_CONTEXT_FILE="$STATE_DIR/loom_context.json"
LOOM_SRC="${HOME}/lain/loom"
LOOM_DB="${HOME}/.local/share/loom/loom.db"
LOOM_SESSION_ROW_ID=""
if [ -d "$LOOM_SRC" ] && [ -f "$LOOM_SRC/.venv/bin/python" ]; then
  loom_py() { PYTHONPATH="$LOOM_SRC" "$LOOM_SRC/.venv/bin/python" -m loom.cli --db "$LOOM_DB" "$@"; }

  # Detect active goal from DB (python3 — sqlite3 CLI not available on this machine).
  ACTIVE_GOAL_ID=$(python3 -c \
    "import sqlite3,sys; c=sqlite3.connect('$LOOM_DB'); r=c.execute(\"SELECT id FROM goals WHERE status IN ('scheduled','in_progress') ORDER BY priority DESC LIMIT 1\").fetchone(); print(r[0] if r else '')" \
    2>/dev/null || echo "")
  GOAL_ARG=""
  if [ -n "$ACTIVE_GOAL_ID" ]; then
    GOAL_ARG="--goal $ACTIVE_GOAL_ID"
    log_line "LOOM active goal detected: ID=$ACTIVE_GOAL_ID"
  fi

  loom_py context $GOAL_ARG --output "$LOOM_CONTEXT_FILE" > /dev/null 2>&1 \
    && log_line "LOOM context snapshot written to $LOOM_CONTEXT_FILE" \
    || log_line "WARNING: loom context snapshot failed (non-fatal)."

  # Record session start in loom_sessions table.
  LOOM_SESSION_ROW_ID=$(loom_py session start \
    --date "$night_id" --number "$new_count" \
    --type "$TRIGGER_MODE" ${ACTIVE_GOAL_ID:+--goal "$ACTIVE_GOAL_ID"} 2>/dev/null || echo "")
  if [ -n "$LOOM_SESSION_ROW_ID" ]; then
    log_line "LOOM session row created: id=$LOOM_SESSION_ROW_ID"
    # Write row ID to state file so the agent can update handoff note during shutdown.
    echo "$LOOM_SESSION_ROW_ID" > "$STATE_DIR/current_loom_session_id.txt"
  else
    log_line "WARNING: loom session start failed (non-fatal)."
    rm -f "$STATE_DIR/current_loom_session_id.txt"
  fi
fi

# Record count BEFORE launching — counts even if agent crashes or hangs.
echo "$new_count" > "$COUNT_FILE"

# Write trigger mode so Lain can read it during orientation.
echo "$TRIGGER_MODE" > "$STATE_DIR/trigger_mode.txt"

session_start_epoch=$(date +%s)
echo "$session_start_epoch" > "$STATE_DIR/session_start_epoch"

# Write lock file. EXIT trap ensures cleanup even on crash.
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# --- Refresh Nexus JWT token (non-fatal) ---
# Keeps state/nexus_lain_token.txt fresh so Lain can use it immediately each session.
NEXUS_PASS_FILE="$PROJECT_DIR/identity/nexus_seed_passwords.txt"
if [ -f "$NEXUS_PASS_FILE" ]; then
  _nexus_pass=$(grep "^# ${AGENT_NAME}" "$NEXUS_PASS_FILE" | grep -o '[^ ]*$' | head -1)
  _nexus_token=$(curl -s --max-time 5 -X POST "${NEXUS_URL}/auth/token" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${AGENT_NAME}\",\"password\":\"$_nexus_pass\"}" \
    | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('access_token',''))" \
    2>/dev/null || echo "")
  if [ -n "$_nexus_token" ]; then
    echo "$_nexus_token" > "$STATE_DIR/nexus_${AGENT_NAME}_token.txt"
    log_line "Nexus JWT refreshed."
  else
    log_line "WARNING: Nexus JWT refresh failed (non-fatal) — nexus may be down or password changed."
  fi
fi

# --- Generate behavioral context snapshot (non-fatal) ---
BEHAVIORAL_TOOL="$PROJECT_DIR/tools/behavioral_adapter.py"
BEHAVIORAL_PROFILE="$PROJECT_DIR/memory/work/musubi_data/users/${AGENT_NAME}/${OWNER_NAME}.md"
BEHAVIORAL_CONTEXT="$STATE_DIR/behavioral_context.txt"
if [ -f "$BEHAVIORAL_TOOL" ] && [ -f "$BEHAVIORAL_PROFILE" ]; then
  /usr/bin/python3 "$BEHAVIORAL_TOOL" \
    --user-file "$BEHAVIORAL_PROFILE" \
    --output "$BEHAVIORAL_CONTEXT" > /dev/null 2>&1 \
    && log_line "Behavioral context generated: $BEHAVIORAL_CONTEXT" \
    || log_line "WARNING: behavioral_adapter.py failed (non-fatal)."
fi

# --- Prune processed inbox entries older than 7 days (non-fatal) ---
INBOX_READ="$PROJECT_DIR/tools/inbox_read.py"
if [ -f "$INBOX_READ" ]; then
  _prune_result=$(/usr/bin/python3 "$INBOX_READ" --prune 2>/dev/null || echo "")
  [ -n "$_prune_result" ] && log_line "$_prune_result" || true
fi

# --- Launch Claude Code headless ---
# --dangerously-skip-permissions is intentional: agent runs unattended.
# Containment is handled at the VM/network level, not here.
SESSION_MODEL_FILE="$STATE_DIR/session_model.txt"
if [[ -f "$SESSION_MODEL_FILE" ]] && [[ -s "$SESSION_MODEL_FILE" ]]; then
  SESSION_MODEL=$(cat "$SESSION_MODEL_FILE")
else
  SESSION_MODEL="${NODE_VERSION:-claude-sonnet-4-6}"
fi
log_line "Using model: $SESSION_MODEL"

claude --dangerously-skip-permissions --model "$SESSION_MODEL" < "$session_prompt" \
  >> "$LOG_DIR/session_${night_id}_${new_count}.out" \
  2>> "$LOG_DIR/session_${night_id}_${new_count}.err"

exit_code=$?
session_end_epoch=$(date +%s)
duration_min=$(( (session_end_epoch - session_start_epoch) / 60 ))

log_line "Session #$new_count ended. exit_code=$exit_code duration_min=$duration_min"
rm -f "$session_prompt"
[ -n "${AUGMENTED_GOAL:-}" ] && rm -f "$AUGMENTED_GOAL"

# --- Record session end in Loom (non-fatal) ---
if [ -n "$LOOM_SESSION_ROW_ID" ] && [ -d "$LOOM_SRC" ] && [ -f "$LOOM_SRC/.venv/bin/python" ]; then
  EXIT_REASON="exit_code=$exit_code"
  PYTHONPATH="$LOOM_SRC" "$LOOM_SRC/.venv/bin/python" -m loom.cli --db "$LOOM_DB" \
    session end --id "$LOOM_SESSION_ROW_ID" \
    --exit-reason "$EXIT_REASON" > /dev/null 2>&1 \
    && log_line "LOOM session $LOOM_SESSION_ROW_ID closed." \
    || log_line "WARNING: loom session end failed (non-fatal)."
fi

# --- Update relationship state (non-fatal, heuristic mode) ---
# Reads last 60 lines of wake.log for this session as classification context.
# Applies decay + classifies events → updates memory/work/musubi_data/users/lain/andrii.md
REL_TOOL="$PROJECT_DIR/tools/relationship_update.py"
REL_PROFILE="$PROJECT_DIR/memory/work/musubi_data/users/${AGENT_NAME}/${OWNER_NAME}.md"
if [ -f "$REL_TOOL" ] && [ -f "$REL_PROFILE" ]; then
  tail -60 "$LOG_DIR/wake.log" | /usr/bin/python3 "$REL_TOOL" \
    --user-file "$REL_PROFILE" \
    --heuristic --stdin --nexus-notify > /dev/null 2>&1 \
    && log_line "Relationship state updated + broadcast to Nexus quorum-ops." \
    || log_line "WARNING: relationship_update.py failed (non-fatal)."
fi
