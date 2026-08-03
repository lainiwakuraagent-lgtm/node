#!/usr/bin/env bash
# check_conv_active.sh
# Prints "active" if a conversational session currently holds the lock,
# "inactive" otherwise (includes the idle_close slow-shutdown case, which
# is treated as inactive since Telegram is allowed again at that point).
# Exit code is always 0 -- this is a status check, not a gate.

set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONV_LOCK="$PROJECT_DIR/state/conversation.lock"
EXIT_REASON="$PROJECT_DIR/state/conversation/exit_reason.txt"

if [ -f "$CONV_LOCK" ] && kill -0 "$(cat "$CONV_LOCK" 2>/dev/null)" 2>/dev/null; then
  if [ -f "$EXIT_REASON" ] && grep -q "idle_close" "$EXIT_REASON" 2>/dev/null; then
    echo "inactive"
  else
    echo "active"
  fi
else
  echo "inactive"
fi
