#!/usr/bin/env bash
# scripts/self_update.sh — pull-based self-update from blank_node upstream
#
# Gate:      SELF_UPDATE_ENABLED=1 in state/agent_config.env (off by default)
# Allowlist: ci/managed_paths.txt        — what upstream may ever touch
# Exclude:   state/self_update_exclude.txt — per-node overrides (optional)
#
# Files are pulled one at a time via `git checkout origin/main -- <path>` and
# committed locally as a single auditable commit (revertible with git revert).
# Exit 0 always — caller can treat non-zero as fatal but we prefer soft logging.
set -euo pipefail

AGENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$AGENT_DIR/state/agent_config.env"
MANAGED_PATHS="$AGENT_DIR/ci/managed_paths.txt"
EXCLUDE_FILE="$AGENT_DIR/state/self_update_exclude.txt"

log() { echo "self_update: $*"; }

# ── Gate ──────────────────────────────────────────────────────────────────────
SELF_UPDATE_ENABLED=0
if [ -f "$CONFIG" ]; then
  val=$(grep -E '^SELF_UPDATE_ENABLED=' "$CONFIG" 2>/dev/null | tail -1 \
        | cut -d= -f2- | tr -d '"'"'"' ' || true)
  [ "$val" = "1" ] && SELF_UPDATE_ENABLED=1
fi
if [ "$SELF_UPDATE_ENABLED" != "1" ]; then
  log "disabled (SELF_UPDATE_ENABLED != 1) — no-op"
  exit 0
fi

# ── Allowlist ─────────────────────────────────────────────────────────────────
if [ ! -f "$MANAGED_PATHS" ]; then
  log "ERROR: ci/managed_paths.txt not found — skipping"
  exit 0
fi

readarray -t ALLOWED_PATTERNS < <(
  grep -v '^[[:space:]]*#' "$MANAGED_PATHS" | grep -v '^[[:space:]]*$' || true
)
if [ "${#ALLOWED_PATTERNS[@]}" -eq 0 ]; then
  log "WARNING: ci/managed_paths.txt has no patterns — nothing to pull"
  exit 0
fi

EXCLUDE_PATTERNS=()
if [ -f "$EXCLUDE_FILE" ]; then
  readarray -t EXCLUDE_PATTERNS < <(
    grep -v '^[[:space:]]*#' "$EXCLUDE_FILE" | grep -v '^[[:space:]]*$' || true
  )
fi

# ── Fetch ─────────────────────────────────────────────────────────────────────
log "fetching from origin..."
if ! timeout 30 git -C "$AGENT_DIR" fetch origin 2>&1; then
  log "git fetch failed — skipping update (non-fatal)"
  exit 0
fi

CHANGED_FILES=$(git -C "$AGENT_DIR" diff --name-only HEAD origin/main 2>/dev/null || true)
if [ -z "$CHANGED_FILES" ]; then
  log "no changes — already up to date"
  echo ""
  echo "=== self_update summary ==="
  echo "files_pulled: 0"
  echo "commit_hash: (no changes)"
  echo "==========================="
  exit 0
fi

# ── Filter and pull ───────────────────────────────────────────────────────────
is_allowed() {
  local f="$1" p
  for p in "${ALLOWED_PATTERNS[@]}"; do
    # [[ ]] == does fnmatch-style glob; matches across / as well
    [[ "$f" == $p ]] && return 0
  done
  return 1
}

is_excluded() {
  local f="$1" p
  for p in "${EXCLUDE_PATTERNS[@]}"; do
    [[ "$f" == $p ]] && return 0
  done
  return 1
}

PULLED=()
SKIPPED_EXCLUDE=()

while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_allowed "$f" || continue
  if is_excluded "$f"; then
    SKIPPED_EXCLUDE+=("$f")
    continue
  fi
  if git -C "$AGENT_DIR" checkout origin/main -- "$f" 2>/dev/null; then
    PULLED+=("$f")
    log "  pulled: $f"
  else
    log "  WARNING: checkout failed for $f (deleted upstream or path error)"
  fi
done <<< "$CHANGED_FILES"

# ── Commit ────────────────────────────────────────────────────────────────────
COMMIT_HASH="(no changes)"
if [ "${#PULLED[@]}" -gt 0 ]; then
  git -C "$AGENT_DIR" add -- "${PULLED[@]}"
  PULL_LIST=$(printf '  %s\n' "${PULLED[@]}")
  git -C "$AGENT_DIR" commit \
    -m "chore(self_update): pull ${#PULLED[@]} file(s) from upstream blank_node

${PULL_LIST}" 2>&1
  COMMIT_HASH=$(git -C "$AGENT_DIR" rev-parse --short HEAD)
  log "committed $COMMIT_HASH"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== self_update summary ==="
echo "files_pulled: ${#PULLED[@]}"
[ "${#PULLED[@]}" -gt 0 ] && printf '  %s\n' "${PULLED[@]}"
echo "files_skipped_by_exclude: ${#SKIPPED_EXCLUDE[@]}"
[ "${#SKIPPED_EXCLUDE[@]}" -gt 0 ] && printf '  %s\n' "${SKIPPED_EXCLUDE[@]}"
echo "commit_hash: $COMMIT_HASH"
echo "==========================="

# ── Restart ───────────────────────────────────────────────────────────────────
# Only matters for long-running processes (Docker). Systemd nodes already run
# scripts fresh from disk each wake — no restart needed for script-only changes.
if [ "${#PULLED[@]}" -gt 0 ]; then
  DOCKER_COMPOSE="$AGENT_DIR/docker-compose.yml"
  PROCCTL="$AGENT_DIR/tools/executional/procctl.sh"

  if [ -f "$DOCKER_COMPOSE" ] && command -v docker &>/dev/null; then
    log "restarting via docker compose..."
    docker compose -f "$DOCKER_COMPOSE" up -d 2>&1 || log "docker compose restart failed (non-fatal)"
  elif [ -f "$PROCCTL" ]; then
    # For systemd nodes: scripts are re-exec'd each wake, so restart is a no-op.
    # Log rather than act to avoid disrupting a session in progress.
    log "systemd node — updated scripts will apply at next wake (no restart needed)"
  else
    log "no restart mechanism found — updated files will take effect at next wake"
  fi
fi

exit 0
