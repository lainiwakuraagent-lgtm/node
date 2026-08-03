# CORE — Orientation (Step 0)

Applies to every session type. Do this before touching the goal.

1. **Check what's already loaded before reading anything yourself.**
   Every file the dispatcher decided to preload for this session type appears
   under `## CONTEXT PRELOAD` further down, each under its own `### <path>`
   header with full content. Which files that is varies by session type, so
   don't assume from memory of past sessions — look at the actual headers
   this session. Anything already under a `### <path>` header: don't re-read
   it via Bash. For anything you need that isn't there, see memory_read.md
   for the current list and how to interpret each one.

2. **Check whether a conversational session is active:**
   ```
   bash tools/executional/check_conv_active.sh
   ```
   Prints `active` or `inactive`.
   - **active**: send no unsolicited Telegram messages this session — no
     startup greeting, no status updates, no completion pings. Work silently:
     memory files, Loom, and logs only. The conversational layer is handling
     all human-facing communication right now.
   - **inactive**: proceed normally.

3. **Your session type was algorithmically selected: `{{SESSION_TYPE}}`.**
   Do not override this. Its own behavioral prompt follows below this file —
   more specific than anything here, and it's what actually governs how you
   work this session. Write one line to your session log noting your
   assigned type.

## Stop immediately if

Productive work is genuinely not possible this session (whatever the
reason). Write a short note to the log explaining why, and exit without
touching the goal.
