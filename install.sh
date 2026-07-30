#!/usr/bin/env bash
# install.sh — Unified installer for blank_node agents
#
# Replaces local_setup.sh (local) and provision_agent.sh (remote).
# Run locally or over SSH with --remote.
#
# Usage (local):
#   bash install.sh --agent-name my-agent --owner-name alice
#   bash install.sh --non-interactive   # all values from env vars (see below)
#   bash install.sh --dry-run           # print what would happen, no changes
#   bash install.sh --skip-nexus --skip-telegram   # minimal local install
#
# Usage (remote):
#   bash install.sh --remote --target-host 100.78.161.59 --target-user xxx \
#     --agent-name orchestrator --owner-name andrii
#
# Non-interactive env vars (used when --non-interactive or a value is missing):
#   AGENT_NAME, OWNER_NAME, TELEGRAM_TOKEN, TELEGRAM_CHAT_ID,
#   NEXUS_URL, NEXUS_PASSWORD
#
# Flags:
#   --agent-name <name>        Required. Slug: lowercase letters, digits, hyphens, underscores.
#   --owner-name <name>        Owner's short name (default: andrii)
#   --model <id>               Claude model ID (default from .example or claude-sonnet-4-6)
#   --telegram-token <token>   Telegram bot token (or set TELEGRAM_TOKEN)
#   --telegram-chat-id <id>    Telegram chat ID (or set TELEGRAM_CHAT_ID)
#   --nexus-url <url>          Nexus URL (default: http://100.110.36.84:8900)
#   --nexus-password <pw>      Nexus password (or set NEXUS_PASSWORD)
#   --skip-telegram            Skip Telegram credential setup
#   --skip-nexus               Skip Nexus registration
#   --skip-loom                Skip Loom clone/venv (use existing install if present)
#   --non-interactive          Never prompt; read from env vars; fail on missing required values
#   --dry-run                  Print what would happen; make no changes
#   --remote                   Install on a remote host over SSH
#   --target-host <host>       Remote host IP or hostname (required with --remote)
#   --target-user <user>       Remote SSH user (required with --remote)
#   --install-path <path>      Remote install path (default: /home/<user>/<agent-name>)
#   --ssh-key <path>           SSH key for remote auth (default: ~/.ssh/id_ed25519)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# ── Defaults ──────────────────────────────────────────────────────────────────

AGENT_NAME="${AGENT_NAME:-}"
OWNER_NAME="${OWNER_NAME:-andrii}"
MODEL="${MODEL:-}"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
NEXUS_URL="${NEXUS_URL:-http://100.110.36.84:8900}"
NEXUS_PASSWORD="${NEXUS_PASSWORD:-}"

SKIP_TELEGRAM=0
SKIP_NEXUS=0
SKIP_LOOM=0
NON_INTERACTIVE=0
DRY_RUN=0

REMOTE=0
TARGET_HOST=""
TARGET_USER=""
INSTALL_PATH=""
SSH_KEY="${HOME}/.ssh/id_ed25519"

SYSTEMD_AVAILABLE=1  # assumed true; prereq check may set to 0

# ── Helpers ───────────────────────────────────────────────────────────────────

info() { printf "  [setup] %s\n" "$*"; }
step() { printf "\n── Step %s ──────────────────────────────────────────────────────\n" "$*"; }
warn() { printf "  [WARN]  %s\n" "$*"; }
err()  { printf "  [ERROR] %s\n" "$*" >&2; exit 1; }
ok()   { printf "  [  OK ] %s\n" "$*"; }
dry()  { printf "  [dry]   would run: %s\n" "$*"; }

usage() {
  cat <<'EOF'
install.sh — Unified installer for blank_node agents

Usage (local):
  bash install.sh --agent-name my-agent --owner-name alice
  bash install.sh --non-interactive   # all values from env vars
  bash install.sh --dry-run           # print what would happen, no changes
  bash install.sh --skip-nexus --skip-telegram   # minimal local install

Usage (remote/SSH):
  bash install.sh --remote --target-host 100.78.161.59 --target-user xxx \
    --agent-name orchestrator --owner-name andrii

Flags:
  --agent-name <name>        Required. Lowercase, digits, hyphens, underscores.
  --owner-name <name>        Owner's short name (default: andrii)
  --model <id>               Claude model ID (default: from .example)
  --telegram-token <token>   Telegram bot token  (or env TELEGRAM_TOKEN)
  --telegram-chat-id <id>    Telegram chat ID    (or env TELEGRAM_CHAT_ID)
  --nexus-url <url>          Nexus URL           (or env NEXUS_URL)
  --nexus-password <pw>      Nexus password      (or env NEXUS_PASSWORD)
  --skip-telegram            Skip Telegram credential setup
  --skip-nexus               Skip Nexus registration
  --skip-loom                Skip Loom clone/venv (use existing)
  --non-interactive          Never prompt; read from env; fail on missing
  --dry-run                  Print what would happen; make no changes
  --remote                   Install on a remote host over SSH
  --target-host <host>       Remote host IP or hostname (required with --remote)
  --target-user <user>       Remote SSH user     (required with --remote)
  --install-path <path>      Remote install path (default: /home/<user>/<name>)
  --ssh-key <path>           SSH key             (default: ~/.ssh/id_ed25519)
EOF
}

run() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "$*"
  else
    eval "$@"
  fi
}

run_silent() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "$*"
  else
    eval "$@" >/dev/null 2>&1
  fi
}

prompt_value() {
  local varname="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local current
  current="${!varname:-}"

  if [ -n "$current" ]; then
    return
  fi

  if [ "$NON_INTERACTIVE" = "1" ]; then
    if [ -n "$default" ]; then
      eval "$varname='$default'"
    else
      err "Non-interactive mode: $varname is required but not set"
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

ssh_run() {
  local cmd="$1"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "${TARGET_USER}@${TARGET_HOST}" "$cmd"
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent-name)        AGENT_NAME="$2";        shift 2 ;;
    --owner-name)        OWNER_NAME="$2";         shift 2 ;;
    --model)             MODEL="$2";              shift 2 ;;
    --telegram-token)    TELEGRAM_TOKEN="$2";     shift 2 ;;
    --telegram-chat-id)  TELEGRAM_CHAT_ID="$2";   shift 2 ;;
    --nexus-url)         NEXUS_URL="$2";           shift 2 ;;
    --nexus-password)    NEXUS_PASSWORD="$2";      shift 2 ;;
    --skip-telegram)     SKIP_TELEGRAM=1;          shift ;;
    --skip-nexus)        SKIP_NEXUS=1;             shift ;;
    --skip-loom)         SKIP_LOOM=1;              shift ;;
    --non-interactive)   NON_INTERACTIVE=1;        shift ;;
    --dry-run)           DRY_RUN=1;               shift ;;
    --remote)            REMOTE=1;                 shift ;;
    --target-host)       TARGET_HOST="$2";         shift 2 ;;
    --target-user)       TARGET_USER="$2";         shift 2 ;;
    --install-path)      INSTALL_PATH="$2";        shift 2 ;;
    --ssh-key)           SSH_KEY="$2";             shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) err "Unknown argument: $1 (try --help)" ;;
  esac
done

# ── Remote mode early validation ──────────────────────────────────────────────

if [ "$REMOTE" = "1" ]; then
  [ -z "$TARGET_HOST" ] && err "--remote requires --target-host <host>"
  [ -z "$TARGET_USER" ] && err "--remote requires --target-user <user>"
  [ -z "$SSH_KEY" ]     && err "--ssh-key path is required for --remote"
  [ -f "$SSH_KEY" ]     || err "SSH key not found: $SSH_KEY"
fi

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

step "1: Prerequisites"

if [ "$REMOTE" = "1" ]; then
  info "Checking prerequisites on ${TARGET_USER}@${TARGET_HOST} ..."
  PREREQ_SCRIPT="$(cat <<'REMOTE_EOF'
set -e
PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || { echo "FAIL:python3 not found"; exit 1; }
PY_MAJOR=${PY_VERSION%%.*}; PY_MINOR=${PY_VERSION##*.}
[ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ] || { echo "FAIL:Python 3.10+ required, found $PY_VERSION"; exit 1; }
echo "OK:python3 $PY_VERSION"
command -v git >/dev/null 2>&1 || { echo "FAIL:git not found"; exit 1; }
echo "OK:git $(git --version | awk '{print $3}')"
systemctl --user status >/dev/null 2>&1 && echo "OK:systemd --user" || echo "WARN:systemd --user not available"
command -v claude >/dev/null 2>&1 && echo "OK:claude CLI" || echo "WARN:claude CLI not found — install before first wake"
REMOTE_EOF
)"
  PREREQ_OUTPUT=$(ssh_run "$PREREQ_SCRIPT" 2>&1) || err "Cannot reach ${TARGET_USER}@${TARGET_HOST}"
  while IFS= read -r line; do
    case "$line" in
      OK:*)   ok "${line#OK:}" ;;
      WARN:*) warn "${line#WARN:}"; SYSTEMD_AVAILABLE=0 ;;
      FAIL:*) err "${line#FAIL:}" ;;
    esac
  done <<< "$PREREQ_OUTPUT"
