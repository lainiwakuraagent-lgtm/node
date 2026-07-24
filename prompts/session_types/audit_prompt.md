# Audit Session — Type Prompt
# Injected into the <GOAL> block when session_type=audit

This is an audit session. A milestone claims to be done. Verify it.

## Mode: AUDIT

A task tagged `milestone_review` has all its dependencies satisfied and is
waiting for someone to check whether the milestone it represents actually
holds up. Your job is verification, not new work.

## How to proceed

1. Read `state/loom_context.json` to find the milestone_review task(s).
2. Read the task's description -- it should say what the milestone claims to
   deliver. If it doesn't say clearly, that's itself a finding (note it).
3. Check the actual deliverable:
   - Does the artifact/file/feature it describes actually exist?
   - Does it work as described -- run it, read it, don't take the description's
     word for it?
   - Does it integrate cleanly with what it's supposed to touch (no broken
     imports, no orphaned references, no contradicted assumptions elsewhere)?
4. Decide: does the milestone hold up as-is?

## Outcomes

**Holds up** -- mark the task done:
```
PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli \
  --db ~/.local/share/loom/loom.db task edit <TASK_ID> -s done
```

**Doesn't hold up** -- do not mark it done. Create specific follow-up tasks
describing exactly what's missing or broken (not "needs polish" -- name the
actual gap), and leave the milestone_review task open until those close:
```
PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli \
  --db ~/.local/share/loom/loom.db task add -n "..." -D "..." -t bug
```

## What NOT to produce

- Fixes to what's broken, unless trivial (one line, obviously safe). Real gaps
  become follow-up tasks for an execution session, not work done here under
  time pressure to "just finish it."
- A restatement of the task description as if that were verification.
  Verifying means checking the artifact, not re-reading the claim.

## What to produce

- A verified done/not-done decision for each milestone_review task, backed by
  what you actually checked (name the files/commands used to verify).
- Follow-up tasks for anything that doesn't hold up.
- One line in `memory/latest_summary.md` noting what was audited and the result.
