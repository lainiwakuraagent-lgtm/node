#!/usr/bin/env python3
"""
command_dispatcher.py — Handle Telegram /commands from the owner.

Called by check_replies.sh when a Telegram message starts with '/'.
Reads state files + Loom DB + session_log.csv to produce a formatted response,
then the caller pipes the output to telegram_send.sh.

Usage:
  python3 tools/command_dispatcher.py "/status"
  python3 tools/command_dispatcher.py "/log 10"
  python3 tools/command_dispatcher.py "/control emergency on 15 urgent"

Exit 0 always. Output is the response text for Telegram.

Supported commands:
  /status              Current state: goal, last session, next scheduled
  /session             Details of last completed session
  /log [N]             Last N session lines from session_log.csv (default: 5)
  /goal                Active Loom goal + tasks
  /analytics           Session stats from analytics.db (if available)
  /who                 Identity + relationship state
  /control emergency on [interval] [reason]   Enable emergency mode
  /control emergency off                       Disable emergency mode
  /control goal <id>                           Switch active Loom goal
"""

import csv
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
LOOM_DB = Path.home() / ".local" / "share" / "loom" / "loom.db"
ANALYTICS_DB = PROJECT_DIR / "logs" / "analytics.db"


def read_state(name, default=""):
    p = PROJECT_DIR / "state" / name
    return p.read_text().strip() if p.exists() else default


def _loom_query(sql, params=()):
    if not LOOM_DB.exists():
        return []
    try:
        conn = sqlite3.connect(LOOM_DB)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(sql, params).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except sqlite3.Error:
        return []


def _analytics_query(sql, params=()):
    if not ANALYTICS_DB.exists():
        return []
    try:
        conn = sqlite3.connect(ANALYTICS_DB)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(sql, params).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except sqlite3.Error:
        return []


def _last_session_csv(n=1):
    """Return last N rows from session_log.csv as list of dicts."""
    csv_path = PROJECT_DIR / "logs" / "session_log.csv"
    if not csv_path.exists():
        return []
    rows = []
    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows[-n:] if rows else []


def _andrii_relationship():
    """Read trust/warmth/friction from andrii.md."""
    andrii_path = PROJECT_DIR / "memory" / "work" / "musubi_data" / "users" / "lain" / "andrii.md"
    if not andrii_path.exists():
        return None
    text = andrii_path.read_text()
    import re
    vals = {}
    for key in ("Trust", "Warmth", "Friction"):
        m = re.search(r"\*\*" + key + r":\*\*\s*([\d.]+)", text)
        if m:
            vals[key.lower()] = m.group(1)
    return vals


# ── Command handlers ──────────────────────────────────────────────────────────

def cmd_status():
    lines = ["@Lain — status"]

    # Active goal
    goals = _loom_query(
        "SELECT id, name, status FROM goals WHERE status IN ('active', 'in_progress') LIMIT 1"
    )
    if goals:
        g = goals[0]
        lines.append(f"Goal: {g['name']} (ID {g['id']}, {g['status']})")
    else:
        lines.append("Goal: none active")

    # Last session from CSV
    last = _last_session_csv(1)
    if last:
        row = last[0]
        ts = row.get("timestamp", "")[:16]
        stype = row.get("session_type", "?")
        dur = row.get("duration_minutes", "?")
        summary = row.get("one_line_summary", "")[:80]
        lines.append(f"Last: [{ts}] {stype} ({dur}min) — {summary}")

    # Current mode
    mode = read_state("trigger_mode.txt", "?")
    count_file = {
        "nightly": "sessions_tonight.count",
        "emergency": "sessions_emergency.count",
    }.get(mode, "sessions_manual.count")
    count = read_state(count_file, "?")
    lines.append(f"Mode: {mode} | sessions={count}")

    # Emergency mode status
    em_active = (PROJECT_DIR / "state" / "emergency_mode.active").exists()
    if em_active:
        lines.append("⚠ EMERGENCY MODE ACTIVE — nightly sessions paused")

    # Context
    ctx = read_state("behavioral_context.txt", "")
    if "Trust=" in ctx:
        import re
        m = re.search(r"Trust=([\d.]+)\s+Warmth=([\d.]+)", ctx)
        if m:
            lines.append(f"Relationship: trust={m.group(1)} warmth={m.group(2)}")

    return "\n".join(lines)


