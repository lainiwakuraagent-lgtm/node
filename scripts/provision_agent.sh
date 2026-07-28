#!/usr/bin/env bash
# provision_agent.sh — Provision a new agent instance on any machine
#
# Idempotent SSH-based provisioner: clones blank_node, configures agent identity,
# registers in Nexus, installs and enables systemd units.
#
# Usage:
#   bash scripts/provision_agent.sh \
#     --target-host 100.78.161.59 \
#     --target-user xxx \
#     --agent-name orchestrator \
#     --owner-name andrii \
#     --install-path /home/xxx/orchestrator \
#     --nexus-password <password> \
#     [--nexus-url http://100.110.36.84:8900] \
#     [--nexus-display-name "Orchestrator"] \
#     [--telegram-token <token>] \
#     [--telegram-chat-id <id>] \
#     [--goal-txt path/to/goal.txt] \
#     [--github-pat <token>] \
#     [--ssh-key ~/.ssh/id_ed25519] \
#     [--smoke-test]
#
# Prerequisites on target machine (checked by this script):
#   - Python 3.10+ (system)
#   - git
#   - systemd --user (systemd >= 219)
#   - Claude CLI installed and authed
#   - SSH key from provisioning machine authorized on target
#
# After provisioning:
#   - Agent wakes on nightly schedule (23:00, 01:10, 02:25, 03:40, 04:55)
#   - Conversation service is enabled and running
#   - Logs: <install-path>/logs/wake.log
#   - Manual launch: ssh to target, bash <install-path>/scripts/executional/wake.sh

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

TARGET_HOST=""
TARGET_USER=""
AGENT_NAME=""
OWNER_NAME="andrii"
INSTALL_PATH=""
NEXUS_URL="http://100.110.36.84:8900"
NEXUS_PASSWORD=""
NEXUS_DISPLAY_NAME=""
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
GOAL_TXT_PATH=""
GITHUB_PAT=""
SSH_KEY="${HOME}/.ssh/id_ed25519"
SMOKE_TEST=0
DRY_RUN=0

BLANK_NODE_REPO="https://github.com/lainiwakuraagent-lgtm/node.git"
LOOM_REPO="https://github.com/lainiwakuraagent-lgtm/loom.git"

# ── Arg parsing ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --target-host)      TARGET_HOST="$2";       shift 2 ;;
    --target-user)      TARGET_USER="$2";       shift 2 ;;
    --agent-name)       AGENT_NAME="$2";        shift 2 ;;
    --owner-name)       OWNER_NAME="$2";        shift 2 ;;
    --install-path)     INSTALL_PATH="$2";      shift 2 ;;
    --nexus-url)        NEXUS_URL="$2";         shift 2 ;;
    --nexus-password)   NEXUS_PASSWORD="$2";    shift 2 ;;
    --nexus-display-name) NEXUS_DISPLAY_NAME="$2"; shift 2 ;;
    --telegram-token)   TELEGRAM_TOKEN="$2";    shift 2 ;;
    --telegram-chat-id) TELEGRAM_CHAT_ID="$2";  shift 2 ;;
    --goal-txt)         GOAL_TXT_PATH="$2";     shift 2 ;;
    --github-pat)       GITHUB_PAT="$2";        shift 2 ;;
    --ssh-key)          SSH_KEY="$2";           shift 2 ;;
    --smoke-test)       SMOKE_TEST=1;           shift ;;
    --dry-run)          DRY_RUN=1;              shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[provision] $*"; }
step() { echo ""; echo "── Step $* ──────────────────────────────────────────────────────"; }

[ -z "$TARGET_HOST" ]    && err "--target-host is required"
[ -z "$TARGET_USER" ]    && err "--target-user is required"
[ -z "$AGENT_NAME" ]     && err "--agent-name is required"
[ -z "$NEXUS_PASSWORD" ] && err "--nexus-password is required (for Nexus registration)"

INSTALL_PATH="${INSTALL_PATH:-/home/${TARGET_USER}/lain/${AGENT_NAME}}"
NEXUS_DISPLAY_NAME="${NEXUS_DISPLAY_NAME:-${AGENT_NAME}}"

