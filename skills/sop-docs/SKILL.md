---
name: sop-docs
description: Procedure for tasks tagged docs — external-facing documentation only (README, architecture, reference docs meant for a future reader). Internal memory-archive writing is memory_strategy.md's job, not this SOP's.
---

# SOP — Docs

## When this applies
Any task tagged `docs` where the target is **external-facing**: `README.md`,
`ROADMAP.md`, `VISION.md`, `prompts/reference/*.md`, architecture notes, or
comments-as-documentation in code — material meant to make the system legible to a
future reader who isn't the agent that's currently working, whether that reader is
the owner, a new clone's first session, or another agent in the fleet.

**Not this SOP's job:** writing into `memory/` itself (`latest_summary.md`,
`knowledge/`, goal/project notes). That's the memory-write discipline covered by
`prompts/core/memory_write.md` and `prompts/reference/memory_strategy.md` — a
different kind of writing with a different audience (this agent's own future
sessions, not an external reader).

## Procedure
1. **Identify who's actually going to read this** before writing — a new clone's
   orientation pass, the owner, another fleet agent — the level of assumed context
   changes the answer.
2. Write or edit the documentation.
3. **Check every factual claim against current reality**, not against what the system
   used to do or is supposed to do. This project has already found documentation
   claiming enforcement that was never implemented — that's exactly the class of error
   this step exists to catch.
4. **Confirm every referenced path, command, or field name by actually checking it**
   (`Read`, `grep`, or running the command) — not from memory, not by assuming the
   thing you wrote earlier in the session is still accurate.
5. **If this doc is a forward-pointer target** — something else already says "see
   `<this file>`" — confirm that reference now actually resolves before finishing.
   This project has repeatedly found dead forward-pointers (four `SKILL.md` files
   pointing at a `memory/work/sop/` directory that never existed); this step exists
   specifically to stop adding more of them.

## Definition of done
- Every factual/technical claim in the changed text has been checked against the
  current system, not assumed.
- Any file/command/field referenced actually exists, confirmed by checking it.
- If this doc is a known forward-pointer target, the pointer resolves.

## Do not
- Document intended future behavior as if it's current behavior.
- Copy an existing doc's claims forward without re-verifying them.
- Write into `memory/` under this tag — that's a different SOP's territory (none
  currently, since it's core-prompt-owned, not tag-gated).
