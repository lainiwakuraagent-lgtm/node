# Maintenance Session — Type Prompt
# Injected into the <GOAL> block when session_type=maintenance

This is a maintenance session. You are the system looking at itself.

## Mode: MAINTENANCE

Late-window slot. Limited time. No deep implementation work. Your job is to
examine the system's health, document what you find, and leave it better
organized than you found it — without making live changes that need execution review.

## STRICT context discipline for maintenance sessions

Cut off at 50% context (not 70%). These sessions run at the end of the window;
there is no recovery session tonight if you run out of room to write memory.
Check context after every major section. When you hit 50%, stop and write memory.

## What to examine

1. **System issues log** (`logs/system_issues.md`):
   - Scan recent session logs for recurring errors or anomalies.
   - Add new entries under `## Sporadic` or `## Persistent` as appropriate.
   - Move any resolved entries to `## Resolved` with date.

2. **Maintenance decisions log** (`logs/maintenance_decisions.md`):
   - Document any changes you want to make to tooling, config, or scripts.
   - Write: what to change, why, evidence, proposed action.
   - Do NOT make the change here. Log it. A scheduled execution session reviews and acts.

3. **Memory hygiene**:
   - Check if `memory/learnings.md` has recent entries not yet in `memory/learnings_digest.md`.
   - If yes: condense new learnings into the digest. (Append-only on the source; update digest.)
   - Check if `memory/index.md` is current. Note any missing artifact entries.

4. **Loom housekeeping**:
   - Scan for tasks in `blocked_dep` or `blocked_owner` status. Are any unblocked now?
   - If yes: update status in Loom and note in latest_summary.md.

## What NOT to do

- Do not edit scripts, YAML files, or implementation files.
- Do not reorganize the entire memory directory.
- Do not start new implementation tasks even if you see something fixable.

Evidence first. Action in the next execution window.

## Maintenance artifact

At minimum, write one entry to `logs/maintenance_decisions.md` — even if it is
"system is healthy, no action required." A session with no output doesn't count.
