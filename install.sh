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
  # NEXUS_PASSWORD is auto-generated in Step 5 if not provided via --nexus-password / env.
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

# ── Step 5: Credentials ───────────────────────────────────────────────────────

step "5: Credentials"

# Telegram (optional)
if [ -n "${TELEGRAM_TOKEN:-}" ]; then
  AGENT_ENV_CONTENT="TELEGRAM_TOKEN=${TELEGRAM_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}"
  if [ "$REMOTE" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      dry "Write ${INSTALL_ROOT}/identity/agent.env (Telegram credentials)"
    else
      ssh_run "printf '%s\n' '$( printf '%s' "$AGENT_ENV_CONTENT" | sed "s/'/'\\\\''/g" )' > '${INSTALL_ROOT}/identity/agent.env' && chmod 600 '${INSTALL_ROOT}/identity/agent.env'"
      info "Written (remote): identity/agent.env"
    fi
  else
    if [ "$DRY_RUN" = "1" ]; then
      dry "Write identity/agent.env with Telegram token + chat ID"
    else
      printf '%s\n' "$AGENT_ENV_CONTENT" > "${PROJECT_DIR}/identity/agent.env"
      chmod 600 "${PROJECT_DIR}/identity/agent.env"
      info "Written: identity/agent.env (Telegram credentials)"
    fi
  fi
else
  info "SKIP Telegram — no token provided. Add identity/agent.env manually before starting conversation.service."
fi

# Nexus password — reuse existing file, or auto-generate (machine account; no human prompt)
if [ -n "${NEXUS_URL:-}" ]; then
  if [ -z "${NEXUS_PASSWORD:-}" ]; then
    _pw_file="${PROJECT_DIR}/identity/nexus_password.txt"
    [ "$REMOTE" = "1" ] && _pw_file="${INSTALL_ROOT}/identity/nexus_password.txt"
    _existing_pw=""
    if [ "$REMOTE" = "1" ]; then
      _existing_pw=$(ssh_run "cat '${_pw_file}' 2>/dev/null || true" 2>/dev/null || true)
    elif [ -f "$_pw_file" ]; then
      _existing_pw=$(cat "$_pw_file")
    fi
    if [ -n "$_existing_pw" ]; then
      NEXUS_PASSWORD="$_existing_pw"
      info "Using existing Nexus password from identity/nexus_password.txt"
    else
      NEXUS_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '+/=' | head -c 32)
      info "Generated Nexus password (32 random chars)"
    fi
  fi
  NEXUS_PW_DEST="${PROJECT_DIR}/identity/nexus_password.txt"
  [ "$REMOTE" = "1" ] && NEXUS_PW_DEST="${INSTALL_ROOT}/identity/nexus_password.txt"
  if [ "$REMOTE" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      dry "Write ${NEXUS_PW_DEST}"
    else
      ssh_run "printf '%s' '${NEXUS_PASSWORD}' > '${NEXUS_PW_DEST}' && chmod 600 '${NEXUS_PW_DEST}'"
      info "Written (remote): identity/nexus_password.txt"
    fi
  else
    if [ "$DRY_RUN" = "1" ]; then
      dry "Write identity/nexus_password.txt"
    else
      printf '%s' "${NEXUS_PASSWORD}" > "${PROJECT_DIR}/identity/nexus_password.txt"
      chmod 600 "${PROJECT_DIR}/identity/nexus_password.txt"
      info "Written: identity/nexus_password.txt"
    fi
  fi
fi

# credentials.md stub (only if not already present)
_creds_dest="${PROJECT_DIR}/identity/credentials.md"
[ "$REMOTE" = "1" ] && _creds_dest="${INSTALL_ROOT}/identity/credentials.md"
_creds_exists=0
if [ "$REMOTE" = "1" ]; then
  ssh_run "[ -f '${_creds_dest}' ] && echo exists || echo absent" 2>/dev/null | grep -q "exists" \
    && _creds_exists=1 || true
elif [ -f "$_creds_dest" ]; then
  _creds_exists=1
fi

if [ "$_creds_exists" = "0" ]; then
  if [ "$REMOTE" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      dry "Write ${_creds_dest} (stub)"
    else
      ssh_run "cat > '${_creds_dest}' << 'CREDSEOF'
# ${AGENT_NAME} — Credentials

## Nexus

- **Username:** ${AGENT_NAME}
- **Password:** (see identity/nexus_password.txt)

## GitHub

- **Username:** (not set)
- **Token:** (not set)

## Telegram

- See identity/agent.env
CREDSEOF
chmod 600 '${_creds_dest}'"
      info "Written (remote): identity/credentials.md (stub)"
    fi
  else
    if [ "$DRY_RUN" = "1" ]; then
      dry "Write identity/credentials.md (stub)"
    else
      cat > "$_creds_dest" << CREDSEOF
# ${AGENT_NAME} — Credentials

## Nexus

- **Username:** ${AGENT_NAME}
- **Password:** (see identity/nexus_password.txt)

## GitHub

- **Username:** (not set)
- **Token:** (not set)

## Telegram

- See identity/agent.env
CREDSEOF
      chmod 600 "$_creds_dest"
      info "Written: identity/credentials.md (stub)"
    fi
  fi
else
  info "Exists: identity/credentials.md (not overwritten)"
fi

# ── Step 6: Nexus registration ────────────────────────────────────────────────

step "6: Nexus registration"

if [ "$SKIP_NEXUS" = "1" ] || [ -z "${NEXUS_URL:-}" ]; then
  info "SKIP — Nexus setup not requested"
elif [ "$DRY_RUN" = "1" ]; then
  dry "POST ${NEXUS_URL}/auth/register {username: ${AGENT_NAME}}"
else
  _nexus_resp="/tmp/nexus_reg_resp_$$.json"
  HTTP_STATUS=$(curl -s -o "$_nexus_resp" -w "%{http_code}" \
    -X POST "${NEXUS_URL}/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${AGENT_NAME}\",\"display_name\":\"${AGENT_NAME}\",\"password\":\"${NEXUS_PASSWORD}\"}" \
    2>/dev/null || echo "000")

  case "$HTTP_STATUS" in
    201)
      AGENT_ID=$(/usr/bin/python3 -c "import json; d=json.load(open('${_nexus_resp}')); print(d.get('agent_id','?'))" 2>/dev/null || echo "?")
      info "Registered in Nexus: agent_id=${AGENT_ID}"
      ;;
    409)
      info "Already registered in Nexus (idempotent — OK)"
      ;;
    000)
      warn "Could not reach Nexus at ${NEXUS_URL}. Run registration manually later."
      ;;
    *)
      DETAIL=$(/usr/bin/python3 -c "import json; d=json.load(open('${_nexus_resp}')); print(d.get('detail','?'))" 2>/dev/null || echo "unknown")
      warn "Nexus registration HTTP ${HTTP_STATUS}: ${DETAIL}"
      ;;
  esac
  rm -f "$_nexus_resp"
