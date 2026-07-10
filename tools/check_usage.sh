#!/usr/bin/env bash
# check_usage.sh
# Checks real account-level subscription utilization by making a minimal API
# call (1 token, cheapest model) and reading the rate-limit headers that
# Anthropic returns on every response.
#
# Exits 0 in all cases (including errors) so wake.sh can always read output.
# The caller should parse the ACTION line to decide whether to abort.
#
# Thresholds (configurable via env vars):
#   USAGE_THRESHOLD_5H  -- rolling 5-hour utilization (0.0-1.0). Default: 0.70
#   USAGE_THRESHOLD_7D  -- rolling 7-day utilization  (0.0-1.0). Default: 0.80

set -euo pipefail

THRESHOLD_5H="${USAGE_THRESHOLD_5H:-0.70}"
THRESHOLD_7D="${USAGE_THRESHOLD_7D:-0.80}"
PROBE_MODEL="claude-haiku-4-5-20251001"
CREDENTIALS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
API_URL="https://api.anthropic.com/v1/messages"

# --- Read access token ---
if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "usage_check_status: error"
    echo "reason: credentials file not found at $CREDENTIALS_FILE"
    echo "ACTION: cannot check usage -- treat as unknown, proceed with caution."
    exit 0
fi

access_token=$(python3 - "$CREDENTIALS_FILE" <<'EOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d["claudeAiOauth"]["accessToken"])
except Exception as e:
    print("ERROR: " + str(e), file=sys.stderr)
    sys.exit(1)
EOF
)

# --- Make minimal probe call, capture headers ---
header_file=$(mktemp)
body_file=$(mktemp)
trap 'rm -f "$header_file" "$body_file"' EXIT

http_code=$(curl -s -o "$body_file" -D "$header_file" -w "%{http_code}" \
    --max-time 15 \
    -X POST "$API_URL" \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"$PROBE_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    2>/dev/null || echo "000")

if [ "$http_code" = "000" ]; then
    echo "usage_check_status: error"
    echo "reason: curl failed (network unreachable or timeout)"
    echo "ACTION: cannot check usage -- treat as unknown, proceed with caution."
    exit 0
fi

if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
    echo "usage_check_status: error"
    echo "reason: auth error (HTTP $http_code) -- token may be expired"
    echo "ACTION: cannot check usage -- treat as unknown, proceed with caution."
    exit 0
fi

# --- Parse utilization headers ---
util_5h=$(grep -i '^anthropic-ratelimit-unified-5h-utilization:' "$header_file" \
    | awk '{print $2}' | tr -d '[:space:]' || echo "")
util_7d=$(grep -i '^anthropic-ratelimit-unified-7d-utilization:' "$header_file" \
    | awk '{print $2}' | tr -d '[:space:]' || echo "")
status_5h=$(grep -i '^anthropic-ratelimit-unified-5h-status:' "$header_file" \
    | awk '{print $2}' | tr -d '[:space:]' || echo "unknown")
status_7d=$(grep -i '^anthropic-ratelimit-unified-7d-status:' "$header_file" \
    | awk '{print $2}' | tr -d '[:space:]' || echo "unknown")
reset_5h=$(grep -i '^anthropic-ratelimit-unified-5h-reset:' "$header_file" \
    | awk '{print $2}' | tr -d '[:space:]' || echo "")
reset_7d=$(grep -i '^anthropic-ratelimit-unified-7d-reset:' "$header_file" \
    | awk '{print $2}' | tr -d '[:space:]' || echo "")

if [ -z "$util_5h" ] && [ -z "$util_7d" ]; then
    echo "usage_check_status: error"
    echo "reason: no utilization headers in response (HTTP $http_code) -- API may have changed"
    echo "ACTION: cannot check usage -- treat as unknown, proceed with caution."
    exit 0
fi

# Convert epoch resets to human-readable
reset_5h_human=""
reset_7d_human=""
if [ -n "$reset_5h" ] && [ "$reset_5h" -gt 0 ] 2>/dev/null; then
    reset_5h_human=$(date -d "@$reset_5h" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$reset_5h")
fi
if [ -n "$reset_7d" ] && [ "$reset_7d" -gt 0 ] 2>/dev/null; then
    reset_7d_human=$(date -d "@$reset_7d" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$reset_7d")
fi

echo "usage_check_status: ok"
echo "utilization_5h: ${util_5h:-unknown}  (status: $status_5h, resets: ${reset_5h_human:-unknown})"
echo "utilization_7d: ${util_7d:-unknown}  (status: $status_7d, resets: ${reset_7d_human:-unknown})"
echo "threshold_5h: $THRESHOLD_5H"
echo "threshold_7d: $THRESHOLD_7D"

# --- Threshold checks (python3 for reliable float comparison) ---
block_reason=""

if [ -n "$util_5h" ]; then
    over_5h=$(python3 -c "print('yes' if float('$util_5h') > float('$THRESHOLD_5H') else 'no')" 2>/dev/null || echo "no")
    if [ "$over_5h" = "yes" ]; then
        pct_5h=$(python3 -c "print(f'{float(\"$util_5h\")*100:.0f}')")
        thr_5h=$(python3 -c "print(f'{float(\"$THRESHOLD_5H\")*100:.0f}')")
        block_reason="5h utilization ${pct_5h}% exceeds threshold ${thr_5h}%"
    fi
fi

if [ -n "$util_7d" ] && [ -z "$block_reason" ]; then
    over_7d=$(python3 -c "print('yes' if float('$util_7d') > float('$THRESHOLD_7D') else 'no')" 2>/dev/null || echo "no")
    if [ "$over_7d" = "yes" ]; then
        pct_7d=$(python3 -c "print(f'{float(\"$util_7d\")*100:.0f}')")
        thr_7d=$(python3 -c "print(f'{float(\"$THRESHOLD_7D\")*100:.0f}')")
        block_reason="7d utilization ${pct_7d}% exceeds threshold ${thr_7d}%"
    fi
fi

if [ -n "$block_reason" ]; then
    echo "ACTION: usage limit exceeded ($block_reason) -- do not launch session."
else
    echo "ACTION: usage within limits, ok to proceed."
fi
