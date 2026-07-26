#!/usr/bin/env python3
"""nexus_watcher.py — Persistent Nexus channel watcher for @Lain.

Runs as an always-on process (no Claude). Responsibilities:
  1. Poll tracked Nexus channels every 30s for new messages
  2. Drain state/nexus_watcher_queue.json for nexus_send entries
  3. Track per-channel session state in state/nexus_watcher_state.json
  4. Enforce initiation_timer (10min) and conversation_timer (5min) timeouts
  5. Publish status changes to lain-status Nexus channel
  6. Spawn conversation.service when inbound message arrives on idle channel

Usage:
  python3 tools/nexus_watcher.py [--dry-run] [--once]

  --dry-run: log actions without spawning sessions or sending messages
  --once:    run one poll cycle then exit (for testing)

State files:
  state/nexus_watcher.pid           — this process's PID
  state/nexus_watcher_state.json    — per-channel state tracking
  state/nexus_watcher_queue.json    — pending nexus_send entries (from outbox_drain.py)
  state/nexus_lain_token.txt        — JWT token (refreshed by wake.sh each session)
  state/nexus_last_read.json        — per-channel last-read message ID (shared with check_nexus.sh)
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent

PID_FILE = PROJECT_DIR / "state" / "nexus_watcher.pid"
STATE_FILE = PROJECT_DIR / "state" / "nexus_watcher_state.json"
QUEUE_FILE = PROJECT_DIR / "state" / "nexus_watcher_queue.json"
LAST_READ_FILE = PROJECT_DIR / "state" / "nexus_last_read.json"
TOKEN_FILE = PROJECT_DIR / "state" / "nexus_lain_token.txt"
WAKE_LOG = PROJECT_DIR / "logs" / "wake.log"
CONV_LOCK = PROJECT_DIR / "state" / "conversation.lock"
PASS_FILE = PROJECT_DIR / "identity" / "nexus_seed_passwords.txt"

NEXUS_URL = os.environ.get("NEXUS_URL", "http://100.110.36.84:8900")
NEXUS_USERNAME = os.environ.get("NEXUS_USERNAME", "lain")

POLL_INTERVAL = 30  # seconds
INITIATION_TIMEOUT = 600   # 10 minutes
CONVERSATION_TIMEOUT = 300  # 5 minutes

# Per-channel channel state keys
IDLE = "idle"
AWAITING_REPLY = "awaiting_reply"
IN_CONVERSATION = "in_conversation"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] nexus_watcher: {msg}"
    print(line, file=sys.stderr)
    try:
        with open(WAKE_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Nexus API helpers
# ---------------------------------------------------------------------------

def _load_token() -> str:
    """Load JWT from file; re-authenticate if missing or stale."""
    if TOKEN_FILE.exists():
        tok = TOKEN_FILE.read_text().strip()
        if tok:
            return tok
    return _authenticate()


def _authenticate() -> str:
    """Get a fresh JWT token from Nexus."""
    password = os.environ.get("NEXUS_PASSWORD", "")
    if not password and PASS_FILE.exists():
        for line in PASS_FILE.read_text().splitlines():
            if line.startswith(f"# {NEXUS_USERNAME}"):
                password = line.split()[-1]
                break
    if not password:
        log("no Nexus password — cannot authenticate")
        return ""
    try:
        body = json.dumps({"username": NEXUS_USERNAME, "password": password}).encode()
        req = urllib.request.Request(
            f"{NEXUS_URL}/auth/token", data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            token = data.get("access_token", "")
            if token and TOKEN_FILE.parent.exists():
                TOKEN_FILE.write_text(token)
            return token
    except Exception as e:
        log(f"auth error: {e}")
        return ""


def nexus_get(path: str, token: str) -> dict | list | None:
    """GET from Nexus API. Returns parsed JSON or None on error."""
    try:
        req = urllib.request.Request(
            f"{NEXUS_URL}{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return None  # token expired — caller handles re-auth
        log(f"nexus GET {path} error {e.code}: {e.reason}")
        return None
    except Exception as e:
        log(f"nexus GET {path} error: {e}")
        return None


def nexus_post(path: str, body: dict, token: str) -> bool:
    """POST to Nexus API. Returns True on success."""
    try:
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            f"{NEXUS_URL}{path}", data=data,
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json",
                     "Accept": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        return True
    except Exception as e:
        log(f"nexus POST {path} error: {e}")
        return False


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def save_state(state: dict) -> None:
    try:
        STATE_FILE.write_text(json.dumps(state, indent=2))
    except OSError as e:
        log(f"state save error: {e}")


def channel_state(state: dict, channel_id: str) -> dict:
    if channel_id not in state:
        state[channel_id] = {
            "state": IDLE,
            "last_activity": None,
            "active_session_pid": None,
            "initiation_timer_start": None,
            "conversation_timer_last_reset": None,
        }
    return state[channel_id]


def load_last_read() -> dict:
    if LAST_READ_FILE.exists():
        try:
            return json.loads(LAST_READ_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def save_last_read(data: dict) -> None:
    try:
        LAST_READ_FILE.write_text(json.dumps(data, indent=2))
    except OSError as e:
        log(f"last_read save error: {e}")


# ---------------------------------------------------------------------------
# Session management
# ---------------------------------------------------------------------------

def is_conversation_active() -> bool:
    """True if conversation.service is running and not in idle_close shutdown."""
    if not CONV_LOCK.exists():
        return False
    try:
        pid = int(CONV_LOCK.read_text().strip())
        os.kill(pid, 0)
        # PID alive — check if it's in idle_close wind-down
        exit_reason_file = PROJECT_DIR / "state" / "conversation" / "exit_reason.txt"
        if exit_reason_file.exists():
            reason = exit_reason_file.read_text().strip()
            if reason == "idle_close":
                return False  # slow shutdown, treat as inactive
        return True
    except (OSError, ValueError):
        return False


def spawn_conversation(dry_run: bool = False) -> bool:
    """Start conversation.service via systemd."""
    if dry_run:
        log("[DRY-RUN] would start conversation.service")
        return True
    try:
        env = {**os.environ, "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}"}
        result = subprocess.run(
            ["systemctl", "--user", "is-active", "conversation.service"],
            capture_output=True, text=True, env=env, timeout=5,
        )
        if result.stdout.strip() == "active":
            log("conversation.service already active — skipping spawn")
            return False
        subprocess.run(
            ["systemctl", "--user", "start", "conversation.service"],
            env=env, timeout=15, check=True,
        )
        log("conversation.service started")
        return True
    except subprocess.CalledProcessError as e:
        log(f"failed to start conversation.service: {e}")
        return False
    except Exception as e:
        log(f"spawn error: {e}")
        return False


# ---------------------------------------------------------------------------
# Status publishing
# ---------------------------------------------------------------------------

def publish_status(status: str, token: str, lain_status_channel: str | None) -> None:
    """Publish free/busy status to lain-status Nexus channel."""
    if not lain_status_channel:
        return
    body = {"content": json.dumps({
        "agent": "lain",
        "status": status,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })}
    nexus_post(f"/conversations/{lain_status_channel}/messages", body, token)


# ---------------------------------------------------------------------------
# Queue drain (nexus_send entries from outbox_drain.py)
# ---------------------------------------------------------------------------

def drain_watcher_queue(token: str, state: dict, dry_run: bool = False) -> None:
    if not QUEUE_FILE.exists():
        return
    try:
        entries = json.loads(QUEUE_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return

    changed = False
    now = datetime.now(timezone.utc).isoformat()
    for entry in entries:
        if entry.get("sent"):
            continue
        channel_id = entry.get("channel_id") or entry.get("channel")
        content = entry.get("content", "").strip()
        if not content or not channel_id:
            entry["sent"] = True
            changed = True
            continue

        if dry_run:
            log(f"[DRY-RUN] would send nexus_send to channel {channel_id}: {content[:60]}")
            entry["sent"] = True
            changed = True
            continue

        ok = nexus_post(f"/conversations/{channel_id}/messages", {"content": content}, token)
        if ok:
            entry["sent"] = True
            changed = True
            log(f"nexus_send sent to {channel_id}")
            ch = channel_state(state, channel_id)
            if entry.get("expects_reply", False):
                ch["state"] = AWAITING_REPLY
                ch["initiation_timer_start"] = now
                ch["last_activity"] = now
            else:
                ch["last_activity"] = now

    if changed:
        try:
            QUEUE_FILE.write_text(json.dumps(entries, indent=2))
        except OSError as e:
            log(f"queue write error: {e}")


# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

def poll_once(token: str, state: dict, dry_run: bool = False) -> str:
    """
    One poll iteration. Returns the token (possibly refreshed).
    """
    last_read = load_last_read()
    now_iso = datetime.now(timezone.utc).isoformat()
    now_dt = datetime.now(timezone.utc)

    # Drain outbound queue first
    drain_watcher_queue(token, state, dry_run=dry_run)

    # Poll each tracked conversation
    for channel_id, last_msg_id in last_read.items():
        result = nexus_get(f"/conversations/{channel_id}/messages?limit=50", token)
        if result is None:
            # Might be 401 — try re-auth once
            new_token = _authenticate()
            if new_token:
                token = new_token
                result = nexus_get(f"/conversations/{channel_id}/messages?limit=50", token)
        if not result:
            continue

        messages = result if isinstance(result, list) else result.get("messages", [])
        if not messages:
            continue

        # Messages newest-first. Find new ones (after last_msg_id)
        new_msgs = []
        if last_msg_id:
            seen_last = False
            for m in reversed(messages):  # oldest-first
                if seen_last:
                    new_msgs.append(m)
                elif m.get("id") == last_msg_id:
                    seen_last = True
        else:
            new_msgs = list(reversed(messages))  # all messages, oldest-first

        if new_msgs:
            ch = channel_state(state, channel_id)
            ch["last_activity"] = now_iso
            ch["conversation_timer_last_reset"] = now_iso
            last_read[channel_id] = messages[0]["id"]  # newest message

            log(f"channel {channel_id}: {len(new_msgs)} new message(s), state={ch['state']}")

            # Spawn session if channel is idle or awaiting_reply
            if ch["state"] in (IDLE, AWAITING_REPLY):
                if not is_conversation_active():
                    log(f"channel {channel_id}: spawning conversation session")
                    if spawn_conversation(dry_run=dry_run):
                        ch["state"] = IN_CONVERSATION
                        ch["initiation_timer_start"] = now_iso
                else:
                    log(f"channel {channel_id}: conversation already active, not spawning")

    save_last_read(last_read)

    # Timeout enforcement
    for channel_id, ch in state.items():
        ch_state = ch.get("state", IDLE)

        if ch_state == AWAITING_REPLY and ch.get("initiation_timer_start"):
            elapsed = (now_dt - datetime.fromisoformat(ch["initiation_timer_start"])).total_seconds()
            if elapsed > INITIATION_TIMEOUT:
                log(f"channel {channel_id}: initiation_timer expired ({elapsed:.0f}s) — logging misaligned_start, resetting to idle")
                ch["state"] = IDLE
                ch["initiation_timer_start"] = None
                _log_analytics_event("misaligned_start", channel_id)

        if ch_state == IN_CONVERSATION:
            last_reset = ch.get("conversation_timer_last_reset")
            if last_reset:
                elapsed = (now_dt - datetime.fromisoformat(last_reset)).total_seconds()
                if elapsed > CONVERSATION_TIMEOUT and not is_conversation_active():
                    log(f"channel {channel_id}: conversation_timer expired, no active session — resetting to idle")
                    ch["state"] = IDLE
                    ch["conversation_timer_last_reset"] = None

    return token


def _log_analytics_event(event_type: str, channel_id: str) -> None:
    """Write an event to wake.log for analytics pickup."""
    log(f"ANALYTICS_EVENT type={event_type} channel={channel_id}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Nexus channel watcher")
    parser.add_argument("--dry-run", action="store_true", help="Log only, no side effects")
    parser.add_argument("--once", action="store_true", help="Run one poll cycle then exit")
    args = parser.parse_args()

    # Write PID file
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))

    def cleanup(signum=None, frame=None):
        PID_FILE.unlink(missing_ok=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    log(f"starting (PID {os.getpid()}, dry_run={args.dry_run})")

    token = _load_token()
    if not token:
        token = _authenticate()
    if not token:
        log("cannot authenticate — exiting")
        PID_FILE.unlink(missing_ok=True)
        sys.exit(1)

    state = load_state()

    try:
        if args.once:
            token = poll_once(token, state, dry_run=args.dry_run)
            save_state(state)
            log("--once: done")
            return

        while True:
            try:
                token = poll_once(token, state, dry_run=args.dry_run)
                save_state(state)
            except Exception as e:
                log(f"poll error (continuing): {e}")
            time.sleep(POLL_INTERVAL)
    finally:
        PID_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