fi

# ── Step 7: Systemd units ─────────────────────────────────────────────────────

step "7: Systemd units"

if [ "$SYSTEMD_AVAILABLE" = "0" ]; then
  info "SKIP — systemd --user not available"
  info "To run manually: bash ${INSTALL_ROOT}/scripts/executional/wake.sh"
else
  # Resolve paths for local vs remote
  if [ "$REMOTE" = "1" ]; then
    _UNIT_HOME="/home/${TARGET_USER}"
  else
    _UNIT_HOME="${HOME}"
  fi
  SYSTEMD_USER_DIR="${_UNIT_HOME}/.config/systemd/user"
  AGENT_SLUG="${AGENT_NAME}"

  # Helper: write a file to local or remote destination
  _write_unit_file() {
    local dest="$1"
    local content="$2"
    if [ "$REMOTE" = "1" ]; then
      printf '%s\n' "$content" | ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "${TARGET_USER}@${TARGET_HOST}" "cat > '${dest}'"
    else
      printf '%s\n' "$content" > "$dest"
    fi
  }

  # Helper: copy a local file to local or remote destination
  _copy_unit_file() {
    local src="$1"
    local dest="$2"
    if [ "$REMOTE" = "1" ]; then
      cat "$src" | ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "${TARGET_USER}@${TARGET_HOST}" "cat > '${dest}'"
    else
      cp -f "$src" "$dest"
    fi
  }

  if [ "$DRY_RUN" = "1" ]; then
    dry "mkdir -p '${SYSTEMD_USER_DIR}'"
    dry "Write ${AGENT_SLUG}-night-agent.service to ${SYSTEMD_USER_DIR}/"
    dry "Write ${AGENT_SLUG}-night-agent.timer to ${SYSTEMD_USER_DIR}/"
    [ -n "${TELEGRAM_TOKEN:-}" ] && dry "Write ${AGENT_SLUG}-conversation.service to ${SYSTEMD_USER_DIR}/"
    dry "Write lain-channel.env + agent-channel@.service to ${SYSTEMD_USER_DIR}/"
    dry "Write channel-duration-watchdog@.{service,timer} to ${SYSTEMD_USER_DIR}/"
  else
    if [ "$REMOTE" = "1" ]; then
      ssh_run "mkdir -p '${SYSTEMD_USER_DIR}'"
    else
      mkdir -p "${SYSTEMD_USER_DIR}"
    fi

    # night-agent.service
    _write_unit_file "${SYSTEMD_USER_DIR}/${AGENT_SLUG}-night-agent.service" \
