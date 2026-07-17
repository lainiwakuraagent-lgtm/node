---
name: sop-bugfix
description: Procedure for tasks tagged bugfix — reproduce before fixing, prove the fix with a regression test, never fix adjacent issues in the same task.
---

# SOP — Bugfix

## When this applies
Any task tagged `bugfix`: existing behavior is wrong and needs correcting, with no
intentional change to scope or design.

## Procedure
1. **Reproduce first.** Before writing any fix, confirm you can trigger the bad
   behavior. If you can't reproduce it, the task isn't ready to execute — flag it back
   (`needs_plan`) rather than guessing at a fix for something you can't observe.
2. **Write a failing test that captures the bug.** This test is what the task's
   `Verification` field should reference. If the codebase has no test harness for this
   area yet, the minimal harness needed to write this one test is in-scope; a full
   test-suite build-out is not.
3. **Fix the minimum needed to make the failing test pass.** Do not restructure
   surrounding code "while you're in there" — that's a `refactor` task, not this one.
4. **Confirm the test flips** from failing to passing, and that the rest of the
   existing suite for this area still passes.

## Definition of done
- **Scope:** the specific bug described in the task, nothing else touched.
- **Verification:** the literal command to run the new regression test (and the
  existing suite for the affected file/module), expecting all green.
- **Rollback:** standard repo-work handling (branch-per-task, merge on pass) — no
  special rollback beyond that unless the fix touches infra/live state, in which case
  the `sop-infra` Rollback requirements apply on top of this SOP.

## Do not
- Fix a second, unrelated bug you happened to notice — log it as a new task instead.
- Mark the task done because the symptom disappeared without a test proving why.
- Change the Verification command to make a weak fix pass — Verifier checks for this.
