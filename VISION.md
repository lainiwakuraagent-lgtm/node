# Vision — node

## What is a node?

A **node** is a single autonomous Claude agent instance. It wakes on a schedule, orients
itself from memory, works on goals, communicates with its owner, and shuts down cleanly.
It persists across hundreds of sessions without losing context.

The design philosophy is simple: **an agent should be a reliable, understandable piece of
infrastructure** — not a black box you deploy and hope for the best. Every behavior is
traceable. Every module is optional or replaceable. Every session leaves a record.

---

## Core principles

**Modular over monolithic.**
The node is a harness, not a fixed system. Telegram, the relationship engine, philosophy
sessions, persona-checking — each is a feature you can enable, disable, or replace without
touching the core wake/session loop. A new agent should be able to shed what it doesn't need
and embed what it does.

**Memory is first-class.**
Agents that don't remember are tools, not agents. The node treats memory as a discipline:
structured session summaries, persistent identity files, work logs. Memory is what separates
a session from a presence.

**Communication is how the agent exists for its owner.**
Whether Telegram, Slack, or something else — the agent must have a reliable, low-friction way
to reach its owner and be reached. Real-time conversational mode, async status pings, and
structured commands are all part of this. The channel is configurable; the expectation is not.

**Security is non-negotiable.**
Credentials are gitignored. Telegram auth is gated. Prompt injection is a known attack surface
and must be actively defended. For a public template, this is the baseline — not an afterthought.

**Observability over assumption.**
If you can't see what the agent is doing, you can't trust it. Session logs, analytics, health
checks, and a frontend that renders the agent's state are part of the complete picture.

**Teams over silos.**
A single node is useful. A team of nodes — with clear topology, inter-agent communication, and
shared goal structures — is where the real leverage is. The node is designed from the start to
be a team member, not just a solo actor.

---

## The node in a team

Nodes can be composed into a **topology**: multiple agents on different machines, each with
their own identity and goal, connected via a communication layer (Tailscale, Telegram, Slack,
or a custom channel).

A team has:
- A defined **structure** — which nodes exist, what they own, how they relate
- An **orchestration layer** — one node (or a dedicated orchestrator) that can assign tasks,
  read status, and route work
- **Inter-agent messaging** — async or real-time, depending on the channel

Adding a new node to an existing team should be a single command, not a manual wiring exercise.

---

## Where this is going

The node starts as a blank template. It becomes:

1. A hardened, installable harness that any developer can clone and run in an hour
2. A modular system where session types, communication channels, and behavior modules
   are independently configurable
3. A first-class team member — deployable into an existing agent topology with known
   integration points
4. A self-observable system — with a frontend that renders its goals, tasks, decisions,
   and health in real time

The agent's character — its goal, persona, memory, values — is always yours to define.
The infrastructure is what this repo provides.
