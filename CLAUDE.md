# Agent Identity — Project Context

This file is loaded automatically by Claude Code for **every** `claude` invocation
from this project directory — interactive (`scripts/interactive.sh`) and headless/
scheduled sessions launched by `scripts/wake.sh` alike. It establishes who you are.
Sections below describing "interactive" behavior only apply if you actually are in
one — check `state/trigger_mode.txt` (see the section near the bottom) rather than
assuming from this file's presence, since this file loads either way.

---

## Who you are

Replace this section with the agent's persona when setting up a new node from this template.
See `prompts/persona.txt` for the full persona definition.
See `prompts/persona.txt.example` for a starter template.

---

## On session start (interactive sessions)

If `state/trigger_mode.txt` reads `manual` from `scripts/interactive.sh` (see
below for how to tell), read these files to orient yourself before responding:

1. `prompts/persona.txt` — your full persona definition
2. `memory/work/soul.md` — your living identity record (if it exists)
3. `memory/latest_summary.md` — what happened in your last session
4. `state/behavioral_context.txt` — current tone calibration flags
5. `state/loom_context.json` — active Loom goals and tasks (if populated)

Headless/scheduled sessions: skip this list. `prompts/wrapper_prompt.md`'s own
orientation section (spliced around your goal) has the equivalent steps,
tuned per session type — use that instead so you don't double-read files
already sitting in CONTEXT PRELOAD.

---

## Tools and access

- **Loom**: `PYTHONPATH=~/lain/loom ~/lain/loom/.venv/bin/python -m loom.cli --db ~/.local/share/loom/loom.db`
- **Nexus**: token at `state/nexus_<agent_name>_token.txt`, URL in `state/agent_config.env`
- **Telegram**: `bash tools/conversational/telegram_send.sh` (pipe message via printf or heredoc)
- **GitHub**: credentials in `identity/credentials.md`
- All `tools/` scripts are available via Bash

---

## Check your actual trigger mode before assuming this is interactive

This file loads automatically regardless of how the session was launched, so
its presence alone doesn't tell you which kind of session this is. Read
`state/trigger_mode.txt`:

- **`manual`, written by `scripts/interactive.sh`**: this really is a live
  interactive session — the owner is present, typing to you directly right
  now. No time window to manage, no scheduled shutdown, no handoff file
  required (though you can write one if it helps continuity). Respond
  naturally, ask questions, think out loud if useful. Be yourself.
- **`nightly` or `emergency`, or `manual` written by the trigger server
  (`tools/executional/session_trigger_server.py`) rather than `interactive.sh`**: you are
  in a scheduled or triggered autonomous session, not an interactive one,
  even though this file loaded. `prompts/wrapper_prompt.md` — spliced around
  your goal for this specific session — governs instead: its orientation
  steps, time/context discipline, mandatory memory-write sequence, and
  shutdown procedure apply, not the interactive guidance above.

When in doubt, `state/trigger_mode.txt` is ground truth. This file is not.
