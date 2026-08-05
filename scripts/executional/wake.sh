#!/usr/bin/env bash
# wake.sh
# Invoked by systemd timers or the manual trigger server.
# Supports three launch modes via TRIGGER_MODE env var:
#   nightly   (default) — scheduled night sessions, window + trigger gate enforcement
#   emergency           — emergency/daytime mode, window gates bypassed
#   manual              — owner-initiated trigger, window gates bypassed
#
# Usage: wake.sh [persona_file]
#
# The goal is no longer a static file — Loom is the sole goal/project source.
# The active goal/project (see loom's GoalService.resolve_active()) is
# resolved from the Loom DB early in this script and used to build the
# session's base goal text dynamically. This replaces the old
# goal.txt / emergency_goal.txt / default_goal.txt files entirely.

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$PROJECT_DIR"
STATE_DIR="$PROJECT_DIR/state"
LOG_DIR="$PROJECT_DIR/logs"
CORE_PROMPT_DIR="$PROJECT_DIR/prompts/core"
EMERGENCY_FLAG="$STATE_DIR/emergency_mode.active"

# --- Load agent config (parameterize for new node instances) ---
AGENT_CONFIG="$STATE_DIR/agent_config.env"
if [ -f "$AGENT_CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$AGENT_CONFIG"
fi
AGENT_NAME="${AGENT_NAME:-UNCONFIGURED_AGENT}"
OWNER_NAME="${OWNER_NAME:-UNCONFIGURED_OWNER}"
if [ "$AGENT_NAME" = "UNCONFIGURED_AGENT" ] || [ "$OWNER_NAME" = "UNCONFIGURED_OWNER" ]; then
  echo "WARNING: AGENT_NAME or OWNER_NAME not set in $AGENT_CONFIG. Copy state/agent_config.env.example and configure it." >&2
fi
AGENT_REPO="${AGENT_REPO:-lainiwakuraagent-lgtm/node}"
NODE_VERSION="${NODE_VERSION:-claude-sonnet-4-6}"

PERSONA_FILE="${1:-}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

timestamp() { date '+%Y-%m-%d %H:%M:%S %Z'; }
log_line() { echo "[$(timestamp)] $*" >> "$LOG_DIR/wake.log"; }

# --- Trigger result reporting (no-op unless TRIGGER_REQUEST_ID is set) ---
# The manual-trigger HTTP endpoints (session_trigger_server.py, web_server.py)
# launch this script fire-and-forget and have no other way to learn whether a
# session actually started -- they'd otherwise report "triggered" the instant
# the subprocess spawns, even if a gate below silently skips or aborts it.
# When set, TRIGGER_REQUEST_ID is echoed back in this file so the caller can
# match its own request to the right result (atomic write via tmp+replace,
# same pattern as check_window.py's mark-fired).
write_trigger_result() {
  [ -z "${TRIGGER_REQUEST_ID:-}" ] && return 0
  local decision="$1" reason="$2" stype="${3:-}" rpid="${4:-}"
  python3 -c '
import json, os, sys
request_id, decision, reason, session_type, pid, out_path = sys.argv[1:7]
data = {
    "request_id": request_id,
    "decision": decision,
    "reason": reason,
    "session_type": session_type or None,
    "pid": int(pid) if pid else None,
}
tmp = out_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f)
os.replace(tmp, out_path)
' "$TRIGGER_REQUEST_ID" "$decision" "$reason" "$stype" "$rpid" \
    "$STATE_DIR/manual_trigger_result.json" 2>/dev/null || true
}

# --- CI/CD template sync (non-fatal, before lock) ---
# Runs only if CI_CD_ENABLED=true in agent_config.env. @Lain is hardcoded false.
# Placed here: agent_config.env is sourced (CI_CD_ENABLED available), LOG_DIR
# exists, and the lock is not yet held (slow fetch should not block other gates).
bash "$PROJECT_DIR/scripts/executional/node_sync.sh" 2>/dev/null || true