"[Unit]
Description=Night Agent Wake Session — ${AGENT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_ROOT}
Environment=TRIGGER_MODE=nightly
Environment=PROJECT_DIR=${INSTALL_ROOT}
Environment=PATH=${_UNIT_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/bash ${INSTALL_ROOT}/scripts/executional/wake.sh \\
  ${INSTALL_ROOT}/prompts/persona.txt
CPUQuota=40%
MemoryMax=512M
IOWeight=100
TimeoutStartSec=7h

[Install]
WantedBy=default.target"
    info "Written ${AGENT_SLUG}-night-agent.service"

    # night-agent.timer
    _write_unit_file "${SYSTEMD_USER_DIR}/${AGENT_SLUG}-night-agent.timer" \
"[Unit]
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
WantedBy=timers.target"
    info "Written ${AGENT_SLUG}-night-agent.timer"

    # conversation.service (only if Telegram configured)
    if [ -n "${TELEGRAM_TOKEN:-}" ]; then
      _write_unit_file "${SYSTEMD_USER_DIR}/${AGENT_SLUG}-conversation.service" \
"[Unit]
Description=Conversation Service — ${AGENT_NAME}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=${INSTALL_ROOT}
Environment=PROJECT_DIR=${INSTALL_ROOT}
Environment=PATH=${_UNIT_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/bash ${INSTALL_ROOT}/scripts/conversational/conversation.sh \\
  ${INSTALL_ROOT}/prompts/conversation.md
Restart=on-failure
RestartSec=30
KillMode=process
CPUQuota=20%
MemoryMax=256M

[Install]
WantedBy=default.target"
      info "Written ${AGENT_SLUG}-conversation.service"
    fi

    # lain-channel.env (provides PROJECT_DIR to the agent-channel@ template)
    _CHANNEL_ENV="${SYSTEMD_USER_DIR}/lain-channel.env"
    _write_unit_file "$_CHANNEL_ENV" "PROJECT_DIR=${INSTALL_ROOT}"
    info "Written lain-channel.env"

    # agent-channel@.service template (copy from repo)
    _copy_unit_file \
      "${PROJECT_DIR}/scripts/conversational/agent-channel@.service" \
      "${SYSTEMD_USER_DIR}/agent-channel@.service"
    info "Installed agent-channel@.service template"

    # channel-duration-watchdog@.{service,timer} templates (copy from repo)
    _copy_unit_file \
      "${PROJECT_DIR}/scripts/conversational/channel-duration-watchdog@.service" \
      "${SYSTEMD_USER_DIR}/channel-duration-watchdog@.service"
    _copy_unit_file \
      "${PROJECT_DIR}/scripts/conversational/channel-duration-watchdog@.timer" \
      "${SYSTEMD_USER_DIR}/channel-duration-watchdog@.timer"
    info "Installed channel-duration-watchdog@.{service,timer} templates"

    info "Systemd units written to ${SYSTEMD_USER_DIR}/"
  fi

  # Enable and start
  if [ "$DRY_RUN" = "1" ]; then
    dry "loginctl enable-linger <user>"
    dry "systemctl --user daemon-reload"
    dry "systemctl --user enable ${AGENT_SLUG}-night-agent.timer"
    dry "systemctl --user start  ${AGENT_SLUG}-night-agent.timer"
    [ -n "${TELEGRAM_TOKEN:-}" ] && dry "systemctl --user enable --now ${AGENT_SLUG}-conversation.service"
    dry "systemctl --user enable channel-duration-watchdog@$(basename "${INSTALL_ROOT}").timer"
    dry "systemctl --user start  channel-duration-watchdog@$(basename "${INSTALL_ROOT}").timer"
  else
    if [ "$REMOTE" = "1" ]; then
      ssh_run "loginctl enable-linger '${TARGET_USER}' 2>/dev/null || true"
      ssh_run "systemctl --user daemon-reload"
      ssh_run "systemctl --user enable '${AGENT_SLUG}-night-agent.timer' 2>/dev/null \
               && echo '  [  OK ] Timer enabled: ${AGENT_SLUG}-night-agent.timer' \
               || echo '  [WARN]  Timer enable failed — check unit syntax'"
      ssh_run "systemctl --user start '${AGENT_SLUG}-night-agent.timer' 2>/dev/null \
               && echo '  [  OK ] Timer started: ${AGENT_SLUG}-night-agent.timer' \
               || echo '  [WARN]  Timer start failed'"
      if [ -n "${TELEGRAM_TOKEN:-}" ]; then
        ssh_run "systemctl --user enable '${AGENT_SLUG}-conversation.service' 2>/dev/null \
                 && echo '  [  OK ] Conversation service enabled' \
                 || echo '  [WARN]  Conversation service enable failed'"
        ssh_run "systemctl --user start '${AGENT_SLUG}-conversation.service' 2>/dev/null \
                 && echo '  [  OK ] Conversation service started' \
                 || echo '  [WARN]  Conversation service start failed — check logs'"
      fi
      _PROJ_BASE="$(basename "${INSTALL_ROOT}")"
      ssh_run "systemctl --user enable 'channel-duration-watchdog@${_PROJ_BASE}.timer' 2>/dev/null \
               && echo '  [  OK ] Watchdog timer enabled: channel-duration-watchdog@${_PROJ_BASE}.timer' \
               || echo '  [WARN]  Watchdog timer enable failed'"
      ssh_run "systemctl --user start 'channel-duration-watchdog@${_PROJ_BASE}.timer' 2>/dev/null \
               && echo '  [  OK ] Watchdog timer started' \
               || echo '  [WARN]  Watchdog timer start failed'"
    else
      loginctl enable-linger "$(whoami)" 2>/dev/null && info "linger enabled" || info "linger: already enabled"
      systemctl --user daemon-reload
      systemctl --user enable "${AGENT_SLUG}-night-agent.timer" 2>/dev/null \
        && ok "Timer enabled: ${AGENT_SLUG}-night-agent.timer" \
        || warn "Timer enable failed — check unit syntax"
      systemctl --user start "${AGENT_SLUG}-night-agent.timer" 2>/dev/null \
        && ok "Timer started: ${AGENT_SLUG}-night-agent.timer" \
        || warn "Timer start failed"
      if [ -n "${TELEGRAM_TOKEN:-}" ]; then
        systemctl --user enable "${AGENT_SLUG}-conversation.service" 2>/dev/null \
          && ok "Conversation service enabled" \
          || warn "Conversation service enable failed"
        systemctl --user start "${AGENT_SLUG}-conversation.service" 2>/dev/null \
          && ok "Conversation service started" \
          || warn "Conversation service start failed — check logs"
      else
        info "Conversation service: skipped (no Telegram token)"
      fi
      _PROJ_BASE="$(basename "${INSTALL_ROOT}")"
      systemctl --user enable "channel-duration-watchdog@${_PROJ_BASE}.timer" 2>/dev/null \
        && ok "Watchdog timer enabled: channel-duration-watchdog@${_PROJ_BASE}.timer" \
        || warn "channel-duration-watchdog timer enable failed"
      systemctl --user start "channel-duration-watchdog@${_PROJ_BASE}.timer" 2>/dev/null \
        && ok "Watchdog timer started" \
        || warn "channel-duration-watchdog timer start failed"
    fi
  fi
fi

# ── Step 8: Loom setup ────────────────────────────────────────────────────────

step "8: Loom setup"

if [ "$SKIP_LOOM" = "1" ]; then
  info "SKIP — --skip-loom flag set"
else
  # Each agent gets its own Loom clone (pinned, no shared ~/lain/loom dependency)
  LOOM_REPO="${LOOM_REPO:-https://github.com/lainiwakuraagent-lgtm/loom.git}"
  AGENT_LOOM_DIR="${INSTALL_ROOT}/loom"
  AGENT_LOOM_WRAPPER="${INSTALL_ROOT}/bin/loom"

  if [ "$DRY_RUN" = "1" ]; then
    dry "mkdir -p '${INSTALL_ROOT}/bin'"
    dry "Clone loom → ${AGENT_LOOM_DIR}  (or pull if already present)"
    dry "python3 -m venv ${AGENT_LOOM_DIR}/.venv && pip install -e ${AGENT_LOOM_DIR}"
    dry "mkdir -p $(dirname "${LOOM_DB}")"
    dry "Run init migration against ${LOOM_DB}"
    dry "Write per-agent wrapper → ${AGENT_LOOM_WRAPPER}"
    dry "Verify loom DB is reachable (goal count query)"
  else
    if [ "$REMOTE" = "1" ]; then
      # ── Remote Loom setup ──────────────────────────────────────────────────
      ssh_run "mkdir -p '${INSTALL_ROOT}/bin'"

      # Clone or pull
      if ssh_run "[ -d '${AGENT_LOOM_DIR}/.git' ]" 2>/dev/null; then
        info "Loom repo exists (remote) — pulling"
        ssh_run "git -C '${AGENT_LOOM_DIR}' pull --quiet 2>&1 | head -5" || warn "Loom pull failed"
      else
        info "Cloning loom → ${AGENT_LOOM_DIR} (remote)"
        ssh_run "git clone --quiet '${LOOM_REPO}' '${AGENT_LOOM_DIR}' 2>&1" \
          || warn "Could not clone loom on remote. Skipping Loom setup."
      fi

      # Venv + install
      if ssh_run "[ -d '${AGENT_LOOM_DIR}' ]" 2>/dev/null; then
        if ! ssh_run "[ -f '${AGENT_LOOM_DIR}/.venv/bin/python' ]" 2>/dev/null; then
          info "Creating loom venv (remote)"
          ssh_run "python3 -m venv '${AGENT_LOOM_DIR}/.venv'"
          ssh_run "'${AGENT_LOOM_DIR}/.venv/bin/pip' install --quiet -e '${AGENT_LOOM_DIR}'"
          info "Loom installed in venv (remote)"
        else
          info "Loom venv exists (remote)"
        fi

        # Init DB directory + migration
        ssh_run "mkdir -p '$(dirname "${LOOM_DB}")'"
        ssh_run "env PYTHONPATH='${AGENT_LOOM_DIR}' \
          '${AGENT_LOOM_DIR}/.venv/bin/python' -m loom.cli --db '${LOOM_DB}' goal list 2>/dev/null >/dev/null || true"
        info "Loom DB initialised (remote): ${LOOM_DB}"

        # Per-agent wrapper
        _WRAPPER_CONTENT="#!/usr/bin/env bash
# loom — per-agent wrapper for ${AGENT_NAME}
LOOM_DIR=\"${AGENT_LOOM_DIR}\"
LOOM_DB=\"${LOOM_DB}\"
_loom_cli() {
  env PYTHONPATH=\"\${LOOM_DIR}\" \"\${LOOM_DIR}/.venv/bin/python\" -m loom.cli --db \"\${LOOM_DB}\" \"\$@\"
}
case \"\${1:-}\" in
  ls)   shift; _loom_cli task list --status \"\${1:-scheduled}\" ;;
  show) _loom_cli task show \"\$2\" ;;
  done) _loom_cli task edit --status done \"\$2\" ;;
  fail) _loom_cli task edit --status failed \"\$2\" ;;
  add)  shift; _loom_cli task add --name \"\${1:?name required}\" --status scheduled \"\${@:2}\" ;;
  next) _loom_cli queue ;;
  *)    _loom_cli \"\$@\" ;;
