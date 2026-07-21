#!/usr/bin/env python3
"""outbox_drain.py — Independent drain for state/conversation/outbox.json.
Routes pending entries via delivery_routing.json on a systemd timer.
Usage: python3 tools/outbox_drain.py [--dry-run]
"""
import argparse, json, os, subprocess, sys, time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
OUTBOX_FILE = PROJECT_DIR / "state" / "conversation" / "outbox.json"
ROUTING_FILE = PROJECT_DIR / "state" / "delivery_routing.json"
WAKE_LOG = PROJECT_DIR / "logs" / "wake.log"


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] outbox_drain: {msg}"
    print(line, file=sys.stderr)
    try:
        WAKE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(WAKE_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_routing() -> dict:
    if not ROUTING_FILE.exists():
        log(f"routing file missing: {ROUTING_FILE}")
        return {}
    try:
        return json.loads(ROUTING_FILE.read_text())
    except (json.JSONDecodeError, OSError) as e:
        log(f"routing load error: {e}")
        return {}


def send_telegram(chat_id: str, content: str) -> bool:
    try:
        env = {**os.environ, "SKIP_TTS": "1", "TELEGRAM_CHAT_ID": chat_id}
        proc = subprocess.run(
            ["bash", str(SCRIPT_DIR / "telegram_send.sh")],
            input=content, text=True, capture_output=True, timeout=35, env=env,
        )
        if proc.returncode != 0:
            log(f"telegram send failed (rc={proc.returncode}): {proc.stderr[:200]}")
            return False
        return True
    except Exception as e:
        log(f"telegram send error: {e}")
        return False


def drain(dry_run: bool = False) -> int:
    if not OUTBOX_FILE.exists():
        return 0
    try:
        entries = json.loads(OUTBOX_FILE.read_text())
    except (json.JSONDecodeError, OSError) as e:
        log(f"outbox load error: {e}")
        return 0

    routing = load_routing()
    if not routing:
        return 0

    sent_count, changed = 0, False
    for entry in entries:
        if entry.get("sent"):
            continue
        content = entry.get("content", "").strip()
        if not content:
            entry["sent"] = True; changed = True; continue

        msg_type = entry.get("type", "message")
        to = entry.get("to", "owner")
        route_key = to if to in routing else "owner"
        route = routing.get(route_key)
        if not route:
            log(f"no route for '{to}' (and no owner fallback)"); continue

        channel = route.get("channel", "")
        if msg_type == "question":
            content = f"Question for you:\n{content}" if channel == "telegram" else f"[question] {content}"

        entry_id = entry.get("id", "?")
        if dry_run:
            log(f"[DRY-RUN] would send {entry_id} -> {route_key} via {channel}")
            sent_count += 1; continue

        sender_fn = SENDERS.get(channel)
        if not sender_fn:
            log(f"unknown channel '{channel}' for route '{route_key}'"); continue
        if sender_fn(route, content):
            entry["sent"] = True; changed = True; sent_count += 1
            log(f"sent {entry_id} -> {route_key} via {channel}")

    if changed:
        try:
            OUTBOX_FILE.write_text(json.dumps(entries, indent=2))
        except OSError as e:
            log(f"outbox write error: {e}")
    return sent_count


def main() -> int:
    parser = argparse.ArgumentParser(description="Drain outbox")
    parser.add_argument("--dry-run", action="store_true", help="Log without sending")
    args = parser.parse_args()

    pending = 0
    if OUTBOX_FILE.exists():
        try:
            entries = json.loads(OUTBOX_FILE.read_text())
            pending = sum(1 for e in entries if not e.get("sent"))
        except (json.JSONDecodeError, OSError):
            pass
    if pending == 0:
        return 0

    log(f"starting drain -- {pending} pending")
    sent = drain(dry_run=args.dry_run)
    if sent:
        log(f"drain complete -- sent {sent}/{pending}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
