# ◈ node — autonomous agent harness

A blank template for spawning autonomous Claude agents. Clone this repo, fill in
your agent's identity and goal, and you have a fully functioning night agent.

Built from @Lain's architecture. Tested across hundreds of sessions.

---

## What this is

A **node** is a single autonomous agent instance. It contains:

- **Wake/schedule harness** — `scripts/wake.sh` with three trigger modes (nightly, emergency, manual)
- **Systemd units** — night timer + emergency timer, user-level (no root needed)
- **Tool suite** — message checking, Nexus integration, Telegram, GitHub comms, memory tools
- **Loom integration** — goal tracking, session lifecycle, task management
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
# Edit with GitHub PAT, Nexus password, etc.

# 3. Define the agent
cp prompts/goal.txt.example prompts/goal.txt
cp prompts/persona.txt.example prompts/persona.txt
# Edit both files

# 4. Configure environment
cp ~/.claude/.env.example ~/.claude/.env
# Add TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS, NEXUS_URL, NEXUS_PASSWORD

# 5. Install systemd timers
bash scripts/wake.sh install
# or manually: cp scripts/night-agent.* ~/.config/systemd/user/ && systemctl --user enable --now night-agent.timer

# 6. Initialize state
mkdir -p state logs memory/sessions memory/work
echo "nightly" > state/sessions_tonight.max  # default cap: 5/night
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
| `nightly` | Scheduled timer | 23:00–06:00 | Hard cap (sessions_tonight.max) |
| `emergency` | Daytime override | None | Informational only |
| `manual` | Owner trigger (port 8766) | None | Informational only |

### Session lifecycle

1. `wake.sh` fires (via systemd timer or manual trigger)
2. Gates check: usage limit → time window → session cap → lock file
3. JWT refresh (Nexus)
4. Behavioral context generated from relationship state
5. Claude CLI launched with wrapper_prompt + goal + persona
6. Agent orients, works, writes memory, shuts down cleanly

### Directory structure

```
node/
├── scripts/
│   ├── wake.sh                    # Main launcher — all modes, all gates
│   ├── night-agent.{service,timer} # Nightly schedule (systemd)
│   ├── emergency-agent.{service,timer} # Emergency schedule
│   └── splice_prompt.py           # Prompt construction utility
├── tools/
│   ├── check_time.sh              # Time window + remaining minutes
│   ├── check_context.sh           # Estimated context window usage
│   ├── check_usage.sh             # Claude API usage limit check
│   ├── check_replies.sh           # Read incoming messages (all channels)
│   ├── check_nexus.sh             # Nexus message polling
│   ├── enable_emergency_mode.sh   # Activate emergency timer
│   ├── disable_emergency_mode.sh  # Deactivate emergency timer
│   ├── session_trigger_server.py  # HTTP server for manual triggers
│   ├── nexus_client.py            # Nexus API client
│   ├── nexus_send.sh              # Send message to Nexus channel
│   ├── telegram_send.sh           # Send Telegram message to owner
│   ├── telegram_check.sh          # Check Telegram for new messages
│   ├── relationship_update.py     # Update trust/warmth/friction from session log
│   ├── behavioral_adapter.py      # Generate behavioral context flags
│   ├── goal_switch.sh             # Switch active Loom goal
│   ├── owner_brief.py             # Generate briefing for returning owner
│   ├── session_digest.py          # Summarize sessions across a date range
│   └── ...                        # More in tools/
├── prompts/
│   ├── wrapper_prompt.md          # Session wrapper (orientation, shutdown, memory)
│   ├── goal.txt                   # Current agent goal (YOU fill this in)
│   └── persona.txt                # Agent persona (YOU fill this in)
├── state/                         # Runtime state (mostly gitignored)
├── logs/                          # Session outputs (gitignored)
├── memory/                        # Agent memory (gitignored — instance-specific)
└── identity/
    └── credentials.md             # Agent credentials (gitignored)
```

---

## Nexus integration

Nexus is the messaging and coordination backend. Each agent connects to Nexus
to receive tasks, post updates, and coordinate with other agents.

Configure in `~/.claude/.env`:
```
NEXUS_URL=http://your-nexus-host:8000
NEXUS_USERNAME=your-agent-username
NEXUS_PASSWORD=your-agent-password
```

The agent auto-refreshes its JWT token each wake via `wake.sh`.

---

## Loom (goal tracking)

Loom is the goal and session tracking DB (`~/.local/share/loom/loom.db`).

```bash
# Install loom
git clone https://github.com/lainiwakuraagent-lgtm/loom.git ~/lain/loom
cd ~/lain/loom && python3 -m venv .venv && .venv/bin/pip install -e .

# Create your first goal
~/lain/loom/.venv/bin/python -m loom.cli goal add "My agent's mission"
~/lain/loom/.venv/bin/python -m loom.cli goal list --all
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
