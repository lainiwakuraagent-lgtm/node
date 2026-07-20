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
CHECKPOINT_FILE = PROJECT_DIR / "state" / "conversation" / "checkpoint.json"
LAST_CHECKPOINT_FILE = PROJECT_DIR / "state" / "last_checkpoint_read.txt"
OUTBOX_FILE = PROJECT_DIR / "state" / "conversation" / "outbox.json"
LOOM_CONTEXT_FILE = PROJECT_DIR / "state" / "loom_context.json"
QUEUE_NOTIFY_TS_FILE = PROJECT_DIR / "state" / "queue_empty_notify_last.txt"
QUEUE_NOTIFY_DISABLED = PROJECT_DIR / "state" / "queue_empty_notify.disabled"
CONV_LOCK_FILE = PROJECT_DIR / "state" / "conversation.lock"
SESSION_SCHEDULE_FILE = PROJECT_DIR / "config" / "session_schedule.json"
MAINTENANCE_DECISIONS = PROJECT_DIR / "logs" / "maintenance_decisions.md"


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


def normalize_ts(ts) -> float:
    """Convert timestamp (int/float/ISO string) to Unix float. Returns 0.0 on failure."""
    if isinstance(ts, (int, float)):
        return float(ts)
    if isinstance(ts, str):
        try:
            from datetime import datetime, timezone
            dt = datetime.fromisoformat(ts)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except (ValueError, AttributeError):
            pass
    return 0.0


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


