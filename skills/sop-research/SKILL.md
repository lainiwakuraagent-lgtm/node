---
name: sop-research
description: Procedure for tasks tagged research — concrete steps for surveying a domain or question in this codebase, not a general research framework.
---

# SOP — Research

## When this applies
Any task tagged `research`: surveying a domain, assessing feasibility, reviewing prior
work, or synthesizing understanding. The output is knowledge, not a decision
(`design`'s job) or an implementation.

## Procedure
1. **Check what's already known before looking anywhere else.** Run
   `python3 tools/executional/memory_search.py "<topic>"` and check `memory/MEMORY_MAP.md`.
   The likely failure isn't missing a source — it's re-deriving something already
   written down. Skip straight to step 2 only if the search comes back empty.
2. **Name your actual sources as you go, not after.** For an internal question: the
   specific files/paths read (`grep`/`Read` targets), not "reviewed the codebase." For
   an external question: the specific doc, command `--help` output, or page consulted
   — a claim with no traceable source doesn't belong in the synthesis.
3. **Stop on a concrete condition, not a vague one.** Pick one before you start: "the N
   most authoritative sources agree," "the specific question in the task is answered,"
   or "context budget for this task is exhausted." Write down which one applies before
   you begin — don't let the boundary get decided in hindsight.
4. **Take notes as you go**, into `memory/work/goal_<id>/{topic}_research.md` or
   `memory/work/project_<id>/{topic}_research.md` (match the task's actual goal/project
   — see `memory_strategy.md` for which folder is yours). Notes are the output, not a
   scratch pad discarded before a final write-up.
5. **Synthesize explicitly**: what was found, what remains uncertain, and one of three
   named transitions — a `design` task (if findings need to become a decision), a
   `blocked_owner` task (if owner input is required), or an update to
   `memory/knowledge/<slug>.md` (if the finding is a durable fact worth carrying, per
   `memory_strategy.md`'s one-topic-per-file rule).

## Definition of done
- A synthesis section exists in the notes file, with sources actually named, not implied.
- The stopping condition chosen in step 3 is stated, and was actually met.
- The next step is one of the three named transitions in step 5 — not left implicit.

## Do not
- Write "explored several options" without naming which ones and where they came from.
- Keep researching past the stopping condition because the answer still isn't fully
  satisfying — an unsatisfying-but-bounded answer transitions to `design` or
  `blocked_owner`; it doesn't justify an unbounded search.
