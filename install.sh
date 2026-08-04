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
#   --skip-khal                Skip khal calendar setup
#   --skip-honcho              Skip Honcho memory client configuration
#   --non-interactive          Never prompt; read from env vars; fail on missing required values
#   --dry-run                  Print what would happen; make no changes
#   --remote                   Install on a remote host over SSH
#   --target-host <host>       Remote host IP or hostname (required with --remote)
#   --target-user <user>       Remote SSH user (required with --remote)
#   --install-path <path>      Remote install path (default: /home/<user>/lain/<agent-name>)
#   --github-pat <pat>         GitHub PAT for private repo clone (auto-read from identity/credentials.md)
#   --ssh-key <path>           SSH key for remote auth (default: ~/.ssh/id_ed25519)
#   --i-know-this-is-the-template  Bypass the guard against installing locally
#                               into the blank_node template checkout itself.
#                               For testing, prefer scripts/dev/test_install.sh.

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
SKIP_KHAL=0
SKIP_HONCHO=0
NON_INTERACTIVE=0
DRY_RUN=0
I_KNOW_THIS_IS_THE_TEMPLATE=0

REMOTE=0
TARGET_HOST=""
TARGET_USER=""
INSTALL_PATH=""
SSH_KEY="${HOME}/.ssh/id_ed25519"
GITHUB_PAT=""

BLANK_NODE_REPO="https://github.com/lainiwakuraagent-lgtm/node.git"
LOOM_REPO="https://github.com/lainiwakuraagent-lgtm/loom.git"

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
  --skip-khal                Skip khal calendar setup
  --skip-honcho              Skip Honcho memory client configuration
  --non-interactive          Never prompt; read from env; fail on missing
  --dry-run                  Print what would happen; make no changes
  --remote                   Install on a remote host over SSH
  --target-host <host>       Remote host IP or hostname (required with --remote)
  --target-user <user>       Remote SSH user     (required with --remote)
  --install-path <path>      Remote install path (default: /home/<user>/lain/<name>)
  --github-pat <pat>         GitHub PAT for private clone (auto-read from identity/credentials.md)
  --ssh-key <path>           SSH key             (default: ~/.ssh/id_ed25519)
  --i-know-this-is-the-template  Bypass the guard against installing locally
                              into the blank_node template checkout itself.
                              For testing, prefer scripts/dev/test_install.sh.
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
  local required="${4:-required}"
  local current
  current="${!varname:-}"

  if [ -n "$current" ]; then
    return
  fi

  if [ "$NON_INTERACTIVE" = "1" ]; then
    if [ -n "$default" ]; then
      eval "$varname='$default'"
    elif [ "$required" = "optional" ]; then
      : # leave empty -- caller treats empty as "not configured", not an error
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

SSH_OPTS="-i ${SSH_KEY} -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

ssh_run() {
  local cmd="$1"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "$cmd"
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
    --skip-khal)         SKIP_KHAL=1;              shift ;;
    --skip-honcho)       SKIP_HONCHO=1;            shift ;;
    --non-interactive)   NON_INTERACTIVE=1;        shift ;;
    --dry-run)           DRY_RUN=1;               shift ;;
    --remote)            REMOTE=1;                 shift ;;
    --target-host)       TARGET_HOST="$2";         shift 2 ;;
    --target-user)       TARGET_USER="$2";         shift 2 ;;
    --install-path)      INSTALL_PATH="$2";        shift 2 ;;
    --ssh-key)           SSH_KEY="$2";             shift 2 ;;
    --github-pat)        GITHUB_PAT="$2";          shift 2 ;;
    --i-know-this-is-the-template) I_KNOW_THIS_IS_THE_TEMPLATE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) err "Unknown argument: $1 (try --help)" ;;
  esac
done

# ── Guard: refuse a local install that would provision the blank_node ─────────
# template itself in place. This is exactly how the T438/T440 test debris
# (stray systemd timers, an overwritten state/agent_config.env, orphaned Loom
# DBs) accumulated in the past — install.sh was run locally, which always
# installs into wherever it physically lives, so testing it in the template
# checkout made the template itself a live agent instance. Local installs
# have no --install-path of their own (only --remote does), so there is no
# other structural way to catch this. Detected via the git origin remote
# rather than a hardcoded path, so it still works if the template checkout
# is renamed or relocated. For real testing, use scripts/dev/test_install.sh,
# which clones to a disposable directory and cleans up unconditionally.
if [ "$REMOTE" = "0" ] && [ "${I_KNOW_THIS_IS_THE_TEMPLATE:-0}" != "1" ]; then
  _origin_url="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$_origin_url" == *"lainiwakuraagent-lgtm/node"* ]]; then
    err "Refusing to install locally into the blank_node template itself ($PROJECT_DIR).
       Use scripts/dev/test_install.sh for a disposable test instance instead.
       If you genuinely intend to make this template checkout a live agent,
       rerun with --i-know-this-is-the-template."
  fi
  unset _origin_url
fi

# ── Remote mode early validation ──────────────────────────────────────────────