# --- Gate 0: single-instance lock (all modes) — acquired FIRST, before any ---
# state mutation below (night-reset, philosophy cap, Loom writes). Previously
# this lock was only checked-then-written right before the `claude` launch,
# near the end of the script — with the night-reset block, Gate 1-3 checks,
# khal sync, Loom context resolution, and session-type resolution all running
# in between the check and the write. Any wake.sh invocation starting inside
# that window passed the check too (nothing had written the file yet), so
# duplicate triggers firing close together — as the stray T438 test timers
# did — could each build their own prompt and launch their own `claude`
# session concurrently, racing on the same state files. flock is atomic (no
# check-then-write gap) and self-releasing: if the holding process dies for
# any reason, including a crash the EXIT trap below never gets to run, the
# kernel drops the flock the moment its last fd closes. That makes the old
# manual "is the PID in the lock file still alive" staleness dance below
# unnecessary — flock already can't go stale.
#
# The lock file's path and plain-PID-text content are unchanged from before:
# scripts/executional/check_window.py (--lock-file, existence-only) and
# tools/executional/web_server.py (status display, reads the PID) both read
# this same file directly, so its shape has to stay a plain file, not a lock
# directory.
LOCK_FILE="$STATE_DIR/session.lock"
exec 9<>"$LOCK_FILE"
if ! flock -n 9; then
  log_line "SKIP: another wake.sh instance holds the lock. Skipping this wake."
  write_trigger_result "skipped" "session already running (lock held)"
  exit 0
fi
echo $$ > "$LOCK_FILE"
# No EXIT trap — flock on FD 9 is inherited by the claude child and released
# automatically by the kernel when the last holder (claude) exits. Removing
# the file on wake.sh EXIT would break this: a new instance could open a fresh
# inode and bypass the lock while claude still runs.

