---
name: sop-research
description: Procedure for tasks tagged research — open-ended exploration of a domain or question without a predetermined answer.
---

# SOP — Research

## When this applies
Any task tagged `research`: surveying a domain, assessing feasibility, reviewing prior
work, or synthesizing understanding. The output is knowledge, not a decision or implementation.

## Procedure

1. **Frame the question.** State what you are trying to find out. If the question has
   a known answer, this is not research — it's a docs or chore task.

2. **Set a scope boundary.** Research without a boundary runs forever. Define:
   - What sources/approaches you will cover
   - When you will stop (time, context budget, or "when the question is answered")

3. **Explore and document.** Take notes as you go into `memory/work/goal_N/{topic}_research.md`.
   Do not wait until the end — notes are the output.

4. **Synthesize.** When scope is exhausted or question answered, write a synthesis section:
   - What was found
   - What remains uncertain
   - What the next step should be (design, blocked_owner, or another research arc)

5. **Transition.** Research rarely ends cleanly. End with either:
   - A design task (if findings need to become a decision)
   - A blocked_owner task (if owner input is required)
   - A note in learnings_digest.md (if findings are architectural/environmental)

## Definition of done
- A synthesis doc exists in `memory/work/`.
- The next step is explicitly named (design task, or "blocked on owner: X").
- If findings affect the system's behavior or environment, learnings.md is updated.

## Full SOP
See: `memory/work/sop/sop_research.md`