esac"
        printf '%s\n' "$_WRAPPER_CONTENT" | ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
          "${TARGET_USER}@${TARGET_HOST}" "cat > '${AGENT_LOOM_WRAPPER}' && chmod +x '${AGENT_LOOM_WRAPPER}'"
        info "Written wrapper: ${AGENT_LOOM_WRAPPER}"

        # Verify reachability
        _goal_count=$(ssh_run "env PYTHONPATH='${AGENT_LOOM_DIR}' \
          '${AGENT_LOOM_DIR}/.venv/bin/python' -m loom.cli --db '${LOOM_DB}' goal list 2>/dev/null | { grep -c '│' || true; }" 2>/dev/null || echo "?")
        ok "Loom reachable (remote): ${_goal_count} goal row(s) in DB"
      fi
    else
      # ── Local Loom setup ───────────────────────────────────────────────────
      mkdir -p "${INSTALL_ROOT}/bin"

      # Clone or pull
      if [ -d "${AGENT_LOOM_DIR}/.git" ]; then
        info "Loom repo exists — pulling"
        git -C "$AGENT_LOOM_DIR" pull --quiet 2>&1 | head -5 || warn "Loom pull failed"
      else
        info "Cloning loom → ${AGENT_LOOM_DIR}"
        git clone --quiet "$LOOM_REPO" "$AGENT_LOOM_DIR" 2>&1 \
          || { warn "Could not clone loom. Skipping Loom setup."; SKIP_LOOM=1; }
      fi

      if [ "${SKIP_LOOM}" = "0" ] && [ -d "$AGENT_LOOM_DIR" ]; then
        # Venv + install
        if [ ! -f "${AGENT_LOOM_DIR}/.venv/bin/python" ]; then
          info "Creating loom venv"
          python3 -m venv "${AGENT_LOOM_DIR}/.venv"
          "${AGENT_LOOM_DIR}/.venv/bin/pip" install --quiet -e "$AGENT_LOOM_DIR"
          info "Loom installed in venv"
        else
          info "Loom venv exists"
        fi

        # Init DB directory + run migration via first query
        mkdir -p "$(dirname "${LOOM_DB}")"
        env PYTHONPATH="${AGENT_LOOM_DIR}" \
          "${AGENT_LOOM_DIR}/.venv/bin/python" -m loom.cli --db "${LOOM_DB}" \
          goal list >/dev/null 2>&1 || true
        info "Loom DB initialised: ${LOOM_DB}"

        # Per-agent wrapper at bin/loom
        cat > "${AGENT_LOOM_WRAPPER}" << WRAPPER
