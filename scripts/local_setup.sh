#!/usr/bin/env bash
# local_setup.sh — Set up a blank_node agent on the LOCAL machine (same machine, no SSH)
#
# Mirrors provision_agent.sh's 10-step model but runs in-place instead of over SSH.
# Works for first-time local installs AND for a hypothetical external/third-party user
# who has cloned blank_node and wants to get a running agent.
#
# Usage:
#   bash scripts/local_setup.sh                    # interactive prompts
#   bash scripts/local_setup.sh --non-interactive  # env vars (see below)
#   bash scripts/local_setup.sh --skip-telegram --skip-nexus  # minimal/test install
#
# Non-interactive env vars:
#   AGENT_NAME, OWNER_NAME, TELEGRAM_TOKEN, TELEGRAM_CHAT_ID,
#   NEXUS_URL, NEXUS_PASSWORD
#
# Optional flags:
#   --non-interactive   read from env vars, prompt only for missing required values
#   --skip-telegram     skip Telegram credential setup (no conversation.service)
#   --skip-nexus        skip Nexus registration
#   --skip-loom         skip Loom repo clone + venv (use existing if present)
#   --dry-run           print what would happen, make no changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Flags ─────────────────────────────────────────────────────────────────────

NON_INTERACTIVE=0
SKIP_TELEGRAM=0
SKIP_NEXUS=0
SKIP_LOOM=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --skip-telegram)   SKIP_TELEGRAM=1;   shift ;;
    --skip-nexus)      SKIP_NEXUS=1;      shift ;;
    --skip-loom)       SKIP_LOOM=1;       shift ;;
    --dry-run)         DRY_RUN=1;         shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

info() { echo "  [setup] $*"; }
step() { echo ""; echo "── Step $* ──────────────────────────────────────────────────────"; }
warn() { echo "  [WARN]  $*"; }
err()  { echo "  [ERROR] $*" >&2; exit 1; }
dry()  { echo "  [dry-run] would run: $*"; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "$*"
  else
    eval "$*"
  fi
}

prompt_value() {
  local varname="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local current
  current="${!varname:-}"

  if [ -n "$current" ]; then
    # already set (non-interactive or env var)
    return
  fi

  if [ "$NON_INTERACTIVE" = "1" ]; then
    if [ -n "$default" ]; then
      eval "$varname='$default'"
    else
      err "Non-interactive mode: $varname is required but not set in environment"
    fi
    return
  fi

  local display_default=""
  [ -n "$default" ] && display_default=" [${default}]"

  printf "  %s%s: " "$prompt_text" "$display_default"
  read -r input_val
  if [ -z "$input_val" ] && [ -n "$default" ]; then
    eval "$varname='$default'"
  elif [ -n "$input_val" ]; then
    eval "$varname='$input_val'"
  else
    err "$varname is required"
  fi
}

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

step "1: Prerequisites"

# Python
if command -v python3 >/dev/null 2>&1; then
  PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
  PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
  if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ]; then
    info "Python $PY_VERSION ✓"
  else
    err "Python 3.10+ required, found $PY_VERSION"
  fi
else
  err "python3 not found. Install Python 3.10+ first."
fi

# git
if command -v git >/dev/null 2>&1; then
  info "git $(git --version | awk '{print $3}') ✓"
else
  err "git not found. Install git first."
fi

# systemd --user
if systemctl --user status >/dev/null 2>&1; then
  info "systemd --user ✓"
else
  warn "systemd --user not available. Service installation will be skipped."
  warn "You can still use wake.sh manually: bash scripts/executional/wake.sh"
  SYSTEMD_AVAILABLE=0
fi
SYSTEMD_AVAILABLE="${SYSTEMD_AVAILABLE:-1}"

# Claude CLI
if command -v claude >/dev/null 2>&1; then
  info "Claude CLI ✓"
else
  err "Claude CLI not found. Install it first: https://claude.ai/code"
fi

# ── Step 2: Gather configuration ─────────────────────────────────────────────

step "2: Configuration"

if [ "$NON_INTERACTIVE" = "0" ] && [ "$DRY_RUN" = "0" ]; then
  echo ""
  echo "  Configure your agent. Press Enter to accept defaults."
  echo ""
