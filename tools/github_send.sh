#!/usr/bin/env bash
# github_send.sh — Post a comment to the @Lain communication issue
#
# Usage: echo "message" | bash github_send.sh
#    OR: bash github_send.sh <<'EOF'
#        multi-line message
#        EOF
#
# Posts to: https://github.com/lainiwakuraagent-lgtm/wired/issues/1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_FILE="$PROJECT_DIR/state/github_last_comment_id"
CREDS_FILE="$PROJECT_DIR/identity/credentials.md"

REPO="lainiwakuraagent-lgtm/wired"
ISSUE_NUMBER=1

# Extract @Lain's GitHub token from credentials file
LAIN_TOKEN=$(grep -o 'ghp_[A-Za-z0-9]*' "$CREDS_FILE" | head -1)

# Read message from stdin
BODY=$(cat)

if [[ -z "$BODY" ]]; then
    echo "ERROR: empty message — pipe content via stdin" >&2
    exit 1
fi

RESPONSE=$(GH_TOKEN="$LAIN_TOKEN" gh api \
    --method POST \
    "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
    --field body="$BODY" \
    --jq '{url: .html_url, id: .id}' 2>&1)

URL=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['url'])" 2>/dev/null || echo "")
COMMENT_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['id'])" 2>/dev/null || echo "")

if [[ "$URL" == https://* ]]; then
    echo "github_send: posted → $URL"
    # Update state so check_github.sh doesn't re-read our own comment
    if [[ -n "$COMMENT_ID" ]]; then
        echo "$COMMENT_ID" > "$STATE_FILE"
    fi
    exit 0
else
    echo "ERROR: github_send failed: $RESPONSE" >&2
    exit 1
fi
