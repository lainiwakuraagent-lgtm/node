---
name: sop-design
description: Procedure for tasks tagged design — converging on a specification or decision before implementation begins.
---

# SOP — Design

## When this applies
Any task tagged `design`: producing a specification, evaluating trade-offs, or making
a decision whose output will unblock implementation. NOT implementation itself.

## Procedure

1. **Define the question.** Before writing anything, state what decision needs to be made
   or what specification needs to be produced. If you cannot state it in one sentence,
   the scope needs tightening.

2. **Survey options.** List the approaches, variants, or constraints. 2-4 options max —
   more implies incomplete scoping.

3. **Evaluate trade-offs.** For each option, note: complexity, reversibility, dependencies,
   and fit with existing architecture. Reference learnings_digest.md for known failure modes.

4. **Decide and record.** Pick one. State WHY. The reasoning must be readable 6 months later.

5. **Write the spec.** Output goes in `memory/work/goal_N/` or `memory/work/sop/`.
   Format: Decision → Rationale → Implementation notes → Open questions.

6. **Write Loom handoff_note.** Point to the spec file so the next execution session
   can pick it up without re-reading the design deliberation.

## Definition of done
- A spec document exists with the decision and rationale.
- The Loom task has a `handoff_note` pointing to the spec.
- The next execution task can be stated in one sentence.

## Full SOP
See: `memory/work/sop/sop_design.md`
