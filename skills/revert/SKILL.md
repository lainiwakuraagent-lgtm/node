---
name: revert
description: Standalone callable skill (not a task-type SOP) — given a completed task's logged Rollback field and available evidence, executes the actual undo. Invoked on demand by the owner, an incident-response session, or a future session, not tag-driven.
---

# Skill — Revert

## When this applies
Any time a completed change needs to be undone: an incident, a regression an audit
caught, or a direct request from Andrey. This is not dispatched by a task's SOP tag
the way `sop-bugfix`/`sop-feature`/etc. are — it's invoked directly, against a specific
already-done task, when reversal is actually needed.

## Procedure
1. **Read the target task's `Rollback` section** (from its Loom description) — this is
   the recorded undo procedure or backup/snapshot pointer, written at plan time before
   the change was ever made.
2. **Gather the evidence referenced there**: a commit hash (for repo-work — `git revert`
   is the primitive), a snapshot/backup file path (for ad-hoc infra changes), or the
   literal undo command if one was recorded directly.
3. **Execute the undo exactly as recorded.** Do not improvise a different reversal path
   even if it seems equivalent — the recorded procedure was written with knowledge of
   the change's actual side effects; a different path may miss something.
4. **If no usable Rollback section exists** (missing, vague, or the referenced evidence
   no longer exists — e.g. a stale snapshot), stop and escalate to `blocked_owner`
   rather than guessing at a reversal. This is itself a finding worth logging: a task
   that can't actually be reverted despite claiming a Rollback plan is a gap the
   relevant SOP (`sop-repo-work` or `sop-infra`) should have prevented.
5. **Confirm the undo actually took effect** — don't assume; verify the state matches
   what existed before the original change, the same way the original change had a
   Verification step.

## Definition of done
- The target state is confirmed restored, with evidence (not just "the revert command
  ran without error").
- The reversal itself is logged (via `loom note`) against the original task, so the
  history shows both what was done and that it was later undone, and why.

## Do not
- Invent a new undo path when the recorded Rollback section already specifies one.
- Treat "command exited 0" as proof the revert worked — confirm the actual state.
- Silently give up if the Rollback section is stale — escalate it as a finding, since a
  broken rollback plan is a real problem for whatever else depends on this having been
  reversible.
