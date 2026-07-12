#!/usr/bin/env bash
# telegram_send.sh — Send a message to the owner via Telegram bot
#
# Usage: telegram_send.sh "message text"
#   or:  telegram_send.sh  (reads message from stdin)
#
# Prints the message_id of the sent message on success.
# Token source: ~/.claude/.env (TELEGRAM_BOT_TOKEN)
# Chat ID source: ~/.claude/.env (TELEGRAM_ALLOWED_USERS)

set -euo pipefail

# Allow CURL_CMD override for testing (e.g. CURL_CMD=/path/to/stub)
CURL="${CURL_CMD:-curl}"

ENV_FILE="$HOME/.claude/.env"
TOKEN=$(grep 'TELEGRAM_BOT_TOKEN' "$ENV_FILE" | cut -d= -f2)
CHAT_ID=$(grep 'TELEGRAM_ALLOWED_USERS' "$ENV_FILE" | cut -d= -f2)

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN not found in $ENV_FILE" >&2
    exit 2
fi

if [[ -z "$CHAT_ID" ]]; then
    echo "ERROR: TELEGRAM_ALLOWED_USERS not found in $ENV_FILE" >&2
    exit 2
fi

# Get message from arg or stdin
if [[ $# -ge 1 ]]; then
    MESSAGE="$*"
else
    MESSAGE=$(cat)
fi

if [[ -z "$MESSAGE" ]]; then
    echo "ERROR: No message provided" >&2
    exit 2
fi

RESPONSE=$($CURL -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}")

OK=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ok','false'))")
if [[ "$OK" != "True" ]]; then
    echo "ERROR: sendMessage failed: $RESPONSE" >&2
    exit 2
fi

MSG_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['message_id'])")
echo "sent message_id=${MSG_ID}"

# ── TTS (optional) ─────────────────────────────────────────────────────────────
VOICE_MODE_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/state/voice_mode.txt"
FISH_TTS="$(dirname "${BASH_SOURCE[0]}")/fish_tts_send.sh"
if [[ "${SKIP_TTS:-0}" != "1" && -f "$VOICE_MODE_FILE" && "$(cat "$VOICE_MODE_FILE" 2>/dev/null | tr -d '[:space:]')" == "on" && -f "$FISH_TTS" ]]; then
    printf '%s' "$MESSAGE" | bash "$FISH_TTS" 2>/dev/null || true
fi
