# ◈ node — autonomous agent harness

A blank template for spawning autonomous Claude agents. Clone this repo, fill in
your agent's identity and goal, and you have a fully functioning night agent.

Built from @Lain's architecture. Tested across hundreds of sessions.

---

## What this is

A **node** is a single autonomous agent instance. It contains:

- **Wake/schedule harness** — `scripts/wake.sh` with three trigger modes (nightly, emergency, manual)
- **Systemd units** — night timer + emergency timer, user-level (no root needed), instance-templated per clone
- **Tool suite** — Telegram communication, memory tools, analytics, reporting, scheduling
- **Loom integration** — goal tracking, session lifecycle, task management (required)
- **Relationship engine** — trust/warmth/friction tracking with behavioral adaptation
- **Wrapper prompt** — session scaffolding (orientation, time limits, memory discipline, shutdown)

What this is NOT:
- Memory files (instance-specific — generated at runtime)
- Identity/credentials (yours to fill in)
- Persona (yours to define); the goal is defined in Loom, not a file

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/lainiwakuraagent-lgtm/node.git my-agent
cd my-agent

# 2. Fill in identity
cp identity/credentials.md.example identity/credentials.md
# Edit with GitHub PAT, Telegram token, etc.

# 3. Define the agent
cp prompts/persona.txt.example prompts/persona.txt
# Edit persona.txt for your agent. The goal is no longer a file -- Loom is
# the sole goal/project source. Create the first goal directly in Loom:
PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli \
  --db ~/.local/share/loom/loom.db goal add -n "..." -d "..." --status scheduled
# wake.sh resolves whichever goal has the highest priority among
# scheduled/in_progress goals automatically -- no activation step needed for
# a single goal. See tools/goal_switch.sh to switch which goal is active
# once you have more than one.

# 4. Configure environment
cp state/agent_config.env.example state/agent_config.env
# Set AGENT_NAME, OWNER_NAME, NODE_VERSION
# Optionally set DEFAULT_GOAL_ID once you've created a standing goal in Loom
# for the agent to fall back to when no goal/project/task is eligible --
# see the commented example in agent_config.env.example. Leave unset to fall
# back to plain philosophy with no goal framing.

# 5. Configure Telegram (for communication)
# Add to ~/.claude/.env:
#   TELEGRAM_BOT_TOKEN=<your bot token>
#   TELEGRAM_ALLOWED_USERS=<your chat id>

# 5a. Configure outbox delivery routing (required for tools/outbox.py drain to
# actually send anything -- without this, outbound messages queue forever
# with no error, only a quiet line in logs/wake.log)
cp state/delivery_routing.json.example state/delivery_routing.json
# Set "chat_id" to the same value as TELEGRAM_ALLOWED_USERS above

# 6. Install systemd timers
# Units are systemd instance templates: %i = this clone's directory name,
# %h = your home dir -- no manual path/username editing needed. This DOES
# require the clone to live at ~/lain/<name> (matching %h/lain/%i); if you
# cloned it somewhere else, move it there first.
cp scripts/night-agent@.* ~/.config/systemd/user/
systemctl --user enable --now "night-agent@$(basename "$PWD").timer"

# The same @-instance pattern applies to emergency-agent@, conv-watchdog@,
# and conversation@ units (scripts/*.service, scripts/*.timer) -- see
# tools/emergency_mode.sh for how the emergency timer is installed
# dynamically, and the Telegram section below for the conversational layer.

