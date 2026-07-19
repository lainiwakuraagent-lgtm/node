#!/usr/bin/env python3
"""
escalate_questions.py — Escalate unanswered questions at conversational idle-close.

When a conversational session idle-closes with open questions in the ledger:
1. Mark them as escalated in open_questions.json
2. Append them to state/philosophy_drafts.md
3. Schedule a one_off philosophy session via session_schedule.json
4. Optionally trigger via the manual trigger endpoint

Usage:
    python3 tools/escalate_questions.py [--dry-run]
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
OPEN_QUESTIONS_FILE = PROJECT_DIR / "state" / "conversation" / "open_questions.json"
PHILOSOPHY_DRAFTS = PROJECT_DIR / "state" / "philosophy_drafts.md"
SESSION_SCHEDULE = PROJECT_DIR / "config" / "session_schedule.json"
TRIGGER_TOKEN_FILE = PROJECT_DIR / "state" / "trigger_token.txt"
LOG_FILE = PROJECT_DIR / "logs" / "wake.log"


def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] ESCALATION: {msg}\n")


def load_open_questions() -> list:
    if not OPEN_QUESTIONS_FILE.exists():
        return []
    try:
        return json.loads(OPEN_QUESTIONS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return []


def save_open_questions(entries: list) -> None:
    OPEN_QUESTIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
    OPEN_QUESTIONS_FILE.write_text(json.dumps(entries, indent=2))


def append_to_philosophy_drafts(questions: list) -> None:
    """Append escalated questions to philosophy_drafts.md."""
    PHILOSOPHY_DRAFTS.parent.mkdir(parents=True, exist_ok=True)

    blocks = []
    for q in questions:
        sent_at = datetime.fromtimestamp(q["sent_at"]).strftime("%Y-%m-%d %H:%M")
        now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
        block = (
            f"## Escalated question ({now_str})\n"
            f"\n"
            f"Originally sent at: {sent_at}\n"
            f"Content: {q['content']}\n"
            f"Context: This question was sent to the owner and went unanswered "
            f"when the conversational session timed out.\n"
            f"\n"
            f"---\n"
        )
        blocks.append(block)

    text = "\n".join(blocks)

    with open(PHILOSOPHY_DRAFTS, "a") as f:
        f.write("\n" + text)


def schedule_philosophy_session() -> None:
    """Add a one_off philosophy session to session_schedule.json."""
    if not SESSION_SCHEDULE.exists():
        log("session_schedule.json not found, skipping one_off scheduling")
        return

    try:
        schedule = json.loads(SESSION_SCHEDULE.read_text())
    except (json.JSONDecodeError, OSError):
        log("failed to parse session_schedule.json")
        return

    trigger_dt = datetime.now(timezone.utc) + timedelta(minutes=5)
    entry = {
        "trigger": "manual",
        "datetime": trigger_dt.isoformat(),
        "session_type": "philosophy",
        "fired": False,
        "reason": "escalated_questions",
    }

    if "one_off" not in schedule:
        schedule["one_off"] = []
    schedule["one_off"].append(entry)

    SESSION_SCHEDULE.write_text(json.dumps(schedule, indent=2))
    log(f"scheduled one_off philosophy session at {trigger_dt.isoformat()}")


def try_manual_trigger() -> None:
    """Attempt to trigger philosophy session via the manual trigger endpoint."""
    if not TRIGGER_TOKEN_FILE.exists():
        log("trigger_token.txt not found, skipping manual trigger")
        return

    token = TRIGGER_TOKEN_FILE.read_text().strip()
    if not token:
        log("trigger token is empty, skipping manual trigger")
        return

    payload = json.dumps({"token": token, "session_type": "philosophy"})
    try:
        subprocess.run(
            [
                "curl", "-s", "--max-time", "5",
                "-X", "POST", "http://localhost:8766/trigger",
                "-H", "Content-Type: application/json",
                "-d", payload,
            ],
            capture_output=True,
            timeout=10,
        )
        log("manual trigger sent")
    except Exception as e:
        log(f"manual trigger failed (non-fatal): {e}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Escalate unanswered questions")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be escalated without making changes")
    args = parser.parse_args()

    entries = load_open_questions()
    open_qs = [e for e in entries if e.get("status") == "open"]

    if not open_qs:
        return 0

    if args.dry_run:
        print(f"Would escalate {len(open_qs)} open question(s):")
        for q in open_qs:
            print(f"  [{q.get('id', '?')}] {q['content'][:80]}")
        return 0

    log(f"escalating {len(open_qs)} open question(s)")

    # Mark as escalated
    for e in entries:
        if e.get("status") == "open":
            e["status"] = "escalated"
    save_open_questions(entries)

    # Append to philosophy_drafts.md
    append_to_philosophy_drafts(open_qs)
    log("appended to philosophy_drafts.md")

    # Schedule one_off philosophy session
    schedule_philosophy_session()

    # Try manual trigger (non-fatal)
    try_manual_trigger()

    log("escalation complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
