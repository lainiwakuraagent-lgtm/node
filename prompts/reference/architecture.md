# Architecture

Reference material, not loaded into any session by default — this is the map of how
the whole system fits together. Referenced by name from other prompts and SOPs
(`planning_prompt.md`, `sop-self-arch`, and others) rather than duplicated into them.
Read this when a session's work actually depends on understanding how a piece
connects to the rest, not just what that piece does on its own.

**What this file is for:** which file feeds which session type, what a given Loom
status actually unlocks, how a change in one place propagates somewhere else you
might not expect. **What it deliberately doesn't cover:** step-by-step procedure
(that's the SOPs' job — `loom.md`), the memory system's own internal shape (that's
`memory_strategy.md`'s job), deep tool CLI syntax (Loom's own bundled docs, and `prompts/reference/tools/nexus.md`).
This file cross-references those rather than restating them —
if you find yourself about to copy a paragraph from one of them into here, don't;
point at it instead.

---

## 1. The wake → dispatch → session chain

Every session — nightly, emergency, or manual — starts the same way: something
invokes `scripts/executional/wake.sh` with `TRIGGER_MODE` set to `nightly`,
`emergency`, or `manual`.

**Gate sequence** (in order; a gate that fails aborts before any Claude session
launches):

- **Gate 0 — usage limits** (nightly + emergency): fails closed only on a confirmed
  "usage limit exceeded"; fails *open* on a check error (network/auth issues never
  silently kill the launch). `manual` bypasses this gate entirely — a deliberate
  break-glass override, distinct from `emergency`, which still respects it.
- **Gate 1 — emergency-mode block** (nightly only): if `state/emergency_mode.active`
  exists, nightly steps aside. Emergency mode owns the schedule while active.
- **Gate 2 — window/schedule check** (nightly only): `scripts/executional/check_window.py`
  reads `config/session_schedule.json` and decides whether this is a valid window to
  launch, including one-off scheduled entries. A one-off match is only detected here,
  not consumed — it's marked fired *after* Gate 4 passes, so it can never be silently
  used up without an actual launch happening. Immediately before this read,
  `tools/executional/khal_schedule_reader.py sync` regenerates the `one_off[]` array
  (only) from this agent's own khal calendar (installed per-agent by install.sh §8b) —
  a khal event tagged with category `blank_node_window:<work|maintenance|reflection>`
  becomes a one-off trigger at that event's start time. `windows[]` (the fixed
  nightly-work/nightly-maintenance/nightly-reflection windows and their triggers) is
  never touched by this sync, so the nightly maintenance window can't be dropped by
  calendar mismanagement — khal only ever *adds* optional, user-configurable windows on
  top of the fixed nightly schedule. A khal failure (not installed, unreadable) is
  non-fatal and leaves the schedule file's `one_off[]` untouched; it never blocks the
  fixed nightly gates. To catch custom windows scheduled outside the fixed nightly
  hours, `night-agent@.timer` also fires an hourly daytime probe (`*:15:00`, offset from
  every fixed trigger time so it never double-fires) — on a night/day with no custom
  windows, this probe is rejected by Gate 2 almost instantly.
- **Gate 3 — retired.** Session-count hard cap was downgraded to informational-only;
  `sessions_tonight.count` is still tracked but nothing aborts on it. The numbering
  below still says "Gate 4" for continuity with existing logs, not because a gate was
  skipped.
- **Gate 4 — lock file** (all modes): `state/session.lock` — a stale lock (dead PID)
  is cleared and proceeded past; a live one aborts this wake attempt.

**After all gates pass:** the active goal/project is resolved via Loom
(`loom goal resolve-active`), a fresh `state/loom_context.json` snapshot is written,
a `loom_sessions` row is created, and dynamic goal text is built from that snapshot
(there is no static `goal.txt` anymore — Loom is the sole source). Then
`scripts/executional/resolve_session_type.py` runs (see §2) and its output is spliced
together with `prompts/core/*` by `scripts/executional/splice_prompt.py` into the
final prompt. Claude Code launches headless:
`claude --dangerously-skip-permissions --model <model> < <spliced prompt>`.
`--dangerously-skip-permissions` is intentional — the agent runs unattended;
containment is handled at the VM/network level, not by permission prompts nobody is
present to answer.

