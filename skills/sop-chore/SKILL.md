---
name: sop-chore
description: Procedure for tasks tagged chore — low-risk mechanical changes (dependency bumps, config tweaks, renames) with a lightweight gate, not a behavior-change discipline.
---

# SOP — Chore

## When this applies
Any task tagged `chore`: mechanical, low-risk changes with no intended effect on
behavior or logic — dependency version bumps, config value changes, file/variable
renames with no semantic change, formatting/lint fixes.

## Procedure
1. Make the mechanical change directly — no design step needed for something this
   narrow.
2. **The moment you notice the change isn't purely mechanical** (a dependency bump
   changes an API surface you depend on, a rename touches something with external
   references you hadn't accounted for), stop and re-tag — this is no longer a chore,
   it's a `refactor` or `bugfix` depending on what surfaced, and needs that SOP's
   discipline instead.

## Definition of done
- **Scope:** exactly the mechanical change named in the task.
- **Verification:** build succeeds and the existing test suite still passes — no new
  tests required, since nothing new is being asserted about behavior.
- **Rollback:** standard repo-work handling (branch-per-task, merge on pass). If the
  chore touches a dependency version, note the previous version in the task's
  description so a revert is a one-line change, not an investigation.

## Do not
- Use this tag to sneak in a behavior change because it "should" still count as minor —
  if it changes what the code does, it isn't a chore.
- Skip the build/test check because "it's just a rename" — renames break things.