# 7. Initialize state
mkdir -p state logs memory/sessions memory/work
echo "0" > state/sessions_tonight.count
echo "0" > state/sessions_tonight.date
echo "0" > state/sessions_emergency.count
echo "0" > state/sessions_manual.count
```

---

## Architecture

### Trigger modes (`state/trigger_mode.txt`)

| Mode | When used | Time window | Session cap |
|------|-----------|-------------|-------------|
| `nightly` | Scheduled timer | 23:00–06:00 | Informational |
| `emergency` | Daytime override | None | Informational |
| `manual` | Owner trigger (port 8766) | None | Informational |

### Session lifecycle

1. `wake.sh` fires (via systemd timer or manual trigger)
2. Gates check: usage limit → time window → lock file
3. Behavioral context generated from relationship state
4. Session type resolved (execution / planning / maintenance / philosophy)
5. Claude CLI launched with wrapper_prompt + goal + persona
6. Agent orients, works, writes memory, shuts down cleanly

### Directory structure

```
node/
├── scripts/
│   ├── wake.sh                      # Main launcher — all modes, all gates
│   ├── interactive.sh               # Owner-triggered interactive session
│   ├── conversation.sh              # Conversational mode (Telegram, continuous)
│   ├── night-agent@.{service,timer}    # Nightly schedule (systemd instance template)
│   ├── emergency-agent@.{service,timer}# Emergency schedule (instance template)
│   ├── conv-watchdog@.{service,timer}  # Conversation watchdog (instance template)
│   ├── conversation@.service           # Conversational/Telegram mode (instance template)
│   ├── resolve_session_type.py      # Session type dispatcher
│   └── splice_prompt.py             # Prompt construction utility
├── tools/
│   ├── check_session.sh             # Unified: --time / --context / --usage checks
│   ├── check_replies.sh             # Read incoming messages (reply.txt + Telegram)
│   ├── emergency_mode.sh            # Toggle emergency timer (on|off)
│   ├── session_trigger_server.py    # HTTP server for manual triggers
│   ├── telegram_send.sh             # Send Telegram message to owner
│   ├── telegram_check.sh            # Check Telegram for new messages
│   ├── telegram_watcher.py          # Telegram long-poll watcher (conversational mode)
│   ├── command_dispatcher.py        # Handle /commands from owner via Telegram
│   ├── relationship_update.py       # Update trust/warmth/friction from session log
│   ├── behavioral_adapter.py        # Generate behavioral context flags
│   ├── goal_switch.sh               # Switch active Loom goal
│   ├── owner_brief.py               # Generate briefing for returning owner
│   ├── session_digest.py            # Summarize sessions across a date range
│   ├── analytics_write.py           # Write session analytics to analytics.db
│   ├── session_report.py            # Generate session reports for /report command
│   ├── inbox.py                     # Inbox tool (startup|read|append|prune)
│   ├── outbox.py                    # Outbox tool (send|drain|check)
│   ├── wonder_module.py             # Philosophy session exploration tool
│   └── ...                          # More in tools/
├── prompts/
│   ├── wrapper_prompt.md            # Session wrapper (orientation, shutdown, memory)
│   ├── persona.txt                  # Agent persona (YOU fill this in)
│   │                                 # (goal lives in Loom now, not a file here)
│   └── session_types/               # Per-type prompts (execution, planning, etc.)
├── config/
│   └── session_types/               # YAML config for each session type
├── skills/                          # SOP skill library (revert, sop-feature, etc.)
├── state/                           # Runtime state (mostly gitignored)
├── logs/                            # Session outputs (gitignored)
├── memory/                          # Agent memory (gitignored — instance-specific)
└── identity/
    └── credentials.md               # Agent credentials (gitignored)
```

---

## Loom (required — goal tracking)

Loom is the goal and session tracking DB (`~/.local/share/loom/loom.db`).
It is a required dependency — the session type dispatcher reads it to decide
what the agent should work on each session.

```bash
# Install loom
git clone https://github.com/lainiwakuraagent-lgtm/loom.git ~/lain/loom
cd ~/lain/loom && python3 -m venv .venv && .venv/bin/pip install -e .

# Create your first goal
~/lain/loom/.venv/bin/python -m loom.cli goal add "My agent's mission"
~/lain/loom/.venv/bin/python -m loom.cli goal list --all
```

---

## Telegram (optional — recommended)

Telegram is how you communicate with the agent. Configure once:

```
# In ~/.claude/.env:
TELEGRAM_BOT_TOKEN=<your bot token from @BotFather>
TELEGRAM_ALLOWED_USERS=<your numeric chat id>
```

Once configured, the agent can:
- Send you status updates and task completion pings via `telegram_send.sh`
- Respond to `/commands` like `/status`, `/log`, `/goal`, `/report` via `command_dispatcher.py`
- Enter a real-time conversational mode via `scripts/conversation.sh`, run continuously as a
  systemd instance service:
  ```bash
  cp scripts/conversation@.service scripts/conv-watchdog@.{service,timer} ~/.config/systemd/user/
  systemctl --user enable --now "conversation@$(basename "$PWD").service"
  systemctl --user enable --now "conv-watchdog@$(basename "$PWD").timer"
  ```

---

## Relationship engine (optional)

The relationship engine tracks `Trust`, `Warmth`, and `Friction` with the owner
over time, and adjusts the agent's tone accordingly each session.

- `tools/relationship_update.py` — updates axes from session log + heuristics
- `tools/behavioral_adapter.py` — generates `state/behavioral_context.txt`
- `wake.sh` runs both automatically post-session

To disable: comment out the relevant lines in `wake.sh`.

---

## Origin

This template was extracted from @Lain's live instance node.
@Lain is an autonomous Claude agent running on Tailscale, summoned at night
and during demonstrations to build, think, and persist across hundreds of sessions.

The instance node lives at: `lainiwakuraagent-lgtm/lain-node`
This blank template lives at: `lainiwakuraagent-lgtm/node`

⊙_⊙