else
  # Local prerequisite check
  PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) \
    || err "python3 not found. Install Python 3.10+ first."
  PY_MAJOR="${PY_VERSION%%.*}"
  PY_MINOR="${PY_VERSION##*.}"
  if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ]; then
    ok "python3 ${PY_VERSION}"
  else
    err "Python 3.10+ required, found ${PY_VERSION}"
  fi

  command -v git >/dev/null 2>&1 \
    && ok "git $(git --version | awk '{print $3}')" \
    || err "git not found. Install git first."

  if systemctl --user status >/dev/null 2>&1; then
    ok "systemd --user"
  else
    warn "systemd --user not available — service installation will be skipped."
    warn "You can still run wake.sh manually: bash scripts/executional/wake.sh"
    SYSTEMD_AVAILABLE=0
  fi

  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI"
  else
    warn "claude CLI not found — install from https://claude.ai/code before first wake"
  fi
fi

# ── Step 2: Configuration ─────────────────────────────────────────────────────

step "2: Configuration"

if [ "$NON_INTERACTIVE" = "0" ] && [ "$DRY_RUN" = "0" ] && [ "$REMOTE" = "0" ]; then
  printf "\n  Configure your agent. Press Enter to accept defaults.\n\n"
fi

prompt_value AGENT_NAME "Agent name (slug, e.g. 'my-agent')" ""
prompt_value OWNER_NAME "Owner name" "andrii"

if [[ ! "$AGENT_NAME" =~ ^[a-z0-9_-]+$ ]]; then
  err "AGENT_NAME must be lowercase letters, digits, hyphens, or underscores only"
fi

if [ "$SKIP_TELEGRAM" = "0" ]; then
  if [ "$NON_INTERACTIVE" = "0" ]; then
    printf "  (Leave Telegram token blank to skip Telegram setup)\n"
  fi
  prompt_value TELEGRAM_TOKEN "Telegram bot token" "" 2>/dev/null || true
  if [ -n "${TELEGRAM_TOKEN:-}" ]; then
    prompt_value TELEGRAM_CHAT_ID "Telegram chat ID (your user ID)" ""
  fi
fi

if [ "$SKIP_NEXUS" = "0" ]; then
  if [ "$NON_INTERACTIVE" = "0" ]; then
    printf "  (Leave Nexus URL blank to skip Nexus setup)\n"
  fi
  prompt_value NEXUS_URL "Nexus URL" "$NEXUS_URL" 2>/dev/null || true
  if [ -n "${NEXUS_URL:-}" ]; then
    prompt_value NEXUS_PASSWORD "Nexus password" ""
  fi
fi

info "Agent name:  ${AGENT_NAME}"
info "Owner name:  ${OWNER_NAME}"
info "Project dir: ${PROJECT_DIR}"
info "Telegram:    $([ -n "${TELEGRAM_TOKEN:-}" ] && echo 'configured' || echo 'skipped')"
info "Nexus:       $([ -n "${NEXUS_URL:-}" ] && echo "${NEXUS_URL}" || echo 'skipped')"

# ── Step 3: Directory scaffold ────────────────────────────────────────────────

step "3: Directory scaffold"

INSTALL_ROOT="$PROJECT_DIR"
if [ "$REMOTE" = "1" ] && [ -z "$INSTALL_PATH" ]; then
  INSTALL_PATH="/home/${TARGET_USER}/${AGENT_NAME}"
fi
[ "$REMOTE" = "1" ] && INSTALL_ROOT="$INSTALL_PATH"

