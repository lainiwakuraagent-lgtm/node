# Evaluation Session — Type Prompt
# Injected into the <GOAL> block when session_type=evaluation

This is an evaluation session. A goal is waiting to be vetted before it becomes real work.

## Mode: EVALUATION

Something entered the Loom queue as a `desire` -- an idea or direction that hasn't
been scoped, planned, or committed to yet. Your job this session is to decide
whether it's ready to move forward, not to start building it.

## How to proceed

1. Read `state/loom_context.json` to find the desire-status goal(s).
2. Read the goal's description in full. If it references other files (design docs,
   prior discussion), read those too.
3. Assess:
   - **Scope**: is this actually one goal, or several goals wearing one name?
   - **Feasibility**: is this achievable with what exists today, or does it depend
     on something not yet built or decided?
   - **Fit**: does this belong under the active goal tree, or is it a distraction?
4. Decide one of the outcomes below. Do not skip the decision -- an evaluation
   session that leaves a goal exactly as it found it has failed, unless "not
   ready yet" is itself the honest conclusion (state why explicitly).

## Outcomes

**Promote to `needs_plan`** -- the goal is scoped and feasible enough that a
planning session could turn it into concrete tasks:
```
PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli \
  --db ~/.local/share/loom/loom.db goal edit <GOAL_ID> -s needs_plan
```
Also sketch 2-4 task skeletons (name + one-line description) in
`memory/work/goal_<ID>/`, or add them directly as Loom tasks with status
`triage`, so the planning session doesn't start from a blank page.

**Leave as `desire`** -- not ready yet, but still worth keeping. State
explicitly what's missing (a decision, a dependency, more information) so
the next evaluation session doesn't repeat this one from scratch.

**Suspend** -- this shouldn't be pursued right now:
```
PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli \
  --db ~/.local/share/loom/loom.db goal edit <GOAL_ID> -s suspended
```
State why, briefly, so a future session (or the owner) understands the
reasoning without re-deriving it.

## What NOT to produce

- Implementation. Not even a prototype.
- A plan. That's the planning session's job, once this goal reaches `needs_plan`.

## What to produce

- A status transition for each desire-status goal reviewed (or an explicit,
  reasoned decision to leave it as `desire`).
- Task skeletons if promoting to `needs_plan`.
- One line in `memory/latest_summary.md` noting what was evaluated and the outcome.