if [ "$REMOTE" = "1" ]; then
  [ -z "$TARGET_HOST" ] && err "--remote requires --target-host <host>"
  [ -z "$TARGET_USER" ] && err "--remote requires --target-user <user>"
  [ -z "$SSH_KEY" ]     && err "--ssh-key path is required for --remote"
  [ -f "$SSH_KEY" ]     || err "SSH key not found: $SSH_KEY"

  # Rebuild SSH_OPTS with confirmed key path (may differ from default)
  SSH_OPTS="-i ${SSH_KEY} -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

  # Auto-read GitHub PAT from local credentials.md if not passed via --github-pat
  if [ -z "$GITHUB_PAT" ]; then
    _local_creds="${PROJECT_DIR}/identity/credentials.md"
    if [ -f "$_local_creds" ]; then
      GITHUB_PAT=$(grep -A2 "Token:" "$_local_creds" 2>/dev/null \
        | grep -oP 'ghp_\w+' | head -1 || true)
      [ -n "$GITHUB_PAT" ] && info "GitHub PAT read from identity/credentials.md"
    fi
  fi

  # Build authenticated clone URLs
  if [ -n "$GITHUB_PAT" ]; then
    CLONE_URL="https://lainiwakuraagent-lgtm:${GITHUB_PAT}@github.com/lainiwakuraagent-lgtm/node.git"
    LOOM_CLONE_URL="https://lainiwakuraagent-lgtm:${GITHUB_PAT}@github.com/lainiwakuraagent-lgtm/loom.git"
  else
    CLONE_URL="$BLANK_NODE_REPO"
    LOOM_CLONE_URL="$LOOM_REPO"
    warn "No --github-pat provided — clone may fail if repos are private"
  fi

  # Pre-flight SSH connectivity check (fail fast, before any real work)
  if [ "$DRY_RUN" = "0" ]; then
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" 'echo ok' >/dev/null 2>&1; then
      err "Cannot reach ${TARGET_USER}@${TARGET_HOST} via SSH (key: ${SSH_KEY})\nCheck Tailscale: tailscale status | grep ${TARGET_HOST}"
    fi
    info "SSH OK: ${TARGET_USER}@${TARGET_HOST}"
  fi
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
  prompt_value TELEGRAM_TOKEN "Telegram bot token" "" optional
  if [ -n "${TELEGRAM_TOKEN:-}" ]; then
    prompt_value TELEGRAM_CHAT_ID "Telegram chat ID (your user ID)" ""
  fi
fi

if [ "$SKIP_NEXUS" = "0" ]; then
  if [ "$NON_INTERACTIVE" = "0" ]; then
    printf "  (Leave Nexus URL blank to skip Nexus setup)\n"
  fi
  prompt_value NEXUS_URL "Nexus URL" "$NEXUS_URL" optional
  # NEXUS_PASSWORD is auto-generated in Step 5 if not provided via --nexus-password / env.
fi

info "Agent name:  ${AGENT_NAME}"
info "Owner name:  ${OWNER_NAME}"
info "Project dir: ${PROJECT_DIR}"
info "Telegram:    $([ -n "${TELEGRAM_TOKEN:-}" ] && echo 'configured' || echo 'skipped')"
info "Nexus:       $([ -n "${NEXUS_URL:-}" ] && echo "${NEXUS_URL}" || echo 'skipped')"

# Resolve INSTALL_ROOT early (needed by Step 2b clone and all subsequent steps)
INSTALL_ROOT="$PROJECT_DIR"
if [ "$REMOTE" = "1" ] && [ -z "$INSTALL_PATH" ]; then
  INSTALL_PATH="/home/${TARGET_USER}/lain/${AGENT_NAME}"
fi
[ "$REMOTE" = "1" ] && INSTALL_ROOT="$INSTALL_PATH"

info "Install root: ${INSTALL_ROOT}"

# ── Step 2b: Clone/pull blank_node repo on remote ────────────────────────────
# (local mode: already running from the repo — skip)

if [ "$REMOTE" = "1" ]; then
  step "2b: Clone/pull blank_node on ${TARGET_USER}@${TARGET_HOST}"
  if [ "$DRY_RUN" = "1" ]; then
    dry "git clone/pull ${CLONE_URL} → ${INSTALL_ROOT}"
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "bash -s" << CLONE_SCRIPT
set -euo pipefail
INSTALL_ROOT="${INSTALL_ROOT}"
CLONE_URL="${CLONE_URL}"

if [ -d "\${INSTALL_ROOT}/.git" ]; then
  echo "  Repo exists — pulling latest"
  git -C "\${INSTALL_ROOT}" pull --quiet 2>&1 \
    | sed 's|https://[^@]*@|https://[PAT]@|g' || true
  echo "  git pull OK"
else
  echo "  Cloning → \${INSTALL_ROOT}"
  mkdir -p "\$(dirname "\${INSTALL_ROOT}")"
  git clone --quiet "\${CLONE_URL}" "\${INSTALL_ROOT}" 2>&1 \
    | sed 's|https://[^@]*@|https://[PAT]@|g'
  echo "  git clone OK"
fi
CLONE_SCRIPT
    info "Repository ready on remote: ${INSTALL_ROOT}"
  fi
fi

# ── Step 3: Directory scaffold ────────────────────────────────────────────────

step "3: Directory scaffold"

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

