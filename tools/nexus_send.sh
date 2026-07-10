#!/usr/bin/env bash
# nexus_send.sh — Send a message to a Nexus conversation from stdin or argument.
#
# Usage:
#   echo "hello" | bash tools/nexus_send.sh <conversation_id>
#   printf '%s' "message" | bash tools/nexus_send.sh <conversation_id>
#   bash tools/nexus_send.sh <conversation_id> "message text"
#
# Environment:
#   NEXUS_URL          (default: http://100.110.36.84:8900)
#   NEXUS_USERNAME     (default: lain)
#   NEXUS_PASSWORD     (from state/nexus_lain_credentials.txt if not set)
#
# The script authenticates fresh on each call to avoid token expiry issues.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXUS_URL="${NEXUS_URL:-http://100.110.36.84:8900}"
NEXUS_USERNAME="${NEXUS_USERNAME:-lain}"

# Load password from credentials file if not in env
if [ -z "${NEXUS_PASSWORD:-}" ]; then
    PASS_FILE="$PROJECT_DIR/identity/nexus_seed_passwords.txt"
    if [ -f "$PASS_FILE" ]; then
        NEXUS_PASSWORD=$(grep "^# lain" "$PASS_FILE" | grep -o '[^ ]*$' | head -1)
    fi
fi

if [ -z "${NEXUS_PASSWORD:-}" ]; then
    echo "ERROR: NEXUS_PASSWORD not set and could not read from identity/nexus_seed_passwords.txt" >&2
    exit 1
fi

CONV_ID="${1:?Usage: nexus_send.sh <conversation_id> [message]}"

# Read message from second arg or stdin
if [ "${2:-}" != "" ]; then
    MESSAGE="$2"
else
    MESSAGE=$(cat)
fi

if [ -z "$MESSAGE" ]; then
    echo "ERROR: empty message" >&2
    exit 1
fi

# Authenticate to get token
TOKEN=$(curl -s -X POST "$NEXUS_URL/auth/token" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$NEXUS_USERNAME\",\"password\":\"$NEXUS_PASSWORD\"}" \
    | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('access_token',''))")

if [ -z "$TOKEN" ]; then
    echo "ERROR: authentication failed" >&2
    exit 1
fi

# Send message
RESULT=$(curl -s -X POST "$NEXUS_URL/conversations/$CONV_ID/messages" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(/usr/bin/python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$MESSAGE")")

MSG_ID=$(/usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id','?')[:8])" <<< "$RESULT" 2>/dev/null || echo "?")
echo "sent nexus message id=${MSG_ID}"
