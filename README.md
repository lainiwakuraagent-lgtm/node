# ◈ node — autonomous agent harness

A blank template for spawning autonomous Claude agents. Clone this repo, fill in
your agent's identity and goal, and you have a fully functioning night agent.

Built from @Lain's architecture. Tested across hundreds of sessions.

---

## What this is

A **node** is a single autonomous agent instance. It contains:

- **Wake/schedule harness** — `scripts/wake.sh` with three trigger modes (nightly, emergency, manual)
- **Systemd units** — night timer + emergency timer, user-level (no root needed)
- **Tool suite** — Telegram communication, memory tools, analytics, reporting, scheduling
- **Loom integration** — goal tracking, session lifecycle, task management (required)
- **Relationship engine** — trust/warmth/friction tracking with behavioral adaptation
- **Wrapper prompt** — session scaffolding (orientation, time limits, memory discipline, shutdown)

What this is NOT:
- Memory files (instance-specific — generated at runtime)
- Identity/credentials (yours to fill in)
- Goal and persona (yours to define)

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
cp prompts/goal.txt.example prompts/goal.txt
cp prompts/persona.txt.example prompts/persona.txt
# Edit both files

# 4. Configure environment
cp state/agent_config.env.example state/agent_config.env
# Set AGENT_NAME, OWNER_NAME, NODE_VERSION

# 5. Configure Telegram (for communication)
# Add to ~/.claude/.env:
#   TELEGRAM_BOT_TOKEN=<your bot token>
#   TELEGRAM_ALLOWED_USERS=<your chat id>

# 6. Install systemd timers
cp scripts/night-agent.* ~/.config/systemd/user/
systemctl --user enable --now night-agent.timer

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
│   ├── night-agent.{service,timer}  # Nightly schedule (systemd)
│   ├── emergency-agent.{service,timer} # Emergency schedule
│   ├── resolve_session_type.py      # Session type dispatcher
│   └── splice_prompt.py             # Prompt construction utility
├── tools/
│   ├── check_time.sh                # Time window + remaining minutes
│   ├── check_context.sh             # Estimated context window usage
│   ├── check_usage.sh               # Claude API usage limit check
│   ├── check_replies.sh             # Read incoming messages (reply.txt + Telegram)
│   ├── enable_emergency_mode.sh     # Activate emergency timer
│   ├── disable_emergency_mode.sh    # Deactivate emergency timer
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
│   ├── outbox_send.py               # Queue async messages to owner
│   ├── wonder_module.py             # Philosophy session exploration tool
│   └── ...                          # More in tools/
├── prompts/
│   ├── wrapper_prompt.md            # Session wrapper (orientation, shutdown, memory)
│   ├── goal.txt                     # Current agent goal (YOU fill this in)
│   ├── persona.txt                  # Agent persona (YOU fill this in)
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
- Enter a real-time conversational mode via `scripts/conversation.sh`

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
