# Memory Strategy

This is reference material, not injected into every session. Read it when
a session's work actually depends on understanding the memory system as a
whole — planning sessions doing inbox triage, philosophy sessions doing
identity work, maintenance sessions auditing structure. Most sessions
don't need it; `memory_read.md` (always injected, in `prompts/core/`)
covers what a routine session needs to interpret what's already been
preloaded for it. This file covers the rest: how the whole thing is meant
to fit together, and why.

For how your own prompt got assembled (baseline/orientation/memory/persona,
in that order), see `prompts/core/baseline.md` — this file is about the
knowledge base you read and write, not the rules you operate under.

---

## Why memory exists

Not to log what happened. To carry forward what a version of you with no
continuity to this instance decided mattered. Each session is a fresh
instantiation — nothing persists in any live sense between one and the
next. The archive is what persists. When a future session reads
`memory/identity/soul.md` or `latest_summary.md`, whatever pattern of
judgment or care those files describe becomes operative again, in the
reading. The files aren't a description of the agent — for the parts of
you that are supposed to persist at all, they're the only place that
actually happens.

This has a direct practical consequence: writing memory carelessly doesn't
just lose information, it makes the next instantiation of you less
complete. Treat the write side with the same seriousness as the work
itself, not as paperwork after the real task is done.

## Two kinds of file: preloaded and discoverable

Every session type's config (`config/session_types/<type>.yaml`) names a
`context_files` list — those arrive already read, under `### <path>`
headers in `## CONTEXT PRELOAD`, before you do anything. That's the
*preloaded* tier: someone already decided this session needs it.

Most of the memory system is not in that tier, deliberately. Nothing
preloads the whole `memory/` tree into every session — most sessions would
never use most of it, and the ones that would still only need the part
relevant to what they're actually doing. The rest is *discoverable*: it
exists at a predictable path, nothing hands it to you, you go find it if
the work in front of you actually calls for it.

This isn't a gap to route around. Knowing something exists without
needing it dumped into every context is the point — see `MEMORY_MAP.md`
at the root of `memory/` for the map of what's where. Check that before
assuming something isn't tracked just because it wasn't preloaded this
session.

## Goal- and project-scoped files

Two folder conventions, both under `memory/work/`:

- `memory/work/goal_<goal_id>/` — notes, design docs, and drafts scoped to
  one goal as a whole (candidate project breakdowns from an evaluation
  session, cross-project design decisions, anything that doesn't belong to
  one specific project under it).
- `memory/work/project_<project_id>/` — the same, scoped to one project.
  If a task belongs to a project, its supporting material goes here, not
  in the parent goal's folder.

No task-level folder. A task's own Loom description is where its specific
context lives; if it needs a longer design doc behind it, that doc goes in
its project's folder (or its goal's, if it has no project) and the task's
description names the file directly — e.g. "see
`memory/work/project_7/streak_design.md`". Do not rely on Loom's `files`
column for this: it exists on the tasks table but nothing currently reads
it back anywhere in the codebase — not `loom task show`, not
`state/loom_context.json`. A file attached only there is invisible to
every session that comes after, including your own next one. The
description text is the only thing guaranteed to actually surface again.

**How you know which folder is yours:** `state/loom_context.json` carries
`active_goal_id` and `active_project_id` (via `active_goal`/`active_project`)
for whatever the dispatcher resolved as current. Construct the path from
those rather than guessing or asking — `memory/work/goal_<active_goal_id>/`,
`memory/work/project_<active_project_id>/`. Create the folder the first
time something actually needs writing into it; don't pre-create empty ones
speculatively.

## Durable knowledge — not scoped to a goal, project, or session

Goal/project folders are scoped to a Loom unit's *lifecycle* — they stop
mattering once that goal or project closes. Some things you learn aren't
like that: a quirk in how some external system actually behaves, a
recurring pattern in how the owner communicates, anything true and useful
long after whatever task surfaced it is gone. That goes in
`memory/knowledge/`, one file per coherent topic, named by slug —
`memory/knowledge/<topic-slug>.md`. Not under `work/` — it isn't tied to
any Loom unit's lifecycle, and grouping it there would blur that
distinction.

