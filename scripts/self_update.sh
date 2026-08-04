#!/usr/bin/env bash
# Pull-based self-update from blank_node upstream.
# Gated by SELF_UPDATE_ENABLED=1 in agent_config.env — off by default.
# Called from maintenance sessions; also safe to invoke manually.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_PREFIX="[self_update $(date -u '+%Y-%m-%dT%H:%M:%SZ')]"

# Source config to pick up SELF_UPDATE_ENABLED
# shellcheck source=/dev/null
source "$REPO_ROOT/agent_config.env" 2>/dev/null || true

if [[ "${SELF_UPDATE_ENABLED:-0}" != "1" ]]; then
  echo "$LOG_PREFIX SELF_UPDATE_ENABLED not set — skipping (set =1 in agent_config.env to enable)"
  exit 0
fi

echo "$LOG_PREFIX Starting self-update (repo: $REPO_ROOT)"

# Fetch latest state from origin without touching working tree
git -C "$REPO_ROOT" fetch origin 2>&1 || {
  echo "$LOG_PREFIX ERROR: git fetch failed — aborting"
  exit 1
}

# Determine changed files between HEAD and origin/main
CHANGED_ON_REMOTE=$(git -C "$REPO_ROOT" diff --name-only HEAD origin/main 2>/dev/null || true)

if [[ -z "$CHANGED_ON_REMOTE" ]]; then
  echo "$LOG_PREFIX No changes on origin/main vs HEAD"
  echo "self_update_result: files_pulled=0 files_skipped=0 commit_hash=none"
  exit 0
fi

MANAGED_FILE="$REPO_ROOT/ci/managed_paths.txt"
if [[ ! -f "$MANAGED_FILE" ]]; then
  echo "$LOG_PREFIX ERROR: $MANAGED_FILE not found — cannot determine safe update set"
  exit 1
fi

EXCLUDE_FILE="$REPO_ROOT/state/self_update_exclude.txt"

# Resolve effective update set via Python glob matching
RESOLUTION=$(REPO_ROOT="$REPO_ROOT" MANAGED_FILE="$MANAGED_FILE" \
  EXCLUDE_FILE="$EXCLUDE_FILE" CHANGED_FILES="$CHANGED_ON_REMOTE" \
  /usr/bin/python3 << 'PYEOF'
import os, fnmatch

managed_file = os.environ['MANAGED_FILE']
exclude_file = os.environ.get('EXCLUDE_FILE', '')
changed_str  = os.environ.get('CHANGED_FILES', '')

changed = [f.strip() for f in changed_str.strip().splitlines() if f.strip()]

managed_patterns = []
with open(managed_file) as fh:
    for line in fh:
        line = line.strip()
        if line and not line.startswith('#'):
            managed_patterns.append(line)

exclude_patterns = []
if exclude_file and os.path.exists(exclude_file):
    with open(exclude_file) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith('#'):
                exclude_patterns.append(line)

def matches_any(path, patterns):
    return any(fnmatch.fnmatch(path, p) for p in patterns)

for f in changed:
    if matches_any(f, managed_patterns):
        tag = 'SKIP' if matches_any(f, exclude_patterns) else 'PULL'
    else:
        tag = 'UNMANAGED'
    print(f"{tag}:{f}")
PYEOF
)

PULL_FILES=()
SKIP_FILES=()
while IFS= read -r line; do
  tag="${line%%:*}"
  path="${line#*:}"
  case "$tag" in
    PULL)  PULL_FILES+=("$path") ;;
    SKIP)  SKIP_FILES+=("$path") ;;
  esac
done <<< "$RESOLUTION"

if [[ ${#PULL_FILES[@]} -eq 0 ]]; then
  echo "$LOG_PREFIX No managed files changed (${#SKIP_FILES[@]} skipped by exclude)"
  echo "self_update_result: files_pulled=0 files_skipped=${#SKIP_FILES[@]} commit_hash=none"
  exit 0
fi

echo "$LOG_PREFIX Pulling ${#PULL_FILES[@]} file(s) from origin/main:"
for f in "${PULL_FILES[@]}"; do
  echo "  + $f"
  git -C "$REPO_ROOT" checkout origin/main -- "$f"
done

if [[ ${#SKIP_FILES[@]} -gt 0 ]]; then
  echo "$LOG_PREFIX Skipped by node exclude list (${#SKIP_FILES[@]}):"
  for f in "${SKIP_FILES[@]}"; do
    echo "  - $f"
  done
fi

# Commit the update with an auditable message (plain git revert works if needed)
COMMIT_MSG="chore(self_update): pull ${#PULL_FILES[@]} file(s) from upstream

$(for f in "${PULL_FILES[@]}"; do echo "  $f"; done)

Origin: $(git -C "$REPO_ROOT" rev-parse origin/main)"

git -C "$REPO_ROOT" add -- "${PULL_FILES[@]}"
git -C "$REPO_ROOT" commit -m "$COMMIT_MSG" 2>&1
COMMIT_HASH=$(git -C "$REPO_ROOT" rev-parse --short HEAD)

echo "$LOG_PREFIX Committed: $COMMIT_HASH"
echo "self_update_result: files_pulled=${#PULL_FILES[@]} files_skipped=${#SKIP_FILES[@]} commit_hash=$COMMIT_HASH"

# Restart: try procctl.sh first (systemd/supervisord nodes), fall back to docker if available
PROCCTL="$REPO_ROOT/tools/executional/procctl.sh"
if [[ -x "$PROCCTL" ]]; then
  echo "$LOG_PREFIX Restarting via procctl.sh"
  bash "$PROCCTL" restart 2>&1 || echo "$LOG_PREFIX WARNING: procctl.sh restart failed — may need manual restart"
elif command -v docker &>/dev/null && [[ -f "$REPO_ROOT/docker-compose.yml" ]]; then
  echo "$LOG_PREFIX Restarting via docker compose"
  docker compose -f "$REPO_ROOT/docker-compose.yml" up -d 2>&1 \
    || echo "$LOG_PREFIX WARNING: docker compose restart failed — may need manual restart"
else
  echo "$LOG_PREFIX No restart handler found — files updated, restart manually if needed"
fi

echo "$LOG_PREFIX Done"