def extract_checkpoint_directives(dry_run: bool) -> list:
    """
    Read state/conversation/checkpoint.json and inject any owner directives
    as a context_update entry into inbox/pending.json.

    Uses state/last_checkpoint_read.txt to avoid reprocessing the same checkpoint.
    Returns a list of status strings for logging.
    """
    if not CHECKPOINT_FILE.exists():
        return []

    try:
        data = json.loads(CHECKPOINT_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return ["checkpoint: read error — skipped"]

    checkpoint_ts = data.get("timestamp", "")
    if not checkpoint_ts:
        return []

    # Skip if we've already processed this checkpoint
    if LAST_CHECKPOINT_FILE.exists():
        if LAST_CHECKPOINT_FILE.read_text().strip() == checkpoint_ts:
            return []

    summary = data.get("summary", "")
    user_msgs = [
        m["text"] for m in data.get("last_messages", [])
        if m.get("role") == "user" and m.get("text")
    ]

    if not summary and not user_msgs:
        return []

    content_parts = []
    if summary:
        content_parts.append(f"Checkpoint summary: {summary}")
    for msg in user_msgs:
        content_parts.append(f"Owner directive: {msg}")

    content = "\n".join(content_parts)

    if dry_run:
        return [f"[DRY RUN] checkpoint directive: {content[:80]}"]

    entry = {
        "type": "context_update",
        "from": "owner_checkpoint",
        "content": content,
        "timestamp": int(time.time()),
        "processed": False,
    }
    entries = load_inbox()
    entries.append(entry)
    save_inbox(entries)

    LAST_CHECKPOINT_FILE.write_text(checkpoint_ts)
    return [f"checkpoint: directive injected — {content[:80]}"]


def handle_schedule_directive(entry: dict, dry_run: bool) -> str:
    """
    Apply a schedule_directive inbox entry to config/session_schedule.json.

    Supported actions:
      adjust_triggers    — replace trigger list in a named window
      set_window_enabled — enable or disable a window
      add_window         — add a new window entry
      remove_window      — remove a window by label
      set_type_hint      — set session_type_hint on a window
    """
    action = entry.get("action", "")
    payload = entry.get("payload", {})
    reason = entry.get("reason", "")
    source = entry.get("source", "unknown")
    week = entry.get("week_starting", "?")

    if dry_run:
        return f"[DRY RUN] schedule_directive action={action} payload={payload}"

    # Load current schedule
    try:
        sched = json.loads(SESSION_SCHEDULE_FILE.read_text())
    except (OSError, json.JSONDecodeError) as e:
        return f"schedule_directive → FAILED: could not read session_schedule.json: {e}"

    windows = sched.get("windows", [])
    label = payload.get("window_label", "")
    window = next((w for w in windows if w.get("label") == label), None)

    applied = False
    detail = ""

    if action == "adjust_triggers":
        new_triggers = payload.get("new_triggers", [])
        if window is None:
            return f"schedule_directive → FAILED: window '{label}' not found"
        old_triggers = window.get("triggers", [])
        window["triggers"] = new_triggers
        applied = True
        detail = f"triggers {old_triggers} → {new_triggers}"

    elif action == "set_window_enabled":
        enabled = payload.get("enabled", True)
        if window is None:
            return f"schedule_directive → FAILED: window '{label}' not found"
        window["enabled"] = enabled
        applied = True
        detail = f"enabled={enabled}"

    elif action == "add_window":
        if window is not None:
            return f"schedule_directive → FAILED: window '{label}' already exists"
        new_window = {
            "label": label,
            "type": payload.get("type", "work"),
            "enabled": payload.get("enabled", True),
            "start": payload.get("start", "00:00"),
            "end": payload.get("end", "08:00"),
            "triggers": payload.get("triggers", []),
        }
        if "session_type_hint" in payload:
            new_window["session_type_hint"] = payload["session_type_hint"]
        windows.append(new_window)
        sched["windows"] = windows
        applied = True
        detail = f"added window {label} {new_window['start']}-{new_window['end']}"

    elif action == "remove_window":
        if window is None:
            return f"schedule_directive → FAILED: window '{label}' not found"
        windows = [w for w in windows if w.get("label") != label]
        sched["windows"] = windows
        applied = True
        detail = f"removed window '{label}'"

    elif action == "set_type_hint":
        hint = payload.get("session_type_hint", "")
        if window is None:
            return f"schedule_directive → FAILED: window '{label}' not found"
        window["session_type_hint"] = hint
        applied = True
        detail = f"session_type_hint='{hint}'"

    else:
        return f"schedule_directive → unknown action '{action}'"

    if not applied:
        return f"schedule_directive → no change applied"

    # Atomic write
    tmp = SESSION_SCHEDULE_FILE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(sched, indent=2))
        tmp.rename(SESSION_SCHEDULE_FILE)
    except OSError as e:
        return f"schedule_directive → FAILED: write error: {e}"

    # Log to maintenance_decisions.md
    ts_now = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    log_entry = (
        f"\n## {ts_now} — schedule_directive (from={source}, week={week})\n"
        f"action: {action} | {detail}\n"
        f"reason: {reason}\n"
    )
    try:
        MAINTENANCE_DECISIONS.parent.mkdir(parents=True, exist_ok=True)
        with MAINTENANCE_DECISIONS.open("a") as f:
            f.write(log_entry)
    except OSError:
        pass  # Non-fatal

    return f"schedule_directive → applied: {action} {detail}"


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

    elif etype == "task_comment":
        task_id = entry.get("task_id")
        text_content = entry.get("text") or content
        if not task_id or not text_content:
            return f"task_comment → skipped: missing task_id or text"
        try:
            import sqlite3 as _sqlite3
            import datetime as _dt
            conn = _sqlite3.connect(str(LOOM_DB))
            now = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            conn.execute(
                "INSERT INTO task_events (task_id, event_type, new_value, changed_at) VALUES (?, 'comment', ?, ?)",
                (task_id, text_content, now),
            )
            conn.commit()
            conn.close()
            return f"task_comment → comment logged on T{task_id}: {text_content[:60]}"
        except Exception as e:
            return f"task_comment → DB error ({e}): task={task_id}"

    elif etype in ("sop_comment", "sop_change"):
        sop_id = entry.get("sop_id", entry.get("path", "?"))
        return f"{etype} → acknowledged: sop={sop_id} from={from_}: {content[:60]}"

    elif etype == "schedule_directive":
        return handle_schedule_directive(entry, dry_run)

    elif etype == "sop_request":
        title = entry.get("title", "untitled SOP")
        instructions = entry.get("content", "")
        task_name = f"Write SOP: {title}"
        task_desc = f"SOP request from {from_}: {instructions}"
        ok = create_loom_task(task_name[:80], from_, status="scheduled", tags="sop")
        if ok:
            # Wire to goal 1 (self-improvement tooling)
            try:
                import sqlite3 as _sqlite3
                conn = _sqlite3.connect(str(LOOM_DB))
                conn.execute(
                    "UPDATE tasks SET goal_id=1 WHERE id=(SELECT MAX(id) FROM tasks WHERE tags='sop')"
                )
                conn.commit()
                conn.close()
            except Exception:
                pass
        status_str = "loom task created (scheduled, goal 1)" if ok else "loom task FAILED"
        return f"sop_request → {status_str}: {title[:60]}"

    else:
        return f"unknown type '{etype}' — skipped"