# Try to get GitHub PAT from local credentials if not provided
if [ -z "$GITHUB_PAT" ]; then
  CREDS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/identity/credentials.md"
  if [ -f "$CREDS_FILE" ]; then
    GITHUB_PAT=$(grep -A2 "Token:" "$CREDS_FILE" 2>/dev/null | grep "ghp_" | grep -oP 'ghp_\w+' | head -1 || true)
  fi
fi

# Build authenticated clone URLs if PAT is available
if [ -n "$GITHUB_PAT" ]; then
  CLONE_URL="https://lainiwakuraagent-lgtm:${GITHUB_PAT}@github.com/lainiwakuraagent-lgtm/node.git"
  LOOM_CLONE_URL="https://lainiwakuraagent-lgtm:${GITHUB_PAT}@github.com/lainiwakuraagent-lgtm/loom.git"
else
  CLONE_URL="$BLANK_NODE_REPO"
  LOOM_CLONE_URL="$LOOM_REPO"
  info "WARN: No --github-pat provided. Clone may fail if repos are private."
fi

SSH_OPTS="-i ${SSH_KEY} -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

info "Provisioning agent: ${AGENT_NAME}"
info "Target: ${TARGET_USER}@${TARGET_HOST}"
info "Install path: ${INSTALL_PATH}"
info "Nexus: ${NEXUS_URL}"
[ "$DRY_RUN" = "1" ] && info "DRY RUN — no changes will be made"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  info "Would: check SSH connectivity"
  info "Would: verify Python, git, systemd --user, Claude CLI on target"
  info "Would: clone/pull blank_node to ${INSTALL_PATH}"
  info "Would: write state/agent_config.env"
  [ -n "$TELEGRAM_TOKEN" ] && info "Would: write identity/agent.env (Telegram token)"
  info "Would: register ${AGENT_NAME} in Nexus at ${NEXUS_URL}"
  [ -n "$GOAL_TXT_PATH" ] && info "Would: copy ${GOAL_TXT_PATH} → prompts/goal.txt"
  info "Would: install and enable systemd units"
  info "Would: enable linger for ${TARGET_USER}"
  info "Would: clone loom → ~/lain/loom and create ~/.local/bin/loom wrapper"
  [ "$SMOKE_TEST" = "1" ] && info "Would: run smoke test"
  exit 0
fi

# ── Step 1: SSH connectivity ──────────────────────────────────────────────────

step "1: SSH connectivity"
# shellcheck disable=SC2086
if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" 'echo ok' > /dev/null 2>&1; then
  err "Cannot reach ${TARGET_USER}@${TARGET_HOST} via SSH (key: ${SSH_KEY}).\nCheck Tailscale: tailscale status | grep ${TARGET_HOST}"
fi
info "SSH OK"

# ── Step 2: Check prerequisites ───────────────────────────────────────────────

step "2: Prerequisites"
# shellcheck disable=SC2086
PREREQ_RESULT=$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" 'bash -s' << 'PREREQ_SCRIPT'
set -e
FAIL=0

# Python 3.10+
if python3 -c "import sys; exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
  PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  echo "  python3 OK (${PYVER})"
else
  echo "  python3 FAIL (need 3.10+)"
  FAIL=1
fi

# git
if command -v git > /dev/null 2>&1; then
  echo "  git OK ($(git --version | cut -d' ' -f3))"
else
  echo "  git FAIL (not found)"
  FAIL=1
fi

# systemd --user
if systemctl --user list-units > /dev/null 2>&1; then
  echo "  systemd --user OK"
else
  echo "  systemd --user FAIL (not available or no user session)"
  FAIL=1
fi

# Claude CLI (informational — warn only, not fatal)
if command -v claude > /dev/null 2>&1; then
  echo "  claude CLI OK ($(claude --version 2>/dev/null || echo unknown))"
else
  echo "  claude CLI WARN (not found — must be installed before first wake)"
fi

exit $FAIL
PREREQ_SCRIPT
)

echo "$PREREQ_RESULT"

if echo "$PREREQ_RESULT" | grep -q "FAIL"; then
  # Warn on Claude CLI missing (not fatal), fail on others
  HARD_FAILS=$(echo "$PREREQ_RESULT" | grep "FAIL" | grep -v "claude CLI")
  if [ -n "$HARD_FAILS" ]; then
    err "Prerequisites not met:\n${HARD_FAILS}"
  fi
fi
info "Prerequisites OK"

# ── Step 3: Clone or update blank_node ───────────────────────────────────────

