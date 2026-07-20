#!/usr/bin/env python3
"""
resolve_session_type.py
Phase 4 — Queue-State-Driven Session Type Dispatcher (v2 schedule)

Resolves the session type and assembles type-specific context (prompt injection
+ preloaded context files) for wake.sh to use.

Priority order:
  1. SESSION_TYPE env var (explicit override — always wins)
  2. WINDOW_TYPE env var (lane constraint from wake.sh):
     - work:        full queue-state logic (below)
     - maintenance: always return "maintenance"
     - reflection:  always return "reflection" (or "philosophy")
  3. Loom queue state (DB-driven algorithmic selection) — used when
     WINDOW_TYPE is "work" or unset (emergency/manual mode)
  4. default: "philosophy" (empty queue → identity/relationship session)

Queue-state rules (priority 3, within work windows):
  - desire-status goals not blocked          -> evaluation
  - needs_plan-status tasks                  -> planning
  - scheduled/in_progress tasks tagged       -> audit
    milestone_review with all deps done
  - scheduled tasks ready to execute         -> execution
  - nothing actionable (empty queue)         -> philosophy

Usage:
  python3 scripts/resolve_session_type.py \\
    --project-dir /path/to/agent_project \\
    --trigger-mode nightly \\
    --output /tmp/session_type_result.json

Output JSON:
  session_type:        resolved type id
  resolution_source:   env_var | queue_state | default
  queue_state_reason:  human-readable reason when source is queue_state (or "")
  prompt_content:      contents of the type's prompt_file (or "")
  assembled_context:   concatenated context_files (or "")
  focus_hint:          type's focus_hint text (or "")
  behavioral_overrides: dict from type YAML
  memory_discipline:   strict | normal (from behavioral_overrides)
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

LOOM_DB_PATH = Path.home() / ".local" / "share" / "loom" / "loom.db"


def parse_args():
    p = argparse.ArgumentParser(description="Resolve session type for wake.sh")
    p.add_argument("--project-dir", required=True, help="Agent project root directory")
    p.add_argument("--trigger-mode", default="nightly",
                   choices=["nightly", "emergency", "manual"],
                   help="Current trigger mode")
    p.add_argument("--output", required=True, help="Output JSON file path")
    p.add_argument("--loom-db", default=None,
                   help="Override Loom DB path (default: ~/.local/share/loom/loom.db)")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Queue-state resolution from Loom DB
# ---------------------------------------------------------------------------

def resolve_from_queue_state(db_path: Path) -> tuple:
    """
    Query the Loom DB and return (session_type, reason) based on queue state.
    Returns (None, None) if no queue-state rule matches (fall through).
    """
    if not db_path.exists():
        return None, None

    try:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
    except sqlite3.Error:
        return None, None

    try:
        result = _check_queue_state(conn)
        return result
    finally:
        conn.close()


def _check_queue_state(conn: sqlite3.Connection) -> tuple:
    """Run queue-state checks in priority order. Returns (type, reason) or (None, None)."""

    # Rule 1: desire-status goals not blocked -> evaluation
    try:
        rows = conn.execute(
            "SELECT id, name FROM goals "
            "WHERE status = 'desire' "
            "AND (blocked_reason IS NULL OR blocked_reason = '') "
            "ORDER BY priority DESC "
            "LIMIT 5"
        ).fetchall()
        if rows:
            names = ", ".join(r["name"] for r in rows[:3])
            return "evaluation", f"{len(rows)} desire-status goal(s) need evaluation: {names}"
    except sqlite3.Error:
        pass

    # Rule 2: needs_plan-status tasks -> planning
    try:
        rows = conn.execute(
            "SELECT id, name FROM tasks "
            "WHERE status = 'needs_plan' "
            "LIMIT 5"
        ).fetchall()
        if rows:
            names = ", ".join(r["name"] for r in rows[:3])
            return "planning", f"{len(rows)} task(s) need planning: {names}"
    except sqlite3.Error:
        pass

    # Rule 3: scheduled/in_progress tasks tagged milestone_review with all deps done -> audit
    try:
        rows = conn.execute(
            "SELECT id, name, depends FROM tasks "
            "WHERE status IN ('scheduled', 'in_progress') "
            "AND tags LIKE '%milestone_review%' "
            "LIMIT 10"
        ).fetchall()
        audit_candidates = []
        for row in rows:
            deps_raw = row["depends"]
            if deps_raw:
                try:
                    dep_ids = json.loads(deps_raw)
                except (json.JSONDecodeError, TypeError):
                    dep_ids = []
                if dep_ids:
                    placeholders = ",".join("?" for _ in dep_ids)
                    undone = conn.execute(
                        f"SELECT COUNT(*) FROM tasks "
                        f"WHERE id IN ({placeholders}) AND status != 'done'",
                        dep_ids
                    ).fetchone()[0]
                    if undone > 0:
                        continue  # deps not all done, skip
            audit_candidates.append(row)

        if audit_candidates:
            names = ", ".join(r["name"] for r in audit_candidates[:3])
            return "audit", f"{len(audit_candidates)} milestone_review task(s) ready for audit: {names}"
    except sqlite3.Error:
        pass

    # Rule 4: scheduled tasks ready to execute (not blocked, wait_until not in future) -> execution
    try:
        now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        rows = conn.execute(
            "SELECT id, name FROM tasks "
            "WHERE status = 'scheduled' "
            "AND (blocked_reason IS NULL OR blocked_reason = '') "
            "AND (wait_until IS NULL OR wait_until <= ?) "
            "ORDER BY urgency_score DESC, priority ASC "
            "LIMIT 5",
            (now_iso,)
        ).fetchall()
        if rows:
            names = ", ".join(r["name"] for r in rows[:3])
            return "execution", f"{len(rows)} scheduled task(s) ready: {names}"
    except sqlite3.Error:
        pass

    # No queue-state rule matched — fall through (empty queue → philosophy)
    return None, None


# ---------------------------------------------------------------------------
# Combined resolution: env_var > queue_state > default
# ---------------------------------------------------------------------------

def resolve_type(project_dir: Path, trigger_mode: str, db_path: Path) -> tuple:
    """
    Returns (session_type: str, resolution_source: str, queue_state_reason: str).
    """

    # Priority 1: SESSION_TYPE env var (explicit override — always wins)
    env_type = os.environ.get("SESSION_TYPE", "").strip()
    if env_type:
        return env_type, "env_var", ""

    # Priority 2: WINDOW_TYPE env var (lane constraint from wake.sh)
    window_type = os.environ.get("WINDOW_TYPE", "").strip().lower()
    if window_type == "maintenance":
        return "maintenance", "window_type", ""
    if window_type == "reflection":
        # Reflection windows can also pick philosophy
        reflection_type = _pick_reflection_type(db_path)
        return reflection_type, "window_type", ""
    # window_type == "work" or unset: fall through to queue-state logic

    # Priority 3: Queue state from Loom DB
    queue_type, queue_reason = resolve_from_queue_state(db_path)
    if queue_type:
        return queue_type, "queue_state", queue_reason

    # Priority 3b: Inbox has unprocessed task_requests/bug_reports/task_comments → execution needed
    # This handles the case where inbox_startup.py hasn't run yet (it runs inside the
    # session, after session type is resolved). If inbox has actionable work, force
    # execution so inbox_startup can convert entries to Loom tasks and work them.
    if _inbox_has_pending_tasks(project_dir):
        return "execution", "inbox_pending", \
            "inbox/pending.json has unprocessed task_request/bug_report/task_comment entries"

    # Priority 4: default — empty queue means philosophy session
    return "philosophy", "default", ""


def _inbox_has_pending_tasks(project_dir: Path) -> bool:
    """
    Return True if inbox/pending.json contains unprocessed entries that require
    an execution session to handle: task_request, bug_report, or task_comment.

    task_comment entries carry owner feedback on existing Loom tasks. Without this
    check, an empty Loom queue causes philosophy sessions to loop while task_comments
    sit unread in the inbox.
    """
    inbox_path = project_dir / "inbox" / "pending.json"
    if not inbox_path.exists():
        return False
    try:
        data = json.loads(inbox_path.read_text(encoding="utf-8"))
        entries = data if isinstance(data, list) else data.get("entries", [])
        for e in entries:
            if e.get("processed", False):
                continue
            if e.get("type") in ("task_request", "bug_report", "task_comment"):
                return True
        return False
    except Exception:
        return False


def _pick_reflection_type(db_path: Path) -> str:
    """
    For reflection windows, decide between 'reflection' and 'philosophy'.
    Uses a simple heuristic: if there is a recent philosophy session (last 3 days),
    return 'reflection'; otherwise alternate by checking session count parity.
    Falls back to 'reflection' on any error.
    """
    if not db_path.exists():
        return "reflection"

    try:
        conn = sqlite3.connect(str(db_path))
        # Check if loom_sessions table exists and has a recent philosophy session
        rows = conn.execute(
            "SELECT COUNT(*) FROM loom_sessions "
            "WHERE type = 'philosophy' "
            "AND date >= date('now', '-3 days')"
        ).fetchone()
        conn.close()
        if rows and rows[0] > 0:
            return "reflection"
        # No recent philosophy — pick philosophy this time
        return "philosophy"
    except Exception:
        return "reflection"


# ---------------------------------------------------------------------------
# YAML loader + config assembly
# ---------------------------------------------------------------------------

def load_yaml_simple(path: Path) -> dict:
    """
    Minimal YAML loader for the simple key-value + list structure used in
    session type configs. Handles: str values, block scalars (>), lists (- items),
    and nested dicts (2-space indent). Does not handle anchors, multi-doc, etc.
    Falls back to {} on parse error.
    """
    try:
        import yaml
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        pass
    except Exception:
        return {}

    # Fallback: hand-rolled minimal parser
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        result = {}
        i = 0
        while i < len(lines):
            line = lines[i]
            stripped = line.rstrip()
            if not stripped or stripped.lstrip().startswith("#"):
                i += 1
                continue
            if ":" in stripped and not stripped.startswith(" "):
                key, _, rest = stripped.partition(":")
                key = key.strip()
                rest = rest.strip()
                if rest in (">", "|", ""):
                    j = i + 1
                    sub_lines = []
                    while j < len(lines):
                        sub = lines[j]
                        if not sub.strip() and sub_lines:
                            sub_lines.append("")
                            j += 1
                            continue
                        if sub and not sub[0].isspace():
                            break
                        sub_lines.append(sub.strip())
                        j += 1
                    if sub_lines and sub_lines[0].startswith("- "):
                        result[key] = [s[2:].strip() for s in sub_lines if s.startswith("- ")]
                    elif sub_lines and sub_lines[0].startswith("#"):
                        result[key] = {}
                    elif sub_lines:
                        result[key] = " ".join(s for s in sub_lines if s)
                    i = j
                elif rest.startswith("["):
                    result[key] = []
                    i += 1
                else:
                    result[key] = rest.strip('"').strip("'")
                    i += 1
            else:
                i += 1
        return result
    except Exception:
        return {}


def load_type_config(project_dir: Path, session_type: str) -> dict:
    """Load and return the session type YAML config dict."""
    type_file = project_dir / "config" / "session_types" / f"{session_type}.yaml"
    if not type_file.exists():
        return {}
    config = load_yaml_simple(type_file)

    # Scope rotation for maintenance sessions
    if session_type == "maintenance" and config.get("scope_rotation"):
        scope_state_file = project_dir / config["scope_state_file"]
        try:
            idx = int(scope_state_file.read_text(encoding="utf-8").strip())
        except (FileNotFoundError, ValueError, OSError):
            idx = 0

        scope_num = idx + 1  # 1-indexed for YAML file naming
        scope_file = project_dir / "config" / "session_types" / f"maintenance_scope{scope_num}.yaml"
        scope_config = load_yaml_simple(scope_file)

        # Merge: scope overrides base context and focus_hint
        config["context_files"] = scope_config.get("context_files", config.get("context_files", []))
        config["focus_hint"] = scope_config.get("focus_hint", config.get("focus_hint", ""))
        config["scope_id"] = scope_num
        config["scope_name"] = scope_config.get("scope_name", f"Scope {scope_num}")

        # Rotate for next maintenance session
        next_idx = (idx + 1) % 3
        try:
            scope_state_file.write_text(str(next_idx), encoding="utf-8")
        except OSError:
            pass

    return config


def assemble_context(project_dir: Path, context_files: list) -> str:
    """
    Read context files and concatenate them with headers.
    Files that don't exist are silently skipped.
    """
    parts = []
    for rel_path in context_files:
        if not isinstance(rel_path, str):
            continue
        abs_path = project_dir / rel_path
        if not abs_path.exists():
            continue
        try:
            content = abs_path.read_text(encoding="utf-8").strip()
            if content:
                parts.append(f"### {rel_path}\n\n{content}")
        except OSError:
            continue

    if not parts:
        return ""

    return "\n\n---\n\n".join(parts)


def load_prompt_content(project_dir: Path, prompt_file: str) -> str:
    """Load the type-specific prompt file contents."""
    if not prompt_file:
        return ""
    prompt_path = project_dir / prompt_file
    if not prompt_path.exists():
        return ""
    try:
        return prompt_path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def main():
    args = parse_args()
    project_dir = Path(args.project_dir).resolve()
    db_path = Path(args.loom_db) if args.loom_db else LOOM_DB_PATH

    session_type, resolution_source, queue_reason = resolve_type(
        project_dir, args.trigger_mode, db_path
    )
    config = load_type_config(project_dir, session_type)

    context_files = config.get("context_files") or []
    if not isinstance(context_files, list):
        context_files = []

    assembled_context = assemble_context(project_dir, context_files)

    prompt_file = config.get("prompt_file") or ""
    if not isinstance(prompt_file, str):
        prompt_file = ""
    prompt_content = load_prompt_content(project_dir, prompt_file)

    behavioral_overrides = config.get("behavioral_overrides") or {}
    if not isinstance(behavioral_overrides, dict):
        behavioral_overrides = {}

    result = {
        "session_type": session_type,
        "resolution_source": resolution_source,
        "queue_state_reason": queue_reason,
        "prompt_content": prompt_content,
        "assembled_context": assembled_context,
        "focus_hint": (config.get("focus_hint") or "").strip(),
        "behavioral_overrides": behavioral_overrides,
        "memory_discipline": behavioral_overrides.get("memory_discipline", "normal"),
        "scope_id": config.get("scope_id"),
        "scope_name": config.get("scope_name"),
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, indent=2), encoding="utf-8")

    # Print summary to stderr for wake.log capture
    scope_suffix = f" scope={result['scope_id']}({result['scope_name']})" if result.get("scope_id") else ""
    print(
        f"session_type={session_type} source={resolution_source} "
        f"queue_reason={queue_reason!r} "
        f"prompt={'yes' if prompt_content else 'no'} "
        f"context_files={len(context_files)} "
        f"memory_discipline={result['memory_discipline']}"
        f"{scope_suffix}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
