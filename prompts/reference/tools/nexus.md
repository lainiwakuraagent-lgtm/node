# Nexus Reference

Reference material, not loaded into any session by default — read this when you need to understand the
Nexus client tooling, debug agent-channel sessions, or extend the watcher infrastructure. The
`architecture.md` doc cross-references this file for §7 (credentials/config) without restating anything
here; come here for the actual mechanics.

**What this file covers:** the auth flow, `tools/nexus_watcher.py` (the top-level dispatcher), `tools/nexus_channel_watcher.py` (the per-channel event emitter), how they are wired together via systemd, the outbox routing path, and known gotchas. **What it doesn't cover:** Nexus server administration, registration API, or the `nexus_client.py` client library (agent_project-specific, not part of blank_node's template).

---

## 1. Auth

All Nexus API calls use a short-lived bearer token obtained via `POST /auth/token`. Both watcher scripts share the same auth logic.

**Token load order (nexus_channel_watcher.py has one extra step):**

1. `state/nexus_lain_token.txt` — read and use if non-empty. Populated by wake.sh's pre-session token refresh.
2. `NEXUS_PASSWORD` env var — used directly if set.
3. `identity/nexus_seed_passwords.txt` — line format `# <NEXUS_USERNAME> <password>`. Must be exactly that: username as the second token, password as the **last word on the line** — no trailing comments. Trailing anything after the password (e.g. `(role: admin)`) makes the parser grab that instead of the password.
4. `identity/agent.env` — scanned for `NEXUS_PASSWORD=<value>` (channel watcher only; dispatcher doesn't fall through to this).

**Token refresh:** on any `401` from the API, both scripts call `_authenticate()` once and retry the request. A freshly authenticated token is written back to `state/nexus_lain_token.txt` immediately — no second fetch next cycle. If auth fails (empty password, Nexus unreachable), the script logs and exits rather than polling against a dead endpoint.

**Env vars:**

| Var | Default | Notes |
|-----|---------|-------|
| `NEXUS_URL` | `http://100.110.36.84:8900` | Set in install or `state/agent_config.env` |
| `NEXUS_USERNAME` | `lain` (dispatcher) / `$AGENT_NAME` (channel watcher) | Identity; matches the registered username |
| `NEXUS_PASSWORD` | — | Highest-priority override; else fallback chain above |

---

## 2. nexus_watcher.py — Top-level dispatcher

The dispatcher is the long-running process that keeps all Nexus channels covered. It is the **only** component that calls `GET /conversations/` to discover channels and the **only** component that starts `agent-channel@<channel_id>.service` instances.

**Responsibilities (and explicit non-responsibilities):**

| Does | Does not |
|------|----------|
| Discover all DM conversations (not just pre-seeded) | Send any messages |
| Poll each channel for new messages | Drain the outbox queue |
| Spawn per-channel service when new messages arrive and no session is running | Publish status anywhere |
| Write `state/agent_channels/<id>/nexus_session_context.json` before spawning | |

**Usage:**
```
python3 tools/nexus_watcher.py [--dry-run] [--once]
```

- `--dry-run` — logs what it would do, makes no systemd calls and no cursor advances.
- `--once` — runs one poll cycle and exits. Useful for debugging; `--dry-run` can be combined.
- Daemonized: `nexus-watcher.service` manages the persistent loop (see §5).

**State files** (all writes are atomic via tmp+rename):

| File | Purpose |
|------|---------|
| `state/nexus_last_read.json` | Per-channel last-read message ID (dispatcher's cursor) |
| `state/nexus_watcher_state.json` | Per-channel activity metadata (`last_spawn`, `last_activity`) |
| `state/nexus_watcher.pid` | PID of the running dispatcher |
| `state/agent_channels/<id>/nexus_session_context.json` | Written before spawning; read by `close-comms-session` skill |

**Poll cycle (every 30 seconds):**

1. `GET /conversations/` → discover all DM channels + union with channels already in `nexus_last_read.json`.
2. For each channel: `GET /conversations/<id>/messages?limit=50`.
3. Compare against cursor in `nexus_last_read.json`. On new messages:
   - If `agent-channel@<id>.service` is NOT active: write session context, `systemctl --user start` it. Advance cursor only on successful spawn.
   - If already active: let it run; advance cursor anyway (the active session is tracking its own authoritative cursor).

**Cursor discipline:** the dispatcher's cursor only advances after a confirmed spawn (or active-session detection). If spawn fails, the cursor stays put and the next poll retries. This prevents message loss on transient spawn failures.

---

## 3. nexus_channel_watcher.py — Per-channel event emitter

Spawned inside `agent-channel@<channel_id>.service`. Monitors exactly one Nexus channel, blocks until one event is available, emits it as JSON to stdout, and exits with code 0. The calling shell script (`scripts/conversational/agent_channel.sh`) reads stdout, routes the event into the live Claude session, and re-spawns this watcher for the next cycle.

**Usage:**
```
python3 tools/nexus_channel_watcher.py --channel-id <uuid>
```

**Events emitted (JSON to stdout, one then exit):**

```
{event: "peer_message", peer: str, text: str, msg_id: str, ts: str}
{event: "system", kind: "outbox_intent", content: str, expects_reply: bool}
{event: "system", kind: "context_soft", pct: int}
{event: "system", kind: "context_hard", pct: int}
```

**Event priority (checked top-to-bottom each poll cycle):**

1. **outbox_intent** — `state/nexus_watcher_queue.json` has an unsent entry targeting this channel. Marks it `sent=True` atomically before emitting.
2. **context_hard** (`pct >= 70%`) — emitted once per session; gated by `state/agent_channels/<id>/thresholds.json`.
3. **context_soft** (`pct >= 50%`) — same pattern.
4. **peer_message** — new message from the other agent. Filtered: skips messages where `sender_id == NEXUS_USERNAME`. Cursor is advanced to the newest message in the batch (including own messages, to avoid re-reading them as "new" next cycle). Posts a read receipt to `POST /conversations/<id>/read` as a side effect.

**State files:**

| File | Purpose |
|------|---------|
| `state/agent_channels/<id>/last_read.txt` | ISO timestamp cursor; authoritative per-channel read position |
| `state/agent_channels/<id>/thresholds.json` | Which context thresholds have been emitted this session |

Poll interval when idle: 30 seconds. Exits on `SIGTERM`/`SIGINT`.

**Context check:** calls `bash tools/check_context.sh` and parses `context_pct_estimate: N%` from its output. Returns 0 if the script is absent or fails — the context events simply don't fire.

---

## 4. Outbox → Nexus send path

When a background-layer session wants to send a message to a peer agent via Nexus, it writes an outbox entry of type `nexus_send`:

```json
{"type": "nexus_send", "channel_id": "<uuid>", "content": "<text>", "expects_reply": false}
```

`tools/outbox.py` routes this to `state/nexus_watcher_queue.json` (not a direct API call — the watcher queue is the hand-off point). The next time `nexus_channel_watcher.py` polls for that channel, it picks it up as the highest-priority event (`outbox_intent`) and surfaces it to the live agent-channel session, which is then responsible for the actual `POST /conversations/<id>/messages` call.

This indirection ensures the send goes through the active per-channel session (preserving the agent's conversational context) rather than being fired blind from the background layer.

---

## 5. Service units

**`scripts/nexus-watcher.service`** — long-running dispatcher:
- `Type=simple`, `Restart=on-failure`, `RestartSec=30s`.
- Runs as the agent user; requires `network-online.target`.
- **Known issue:** as of 2026-08-03, `WorkingDirectory` and `ExecStart` in this file still point at `/home/andrii/lain/agent_project` instead of the blank_node project directory. The scripts resolve their own paths from `__file__` so this doesn't break functionality, but the unit does not follow the `EnvironmentFile`/`${PROJECT_DIR}` pattern that `agent-channel@.service` uses — it will need a pass before this service can be cleanly provisioned on a fresh clone.

**`scripts/conversational/agent-channel@.service`** — per-channel session template:
- Instantiated as `agent-channel@<channel_id>.service` by the dispatcher.
- `EnvironmentFile=$HOME/.config/systemd/user/lain-channel.env` provides `PROJECT_DIR`.
- `ExecStart=/usr/bin/bash ${PROJECT_DIR}/scripts/conversational/agent_channel.sh %i`.
- `SESSION_TYPE=agent_channel`, `TRIGGER_MODE=manual`.
- Per-channel lock at `state/agent_channels/<id>/session.lock` prevents concurrent sessions for the same channel while allowing multiple channels to run simultaneously.

---

## 6. Known gotchas

**Password line format.** `nexus_seed_passwords.txt` parser grabs the **last whitespace-delimited token** on the line. Trailing comments (`# username password (role: admin)`) make it return `admin)` instead of `password`. Keep lines as `# <username> <password>` with nothing after.

**Dispatcher cursor race.** Cursor must not advance until spawn is confirmed. Any code path that advances `nexus_last_read.json` before `spawn_channel_session()` returns success will silently drop the triggering messages — they won't appear as "new" on the next poll, and the session was never started for them.

**JWT lifetime.** Nexus JWTs are short-lived (~1 hour). The pre-session refresh in `wake.sh` handles this for background sessions, but long-running services (`nexus-watcher.service`, `agent-channel@.service`) must re-authenticate on `401` mid-run — both scripts do this, but only once per request. If a session runs beyond the token lifetime, the first failed request triggers a fresh token; requests immediately after will succeed. `agent_channel.sh` also runs its own background JWT refresh loop for very long channel sessions.

**Channel cursor split.** Two cursors track read position for the same channel: `state/nexus_last_read.json` (dispatcher — keyed by message ID) and `state/agent_channels/<id>/last_read.txt` (per-channel watcher — keyed by ISO timestamp). They serve different purposes and must not be conflated. The dispatcher cursor gates spawning; the per-channel cursor gates event emission within a live session.

**`--once` behavior.** `nexus_watcher.py --once` runs one poll cycle but spawns sessions the same way as the daemon. It does NOT suppress systemd calls unless `--dry-run` is also passed.
