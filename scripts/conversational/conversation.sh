#!/usr/bin/env bash
# conversation.sh — Launch @Lain in conversational mode.
#
# Designed to run continuously and restart automatically when a session exits.
# No gates, no session count limits, no time window constraints.
#
# IMPORTANT: Deletes the Telegram webhook before starting (getUpdates requires it).
# Restores the webhook automatically when this script exits, via trap.
#
# Usage: bash scripts/conversation.sh
#   or:  SESSION_TYPE=conversation bash scripts/conversation.sh

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PROJECT_DIR/state"
LOG_DIR="$PROJECT_DIR/logs"
ENV_FILE="$HOME/.claude/.env"
CONV_DIR="$STATE_DIR/conversation"
PROMPT_FILE="$PROJECT_DIR/prompts/conversation.md"
SOUL_FILE="$PROJECT_DIR/memory/work/soul.md"
LOCK_FILE="$STATE_DIR/conversation.lock"
WATCHER_PID_FILE="$CONV_DIR/watcher.pid"

# --- Load agent config (parameterize for new node instances) ---
AGENT_CONFIG="$STATE_DIR/agent_config.env"
if [ -f "$AGENT_CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$AGENT_CONFIG"
fi
AGENT_NAME="${AGENT_NAME:-lain}"
OWNER_NAME="${OWNER_NAME:-andrii}"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$CONV_DIR"

timestamp() { date '+%Y-%m-%d %H:%M:%S %Z'; }
log_line() { echo "[$(timestamp)] $*" | tee -a "$LOG_DIR/wake.log"; }

# --- Load Telegram credentials ---
TOKEN=$(grep 'TELEGRAM_BOT_TOKEN' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
WEBHOOK_URL_FILE="$CONV_DIR/saved_webhook_url.txt"

# --- Webhook management ---
delete_webhook() {
    if [ -z "$TOKEN" ]; then return; fi
    local resp
    resp=$(curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo")
    local current_url
    current_url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('url',''))" 2>/dev/null || true)
    if [ -n "$current_url" ]; then
        echo "$current_url" > "$WEBHOOK_URL_FILE"
        curl -s "https://api.telegram.org/bot${TOKEN}/deleteWebhook" > /dev/null
        log_line "CONV: webhook deleted (was: ${current_url}). Saved for restore."
    else
        log_line "CONV: no webhook registered — polling mode already active."
    fi
}

restore_webhook() {
    if [ -z "$TOKEN" ]; then return; fi
    if [ -f "$WEBHOOK_URL_FILE" ]; then
        local url
        url=$(cat "$WEBHOOK_URL_FILE")
        if [ -n "$url" ]; then
            curl -s "https://api.telegram.org/bot${TOKEN}/setWebhook?url=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote('$url',safe=':/'))")" > /dev/null
            log_line "CONV: webhook restored to $url"
        fi
        rm -f "$WEBHOOK_URL_FILE"
    fi
}

# On any exit: restore webhook and remove lock
cleanup() {
    log_line "CONV: exiting — restoring webhook and releasing lock."
    kill_stale_watcher 2>/dev/null || true
    restore_webhook
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# --- Lock: prevent concurrent conversation sessions ---
if [ -f "$LOCK_FILE" ]; then
    locked_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$locked_pid" ] && kill -0 "$locked_pid" 2>/dev/null; then
        log_line "CONV: already running (PID $locked_pid). Exiting."
        exit 0
    else
        log_line "CONV: stale lock (PID ${locked_pid:-?} dead). Removing."
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

# --- Delete webhook (enables getUpdates) ---
delete_webhook

export SESSION_TYPE="conversation"
export CURRENT_SESSION_TYPE="conversation"
export TRIGGER_MODE="manual"
export PROJECT_DIR

log_line "CONV: Starting conversation session loop (PID $$)."

# Model selection
MODEL_FILE="$STATE_DIR/session_model.txt"
if [ -f "$MODEL_FILE" ]; then
    MODEL=$(cat "$MODEL_FILE")
else
    MODEL="claude-sonnet-4-6"
fi

kill_stale_watcher() {
    if [ -f "$WATCHER_PID_FILE" ]; then
        local pid_content watcher_pid wrapper_pid_stored
        pid_content=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
        # Support "watcher_pid:wrapper_pid" format (new) and plain "pid" (old)
        watcher_pid="${pid_content%%:*}"
        wrapper_pid_stored="${pid_content##*:}"
        [ "$wrapper_pid_stored" = "$watcher_pid" ] && wrapper_pid_stored=""

        if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
            local wrapper_pid_live
            wrapper_pid_live=$(ps -o ppid= -p "$watcher_pid" 2>/dev/null | tr -d '[:space:]' || echo "")
            log_line "CONV: killing stale watcher (PID $watcher_pid) before restart."
            kill "$watcher_pid" 2>/dev/null || true
            if [ -n "$wrapper_pid_live" ] && [ "$wrapper_pid_live" != "1" ] && kill -0 "$wrapper_pid_live" 2>/dev/null; then
                log_line "CONV: killing watcher bash wrapper via ps (PID $wrapper_pid_live)."
                kill "$wrapper_pid_live" 2>/dev/null || true
            fi
            sleep 2
        fi

        if [ -n "$wrapper_pid_stored" ] && [ "$wrapper_pid_stored" != "1" ] && kill -0 "$wrapper_pid_stored" 2>/dev/null; then
            log_line "CONV: killing stale watcher bash wrapper (PID $wrapper_pid_stored)."
            kill "$wrapper_pid_stored" 2>/dev/null || true
        fi

        rm -f "$WATCHER_PID_FILE"
    fi
    # Kill remaining telegram_watcher.py orphans — python3 watchers AND bash wrappers
    # (run_in_background survivors from prior sessions). Skip claude processes whose
    # -p prompt text may contain "telegram_watcher.py" (comm is "claude", not bash/python).
    local _killed_stray=0
    while IFS= read -r stray_pid; do
        stray_comm=$(cat "/proc/$stray_pid/comm" 2>/dev/null || echo "")
        if [[ "$stray_comm" == python* ]]; then
            log_line "CONV: pkill fallback — killing stray watcher python PID $stray_pid."
            kill "$stray_pid" 2>/dev/null || true
            _killed_stray=1
        elif [[ "$stray_comm" == "bash" ]]; then
            stray_cmd=$(tr '\0' ' ' < "/proc/$stray_pid/cmdline" 2>/dev/null || echo "")
            if [[ "$stray_cmd" == *telegram_watcher* ]]; then
                log_line "CONV: pkill fallback — killing stray watcher bash wrapper PID $stray_pid."
                kill "$stray_pid" 2>/dev/null || true
                _killed_stray=1
            fi
        fi
    done < <(pgrep -f "telegram_watcher.py" 2>/dev/null || true)
    [ "$_killed_stray" = "1" ] && sleep 1 || true
}

# One-time startup sweep: kill any telegram_watcher orphans from prior conversation.sh runs.
# Handles the case where a bash wrapper (spawned via run_in_background by a prior session)
# outlived its session's exit. The per-loop kill_stale_watcher can miss these if the bash
# wrapper hasn't yet spawned its python3 child by the time pgrep runs. This sweep fires
# before the main loop, giving us the cleanest possible starting state.
log_line "CONV: startup — sweeping for pre-session watcher orphans."
_sw_killed=0
while IFS= read -r _sw_pid; do
    _sw_comm=$(cat "/proc/$_sw_pid/comm" 2>/dev/null || echo "")
    if [[ "$_sw_comm" == python* ]]; then
        log_line "CONV: startup sweep — killing stale watcher python PID $_sw_pid."
        kill "$_sw_pid" 2>/dev/null || true
        _sw_killed=1
    elif [[ "$_sw_comm" == "bash" ]]; then
        _sw_cmd=$(tr '\0' ' ' < "/proc/$_sw_pid/cmdline" 2>/dev/null || echo "")
        if [[ "$_sw_cmd" == *telegram_watcher* ]]; then
            log_line "CONV: startup sweep — killing stale watcher bash wrapper PID $_sw_pid."
            kill "$_sw_pid" 2>/dev/null || true
            _sw_killed=1
        fi
    fi
done < <(pgrep -f "telegram_watcher.py" 2>/dev/null || true)
[ "$_sw_killed" = "1" ] && sleep 1 || true

# One-time startup sweep: kill orphaned Claude sessions from prior conversation.sh runs.
# An orphaned Claude process has "conv_prompt" in its cmdline (launched by conversation.sh)
# but PPID=1 (reparented to init — its parent conversation.sh already died). If left alive
# it holds the Telegram bot token and causes HTTP 409 conflicts for the new session.
log_line "CONV: startup — sweeping for orphaned Claude sessions."
_oc_killed=0
while IFS= read -r _oc_pid; do
    _oc_ppid=$(ps -o ppid= -p "$_oc_pid" 2>/dev/null | tr -d '[:space:]' || echo "")
    if [[ "$_oc_ppid" == "1" ]]; then
        log_line "CONV: startup sweep — killing orphaned Claude PID $_oc_pid (conv_prompt, PPID=1)."
        kill "$_oc_pid" 2>/dev/null || true
        _oc_killed=1
    fi
done < <(pgrep -f "conv_prompt" 2>/dev/null || true)
[ "$_oc_killed" = "1" ] && sleep 2 || true

# --- Auto-restart loop ---
RESTART_COUNT=0
LAST_EXIT_REASON=""
while true; do
    RESTART_COUNT=$((RESTART_COUNT + 1))
    kill_stale_watcher
    # Clear any stale idle-close signal from a previous session.
    # Each new session starts with a clean slate — conv_idle_check.py will
    # write a fresh signal if the session actually goes idle.
    rm -f "$CONV_DIR/reset_signal.txt"
    log_line "CONV: Session start #$RESTART_COUNT"

    # This iteration only runs because the previous one ended in reset/new —
    # confirm to Andrii that the restart actually happened. Hardcoded, not
    # agent-generated, so it doesn't depend on the new session doing anything
    # right to be trustworthy.
    if [ "$LAST_EXIT_REASON" = "reset" ] || [ "$LAST_EXIT_REASON" = "new" ]; then
        printf '%s' "⚙ session restarted — back online. (´_\`)" \
            | bash "$PROJECT_DIR/tools/conversational/telegram_send.sh" >/dev/null 2>&1 || true
    fi

    SESSION_OUT="$LOG_DIR/conversation_$(date +%Y-%m-%d)_${RESTART_COUNT}.out"
    SESSION_ERR="$LOG_DIR/conversation_$(date +%Y-%m-%d)_${RESTART_COUNT}.err"

    # Refresh behavioral context from Honcho + Argus (non-fatal).
    BEHAVIORAL_TOOL="$PROJECT_DIR/tools/executional/behavioral_adapter.py"
    if [ -f "$BEHAVIORAL_TOOL" ]; then
        /usr/bin/python3 "$BEHAVIORAL_TOOL" \
            --peer-id "$OWNER_NAME" \
            --output "$STATE_DIR/behavioral_context.txt" > /dev/null 2>&1 \
            && log_line "CONV: behavioral context refreshed." \
            || log_line "CONV: WARNING: behavioral_adapter.py failed (non-fatal)."
    fi

    # Build prompt: conversation.md + soul.md (identity/persona).
    # conversation.md uses ${AGENT_NAME}/${OWNER_NAME} tokens for identity paths
    # (same convention resolve_session_type.py substitutes for other session
    # types) -- substitute them here since this path never goes through that
    # resolver.
    SESSION_PROMPT=$(mktemp "$STATE_DIR/conv_prompt.XXXXXX.md")
    {
        sed -e "s/\${AGENT_NAME}/${AGENT_NAME}/g" -e "s/\${OWNER_NAME}/${OWNER_NAME}/g" "$PROMPT_FILE"
        if [ -f "$SOUL_FILE" ]; then
            echo ""
            echo "---"
            echo ""
            cat "$SOUL_FILE"
        fi
    } > "$SESSION_PROMPT"

    # Launch Claude Code in conversation mode.
    # set +e around the launch: this is a restart loop, so a crashed/nonzero
    # exit must not abort the whole script under `set -e`. The old `|| true`
    # on this command discarded the real exit code entirely, and capturing
    # $? after the `rm -f` that followed it made EXIT_CODE always read 0
    # regardless of what actually happened -- every logged exit code below
    # was meaningless.
    set +e
    claude \
        --model "$MODEL" \
        --dangerously-skip-permissions \
        -p "$(cat "$SESSION_PROMPT")" \
        > "$SESSION_OUT" 2> "$SESSION_ERR" &
    CLAUDE_PID=$!
    echo "$CLAUDE_PID" > "$CONV_DIR/claude.pid"
    wait "$CLAUDE_PID"
    EXIT_CODE=$?
    set -e

    rm -f "$CONV_DIR/claude.pid"
    rm -f "$SESSION_PROMPT"

    # Read exit reason (written by agent before exiting)
    EXIT_REASON_FILE="$CONV_DIR/exit_reason.txt"
    EXIT_REASON="unknown"
    if [ -f "$EXIT_REASON_FILE" ]; then
        EXIT_REASON=$(cat "$EXIT_REASON_FILE")
        rm -f "$EXIT_REASON_FILE"
    fi

    log_line "CONV: Session #$RESTART_COUNT exited (code=$EXIT_CODE, reason=$EXIT_REASON)."

    # Write conversational analytics record for this session.
    /usr/bin/python3 "$PROJECT_DIR/tools/conversational/conversational_analytics_write.py" \
        --channel telegram \
        --exit-reason "$EXIT_REASON" \
        2>/dev/null || true

    # Push this session's new thread.json entries into Honcho (no-ops if
    # HONCHO_URL isn't configured; incremental via honcho_last_synced.json).
    /usr/bin/python3 "$PROJECT_DIR/tools/conversational/honcho_client.py" \
        --sync-thread "$OWNER_NAME" \
        --session-id "$(date +%Y-%m-%d)_conv_${RESTART_COUNT}" \
        --thread-file "$CONV_DIR/thread.json" \
        --marker-file "$CONV_DIR/honcho_last_synced.json" \
        2>/dev/null || true

    if [ "$EXIT_REASON" = "idle_close" ]; then
        log_line "CONV: Idle-close — not restarting. Service will stop."
        break
    fi

    # Only restart on explicit user commands (/reset, agent-cooperative, or
    # /new, a hard kill from command_dispatcher.py). Everything else
    # (crashes, unrecognized reasons) stops the service — owner restarts
    # manually, or conv_watchdog.py's crash detection brings it back.
    if [ "$EXIT_REASON" = "reset" ] || [ "$EXIT_REASON" = "new" ]; then
        log_line "CONV: Explicit $EXIT_REASON — restarting in 3s."
        LAST_EXIT_REASON="$EXIT_REASON"
        sleep 3
    else
        log_line "CONV: Exit reason '$EXIT_REASON' — not restarting. Service will stop."
        break
    fi
done
