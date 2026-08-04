---
name: close-conversational-session
description: Close a conversational-layer session cleanly — Telegram or Nexus agent-channel. Writes a checkpoint (channel-appropriate shape), handles Nexus-only relationship bookkeeping when the exchange is genuinely over, and writes exit_reason.txt so the launcher (conversation.sh / agent_channel.sh) knows whether to restart. Replaces close-comms-session and wrap-conversation-session, which duplicated this with two inconsistent implementations.
argument-hint: channel=telegram|<nexus_channel_id> reason=reset|idle_close|closed_by_agent
allowed-tools: Read Write Edit Bash
---

Closes a conversational-layer session — Telegram or Nexus agent-channel, same
skill, branching on `channel`. `PROJECT_DIR` is exported by the launcher
(`conversation.sh` or `agent_channel.sh`); this skill does not run outside
that context and does not hardcode a fallback.

Do **not** write analytics or sync to Honcho here — `conversation.sh` and
`agent_channel.sh` both already do that automatically after every session
exit, regardless of exit reason. Doing it again here would double-record.

---

## Step 0 — Parse arguments

`$ARGUMENTS` is `channel=<value> reason=<value>`.

- `channel` — `telegram`, or a Nexus channel UUID.
- `reason` — `reset` or `idle_close` (Telegram only), or `closed_by_agent`
  (Nexus only, the agent decided the exchange is done). This skill is not
  for `context_full` on either channel — that's a mid-conversation context
  handoff, not a close, and stays handled inline where it already is
  (`agent_channel.md`'s `context_hard` branch; Telegram no longer has a
  context-triggered close at all).

Resolve the state directory:
- `channel=telegram` → `$PROJECT_DIR/state/conversation`
- otherwise → `$PROJECT_DIR/state/agent_channels/<channel>`

---

## Step 1 — Write checkpoint.json

Summarize the thread (tail `thread.json` in the resolved state dir — last
~20 entries is plenty, don't read it in full) in 3-5 lines: what was
discussed, anything left open. If `reason=idle_close`, say so plainly in the
summary ("session idled out, no new messages") rather than inventing content.

**Telegram** (`<state_dir>/checkpoint.json`):
```json
{
  "timestamp": "<ISO timestamp>",
  "summary": "<3-5 line summary>",
  "last_messages": [
    {"role": "andrii", "text": "..."},
    {"role": "lain", "text": "..."}
  ]
}
```

**Nexus** (`<state_dir>/checkpoint.json`):
```json
{
  "channel_id": "<channel>",
  "peer_id": "<peer_id, from nexus_session_context.json>",
  "saved_at": "<ISO timestamp>",
  "summary": "<3-5 line summary>",
  "open_threads": ["<any unresolved topics>"],
  "last_msg_ts": "<ISO timestamp of last message>"
}
```

---

## Step 2 — Nexus-only: the exchange is genuinely over

Only when `channel != telegram` **and** `reason = closed_by_agent`. Skip this
entire step for `reset`/`idle_close` (Telegram-only reasons — never applies)
and skip it for any other Nexus exit — this is specifically for "the peer
relationship continues, but this particular exchange has concluded."

1. Read `peer_id` from `<state_dir>/nexus_session_context.json`.
2. Append a dated entry to `$PROJECT_DIR/memory/conversations/<peer_id>_summary.md`
   (create with a header if it doesn't exist — see the reference format below).
3. Update `$PROJECT_DIR/state/nexus_watcher_state.json`: set this channel's
   `state` to `"idle"`, `active_session_pid` to `null`,
   `conversation_timer_last_reset` to `null`, so `nexus_watcher.py` knows it
   can re-spawn this channel when new messages arrive.

Do **not** delete `nexus_session_context.json` yourself — the launcher reads
it after this session exits (for its own Honcho sync) and deletes it as the
last step, only for `closed_by_agent`. Deleting it here would race the
launcher's read.

**`memory/conversations/<peer_id>_summary.md` format** (create if absent):
```markdown
# Conversation history: <peer_id>
# Last updated: <today's date>

## Relationship overview
[Who this peer is, communication style, notable patterns — fill in what you know]

## Conversation log
```
Append under `## Conversation log`:
```markdown
### <YYYY-MM-DD> — <one-line topic derived from summary>
<The 3-5 sentence summary from Step 1.>
```
Use append, not full rewrite, to avoid clobbering concurrent writes.

---

## Step 3 — Delete the reset signal (Telegram only, harmless elsewhere)

```bash
rm -f "$PROJECT_DIR/state/conversation/reset_signal.txt"
```
No-op for Nexus — that file doesn't exist there. Only relevant when
`reason` came from `reset_signal.txt` in the first place (`reset`/`idle_close`);
delete it before writing `exit_reason.txt` below so a crash mid-close
self-heals (the next watcher poll re-emits the same signal instead of the
session vanishing silently).

---

## Step 4 — Write exit_reason.txt and exit

```bash
echo "<reason>" > "<state_dir>/exit_reason.txt"
```
Then exit 0. The launcher reads this file and decides whether to restart:
`reset` restarts (and sends its own hardcoded confirmation once the new
session is up — not your job), `idle_close` stops the service silently,
`closed_by_agent` stops the Nexus channel service.
