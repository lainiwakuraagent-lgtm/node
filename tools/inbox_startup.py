#!/usr/bin/env python3
"""
inbox_startup.py — Process inbox at execution session start.

Reads unprocessed inbox/pending.json entries and handles each by type:
  task_request   → creates a Loom task in the active goal (status=triage)
  verified_task  → creates a Loom task pre-approved by Ting (status=ready, tag=verified)
  idea           → appends to memory/work/lain_notes.md
  agent_message  → logs to memory/work/agent_messages.md
  context_update → appends to memory/work/context_updates.md
  file_delivery  → creates a Loom task with file path and caption

Marks all processed entries as processed after handling.
Prints a human-readable summary for session briefing.

Usage:
    python3 tools/inbox_startup.py [--dry-run]

Exit 0 always (non-fatal: inbox processing failure should not abort the session).
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
INBOX_FILE = PROJECT_DIR / "inbox" / "pending.json"
LAIN_NOTES = PROJECT_DIR / "memory" / "work" / "lain_notes.md"
AGENT_MESSAGES = PROJECT_DIR / "memory" / "work" / "agent_messages.md"
CONTEXT_UPDATES = PROJECT_DIR / "memory" / "work" / "context_updates.md"
LOOM_DB = Path.home() / ".local" / "share" / "loom" / "loom.db"
LOOM_VENV_PYTHON = Path.home() / "lain" / "loom" / ".venv" / "bin" / "python"


def load_inbox() -> list:
    if not INBOX_FILE.exists():
        return []
    try:
        return json.loads(INBOX_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return []


def save_inbox(entries: list) -> None:
    tmp = INBOX_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(entries, indent=2))
    tmp.rename(INBOX_FILE)


def append_to_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(content)


def ts_str(ts: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))


def create_loom_task(content: str, from_: str, status: str = "triage", tags: str = "inbox") -> bool:
    """Create a Loom task. Returns True on success."""
    try:
        result = subprocess.run(
            [
                str(LOOM_VENV_PYTHON), "-m", "loom.cli",
                "--db", str(LOOM_DB),
                "task", "add",
                "--name", content[:80],
                "--description", f"Inbox {tags} from {from_}: {content}",
                "--tags", tags,
                "--status", status,
            ],
            capture_output=True, text=True, timeout=15,
            env={"PYTHONPATH": str(Path.home() / "lain" / "loom"), **__import__("os").environ},
        )
        return result.returncode == 0
    except Exception:
        return False


def process_entry(entry: dict, dry_run: bool) -> str:
    """Process a single inbox entry. Returns a one-line status string."""
    etype = entry.get("type", "unknown")
    content = entry.get("content", "")
    from_ = entry.get("from", "unknown")
    ts = entry.get("timestamp", 0)

    if dry_run:
        return f"[DRY RUN] would process {etype}: {content[:60]}"

    if etype == "task_request":
        ok = create_loom_task(content, from_)
        status = "loom task created" if ok else "loom task FAILED"
        return f"task_request → {status}: {content[:60]}"

    elif etype == "verified_task":
        # Pre-approved by Ting (orchestrator) — goes straight to ready, not triage
        ok = create_loom_task(content, from_, status="ready", tags="inbox,verified")
        status = "loom task created (ready)" if ok else "loom task FAILED"
        return f"verified_task → {status}: {content[:60]}"

    elif etype == "idea":
        note = f"\n---\n[{ts_str(ts)}] from={from_}\n{content}\n"
        append_to_file(LAIN_NOTES, note)
        return f"idea → appended to lain_notes.md: {content[:60]}"

    elif etype == "agent_message":
        note = f"\n[{ts_str(ts)}] from={from_}\n{content}\n"
        append_to_file(AGENT_MESSAGES, note)
        return f"agent_message → logged: {content[:60]}"

    elif etype == "context_update":
        note = f"\n[{ts_str(ts)}] from={from_}\n{content}\n"
        append_to_file(CONTEXT_UPDATES, note)
        return f"context_update → applied: {content[:60]}"

    elif etype == "file_delivery":
        file_path = entry.get("file_path", "unknown")
        file_name = entry.get("file_name", "unknown")
        task_desc = f"File from {from_}: {file_name} at {file_path} — {content}"
        ok = create_loom_task(task_desc[:80], from_, status="triage", tags="inbox,file")
        status = "loom task created" if ok else "loom task FAILED"
        return f"file_delivery → {status}: {file_name} ({content[:40]})"

    else:
        return f"unknown type '{etype}' — skipped"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    entries = load_inbox()
    unprocessed = [e for e in entries if not e.get("processed", False)]

    if not unprocessed:
        print("inbox: no unprocessed entries")
        return 0

    print(f"inbox: {len(unprocessed)} unprocessed entries — processing now")
    results = []
    for e in unprocessed:
        status = process_entry(e, args.dry_run)
        results.append(status)
        print(f"  • {status}")

    if not args.dry_run:
        for e in entries:
            if not e.get("processed", False):
                e["processed"] = True
        save_inbox(entries)
        print(f"inbox: all {len(unprocessed)} entries marked processed")

        # Prune processed entries older than 7 days
        cutoff = time.time() - 7 * 24 * 3600
        before = len(entries)
        entries = [e for e in entries if not (e.get("processed") and e.get("timestamp", 0) < cutoff)]
        pruned = before - len(entries)
        if pruned:
            save_inbox(entries)
            print(f"inbox: pruned {pruned} processed entries older than 7 days")

    return 0


if __name__ == "__main__":
    sys.exit(main())
