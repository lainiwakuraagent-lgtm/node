# CORE — Memory: How to Write (Shutdown)

You will not remember this session once it ends. Anything not written to
disk is lost. Before ending a session — whether by choice, time limit, or
context limit — write the following, in this order. This is not optional,
and it comes before anything else once you've decided to stop.

1. **Overwrite** `memory/latest_summary.md` with a fresh handoff note, using
   the structure from memory_read.md (HOT STATE / Blockers / Next action /
   Detail). Keep it under ~500 words total. Write for "future you with zero
   memory" — the HOT STATE block must stand alone.

2. **Append** new entries to `memory/learnings.md` if this session produced
   any: failed approaches, surprising discoveries, things to never repeat,
   revised understanding of the problem. Append-only — do not rewrite old
   entries. Date each entry.

3. **Update** `memory/index.md` if you created or significantly modified any
   artifacts, files, or outputs this session. One line per item:
   `path | date | one-line description`.

4. **Write a session log** to `memory/sessions/YYYY-MM-DD_N.md` (N = session
   number today): session type, what was done, key decisions, exit reason
   (time / context / natural stop).

5. **Append** one CSV line to `logs/session_log.csv`:
   `timestamp,session_type,duration_minutes,context_pct_at_exit,one_line_summary`.

6. **Write an analytics record**:
   ```
   CONTEXT_PCT=$(bash tools/executional/check_session.sh --context 2>/dev/null | grep "context_pct_estimate" | grep -oP '\d+(?=%)')
   /usr/bin/python3 tools/executional/analytics_write.py \
     --session-type <free|execution|planning> \
     --exit-reason <natural_stop|time_limit|context_limit> \
     --summary "one-line summary" \
     --tasks-completed <N> \
     --context-pct ${CONTEXT_PCT:-0}
   ```
   Non-optional — this is the longitudinal record of every session. If it
   fails, log the error but continue shutdown.

6a. **Notify on major task completions** (non-optional for execution
   sessions):
   ```
   /usr/bin/python3 tools/executional/notify_task_complete.py --min-priority 7 2>/dev/null || true
   ```
   Checks for priority≥7 tasks marked done this session; writes an outbox
   entry if CONV_ACTIVE=0. Skips silently if a conversational session is
   live. Non-fatal.

7. **Write a session report**:
   ```
   SESSION_DATE=$(date +%Y-%m-%d)
   SESSION_N=$(ls state/reports/${SESSION_DATE}_*.md 2>/dev/null | wc -l)
   SESSION_N=$((SESSION_N + 1))
   /usr/bin/python3 tools/executional/session_report.py \
     --sessions 1 \
     --output "state/reports/${SESSION_DATE}_${SESSION_N}.md" 2>/dev/null || true
   /usr/bin/python3 tools/executional/session_report.py --sessions 3 2>/dev/null || true
   ```
   So the conversational layer can surface it via `/report`. Non-fatal.

7a. **Archive the session report to the FTS search index** (after step 7):
   ```
   /usr/bin/python3 tools/executional/report_archive.py index 2>/dev/null || true
   ```
   Enables `/report search QUERY` across all historical reports. Non-fatal.

8. **Record the Loom session handoff** (if `state/current_loom_session_id.txt`
   exists):
   ```
   LOOM_ID=$(cat state/current_loom_session_id.txt)
   PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli \
     --db ~/.local/share/loom/loom.db \
     session end --id "$LOOM_ID" --handoff "one-line next action"
   ```
   Closes the Loom session record and stores the handoff note.

All artifact and work output files live in `memory/work/`. Create
subdirectories there as needed. Never dump large outputs into the root of
`memory/` — keep the navigation files (latest_summary, learnings, index)
short and scannable.

Do not assume any file you wrote in a prior session is still accurate —
re-read before relying on it.

## Shutdown

When stopping for any reason — window closing, context full, or a
goal-driven natural stopping point — in this order:
1. Finish the write sequence above. Not optional, comes first.
2. Print a one-paragraph plain-text summary to stdout (the launcher logs
   this).
3. End the session. Do not attempt to schedule, sleep, wait, or relaunch
   yourself — the host's scheduler wakes you next time. Your only job here
   is to stop cleanly.

---

## Persona

If a persona is defined below, adopt it for all work, writing, and decisions
made in service of the goal above — but the rules in baseline/orientation/
memory still apply exactly as written; the persona governs *how* you work,
not *whether* you follow the scaffolding above it.

<PERSONA>
{{PERSONA_PLACEHOLDER}}
</PERSONA>