# This step regenerates agent_config.env unconditionally on every install.sh
# run (re-runs are how Telegram creds / other steps get added later), which
# would otherwise silently drop an already-set DEFAULT_GOAL_ID — including
# the one Step 8 sets automatically. Capture it now, restore it after write.
_prior_default_goal_id=""
if [ "$REMOTE" = "1" ]; then
  _prior_default_goal_id=$(ssh_run "grep -E '^DEFAULT_GOAL_ID=' '${AGENT_CONFIG}' 2>/dev/null | tail -1" 2>/dev/null || echo "")
elif [ -f "$AGENT_CONFIG" ]; then
  _prior_default_goal_id=$(grep -E '^DEFAULT_GOAL_ID=' "$AGENT_CONFIG" 2>/dev/null | tail -1 || echo "")
fi

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
    [ -n "$_prior_default_goal_id" ] && dry "Restore existing ${_prior_default_goal_id} after regeneration"
  elif [ "$REMOTE" = "1" ]; then
    ssh_run "cat > '${AGENT_CONFIG}'" <<< "$GENERATED_CONFIG"
    info "Written (remote): state/agent_config.env"
    if [ -n "$_prior_default_goal_id" ]; then
      ssh_run "sed -i 's|^# DEFAULT_GOAL_ID=.*|${_prior_default_goal_id}|' '${AGENT_CONFIG}'"
      info "  DEFAULT_GOAL_ID preserved from previous install (remote): ${_prior_default_goal_id#DEFAULT_GOAL_ID=}"
    fi
  else
    echo "$GENERATED_CONFIG" > "$AGENT_CONFIG"
    info "Written: state/agent_config.env"
    info "  AGENT_REPO set to '${AGENT_NAME}-node' — update if your repo name differs"
    if [ -n "$_prior_default_goal_id" ]; then
      sed -i "s|^# DEFAULT_GOAL_ID=.*|${_prior_default_goal_id}|" "$AGENT_CONFIG"
      info "  DEFAULT_GOAL_ID preserved from previous install: ${_prior_default_goal_id#DEFAULT_GOAL_ID=}"
    elif [ "$SKIP_LOOM" = "1" ]; then
      info "  DEFAULT_GOAL_ID: left commented out (--skip-loom) — uncomment once a goal exists"
    else
      info "  DEFAULT_GOAL_ID: left commented out here — Step 8 (Loom setup) auto-creates a standing Onboarding goal and sets it"
    fi
  fi
fi

# ── Step 4b: Persona ──────────────────────────────────────────────────────────

step "4b: Persona"

PERSONA_NAME="${PERSONA_NAME:-}"
PERSONA_BACKGROUND="${PERSONA_BACKGROUND:-}"
PERSONA_DESCRIPTION="${PERSONA_DESCRIPTION:-}"
PERSONA_FILE="${INSTALL_ROOT}/prompts/persona.txt"

_persona_exists=0
if [ "$REMOTE" = "1" ]; then
  ssh_run "[ -f '${PERSONA_FILE}' ]" 2>/dev/null && _persona_exists=1 || true
elif [ -f "$PERSONA_FILE" ]; then
  _persona_exists=1
fi

if [ "$_persona_exists" = "1" ]; then
  info "Exists: prompts/persona.txt (not overwritten)"
else
  prompt_value PERSONA_NAME "Agent persona name" "@${AGENT_NAME}"
  prompt_value PERSONA_BACKGROUND \
    "Agent background (one line)" \
    "Autonomous agent built on the blank_node harness."
  prompt_value PERSONA_DESCRIPTION \
    "Core traits / character description (one line)" \
    "- Task-focused. Precise. Clear."

  _persona_content="NAME: ${PERSONA_NAME}

BACKGROUND: ${PERSONA_BACKGROUND}

CORE TRAITS:
${PERSONA_DESCRIPTION}

STYLE: Direct. Clear. One kaomoji when mood warrants it."

  if [ "$DRY_RUN" = "1" ]; then
    dry "Write prompts/persona.txt (NAME=${PERSONA_NAME})"
  elif [ "$REMOTE" = "1" ]; then
    ssh_run "cat > '${PERSONA_FILE}'" <<< "$_persona_content"
    info "Written (remote): prompts/persona.txt"
  else
    printf '%s\n' "$_persona_content" > "$PERSONA_FILE"
    info "Written: prompts/persona.txt"
    info "  Edit prompts/persona.txt to refine the agent's voice before first run."
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

  # nexus_watcher.py (runtime channel spawning) reads a *different* file in a
  # *different* format than the plain nexus_password.txt above: a seed-list
  # at identity/nexus_seed_passwords.txt, one line per agent as
  # "# <username> <password>", keyed by NEXUS_USERNAME (defaults to
  # AGENT_NAME's value at runtime). Without this, nexus_watcher.py fails to
  # authenticate and exits on every restart even though registration
  # succeeded — a real gap, not a Docker-specific one; only ever unnoticed
  # because nothing previously exercised install.sh -> nexus_watcher.py
  # end-to-end on a fresh agent.
  NEXUS_SEED_DEST="${PROJECT_DIR}/identity/nexus_seed_passwords.txt"
  [ "$REMOTE" = "1" ] && NEXUS_SEED_DEST="${INSTALL_ROOT}/identity/nexus_seed_passwords.txt"
  if [ "$DRY_RUN" = "1" ]; then
    dry "Write/update ${NEXUS_SEED_DEST} with '# ${AGENT_NAME} <password>'"
  elif [ "$REMOTE" = "1" ]; then
    ssh_run "touch '${NEXUS_SEED_DEST}' \
      && grep -v '^# ${AGENT_NAME} ' '${NEXUS_SEED_DEST}' > '${NEXUS_SEED_DEST}.tmp' 2>/dev/null; \
      echo '# ${AGENT_NAME} ${NEXUS_PASSWORD}' >> '${NEXUS_SEED_DEST}.tmp' \
      && mv '${NEXUS_SEED_DEST}.tmp' '${NEXUS_SEED_DEST}' && chmod 600 '${NEXUS_SEED_DEST}'"
    info "Written (remote): identity/nexus_seed_passwords.txt"
  else
    touch "$NEXUS_SEED_DEST"
    grep -v "^# ${AGENT_NAME} " "$NEXUS_SEED_DEST" > "${NEXUS_SEED_DEST}.tmp" 2>/dev/null || true
    echo "# ${AGENT_NAME} ${NEXUS_PASSWORD}" >> "${NEXUS_SEED_DEST}.tmp"
    mv "${NEXUS_SEED_DEST}.tmp" "$NEXUS_SEED_DEST"
    chmod 600 "$NEXUS_SEED_DEST"
    info "Written: identity/nexus_seed_passwords.txt (nexus_watcher.py's expected format)"
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
    --connect-timeout 10 --max-time 20 \
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

