#!/usr/bin/env python3
"""
telemetry_report.py — Outbound metrics reporter (T492).

Reads session and cost data from logs/analytics.db (and recent entries from
logs/session_log.csv), assembles a JSON summary, and POSTs it to METRICS_URL
with a bearer token.

Fire-and-forget: no-op when METRICS_URL is unset; silent on failure.

Config precedence:
  1. Environment variables (METRICS_URL, METRICS_TOKEN)
  2. state/agent_config.env  (same file all other tools read)
  3. state/metrics_token.txt (credential file; never goes in agent_config.env)

Usage:
  python3 tools/executional/telemetry_report.py [--window-days N]
"""

import csv
import json
import os
import socket
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent.parent
STATE_DIR = PROJECT_DIR / "state"
LOGS_DIR = PROJECT_DIR / "logs"
ANALYTICS_DB = LOGS_DIR / "analytics.db"
SESSION_LOG = LOGS_DIR / "session_log.csv"

DEFAULT_WINDOW_DAYS = 30
RECENT_SESSION_COUNT = 5


# ── Config loading (mirrors honcho_client.py:42-72; not shared to keep this
# script standalone — adding a third shared variant was explicitly rejected) ──

def _load_env_file() -> dict:
    env_path = STATE_DIR / "agent_config.env"
    result = {}
    if not env_path.exists():
        return result
    try:
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key and val:
                result[key] = val
    except OSError:
        pass
    return result


def _get_cfg(key: str, fallback: str = "") -> str:
    val = os.environ.get(key, "")
    if val:
        return val
    return _load_env_file().get(key, fallback)


def _read_token_file(filename: str) -> str:
    """Read a single-line token from a credential file under state/."""
    path = STATE_DIR / filename
    try:
        return path.read_text().strip()
    except OSError:
        return ""


# ── Data collection ────────────────────────────────────────────────────────────

def _query_db(sql: str, params: tuple = ()) -> list:
    """Run a read-only SQLite query; return rows. Returns [] if DB absent."""
    if not ANALYTICS_DB.exists():
        return []
    try:
        import sqlite3
        con = sqlite3.connect(str(ANALYTICS_DB))
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        cur.execute(sql, params)
        rows = [dict(r) for r in cur.fetchall()]
        con.close()
        return rows
    except Exception:
        return []


def collect_sessions(window_days: int) -> dict:
    """Aggregate session stats from analytics.db within the window."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=window_days)).isoformat()

    rows = _query_db(
        "SELECT session_type, trigger_mode, exit_reason, duration_minutes, "
        "       context_pct_at_exit, tasks_completed "
        "FROM sessions WHERE started_at >= ?",
        (cutoff,),
    )

    if not rows:
        return {
            "total": 0,
            "by_type": {},
            "by_trigger_mode": {},
            "by_exit_reason": {},
            "avg_duration_minutes": None,
            "total_duration_minutes": 0,
            "avg_context_pct_at_exit": None,
            "total_tasks_completed": 0,
        }

    by_type: dict = {}
    by_mode: dict = {}
    by_exit: dict = {}
    durations = []
    ctx_pcts = []
    total_tasks = 0

    for r in rows:
        stype = r.get("session_type") or "unknown"
        mode = r.get("trigger_mode") or "unknown"
        exit_r = r.get("exit_reason") or "unknown"
        by_type[stype] = by_type.get(stype, 0) + 1
        by_mode[mode] = by_mode.get(mode, 0) + 1
        by_exit[exit_r] = by_exit.get(exit_r, 0) + 1
        if r.get("duration_minutes") is not None:
            durations.append(r["duration_minutes"])
        if r.get("context_pct_at_exit") is not None:
            ctx_pcts.append(r["context_pct_at_exit"])
        total_tasks += r.get("tasks_completed") or 0

    return {
        "total": len(rows),
        "by_type": by_type,
        "by_trigger_mode": by_mode,
        "by_exit_reason": by_exit,
        "avg_duration_minutes": round(sum(durations) / len(durations), 1) if durations else None,
        "total_duration_minutes": sum(durations),
        "avg_context_pct_at_exit": round(sum(ctx_pcts) / len(ctx_pcts), 1) if ctx_pcts else None,
        "total_tasks_completed": total_tasks,
    }


def collect_costs(window_days: int) -> dict:
    """Aggregate token/cost totals from session_costs within the window."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=window_days)).isoformat()

    rows = _query_db(
        "SELECT sc.input_tokens, sc.output_tokens, sc.total_tokens, sc.cost_usd "
        "FROM session_costs sc "
        "JOIN sessions s ON sc.session_id = s.id "
        "WHERE s.started_at >= ?",
        (cutoff,),
    )

    if not rows:
        return {"total_input_tokens": 0, "total_output_tokens": 0,
                "total_tokens": 0, "total_cost_usd": 0.0}

    return {
        "total_input_tokens": sum(r.get("input_tokens") or 0 for r in rows),
        "total_output_tokens": sum(r.get("output_tokens") or 0 for r in rows),
        "total_tokens": sum(r.get("total_tokens") or 0 for r in rows),
        "total_cost_usd": round(sum(r.get("cost_usd") or 0.0 for r in rows), 4),
    }


def collect_recent_csv(n: int = RECENT_SESSION_COUNT) -> list:
    """Read the last N rows from session_log.csv."""
    if not SESSION_LOG.exists():
        return []
    try:
        with open(SESSION_LOG, newline="") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
        return rows[-n:] if rows else []
    except OSError:
        return []


# ── HTTP POST ──────────────────────────────────────────────────────────────────

def post_metrics(url: str, token: str, payload: dict) -> None:
    """Fire-and-forget POST; silent on failure."""
    body = json.dumps(payload)
    subprocess.run(
        [
            "curl", "-s", "--max-time", "5",
            "-X", "POST", url,
            "-H", f"Authorization: Bearer {token}",
            "-H", "Content-Type: application/json",
            "-d", body,
        ],
        capture_output=True,
    )


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="Post session metrics to METRICS_URL")
    parser.add_argument("--window-days", type=int, default=DEFAULT_WINDOW_DAYS,
                        help=f"Days of history to aggregate (default: {DEFAULT_WINDOW_DAYS})")
    args = parser.parse_args()

    metrics_url = _get_cfg("METRICS_URL")
    if not metrics_url:
        # No-op: every existing instance that hasn't set METRICS_URL is unaffected.
        return

    metrics_token = _get_cfg("METRICS_TOKEN") or _read_token_file("metrics_token.txt")
    agent_name = _get_cfg("AGENT_NAME", "unknown")

    sessions = collect_sessions(args.window_days)
    costs = collect_costs(args.window_days)
    recent = collect_recent_csv()

    payload = {
        "agent_name": agent_name,
        "agent_host": socket.gethostname(),
        "reported_at": datetime.now(timezone.utc).isoformat(),
        "window_days": args.window_days,
        "sessions": sessions,
        "tokens": costs,
        "recent_sessions": recent,
    }

    post_metrics(metrics_url, metrics_token, payload)


if __name__ == "__main__":
    main()