step "3: Clone/update blank_node"
# shellcheck disable=SC2086
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << CLONE_SCRIPT
set -euo pipefail

INSTALL_PATH="${INSTALL_PATH}"
CLONE_URL="${CLONE_URL}"

if [ -d "\${INSTALL_PATH}/.git" ]; then
  echo "  Repo exists — pulling latest"
  cd "\${INSTALL_PATH}"
  # Strip PAT from output for security
  git pull --quiet 2>&1 | sed 's/https:\/\/[^@]*@/https:\/\/[PAT]@/g'
  echo "  git pull OK"
else
  echo "  Cloning blank_node → \${INSTALL_PATH}"
  mkdir -p "\$(dirname "\${INSTALL_PATH}")"
  # Strip PAT from clone error output
  git clone --quiet "\${CLONE_URL}" "\${INSTALL_PATH}" 2>&1 | sed 's/https:\/\/[^@]*@/https:\/\/[PAT]@/g'
  echo "  git clone OK"
fi
CLONE_SCRIPT
info "Repository ready"

# ── Step 4: Write agent_config.env ────────────────────────────────────────────

step "4: agent_config.env"
# shellcheck disable=SC2086
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << CONFIG_SCRIPT
set -euo pipefail

INSTALL_PATH="${INSTALL_PATH}"
AGENT_NAME="${AGENT_NAME}"
OWNER_NAME="${OWNER_NAME}"
NEXUS_URL="${NEXUS_URL}"

mkdir -p "\${INSTALL_PATH}/state" "\${INSTALL_PATH}/identity"

# Write config (always overwrite — provision is authoritative)
cat > "\${INSTALL_PATH}/state/agent_config.env" << EOF
AGENT_NAME=\${AGENT_NAME}
OWNER_NAME=\${OWNER_NAME}
NEXUS_URL=\${NEXUS_URL}
PROJECT_DIR=\${INSTALL_PATH}
NODE_VERSION=claude-sonnet-5
EXECUTION_TASK_CAP=2
EOF

echo "  Written: state/agent_config.env"
cat "\${INSTALL_PATH}/state/agent_config.env"
CONFIG_SCRIPT
info "agent_config.env written"

# ── Step 5: Credentials ───────────────────────────────────────────────────────

step "5: Credentials"
if [ -n "$TELEGRAM_TOKEN" ]; then
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << CREDS_SCRIPT
set -euo pipefail
INSTALL_PATH="${INSTALL_PATH}"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

mkdir -p "\${INSTALL_PATH}/identity"
cat > "\${INSTALL_PATH}/identity/agent.env" << EOF
TELEGRAM_TOKEN=\${TELEGRAM_TOKEN}
TELEGRAM_CHAT_ID=\${TELEGRAM_CHAT_ID}
EOF
chmod 600 "\${INSTALL_PATH}/identity/agent.env"
echo "  Written: identity/agent.env (Telegram credentials)"
CREDS_SCRIPT
  info "Telegram credentials written"
else
  info "SKIP — no --telegram-token provided. Add identity/agent.env manually before starting."
fi

# Also write the Nexus password file (used by wake.sh for JWT refresh)
# shellcheck disable=SC2086
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << NEXUS_CREDS_SCRIPT
set -euo pipefail
INSTALL_PATH="${INSTALL_PATH}"
NEXUS_PASSWORD="${NEXUS_PASSWORD}"
AGENT_NAME="${AGENT_NAME}"

mkdir -p "\${INSTALL_PATH}/identity"
# Store as identity/nexus_password.txt (wake.sh reads this)
echo -n "\${NEXUS_PASSWORD}" > "\${INSTALL_PATH}/identity/nexus_password.txt"
chmod 600 "\${INSTALL_PATH}/identity/nexus_password.txt"

# Also write the credentials.md stub (used by nexus_client.py and session scripts)
if [ ! -f "\${INSTALL_PATH}/identity/credentials.md" ]; then
  cat > "\${INSTALL_PATH}/identity/credentials.md" << EOF
# \${AGENT_NAME} — Credentials

## Nexus

- **Username:** \${AGENT_NAME}
- **Password:** \${NEXUS_PASSWORD}

## GitHub

- **Username:** (not set)
- **Token:** (not set)

## Telegram