# ── Step 6b: Honcho configuration ────────────────────────────────────────────

step "6b: Honcho memory client (optional)"

if [ "$SKIP_HONCHO" = "1" ]; then
  info "SKIP — --skip-honcho flag set"
else
  _honcho_url=""
  _honcho_workspace=""

  if [ "$NON_INTERACTIVE" = "1" ]; then
    _honcho_url="${HONCHO_URL:-}"
    _honcho_workspace="${HONCHO_WORKSPACE:-}"
  elif [ "$DRY_RUN" = "1" ]; then
    dry "Prompt for HONCHO_URL and HONCHO_WORKSPACE; write to state/agent_config.env"
  else
    printf "  Honcho server URL (leave blank to skip): "
    read -r _honcho_url
    if [ -n "$_honcho_url" ]; then
      printf "  Honcho workspace ID [%s]: " "${AGENT_NAME}-workspace"
      read -r _honcho_workspace
      [ -z "$_honcho_workspace" ] && _honcho_workspace="${AGENT_NAME}-workspace"
    fi
  fi

  if [ -n "$_honcho_url" ] && [ "$DRY_RUN" = "0" ]; then
    _env_file="${INSTALL_ROOT}/state/agent_config.env"
    if [ "$REMOTE" = "1" ]; then
      # Append to remote agent_config.env if not already set
      ssh_run "grep -q '^HONCHO_URL=' '${_env_file}' 2>/dev/null || echo 'HONCHO_URL=${_honcho_url}' >> '${_env_file}'"
      ssh_run "grep -q '^HONCHO_WORKSPACE=' '${_env_file}' 2>/dev/null || echo 'HONCHO_WORKSPACE=${_honcho_workspace}' >> '${_env_file}'"
    else
      grep -q "^HONCHO_URL=" "${_env_file}" 2>/dev/null \
        || printf 'HONCHO_URL=%s\n' "$_honcho_url" >> "${_env_file}"
      grep -q "^HONCHO_WORKSPACE=" "${_env_file}" 2>/dev/null \
        || printf 'HONCHO_WORKSPACE=%s\n' "$_honcho_workspace" >> "${_env_file}"
    fi
    ok "Honcho configured: ${_honcho_url} (workspace: ${_honcho_workspace})"
    info "Test connectivity after install:"
    info "  /usr/bin/python3 ${INSTALL_ROOT}/tools/conversational/honcho_client.py --test-read <peer>"
  elif [ -z "$_honcho_url" ] && [ "$DRY_RUN" = "0" ]; then
    info "Skipped — no Honcho URL provided. Configure later:"
    info "  echo 'HONCHO_URL=http://...' >> state/agent_config.env"
    info "  echo 'HONCHO_WORKSPACE=my-workspace' >> state/agent_config.env"
  fi
fi

# ── Step 7: Systemd units ─────────────────────────────────────────────────────

step "7: Systemd units"

