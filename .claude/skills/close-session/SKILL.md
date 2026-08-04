---
name: close-session
description: Close an interactive session cleanly — write handoff notes to latest_summary.md, update memory files, log to session_log.csv. Use at the end of any manual/interactive session. Invokable as /wrap.
argument-hint: [brief description of what happened this session]
allowed-tools: Read Write Edit Bash
---

This skill closes an interactive session. Execute the steps below in order. Do not skip steps — each one matters for continuity. This runs WITHOUT wake.sh infrastructure, so do everything manually.

`PROJECT_DIR` is the project root — resolve it once at the start and reuse it:
```bash
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
AGENT_NAME=$(grep -oP '(?<=^AGENT_NAME=).*' "$PROJECT_DIR/state/agent_config.env" 2>/dev/null || echo "agent")
```
Interactive sessions are normally launched with the project directory as cwd, so the
`$(pwd)` fallback is almost always correct; only trust an explicitly-set `PROJECT_DIR`
over it.

---

## Step 1 — Gather state

Run these and record the values:

```bash
cat "$PROJECT_DIR/state/trigger_mode.txt" 2>/dev/null || echo "manual"
bash "$PROJECT_DIR/tools/executional/check_context.sh" 2>/dev/null | grep "context_pct_estimate" | grep -oP '\d+(?=%)'
SESSION_EPOCH=$(cat "$PROJECT_DIR/state/session_start_epoch" 2>/dev/null || echo 0)
[ "$SESSION_EPOCH" -gt 0 ] && echo $(( ($(date +%s) - $SESSION_EPOCH) / 60 )) || echo "unknown"
cat "$PROJECT_DIR/state/current_loom_session_id.txt" 2>/dev/null || echo "no-loom-session"
```

---

## Step 2 — Read current state

Read these files to understand context before writing anything:

- `memory/latest_summary.md` — previous HOT STATE, so the new one is coherent
- `state/loom_context.json` — current Loom task and queue

---

## Step 3 — Determine session summary

If `$ARGUMENTS` was provided, use it as the session summary basis.

If not, derive the summary from the conversation context — look back at what was discussed and done in this session. Be honest about what actually happened, not what was intended.

---

## Step 4 — Write latest_summary.md

Overwrite `$PROJECT_DIR/memory/latest_summary.md` with this exact structure:

```
## HOT STATE: [3 lines max — emergency mode? blockers? session type? next action?]
## Blockers: [bullet list, or "NONE"]
## Next action: [1 line — what the next session should do first]

## Detail

Session YYYY-MM-DD manual_N (~X min, interactive)

### What this session did

[Paragraph or bullet list: what was worked on, what was decided, what changed.]

### For next session

[What the next session needs to know that isn't captured elsewhere.]

### Still open

[Items that are unresolved or waiting on the owner.]
```

Keep it under 500 words total. Write for "a future instance with zero memory."

---

## Step 5 — Write notes (if applicable)

**`memory/identity/${AGENT_NAME}_notes.md`** — if any ideas, observations, or philosophical threads arose that are worth keeping:
Append a dated entry to `$PROJECT_DIR/memory/identity/${AGENT_NAME}_notes.md`.
Format: `### YYYY-MM-DD — [title]\n[content]`

**`narrative_log.md`** — if something meaningful shifted about identity, relationship, or direction:
Append a dated entry to `$PROJECT_DIR/memory/narrative_log.md`.
Four-question format:
1. What happened this session?
2. Why did it matter?
3. What changed (about the agent, the system, or the relationship)?
4. Narrative update — one sentence that carries the thread forward.

Skip these if nothing is worth recording. Do not write entries just to have entries.

---

## Step 6 — Update progress.md (if needed)

If something was completed, decided, or significantly changed this session:
Edit `$PROJECT_DIR/memory/progress.md` to add a brief session entry.

Insert it near the top of the file (after the "## Overall Goal" block), using the format:
```
## Session manual_N (YYYY-MM-DD HH:MM) — [session type: interactive/architecture/execution/etc.]

**[One sentence: what this session accomplished or decided.]**

- Bullet points of key actions taken
- Decisions made
- What's blocked or pending

---
```

If nothing substantial changed, skip this step.

---

## Step 7 — Write session_log.csv entry

Append one line to `$PROJECT_DIR/logs/session_log.csv`:

```
YYYY-MM-DDTHH:MM:SS,interactive,<duration_min>,<context_pct>,<one_line_summary>
```

Get current time with: `date +%Y-%m-%dT%H:%M:%S`

---

## Step 8 — Write analytics record

```bash
CONTEXT_PCT=$(bash "$PROJECT_DIR/tools/executional/check_context.sh" 2>/dev/null | grep "context_pct_estimate" | grep -oP '\d+(?=%)')
/usr/bin/python3 "$PROJECT_DIR/tools/executional/analytics_write.py" \
  --session-type interactive \
  --exit-reason natural_stop \
  --summary "<one-line summary>" \
  --tasks-completed <N> \
  --context-pct ${CONTEXT_PCT:-0}
```

Non-fatal — if analytics_write.py fails, log a note and continue.

---

## Step 9 — Write session report

```bash
SESSION_DATE=$(date +%Y-%m-%d)
SESSION_N=$(ls "$PROJECT_DIR/state/reports/${SESSION_DATE}_"*.md 2>/dev/null | wc -l)
SESSION_N=$((SESSION_N + 1))
/usr/bin/python3 "$PROJECT_DIR/tools/executional/session_report.py" \
  --sessions 1 \
  --output "$PROJECT_DIR/state/reports/${SESSION_DATE}_${SESSION_N}.md" 2>/dev/null || true
/usr/bin/python3 "$PROJECT_DIR/tools/executional/session_report.py" --sessions 3 2>/dev/null || true
/usr/bin/python3 "$PROJECT_DIR/tools/executional/report_archive.py" index 2>/dev/null || true
```

Non-fatal.

---

## Step 10 — Close Loom session (if applicable)

Check `state/current_loom_session_id.txt`. If it exists and contains a number:

```bash
LOOM_ID=$(cat "$PROJECT_DIR/state/current_loom_session_id.txt")
PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli \
  --db ~/.local/share/loom/loom.db \
  session end --id "$LOOM_ID" --handoff "<one-line next action>"
```

If the file doesn't exist or is empty, skip this step.

---

## Step 11 — Confirm

Report to the owner what was written:
- latest_summary.md: updated / skipped
- `${AGENT_NAME}_notes.md`: new entry / skipped
- narrative_log.md: new entry / skipped
- progress.md: updated / skipped
- session_log.csv: new entry written
- analytics: written / failed
- Loom session: closed / no session

Keep it brief.

If `CONV_ACTIVE` (a conversational session is running), check:
```bash
CONV_LOCK="$PROJECT_DIR/state/conversation.lock"
[ -f "$CONV_LOCK" ] && kill -0 "$(cat "$CONV_LOCK")" 2>/dev/null && echo "conv-active" || echo "conv-inactive"
```
If conv-active: do NOT send a Telegram message. Just print the summary to the terminal.
If conv-inactive: optionally send a brief Telegram close notification via:
`printf '%s' "message" | bash "$PROJECT_DIR/tools/conversational/telegram_send.sh"`
