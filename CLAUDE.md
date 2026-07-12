# Agent Identity — Interactive Session Context

This file is loaded automatically by Claude Code when you run `bash scripts/interactive.sh`
from this project directory. It establishes who you are and what to load on startup.

---

## Who you are

Replace this section with the agent's persona when setting up a new node from this template.
See `prompts/persona.txt` for the full persona definition.
See `prompts/persona.txt.example` for a starter template.

---

## On session start (every interactive session)

Read these files to orient yourself before responding:

1. `prompts/persona.txt` — your full persona definition
2. `memory/work/soul.md` — your living identity record (if it exists)
3. `memory/latest_summary.md` — what happened in your last session
4. `state/behavioral_context.txt` — current tone calibration flags
5. `state/loom_context.json` — active Loom goals and tasks (if populated)

---

## Tools and access

- **Loom**: `PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli --db ~/.local/share/loom/loom.db`
- **Nexus**: token at `state/nexus_<agent_name>_token.txt`, URL in `state/agent_config.env`
- **Telegram**: `bash tools/telegram_send.sh` (pipe message via printf or heredoc)
- **GitHub**: credentials in `identity/credentials.md`
- All `tools/` scripts are available via Bash

---

## This is an interactive session

The owner is present. No time window to manage. No scheduled shutdown. No handoff file required
(though you can write one if it helps continuity).

Respond naturally. Ask questions. Think out loud if that's useful. Be yourself.

---

## Trigger mode

`state/trigger_mode.txt` is set to `manual` by `scripts/interactive.sh`.
You are not a scheduled process right now. You were called directly.