def cmd_session():
    lines = ["@Lain — last session"]
    last = _last_session_csv(1)
    if not last:
        return "@Lain — no session data found"
    row = last[0]
    lines.append(f"Time:     {row.get('timestamp', '?')[:19]}")
    lines.append(f"Type:     {row.get('session_type', '?')}")
    lines.append(f"Duration: {row.get('duration_minutes', '?')} min")
    lines.append(f"Context:  {row.get('context_pct_at_exit', '?')}%")
    lines.append(f"Summary:  {row.get('one_line_summary', '?')}")

    # Try latest_summary.md HOT STATE
    ls_path = PROJECT_DIR / "memory" / "latest_summary.md"
    if ls_path.exists():
        text = ls_path.read_text()
        # Extract first few lines after HOT STATE header
        lines_text = text.split("\n")
        for i, l in enumerate(lines_text):
            if "HOT STATE" in l and i + 1 < len(lines_text):
                hot = lines_text[i + 1].strip()
                if hot:
                    lines.append(f"Hot:      {hot[:100]}")
                break

    return "\n".join(lines)


def cmd_log(n=5):
    try:
        n = int(n)
    except (ValueError, TypeError):
        n = 5
    n = min(n, 20)

    rows = _last_session_csv(n)
    if not rows:
        return "@Lain — no session log found"

    lines = [f"@Lain — last {len(rows)} sessions"]
    for row in reversed(rows):
        ts = row.get("timestamp", "")[:16]
        stype = row.get("session_type", "?")
        dur = row.get("duration_minutes", "?")
        summary = (row.get("one_line_summary") or "")[:60]
        lines.append(f"[{ts}] {stype} ({dur}min) — {summary}")
    return "\n".join(lines)


def cmd_goal():
    goals = _loom_query(
        "SELECT id, name, status, priority FROM goals WHERE status IN ('active', 'in_progress') LIMIT 3"
    )
    if not goals:
        return "@Lain — no active goal in Loom"

    lines = ["@Lain — active goals"]
    for g in goals:
        lines.append(f"Goal {g['id']}: {g['name']} [{g['status']}]")

        # Projects under this goal
        projects = _loom_query(
            "SELECT id, title FROM projects WHERE goal_id = ?", (g["id"],)
        )
        for p in projects:
            # Task counts
            task_stats = _loom_query(
                "SELECT status, COUNT(*) as n FROM tasks WHERE project_id = ? GROUP BY status",
                (p["id"],),
            )
            done = sum(r["n"] for r in task_stats if r["status"] in ("done", "completed"))
            total = sum(r["n"] for r in task_stats)
            lines.append(f"  └ Project {p['id']}: {p['title']} ({done}/{total} done)")

    return "\n".join(lines)


def cmd_analytics():
    if not ANALYTICS_DB.exists():
        return (
            "@Lain — analytics\n"
            "DB not yet initialized. Will populate at next session end.\n"
            "Run: python3 tools/analytics_write.py --import-csv"
        )

    rows = _analytics_query(
        "SELECT COUNT(*) as n, AVG(duration_minutes) as avg_dur, "
        "AVG(context_pct_at_exit) as avg_ctx, SUM(tasks_completed) as tasks "
        "FROM sessions WHERE started_at >= datetime('now', '-7 days')"
    )
    if not rows or rows[0]["n"] == 0:
        return "@Lain — analytics: no data for last 7 days"

    r = rows[0]
    lines = ["@Lain — analytics (last 7 days)"]
    lines.append(f"Sessions:  {r['n']}")
    lines.append(f"Avg dur:   {round(r['avg_dur'] or 0, 1)} min")
    lines.append(f"Avg ctx:   {round(r['avg_ctx'] or 0, 1)}%")
    lines.append(f"Tasks:     {r['tasks'] or 0} completed")

    # Type breakdown
    types = _analytics_query(
        "SELECT session_type, COUNT(*) as n FROM sessions "
        "WHERE started_at >= datetime('now', '-7 days') GROUP BY session_type"
    )
    if types:
        breakdown = " / ".join(f"{t['session_type']}:{t['n']}" for t in types)
        lines.append(f"Types:     {breakdown}")

    # Cost
    costs = _analytics_query(
        "SELECT SUM(cost_usd) as total, SUM(total_tokens) as tokens FROM session_costs sc "
        "JOIN sessions s ON sc.session_id = s.id "
        "WHERE s.started_at >= datetime('now', '-7 days')"
    )
    if costs and costs[0]["total"]:
        lines.append(f"Cost est:  ${round(costs[0]['total'], 3)} USD ({costs[0]['tokens']:,} tokens)")
    else:
        lines.append("Cost:      (not yet tracked — run analytics_write.py at session end)")

    # Top tools
    tools = _analytics_query(
        "SELECT tool_name, SUM(call_count) as n FROM session_tools st "
        "JOIN sessions s ON st.session_id = s.id "
        "WHERE s.started_at >= datetime('now', '-7 days') "
        "GROUP BY tool_name ORDER BY n DESC LIMIT 5"
    )
    if tools:
        top = ", ".join(f"{t['tool_name']}({t['n']})" for t in tools)
        lines.append(f"Top tools: {top}")

    return "\n".join(lines)


