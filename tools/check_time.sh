#!/usr/bin/env bash
# check_time.sh
# Reports real wall-clock time and whether we're inside the nightly
# work window (23:00-06:00 local time). Never trust an LLM's internal
# sense of time -- this script is the single source of truth.
#
# Emergency mode override: if state/emergency_mode.active exists, the work
# window is considered always open (daytime showcase / continuous running).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMERGENCY_FLAG="$PROJECT_DIR/state/emergency_mode.active"

WINDOW_START_HOUR=23   # 23:00
WINDOW_END_HOUR=6      # 06:00

now_epoch=$(date +%s)
now_human=$(date '+%Y-%m-%d %H:%M:%S %Z')
hour=$(date +%H)
hour=$((10#$hour))  # force base-10 (avoid octal parsing of "08", "09")
minute=$(date +%M)
minute=$((10#$minute))

# Emergency mode: bypass the time window entirely.
if [ -f "$EMERGENCY_FLAG" ]; then
  emergency_reason=$(cat "$EMERGENCY_FLAG" 2>/dev/null | head -1 || echo "active")
  echo "current_time: $now_human"
  echo "in_work_window: true"
  echo "minutes_remaining_until_window_close: 9999"
  echo "emergency_mode: ACTIVE ($emergency_reason)"
  echo "ACTION: emergency mode -- window always open, no time-based shutdown."
  exit 0
fi

# Are we inside [23:00, 06:00)? This window wraps midnight.
if [ "$hour" -ge "$WINDOW_START_HOUR" ] || [ "$hour" -lt "$WINDOW_END_HOUR" ]; then
  in_window="true"
else
  in_window="false"
fi

# Minutes remaining until 06:00 (today if hour < 6, else tomorrow).
if [ "$hour" -lt "$WINDOW_END_HOUR" ]; then
  end_epoch=$(date -d "today ${WINDOW_END_HOUR}:00:00" +%s)
else
  end_epoch=$(date -d "tomorrow ${WINDOW_END_HOUR}:00:00" +%s)
fi
minutes_remaining=$(( (end_epoch - now_epoch) / 60 ))

echo "current_time: $now_human"
echo "in_work_window: $in_window"
echo "minutes_remaining_until_window_close: $minutes_remaining"

if [ "$in_window" = "false" ]; then
  echo "ACTION: outside work window -- do not proceed with goal work, shut down now."
elif [ "$minutes_remaining" -lt 15 ]; then
  echo "ACTION: less than 15 minutes remain -- treat as window closing, begin shutdown."
fi