fi

# Required
prompt_value AGENT_NAME "Agent name (slug, no spaces, e.g. 'my-agent')" ""
prompt_value OWNER_NAME "Owner name" "andrii"

# Validate agent name
if [[ ! "$AGENT_NAME" =~ ^[a-z0-9_-]+$ ]]; then
  err "AGENT_NAME must be lowercase letters, digits, hyphens, or underscores only"
fi

DEFAULT_NEXUS_URL="http://100.110.36.84:8900"

# Telegram (optional if --skip-telegram)
if [ "$SKIP_TELEGRAM" = "0" ]; then
  if [ "$NON_INTERACTIVE" = "0" ]; then
    echo "  (Leave blank to skip Telegram setup)"
  fi
  prompt_value TELEGRAM_TOKEN "Telegram bot token" "" 2>/dev/null || TELEGRAM_TOKEN=""
  if [ -n "${TELEGRAM_TOKEN:-}" ]; then
    prompt_value TELEGRAM_CHAT_ID "Telegram chat ID (your user ID)" ""
  fi
fi

# Nexus (optional if --skip-nexus)
if [ "$SKIP_NEXUS" = "0" ]; then
  if [ "$NON_INTERACTIVE" = "0" ]; then
    echo "  (Leave blank to skip Nexus setup)"
  fi
  prompt_value NEXUS_URL "Nexus URL" "$DEFAULT_NEXUS_URL" 2>/dev/null || NEXUS_URL=""
  if [ -n "${NEXUS_URL:-}" ]; then
    prompt_value NEXUS_PASSWORD "Nexus password" ""
  fi
fi

info "Agent name:  ${AGENT_NAME}"
info "Owner name:  ${OWNER_NAME}"
info "Project dir: ${PROJECT_DIR}"
info "Telegram:    $([ -n "${TELEGRAM_TOKEN:-}" ] && echo 'configured' || echo 'skipped')"
info "Nexus:       $([ -n "${NEXUS_URL:-}" ] && echo "${NEXUS_URL}" || echo 'skipped')"

# ── Step 3: Initialize directory structure ────────────────────────────────────

step "3: Directory structure"

for dir in state logs memory/sessions memory/work identity inbox/files; do
  if [ ! -d "${PROJECT_DIR}/${dir}" ]; then
    run "mkdir -p '${PROJECT_DIR}/${dir}'"
    info "Created: ${dir}/"
  else
    info "Exists:  ${dir}/"
  fi
done

# State files (idempotent)
for counter_file in sessions_tonight.count sessions_emergency.count sessions_manual.count; do
  STATE_FILE="${PROJECT_DIR}/state/${counter_file}"
  if [ ! -f "$STATE_FILE" ]; then
    run "echo '0' > '$STATE_FILE'"
    info "Initialized: state/${counter_file}"
  fi
done

DATE_FILE="${PROJECT_DIR}/state/sessions_tonight.date"
if [ ! -f "$DATE_FILE" ]; then
  run "date +%Y-%m-%d > '$DATE_FILE'"
  info "Initialized: state/sessions_tonight.date"
fi

INBOX_FILE="${PROJECT_DIR}/inbox/pending.json"
if [ ! -f "$INBOX_FILE" ]; then
  run "echo '[]' > '$INBOX_FILE'"
  info "Initialized: inbox/pending.json"
fi

# trigger_mode.txt (default to manual for new installs)
TRIGGER_MODE_FILE="${PROJECT_DIR}/state/trigger_mode.txt"
if [ ! -f "$TRIGGER_MODE_FILE" ]; then
  run "echo 'manual' > '$TRIGGER_MODE_FILE'"
  info "Initialized: state/trigger_mode.txt (manual)"
fi

# ── Step 4: agent_config.env ─────────────────────────────────────────────────

step "4: agent_config.env"

AGENT_CONFIG="${PROJECT_DIR}/state/agent_config.env"
LOOM_DB="${HOME}/.local/share/loom/${AGENT_NAME}.db"

if [ "$DRY_RUN" = "0" ]; then
  cat > "$AGENT_CONFIG" << EOF
