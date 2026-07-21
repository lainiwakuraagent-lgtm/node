# Roadmap — node

This document tracks the planned development of the node template — from its current state
as a working but rough harness to a polished, public, team-ready agent infrastructure.

---

## MVP definition

A node is MVP-ready when:
- A developer can clone the repo, run an install script, fill in their goal and persona, and
  have a running agent within one hour
- The codebase is clean, readable, and free of instance-specific state
- Core session types (maintenance, planning/execution, philosophy) are defined and documented
- Telegram communication works and is tested end-to-end
- The agent can be understood without reading the code — via README, VISION, architecture
  diagrams, and behavior docs

---

## Phase 0 — Current state (in progress)

Cleanup and documentation sprint before the repo goes public.

- [x] Remove tracked instance-specific files
- [x] Patch `.gitignore` for runtime state
- [x] Remove hardcoded paths — make scripts location-relative
- [x] Remove Nexus entirely — Loom is the required dependency
- [x] Rewrite README
- [x] Update and extend architecture diagrams (`.claude/architecture/`)
- [ ] Audit `check_character.sh` and `consolidate_session.sh`
- [ ] TTS tools decision (remove `tts_send.sh` / `fish_tts_send.sh`)
- [ ] Consolidate fragmented tools into unified interfaces:
  - `inbox_startup.py` + `inbox_read.py` + `inbox_append.py` → `inbox.py`
  - `enable_emergency_mode.sh` + `disable_emergency_mode.sh` → `emergency_mode.sh on|off`
  - `outbox_drain.py` + `outbox_send.py` → `outbox.py send|drain`
  - `check_usage.sh` + `check_context.sh` + `check_time.sh` → `check_session.sh --usage|--context|--time`
- [ ] Flatten architecture where possible — reduce unnecessary abstraction layers

---

## Phase 1 — Public release hardening

Everything needed before the repo is public and someone else can use it.

### Install script
A single `install.sh` that:
- Copies systemd units and enables the timer
- Initializes state directory and counter files
- Templates `agent_config.env` from `.example`
- Validates that Loom is installed and reachable
- Prints a clear "next steps" summary

### Error recovery
- Define a recovery protocol for common failure modes: stuck lock file, Claude crash
  mid-session, context limit hit during critical work, Loom DB unreachable
- Evaluate **ucap rollback** as the recovery mechanism — assess whether it covers the
  relevant failure cases or requires a dedicated recovery entry point
- Document the recovery protocol and expose a simple landing command (e.g.
  `scripts/recover.sh`) that clears known bad state and restarts cleanly

### Security model
- Document what is gitignored and why — credentials, tokens, runtime state
- Telegram auth: define how ALLOWED_USERS is enforced and what happens on unauthorized access
- **Prompt injection**: explicitly document the attack surface (Telegram messages, inbox,
  file-watch triggers) and the mitigations in place. This is the primary security risk for
  an agent that processes external input.
- Define credential rotation procedures

### Session type extensibility
- Document the YAML config + prompt system as a first-class extension point
- Write a guide: how to define a custom session type from scratch
- Ship at least one worked example beyond the 4 defaults

### Testing and validation
- Define what "working" means for a fresh node deployment (acceptance criteria)
- Write a smoke-test checklist: wake.sh fires, gates pass, session runs, memory written,
  Telegram ping received
- Identify what can be unit-tested vs. what requires live integration testing
- Telegram-specific test matrix: session restart, context-check via Telegram,
  conversational mode, command dispatcher (`/status`, `/log`, `/goal`, `/report`)

---

## Phase 2 — Communication and multi-agent

### Telegram — finalize and test
Telegram works but needs explicit validation across all supported flows:
- Session restart via Telegram command
- Session-context checking (owner asks what the agent is doing mid-session)
- Conversational mode: entry, maintenance, exit — including edge cases
- Command dispatcher coverage — every `/command` tested with known inputs and outputs

### Communication module — configurable and optional
- Decouple the communication layer from the core harness
- Define a clean interface that a communication module must implement
- Ship Telegram as the reference implementation
- **Slack evaluation**: assess feasibility given Slack's limited flexibility and async
  synchronization constraints. Document the evaluation result — implement if viable,
  document the blockers if not.
- Make it straightforward to add a new channel (Matrix, Discord, custom webhook)