**After the session ends** (regardless of exit code — the launch itself runs under
`set +e` specifically so a crash doesn't skip this bookkeeping): the consecutive
philosophy counter updates (see §3), the Loom session row is closed, relationship
state updates heuristically from the tail of `wake.log`, and an analytics fallback
record is written if the agent's own shutdown sequence didn't already write one.

## 2. Session type dispatch

`resolve_session_type.py` decides what kind of session this is, in strict priority
order:

1. **`SESSION_TYPE` env var** — explicit override, always wins.
2. **`WINDOW_TYPE` env var** (a lane constraint `wake.sh` may set) — `maintenance` or
   `reflection` force that type directly; `work` or unset falls through.
3. **Philosophy-cap gate** — if `consecutive_philosophy.count >= 3`, resolves to
   `philosophy_cap`, which aborts *before* Claude ever launches (see §1). This check
   runs before queue-state on purpose, so a philosophy-ladder-created task can't
   reset the counter and dodge the cap by immediately triggering execution.
4. **Queue-state rules**, read directly from the Loom DB, in order — goal beats
   project beats task when more than one level matches simultaneously:
   - `desire`-status goal/project, not blocked → **evaluation**
   - `needs_plan`-status goal/project/task (task only if all `depends` are done) → **planning**
   - `review`-status goal, or a `scheduled`/`in_progress` task tagged
     `milestone_review` with deps done → **audit**
   - `scheduled` task, not blocked, `wait_until` not in the future, deps done → **execution**
     (capped at `EXECUTION_TASK_CAP`, default 2, and scoped to one project/goal bucket
     at a time)
5. **Inbox-pending fallback** — if none of the above matched and the inbox has
   unprocessed `request`/`comment` entries, forces **execution**. **This is a known,
   live bug**, not a design choice: `execution_prompt.md` explicitly tells the agent
   to leave the inbox alone, since inbox absorption is planning's job (see §7). This
   should force `planning`, not `execution` — tracked as a Loom task, not yet fixed.
   `sop-self-arch` names this as a real instance of dispatcher misrouting, not a
   hypothetical one.
6. **Maintenance-overdue fallback** — if the queue is empty and it's been longer than
   `MAINTENANCE_INTERVAL_DAYS` (default 2) since the last maintenance session
   (per `logs/session_log.csv`), forces **maintenance**.
7. **Default — the philosophy escalation ladder.** Nothing eligible anywhere means an
   empty queue. Checked last at Priority 4: `consecutive_philosophy_count` 0/1/2 →
   `philosophy` (tier 1/2/3), 3+ → `philosophy_cap`. Placing the cap here (after
   queue-state) means a pre-existing scheduled task always preempts it.

**The types themselves**, one line each:

- **execution** — moves the Loom queue forward; ships artifacts, doesn't replan.
- **planning** — decomposition work (`needs_plan` items) plus inbox absorption
  (judgment-tier `request`/`comment` entries `inbox.py` deliberately leaves alone).
  Has goal-scoped and project-scoped prompt/context variants
  (`planning_goal_scope.yaml`/`planning_project_scope.yaml`), selected by which level
  the dispatch rule actually matched.
- **evaluation** — judges a `desire`-status goal/project before it's worth planning.
- **audit** — reviews a `review`-status goal or a completed `milestone_review` task.
- **maintenance** — structural upkeep, 3-way scope rotation
  (`maintenance_scope{1,2,3}.yaml`) that advances by one on every maintenance session
  regardless of trigger source.
- **philosophy** — the identity/reflection ladder for an empty queue. Three tiers
  selected by `consecutive_philosophy_count` via the YAML scope-merge
  (`philosophy.yaml` + `philosophy_scope{1,2,3}.yaml`). The dispatcher returns
  the single type id `philosophy`; tier selection is a `load_type_config()` concern.
- **reflection** — picked over `philosophy` by `WINDOW_TYPE=reflection` lanes when a
  recent philosophy session already happened (last 3 days), so reflection windows
  don't just re-trigger the same identity work.
- **philosophy_cap** — not a real session type; an abort state, handled entirely
  inside `wake.sh`/`resolve_session_type.py` before any Claude process launches.

## 3. Loom data model

Goals → projects → tasks, sharing one status vocabulary across all three levels
(`desire`, `needs_plan`, `review`, `scheduled`, `in_progress`, `done`, plus
`blocked_reason`/`blocked_note`). This is what §2's queue-state rules read directly —
the dispatcher is not a separate system layered on top of Loom, it *is* a live query
against Loom's own tables.

`state/loom_context.json`'s `active_goal_id`/`active_project_id` (via
`active_goal`/`active_project`) reflect whichever goal/project `loom goal
resolve-active` picked (priority DESC, id ASC among `scheduled`/`in_progress`) — this
is a *different* thing from whatever goal/project a queue-state rule matched for
dispatch purposes in a given session, since rules 1-3 in §2 are system-wide, not
scoped to the active goal. Don't conflate "the goal this session is dispatched for"
with "the goal marked active" — they're usually the same but aren't guaranteed to be.