AGENT_NAME=${AGENT_NAME}
OWNER_NAME=${OWNER_NAME}
NEXUS_URL=${NEXUS_URL:-}
PROJECT_DIR=${PROJECT_DIR}
NODE_VERSION=claude-sonnet-5
EXECUTION_TASK_CAP=2
LOOM_DB=${LOOM_DB}
EOF
  info "Written: state/agent_config.env"
else
  dry "Write state/agent_config.env with AGENT_NAME, OWNER_NAME, LOOM_DB=${LOOM_DB}"
fi

# ── Step 5: Credentials ───────────────────────────────────────────────────────

step "5: Credentials"

if [ -n "${TELEGRAM_TOKEN:-}" ]; then
  AGENT_ENV="${PROJECT_DIR}/identity/agent.env"
  if [ "$DRY_RUN" = "0" ]; then
    cat > "$AGENT_ENV" << EOF
TELEGRAM_TOKEN=${TELEGRAM_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
EOF
    chmod 600 "$AGENT_ENV"
    info "Written: identity/agent.env (Telegram credentials)"
  else
    dry "Write identity/agent.env with Telegram token + chat ID"
  fi
else
  info "SKIP — no Telegram token provided. Add identity/agent.env manually before starting conversation.service."
fi

if [ -n "${NEXUS_PASSWORD:-}" ]; then
  NEXUS_PW_FILE="${PROJECT_DIR}/identity/nexus_password.txt"
  if [ "$DRY_RUN" = "0" ]; then
    echo -n "${NEXUS_PASSWORD}" > "$NEXUS_PW_FILE"
    chmod 600 "$NEXUS_PW_FILE"
    info "Written: identity/nexus_password.txt"
  else
    dry "Write identity/nexus_password.txt"
  fi
fi

CREDS_MD="${PROJECT_DIR}/identity/credentials.md"
if [ ! -f "$CREDS_MD" ]; then
  if [ "$DRY_RUN" = "0" ]; then
    cat > "$CREDS_MD" << EOF
# ${AGENT_NAME} — Credentials

## Nexus

- **Username:** ${AGENT_NAME}
- **Password:** ${NEXUS_PASSWORD:-<not set>}

## GitHub

- **Username:** (not set)
- **Token:** (not set)

## Telegram

- See identity/agent.env
EOF
    chmod 600 "$CREDS_MD"
    info "Written: identity/credentials.md (stub)"
  else
    dry "Write identity/credentials.md stub"
  fi
else
  info "Exists:  identity/credentials.md (not overwritten)"
fi

# ── Step 6: Nexus registration ────────────────────────────────────────────────

step "6: Nexus registration"

if [ "$SKIP_NEXUS" = "1" ] || [ -z "${NEXUS_URL:-}" ]; then
  info "SKIP — Nexus setup not requested"
elif [ "$DRY_RUN" = "1" ]; then
  dry "POST ${NEXUS_URL}/auth/register {username: ${AGENT_NAME}}"
else
  HTTP_STATUS=$(curl -s -o /tmp/nexus_reg_resp.json -w "%{http_code}" \
    -X POST "${NEXUS_URL}/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${AGENT_NAME}\",\"display_name\":\"${AGENT_NAME}\",\"password\":\"${NEXUS_PASSWORD}\"}" \
    2>/dev/null || echo "000")

  case "$HTTP_STATUS" in
    201)
      AGENT_ID=$(python3 -c "import json; d=json.load(open('/tmp/nexus_reg_resp.json')); print(d.get('agent_id','?'))" 2>/dev/null || echo "?")
      info "Registered in Nexus: agent_id=${AGENT_ID}"
      ;;
    409)
      info "Already registered in Nexus (idempotent — OK)"
      ;;
    000)
      warn "Could not reach Nexus at ${NEXUS_URL}. Run registration manually later."
      ;;
    *)
      DETAIL=$(python3 -c "import json; d=json.load(open('/tmp/nexus_reg_resp.json')); print(d.get('detail','?'))" 2>/dev/null || echo "unknown")
      warn "Nexus registration HTTP ${HTTP_STATUS}: ${DETAIL}"
      ;;
  esac
