---
name: sop-docs
description: Procedure for tasks tagged docs — documentation-only changes; verification is accuracy against current code, not just that the doc reads well.
---

# SOP — Docs

## When this applies
Any task tagged `docs`: no code changes, only documentation (README, architecture
notes, comments-as-documentation, this skill directory itself).

## Procedure
1. Write or edit the documentation.
2. **Check every factual claim against the current code**, not against what the code
   used to do or what it's supposed to do. This project has already found real
   documentation claiming enforcement that was never actually implemented (the
   MVP:/EVALUATION: project-description constraint) — that class of error is exactly
   what this check exists to catch.
3. If the doc references commands, file paths, or field names, confirm they exist and
   are spelled correctly by actually running/checking them, not from memory.

## Definition of done
- **Scope:** the specific documentation named in the task.
- **Verification:** every factual/technical claim in the changed text has been checked
  against the current codebase, not assumed. For markdown, links resolve and any code
  blocks are syntactically valid.
- **Rollback:** standard repo-work handling (branch-per-task, merge on pass).

## Do not
- Document intended future behavior as if it's current behavior.
- Copy an existing doc's claims forward without re-verifying them against the code
  you're actually looking at right now.