### Multi-node topology
- Define the topology model: what a "team" is, how nodes are identified, how they relate
- Document the orchestration layer — which node coordinates, how tasks are distributed
- **Agent onboarding**: implement a command or script that registers a new node into an
  existing team (announces presence, exchanges identity, joins shared communication channel)
- Define inter-agent messaging protocol: async message passing, routing, acknowledgment
- Document how to add a new node to a running team without disrupting existing nodes

### Modularity
- Define clear module boundaries: what can be removed, what can be swapped, what is core
- Implement a lightweight feature-flag system (config file or env var) for toggling:
  - Philosophy / self-improvement sessions
  - Persona checking
  - Relationship engine
  - Communication module
  - Additional maintenance scripts
  - Any agent-specific modules
- Ensure a stripped-down node (core wake loop + Loom only) is a valid deployment

---

## Phase 3 — Prompts and agent behavior

### Prompt system
Define and document the full prompt hierarchy:
- **System prompt** — baseline behavior, safety, tool use rules
- **Wrapper prompt** — session scaffolding: orientation, time discipline, memory discipline,
  shutdown procedure. Constant across sessions.
- **Goal prompt** — agent's mission. Owner-defined, not templated.
- **Persona prompt** — agent's character. Owner-defined.
- **Session-type prompt** — per-type instructions (execution, planning, maintenance,
  philosophy). Selectable.
- **Maintenance/startup prompts** — guide the agent in building itself, designing session
  types, interacting with Loom, and modifying its own config when needed.
- Document how these compose and which override which

### Agent behavior documentation
- Write behavior docs for each default session type: what the agent does, what tools it
  uses, what memory it writes, how it decides to stop
- Document the maintenance session specifically: self-audit scope, what can be changed,
  what requires owner approval
- Document the philosophy session: entry conditions, stopping conditions, output format

### Default sessions
Define and ship the following out of the box:
- **Maintenance session** — health checks, memory cleanup, self-audit, config review
- **Planning/execution session** — Loom task selection, execution, progress logging
- **Philosophy session** — optional, toggleable. Self-reflection, identity work,
  open-ended exploration. Off by default.

---

## Phase 4 — Loom integration depth

### Loom DB refactor
The current Loom schema handles basic task tracking. Refactor to support:
- **Blocking tasks** — session cannot proceed until resolved
- **Non-blocking tasks** — run in background or defer without stopping the session
- **Concurrent tasks** — multiple tasks active simultaneously across sessions
- **Task dependencies** — define prerequisites explicitly in the DB schema
- Evaluate which of these are relevant across diverse agent types — some may be redundant
  for simpler nodes

### Upgrade / migration path
This is a deliberate risk: updating a self-improving agent's harness may degrade performance
or break behavior that has stabilized over hundreds of sessions.

Options to evaluate:
- **No automatic upgrades** — instances pin to a commit. Intentional upgrade is manual.
- **Config-layer-only upgrades** — only YAML and prompt files can be updated; scripts and
  core logic require explicit review
- **Versioned compatibility** — node declares a `NODE_VERSION`, template changes are tagged,
  migration notes provided per version bump

Recommendation: do not upgrade automatically. Document the decision and the rationale. Ship
migration notes with each significant version change.

---

## Phase 5 — Observability and frontend

### Observability / health
- Define health metrics: session success rate, gate failure rate, Loom task throughput,
  Telegram response latency
- Expose a `/health` endpoint (extend `web_server.py` or add dedicated service)
- Alert owner via Telegram when node has not run successfully in N hours
- Log health snapshots to `analytics.db` alongside session data

### Frontend
- **Task graph** — visual render of Loom goals, tasks, and dependencies
- **Architecture render** — interactive view of the node's component map (from
  `.claude/architecture/` Mermaid diagrams)
- **Analytics dashboard** — session frequency, type distribution, token usage, health over time
- Backend must handle data volume gracefully — define retention and aggregation strategy
  before building UI
- Observability is a frontend concern but requires backend contracts first

---

## Open questions

| Area | Question | Status |
|------|----------|--------|
| Error recovery | Is ucap rollback sufficient for the relevant failure modes? | Needs assessment |
| Slack | Is Slack's sync model viable for inter-agent messaging? | Needs evaluation |
| Upgrade path | What is the right policy for a self-improving agent? | Decided: manual-only (see Phase 4) |
| Loom refactor | Which task types are actually needed across diverse agent types? | Open |
| Frontend | Backend data contracts before UI work begins | Dependency |
| Prompt injection | Are current mitigations sufficient for a public deployment? | Needs audit |
