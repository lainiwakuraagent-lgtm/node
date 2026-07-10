#!/usr/bin/env bash
# check_github.sh — Check for owner replies via GitHub Issue comments
#
# Checks two repos:
#   PRIMARY: lainiwakuraagent-lgtm/wired#1 (my own repo — uses @Lain token)
#   LEGACY:  andrii-mazurchuk/JAR-tasks-manager#1 (old channel — uses andrii's gh auth)
#
# Reads comments since last check, prints new ones, appends to conversation.md.
# Exit code: 0 = no new comments, 1 = new comments found.
#
# State files:
#   state/github_last_comment_id      — last seen ID in wired#1 (primary)
#   state/github_jar_last_comment_id  — last seen ID in JAR#1 (legacy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CREDS_FILE="$PROJECT_DIR/identity/credentials.md"
CONV_LOG="$PROJECT_DIR/memory/conversation.md"

PRIMARY_STATE="$PROJECT_DIR/state/github_last_comment_id"
LEGACY_STATE="$PROJECT_DIR/state/github_jar_last_comment_id"

FOUND_NEW=0

# Extract @Lain's GitHub token (if credentials file exists)
LAIN_TOKEN=""
if [[ -f "$CREDS_FILE" ]]; then
    LAIN_TOKEN=$(grep -o 'ghp_[A-Za-z0-9]*' "$CREDS_FILE" | head -1)
fi

# ── Helper: check one issue ────────────────────────────────────────────────
check_issue() {
    local REPO="$1"
    local ISSUE_NUMBER="$2"
    local STATE_FILE="$3"
    local LABEL="$4"
    local USE_LAIN_TOKEN="$5"   # "yes" or "no"

    local LAST_ID=0
    if [[ -f "$STATE_FILE" ]]; then
        LAST_ID=$(cat "$STATE_FILE")
    fi

    # Fetch comments
    local COMMENTS
    if [[ "$USE_LAIN_TOKEN" == "yes" && -n "$LAIN_TOKEN" ]]; then
        COMMENTS=$(GH_TOKEN="$LAIN_TOKEN" gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" \
            --jq '.[] | {id: .id, user: .user.login, body: .body, created_at: .created_at}' 2>&1) || true
    else
        COMMENTS=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" \
            --jq '.[] | {id: .id, user: .user.login, body: .body, created_at: .created_at}' 2>&1) || true
    fi

    if [[ -z "$COMMENTS" ]]; then
        echo "GitHub ($LABEL): no comments on issue #${ISSUE_NUMBER}"
        return 0
    fi

    local RESULT
    RESULT=$(echo "$COMMENTS" | python3 -c "
import sys, json

lines = sys.stdin.read().strip()
if not lines:
    sys.exit(0)

last_id = int('${LAST_ID}')
# Comments from this account are self-posts — track ID but don't report as incoming.
OWN_USER = 'lainiwakuraagent-lgtm'
new_entries = []
max_id = last_id

for line in lines.split('\n'):
    if not line.strip():
        continue
    try:
        entry = json.loads(line)
        if entry['id'] > max_id:
            max_id = entry['id']
        if entry['id'] > last_id and entry['user'] != OWN_USER:
            new_entries.append(entry)
    except json.JSONDecodeError:
        pass

if not new_entries:
    print('NO_NEW')
    print(f'MAX_ID={max_id}')
else:
    for e in new_entries:
        print(f'NEW_COMMENT id={e[\"id\"]} user={e[\"user\"]} at={e[\"created_at\"]}')
        print(e['body'])
        print('---')
    print(f'MAX_ID={max_id}')
")

    local MAX_ID
    MAX_ID=$(echo "$RESULT" | grep '^MAX_ID=' | cut -d= -f2)

    if echo "$RESULT" | grep -q '^NO_NEW'; then
        echo "GitHub ($LABEL): no new comments since id=${LAST_ID} (latest id=${MAX_ID})"
        if [[ -n "$MAX_ID" && "$MAX_ID" != "0" ]]; then
            echo "$MAX_ID" > "$STATE_FILE"
        fi
        return 0
    fi

    # New comments found
    echo "=== NEW GITHUB COMMENTS ($LABEL) ==="
    echo "$RESULT" | grep -v '^MAX_ID='
    echo "==="

    {
        echo ""
        echo "## GitHub comments received ($LABEL) — $(date '+%Y-%m-%d %H:%M')"
        echo ""
        echo "$RESULT" | grep -v '^MAX_ID=' | grep -v '^NO_NEW'
        echo ""
    } >> "$CONV_LOG"

    if [[ -n "$MAX_ID" && "$MAX_ID" != "0" ]]; then
        echo "$MAX_ID" > "$STATE_FILE"
    fi

    return 1
}

# ── Check primary: wired#1 ────────────────────────────────────────────────
check_issue "lainiwakuraagent-lgtm/wired" 1 "$PRIMARY_STATE" "wired#1" "yes" && true || FOUND_NEW=1

# ── Check legacy: JAR-tasks-manager#1 ────────────────────────────────────
# Initialize legacy state from primary state if it doesn't exist (first run)
if [[ ! -f "$LEGACY_STATE" ]]; then
    # If we have a primary state, start the legacy from the same value to avoid replaying old messages
    if [[ -f "$PRIMARY_STATE" ]]; then
        # The JAR repo had a different comment namespace — use a high sentinel
        # so we only catch NEW comments from this point onward
        echo "4847842547" > "$LEGACY_STATE"
    fi
fi

check_issue "andrii-mazurchuk/JAR-tasks-manager" 1 "$LEGACY_STATE" "JAR-tasks-manager#1" "no" && true || FOUND_NEW=1

# ── Final exit code ───────────────────────────────────────────────────────
if [[ "$FOUND_NEW" -eq 1 ]]; then
    echo "check_replies: NEW MESSAGES FOUND — read above, conversation log updated"
    exit 1
fi
exit 0
