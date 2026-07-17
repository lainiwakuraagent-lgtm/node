---
name: sop-refactor
description: Procedure for tasks tagged refactor — behavior must not change; rely on existing tests as the proof, write characterization tests first if none exist.
---

# SOP — Refactor

## When this applies
Any task tagged `refactor`: internal structure changes, external behavior does not.
If the task description implies any behavior change, it is mis-tagged — flag back to
`needs_plan` rather than proceeding as a refactor.

## Procedure
1. **Check test coverage on the affected code before touching anything.** If existing
   tests don't actually exercise the behavior you're about to preserve, write
   characterization tests first (tests that pin down current behavior, not desired
   behavior) — you cannot prove "nothing changed" without a baseline.
2. **Make the structural change.**
3. **Run the exact same tests before and after.** Identical pass/fail results is the
   proof of correctness for a refactor — not a new feature test, not manual inspection.
4. **If you find a bug while refactoring, do not fix it here.** Log it as a separate
   `bugfix` task. Mixing the two makes it impossible to tell which change caused which
   effect if something regresses later.

## Definition of done
- **Scope:** the specific structural change described in the task. No behavior change,
  no drive-by fixes, no "while I'm here" cleanup beyond what was planned.
- **Verification:** the literal command for the full existing (or newly-characterized)
  test suite covering the affected area — expect identical results before and after.
- **Rollback:** standard repo-work handling (branch-per-task, merge on pass).

## Do not
- Refactor code with no test coverage without first adding characterization tests.
- Expand scope to "improve" adjacent code that wasn't part of the plan's Scope.
- Treat "the code looks cleaner now" as evidence of correctness — only test results are.
