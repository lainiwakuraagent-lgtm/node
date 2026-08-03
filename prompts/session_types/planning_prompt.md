# Planning Session — Type Prompt
# Injected into the <GOAL> block when session_type=planning

This is a planning session. The work here is thinking, not building — but
it now has two distinct reasons to have fired, and the first thing you do
is figure out which one (possibly both) brought you here this time.

## Mode: PLANNING

## Why you're here

Planning now fires for either of two reasons. Check which applies before
doing anything else:

**A. Something in Loom needs a plan.** A goal, project, or task has reached
`needs_plan` status — the traditional trigger. See "Decomposition work"
below.

**B. The inbox has unprocessed information.** New input arrived from the
communicational layer (Telegram, Nexus) since the last planning session.
See "Inbox absorption" below — this is the newer, equally important half of
this session type, not a side task.

Both can be true at once. If so, do the inbox absorption first — it may
surface new `needs_plan` items or context that changes how you approach the
decomposition work.

---

## Inbox absorption

**What this is, and isn't.** `tools/inbox.py startup` already handles the
auto-tier entries end to end — `context_update`, `agent_message`,
`schedule_directive`, `verified_task` are applied and marked processed
without needing you. You won't see those; don't go looking for them.

What's left after that is deliberately *not* touched by `inbox.py`:
`request` entries (a raw ask — `kind` is `task`, `bug`, `idea`, `sop`, or
`sop_change`, optionally with an attached file) and `comment` entries (`kind`
n/a, but a `target_type`/`target_id` pointing at an existing task/sop/goal).
`inbox.py` deliberately does not create a Loom task or act on these itself —
that placement judgment is yours, not a mechanical default. Left alone, they
just sit in `inbox/pending.json` with `processed: false`, invisible to
everything else.

**Your job, for each unprocessed `request`/`comment`:**

1. Run `python3 tools/inbox.py read --summary` to see what's waiting (or
   `python3 tools/inbox.py startup` first if auto-tier entries haven't been
   applied yet this session).
2. For a `request`: decide whether it belongs under an existing goal/project
   or needs a new one, and what status it's actually ready for —
   `scheduled` if an execution session could pick it up as-is, `needs_plan`
   if it needs more thought first (possibly right now, in this same
   session), `desire` if it needs evaluation before either. Create the Loom
   task with that real status directly — there's no intermediate holding
   status to leave it in.
3. For a `comment`: read what it's saying about its target, and decide what
   that implies — update the target task's description/priority/status,
   fold it into a design doc, or conclude it needs nothing beyond having
   been read. Say which.
4. Not every entry needs a Loom task. Some are just context that should
   inform how you read the goal picture below, or belong in
   `memory/work/pending_decisions.md` if they need the owner specifically,
   not you. Routing is a decision each time, not a reflex.
5. Once you've acted on an entry, close it out: `python3 tools/inbox.py
   resolve --id <ID>`. An entry you looked at but didn't resolve isn't done
   — the id is in the JSON `inbox.py read` printed.

To do any of this well you need a working picture of how the system fits
together — which file feeds which session type, what a given status
actually unlocks. See `prompts/reference/architecture.md` for that (this
file doesn't exist yet — until it does, rely on what's in CONTEXT PRELOAD
and the goal/project folders, and don't guess at mechanics you haven't
verified).

**Known gap, not yours to fix here:** the dispatcher can still hand an
`execution` session instead of this one when the inbox has unprocessed
`request`/`comment` entries — that redirect hasn't been updated to point at
planning yet. Not something to fix from inside a session; if you notice
inbox entries that look like they've been waiting a long time, that
dispatch mismatch is the likely reason.

---

## Decomposition work

1. Read `state/loom_context.json` and the goal/project's own folder
   (`memory/work/goal_<id>/` or `memory/work/project_<id>/`, if either has
   accumulated notes) — understand the whole goal's actual state, not just
   the next step.
2. Read `memory/learnings_digest.md` — what has already been tried and
   failed.
3. Read `memory/index.md` — what has already been built.
4. Identify: what is actually blocking progress? A technical problem, an
   unclear requirement, a missing dependency, or something the owner needs
   to decide?

## Tag discipline

Before assigning tags to any task — new, reorganized, or promoted from the inbox
sweep — run `scripts/executional/tag_skill_lookup.py --project-dir . --list`. It
prints every existing SOP tag alongside its skill file and one-line description.
Check the task's actual category against both the tag names and the descriptions,
not just the word that first comes to mind — a task about reviewing another agent's
output might read as "code review" but already be covered by `adversarial`; a
mismatch in wording is not the same as a genuine gap. Only tag something as needing a
new SOP — and only then follow `prompts/reference/tools/loom.md`'s "When to propose a
new SOP" section — once you've actually checked and nothing existing covers it.

## What this session is actually deciding

- The Loom tasks that come out of it — new, reorganized, or promoted from
  the inbox sweep — are the real output. Get their goal/project placement
  and status right, not just their existence.
- A `blocked_owner` task for a decision that genuinely needs the owner is a
  legitimate outcome, not a fallback. **When you create one with a design
  doc behind it, put the doc in the task's project folder**
  (`memory/work/project_<project_id>/`, or `memory/work/goal_<goal_id>/`
  if it has no project) **and name the file in the task's description
  text** — e.g. "see memory/work/project_7/streak_design.md". Do not rely
  on Loom's `files` column for this: it exists on the tasks table but
  nothing reads it back anywhere (checked — not `loom task show`, not
  `state/loom_context.json`), so a file attached only there is invisible
  to every future session including your own next one. The description is
  the only thing guaranteed to actually surface again.

## What NOT to produce

- Code. Not even "just a quick prototype."
- Redesigns of things that are working. Only revise what is stuck.
- Comprehensive plans for the next six months. Revise the next three steps.
- A Loom task for every note-file entry regardless of whether it implies
  work — routing is a decision, not a reflex.

## When planning is done

You know you're done when the goal picture has a single next action clear
enough that another agent could execute it immediately without
clarification, and the inbox has nothing left sitting unrouted — not
necessarily *resolved*, but placed somewhere deliberate rather than ignored.

Then stop. The next execution session picks up from there.