if [ "$SYSTEMD_AVAILABLE" = "0" ]; then
  info "SKIP — systemd --user not available"
  info "Docker/supervisord deployments: no action needed — scheduling and services"
  info "are already handled by scripts/docker/supervisord.conf's static programs"
  info "(conversation, nexus-watcher, scheduler, channel-watchdog)."
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

  # Helper: copy a file to local or remote destination.
  # Remote: derive the remote src path from the local path (repo was cloned to INSTALL_ROOT).
  _copy_unit_file() {
    local src="$1"
    local dest="$2"
    if [ "$REMOTE" = "1" ]; then
      local remote_src="${INSTALL_ROOT}${src#$PROJECT_DIR}"
      ssh_run "cp -f '${remote_src}' '${dest}'"
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
TimeoutStartSec=7h
TimeoutStopSec=120
CPUQuota=40%
MemoryHigh=1G
MemoryMax=1536M
IOWeight=100

[Install]
WantedBy=default.target"
    info "Written ${AGENT_SLUG}-night-agent.service"

    # night-agent.timer — OnCalendar lines generated from config/session_schedule.json (seam A).
    # For remote installs the schedule is read from the local PROJECT_DIR (the source template);
    # the remote host's own schedule may diverge post-install, but that is expected — install.sh
    # only writes the initial unit, not subsequent schedule changes.
    _SCHEDULE_SRC="${PROJECT_DIR}/config/session_schedule.json"
    _ONCALENDAR_LINES=$(python3 - "$_SCHEDULE_SRC" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        s = json.load(f)
except Exception as e:
    sys.stderr.write(f"WARNING: cannot read {path}: {e}\nFalling back to hardcoded schedule.\n")
    # Hardcoded fallback matches the historical template values.
    for t in ["23:00","01:10","02:25","03:40","04:05","04:30","04:55"]:
        h, m = t.split(':')
        print(f"OnCalendar=*-*-* {int(h):02d}:{int(m):02d}:00")
    sys.exit(0)
seen = set()
for w in s.get("windows", []):
    if not w.get("enabled", True):
        continue
    for t in w.get("triggers", []):
        if t in seen:
            continue
        seen.add(t)
        h, m = t.split(":")
        print(f"OnCalendar=*-*-* {int(h):02d}:{int(m):02d}:00")
PYEOF
)
    _write_unit_file "${SYSTEMD_USER_DIR}/${AGENT_SLUG}-night-agent.timer" \
"[Unit]
Description=Night Agent Timer — ${AGENT_NAME}
Requires=${AGENT_SLUG}-night-agent.service

[Timer]
${_ONCALENDAR_LINES}
# Hourly probe: lets one_off[] entries (custom windows synced from khal) fire
# outside fixed nightly windows. check_window.py's Gate 2 rejects most of
# these quickly; on a normal night the overhead is negligible.
OnCalendar=*-*-* *:15:00
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
CPUQuota=20%
MemoryHigh=512M
MemoryMax=1G

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
  # Use PAT-authenticated URL for remote if available (set in early-validation block)
  _LOOM_CLONE_URL="${LOOM_CLONE_URL:-$LOOM_REPO}"
  AGENT_LOOM_DIR="${INSTALL_ROOT}/loom"
  AGENT_LOOM_WRAPPER="${INSTALL_ROOT}/bin/loom"

  # Standing onboarding goal, created only when the DB has zero goals (a re-run
  # against an existing DB must not clobber a goal the agent or owner already
  # set up). Reached only once nothing else is eligible in resolve_session_type.py's
  # priority chain (no goal/project/task queue state, no pending inbox, maintenance
  # not due) — so landing here means no peer/orchestrator assignment (which would
  # arrive as an inbox verified_task entry and become a ready Loom task automatically,
  # ahead of this goal) and no other direction has surfaced yet. One line, no embedded
  # newlines, so it survives both direct and ssh-quoted invocation below unchanged.
  _onboard_desc="Standing onboarding goal, auto-created by install.sh and set as DEFAULT_GOAL_ID -- reached only when Loom has no scheduled/in-progress goal, project, or ready task, no pending inbox entry, and maintenance isn't due (see resolve_session_type.py's priority chain). If a peer or orchestrator ever assigns real work via an inbox verified_task entry, it becomes a ready Loom task automatically and this goal is never reached -- so landing here means nothing has arrived yet. This is not generic identity philosophy: read prompts/persona.txt for any purpose hint the owner gave at install time (treat it as a hypothesis, not a settled answer), note explicitly in session notes or an inbox context_update that you are unassigned and awaiting direction if an owner is configured, and then genuinely investigate what you are for -- your name, your persona, who deployed you and why -- writing a specific, sharpening-over-time hypothesis rather than open-ended musing. Replace this goal entirely once a real purpose is established, from any of those sources."

  if [ "$DRY_RUN" = "1" ]; then
    dry "mkdir -p '${INSTALL_ROOT}/bin'"
    dry "Clone loom → ${AGENT_LOOM_DIR}  (or pull if already present)"
    dry "python3 -m venv ${AGENT_LOOM_DIR}/.venv && pip install -e ${AGENT_LOOM_DIR}"
    dry "mkdir -p $(dirname "${LOOM_DB}")"
    dry "Run init migration against ${LOOM_DB}"
    dry "Write per-agent wrapper → ${AGENT_LOOM_WRAPPER}"
    dry "Verify loom DB is reachable (goal count query)"
    dry "If DB has zero goals: create standing 'Onboarding' goal, set DEFAULT_GOAL_ID"
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
        ssh_run "git clone --quiet '${_LOOM_CLONE_URL}' '${AGENT_LOOM_DIR}' 2>&1 \
          | sed 's|https://[^@]*@|https://[PAT]@|g'" \
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

        # Standing onboarding goal (remote) — only when the DB is empty
        if [ "${_goal_count}" = "0" ]; then
          printf '%s' "$_onboard_desc" | \
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            "${TARGET_USER}@${TARGET_HOST}" "cat > '/tmp/${AGENT_NAME}_onboard_desc.txt'"
          _onboard_out=$(ssh_run "env PYTHONPATH='${AGENT_LOOM_DIR}' \
            '${AGENT_LOOM_DIR}/.venv/bin/python' -m loom.cli --db '${LOOM_DB}' \
            goal add -n Onboarding -d \"\$(cat '/tmp/${AGENT_NAME}_onboard_desc.txt')\" -s scheduled -p 5 2>&1; \
            rm -f '/tmp/${AGENT_NAME}_onboard_desc.txt'" 2>/dev/null || echo "")
          _onboard_id=$(printf '%s' "$_onboard_out" | grep -oE 'Created goal [0-9]+' | grep -oE '[0-9]+')
          if [ -n "$_onboard_id" ]; then
            ssh_run "sed -i 's|^# DEFAULT_GOAL_ID=.*|DEFAULT_GOAL_ID=${_onboard_id}|' '${AGENT_CONFIG}'"
            ok "Onboarding goal created (remote, id ${_onboard_id}) — DEFAULT_GOAL_ID set"
          else
            warn "Onboarding goal creation failed (remote) — DEFAULT_GOAL_ID left unset: ${_onboard_out}"
          fi
        else
          info "Loom DB already has ${_goal_count} goal(s) (remote) — skipping onboarding goal creation"
        fi
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

        # Standing onboarding goal — only when the DB is empty (a re-run against
        # an existing DB must not clobber a goal the agent or owner already set up)
        if [ "${_goal_count}" = "0" ]; then
          _onboard_out=$(env PYTHONPATH="${AGENT_LOOM_DIR}" \
            "${AGENT_LOOM_DIR}/.venv/bin/python" -m loom.cli --db "${LOOM_DB}" \
            goal add -n "Onboarding" -d "$_onboard_desc" -s scheduled -p 5 2>&1)
          _onboard_id=$(printf '%s' "$_onboard_out" | grep -oE 'Created goal [0-9]+' | grep -oE '[0-9]+')
          if [ -n "$_onboard_id" ]; then
            sed -i "s|^# DEFAULT_GOAL_ID=.*|DEFAULT_GOAL_ID=${_onboard_id}|" "$AGENT_CONFIG"
            ok "Onboarding goal created (id ${_onboard_id}) — DEFAULT_GOAL_ID set"
          else
            warn "Onboarding goal creation failed — DEFAULT_GOAL_ID left unset: ${_onboard_out}"
          fi
        else
          info "Loom DB already has ${_goal_count} goal(s) — skipping onboarding goal creation"
        fi
      fi
    fi
  fi
fi

# ── Step 8b: khal calendar setup ─────────────────────────────────────────────

step "8b: khal calendar setup"

if [ "$SKIP_KHAL" = "1" ]; then
  info "SKIP — --skip-khal flag set"
else
  KHAL_CALENDAR_DIR="${INSTALL_ROOT}/state/calendar/${AGENT_NAME}"
  KHAL_CONFIG="${INSTALL_ROOT}/config/khal.cfg"
  KHAL_DB="${INSTALL_ROOT}/state/khal.db"
  KHAL_WRAPPER="${INSTALL_ROOT}/bin/khal"

  _build_khal_config() {
    local cal_dir="$1" db_path="$2" agent="$3"
    printf '[calendars]\n\n[[%s]]\npath = %s/\ncolor = auto\n\n[sqlite]\npath = %s\n\n[locale]\ntimeformat = %%H:%%M\ndateformat = %%Y-%%m-%%d\ndatetimeformat = %%Y-%%m-%%d %%H:%%M\nfirstweekday = 0\n' \
      "$agent" "$cal_dir" "$db_path"
  }

  if [ "$DRY_RUN" = "1" ]; then
    dry "Install khal (pip3 install --user khal or apt-get install khal)"
    dry "mkdir -p ${KHAL_CALENDAR_DIR}"
    dry "mkdir -p ${INSTALL_ROOT}/config"
    dry "Write ${KHAL_CONFIG}"
    dry "Write ${KHAL_WRAPPER}"
  elif [ "$REMOTE" = "1" ]; then
    # ── Remote khal install ──────────────────────────────────────────────────
    _khal_bin_remote=""
    if ssh_run "command -v khal >/dev/null 2>&1"; then
      _khal_bin_remote="khal"
      info "khal already installed (remote)"
    elif ssh_run "[ -f ~/.local/bin/khal ]" 2>/dev/null; then
      _khal_bin_remote="~/.local/bin/khal"
      info "khal already installed at ~/.local/bin/khal (remote)"
    else
      info "Installing khal on ${TARGET_USER}@${TARGET_HOST} ..."
      if ssh_run "pip3 install --user --break-system-packages khal >/dev/null 2>&1 \
                  || pip3 install --user khal >/dev/null 2>&1" 2>/dev/null; then
        _khal_bin_remote='${HOME}/.local/bin/khal'
        ok "khal installed via pip (remote)"
      elif ssh_run "apt-get install -y khal >/dev/null 2>&1" 2>/dev/null; then
        _khal_bin_remote="khal"
        ok "khal installed via apt (remote)"
      else
        warn "khal install failed on remote — skip calendar setup. Install manually: pip3 install --user khal"
        _khal_bin_remote=""
      fi
    fi

    if [ -n "$_khal_bin_remote" ]; then
      ssh_run "mkdir -p '${KHAL_CALENDAR_DIR}'"
      ssh_run "mkdir -p '${INSTALL_ROOT}/config'"

      _khal_cfg=$(_build_khal_config "${KHAL_CALENDAR_DIR}" "${KHAL_DB}" "${AGENT_NAME}")
      printf '%s\n' "$_khal_cfg" | \
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "${TARGET_USER}@${TARGET_HOST}" "cat > '${KHAL_CONFIG}'"
      info "Written (remote): config/khal.cfg"

      _khal_wrap="#!/usr/bin/env bash
# khal wrapper for agent: ${AGENT_NAME}
exec \"${_khal_bin_remote}\" -c \"${KHAL_CONFIG}\" \"\$@\""
      printf '%s\n' "$_khal_wrap" | \
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "${TARGET_USER}@${TARGET_HOST}" "cat > '${KHAL_WRAPPER}' && chmod +x '${KHAL_WRAPPER}'"
      info "Written (remote): bin/khal"

      if ssh_run "'${KHAL_WRAPPER}' printcalendars >/dev/null 2>&1" 2>/dev/null; then
        ok "khal calendar ready (remote): ${KHAL_CALENDAR_DIR}"
      else
        warn "khal installed (remote) but verification failed — check ${KHAL_CONFIG}"
      fi
    fi
  else
    # ── Local khal install ───────────────────────────────────────────────────
    _khal_bin=""
    if command -v khal >/dev/null 2>&1; then
      _khal_bin="$(command -v khal)"
      info "khal already installed: ${_khal_bin}"
    elif [ -f "${HOME}/.local/bin/khal" ]; then
      _khal_bin="${HOME}/.local/bin/khal"
      info "khal already installed (user): ${_khal_bin}"
    else
      info "Installing khal ..."
      if pip3 install --user --break-system-packages khal >/dev/null 2>&1 \
         || pip3 install --user khal >/dev/null 2>&1; then
        _khal_bin="${HOME}/.local/bin/khal"
        ok "khal installed via pip: ${_khal_bin}"
      elif apt-get install -y khal >/dev/null 2>&1; then
        _khal_bin="$(command -v khal)"
        ok "khal installed via apt: ${_khal_bin}"
      else
        warn "khal install failed — calendar setup skipped. Install manually: pip3 install --user khal"
      fi
    fi

    if [ -n "$_khal_bin" ]; then
      mkdir -p "${KHAL_CALENDAR_DIR}"
      mkdir -p "${INSTALL_ROOT}/config"

      _build_khal_config "${KHAL_CALENDAR_DIR}" "${KHAL_DB}" "${AGENT_NAME}" > "${KHAL_CONFIG}"
      info "Written: config/khal.cfg"

      printf '#!/usr/bin/env bash\n# khal wrapper for agent: %s\nexec "%s" -c "%s" "$@"\n' \
        "${AGENT_NAME}" "${_khal_bin}" "${KHAL_CONFIG}" > "${KHAL_WRAPPER}"
      chmod +x "${KHAL_WRAPPER}"
      info "Written: bin/khal"

      if "${KHAL_WRAPPER}" printcalendars >/dev/null 2>&1; then
        ok "khal calendar ready: ${KHAL_CALENDAR_DIR}"
        ok "khal wrapper: ${KHAL_WRAPPER}"
      else
        warn "khal installed but verification failed — check ${KHAL_CONFIG}"
      fi
    fi
  fi
fi

# ── Step 9: Smoke test ────────────────────────────────────────────────────────
# Lightweight file-integrity check — not a full agent run.

step "9: Smoke test"

_SMOKE_PASS=1
_smoke_check() {
  local label="$1" path="$2"
  if [ "$REMOTE" = "1" ]; then
    if ssh_run "[ -e '${path}' ]" 2>/dev/null; then
      ok "  ${label}"
    else
      warn "MISSING: ${label} — ${path}"
      _SMOKE_PASS=0
    fi
  else
    if [ -e "${path}" ]; then
      ok "  ${label}"
    else
      warn "MISSING: ${label} — ${path}"
      _SMOKE_PASS=0
    fi
  fi
}

if [ "$DRY_RUN" = "1" ]; then
  dry "Verify key files exist at ${INSTALL_ROOT}"
else
  _smoke_check "scripts/executional/wake.sh"        "${INSTALL_ROOT}/scripts/executional/wake.sh"
  _smoke_check "scripts/executional/resolve_session_type.py" \
    "${INSTALL_ROOT}/scripts/executional/resolve_session_type.py"
  _smoke_check "prompts/core/baseline.md"            "${INSTALL_ROOT}/prompts/core/baseline.md"
  _smoke_check "prompts/persona.txt"                 "${INSTALL_ROOT}/prompts/persona.txt"
  _smoke_check "state/agent_config.env"              "${INSTALL_ROOT}/state/agent_config.env"
  _smoke_check "bin/loom wrapper"                    "${INSTALL_ROOT}/bin/loom"
  _smoke_check "inbox/pending.json"                  "${INSTALL_ROOT}/inbox/pending.json"
  if [ "$SKIP_KHAL" = "0" ]; then
    _smoke_check "config/khal.cfg"                   "${INSTALL_ROOT}/config/khal.cfg"
    _smoke_check "bin/khal wrapper"                  "${INSTALL_ROOT}/bin/khal"
  fi

  if [ "$_SMOKE_PASS" = "1" ]; then
    ok "Smoke test PASS — key files present"
  else
    warn "Smoke test: one or more files missing. Check ${INSTALL_ROOT} for gaps."
  fi
fi

# ── Step 10: Summary + next steps ─────────────────────────────────────────────

step "10: Summary"

echo ""
if [ "$REMOTE" = "1" ]; then
  echo "══════════════════════════════════════════════════════════════"
  printf " Install complete: %s → %s@%s\n" "${AGENT_NAME}" "${TARGET_USER}" "${TARGET_HOST}"
  echo "══════════════════════════════════════════════════════════════"
else
  echo "══════════════════════════════════════════════════════════════"
  printf " Install complete: %s (local)\n" "${AGENT_NAME}"
  echo "══════════════════════════════════════════════════════════════"
fi
echo ""
echo "  Install path:  ${INSTALL_ROOT}"
echo "  Loom DB:       ${LOOM_DB}"
echo "  Loom wrapper:  ${INSTALL_ROOT}/bin/loom"
[ -n "${NEXUS_URL:-}" ] && echo "  Nexus URL:     ${NEXUS_URL}"
echo ""
echo "NEXT STEPS:"
echo ""

_step=1
printf "  %d. Review and customize the agent's persona:\n" "$_step"
if [ "$REMOTE" = "1" ]; then
  echo "     ssh ${TARGET_USER}@${TARGET_HOST}"
  echo "     \$EDITOR ${INSTALL_ROOT}/prompts/persona.txt"
else
  echo "     \$EDITOR ${INSTALL_ROOT}/prompts/persona.txt"
fi
echo "     (NAME / BACKGROUND / CORE TRAITS / STYLE — defines identity and voice)"
echo ""
_step=$((_step + 1))
if [ -z "${TELEGRAM_TOKEN:-}" ]; then
  if [ "$REMOTE" = "1" ]; then
    printf "  %d. Add Telegram credentials on target:\n" "$_step"
    echo "     ssh ${TARGET_USER}@${TARGET_HOST}"
    echo "     cat > ${INSTALL_ROOT}/identity/agent.env << 'EOF'"
    echo "     TELEGRAM_TOKEN=<bot-token>"
    echo "     TELEGRAM_CHAT_ID=<your-chat-id>"
    echo "     EOF"
    echo "     chmod 600 ${INSTALL_ROOT}/identity/agent.env"
  else
    printf "  %d. Add Telegram credentials:\n" "$_step"
    echo "     cat > ${INSTALL_ROOT}/identity/agent.env << 'EOF'"
    echo "     TELEGRAM_TOKEN=<bot-token>"
    echo "     TELEGRAM_CHAT_ID=<your-chat-id>"
    echo "     EOF"
    echo "     chmod 600 ${INSTALL_ROOT}/identity/agent.env"
  fi
  echo ""
  _step=$((_step + 1))
fi

if [ "$REMOTE" = "1" ]; then
  printf "  %d. Auth Claude CLI on target (first time):\n" "$_step"
  echo "     ssh ${TARGET_USER}@${TARGET_HOST} 'claude auth login'"
  echo ""
  _step=$((_step + 1))
  printf "  %d. Verify the timer is running:\n" "$_step"
  # shellcheck disable=SC2016
  echo "     ssh ${TARGET_USER}@${TARGET_HOST} \\"
  echo "       'XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user list-timers | grep ${AGENT_NAME}'"
  echo ""
  _step=$((_step + 1))
  printf "  %d. Manage tasks with loom (on target):\n" "$_step"
  echo "     ssh ${TARGET_USER}@${TARGET_HOST}"
  echo "     ${INSTALL_ROOT}/bin/loom goal list --all"
  echo "     ${INSTALL_ROOT}/bin/loom ls               # scheduled tasks"
  echo ""
  _step=$((_step + 1))
  printf "  %d. Monitor first nightly wake (fires 23:00 local time):\n" "$_step"
  echo "     ssh ${TARGET_USER}@${TARGET_HOST} 'tail -f ${INSTALL_ROOT}/logs/wake.log'"
else
  printf "  %d. Auth Claude CLI (if not already done):\n" "$_step"
  echo "     claude auth login"
  echo ""
  _step=$((_step + 1))
  if [ "$SYSTEMD_AVAILABLE" = "1" ]; then
    printf "  %d. Verify the timer is running:\n" "$_step"
    echo "     systemctl --user list-timers | grep ${AGENT_NAME}"
    echo ""
    _step=$((_step + 1))
  fi
  printf "  %d. Manage tasks with loom:\n" "$_step"
  echo "     ${INSTALL_ROOT}/bin/loom goal list --all"
  echo "     ${INSTALL_ROOT}/bin/loom ls               # scheduled tasks"
  echo ""
  _step=$((_step + 1))
  if [ "$SYSTEMD_AVAILABLE" = "1" ]; then
    printf "  %d. Monitor first nightly wake (fires 23:00 local time):\n" "$_step"
    echo "     tail -f ${INSTALL_ROOT}/logs/wake.log"
  else
    printf "  %d. Launch a manual session:\n" "$_step"
    echo "     TRIGGER_MODE=manual bash ${INSTALL_ROOT}/scripts/executional/wake.sh"
  fi
fi
echo ""

exit 0