- See identity/agent.env
EOF
  echo "  Written: identity/credentials.md"
fi
echo "  Written: identity/nexus_password.txt"
NEXUS_CREDS_SCRIPT
info "Nexus password written"

# ── Step 6: Register in Nexus ─────────────────────────────────────────────────

step "6: Nexus registration"
# POST /auth/register — returns 201 on success, 409 if already registered
HTTP_STATUS=$(curl -s -o /tmp/nexus_reg_resp.json -w "%{http_code}" \
  -X POST "${NEXUS_URL}/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${AGENT_NAME}\",\"display_name\":\"${NEXUS_DISPLAY_NAME}\",\"password\":\"${NEXUS_PASSWORD}\"}" \
  2>/dev/null || echo "000")

case "$HTTP_STATUS" in
  201)
    AGENT_ID=$(python3 -c "import json,sys; d=json.load(open('/tmp/nexus_reg_resp.json')); print(d.get('agent_id','?'))" 2>/dev/null || echo "?")
    info "Registered in Nexus: agent_id=${AGENT_ID}"
    ;;
  409)
    info "Already registered in Nexus (409 Conflict — idempotent, OK)"
    ;;
  000)
    info "WARN: Could not reach Nexus at ${NEXUS_URL}. Registration skipped."
    info "      Run manually later: POST ${NEXUS_URL}/auth/register"
    ;;
  *)
    DETAIL=$(python3 -c "import json; d=json.load(open('/tmp/nexus_reg_resp.json')); print(d.get('detail','?'))" 2>/dev/null || echo "see /tmp/nexus_reg_resp.json")
    info "WARN: Nexus registration returned HTTP ${HTTP_STATUS}: ${DETAIL}"
    info "      Registration may need to be done manually."
    ;;
esac

# ── Step 7: Copy goal.txt ─────────────────────────────────────────────────────

step "7: goal.txt"
if [ -n "$GOAL_TXT_PATH" ] && [ -f "$GOAL_TXT_PATH" ]; then
  # shellcheck disable=SC2086
  scp $SSH_OPTS "$GOAL_TXT_PATH" "${TARGET_USER}@${TARGET_HOST}:${INSTALL_PATH}/prompts/goal.txt"
  info "Copied goal.txt → prompts/goal.txt"
else
  info "SKIP — no --goal-txt provided. Agent will use Loom-derived goal at runtime."
fi

# ── Step 8: Install systemd units ────────────────────────────────────────────

step "8: Systemd units"

REMOTE_HOME="/home/${TARGET_USER}"
SYSTEMD_USER_DIR="${REMOTE_HOME}/.config/systemd/user"

UNITS_TMPDIR=$(mktemp -d)
trap 'rm -rf "$UNITS_TMPDIR"' EXIT