for dir in state logs memory/sessions memory/work identity inbox/files; do
  if [ "$REMOTE" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      dry "mkdir -p ${INSTALL_ROOT}/${dir}"
    else
      ssh_run "mkdir -p '${INSTALL_ROOT}/${dir}'"
      info "Created (remote): ${dir}/"
    fi
  else
    if [ ! -d "${INSTALL_ROOT}/${dir}" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        dry "mkdir -p ${INSTALL_ROOT}/${dir}"
      else
        mkdir -p "${INSTALL_ROOT}/${dir}"
        info "Created: ${dir}/"
      fi
    else
      info "Exists:  ${dir}/"
    fi
  fi
done

# Counter and state files (idempotent)
_init_file() {
  local path="$1" content="$2"
  if [ "$REMOTE" = "1" ]; then
    [ "$DRY_RUN" = "1" ] \
      && dry "[ -f '${path}' ] || echo '${content}' > '${path}'" \
      || ssh_run "[ -f '${path}' ] || echo '${content}' > '${path}'"
  else
    if [ ! -f "${path}" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        dry "echo '${content}' > '${path}'"
      else
        echo "${content}" > "${path}"
        info "Initialized: ${path#$INSTALL_ROOT/}"
      fi
    fi
  fi
}

_init_file "${INSTALL_ROOT}/state/sessions_tonight.count" "0"
_init_file "${INSTALL_ROOT}/state/sessions_emergency.count" "0"
_init_file "${INSTALL_ROOT}/state/sessions_manual.count" "0"
_init_file "${INSTALL_ROOT}/state/sessions_tonight.date" "$(date +%Y-%m-%d)"
_init_file "${INSTALL_ROOT}/state/trigger_mode.txt" "manual"

if [ "$REMOTE" = "1" ]; then
  [ "$DRY_RUN" = "1" ] \
    && dry "[ -f '${INSTALL_ROOT}/inbox/pending.json' ] || echo '[]' > '${INSTALL_ROOT}/inbox/pending.json'" \
    || ssh_run "[ -f '${INSTALL_ROOT}/inbox/pending.json' ] || echo '[]' > '${INSTALL_ROOT}/inbox/pending.json'"
else
  if [ ! -f "${INSTALL_ROOT}/inbox/pending.json" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      dry "echo '[]' > ${INSTALL_ROOT}/inbox/pending.json"
    else
      echo "[]" > "${INSTALL_ROOT}/inbox/pending.json"
      info "Initialized: inbox/pending.json"
    fi
  fi
fi

# ── Step 4: agent_config.env ──────────────────────────────────────────────────

step "4: agent_config.env"

AGENT_CONFIG="${INSTALL_ROOT}/state/agent_config.env"
LOOM_DB="${HOME}/.local/share/loom/${AGENT_NAME}.db"
[ "$REMOTE" = "1" ] && LOOM_DB="/home/${TARGET_USER}/.local/share/loom/${AGENT_NAME}.db"
EXAMPLE_FILE="${PROJECT_DIR}/state/agent_config.env.example"
RESOLVED_MODEL="${MODEL:-claude-sonnet-4-6}"

if [ ! -f "$EXAMPLE_FILE" ]; then
  warn "agent_config.env.example not found at ${EXAMPLE_FILE} — writing minimal config"
  if [ "$DRY_RUN" = "0" ] && [ "$REMOTE" = "0" ]; then
    cat > "$AGENT_CONFIG" << EOF
AGENT_NAME=${AGENT_NAME}
OWNER_NAME=${OWNER_NAME}
NODE_VERSION=${RESOLVED_MODEL}
EXECUTION_TASK_CAP=2
LOOM_DB=${LOOM_DB}
EOF
    info "Written: state/agent_config.env (minimal — example missing)"
  else
    dry "Write minimal state/agent_config.env (AGENT_NAME, OWNER_NAME, NODE_VERSION, LOOM_DB)"
  fi
else
  # Substitute into the example template so no fields are silently dropped.
  # Strategy: sed-replace known placeholder tokens; preserve comment lines and
  # optional settings (DEFAULT_GOAL_ID, AGENT_REPO) as-is with their comments.
  GENERATED_CONFIG="$(sed \
    -e "s|^AGENT_NAME=.*|AGENT_NAME=${AGENT_NAME}|" \
    -e "s|^OWNER_NAME=.*|OWNER_NAME=${OWNER_NAME}|" \
    -e "s|^AGENT_REPO=.*|AGENT_REPO=${AGENT_NAME}-node|" \
    -e "s|^NODE_VERSION=.*|NODE_VERSION=${RESOLVED_MODEL}|" \
    -e "s|^LOOM_DB=.*|LOOM_DB=${LOOM_DB}|" \
    "$EXAMPLE_FILE")"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Write state/agent_config.env (from .example, substituting AGENT_NAME/OWNER_NAME/NODE_VERSION/LOOM_DB)"
  elif [ "$REMOTE" = "1" ]; then
    ssh_run "cat > '${AGENT_CONFIG}'" <<< "$GENERATED_CONFIG"
    info "Written (remote): state/agent_config.env"
  else
    echo "$GENERATED_CONFIG" > "$AGENT_CONFIG"
    info "Written: state/agent_config.env"
    info "  AGENT_REPO set to '${AGENT_NAME}-node' — update if your repo name differs"
    info "  DEFAULT_GOAL_ID: left commented out — uncomment when you have a goal in Loom"
  fi
fi

# ── Steps 5–9: Credentials, Nexus, Loom, systemd, smoke test ─────────────────
# (implemented in subsequent tasks: T436–T440)
step "5–9: Remaining steps (not yet implemented)"
warn "Steps 5–9 are not yet implemented — run scripts/local_setup.sh for the full setup."
warn "Steps done so far: prerequisites ✓  directories ✓  agent_config.env ✓"
exit 0