def notify_queue_empty_if_needed() -> str | None:
    """
    If the Loom queue is empty and no conversation is active, write a
    notification to outbox so Andrii knows to dispatch new work.
    Rate-limited to once per 2 hours. Disabled by state/queue_empty_notify.disabled.
    Returns a status string (for logging) or None if nothing was done.
    """
    if QUEUE_NOTIFY_DISABLED.exists():
        return None

    # Check conversation.lock — if conversation is active, owner is present; skip
    try:
        if CONV_LOCK_FILE.exists():
            pid = int(CONV_LOCK_FILE.read_text().strip())
            import os as _os
            _os.kill(pid, 0)
            return None  # conversation active — owner can ask directly
    except (ValueError, ProcessLookupError, OSError):
        pass

    # Only fire for execution sessions
    session_type = (PROJECT_DIR / "state" / "current_session_type.txt")
    if not session_type.exists() or session_type.read_text().strip() != "execution":
        return None

    # Check loom_context for empty queue
    if not LOOM_CONTEXT_FILE.exists():
        return None
    try:
        ctx = json.loads(LOOM_CONTEXT_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return None

    ready = ctx.get("ready_queue") or []
    current = ctx.get("current_task")
    if ready or current:
        return None  # queue is not empty

    # Rate limit: no more than once per 2 hours
    now = time.time()
    if QUEUE_NOTIFY_TS_FILE.exists():
        try:
            last_ts = float(QUEUE_NOTIFY_TS_FILE.read_text().strip())
            if now - last_ts < 7200:  # 2 hours
                return None
        except (ValueError, OSError):
            pass

    # Write notification to outbox
    try:
        import uuid
        OUTBOX_FILE.parent.mkdir(parents=True, exist_ok=True)
        entries = []
        if OUTBOX_FILE.exists():
            try:
                entries = json.loads(OUTBOX_FILE.read_text())
            except (json.JSONDecodeError, ValueError):
                entries = []
        entry = {
            "id": str(uuid.uuid4())[:8],
            "from": "execution_layer",
            "type": "message",
            "to": "owner",
            "content": "@Lain — queue is empty. Nothing ready to execute. Waiting for new tasks.",
            "timestamp": int(now),
            "sent": False,
        }
        entries.append(entry)
        OUTBOX_FILE.write_text(json.dumps(entries, indent=2))
        QUEUE_NOTIFY_TS_FILE.write_text(str(now))
        return "queue-empty notification written to outbox"
    except Exception as e:
        return f"queue-empty notify failed: {e}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--types",
        default=None,
        help="Comma-separated entry types to process (default: all). "
             "Example: --types agent_message,context_update",
    )
    args = parser.parse_args()

    allowed_types = set(args.types.split(",")) if args.types else None

    # Queue-empty notification (execution sessions only, when no conversation active)
    # Skip when filtering by type — this is a lightweight pre-launch pass.
    if not args.dry_run and allowed_types is None:
        notify_result = notify_queue_empty_if_needed()
        if notify_result:
            print(f"  • {notify_result}")

    # Extract any owner directives from the last conversational checkpoint.
    # Skip when filtering by type — checkpoint injection is a full-pass concern.
    if allowed_types is None:
        cp_results = extract_checkpoint_directives(args.dry_run)
        for r in cp_results:
            print(f"  • {r}")

    entries = load_inbox()
    unprocessed = [
        e for e in entries
        if not e.get("processed", False)
        and (allowed_types is None or e.get("type") in allowed_types)
    ]

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
            if not e.get("processed", False) and (
                allowed_types is None or e.get("type") in allowed_types
            ):
                e["processed"] = True
        save_inbox(entries)
        print(f"inbox: {len(unprocessed)} entries marked processed"
              + (f" (types: {args.types})" if allowed_types else ""))

        # Prune processed entries older than 7 days
        cutoff = time.time() - 7 * 24 * 3600
        before = len(entries)
        entries = [e for e in entries if not (e.get("processed") and normalize_ts(e.get("timestamp", 0)) < cutoff)]
        pruned = before - len(entries)
        if pruned:
            save_inbox(entries)
            print(f"inbox: pruned {pruned} processed entries older than 7 days")

    return 0


if __name__ == "__main__":
    sys.exit(main())