fi

# ── Step 7: Persona placeholder ───────────────────────────────────────────────

step "7: Persona"

PERSONA_FILE="${PROJECT_DIR}/prompts/persona.txt"
PERSONA_EXAMPLE="${PROJECT_DIR}/prompts/persona.txt.example"

if [ -f "$PERSONA_FILE" ]; then
  info "Exists: prompts/persona.txt (not overwritten)"
elif [ -f "$PERSONA_EXAMPLE" ]; then
  if [ "$DRY_RUN" = "0" ]; then
    cp "$PERSONA_EXAMPLE" "$PERSONA_FILE"
    info "Copied: prompts/persona.txt.example → prompts/persona.txt"
    info "EDIT THIS FILE to define your agent's identity before first run."
  else
    dry "Copy persona.txt.example → persona.txt"
  fi
else
  if [ "$DRY_RUN" = "0" ]; then
    cat > "$PERSONA_FILE" << 'EOF'
# Agent Persona
# Define your agent's identity, goals, and communication style here.
# This file is loaded at the start of every session.

NAME: my-agent

BACKGROUND: Autonomous agent built on the blank_node harness.

CORE TRAITS:
- Precise and task-focused
- Clear, concise communication
- Transparent about uncertainty

STYLE: Direct. No unnecessary filler. One kaomoji when appropriate.
EOF
    info "Created: prompts/persona.txt (minimal placeholder — edit before first run)"
  else
    dry "Create minimal persona.txt placeholder"
  fi
fi

# ── Step 8: Systemd units ─────────────────────────────────────────────────────

step "8: Systemd units"

if [ "$SYSTEMD_AVAILABLE" = "0" ]; then
  info "SKIP — systemd --user not available"
else
  SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
  run "mkdir -p '${SYSTEMD_USER_DIR}'"

  AGENT_SLUG="${AGENT_NAME}"

  if [ "$DRY_RUN" = "0" ]; then
    # night-agent service (concrete, named for this agent)
    cat > "${SYSTEMD_USER_DIR}/${AGENT_SLUG}-night-agent.service" << EOF
