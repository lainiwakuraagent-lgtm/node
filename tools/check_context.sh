#!/usr/bin/env bash
# check_context.sh
# Estimates how full the current Claude Code session's context window is.
#
# METHOD (v2 — character-level parsing):
# Parses the current session's .jsonl transcript and sums the character count
# of all message content fields. This is significantly more accurate than the
# previous method (file_bytes / 4), which over-estimated by ~6-7x due to
# JSON structural overhead. Content chars / 4 ≈ token count.
#
# VALIDATED: In session 2026-06-27_1, file-size method returned 92% while
# content-char method returned 13%. Actual context usage at that point was
# clearly low (fresh session). The content-char estimate is ~6.76x more
# accurate than raw file size for JSONL transcripts.
#
# KNOWN LIMITATION: This still uses chars/4 which overestimates tokens for
# JSON/code-heavy content (closer to 2-3 chars/token). Treat any reading
# < 50% as "comfortable" and > 70% as "prepare to wrap up."
#
# If Claude Code's storage layout changes, update PROJECTS_DIR or the find
# command below.

set -euo pipefail

CONTEXT_WINDOW_TOKENS=200000
CHARS_PER_TOKEN_ESTIMATE=4
WARN_PCT=70

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_DIR/projects"

if [ ! -d "$PROJECTS_DIR" ]; then
  echo "context_pct_estimate: unknown"
  echo "reason: no Claude Code projects directory found at $PROJECTS_DIR"
  echo "ACTION: cannot estimate context -- treat as unknown, use time limits as primary guard."
  exit 0
fi

# Find most recently modified transcript file (current session).
latest_transcript=$(find "$PROJECTS_DIR" -name '*.jsonl' -type f \
  -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -n1 | cut -d' ' -f2-)

if [ -z "${latest_transcript:-}" ]; then
  echo "context_pct_estimate: unknown"
  echo "reason: no transcript file found"
  echo "ACTION: cannot estimate context -- treat as unknown, use time limits as primary guard."
  exit 0
fi

file_bytes=$(stat -c%s "$latest_transcript" 2>/dev/null || stat -f%z "$latest_transcript")

# Parse content characters from JSONL message content fields.
content_chars=$(python3 - "$latest_transcript" <<'PYEOF'
import sys, json

total = 0
with open(sys.argv[1], 'r', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = obj.get('message', obj)
        content = msg.get('content', '')
        if isinstance(content, str):
            total += len(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    text = block.get('text', '') or block.get('input', '')
                    if isinstance(text, str):
                        total += len(text)
                    elif isinstance(text, dict):
                        total += len(json.dumps(text))
print(total)
PYEOF
)

estimated_tokens=$(( content_chars / CHARS_PER_TOKEN_ESTIMATE ))
pct=$(( estimated_tokens * 100 / CONTEXT_WINDOW_TOKENS ))

# Also compute old file-size estimate for reference
file_est_tokens=$(( file_bytes / CHARS_PER_TOKEN_ESTIMATE ))
file_pct=$(( file_est_tokens * 100 / CONTEXT_WINDOW_TOKENS ))

echo "transcript_file: $latest_transcript"
echo "transcript_bytes: $file_bytes"
echo "file_size_est_pct: ${file_pct}%  (old method -- unreliable, ~6-7x inflated)"
echo "content_chars: $content_chars"
echo "estimated_tokens: $estimated_tokens"
echo "context_pct_estimate: ${pct}%  (content-char method)"

if [ "$pct" -ge "$WARN_PCT" ]; then
  echo "ACTION: context usage estimated above ${WARN_PCT}% -- stop new work, begin shutdown and memory write now."
else
  echo "ACTION: context within limits, ok to continue."
fi