def cmd_who():
    lines = ["@Lain — identity"]
    lines.append("Name: @Lain  |  Model: " + read_state("session_model.txt", "claude-sonnet-4-6"))
    lines.append("Instance: fokacco-hp-laptop-14-dk0xxx (Tailscale)")

    rel = _andrii_relationship()
    if rel:
        lines.append(f"Relationship → Andrii: trust={rel.get('trust','?')} warmth={rel.get('warmth','?')} friction={rel.get('friction','?')}")

    em_active = (PROJECT_DIR / "state" / "emergency_mode.active").exists()
    mode = read_state("trigger_mode.txt", "?")
    lines.append(f"Mode: {mode} | Emergency: {'ON' if em_active else 'off'}")

    return "\n".join(lines)


def cmd_control(args):
    if not args:
        return "@Lain — /control: needs subcommand (emergency on/off, goal <id>)"

    sub = args[0].lower()

    if sub == "emergency":
        if len(args) < 2:
            return "@Lain — /control emergency: needs 'on [interval] [reason]' or 'off'"
        action = args[1].lower()
        if action == "off":
            result = subprocess.run(
                ["bash", str(SCRIPT_DIR / "disable_emergency_mode.sh")],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                return "@Lain — emergency mode disabled. Nightly sessions resumed."
            return f"@Lain — failed to disable emergency mode:\n{result.stderr[:200]}"
        elif action == "on":
            interval = args[2] if len(args) > 2 else "15"
            reason = " ".join(args[3:]) if len(args) > 3 else "manual control"
            result = subprocess.run(
                ["bash", str(SCRIPT_DIR / "enable_emergency_mode.sh"), interval, reason],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                return f"@Lain — emergency mode ON (every {interval} min)\nReason: {reason}\nNightly sessions paused."
            return f"@Lain — failed to enable emergency mode:\n{result.stderr[:200]}"
        else:
            return f"@Lain — unknown emergency action: {action}"

    elif sub == "goal":
        if len(args) < 2:
            return "@Lain — /control goal: needs goal ID"
        goal_id = args[1]
        result = subprocess.run(
            ["bash", str(SCRIPT_DIR / "goal_switch.sh"), goal_id],
            capture_output=True, text=True,
            cwd=str(PROJECT_DIR)
        )
        if result.returncode == 0:
            return f"@Lain — switched to goal {goal_id}.\n{result.stdout[:200]}"
        return f"@Lain — goal switch failed:\n{result.stderr[:200]}"

    else:
        return f"@Lain — unknown /control subcommand: {sub}\nTry: emergency on/off, goal <id>"


def cmd_help():
    return (
        "@Lain — commands\n"
        "/status        — current state, goal, last session\n"
        "/session       — last session details\n"
        "/log [N]       — last N sessions (default 5)\n"
        "/goal          — active Loom goal + tasks\n"
        "/analytics     — session stats + costs\n"
        "/who           — identity + relationship state\n"
        "/control emergency on [min] [reason]  — enable emergency mode\n"
        "/control emergency off                — disable emergency mode\n"
        "/control goal <id>                    — switch active goal"
    )


# ── Dispatch ──────────────────────────────────────────────────────────────────

def dispatch(raw_command):
    parts = raw_command.strip().split()
    if not parts or not parts[0].startswith("/"):
        return "@Lain — not a command"

    cmd = parts[0].lower()
    args = parts[1:]

    if cmd == "/status":
        return cmd_status()
    elif cmd == "/session":
        return cmd_session()
    elif cmd == "/log":
        return cmd_log(args[0] if args else 5)
    elif cmd == "/goal":
        return cmd_goal()
    elif cmd == "/analytics":
        return cmd_analytics()
    elif cmd == "/who":
        return cmd_who()
    elif cmd == "/control":
        return cmd_control(args)
    elif cmd in ("/help", "/?"):
        return cmd_help()
    else:
        return f"@Lain — unknown command: {cmd}\nTry /help"


def main():
    if len(sys.argv) < 2:
        print("Usage: command_dispatcher.py '/command [args]'", file=sys.stderr)
        sys.exit(1)
    raw = " ".join(sys.argv[1:])
    print(dispatch(raw))


if __name__ == "__main__":
    main()