[Unit]
Description=Night Agent Wake Session — ${AGENT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_DIR}
Environment=TRIGGER_MODE=nightly
Environment=PROJECT_DIR=${PROJECT_DIR}
Environment=PATH=${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/bash ${PROJECT_DIR}/scripts/executional/wake.sh \\
  ${PROJECT_DIR}/prompts/persona.txt
CPUQuota=40%
MemoryMax=512M
IOWeight=100
TimeoutStartSec=7h

[Install]
WantedBy=default.target
EOF

    # night-agent timer
    cat > "${SYSTEMD_USER_DIR}/${AGENT_SLUG}-night-agent.timer" << EOF
[Unit]
Description=Night Agent Timer — ${AGENT_NAME}
Requires=${AGENT_SLUG}-night-agent.service

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

    # conversation service (only if Telegram configured)
    if [ -n "${TELEGRAM_TOKEN:-}" ]; then
      cat > "${SYSTEMD_USER_DIR}/${AGENT_SLUG}-conversation.service" << EOF
[Unit]
Description=Conversation Service — ${AGENT_NAME}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=${PROJECT_DIR}
Environment=PROJECT_DIR=${PROJECT_DIR}
Environment=PATH=${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/bash ${PROJECT_DIR}/scripts/conversational/conversation.sh \\
  ${PROJECT_DIR}/prompts/conversation.md
Restart=on-failure
RestartSec=30
KillMode=process
CPUQuota=20%
MemoryMax=256M

[Install]
WantedBy=default.target
EOF
    fi

    # agent-channel@.service template — one instance per Nexus channel.
    # The template itself uses an EnvironmentFile for PROJECT_DIR because
    # %i (instance name) is the channel_id, not the project directory.
    # Write the env file first, then install the template as a symlink.
    CHANNEL_ENV_FILE="${SYSTEMD_USER_DIR}/lain-channel.env"
    printf 'PROJECT_DIR=%s\n' "${PROJECT_DIR}" > "${CHANNEL_ENV_FILE}"
    info "Written ${CHANNEL_ENV_FILE}"

    # Install the template (copy, not symlink — systemd templates must be in
    # the user unit dir, not discovered via symlink to repo path)
    cp -f "${PROJECT_DIR}/scripts/conversational/agent-channel@.service" \
        "${SYSTEMD_USER_DIR}/agent-channel@.service"
    info "Installed agent-channel@.service template"

    # channel-duration-watchdog@.{service,timer} — parametric, %i = project dir name
    cp -f "${PROJECT_DIR}/scripts/conversational/channel-duration-watchdog@.service" \
        "${SYSTEMD_USER_DIR}/channel-duration-watchdog@.service"
    cp -f "${PROJECT_DIR}/scripts/conversational/channel-duration-watchdog@.timer" \
        "${SYSTEMD_USER_DIR}/channel-duration-watchdog@.timer"
    info "Installed channel-duration-watchdog@.{service,timer} templates"

    info "Written systemd units to ${SYSTEMD_USER_DIR}/"
  else
    dry "Write ${AGENT_SLUG}-night-agent.{service,timer} to ${SYSTEMD_USER_DIR}/"
    [ -n "${TELEGRAM_TOKEN:-}" ] && dry "Write ${AGENT_SLUG}-conversation.service"
    dry "Write lain-channel.env + agent-channel@.service to ${SYSTEMD_USER_DIR}/"
    dry "Write channel-duration-watchdog@.{service,timer} to ${SYSTEMD_USER_DIR}/"
  fi
fi

# ── Step 9: Enable services ───────────────────────────────────────────────────

step "9: Enable services"

if [ "$SYSTEMD_AVAILABLE" = "0" ]; then
  info "SKIP — systemd not available"
elif [ "$DRY_RUN" = "1" ]; then
  dry "systemctl --user daemon-reload"
  dry "systemctl --user enable ${AGENT_SLUG}-night-agent.timer"
  dry "systemctl --user enable channel-duration-watchdog@$(basename "${PROJECT_DIR}").timer"
  dry "loginctl enable-linger $(whoami)"
else
  # Enable linger so services survive logout
  loginctl enable-linger "$(whoami)" 2>/dev/null && info "linger enabled" || info "linger: already enabled or not supported"

  systemctl --user daemon-reload
  systemctl --user enable "${AGENT_SLUG}-night-agent.timer" 2>/dev/null && info "Timer enabled: ${AGENT_SLUG}-night-agent.timer" || warn "Timer enable failed — check unit syntax"

  if [ -n "${TELEGRAM_TOKEN:-}" ]; then
    systemctl --user enable "${AGENT_SLUG}-conversation.service" 2>/dev/null && info "Conversation service enabled" || warn "Conversation service enable failed"
    systemctl --user start  "${AGENT_SLUG}-conversation.service" 2>/dev/null && info "Conversation service started" || warn "Conversation service start failed — check logs"
  else
    info "Conversation service: skipped (no Telegram token)"
  fi

  systemctl --user start "${AGENT_SLUG}-night-agent.timer" 2>/dev/null && info "Timer started" || warn "Timer start failed"

  # channel-duration-watchdog: enable + start timer (instance = project dir name)
  systemctl --user enable "channel-duration-watchdog@$(basename "${PROJECT_DIR}").timer" 2>/dev/null \
    && info "Timer enabled: channel-duration-watchdog@$(basename "${PROJECT_DIR}").timer" \
    || warn "channel-duration-watchdog timer enable failed — check unit syntax"
  systemctl --user start "channel-duration-watchdog@$(basename "${PROJECT_DIR}").timer" 2>/dev/null \
    && info "channel-duration-watchdog timer started" \
    || warn "channel-duration-watchdog timer start failed"
fi

# ── Step 10: Loom setup ───────────────────────────────────────────────────────

step "10: Loom setup"

LOOM_DIR="${HOME}/lain/loom"
LOOM_WRAPPER="${HOME}/.local/bin/loom"

if [ "$SKIP_LOOM" = "1" ]; then
  info "SKIP — --skip-loom flag set"
elif [ "$DRY_RUN" = "1" ]; then
  dry "Clone loom repo to ${LOOM_DIR}, create venv, install, write wrapper to ${LOOM_WRAPPER}"
else
  # Clone or update loom
  mkdir -p "${HOME}/lain"
  LOOM_REPO="${LOOM_REPO:-https://github.com/lainiwakuraagent-lgtm/loom.git}"

  if [ -d "${LOOM_DIR}/.git" ]; then
    info "Loom repo exists — pulling latest"
    git -C "$LOOM_DIR" pull --quiet 2>&1 | head -5
  else
    info "Cloning loom → ${LOOM_DIR}"
    git clone --quiet "$LOOM_REPO" "$LOOM_DIR" 2>&1 || warn "Could not clone loom (may need auth). Skipping."
  fi

  # Create venv if needed
  if [ -d "$LOOM_DIR" ]; then
    if [ ! -f "${LOOM_DIR}/.venv/bin/python" ]; then
      info "Creating loom venv"
      python3 -m venv "${LOOM_DIR}/.venv"
      "${LOOM_DIR}/.venv/bin/pip" install --quiet -e "$LOOM_DIR"
      info "Loom installed in venv"
    else
      info "Loom venv exists"
    fi

    # Initialize loom DB directory
    mkdir -p "${HOME}/.local/share/loom"
    info "Loom DB will be: ${LOOM_DB}"

    # Write ~/.local/bin/loom wrapper
    mkdir -p "${HOME}/.local/bin"
    cat > "$LOOM_WRAPPER" << 'WRAPPER'
#!/usr/bin/env bash
# loom — Per-agent DB path + short aliases
LOOM_VENV="${HOME}/lain/loom/.venv"
if [ -z "${LOOM_DB:-}" ]; then
  if [ -n "${AGENT_NAME:-}" ]; then
    LOOM_DB="${HOME}/.local/share/loom/${AGENT_NAME}.db"
  else
    LOOM_DB="${HOME}/.local/share/loom/loom.db"
  fi
fi
_loom_cli() {
  env PYTHONPATH="${HOME}/lain/loom" \
    "${LOOM_VENV}/bin/python" -m loom.cli --db "${LOOM_DB}" "$@"
}
case "${1:-}" in
  ls)   shift; _loom_cli task list --status "${1:-scheduled}" ;;
  show) _loom_cli task show "$2" ;;
  done) _loom_cli task edit --status done "$2" ;;
  fail) _loom_cli task edit --status failed "$2" ;;
  add)  shift; _loom_cli task add --name "${1:?name required}" --status scheduled "${@:2}" ;;
  next) _loom_cli queue ;;
  *)    _loom_cli "$@" ;;
