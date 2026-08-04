#!/usr/bin/env bash
# telegram_chat_action.sh — show/hide Telegram's "typing…" / "recording voice…"
# indicator while something is actually happening, so the owner can tell
# "working" from "stuck" without waiting on a reply that may take a while.
#
# Telegram's sendChatAction only shows the indicator for ~5 seconds per call,
# so a real wait needs it re-issued periodically, not a single fire-and-forget
# request. `start` backgrounds a detached loop that does that; `stop` kills it.
#
# Usage:
#   bash telegram_chat_action.sh start [typing|record_voice|upload_voice|upload_document]
#   bash telegram_chat_action.sh stop
#
# Never blocks or fails loudly -- this is a cosmetic feature. Any resolution
# failure (missing token/chat_id, missing setsid) is a silent no-op.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
AGENT_ENV="$PROJECT_DIR/identity/agent.env"
FALLBACK_ENV="$HOME/.claude/.env"
PID_FILE="$PROJECT_DIR/state/conversation/typing.pid"
SAFETY_CAP_SECONDS=180   # ~3 min; if a real response takes longer, the
                         # indicator drops off rather than lying forever.
REFRESH_SECONDS=4

# Token/chat_id resolution -- same priority as telegram_send.sh.
resolve_token() {
    local t=""
    if [[ -n "${TELEGRAM_BOT_TOKEN_FILE:-}" && -f "${TELEGRAM_BOT_TOKEN_FILE}" ]]; then
        t=$(cat "$TELEGRAM_BOT_TOKEN_FILE" | tr -d '[:space:]')
    fi
    if [[ -z "$t" && -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        t="$TELEGRAM_BOT_TOKEN"
    fi
    if [[ -z "$t" && -f "$AGENT_ENV" ]]; then
        t=$(grep '^TELEGRAM_BOT_TOKEN=' "$AGENT_ENV" 2>/dev/null | cut -d= -f2)
    fi
    if [[ -z "$t" ]]; then
        t=$(grep 'TELEGRAM_BOT_TOKEN' "$FALLBACK_ENV" 2>/dev/null | cut -d= -f2)
    fi
    echo "$t"
}

resolve_chat_id() {
    local c="${TELEGRAM_CHAT_ID:-}"
    if [[ -z "$c" && -f "$AGENT_ENV" ]]; then
        c=$(grep '^TELEGRAM_CHAT_ID=' "$AGENT_ENV" 2>/dev/null | cut -d= -f2)
        if [[ -z "$c" ]]; then
            c=$(grep '^TELEGRAM_ALLOWED_USERS=' "$AGENT_ENV" 2>/dev/null | cut -d= -f2)
        fi
    fi
    if [[ -z "$c" ]]; then
        c=$(grep 'TELEGRAM_ALLOWED_USERS' "$FALLBACK_ENV" 2>/dev/null | cut -d= -f2)
    fi
    echo "$c"
}

stop_indicator() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    return 0
}

# Internal: the actual refresh loop. Only ever invoked via `setsid "$0" _loop ...`
# from start_indicator, never directly -- re-resolves token/chat_id itself
# since it's a fresh process, not a fork sharing start_indicator's locals.
#
# Writes its OWN pid ($$) to PID_FILE as its first action, rather than
# start_indicator capturing `$!` on the backgrounded `setsid` call -- verified
# empirically that setsid forks internally on this system, so `$!` there is
# the PID of a process that exits almost immediately, not the long-running
# loop. `$$` from inside the loop itself is correct regardless of how it was
# forked, since a process always knows its own real PID.
_loop() {
    local action="${1:-typing}"
    local token chat_id elapsed=0
    token=$(resolve_token)
    chat_id=$(resolve_chat_id)
    [[ -z "$token" || -z "$chat_id" ]] && return 0

    echo $$ > "$PID_FILE"

    while [[ "$elapsed" -lt "$SAFETY_CAP_SECONDS" ]]; do
        curl -s -X POST "https://api.telegram.org/bot${token}/sendChatAction" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "action=${action}" \
            > /dev/null 2>&1
        sleep "$REFRESH_SECONDS"
        elapsed=$((elapsed + REFRESH_SECONDS))
    done
    rm -f "$PID_FILE"
}

start_indicator() {
    local action="${1:-typing}"
    local token chat_id
    token=$(resolve_token)
    chat_id=$(resolve_chat_id)
    [[ -z "$token" || -z "$chat_id" ]] && return 0
    command -v setsid > /dev/null 2>&1 || return 0

    stop_indicator  # replace any stale/previous loop first
    mkdir -p "$(dirname "$PID_FILE")"
    setsid "$0" _loop "$action" < /dev/null > /dev/null 2>&1 &
    return 0
}

case "${1:-}" in
    start) start_indicator "${2:-typing}" ;;
    stop) stop_indicator ;;
    _loop) _loop "${2:-typing}" ;;
    *)
        echo "Usage: $0 start [typing|record_voice|upload_voice|upload_document] | stop" >&2
        exit 2
        ;;
esac