# --- Log rotation (non-fatal) ---
# If wake.log exceeds 1MB, rotate it before writing this session's entries.
# Keeps the last 3 rotated files; older ones are removed automatically.
{
  _wake_log="$LOG_DIR/wake.log"
  _wake_log_size=$(stat -c%s "$_wake_log" 2>/dev/null || echo 0)
  if [ "$_wake_log_size" -gt 1048576 ]; then
    _rotated="$LOG_DIR/wake.log.$(date +%Y%m%d_%H%M%S).gz"
    if gzip -c "$_wake_log" > "$_rotated"; then
      : > "$_wake_log"
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
  echo "0" > "$STATE_DIR/consecutive_philosophy.count"
  rm -f "$STATE_DIR/philosophy_cap.active" "$STATE_DIR/philosophy_cap_notified_at.txt"   # Clear philosophy cap on new night
  log_line "New night detected ($night_id). Session counter reset to 0."
fi
current_count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")

# --- Philosophy cap staleness/notification: moved to resolve_session_type.py + the
# philosophy_cap abort handler below. This used to be a separate nightly-only early
# exit here that only ever checked the inbox for "is the cap still valid" — it ran
# before the window check determined WINDOW_TYPE (so it could swallow a legitimate scheduled
# maintenance/reflection window that should override the cap), never checked the Loom
# queue itself (only inbox), and being nightly-gated meant emergency/manual mode had
# no reset path at all short of a full calendar-night rollover once capped. All of
# that logic now lives in resolve_session_type.py's Priority 2.5 (_cap_is_stale),
# which is mode-agnostic and Loom-aware, and runs every wake regardless of
# TRIGGER_MODE — the modest per-wake cost of always invoking it (a few sqlite
# queries) is a better trade than a second, drifting reimplementation in bash.
#
# Full list of what resets consecutive_philosophy.count / philosophy_cap.active:
#   1. New calendar night (immediately below) — the hard, guaranteed reset.
#   2. New working window within the same night/day (Gate 3, below) — a cap
#      hit in one scheduled window must not bleed into and block a later,
#      unrelated window.
#   3. A non-philosophy session actually runs (end of this script) — the
#      normal case once real queue/inbox work appears.
#   4. Staleness check in resolve_session_type.py's Priority 2.5 — clears an
#      already-active cap early if something genuinely new landed in Loom or
#      the inbox after the cap was set.

# --- Gate 1: subscription usage limits (nightly + emergency) ---
# manual is a deliberate break-glass override: it exists for exactly the case
# where a session is needed despite hitting a usage limit, so it skips this
# gate entirely rather than being fail-open on error like the other modes.
# This is what distinguishes it from emergency mode, which bypasses the time
# window but still respects usage limits.
if [ "$TRIGGER_MODE" = "manual" ]; then
  log_line "Gate 1 (usage check) bypassed -- TRIGGER_MODE=manual (break-glass override)."
else
  # Fail-open on errors so network/auth issues never silently kill the launch.
  usage_check_output=$(bash "$PROJECT_DIR/tools/executional/check_session.sh" --usage 2>&1) \
    || usage_check_output="ACTION: cannot check usage -- treat as unknown, proceed with caution."
  usage_action=$(echo "$usage_check_output" | grep '^ACTION:' | head -n1)

  if echo "$usage_action" | grep -q 'usage limit exceeded'; then
    log_line "ABORT: subscription usage too high. check_session.sh --usage output: $usage_check_output"
    exit 0
  fi
  if echo "$usage_action" | grep -q 'cannot check usage'; then
    log_line "WARNING: could not check usage limits (proceeding). check_session.sh --usage output: $usage_check_output"
  fi
fi

# --- Gate 2 (nightly only): block if emergency mode is active ---
# Emergency mode owns the schedule when active; nightly sessions step aside.
if [ "$TRIGGER_MODE" = "nightly" ]; then
  if [ -f "$EMERGENCY_FLAG" ]; then
    reason=$(head -1 "$EMERGENCY_FLAG")
    log_line "ABORT: emergency mode is active ($reason) — nightly session skipped. Disable emergency mode to resume nightly schedule."
    exit 0
  fi
fi

# --- Gate 3 (nightly only): window + trigger check from session_schedule.json ---
# Emergency and manual modes bypass window checks entirely.
# Logic lives in scripts/check_window.py. `check` is read-only — a matching
# one_off entry is detected but NOT marked fired here. It's only marked fired
# once we're past the lock (Gate 0, acquired at the top of this script),
# below, so a one_off session can never be silently consumed without actually
# launching.
ONE_OFF_INDEX=""
if [ "$TRIGGER_MODE" = "nightly" ]; then
  SCHEDULE_FILE="$PROJECT_DIR/config/session_schedule.json"

  # Best-effort: pull this agent's khal calendar into one_off[] before the
  # window check reads it, so user-added custom windows are considered.
  # windows[] (nightly-work/maintenance/reflection) is never touched by this --
  # a khal failure here must never block the fixed nightly schedule.
  khal_sync_result=$(python3 "$PROJECT_DIR/tools/executional/khal_schedule_reader.py" sync \
    --schedule-file "$SCHEDULE_FILE" 2>&1) || true
  log_line "khal schedule sync: $khal_sync_result"

  # check_window.py's own "someone else already running" signal (used for
  # its consecutive_run catch-up-poll logic) would otherwise read
  # $STATE_DIR/session.lock -- but by this point Gate 0 has already
  # atomically acquired that same lock for us, so it always exists from here
  # on and would misreport "someone else is running" against ourselves.
  # Double-launch is already structurally impossible (Gate 0 would have
  # exited before reaching here), so this check is redundant -- pass a path
  # guaranteed to never exist so it always reads "nobody else is running"
  # and the original catch-up-poll behavior is preserved. NOTE: /dev/null is
  # NOT such a path -- it's a real device node, os.path.exists('/dev/null')
  # is True, and that silently broke this exact check before this fix.
  window_result=$(python3 "$PROJECT_DIR/scripts/executional/check_window.py" check \
    --schedule-file "$SCHEDULE_FILE" --lock-file "$STATE_DIR/.no_lock_check" 2>&1)

  log_line "Window check result: $window_result"

  window_launch=$(echo "$window_result" | grep '^LAUNCH:' | head -1 | awk '{print $2}')
  WINDOW_TYPE=$(echo "$window_result" | grep '^WINDOW_TYPE:' | head -1 | awk '{print $2}')
  WINDOW_LABEL=$(echo "$window_result" | grep '^WINDOW_LABEL:' | head -1 | awk '{print $2}')
  ONE_OFF_INDEX=$(echo "$window_result" | grep '^one_off_index:' | head -1 | awk '{print $2}' || true)
  export WINDOW_TYPE
  log_line "Window type: $WINDOW_TYPE (label: ${WINDOW_LABEL:-none})"

  if [ "$window_launch" != "yes" ]; then
    log_line "ABORT: window gate denied launch. $window_result"
    exit 0
  fi

  # --- Reset philosophy cap/count on entering a new working window ---
  # The night-boundary reset above only fires once per calendar night, but a
  # single night (or a khal-synced daytime schedule) can contain several
  # distinct windows -- e.g. a 10:00-12:00 block and an unrelated 14:00-15:00
  # block. Hitting the cap in the first must not carry over and block the
  # second: each window is a fresh opportunity to work the queue/inbox.
  # Keyed on WINDOW_LABEL (not WINDOW_TYPE, which multiple windows can
  # share) so this only fires on a genuine window change, not on repeated
  # catch-up polls inside the same window. Two same-day windows sharing an
  # identical label (e.g. a recurring khal event with the same title) won't
  # be told apart -- session_schedule.json's windows[] already requires
  # unique labels, so this only matters for one_off entries.
  if [ -n "${WINDOW_LABEL:-}" ] && [ "$WINDOW_LABEL" != "none" ]; then
    LAST_WINDOW_FILE="$STATE_DIR/last_window_label.txt"
    last_window_label=""
    [ -f "$LAST_WINDOW_FILE" ] && last_window_label=$(cat "$LAST_WINDOW_FILE")
    if [ "$last_window_label" != "$WINDOW_LABEL" ]; then
      log_line "New working window entered ($WINDOW_LABEL, was: ${last_window_label:-none}). Resetting philosophy cap/count."
      echo "0" > "$STATE_DIR/consecutive_philosophy.count"
      rm -f "$STATE_DIR/philosophy_cap.active" "$STATE_DIR/philosophy_cap_notified_at.txt"
      echo "$WINDOW_LABEL" > "$LAST_WINDOW_FILE"
    fi
  fi
else
  log_line "Gate 3 (window check) skipped — TRIGGER_MODE=$TRIGGER_MODE."
fi

# session-count hard cap (was Gate 3 in an older revision) was downgraded to
# informational-only — see `current_count` above, tracked but not enforced.
# The single-instance lock is Gate 0, acquired at the very top of this script.

# We're already holding the lock (Gate 0, top of script) — safe to consume
# the one_off entry detected in Gate 3. For nightly mode, ONE_OFF_INDEX was
# already set by the Gate 3 check above. For manual/emergency mode, Gate 3 is
# skipped so we do a one-off-only check here.
if [ "$TRIGGER_MODE" != "nightly" ] && [ -z "$ONE_OFF_INDEX" ]; then
  _schedule_file="$PROJECT_DIR/config/session_schedule.json"
  if [ -f "$_schedule_file" ]; then
    _check_out=$(python3 "$PROJECT_DIR/scripts/executional/check_window.py" check \
      --schedule-file "$_schedule_file" --lock-file "$STATE_DIR/.no_lock_check" 2>/dev/null || true)
    ONE_OFF_INDEX=$(echo "$_check_out" | grep '^one_off_index:' | head -1 | awk '{print $2}' || true)
    SCHEDULE_FILE="$_schedule_file"
    if [ -n "$ONE_OFF_INDEX" ]; then
      log_line "One-off entry detected in $TRIGGER_MODE mode (index $ONE_OFF_INDEX)."
    fi
    unset _check_out _schedule_file
  fi
fi
if [ -n "$ONE_OFF_INDEX" ]; then
  python3 "$PROJECT_DIR/scripts/executional/check_window.py" mark-fired \
    --schedule-file "$SCHEDULE_FILE" --one-off-index "$ONE_OFF_INDEX" 2>&1 \
    | while IFS= read -r _line; do log_line "$_line"; done
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
log_line "LAUNCHING session #$new_count (mode=$TRIGGER_MODE, night=$night_id)."

# Build prompt by splicing goal (and optional persona) into the wrapper template.
session_prompt=$(mktemp "$STATE_DIR/session_prompt.XXXXXX.md")

# --- Resolve active goal/project from Loom and generate the context snapshot ---
# Moved up (was previously generated after prompt assembly): the dynamic goal
# text built below depends on this snapshot existing first. Single source of
# truth for active-goal resolution (priority DESC, id ASC among
# scheduled/in_progress) — was previously a local duplicated SQL query here,
# and a second, broken copy in interactive.sh (`status='active'`, a value
# that can never be set).
LOOM_CONTEXT_FILE="$STATE_DIR/loom_context.json"
LOOM_SRC="${LOOM_SRC:-${HOME}/lain/loom}"
LOOM_DB="${LOOM_DB:-${HOME}/.local/share/loom/loom.db}"
export LOOM_DB
LOOM_SESSION_ROW_ID=""
ACTIVE_GOAL_ID=""
if [ -d "$LOOM_SRC" ] && [ -f "$LOOM_SRC/.venv/bin/python" ]; then
  loom_py() { PYTHONPATH="$LOOM_SRC" "$LOOM_SRC/.venv/bin/python" -m loom.cli --db "$LOOM_DB" "$@"; }

  ACTIVE_GOAL_ID=$(loom_py goal resolve-active 2>/dev/null || echo "")
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

# --- Build the dynamic goal text (replaces the old static goal.txt) ---
# Sourced from the context snapshot just written: active goal/project name +
# description. Empty/no active goal is not an error — the default-goal
# fallback (resolve_session_type.py Priority 4) and philosophy framing carry
# that case, same as an empty goal.txt used to fall through before.
GOAL_FILE=$(mktemp "$STATE_DIR/goal_text.XXXXXX.md")
DYNAMIC_GOAL_FILE="$GOAL_FILE"
python3 -c "
import json
try:
    d = json.load(open('$LOOM_CONTEXT_FILE'))
except Exception:
    d = {}
g = d.get('active_goal')
p = d.get('active_project')
lines = []
if g:
    lines.append(f\"Active goal: {g.get('name')}\")
    if g.get('description'):
        lines.append(g['description'])
else:
    lines.append('No active goal currently set.')
if p:
    lines.append(f\"Active project: {p.get('name')}\")
    if p.get('description'):
        lines.append(p['description'])
open('$GOAL_FILE', 'w').write('\n\n'.join(lines) + '\n')
" 2>/dev/null || echo "No active goal currently set." > "$GOAL_FILE"
log_line "Dynamic goal text built from Loom (active_goal_id=${ACTIVE_GOAL_ID:-none})."

if [ -n "$PERSONA_FILE" ] && [ -f "$PERSONA_FILE" ]; then
  persona_arg="$PERSONA_FILE"
else
  persona_arg=""
fi

# --- Session type resolution ---
# Priority: SESSION_TYPE env var → Loom queue state → default (maintenance)
# Resolves type, loads type config YAML, assembles context files + type prompt.
SESSION_TYPE_RESULT=$(mktemp "$STATE_DIR/session_type_result.XXXXXX.json")
if [ -f "$PROJECT_DIR/scripts/executional/resolve_session_type.py" ]; then
  _type_stderr=$(python3 "$PROJECT_DIR/scripts/executional/resolve_session_type.py" \
    --project-dir "$PROJECT_DIR" \
    --trigger-mode "$TRIGGER_MODE" \
    --output "$SESSION_TYPE_RESULT" 2>&1) || true
  log_line "Session type resolution: ${_type_stderr:-no output}"

  # Parse resolved type and resolution source.
  CURRENT_SESSION_TYPE=$(python3 -c \
    "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('session_type','execution'))" \
    "$SESSION_TYPE_RESULT" 2>/dev/null || echo "execution")
  CURRENT_SESSION_TYPE_SOURCE=$(python3 -c \
    "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('resolution_source','default'))" \
    "$SESSION_TYPE_RESULT" 2>/dev/null || echo "default")

  # Export maintenance scope if present (scope_id/scope_slug from resolve_session_type.py result).
  MAINTENANCE_SCOPE=$(python3 -c \
    "import json,sys; d=json.load(open(sys.argv[1])); s=d.get('scope_id'); print(s if s else '')" \
    "$SESSION_TYPE_RESULT" 2>/dev/null || echo "")
  MAINTENANCE_SCOPE_SLUG=$(python3 -c \
    "import json,sys; d=json.load(open(sys.argv[1])); s=d.get('scope_slug'); print(s if s else '')" \
    "$SESSION_TYPE_RESULT" 2>/dev/null || echo "")
  export MAINTENANCE_SCOPE

  # Qualify the logged/reported type by scope (e.g. maintenance_memory,
  # philosophy_wonder) so session logs, session history, and analytics
  # distinguish which of the 3 rotating scopes/tiers ran -- previously every
  # session of these types was logged identically regardless of scope.
  # Config-file lookup above already used the base type identity; this only
  # affects what gets reported downstream from here. Variable names stay
  # MAINTENANCE_SCOPE* (not renamed to something generic) since
  # analytics_write.py already documents that name in a comment -- this is
  # just the condition widening to cover philosophy too, not a rename.
  if { [ "$CURRENT_SESSION_TYPE" = "maintenance" ] || [ "$CURRENT_SESSION_TYPE" = "philosophy" ]; } \
      && [ -n "$MAINTENANCE_SCOPE_SLUG" ]; then
    CURRENT_SESSION_TYPE="${CURRENT_SESSION_TYPE}_${MAINTENANCE_SCOPE_SLUG}"
  fi

  export CURRENT_SESSION_TYPE CURRENT_SESSION_TYPE_SOURCE
  echo "$CURRENT_SESSION_TYPE" > "$STATE_DIR/current_session_type.txt"
  log_line "Session type: $CURRENT_SESSION_TYPE (source: $CURRENT_SESSION_TYPE_SOURCE)"
  [ -n "$MAINTENANCE_SCOPE" ] && log_line "Maintenance scope: $MAINTENANCE_SCOPE ($MAINTENANCE_SCOPE_SLUG)"

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
    t = data.get('target_context', '').strip()
    # Substitute maintenance scope placeholders if present
    scope_id = data.get('scope_id')
    scope_name = data.get('scope_name', f'Scope {scope_id}') if scope_id else ''
    focus_hint = data.get('focus_hint', '')
    if p and scope_id:
        p = p.replace('{MAINTENANCE_SCOPE_NAME}', scope_name)
        p = p.replace('{MAINTENANCE_SCOPE_FOCUS}', focus_hint)
    if p:
        parts.append(p)
    if c:
        parts.append('## CONTEXT PRELOAD\n\n' + c)
    # Generic scope section -- not every scoped type's prompt file uses the
    # {MAINTENANCE_SCOPE_*} inline placeholders above (philosophy_prompt.md
    # deliberately doesn't -- its tiers are static sections, told apart by
    # this block instead). Skipped for maintenance to avoid saying the same
    # thing twice in one prompt, since that type's own placeholders already
    # carry it inline.
    if scope_id and data.get('session_type') != 'maintenance':
        parts.append(f'## SCOPE\n\n{scope_name} (tier/scope {scope_id})\n\n{focus_hint}')
    if t:
        # The specific goal/project record this session's dispatch rule matched
        # (evaluation/planning/audit at goal or project level) — system-wide,
        # not necessarily the same record as state/loom_context.json's active
        # goal/project, since rules 1-3 aren't scoped to whichever goal is active.
        parts.append('## TARGET\n\n' + t)
    parts.append(goal)
    open(sys.argv[3], 'w').write('\n\n---\n\n'.join(parts) + '\n')
except Exception:
    import shutil
    shutil.copy(sys.argv[2], sys.argv[3])
" "$SESSION_TYPE_RESULT" "$GOAL_FILE" "$AUGMENTED_GOAL" 2>/dev/null \
    || cp "$GOAL_FILE" "$AUGMENTED_GOAL"

  rm -f "$SESSION_TYPE_RESULT"

  # Gate: abort if consecutive philosophy cap reached (no Claude launch needed).
  # Runs regardless of TRIGGER_MODE now — resolve_session_type.py's Priority 2.5
  # already decides staleness (Loom + inbox aware) before ever returning this type,
  # so by the time we see it here the cap is genuinely still valid for every mode.
  if [ "$CURRENT_SESSION_TYPE" = "philosophy_cap" ]; then
    _consec=$(cat "$STATE_DIR/consecutive_philosophy.count" 2>/dev/null || echo "3")
    log_line "ABORT: philosophy cap reached (consecutive_philosophy.count=$_consec). Skipping session."
    # Write cap-active flag on first hit; stays put on subsequent hits until
    # resolve_session_type.py finds it stale and clears it.
    _cap_is_new=0
    if [ ! -f "$STATE_DIR/philosophy_cap.active" ]; then
      echo "$(date +%s)" > "$STATE_DIR/philosophy_cap.active"
      _cap_is_new=1
    fi

    # T443: proactive notification when cap has been held > threshold. Moved here
    # (was previously only reachable in a nightly-only early-abort path) so
    # emergency/manual mode gets notified too instead of silently looping forever.
    if [ "$_cap_is_new" -eq 0 ]; then
      _cap_ts=$(cat "$STATE_DIR/philosophy_cap.active" 2>/dev/null | tr -d '[:space:]' || echo "0")
      _now=$(date +%s)
      _age=$(( _now - _cap_ts ))
      _notify_threshold=${PHILOSOPHY_CAP_NOTIFY_THRESHOLD:-7200}
      _notify_rate=${PHILOSOPHY_CAP_NOTIFY_RATE:-10800}
      _last_notify=$(cat "$STATE_DIR/philosophy_cap_notified_at.txt" 2>/dev/null | tr -d '[:space:]' || echo "0")
      _since_notify=$(( _now - _last_notify ))
      if [ "$_age" -gt "$_notify_threshold" ] && [ "$_since_notify" -gt "$_notify_rate" ]; then
        _age_h=$(( _age / 3600 ))
        _cap_time=$(date -d "@${_cap_ts}" '+%H:%M %Z %Y-%m-%d' 2>/dev/null || echo "ts=${_cap_ts}")
        printf '@Lain philosophy cap: held %dh (since %s, mode=%s). No sessions will run until new work appears or the next nightly boundary resets. To unblock manually: rm state/philosophy_cap.active' \
          "$_age_h" "$_cap_time" "$TRIGGER_MODE" \
          | bash "$PROJECT_DIR/tools/conversational/telegram_send.sh" 2>/dev/null || true
        echo "$_now" > "$STATE_DIR/philosophy_cap_notified_at.txt"
        log_line "T443: philosophy_cap_alert sent (${_age}s held, mode=$TRIGGER_MODE)"
      fi
    fi
    unset _cap_is_new

    write_trigger_result "aborted" "philosophy cap reached (consecutive_philosophy_count=$_consec)"
    rm -f "$AUGMENTED_GOAL" "$DYNAMIC_GOAL_FILE"
    exit 0
  fi

  GOAL_FILE="$AUGMENTED_GOAL"
  log_line "Augmented goal built for session type: $CURRENT_SESSION_TYPE"
else
  log_line "WARNING: resolve_session_type.py not found — skipping type injection."
  CURRENT_SESSION_TYPE="execution"
  CURRENT_SESSION_TYPE_SOURCE="default"
  export CURRENT_SESSION_TYPE CURRENT_SESSION_TYPE_SOURCE
  echo "$CURRENT_SESSION_TYPE" > "$STATE_DIR/current_session_type.txt"
fi

write_trigger_result "launched" "" "$CURRENT_SESSION_TYPE" "$$"

# --- Inject codebase brief if orchestrator has set an active project path ---
_ACTIVE_PROJECT_PATH_FILE="$STATE_DIR/active_project_path.txt"
if [ -f "$_ACTIVE_PROJECT_PATH_FILE" ]; then
  _active_project_path=$(cat "$_ACTIVE_PROJECT_PATH_FILE")
  _project_name=$(basename "$_active_project_path")
  _brief_file="$PROJECT_DIR/memory/codebase_briefs/${_project_name}.md"
  if [ -f "$_brief_file" ] && grep -q "## Narrative" "$_brief_file" 2>/dev/null; then
    { echo ""; echo "---"; echo ""; echo "## Codebase Brief: $_project_name"; echo ""; cat "$_brief_file"; } >> "$GOAL_FILE"
    log_line "Injected codebase brief for $_project_name into goal context."
  fi
  unset _active_project_path _project_name _brief_file
fi
unset _ACTIVE_PROJECT_PATH_FILE

python3 "$PROJECT_DIR/scripts/executional/splice_prompt.py" \
  "$CORE_PROMPT_DIR" "$GOAL_FILE" "$session_prompt" "$persona_arg"

# Record count BEFORE launching — counts even if agent crashes or hangs.
echo "$new_count" > "$COUNT_FILE"

# Update mode-specific counters (manual / emergency).
# COUNT_FILE always tracks sessions_tonight.count; analytics_write.py::derive_session_key()
# reads mode-specific files, so they must be kept in sync.
case "$TRIGGER_MODE" in
  manual)
    _mc="$STATE_DIR/sessions_manual.count"
    _mv=$(( $(cat "$_mc" 2>/dev/null || echo "0") + 1 ))
    echo "$_mv" > "$_mc"
    unset _mc _mv
    ;;
  emergency)
    _mc="$STATE_DIR/sessions_emergency.count"
    _mv=$(( $(cat "$_mc" 2>/dev/null || echo "0") + 1 ))
    echo "$_mv" > "$_mc"
    unset _mc _mv
    ;;
esac

# Write the canonical session key (night_id + count) so analytics_write.py
# can look it up directly instead of re-deriving it with potentially stale files.
echo "${night_id}_${new_count}" > "$STATE_DIR/current_session_key.txt"

# Write trigger mode so Lain can read it during orientation.
echo "$TRIGGER_MODE" > "$STATE_DIR/trigger_mode.txt"

session_start_epoch=$(date +%s)
echo "$session_start_epoch" > "$STATE_DIR/session_start_epoch"

# --- Nexus heartbeat: push last_seen at session start (non-fatal, T402) ---
_nexus_token_file="$STATE_DIR/nexus_${AGENT_NAME}_token.txt"
if [ -f "$_nexus_token_file" ]; then
  _hb_token=$(cat "$_nexus_token_file")
  curl -s --max-time 5 -X POST "$NEXUS_URL/agents/${AGENT_NAME}/heartbeat" \
    -H "Authorization: Bearer $_hb_token" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"session_start\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    > /dev/null 2>&1 || true
  log_line "Nexus heartbeat sent (non-fatal if endpoint not yet live)."
fi

# --- Generate behavioral context snapshot from Honcho + Argus (non-fatal) ---
BEHAVIORAL_TOOL="$PROJECT_DIR/tools/executional/behavioral_adapter.py"
BEHAVIORAL_CONTEXT="$STATE_DIR/behavioral_context.txt"
if [ -f "$BEHAVIORAL_TOOL" ]; then
  /usr/bin/python3 "$BEHAVIORAL_TOOL" \
    --peer-id "$OWNER_NAME" \
    --output "$BEHAVIORAL_CONTEXT" > /dev/null 2>&1 \
    && log_line "Behavioral context generated: $BEHAVIORAL_CONTEXT" \
    || log_line "WARNING: behavioral_adapter.py failed (non-fatal)."
fi

# --- Poll argus for fresh owner context snapshot (non-fatal) ---
ARGUS_POLLER="$PROJECT_DIR/tools/executional/argus_context_poller.py"
ARGUS_CONTEXT="$STATE_DIR/argus_context.json"
if [ -f "$ARGUS_POLLER" ] && grep -q "^ARGUS_URL=" "$STATE_DIR/agent_config.env" 2>/dev/null; then
  /usr/bin/python3 "$ARGUS_POLLER" > /dev/null 2>&1 || true
  ARGUS_STATE=$(/usr/bin/python3 -c \
    "import json; d=json.load(open('$ARGUS_CONTEXT')); print(d.get('state','unknown'))" \
    2>/dev/null || echo "unknown")
  export ARGUS_STATE
  log_line "argus_state: $ARGUS_STATE"
fi

# --- Prune processed inbox entries older than 7 days (non-fatal) ---
INBOX_TOOL="$PROJECT_DIR/tools/inbox.py"
if [ -f "$INBOX_TOOL" ]; then
  _prune_result=$(/usr/bin/python3 "$INBOX_TOOL" prune 2>/dev/null || echo "")
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

# set +e around the launch: a crashed/killed/non-zero-exiting session must NOT
# abort wake.sh here under `set -e`, or all the post-session bookkeeping below
# (Loom session end, relationship update, consecutive-philosophy counter,
# analytics fallback) gets silently skipped for exactly the sessions — crashes —
# where you'd most want a record.
set +e
claude --dangerously-skip-permissions --model "$SESSION_MODEL" < "$session_prompt" \
  >> "$LOG_DIR/session_${night_id}_${new_count}.out" \
  2>> "$LOG_DIR/session_${night_id}_${new_count}.err"
exit_code=$?
set -e
session_end_epoch=$(date +%s)
duration_min=$(( (session_end_epoch - session_start_epoch) / 60 ))

log_line "Session #$new_count ended. exit_code=$exit_code duration_min=$duration_min"
rm -f "$session_prompt"
[ -n "${AUGMENTED_GOAL:-}" ] && rm -f "$AUGMENTED_GOAL"
rm -f "$DYNAMIC_GOAL_FILE"

# --- Update consecutive philosophy counter ---
# Any philosophy-tier session increments (bare "philosophy" or scope-qualified
# "philosophy_wonder"/"philosophy_creative"/"philosophy_blocker" -- the glob
# below also matches "philosophy_cap", but that's harmless: philosophy_cap
# always exits before Claude ever launches, well before this block runs.
# Any other type resets to 0.
_CONSEC_FILE="$STATE_DIR/consecutive_philosophy.count"
case "${CURRENT_SESSION_TYPE:-}" in
  philosophy|philosophy_*)
    _prev=$(cat "$_CONSEC_FILE" 2>/dev/null || echo "0")
    _next=$(( _prev + 1 ))
    echo "$_next" > "$_CONSEC_FILE"
    log_line "consecutive_philosophy.count: $_prev -> $_next"
    ;;
  *)
    echo "0" > "$_CONSEC_FILE"
    log_line "consecutive_philosophy.count reset to 0 (session_type=${CURRENT_SESSION_TYPE:-unknown})"
    ;;
