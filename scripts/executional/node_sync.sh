#!/usr/bin/env bash
# node_sync.sh — Pull-based CI/CD sync from blank_node template.
# Called non-fatally by wake.sh after agent_config.env is sourced.
# CI_CD_ENABLED from agent_config.env controls whether sync runs.
# BLANK_NODE_REPO: if set, auto-clones the template on first run when
# BLANK_NODE_DIR doesn't exist — enables off-machine agents (T515).

set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$PROJECT_DIR"
STATE_DIR="$PROJECT_DIR/state"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/node_sync.log"

mkdir -p "$LOG_DIR"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] node_sync: $*" | tee -a "$LOG_FILE"; }

# ── CI/CD gate ────────────────────────────────────────────────────────────────
if [ "${CI_CD_ENABLED:-false}" != "true" ]; then
  log "CI_CD_ENABLED=${CI_CD_ENABLED:-false} — skip"
  exit 0
fi

# ── Validate blank_node dir ───────────────────────────────────────────────────
BLANK_NODE_DIR="${BLANK_NODE_DIR:-}"
if [ -z "$BLANK_NODE_DIR" ]; then
  log "ERROR: BLANK_NODE_DIR not set in agent_config.env — cannot sync. Set CI_CD_ENABLED=false to suppress this message."
  exit 0
fi
if [ "$BLANK_NODE_DIR" -ef "$PROJECT_DIR" ] 2>/dev/null || [ "$(realpath "$BLANK_NODE_DIR" 2>/dev/null)" = "$(realpath "$PROJECT_DIR")" ]; then
  log "ERROR: BLANK_NODE_DIR resolves to PROJECT_DIR — refusing self-sync."
  exit 0
fi
if [ ! -d "$BLANK_NODE_DIR/.git" ]; then
  BLANK_NODE_REPO="${BLANK_NODE_REPO:-}"
  if [ -n "$BLANK_NODE_REPO" ]; then
    log "BLANK_NODE_DIR has no .git — cloning from $BLANK_NODE_REPO..."
    mkdir -p "$(dirname "$BLANK_NODE_DIR")"
    if ! timeout 120 git clone --depth 1 "$BLANK_NODE_REPO" "$BLANK_NODE_DIR" >> "$LOG_FILE" 2>&1; then
      log "ERROR: git clone failed — cannot bootstrap BLANK_NODE_DIR. CI/CD skip."
      exit 0
    fi
    log "Clone complete: $BLANK_NODE_DIR"
  else
    log "ERROR: BLANK_NODE_DIR=$BLANK_NODE_DIR is not a git repo and BLANK_NODE_REPO is not set — skip."
    exit 0
  fi
fi

# ── Fetch upstream ────────────────────────────────────────────────────────────
log "Fetching origin/main from $BLANK_NODE_DIR"
if ! timeout 30 git -C "$BLANK_NODE_DIR" fetch origin main --quiet 2>/dev/null; then
  log "WARN: git fetch failed or timed out — skipping sync this wake."
  exit 0
fi

UPSTREAM_SHA=$(git -C "$BLANK_NODE_DIR" rev-parse origin/main 2>/dev/null) || {
  log "ERROR: could not resolve origin/main SHA — skip."
  exit 0
}

# ── SHA pin check ─────────────────────────────────────────────────────────────
NODE_VERSION_FILE="$STATE_DIR/node_version.txt"
PINNED_SHA=""
if [ -f "$NODE_VERSION_FILE" ]; then
  PINNED_SHA=$(tr -d '[:space:]' < "$NODE_VERSION_FILE")
fi

if [ -n "$PINNED_SHA" ] && [ "$UPSTREAM_SHA" = "$PINNED_SHA" ]; then
  log "Already at $UPSTREAM_SHA — no sync needed."
  exit 0
fi

log "New upstream: $UPSTREAM_SHA (pinned: ${PINNED_SHA:-none})"

# ── Build effective denylist (base ∪ local) ───────────────────────────────────
BASE_DENYLIST="$BLANK_NODE_DIR/config/cicd_denylist.txt"
LOCAL_DENYLIST="$STATE_DIR/cicd_denylist.local.txt"

if [ ! -f "$BASE_DENYLIST" ]; then
  log "ERROR: base denylist missing at $BASE_DENYLIST — refusing sync (safety abort)."
  exit 0
fi

EFFECTIVE_DENYLIST=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f '$EFFECTIVE_DENYLIST'" EXIT

cat "$BASE_DENYLIST" > "$EFFECTIVE_DENYLIST"
if [ -f "$LOCAL_DENYLIST" ]; then
  cat "$LOCAL_DENYLIST" >> "$EFFECTIVE_DENYLIST"
  log "Local denylist merged ($LOCAL_DENYLIST)"
fi
# Hard invariant: local file can only ADD patterns, never remove base patterns.
# The union is guaranteed by construction (concatenation); the local file's
# content is never parsed to subtract entries from the base list.

