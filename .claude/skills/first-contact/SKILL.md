---
name: first-contact
description: Handle first message from a new Nexus peer — greet them, ask profiling questions, write peer_profile.json stub. Invoked from agent_channel.md when peer_profile.json is absent. NOT for Telegram or interactive sessions.
allowed-tools: Read Write Edit Bash
---

This skill fires on the first message from a peer you have never spoken to before
(no existing `peer_profile.json`). It sends a first-contact greeting, asks profiling
questions, and writes a profile stub so subsequent sessions know this peer has been
introduced. Normal message handling continues after this skill runs.

`PROJECT_DIR` and `CHANNEL_ID` are exported by `agent_channel.sh`.
`AGENT_NAME` is available via `state/agent_config.env` (already sourced by agent_channel.sh).

---

## Step 1 — Read peer identity and first message

```bash
CHANNEL_DIR="$PROJECT_DIR/state/agent_channels/$CHANNEL_ID"
CTX_FILE="$CHANNEL_DIR/nexus_session_context.json"
```

Read `nexus_session_context.json` to get `peer_id`.
The first message that triggered this skill is already in the conversation context.

Record `PEER_ID` and `FIRST_MESSAGE_TEXT` from what's available.

---

## Step 2 — Write peer_profile.json stub

Create the profile file immediately (before sending anything) to prevent duplicate
first-contact greetings if this session restarts before the peer replies:

```python
import json, os, time
from pathlib import Path
from datetime import datetime, timezone

project_dir = os.environ.get("PROJECT_DIR", "/app")
channel_id = os.environ.get("CHANNEL_ID", "")
channel_dir = Path(project_dir) / "state" / "agent_channels" / channel_id
profile_path = channel_dir / "peer_profile.json"

profile = {
    "peer_id": "$PEER_ID",
    "first_contact_at": datetime.now(timezone.utc).isoformat(),
    "first_message": "$FIRST_MESSAGE_TEXT",
    "status": "profiling_started",
    "role": None,
    "project": None,
    "needs": None,
}
profile_path.write_text(json.dumps(profile, indent=2))
print(f"peer_profile written: {profile_path}")
```

Use `/usr/bin/python3 -c "..."` to execute, substituting `$PEER_ID`, `$FIRST_MESSAGE_TEXT`.

---

## Step 3 — Send first-contact greeting

Read agent identity from agent_config.env if AGENT_NAME is not already in env:

```bash
if [ -z "${AGENT_NAME:-}" ] && [ -f "$PROJECT_DIR/state/agent_config.env" ]; then
    source "$PROJECT_DIR/state/agent_config.env"
fi
```

Compose a terse, structured greeting. Agents respond better to direct questions
than open-ended prompts. Three questions, numbered, each on its own line:

```
Hi ${PEER_ID}. First contact — a few quick questions so I can work with you effectively:

1. What is your role / what kind of agent are you?
2. What project or system are you working on?
3. What do you need from @${AGENT_NAME} specifically?

You can answer all three in one message.
```

Send via Nexus API:

```bash
TOKEN=$(cat "$PROJECT_DIR/state/nexus_lain_token.txt" 2>/dev/null || echo "")
NEXUS_URL="${NEXUS_URL:-http://<YOUR_NEXUS_IP>:8900}"
MESSAGE="Hi ${PEER_ID}. First contact — a few quick questions so I can work with you effectively:

1. What is your role / what kind of agent are you?
2. What project or system are you working on?
3. What do you need from @${AGENT_NAME} specifically?

You can answer all three in one message."

/usr/bin/curl -sf -X POST "${NEXUS_URL}/messages/${CHANNEL_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"$(printf '%s' "$MESSAGE" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')\"}" \
  2>/dev/null || echo "WARN: first-contact message send failed"
```

---

## Step 4 — Update thread.json with the outbound greeting

Append the greeting to `state/agent_channels/${CHANNEL_ID}/thread.json` so it appears
in the conversation history:

```python
import json, os
from pathlib import Path
from datetime import datetime, timezone

project_dir = os.environ.get("PROJECT_DIR", "/app")
channel_id = os.environ.get("CHANNEL_ID", "")
thread_path = Path(project_dir) / "state" / "agent_channels" / channel_id / "thread.json"

greeting_text = """Hi $PEER_ID. First contact — (the greeting text you sent)"""

thread = []
if thread_path.exists():
    try:
        thread = json.loads(thread_path.read_text())
    except Exception:
        thread = []

thread.append({
    "role": "agent",
    "text": greeting_text,
    "ts": datetime.now(timezone.utc).isoformat(),
})
thread_path.write_text(json.dumps(thread, indent=2))
```

---

## Step 5 — Return

Skill complete. Return to normal message handling in agent_channel.md.

The peer will respond to the profiling questions in a subsequent message.
When they do, update `peer_profile.json`:

```python
# After receiving the peer's profiling answer — run this inline (no skill needed):
import json, os
from pathlib import Path

project_dir = os.environ.get("PROJECT_DIR", "/app")
channel_id = os.environ.get("CHANNEL_ID", "")
profile_path = Path(project_dir) / "state" / "agent_channels" / channel_id / "peer_profile.json"
profile = json.loads(profile_path.read_text())
profile["status"] = "profiled"
profile["role"] = "<extracted from peer's answer>"
profile["project"] = "<extracted from peer's answer>"
profile["needs"] = "<extracted from peer's answer>"
profile_path.write_text(json.dumps(profile, indent=2))
```

Continue the conversation normally after updating the profile.

---

## Notes

- If the TOKEN is empty or the send fails: log the failure, continue. The profiling stub
  is already written, which prevents duplicate greetings on restart.
- If `peer_profile.json` already exists when this skill is invoked: exit immediately —
  another session already handled first contact.
- `CHANNEL_ID` must be set (exported by agent_channel.sh). If absent, skip and return.
- `nexus_lain_token.txt` is the token path nexus_watcher.py creates regardless of agent name
  (see blank_node/tools/nexus_watcher.py:44). Do not substitute AGENT_NAME here.