esac
unset _CONSEC_FILE _prev _next

# --- Record session end in Loom (non-fatal) ---
if [ -n "$LOOM_SESSION_ROW_ID" ] && [ -d "$LOOM_SRC" ] && [ -f "$LOOM_SRC/.venv/bin/python" ]; then
  EXIT_REASON="exit_code=$exit_code"
  PYTHONPATH="$LOOM_SRC" "$LOOM_SRC/.venv/bin/python" -m loom.cli --db "$LOOM_DB" \
    session end --id "$LOOM_SESSION_ROW_ID" \
    --exit-reason "$EXIT_REASON" > /dev/null 2>&1 \
    && log_line "LOOM session $LOOM_SESSION_ROW_ID closed." \
    || log_line "WARNING: loom session end failed (non-fatal)."
fi

# --- Write analytics record (fallback — agent writes it during shutdown; this catches gate aborts) ---
# --skip-if-exists: if agent already wrote it during its own shutdown, preserve the richer record.
ANALYTICS_TOOL="$PROJECT_DIR/tools/executional/analytics_write.py"
if [ -f "$ANALYTICS_TOOL" ]; then
  CONTEXT_PCT_AT_EXIT=$(bash "$PROJECT_DIR/tools/executional/check_session.sh" --context 2>/dev/null \
    | grep "context_pct_estimate" | grep -oP '\d+(?=%)' | head -1 || echo "0")
  /usr/bin/python3 "$ANALYTICS_TOOL" \
    --session-type "${CURRENT_SESSION_TYPE:-execution}" \
    --exit-reason "gate_abort" \
    --summary "wake.sh fallback — agent did not write analytics" \
    --tasks-completed 0 \
    --context-pct "${CONTEXT_PCT_AT_EXIT:-0}" \
    --no-transcript \
    --skip-if-exists \
    > /dev/null 2>&1 \
    && log_line "Analytics fallback record written (or skipped — agent already wrote it)." \
    || log_line "WARNING: analytics_write.py fallback failed (non-fatal)."
fi
