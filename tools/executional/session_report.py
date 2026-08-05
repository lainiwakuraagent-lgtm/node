#!/usr/bin/env python3
"""
session_report.py — Goal 9, Task 64

Generates state/reports/session_report.md: a human-readable summary of
recent execution sessions for the conversational layer to surface on demand.

Usage:
  python3 tools/session_report.py [--sessions N] [--output PATH] [--send]

  --sessions N   Number of recent sessions to include (default: 3)
  --output PATH  Output path (default: state/reports/session_report.md)
  --send         Print to stdout (for Telegram piping) instead of file

Reads:
  memory/latest_summary.md
  logs/session_log.csv
  memory/sessions/*.md (most recent N)
"""

import argparse
import csv
import os
import re
import sys
from datetime import datetime
from pathlib import Path

PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", Path(__file__).parent.parent.parent))


def _load_agent_tag() -> str:
    """Read AGENT_NAME from state/agent_config.env, default 'agent'."""
    config_path = PROJECT_DIR / "state" / "agent_config.env"
    name = "agent"
    if config_path.exists():
        for line in config_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("AGENT_NAME="):
                name = line.split("=", 1)[1].strip()
                break
    return "@" + name[:1].upper() + name[1:]


AGENT_TAG = _load_agent_tag()


def _extract_section(text: str, header: str) -> str:
    """Extract content from a ## section header.

    Handles two formats:
      - Inline: '## Header: content on same line'
      - Block:  '## Header\ncontent\nover\nmultiple lines'
    Returns the content string, stripped.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not line.startswith("## "):
            continue
        section = line[3:].strip()
        if not section.lower().startswith(header.lower()):
            continue
        # Check for inline content after the colon
        colon_pos = section.find(":")
        if colon_pos != -1:
            inline = section[colon_pos + 1:].strip()
            if inline:
                return inline
        # Multi-line: collect subsequent lines until next ## header
        block_lines = []
        for j in range(i + 1, len(lines)):
            if lines[j].startswith("## "):
                break
            block_lines.append(lines[j])
        return "\n".join(block_lines).strip()
    return ""


def read_hot_state(summary_path: Path) -> str:
    """Extract HOT STATE block from latest_summary.md."""
    if not summary_path.exists():
        return "No summary file found."
    text = summary_path.read_text()
    result = _extract_section(text, "HOT STATE")
    return result or text.splitlines()[0]


def read_blockers(summary_path: Path) -> str:
    """Extract Blockers section from latest_summary.md."""
    if not summary_path.exists():
        return "Unknown"
    text = summary_path.read_text()
    return _extract_section(text, "Blockers") or "NONE"


def read_next_action(summary_path: Path) -> str:
    """Extract Next action from latest_summary.md."""
    if not summary_path.exists():
        return "Unknown"
    text = summary_path.read_text()
    return _extract_section(text, "Next action") or "Unknown"


def read_csv_sessions(csv_path: Path, n: int) -> list[dict]:
    """Read last N rows from session_log.csv."""
    if not csv_path.exists():
        return []
    rows = []
    with open(csv_path, newline="") as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) >= 5 and row[1]:  # skip malformed
                rows.append({
                    "timestamp": row[0],
                    "type": row[1],
                    "duration": row[2],
                    "context_pct": row[3],
                    "summary": row[4],
                })
    return rows[-n:]


def find_session_files(sessions_dir: Path, n: int) -> list[Path]:
    """Return most recent N session .md files by mtime."""
    if not sessions_dir.exists():
        return []
    files = sorted(sessions_dir.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[:n]


def read_session_file(path: Path) -> dict:
    """Parse a session .md file for key info."""
    text = path.read_text()
    lines = text.splitlines()

    result = {"filename": path.name, "what": [], "findings": [], "decisions": []}

    # Extract type/duration/exit from header lines
    for line in lines[:8]:
        if "**Type:**" in line:
            result["type"] = line.split("**Type:**")[-1].strip()
        if "**Duration:**" in line:
            result["duration"] = line.split("**Duration:**")[-1].strip()
        if "**Exit reason:**" in line:
            result["exit"] = line.split("**Exit reason:**")[-1].strip()

    # Extract "What happened" section
    in_section = None
    for line in lines:
        lower = line.lower()
        if "## what happened" in lower or "## what was done" in lower:
            in_section = "what"
            continue
        elif "## key findings" in lower or "## decisions" in lower:
            in_section = "findings"
            continue
        elif line.startswith("## "):
            in_section = None
            continue

        if in_section == "what" and line.strip().startswith("-"):
            result["what"].append(line.strip("- ").strip())
        elif in_section == "findings" and line.strip().startswith("-"):
            result["findings"].append(line.strip("- ").strip())

    return result


def format_timestamp(ts: str) -> str:
    """Format timestamp for display."""
    ts = ts.rstrip("Z")
    try:
        dt = datetime.fromisoformat(ts)
        return dt.strftime("%Y-%m-%d %H:%M")
    except Exception:
        return ts[:16]


def read_self_update_log(log_path: Path) -> dict | None:
    """Parse the latest self_update run from logs/self_update.log.

    Returns a dict with keys: status, files_pulled, files_skipped, commit_hash.
    Returns None if the log is absent or unreadable.
    """
    if not log_path.exists():
        return None
    try:
        text = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    if not text.strip():
        return None

    # Find the last summary block
    marker = "=== self_update summary ==="
    end_marker = "==========================="
    last_start = text.rfind(marker)

    if last_start == -1:
        # No summary block — check for disabled/no-op message
        lines = text.splitlines()
        for line in reversed(lines):
            if "disabled" in line or "no-op" in line:
                return {"status": "disabled", "files_pulled": [], "files_skipped": [], "commit_hash": ""}
        return {"status": "unknown", "files_pulled": [], "files_skipped": [], "commit_hash": ""}

    block_text = text[last_start:]
    end_pos = block_text.find(end_marker)
    if end_pos != -1:
        block_text = block_text[:end_pos + len(end_marker)]

    result: dict = {"status": "ok", "files_pulled": [], "files_skipped": [], "commit_hash": ""}
    lines = block_text.splitlines()
    mode = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("files_pulled:"):
            mode = "pulled"
            count_str = stripped.split(":", 1)[1].strip()
            result["files_pulled_count"] = int(count_str) if count_str.isdigit() else 0
        elif stripped.startswith("files_skipped_by_exclude:"):
            mode = "skipped"
            count_str = stripped.split(":", 1)[1].strip()
            result["files_skipped_count"] = int(count_str) if count_str.isdigit() else 0
        elif stripped.startswith("commit_hash:"):
            mode = None
            result["commit_hash"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("==="):
            mode = None
        elif mode == "pulled" and stripped:
            result["files_pulled"].append(stripped)
        elif mode == "skipped" and stripped:
            result["files_skipped"].append(stripped)
    return result


def generate_report(n_sessions: int = 3) -> str:
    """Generate the full session report."""
    summary_path = PROJECT_DIR / "memory" / "latest_summary.md"
    csv_path = PROJECT_DIR / "logs" / "session_log.csv"
    sessions_dir = PROJECT_DIR / "memory" / "sessions"
    self_update_log = PROJECT_DIR / "logs" / "self_update.log"

    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    hot_state = read_hot_state(summary_path)
    blockers = read_blockers(summary_path)
    next_action = read_next_action(summary_path)
    csv_rows = read_csv_sessions(csv_path, n_sessions)
    session_files = find_session_files(sessions_dir, n_sessions)
    self_update = read_self_update_log(self_update_log)

    lines = [
        f"# Session Report — {AGENT_TAG}",
        f"Generated: {now}",
        "",
        "---",
        "",
        "## Status",
        "",
        hot_state,
        "",
        "---",
        "",
        "## Blockers",
        "",
        blockers,
        "",
        "---",
        "",
        "## Next action",
        "",
        next_action,
        "",
        "---",
        "",
        f"## Recent sessions (last {n_sessions})",
        "",
    ]

    # CSV entries — compact table
    if csv_rows:
        lines.append("| When | Type | Duration | Summary |")
        lines.append("|------|------|----------|---------|")
        for row in csv_rows:
            ts = format_timestamp(row["timestamp"])
            stype = row["type"]
            dur = row["duration"] + "m" if row["duration"] and not row["duration"].endswith("m") else row["duration"]
            summary = row["summary"][:80] + "..." if len(row["summary"]) > 80 else row["summary"]
            lines.append(f"| {ts} | {stype} | {dur} | {summary} |")
        lines.append("")

    # Session file detail
    for sf in session_files:
        info = read_session_file(sf)
        lines.append(f"### {sf.stem}")
        if "type" in info:
            lines.append(f"- Type: {info['type']}")
        if "duration" in info:
            lines.append(f"- Duration: {info['duration']}")
        if "exit" in info:
            lines.append(f"- Exit: {info['exit']}")
        if info["what"]:
            lines.append("- What was done:")
            for item in info["what"][:5]:
                lines.append(f"  - {item}")
        if info["findings"]:
            lines.append("- Key findings:")
            for item in info["findings"][:3]:
                lines.append(f"  - {item}")
        lines.append("")

    # Maintenance — self_update section (non-breaking if log absent)
    if self_update is not None:
        lines += ["---", "", "## Maintenance — Self-update", ""]
        status = self_update.get("status", "unknown")
        if status == "disabled":
            lines.append("Self-update: disabled (SELF_UPDATE_ENABLED not set — no-op)")
        elif status == "ok":
            pulled = self_update.get("files_pulled", [])
            skipped = self_update.get("files_skipped", [])
            commit = self_update.get("commit_hash", "")
            if pulled:
                lines.append(f"Files pulled: {len(pulled)}")
                for f in pulled:
                    lines.append(f"  - {f}")
            else:
                lines.append("Files pulled: 0 (already up to date)")
            if skipped:
                lines.append(f"Files skipped by exclude list: {len(skipped)}")
                for f in skipped:
                    lines.append(f"  - {f}")
            lines.append(f"Commit: {commit or '(no changes)'}")
        else:
            lines.append(f"Self-update: {status}")
        lines.append("")

    lines += [
        "---",
        "",
        "*This report is generated by tools/session_report.py — Goal 9, Task 64.*",
        "*Source: latest_summary.md + session_log.csv + memory/sessions/.*",
    ]

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Generate session report")
    parser.add_argument("--sessions", type=int, default=3, help="Number of recent sessions (default: 3)")
    parser.add_argument("--output", type=str, default=None, help="Output path (default: state/reports/session_report.md)")
    parser.add_argument("--send", action="store_true", help="Print to stdout instead of writing file")
    args = parser.parse_args()

    report = generate_report(n_sessions=args.sessions)

    if args.send:
        print(report)
    else:
        output_path = Path(args.output) if args.output else PROJECT_DIR / "state" / "reports" / "session_report.md"
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(report)
        print(f"Report written to {output_path}")


if __name__ == "__main__":
    main()