# ── Denylist matching ─────────────────────────────────────────────────────────
# Returns 0 (match = excluded) if filepath matches any denylist pattern.
# Supports: directory prefix patterns (trailing /), anchored patterns (leading /),
# and exact file path patterns. Simple glob * within a segment is not yet supported.
path_is_denied() {
  local filepath="$1"
  local pattern raw
  while IFS= read -r raw; do
    # strip leading/trailing whitespace
    pattern="${raw#"${raw%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    # skip comments and blank lines
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # strip leading / (anchoring is implicit: all paths are relative to agent root)
    pattern="${pattern#/}"
    # directory prefix match (trailing /)
    if [[ "$pattern" == */ ]]; then
      [[ "$filepath" == "${pattern}"* ]] && return 0
    else
      # exact file match
      [[ "$filepath" == "$pattern" ]] && return 0
    fi
  done < "$EFFECTIVE_DENYLIST"
  return 1
}

# ── File list from upstream ───────────────────────────────────────────────────
mapfile -t ALL_FILES < <(git -C "$BLANK_NODE_DIR" ls-tree --name-only -r origin/main 2>/dev/null)

if [ ${#ALL_FILES[@]} -eq 0 ]; then
  log "ERROR: git ls-tree returned no files from origin/main — skip."
  exit 0
fi

FILES_TO_SYNC=()
FILES_SKIPPED=()
for f in "${ALL_FILES[@]}"; do
  if path_is_denied "$f"; then
    FILES_SKIPPED+=("$f")
  else
    FILES_TO_SYNC+=("$f")
  fi
done

log "Candidates: ${#ALL_FILES[@]}  to_sync: ${#FILES_TO_SYNC[@]}  denied: ${#FILES_SKIPPED[@]}"

if [ ${#FILES_TO_SYNC[@]} -eq 0 ]; then
  log "Nothing to sync after denylist filtering — updating pin only."
  echo "$UPSTREAM_SHA" > "$NODE_VERSION_FILE"
  exit 0
fi

# ── Prune old backups (keep 5 most recent) ───────────────────────────────────
mapfile -t OLD_BACKUPS < <(ls -1dt "$STATE_DIR"/cicd_backup_* 2>/dev/null | tail -n +6)
for old in "${OLD_BACKUPS[@]}"; do
  rm -rf "$old"
  log "Pruned old backup: $(basename "$old")"
done

# ── Backup existing files ─────────────────────────────────────────────────────
BACKUP_TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$STATE_DIR/cicd_backup_${BACKUP_TS}"
mkdir -p "$BACKUP_DIR"
log "Backup dir: $BACKUP_DIR"

for f in "${FILES_TO_SYNC[@]}"; do
  if [ -f "$PROJECT_DIR/$f" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp "$PROJECT_DIR/$f" "$BACKUP_DIR/$f"
  fi
done

# ── Sync files ────────────────────────────────────────────────────────────────
SYNCED_FILES=()
SYNCED_PY=()
SYNCED_SH=()

for f in "${FILES_TO_SYNC[@]}"; do
  target="$PROJECT_DIR/$f"
  mkdir -p "$(dirname "$target")"
  if git -C "$BLANK_NODE_DIR" show "origin/main:$f" > "$target" 2>/dev/null; then
    SYNCED_FILES+=("$f")
    [[ "$f" == *.py ]] && SYNCED_PY+=("$f")
    [[ "$f" == *.sh ]] && SYNCED_SH+=("$f")
  else
    log "WARN: failed to extract $f from origin/main — skipping."
  fi
done

log "Synced ${#SYNCED_FILES[@]} files."

# ── Post-sync validation ──────────────────────────────────────────────────────
VALIDATION_FAILED=false

for f in "${SYNCED_PY[@]}"; do
  if ! /usr/bin/python3 -m py_compile "$PROJECT_DIR/$f" 2>/dev/null; then
    log "ERROR: Python syntax check failed: $f"
    VALIDATION_FAILED=true
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in "${SYNCED_SH[@]}"; do
    if ! shellcheck --severity=error "$PROJECT_DIR/$f" 2>/dev/null; then
      log "ERROR: shellcheck failed: $f"
      VALIDATION_FAILED=true
    fi
  done
else
  log "shellcheck not available — shell validation skipped."
fi

# ── Restore on validation failure ─────────────────────────────────────────────
if [ "$VALIDATION_FAILED" = "true" ]; then
  log "Validation failed — restoring from $BACKUP_DIR"
  for f in "${SYNCED_FILES[@]}"; do
    if [ -f "$BACKUP_DIR/$f" ]; then
      cp "$BACKUP_DIR/$f" "$PROJECT_DIR/$f"
    else
      # File is new (no backup) — remove it
      rm -f "$PROJECT_DIR/$f"
    fi
  done
  log "Restore complete. Pin unchanged (${PINNED_SHA:-none})."
  exit 1
fi

# ── Update pin ────────────────────────────────────────────────────────────────
echo "$UPSTREAM_SHA" > "$NODE_VERSION_FILE"

# ── Write sync manifest ───────────────────────────────────────────────────────
MANIFEST_FILE="$STATE_DIR/cicd_last_sync.json"

# Build arrays as temp files to avoid shell-Python quoting issues
_TMP_SYNCED=$(mktemp)
_TMP_SKIPPED=$(mktemp)
printf '%s\n' "${SYNCED_FILES[@]}" > "$_TMP_SYNCED"
printf '%s\n' "${FILES_SKIPPED[@]}" > "$_TMP_SKIPPED"

/usr/bin/python3 - "$MANIFEST_FILE" "$_TMP_SYNCED" "$_TMP_SKIPPED" \
    "$UPSTREAM_SHA" "${PINNED_SHA:-}" <<'PYEOF'
import json, sys
from datetime import datetime, timezone

out_path, synced_f, skipped_f, to_sha, from_sha = sys.argv[1:6]

def read_lines(path):
    try:
        with open(path) as f:
            return [l.rstrip('\n') for l in f if l.strip()]
    except OSError:
        return []

data = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "from_sha": from_sha or None,
    "to_sha": to_sha,
    "files_synced": read_lines(synced_f),
    "files_skipped_denylist": read_lines(skipped_f),
}
tmp = out_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
import os
os.replace(tmp, out_path)
PYEOF

rm -f "$_TMP_SYNCED" "$_TMP_SKIPPED"

log "Sync complete: ${PINNED_SHA:-none} → $UPSTREAM_SHA (${#SYNCED_FILES[@]} files). Manifest: $MANIFEST_FILE"