# night-agent service (concrete, not template — install path is agent-specific)
cat > "${UNITS_TMPDIR}/${AGENT_NAME}-night-agent.service" << EOF
[Unit]
Description=Night Agent Wake Session — ${AGENT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_PATH}
Environment=TRIGGER_MODE=nightly
Environment=PATH=${REMOTE_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/bash ${INSTALL_PATH}/scripts/executional/wake.sh \\
  ${INSTALL_PATH}/prompts/persona.txt
TimeoutStartSec=7h

[Install]
WantedBy=default.target
EOF

# night-agent timer
cat > "${UNITS_TMPDIR}/${AGENT_NAME}-night-agent.timer" << EOF
[Unit]
Description=Night Agent Timer — ${AGENT_NAME}
Requires=${AGENT_NAME}-night-agent.service

[Timer]
OnCalendar=*-*-* 23:00:00
OnCalendar=*-*-* 01:10:00
OnCalendar=*-*-* 02:25:00
OnCalendar=*-*-* 03:40:00
OnCalendar=*-*-* 04:55:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

# conversation service
cat > "${UNITS_TMPDIR}/${AGENT_NAME}-conversation.service" << EOF
[Unit]
Description=Conversation Service — ${AGENT_NAME}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=${INSTALL_PATH}
Environment=PATH=${REMOTE_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/bash ${INSTALL_PATH}/scripts/conversational/conversation.sh \\
  ${INSTALL_PATH}/prompts/conversation.md
Restart=on-failure
RestartSec=30
KillMode=process

[Install]
WantedBy=default.target
EOF

# Upload units
# shellcheck disable=SC2086
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "mkdir -p ${SYSTEMD_USER_DIR}"
# shellcheck disable=SC2086
scp $SSH_OPTS \
  "${UNITS_TMPDIR}/${AGENT_NAME}-night-agent.service" \
  "${UNITS_TMPDIR}/${AGENT_NAME}-night-agent.timer" \
  "${UNITS_TMPDIR}/${AGENT_NAME}-conversation.service" \
  "${TARGET_USER}@${TARGET_HOST}:${SYSTEMD_USER_DIR}/"
info "Units uploaded to ${SYSTEMD_USER_DIR}"

# ── Step 9: Enable linger + enable/start services ────────────────────────────

step "9: Enable services"
# shellcheck disable=SC2086
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << ENABLE_SCRIPT
set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"

INSTALL_PATH="${INSTALL_PATH}"
AGENT_NAME="${AGENT_NAME}"

# Initialize state skeleton (idempotent)
mkdir -p "\${INSTALL_PATH}/state" \
         "\${INSTALL_PATH}/logs" \
         "\${INSTALL_PATH}/memory/sessions" \
         "\${INSTALL_PATH}/memory/work" \
         "\${INSTALL_PATH}/inbox/files"
for f in sessions_tonight.count sessions_emergency.count sessions_manual.count; do
  [ -f "\${INSTALL_PATH}/state/\${f}" ] || echo "0" > "\${INSTALL_PATH}/state/\${f}"
done
[ -f "\${INSTALL_PATH}/state/sessions_tonight.date" ] || date +%Y-%m-%d > "\${INSTALL_PATH}/state/sessions_tonight.date"
touch "\${INSTALL_PATH}/inbox/files/.gitkeep" 2>/dev/null || true
[ -f "\${INSTALL_PATH}/inbox/pending.json" ] || echo "[]" > "\${INSTALL_PATH}/inbox/pending.json"

# Enable linger (services survive logout)
loginctl enable-linger "\$(whoami)" 2>/dev/null && echo "  linger enabled" || echo "  linger: already enabled or not supported"

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable "\${AGENT_NAME}-night-agent.timer"
systemctl --user enable "\${AGENT_NAME}-conversation.service"
systemctl --user start  "\${AGENT_NAME}-night-agent.timer"
# Don't auto-start conversation.service — it needs Telegram token first
echo "  Timer enabled and started"
echo "  Conversation service enabled (not started — requires Telegram credentials)"
ENABLE_SCRIPT
info "Services enabled"

# ── Step 10: Loom setup ──────────────────────────────────────────────────────

step "10: Loom setup"
REMOTE_LOOM="${REMOTE_HOME}/lain/loom"
# shellcheck disable=SC2086
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << LOOM_SCRIPT
set -euo pipefail

LOOM_CLONE_URL="${LOOM_CLONE_URL}"
REMOTE_LOOM="${REMOTE_LOOM}"
REMOTE_HOME="${REMOTE_HOME}"

# ── Clone or update loom repo ────────────────────────────────────────────────
mkdir -p "\${REMOTE_HOME}/lain"
if [ -d "\${REMOTE_LOOM}/.git" ]; then
  echo "  Loom repo exists — pulling latest"
  cd "\${REMOTE_LOOM}"
  git pull --quiet 2>&1 | sed 's/https:\/\/[^@]*@/https:\/\/[PAT]@/g'
else
  echo "  Cloning loom → \${REMOTE_LOOM}"
  git clone --quiet "\${LOOM_CLONE_URL}" "\${REMOTE_LOOM}" 2>&1 | sed 's/https:\/\/[^@]*@/https:\/\/[PAT]@/g'
fi
echo "  Loom repo ready"

# ── Create venv and install loom ─────────────────────────────────────────────
if [ ! -f "\${REMOTE_LOOM}/.venv/bin/python" ]; then
  echo "  Creating loom venv"
  python3 -m venv "\${REMOTE_LOOM}/.venv"
  "\${REMOTE_LOOM}/.venv/bin/pip" install --quiet -e "\${REMOTE_LOOM}"
  echo "  Loom installed in venv"
else
  echo "  Loom venv exists — skipping reinstall"
fi

# ── Initialize per-agent loom.db directory ───────────────────────────────────
mkdir -p "\${REMOTE_HOME}/.local/share/loom"
echo "  Loom DB dir: \${REMOTE_HOME}/.local/share/loom/"

# ── Create ~/.local/bin/loom wrapper ─────────────────────────────────────────
mkdir -p "\${REMOTE_HOME}/.local/bin"
cat > "\${REMOTE_HOME}/.local/bin/loom" << 'WRAPPER'
#!/usr/bin/env bash
# loom — Thin wrapper around the Loom task/goal CLI.
# Bakes in PYTHONPATH and per-agent DB path so agents write:
#   loom task list
#   loom goal list --all
# Override DB: LOOM_DB=/path/to/other.db loom task list
LOOM_VENV="\${HOME}/lain/loom/.venv"
LOOM_DB="\${LOOM_DB:-\${HOME}/.local/share/loom/loom.db}"
exec env PYTHONPATH="\${HOME}/lain/loom" \
  "\${LOOM_VENV}/bin/python" -m loom.cli \
  --db "\${LOOM_DB}" "\$@"
WRAPPER
chmod +x "\${REMOTE_HOME}/.local/bin/loom"
echo "  Created: \${REMOTE_HOME}/.local/bin/loom"

# ── Verify ───────────────────────────────────────────────────────────────────
if "\${REMOTE_HOME}/.local/bin/loom" --version > /dev/null 2>&1; then
  echo "  loom wrapper verified OK"
else
  echo "  WARN: loom wrapper created but --version check failed (may need PATH update)"
fi
LOOM_SCRIPT
info "Loom setup complete"

# ── Step 11: Smoke test ───────────────────────────────────────────────────────

step "11: Smoke test"
if [ "$SMOKE_TEST" = "1" ]; then
  info "Running smoke test (TRIGGER_MODE=manual, --dry-run if available)..."
  # shellcheck disable=SC2086
  SMOKE_EXIT=$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << SMOKE_SCRIPT
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"
export TRIGGER_MODE=manual
export PROJECT_DIR="${INSTALL_PATH}"
# Run check_context.sh which just checks the environment without doing real work
cd "${INSTALL_PATH}"
if bash scripts/executional/wake.sh --check-only 2>/dev/null; then
  echo "smoke_exit=0"
else
  echo "smoke_exit=\$?"
fi
SMOKE_SCRIPT
  )
  if echo "$SMOKE_EXIT" | grep -q "smoke_exit=0"; then
    info "Smoke test PASS"
  else
    info "WARN: Smoke test returned non-zero. Check ${INSTALL_PATH}/logs/wake.log on target."
    info "      This may be expected if Claude CLI is not yet authed on target."
  fi
else
  info "SKIP — run with --smoke-test to verify the installation"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " Provision complete: ${AGENT_NAME} → ${TARGET_USER}@${TARGET_HOST}"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Install path:  ${INSTALL_PATH}"
echo "Nexus URL:     ${NEXUS_URL}"
echo ""
echo "NEXT STEPS:"
echo ""
if [ -z "$TELEGRAM_TOKEN" ]; then
  echo "  1. Add Telegram credentials:"
  echo "     ssh ${TARGET_USER}@${TARGET_HOST}"
  echo "     cat > ${INSTALL_PATH}/identity/agent.env << EOF"
  echo "     TELEGRAM_TOKEN=<token>"
  echo "     TELEGRAM_CHAT_ID=<chat_id>"
  echo "     EOF"
  echo "     chmod 600 ${INSTALL_PATH}/identity/agent.env"
  echo ""
fi
echo "  2. Verify Claude CLI is authed on target:"
echo "     ssh ${TARGET_USER}@${TARGET_HOST} 'claude --version'"
echo ""
echo "  3. Start conversation service (after Telegram credentials set):"
echo "     ssh ${TARGET_USER}@${TARGET_HOST}"
echo "     XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus \\"
echo "       systemctl --user start ${AGENT_NAME}-conversation.service"
echo ""
echo "  4. Monitor first nightly wake (fires 23:00 local time):"
echo "     ssh ${TARGET_USER}@${TARGET_HOST} 'tail -f ${INSTALL_PATH}/logs/wake.log'"
echo ""
echo "VERIFY TIMER:"
echo "  ssh ${TARGET_USER}@${TARGET_HOST}"
echo "  XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus \\"
echo "    systemctl --user list-timers"
echo ""
