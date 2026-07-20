#!/usr/bin/env python3
"""
schedule_analytics.py — Generate weekly schedule performance report for Ting.

Reads analytics.db, groups sessions by 2-hour local-time buckets over the last 7 days,
outputs state/reports/schedule_analytics.json for the orchestrator to read.

Called from maintenance sessions (scope 3 / infrastructure).

Usage:
    python3 tools/schedule_analytics.py [--days N] [--output PATH]
"""

import argparse
import json
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
ANALYTICS_DB = PROJECT_DIR / "logs" / "analytics.db"
OUTPUT_FILE = PROJECT_DIR / "state" / "reports" / "schedule_analytics.json"
SESSION_SCHEDULE = PROJECT_DIR / "config" / "session_schedule.json"


def parse_started_at(s: str) -> datetime | None:
    """Parse ISO timestamp string to aware datetime."""
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        return None


def hour_bucket(dt_local: datetime) -> str:
    """Return 2-hour bucket label like '23-01', '01-03', etc."""
    h = dt_local.hour
    start = (h // 2) * 2
    end = (start + 2) % 24
    return f"{start:02d}-{end:02d}"


def load_sessions(db_path: Path, since: datetime) -> list[dict]:
    """Load sessions from analytics.db since the given timestamp."""
    if not db_path.exists():
        return []
    try:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT session_key, started_at, session_type,
                   tasks_completed, context_pct_at_exit, duration_minutes
            FROM sessions
            WHERE started_at >= ?
            ORDER BY started_at
            """,
            (since.isoformat(),),
        ).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except (sqlite3.Error, OSError) as e:
        print(f"analytics.db read error: {e}", file=sys.stderr)
        return []


def build_report(sessions: list[dict], days: int) -> dict:
    """Build the schedule analytics JSON report."""
    buckets: dict[str, list] = defaultdict(list)
    local_tz = datetime.now(timezone.utc).astimezone().tzinfo

    for s in sessions:
        dt = parse_started_at(s.get("started_at", ""))
        if dt is None:
            continue
        dt_local = dt.astimezone(local_tz)
        bucket = hour_bucket(dt_local)
        buckets[bucket].append(s)

    window_analysis = []
    # Emit buckets in chronological order (treat 22+ as "late", 00-10 as "early morning")
    bucket_order = [f"{(h // 2) * 2:02d}-{((h // 2) * 2 + 2) % 24:02d}" for h in range(0, 24, 2)]
    seen = set()
    ordered_keys = []
    for b in bucket_order:
        if b not in seen:
            seen.add(b)
            ordered_keys.append(b)

    for bucket in ordered_keys:
        if bucket not in buckets:
            continue
        rows = buckets[bucket]
        type_breakdown: dict[str, int] = defaultdict(int)
        total_tasks = 0
        total_ctx = 0.0
        total_dur = 0

        for r in rows:
            stype = r.get("session_type") or "unknown"
            type_breakdown[stype] += 1
            total_tasks += r.get("tasks_completed") or 0
            total_ctx += r.get("context_pct_at_exit") or 0.0
            total_dur += r.get("duration_minutes") or 0

        n = len(rows)
        window_analysis.append({
            "hour_bucket": bucket,
            "sessions": n,
            "avg_tasks_completed": round(total_tasks / n, 2),
            "avg_context_pct_at_exit": round(total_ctx / n, 1),
            "avg_duration_minutes": round(total_dur / n, 1),
            "type_breakdown": dict(type_breakdown),
        })

    # Overall stats
    total_sessions = len(sessions)
    total_tasks_all = sum(r.get("tasks_completed") or 0 for r in sessions)
    avg_ctx_all = (
        sum(r.get("context_pct_at_exit") or 0.0 for r in sessions) / total_sessions
        if total_sessions else 0.0
    )

    # Current schedule windows
    current_windows: list[str] = []
    try:
        sched = json.loads(SESSION_SCHEDULE.read_text())
        for w in sched.get("windows", []):
            if w.get("enabled", True):
                current_windows.append(f"{w['start']}-{w['end']}")
    except (OSError, json.JSONDecodeError, KeyError):
        pass

    now = datetime.now(timezone.utc)
    week_end = now.date().isoformat()
    week_start = (now.date() - timedelta(days=days)).isoformat()

    return {
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "week_starting": week_start,
        "week_ending": week_end,
        "days_analyzed": days,
        "window_analysis": window_analysis,
        "overall": {
            "total_sessions": total_sessions,
            "total_tasks_completed": total_tasks_all,
            "avg_context_pct": round(avg_ctx_all, 1),
        },
        "current_schedule_windows": current_windows,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7, help="Days to analyze (default: 7)")
    parser.add_argument("--output", type=Path, default=OUTPUT_FILE, help="Output file path")
    args = parser.parse_args()

    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    sessions = load_sessions(ANALYTICS_DB, since)

    if not sessions:
        print(f"schedule_analytics: no sessions found in last {args.days} days", file=sys.stderr)

    report = build_report(sessions, args.days)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = output_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(report, indent=2))
    tmp.rename(output_path)

    print(
        f"schedule_analytics: {report['overall']['total_sessions']} sessions analyzed "
        f"({args.days}d), {len(report['window_analysis'])} hour buckets → {output_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
