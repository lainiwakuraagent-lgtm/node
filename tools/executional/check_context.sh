#!/usr/bin/env bash
# check_context.sh
# Reports how full the current Claude Code session's context window is.
#
# METHOD (v3 — real API usage, not estimated):
# Every assistant transcript entry already carries the real usage field from
# the Anthropic API response (input_tokens, cache_creation_input_tokens,
# cache_read_input_tokens) -- the exact token count the model was actually
# sent on that turn. This reads the LAST such entry directly instead of
# reconstructing an approximation from raw transcript characters.
#
# Prior char-counting methods (v1: file_bytes/4, v2: content_chars/4) were
# both estimates and both wrong in ways that compounded: v2 silently excluded
# tool_result and thinking block content (stored under 'content'/'thinking'
# keys, not the 'text'/'input' keys it checked), and even correcting for that,
# chars/4 undercounted real usage by roughly 2x for tool/code-heavy sessions.
# Measured on a real session: v2 reported 15% where real usage was 40%.
#
# If Claude Code's storage layout changes, update PROJECTS_DIR or the find
# command below.

set -euo pipefail

CONTEXT_WINDOW_TOKENS=200000
EXTENDED_CONTEXT_WINDOW_TOKENS=1000000
WARN_PCT=70

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_DIR/projects"

if [ ! -d "$PROJECTS_DIR" ]; then
  echo "context_pct_estimate: unknown"
  echo "reason: no Claude Code projects directory found at $PROJECTS_DIR"
  echo "ACTION: cannot estimate context -- treat as unknown, use time limits as primary guard."
  exit 0
fi

# Scope the transcript search to the current project's directory.
# Priority 1: CLAUDE_CODE_SESSION_ID + project slug (exact, no globbing needed).
# Priority 2: find most-recent in current project's transcript dir (scoped, not all projects).
# Priority 3: fallback to all projects (broken original behavior, only if scoped dir missing).
#
# CLAUDE_CODE_SESSION_ID is exported by Claude Code when running as an agent.
# project_slug: replace / and _ with - to match Claude Code's directory naming.
PROJECT_DIR_FOR_SLUG="${PROJECT_DIR:-$(pwd)}"
project_slug=$(echo "$PROJECT_DIR_FOR_SLUG" | sed 's|[/_]|-|g')
SCOPED_DIR="$PROJECTS_DIR/${project_slug}"

latest_transcript=""
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
  exit 0
fi

# Read the real usage field from the last assistant entry in the transcript.
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
read -r input_tokens cache_creation_tokens cache_read_tokens real_context_tokens <<< "$usage_line"

# A successful API call can't exceed the model's actual context window, so if
# real usage is already above the standard 200k, the call must have run under
# the extended (1M) context beta -- switch denominators rather than report
# a nonsensical >100%. This matters for the conversational/Telegram layer,
# which can legitimately use extended context for long-running threads.
window="$CONTEXT_WINDOW_TOKENS"
if [ "$real_context_tokens" -gt "$CONTEXT_WINDOW_TOKENS" ]; then
  window="$EXTENDED_CONTEXT_WINDOW_TOKENS"
fi
pct=$(( real_context_tokens * 100 / window ))

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
