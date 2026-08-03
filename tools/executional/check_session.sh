#!/usr/bin/env bash
# check_session.sh — Unified session health checks.
#
# Subcommands:
#   --usage    Check real account-level subscription utilization (rate-limit headers)
#   --context  Estimate current session's context window fill percentage
#   --time     Report wall-clock time and nightly work-window status
#
# Each subcommand exits 0 in all cases (including internal errors) and prints
# an ACTION line for the caller to parse. This preserves the exact output
# format of the three scripts this replaces (check_usage.sh, check_context.sh,
# check_time.sh), so existing callers only need their invocation updated.
#
# Usage:
#   bash tools/check_session.sh --usage
#   bash tools/check_session.sh --context
#   bash tools/check_session.sh --time

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# =============================================================================
# --usage — real account-level subscription utilization
#
# Makes a minimal API call (1 token, cheapest model) and reads the rate-limit
# headers that Anthropic returns on every response.
#
# Thresholds (configurable via env vars):
#   USAGE_THRESHOLD_5H  -- rolling 5-hour utilization (0.0-1.0). Default: 0.70
#   USAGE_THRESHOLD_7D  -- rolling 7-day utilization  (0.0-1.0). Default: 0.80
# =============================================================================
cmd_usage() {
  local THRESHOLD_5H="${USAGE_THRESHOLD_5H:-0.70}"
  local THRESHOLD_7D="${USAGE_THRESHOLD_7D:-0.80}"
  local PROBE_MODEL="claude-haiku-4-5-20251001"
  local CREDENTIALS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  local API_URL="https://api.anthropic.com/v1/messages"

  if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "usage_check_status: error"
    echo "reason: credentials file not found at $CREDENTIALS_FILE"
    echo "ACTION: cannot check usage -- treat as unknown, proceed with caution."
    return 0
  fi

  local access_token
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

  local header_file body_file
  header_file=$(mktemp)
  body_file=$(mktemp)
  trap 'rm -f "$header_file" "$body_file"' RETURN

  local http_code
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
    return 0
  fi

  if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
    echo "usage_check_status: error"
    echo "reason: auth error (HTTP $http_code) -- token may be expired"
    echo "ACTION: cannot check usage -- treat as unknown, proceed with caution."
    return 0
  fi

  local util_5h util_7d status_5h status_7d reset_5h reset_7d
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
    return 0
  fi

  local reset_5h_human="" reset_7d_human=""
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

  local block_reason=""

  if [ -n "$util_5h" ]; then
    local over_5h
    over_5h=$(python3 -c "print('yes' if float('$util_5h') > float('$THRESHOLD_5H') else 'no')" 2>/dev/null || echo "no")
    if [ "$over_5h" = "yes" ]; then
      local pct_5h thr_5h
      pct_5h=$(python3 -c "print(f'{float(\"$util_5h\")*100:.0f}')")
      thr_5h=$(python3 -c "print(f'{float(\"$THRESHOLD_5H\")*100:.0f}')")
      block_reason="5h utilization ${pct_5h}% exceeds threshold ${thr_5h}%"
    fi
  fi

  if [ -n "$util_7d" ] && [ -z "$block_reason" ]; then
    local over_7d
    over_7d=$(python3 -c "print('yes' if float('$util_7d') > float('$THRESHOLD_7D') else 'no')" 2>/dev/null || echo "no")
    if [ "$over_7d" = "yes" ]; then
      local pct_7d thr_7d
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
}

