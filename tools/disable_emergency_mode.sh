#!/usr/bin/env bash
# disable_emergency_mode.sh
# Deactivates @Lain emergency/daytime mode:
#   - Removes the emergency flag (restores time window and session count enforcement)
#   - Stops and removes the 15-minute emergency timer
#
# Usage:
#   bash tools/disable_emergency_mode.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$PROJECT_DIR/state"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
EMERGENCY_FLAG="$STATE_DIR/emergency_mode.active"

echo "=== Disabling Emergency Mode ==="

# 1. Stop and disable the timer.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"

if systemctl --user is-active emergency-agent.timer &>/dev/null; then
  systemctl --user stop emergency-agent.timer
  echo "[OK] emergency-agent.timer stopped"
else
  echo "[--] emergency-agent.timer was not running"
fi

if systemctl --user is-enabled emergency-agent.timer &>/dev/null; then
  systemctl --user disable emergency-agent.timer
  echo "[OK] emergency-agent.timer disabled"
fi

# 2. Remove the installed unit files.
rm -f "$SYSTEMD_USER_DIR/emergency-agent.timer" "$SYSTEMD_USER_DIR/emergency-agent.service"
echo "[OK] Systemd unit files removed"

systemctl --user daemon-reload
echo "[OK] systemd user daemon reloaded"

# 3. Remove the emergency flag.
if [ -f "$EMERGENCY_FLAG" ]; then
  reason=$(cat "$EMERGENCY_FLAG")
  rm -f "$EMERGENCY_FLAG"
  echo "[OK] Emergency flag removed (was: $reason)"
else
  echo "[--] Emergency flag was not present"
fi

# 4. Reset the emergency session counter.
echo "0" > "$STATE_DIR/sessions_emergency.count"
echo "[OK] sessions_emergency.count reset to 0"

echo ""
echo "=== Emergency Mode DISABLED ==="
echo "Normal 23:00-06:00 scheduling resumes."
echo "Night agent will next fire at scheduled timer times."