Two things worth knowing that live in `memory_strategy.md`, not repeated here: the
`files` column on tasks is dead (nothing reads it back — use the task description to
point at a file instead), and goal/project-scoped work goes in
`memory/work/goal_<id>/` or `memory/work/project_<id>/`.

Tags on tasks are a separate dispatch axis from status — see §5.

## 4. The three-tier procedure system

Three distinct tiers, deliberately not collapsed into one mechanism:

- **SOP** (`skills/sop-*/`) — mandatory, dispatched off a task's tags via
  `scripts/executional/tag_skill_lookup.py`, background-layer only. Full mechanics,
  the tag→skill resolution model, and the "when to propose a new SOP" policy live in
  `prompts/reference/tools/loom.md` — this file doesn't restate them.
- **Skill** (`skills/<name>/`, no `sop-` prefix) — discretionary, invoked when the
  agent itself judges it relevant, not tag-dispatched. `skills/revert/` and
  `skills/escalation/` are the two examples so far.
- **Communication-layer standard** (`prompts/reference/communication_standard.md`) —
  not a procedure at all, a register/conduct standard for live conversational
  exchanges (agent↔owner, agent↔agent). Deliberately loose.

The encapsulation principle governing all three (from `loom.md`): none of this gets
broadcast into a session's context by default the way Claude's native Skill-listing
does. Execution resolves only its current task's own tags; planning consults the SOP
list only at the moment of tagging; no other session type touches any of it.

## 5. Memory system

Preloaded (named in a session type's `context_files`) vs. discoverable (exists at a
known path, nothing hands it to you) — the full shape, the identity/knowledge/work
split, and the durable-knowledge convention all live in `memory_strategy.md`. The one
thing worth surfacing here because it ties directly to §1: `soul.md` and
`latest_summary.md` are read as part of every session's orientation, which is exactly
why they're named explicitly as one of `sop-self-arch`'s four blast-radius categories
(§9) — corruption there doesn't stop the agent waking up, it wakes up degraded.

## 6. Inbox

`tools/inbox.py startup` handles auto-tier entries (`context_update`,
`agent_message`, `schedule_directive`, `verified_task`) end to end, without needing a
session's judgment. What's left — `request` and `comment` entries — is deliberately
untouched by `inbox.py`; that placement judgment belongs to planning (§2's
"planning" description covers absorption). The live dispatcher bug in §2 rule 5
(inbox-pending forcing `execution` instead of `planning`) is the concrete failure
mode of this layer not being fully wired yet — cross-referenced from
`sop-self-arch`'s dispatch/routing category, since it's the same underlying risk
class: dispatch logic that doesn't crash, just silently misroutes.

## 7. Credentials, config, and fleet isolation