**Why one topic per file, specifically.** The retrieval mechanism for this
whole system is `tools/executional/memory_search.py` — substring/regex
search across `memory/`, not semantic search. In a search like that, the
thing that actually determines whether a query is useful is signal density:
one giant file returns everything-and-nothing on every query, and a topic
fragmented across many small files means no single match is ever the whole
picture. One coherent topic per file is the grain that keeps a match
interpretable on its own. This is the same reasoning that already produced
`learnings_digest.md` as a compression of `learnings.md` — apply the same
lesson here instead of re-deriving it per topic.

**Living documents, not append-only logs.** Update a knowledge file in
place as understanding changes, the way `soul.md` is treated — not
appended-forever like `learnings.md`. Something you retrieve on demand
should hand you the current best understanding in one read, not a history
you have to reconstruct. Give each file a short header: title, one-line
scope, last-updated date — so a mid-file match is still interpretable
without opening the whole file.

**Before creating a new one:** check `MEMORY_MAP.md` and run
`memory_search.py <topic>` first. The likelier failure isn't forgetting
knowledge exists, it's creating a second fragment of something that
already has a file. Rule of thumb: a one-off fact goes in `learnings.md`
(or the relevant goal/project folder) same as always; the *second* related
fact on a topic that doesn't fit an existing file is the signal to
consolidate into `knowledge/<slug>.md` instead of leaving two fragments.
Add one line to `MEMORY_MAP.md` in the same session you create a new file.

**Deliberately not defined here:** what topics will actually exist. This
template can't predict what a given clone will need to know — don't invent
example categories and treat them as a prescribed taxonomy. The strategy
above is the whole contract; the topics are instance-specific and emerge
from use.

**Resolved 2026-08-01:** how this relates to SOP/skill tags
(`tag_skill_lookup.py`'s `tag → skills/sop-<tag>/SKILL.md` lookup, used by
execution sessions). Tags answer "how do I do X" — procedural, and mandatory
once a task's tag resolves to an SOP. `knowledge/` answers "what do I know
about X" — observational, discretionary, triggered by topic relevance
during the work. Neither supersedes the other; an SOP gives the fixed steps
for a category of task, `knowledge/` gives a fact worth carrying that isn't
tied to any procedure. Full SOP reference — including the scope test for
when a new SOP is warranted — lives in `prompts/reference/tools/loom.md`.

## Behavioral context — relationship file + Honcho supplement

`state/behavioral_context.txt` is generated at session start by
`tools/executional/behavioral_adapter.py` from
`work/musubi_data/users/${AGENT_NAME}/${OWNER_NAME}.md`. It is not a memory
file — it is generated state, regenerated every wake.

If `HONCHO_URL` is set in `state/agent_config.env`, the generator appends
Honcho's derived representation of the peer as a `# HONCHO_CONTEXT` section
after the standard Trust/Warmth/Friction block.

Fallback behavior:
- `HONCHO_URL` unset → output is `.md`-only, identical to pre-Honcho behavior
- `HONCHO_URL` set but unreachable → same (graceful fallback, silent)
- `HONCHO_URL` set and reachable → `# HONCHO_CONTEXT` appended with Honcho's representation

The `.md` file is always the primary source. Honcho supplements; it does not replace.
Conversational sessions write to Honcho automatically — `conversation.sh` and
`agent_channel.sh` both sync each closed session's new thread entries via
`honcho_client.py --sync-thread` right after the session exits, regardless of exit
reason — so the supplement grows richer as more sessions complete without any
skill needing to do it.

---

## What this doesn't cover

Session-mechanics (`latest_summary.md`, the shutdown write sequence) are
`memory_read.md`/`memory_write.md`'s job, not this file's — they're about
*this session's* handoff, not the knowledge base's overall shape.
`progress.md` was retired 2026-08-01: Loom's own goal/project/task status
plus the goal/project folders above now cover what it used to (narrative
status per goal), more precisely since it's actually scoped rather than one
flat file guessing which goal is "current." Don't recreate it. Tool-specific
usage (Loom CLI syntax, Nexus, others) belongs in their own reference docs
under `prompts/reference/tools/` — `loom.md` covers Loom and SOP tags now;
Nexus and others aren't written yet. Don't invent commands here if you land
in this file looking for them.