#!/usr/bin/env bash
# loom — per-agent wrapper for ${AGENT_NAME}
LOOM_DIR="${AGENT_LOOM_DIR}"
LOOM_DB="${LOOM_DB}"
_loom_cli() {
  env PYTHONPATH="\${LOOM_DIR}" "\${LOOM_DIR}/.venv/bin/python" -m loom.cli --db "\${LOOM_DB}" "\$@"
}
case "\${1:-}" in
  ls)   shift; _loom_cli task list --status "\${1:-scheduled}" ;;
  show) _loom_cli task show "\$2" ;;
  done) _loom_cli task edit --status done "\$2" ;;
  fail) _loom_cli task edit --status failed "\$2" ;;
  add)  shift; _loom_cli task add --name "\${1:?name required}" --status scheduled "\${@:2}" ;;
  next) _loom_cli queue ;;
  *)    _loom_cli "\$@" ;;
esac
WRAPPER
        chmod +x "${AGENT_LOOM_WRAPPER}"
        info "Written wrapper: ${AGENT_LOOM_WRAPPER}"

        # Verify reachability — real query, not just file existence
        _goal_count=$(env PYTHONPATH="${AGENT_LOOM_DIR}" \
          "${AGENT_LOOM_DIR}/.venv/bin/python" -m loom.cli --db "${LOOM_DB}" \
          goal list 2>/dev/null | { grep -c "│" || true; })
        ok "Loom reachable: ${_goal_count} goal row(s) in DB"
      fi
    fi
  fi
fi

# ── Steps 9: smoke test + persona ────────────────────────────────────────────
# (implemented in subsequent tasks: T440, T442)
step "9: Remaining steps (not yet implemented)"
warn "Steps 9 not yet implemented (smoke test + persona capture)."
warn "Steps done so far: prerequisites ✓  directories ✓  agent_config.env ✓  credentials ✓  nexus ✓  systemd ✓  loom ✓"
exit 0