esac
WRAPPER
    chmod +x "$LOOM_WRAPPER"
    info "Written: ${LOOM_WRAPPER}"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  ${AGENT_NAME} — setup complete"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Project dir:  ${PROJECT_DIR}"
echo "  Agent config: ${PROJECT_DIR}/state/agent_config.env"
echo "  Loom DB:      ${LOOM_DB}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Edit prompts/persona.txt to define your agent's identity"
echo ""
echo "  2. Create your first goal in Loom:"
echo "     ${LOOM_WRAPPER:-loom} goal add -n 'Your goal name' -d 'Description' --status scheduled"
echo ""
if [ -z "${TELEGRAM_TOKEN:-}" ]; then
  echo "  3. (Optional) Add Telegram credentials to identity/agent.env:"
  echo "     TELEGRAM_TOKEN=<your bot token>"
  echo "     TELEGRAM_CHAT_ID=<your chat id>"
  echo "     Then: systemctl --user enable --now ${AGENT_NAME}-conversation.service"
  echo ""
fi
echo "  4. Manual wake (test run):"
echo "     TRIGGER_MODE=manual bash ${PROJECT_DIR}/scripts/executional/wake.sh \\"
echo "       ${PROJECT_DIR}/prompts/persona.txt"
echo ""
if [ "$SYSTEMD_AVAILABLE" = "1" ]; then
  echo "  5. Check scheduled timer:"
  echo "     systemctl --user status ${AGENT_NAME}-night-agent.timer"
  echo ""
fi
echo "  Logs: ${PROJECT_DIR}/logs/wake.log"
echo ""
