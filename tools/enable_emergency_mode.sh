#!/usr/bin/env bash
# enable_emergency_mode.sh
# Activates @Lain emergency/daytime mode:
#   - Bypasses 23:00-06:00 time window restriction
#   - Bypasses session count limits (effectively unlimited sessions)
#   - Installs a user-level systemd timer at the specified interval
#   - First session starts in ~1 minute
#
# Usage:
#   bash tools/enable_emergency_mode.sh [interval] [reason]
#   interval: session interval in minutes (default: 60)
#   reason:   free-text label written to the flag file (default: "daytime showcase mode")
#
# Examples:
#   bash tools/enable_emergency_mode.sh             # 60-min interval
#   bash tools/enable_emergency_mode.sh 30          # 30-min interval
#   bash tools/enable_emergency_mode.sh 15 "urgent" # 15-min, custom reason
#
# To stop emergency mode:
#   bash tools/disable_emergency_mode.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$PROJECT_DIR/state"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
EMERGENCY_FLAG="$STATE_DIR/emergency_mode.active"

INTERVAL_MIN="${1:-60}"
REASON="${2:-daytime showcase mode}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Validate interval is a positive integer.
if ! [[ "$INTERVAL_MIN" =~ ^[0-9]+$ ]] || [ "$INTERVAL_MIN" -lt 1 ]; then
  echo "ERROR: interval must be a positive integer (minutes). Got: $INTERVAL_MIN" >&2
  exit 1
fi

echo "=== Enabling Emergency Mode ==="
echo "Interval: ${INTERVAL_MIN}min between sessions"
echo "Reason:   $REASON"
echo "Time:     $TIMESTAMP"
echo ""

# 1. Write the emergency flag.
echo "$REASON (activated: $TIMESTAMP)" > "$EMERGENCY_FLAG"
echo "[OK] Emergency flag written: $EMERGENCY_FLAG"

# 2. Install user-level systemd units.
# The timer interval is written dynamically so no manual edits to the .timer
# file are needed — just pass a different interval to this script.
mkdir -p "$SYSTEMD_USER_DIR"
cp "$SCRIPTS_DIR/emergency-agent.service" "$SYSTEMD_USER_DIR/emergency-agent.service"
cat > "$SYSTEMD_USER_DIR/emergency-agent.timer" <<EOF
[Unit]
Description=Emergency Agent Timer — fires every ${INTERVAL_MIN} minutes

[Timer]
OnActiveSec=1min
OnUnitActiveSec=${INTERVAL_MIN}min
Persistent=false

[Install]
WantedBy=timers.target
EOF
echo "[OK] Systemd units installed to $SYSTEMD_USER_DIR (interval: ${INTERVAL_MIN}min)"

# 3. Enable linger so user services survive without an active login session.
loginctl enable-linger "$(whoami)" 2>/dev/null && echo "[OK] Linger enabled for $(whoami)" \
  || echo "[WARN] Could not enable linger (may already be enabled or requires sudo)"

# 4. Reload and start the timer.
_uid="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/${_uid}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_uid}/bus"

systemctl --user daemon-reload
echo "[OK] systemd user daemon reloaded"

systemctl --user enable emergency-agent.timer
systemctl --user start emergency-agent.timer
echo "[OK] emergency-agent.timer enabled and started"

echo ""
echo "=== Emergency Mode ACTIVE ==="
echo "First session fires in ~1 minute."
echo "Subsequent sessions fire every ${INTERVAL_MIN} minutes."
echo "Sessions log to: $PROJECT_DIR/logs/"
echo ""
echo "To check timer status:"
echo "  systemctl --user status emergency-agent.timer"
echo ""
echo "To disable emergency mode:"
echo "  bash $PROJECT_DIR/tools/disable_emergency_mode.sh"
