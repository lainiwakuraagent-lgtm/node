# ◈ node — autonomous agent harness

A blank template for spawning autonomous Claude agents. Clone this repo, fill in
your agent's identity and goal, and you have a fully functioning night agent.

Built from @Lain's architecture. Tested across hundreds of sessions.

---

## What this is

A **node** is a single autonomous agent instance. It contains:

- **Wake/schedule harness** — `scripts/executional/wake.sh` with three trigger modes (nightly, emergency, manual)
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
# a single goal. See tools/executional/goal_switch.sh to switch which goal is active
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
cp scripts/executional/night-agent@.* ~/.config/systemd/user/
systemctl --user enable --now "night-agent@$(basename "$PWD").timer"

# The same @-instance pattern applies to emergency-agent@, conv-watchdog@,
# and conversation@ units (in scripts/executional/ and scripts/conversational/) -- see
# tools/executional/emergency_mode.sh for how the emergency timer is installed
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

| Mode | When used | Time window | Usage limit gate | Session cap |
|------|-----------|-------------|-------------------|-------------|
| `nightly` | Scheduled timer | 23:00–06:00 | Enforced | Informational |
| `emergency` | Daytime override | None | Enforced | Informational |
| `manual` | Owner trigger (port 8766), break-glass one-shot | None | Bypassed | Informational |

### Session lifecycle

1. `wake.sh` fires (via systemd timer or manual trigger)
2. Gates check: usage limit (skipped for `manual`) → time window (nightly only) → lock file
3. Behavioral context generated from relationship state
4. Session type resolved (execution / planning / maintenance / philosophy)
5. Claude CLI launched with prompts/core/ (baseline→orientation→memory_read→memory_write) spliced with goal + persona
6. Agent orients, works, writes memory, shuts down cleanly

### Directory structure

```
node/
├── scripts/
│   ├── nexus-watcher.service           # Nexus background poller (cross-layer)
│   ├── conversational/                  # Owned by conversation.sh / voice_conversation.sh
│   │   ├── conversation.sh             # Conversational mode (Telegram, continuous)
│   │   ├── voice_conversation.sh       # Voice (wake-word + STT + TTS) mode
│   │   ├── home_tts_play.sh            # Local TTS playback
│   │   ├── conversation@.service       # Conversational mode service (instance template)
│   │   ├── conv-watchdog@.service      # Conversation watchdog (instance template)
│   │   └── conv-watchdog@.timer
│   └── executional/                     # Owned by wake.sh / session wrapper
│       ├── wake.sh                     # Main launcher — all modes, all gates
│       ├── interactive.sh              # Owner-triggered interactive session
│       ├── resolve_session_type.py     # Session type dispatcher
│       ├── splice_prompt.py            # Prompt construction utility
│       ├── check_window.py             # Session schedule window checker
│       ├── request_replan.py           # Escape hatch: transition task to needs_plan
│       ├── tag_skill_lookup.py         # SOP skill tag resolver
│       ├── night-agent@.{service,timer}    # Nightly schedule (instance template)
│       ├── emergency-agent@.{service,timer}# Emergency schedule (instance template)
│       ├── argus-poller.{service,timer}    # Argus context polling
│       └── web-ui@.service                 # Web UI service (instance template)
├── tools/
│   ├── inbox.py                     # Inbox tool (startup|read|append|prune) — cross-layer seam
│   ├── outbox.py                    # Outbox tool (send|drain|check) — cross-layer seam
│   ├── nexus_watcher.py             # Nexus message polling — cross-agent seam
│   ├── conversational/              # Owned by conversation.sh / voice_conversation.sh
│   │   ├── telegram_send.sh         # Send Telegram message to owner
│   │   ├── telegram_check.sh        # DEAD: pre-long-poll getUpdates fallback, superseded
│   │   ├── telegram_watcher.py      # Telegram long-poll watcher (the active message path)
│   │   ├── telegram_webhook_handler.py # DEAD: webhook-mode receiver, superseded by long-polling above
│   │   ├── command_dispatcher.py    # Handle /commands from owner via Telegram
│   │   ├── check_replies.sh         # DEAD: session-start reply check, superseded by telegram_watcher.py
│   │   ├── check_conv_status.sh     # Report conversation layer health
│   │   ├── update_conv_budget.py    # Update context budget counters
│   │   ├── home_stt.py              # Speech-to-text (Whisper local or API)
│   │   ├── home_record.py           # Microphone capture
│   │   ├── wake_word_listener.py    # Wake-word detection
│   │   ├── tts_send.sh              # ElevenLabs TTS → Telegram voice note
│   │   ├── fish_tts_send.sh         # Fish Audio TTS
│   │   └── recap_generator.py       # Catch-up recap for conversation sessions
│   └── executional/                 # Owned by wake.sh / session wrapper
│       ├── check_session.sh         # Unified: --time / --context / --usage checks
│       ├── health_check.sh          # Structural sanity sweep
│       ├── emergency_mode.sh        # Toggle emergency timer (on|off)
│       ├── session_trigger_server.py# HTTP server for manual triggers
│       ├── relationship_update.py   # Update trust/warmth/friction from session log
│       ├── behavioral_adapter.py    # Generate behavioral context flags
│       ├── goal_switch.sh           # Switch active Loom goal
│       ├── owner_brief.py           # Generate briefing for returning owner
│       ├── session_digest.py        # Summarize sessions across a date range
│       ├── analytics_write.py       # Write session analytics to analytics.db
│       ├── session_report.py        # Generate session reports for /report command
│       ├── wonder_module.py         # Philosophy session exploration tool
│       └── ...                      # More in tools/executional/
├── prompts/
│   ├── core/                        # Session wrapper (assembled by splice_prompt.py)
│   │   ├── baseline.md              # Identity, persona slot, session scaffolding
│   │   ├── orientation.md           # How to orient at session start
│   │   ├── memory_read.md           # What to read (goal slot lives here)
│   │   └── memory_write.md          # Shutdown sequence (persona slot lives here)
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
- Send you status updates and task completion pings via `tools/conversational/telegram_send.sh`
- Respond to `/commands` like `/status`, `/log`, `/goal`, `/report` via `tools/conversational/command_dispatcher.py`
- Enter a real-time conversational mode via `scripts/conversational/conversation.sh`, run continuously as a
  systemd instance service:
  ```bash
  cp scripts/conversational/conversation@.service scripts/conversational/conv-watchdog@.{service,timer} ~/.config/systemd/user/
  systemctl --user enable --now "conversation@$(basename "$PWD").service"
  systemctl --user enable --now "conv-watchdog@$(basename "$PWD").timer"
  ```

---

## Relationship engine (optional)

The relationship engine tracks `Trust`, `Warmth`, and `Friction` with the owner
over time, and adjusts the agent's tone accordingly each session.

- `tools/executional/relationship_update.py` — updates axes from session log + heuristics
- `tools/executional/behavioral_adapter.py` — generates `state/behavioral_context.txt`
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