# =============================================================================
# --context — real context window fill percentage
#
# METHOD (v3 — real API usage, not estimated): every assistant transcript
# entry carries the real usage field from the Anthropic API response
# (input_tokens, cache_creation_input_tokens, cache_read_input_tokens) --
# the exact token count the model was actually sent on that turn. Reads the
# LAST such entry directly instead of reconstructing an approximation from
# raw transcript characters.
#
# Prior char-counting methods (v1: file_bytes/4, v2: content_chars/4) were
# both estimates and both wrong in ways that compounded: v2 silently excluded
# tool_result and thinking block content (stored under 'content'/'thinking'
# keys, not the 'text'/'input' keys it checked), and even correcting for
# that, chars/4 undercounted real usage by roughly 2x for tool/code-heavy
# sessions. Measured on a real session: v2 reported 15% where real usage was
# 40%.
# =============================================================================
cmd_context() {
  local CONTEXT_WINDOW_TOKENS=200000
  local EXTENDED_CONTEXT_WINDOW_TOKENS=1000000
  local WARN_PCT=70

  local CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local PROJECTS_DIR="$CLAUDE_DIR/projects"

  if [ ! -d "$PROJECTS_DIR" ]; then
    echo "context_pct_estimate: unknown"
    echo "reason: no Claude Code projects directory found at $PROJECTS_DIR"
    echo "ACTION: cannot estimate context -- treat as unknown, use time limits as primary guard."
    return 0
  fi

  # Scope the transcript search to the current project's directory.
  # Priority 1: CLAUDE_CODE_SESSION_ID + project slug (exact, no globbing needed).
  # Priority 2: find most-recent in current project's transcript dir (scoped, not all projects).
  # Priority 3: fallback to all projects (broken original behavior, only if scoped dir missing).
  local project_slug SCOPED_DIR
  project_slug=$(echo "$PROJECT_DIR" | sed 's|[/_]|-|g')
  SCOPED_DIR="$PROJECTS_DIR/${project_slug}"

  local latest_transcript
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -f "$SCOPED_DIR/${CLAUDE_CODE_SESSION_ID}.jsonl" ]; then
    latest_transcript="$SCOPED_DIR/${CLAUDE_CODE_SESSION_ID}.jsonl"
  elif [ -d "$SCOPED_DIR" ]; then
    latest_transcript=$(find "$SCOPED_DIR" -name '*.jsonl' -type f \
      -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -n1 | cut -d' ' -f2-) || true
  else
    latest_transcript=$(find "$PROJECTS_DIR" -name '*.jsonl' -type f \
      -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -n1 | cut -d' ' -f2-) || true
  fi

  if [ -z "${latest_transcript:-}" ]; then
    echo "context_pct_estimate: unknown"
    echo "reason: no transcript file found"
    echo "ACTION: cannot estimate context -- treat as unknown, use time limits as primary guard."
    return 0
  fi

  # Read the real usage field from the last assistant entry in the transcript.
  local usage_line
  usage_line=$(python3 - "$latest_transcript" <<'PYEOF'
import sys, json

latest_usage = {}
with open(sys.argv[1], 'r', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get('type') != 'assistant':
            continue
        usage = obj.get('message', obj).get('usage')
        if usage:
            latest_usage = usage

inp = latest_usage.get('input_tokens', 0)
cc = latest_usage.get('cache_creation_input_tokens', 0)
cr = latest_usage.get('cache_read_input_tokens', 0)
print(inp, cc, cr, inp + cc + cr)
PYEOF
)
  local input_tokens cache_creation_tokens cache_read_tokens real_context_tokens
  read -r input_tokens cache_creation_tokens cache_read_tokens real_context_tokens <<< "$usage_line"

  # A successful API call can't exceed the model's actual context window, so if
  # real usage is already above the standard 200k, the call must have run under
  # the extended (1M) context beta -- switch denominators rather than report
  # a nonsensical >100%. This matters for the conversational/Telegram layer,
  # which can legitimately use extended context for long-running threads.
  local window="$CONTEXT_WINDOW_TOKENS"
  if [ "$real_context_tokens" -gt "$CONTEXT_WINDOW_TOKENS" ]; then
    window="$EXTENDED_CONTEXT_WINDOW_TOKENS"
  fi
  local pct=$(( real_context_tokens * 100 / window ))

  echo "transcript_file: $latest_transcript"
  echo "real_input_tokens: $input_tokens"
  echo "real_cache_creation_tokens: $cache_creation_tokens"
  echo "real_cache_read_tokens: $cache_read_tokens"
  echo "real_context_tokens: $real_context_tokens"
  echo "context_window_used: $window"
  echo "context_pct_estimate: ${pct}%  (real API usage, not estimated)"

  if [ "$pct" -ge "$WARN_PCT" ]; then
    echo "ACTION: context usage estimated above ${WARN_PCT}% -- stop new work, begin shutdown and memory write now."
  else
    echo "ACTION: context within limits, ok to continue."
  fi
}

# =============================================================================
# --time — wall-clock time and nightly work-window status
#
# Never trust an LLM's internal sense of time -- this is the single source
# of truth. Emergency mode override: if state/emergency_mode.active exists,
# the work window is considered always open.
# =============================================================================
cmd_time() {
  local EMERGENCY_FLAG="$PROJECT_DIR/state/emergency_mode.active"

  local WINDOW_START_HOUR=23   # 23:00
  local WINDOW_END_HOUR=6      # 06:00

  local now_epoch now_human hour minute
  now_epoch=$(date +%s)
  now_human=$(date '+%Y-%m-%d %H:%M:%S %Z')
  hour=$(date +%H)
  hour=$((10#$hour))  # force base-10 (avoid octal parsing of "08", "09")
  minute=$(date +%M)
  minute=$((10#$minute))

  if [ -f "$EMERGENCY_FLAG" ]; then
    local emergency_reason
    emergency_reason=$(cat "$EMERGENCY_FLAG" 2>/dev/null | head -1 || echo "active")
    echo "current_time: $now_human"
    echo "in_work_window: true"
    echo "minutes_remaining_until_window_close: 9999"
    echo "emergency_mode: ACTIVE ($emergency_reason)"
    echo "ACTION: emergency mode -- window always open, no time-based shutdown."
    return 0
  fi

  local in_window
  if [ "$hour" -ge "$WINDOW_START_HOUR" ] || [ "$hour" -lt "$WINDOW_END_HOUR" ]; then
    in_window="true"
  else
    in_window="false"
  fi

  local end_epoch
  if [ "$hour" -lt "$WINDOW_END_HOUR" ]; then
    end_epoch=$(date -d "today ${WINDOW_END_HOUR}:00:00" +%s)
  else
    end_epoch=$(date -d "tomorrow ${WINDOW_END_HOUR}:00:00" +%s)
  fi
  local minutes_remaining=$(( (end_epoch - now_epoch) / 60 ))

  echo "current_time: $now_human"
  echo "in_work_window: $in_window"
  echo "minutes_remaining_until_window_close: $minutes_remaining"

  if [ "$in_window" = "false" ]; then
    echo "ACTION: outside work window -- do not proceed with goal work, shut down now."
  elif [ "$minutes_remaining" -lt 15 ]; then
    echo "ACTION: less than 15 minutes remain -- treat as window closing, begin shutdown."
  fi
}

case "${1:-}" in
  --usage) cmd_usage ;;
  --context) cmd_context ;;
  --time) cmd_time ;;
  *)
    echo "Usage: check_session.sh --usage|--context|--time" >&2
    exit 1
    ;;
esac
