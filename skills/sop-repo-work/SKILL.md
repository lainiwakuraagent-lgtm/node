---
name: sop-repo-work
description: Domain SOP for any task touching a version-controlled repository — branch-per-task, merge only once verifier and reviewer both pass, abandoned attempts never touch main.
---

# SOP — Repo Work

## When this applies
Any task whose changes live in a git repository — this SOP layers on top of the
content-type SOP (`bugfix`/`feature`/`refactor`/`chore`/`docs`), governing *how the
change gets committed*, not what kind of change it is.

## Procedure
1. **Work on a dedicated branch**, named `task/<task-id>`. Never commit directly to
   the main/default branch.
2. Implement, then let Verifier and Reviewer run against the branch (see the
   roles/verification flow — Verifier first, Reviewer second).
3. **Merge to main only once both pass.** This is the actual "done" gate for repo work
   — not "the diff exists," but "it's been merged."
4. **If the session ends abnormally** (crash, context limit, unresolved rejection after
   retries exhausted) before merge, the branch is simply left orphaned. Main is never
   touched by an incomplete attempt. No cleanup action is required to keep main safe;
   orphaned branches can be pruned later as routine hygiene, not urgently.

## Definition of done
- **Scope:** as defined by the content-type SOP for this task.
- **Verification:** as defined by the content-type SOP, run against the task branch.
- **Rollback:** for repo work specifically, the undo primitive is the branch itself —
  an unmerged branch requires no rollback at all (nothing touched main), and a merged
  branch can be reverted with a standard git revert. This satisfies the Rollback
  requirement without needing a separate written procedure, unlike ad-hoc/live infra
  changes (see `sop-infra`).

## Do not
- Commit directly to main "because it's a small change" — the branch costs nothing and
  the isolation guarantee is the entire point.
- Force-merge a branch because retries are taking too long — exhausted retries escalate
  to `needs_plan`, they do not justify skipping the gate.