`state/agent_config.env` carries per-clone identity (`AGENT_NAME`, `OWNER_NAME`) and
optional settings (`DEFAULT_GOAL_ID` — the fallback goal attached when nothing else
is eligible; `ARGUS_URL` — gates whether the argus context poller runs). Provisioned
by `install.sh` (§10). A background-layer task touching this file falls under
`sop-self-arch`'s credential/config category.

Multi-project coordination (more than one project touched by related work) is
`sop-fleet`'s territory — dependencies, environment, and credentials tracked strictly
per-project, never merged into one shared pool even when projects look related.

Nexus: a lightweight heartbeat POST fires at the start of every session if a Nexus
token file exists for this agent (non-fatal if the endpoint isn't live). Deeper Nexus
mechanics belong in `prompts/reference/tools/nexus.md`, not here.

## 8. Background layer vs. communication layer

Everything in §1-§7 is the **background layer** — execution, planning, maintenance,
evaluation, audit, philosophy/creative/blocker_resolver, reflection. These are the
session types SOPs apply to. The **communication layer** is different: live
conversational sessions (Telegram, Nexus agent-channel, an interactive session like
this one) that don't run tagged Loom tasks and aren't SOP-gated at all — they're
governed by `communication_standard.md` instead, and have their own separate
activity-gating mechanism (`tools/executional/check_conv_active.sh`) that this file
doesn't attempt to fully specify — check that script directly rather than trusting a
paraphrase here if the exact mechanics matter for what you're doing.

## 9. Self-architecture safety — the blast-radius map

This is the canonical list `sop-self-arch` references rather than duplicates. Any
task touching one of these four categories falls under that SOP's procedure:

- **Bootstrap/wake chain**: `scripts/executional/wake.sh`, the systemd timer units,
  `scripts/executional/splice_prompt.py`, `scripts/executional/resolve_session_type.py`,
  `config/session_types/*.yaml`, `prompts/core/*.md`, the lock/gate files
  (`state/session.lock`, `state/emergency_mode.active`),
  `session_trigger_server.py`, `scripts/executional/check_window.py`,
  `tools/executional/khal_schedule_reader.py`, `config/session_schedule.json`.
- **Identity/memory chain**: `memory/identity/soul.md`, `memory/latest_summary.md`,
  `prompts/core/memory_read.md`, `prompts/core/memory_write.md`, `memory/MEMORY_MAP.md`.
- **Credential/config chain**: `state/agent_config.env`, token/credential files,
  `install.sh`'s config-writing steps.
- **Dispatch/routing logic**: `scripts/executional/resolve_session_type.py`,
  `config/session_types/*.yaml`. The inbox-pending misrouting bug (§6) is the live,
  current instance of this category — not hypothetical.

Why this list lives here and not only in the SOP: this file is the map (what exists,
how it connects); the SOP is the procedure (what to do about it). Keeping the list in
one place means a category that's added or retired only needs updating once.

## 10. Fresh-clone bootstrap walkthrough

`install.sh`'s actual step sequence, as the concrete worked example tying §1/§3/§7
together:

1. **Prerequisites** — environment/tooling checks.
2. **Configuration** — base install-time settings.
3. **2b. Clone/pull** (optional) — if installing onto a remote target, clones or
   updates the blank_node repo there first.
4. **Directory scaffold** — creates the working tree this whole file describes.
5. **agent_config.env** — writes the identity/config file §7 covers.
6. **4b. Persona** — the agent's persona file.
7. **Credentials** — provisions API keys/tokens.
8. **Nexus registration** — optional; registers this clone as a Nexus peer.
9. **Systemd units** — installs the timers that call `wake.sh` (§1).
10. **Loom setup** — initializes the Loom DB this whole dispatch chain (§2/§3)
    depends on.
11. **8b. khal calendar setup** (optional).
12. **Smoke test** — verifies the install before handing off.
13. **Summary** — next steps (persona review, credential setup on the target, first
    manual launch, timer verification).

A task that modifies `install.sh` itself falls under `sop-self-arch`'s
credential/config category (§9), since a broken install step can produce a clone that
looks provisioned but silently isn't.
