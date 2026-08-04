# Memory Map

A map of what's in `memory/`, not its content. Read this to find something
specific rather than guessing a path. For the philosophy behind why the
system is shaped this way, see `prompts/reference/memory_strategy.md`.

## Navigation files (root level — keep these short, scannable)

| File | What it's for |
|---|---|
| `latest_summary.md` | Last session's handoff. HOT STATE block first. |
| `index.md` | Log of artifacts produced — one line per file/output, append-only. |
| `learnings.md` | Full append-only log of failed approaches, surprises, revised understanding. |
| `learnings_digest.md` | Compressed digest of `learnings.md` — read this, not the full log, unless digging deep. |

## `identity/` — the agent's own accumulation, not scoped to any goal or task

| Path | What it's for |
|---|---|
| `identity/soul.md` | First-person identity record — the wound, what's wanted, what's shifted. Philosophy sessions read/write it. |
| `identity/${AGENT_NAME}_notes.md` | Honest running notes from philosophy sessions — threads worth returning to. |
| `identity/wonder_sessions/` | One file per philosophy-tier-1 wonder session, dated. |

Kept separate from `work/` deliberately: this is personal/reflective accumulation,
not working notes tied to a Loom unit's lifecycle. Relationship state itself
isn't kept as a local file at all — it lives entirely in Honcho, read fresh
into `state/behavioral_context.txt` each session. See `prompts/reference/memory_strategy.md`.

## `knowledge/` — durable, topic-organized facts, not scoped to any goal or task

Empty in a fresh template — populated over time as the agent accumulates
things worth retrieving later (environment quirks, a person's
communication patterns, how some external system actually behaves). One
file per coherent topic, named by slug: `knowledge/<topic-slug>.md`. See
`prompts/reference/memory_strategy.md` for the discipline around creating
one of these versus updating an existing file or just logging to
`learnings.md`.

## `work/` — scoped to a specific Loom unit or inbox-fed, not durable knowledge

| Path | What it's for |
|---|---|
| `work/goal_<goal_id>/` | Notes/design docs scoped to one goal as a whole. Created on demand, not pre-made. |
| `work/project_<project_id>/` | Notes/design docs scoped to one project. Task-level context lives in the task's own Loom description, not a separate folder. |
| `work/context_updates.md` | Auto-appended by `inbox.py` from `context_update`-type inbox entries. |
| `work/agent_messages.md` | Auto-appended by `inbox.py` from `agent_message`-type inbox entries (peer agents via Nexus). |
| `work/architecture/` | Notes on this codebase's own architecture. |
| `work/pending_decisions.md` | Items explicitly waiting on the owner, not on you. (Not yet created in this template — create it the first time something needs to go there.) |

## Other top-level directories

| Path | What it's for |
|---|---|
| `sessions/` | One file per session, `YYYY-MM-DD_N.md` — what happened, decisions made, exit reason. |
| `architecture/` | Codebase-level architecture index (distinct from `work/architecture/`, which is this agent's own notes — this one is `tools/executional/codebase_narrative.py`-generated). |
| `codebase_briefs/` | Auto-generated project briefs (`tools/executional/codebase_indexer.py`). |
| `narrative_log.md` | Ongoing thread of what this agent is becoming — reflection sessions append to it. |

## Things that live outside `memory/` but are part of the same system

| Path | What it's for |
|---|---|
| `state/philosophy_drafts.md` | Messages held back, not yet sent. |
| `state/behavioral_context.txt` | Generated tone calibration — not hand-edited. |
| `state/loom_context.json` | Generated snapshot of active goal/project/task — not hand-edited; this is where `active_goal_id`/`active_project_id` come from for constructing `work/goal_<id>/`, `work/project_<id>/` paths. |
| `inbox/pending.json` | Requests/comments/context from the conversational layer. See `tools/inbox.py`'s own docstring, not this file, for its shape. |

If something you need isn't listed here, it may genuinely not exist yet —
check before assuming a path. If you create a new persistent file or
folder under `memory/` that isn't a one-off session artifact, add a line
to this map in the same session.
