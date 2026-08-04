#!/usr/bin/env python3
"""
scheduler_loop.py — Calendar-trigger replacement for the systemd night-agent
timer (and schedule_one_off.py's job), for nodes running under the
supervisord process backend (Docker). Not used on bare-metal systemd
installs — those keep the real timer units; this only runs as a supervisord
program when PROCESS_BACKEND=supervisord.

Polls config/session_schedule.json and state/emergency_mode.active on a
short interval and fires wake.sh (background, non-blocking — a systemd timer
doesn't wait for its service either) at the right times:

  - windows[] triggers: exact "HH:MM" times, same source install.sh reads to
    generate OnCalendar lines on bare-metal installs.
  - one_off[] entries: fired individually at their exact datetime, polled at
    POLL_SECONDS resolution — tighter than the systemd path's hourly ":15"
    fallback probe, so no equivalent of that probe is needed here.
    resolve_session_type.py (inside wake.sh, unchanged) marks fired=true
    exactly as it already does for the systemd path.
  - emergency mode: state/emergency_mode.active present → fire on a fixed
    interval (state/emergency_mode.json's interval_min, if present) instead
    of the normal schedule.

Usage:
  python3 tools/executional/scheduler_loop.py
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime

PROJECT_DIR = __import__("pathlib").Path(__file__).resolve().parent.parent.parent
SCHEDULE_FILE = PROJECT_DIR / "config" / "session_schedule.json"
EMERGENCY_FLAG = PROJECT_DIR / "state" / "emergency_mode.active"
EMERGENCY_META = PROJECT_DIR / "state" / "emergency_mode.json"
WAKE_SH = PROJECT_DIR / "scripts" / "executional" / "wake.sh"
LOG_FILE = PROJECT_DIR / "logs" / "wake.log"

POLL_SECONDS = 30
DEFAULT_EMERGENCY_INTERVAL_MIN = 60


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] scheduler_loop.py: {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_schedule() -> dict:
    if not SCHEDULE_FILE.exists():
        return {"windows": [], "one_off": []}
    try:
        return json.loads(SCHEDULE_FILE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        log(f"WARNING: could not read {SCHEDULE_FILE}: {e}")
        return {"windows": [], "one_off": []}


def nightly_triggers(schedule: dict) -> set:
    """Deduped set of 'HH:MM' trigger times from all enabled windows."""
    triggers = set()
    for w in schedule.get("windows", []):
        if not w.get("enabled", True):
            continue
        for t in w.get("triggers", []):
            triggers.add(t)
    return triggers


def due_one_offs(schedule: dict, now: datetime, already_fired: set) -> list:
    due = []
    for i, entry in enumerate(schedule.get("one_off", [])):
        if entry.get("fired", False):
            continue
        key = (i, entry.get("datetime", ""))
        if key in already_fired:
            continue
        dt_str = entry.get("datetime", "")
        if not dt_str:
            continue
        try:
            dt = datetime.fromisoformat(dt_str).replace(tzinfo=None)
        except ValueError:
            continue
        if dt <= now:
            due.append((key, entry))
    return due


def emergency_state() -> tuple:
    if not EMERGENCY_FLAG.exists():
        return False, DEFAULT_EMERGENCY_INTERVAL_MIN
    interval = DEFAULT_EMERGENCY_INTERVAL_MIN
    if EMERGENCY_META.exists():
        try:
            meta = json.loads(EMERGENCY_META.read_text(encoding="utf-8"))
            interval = int(meta.get("interval_min", DEFAULT_EMERGENCY_INTERVAL_MIN))
        except (json.JSONDecodeError, OSError, ValueError, TypeError):
            pass
    return True, interval


def fire_wake(trigger_mode: str, label: str) -> None:
    log(f"firing wake.sh (TRIGGER_MODE={trigger_mode}, trigger={label})")
    env = dict(os.environ)
    env["TRIGGER_MODE"] = trigger_mode
    env["PROJECT_DIR"] = str(PROJECT_DIR)
    try:
        subprocess.Popen(
            ["bash", str(WAKE_SH)],
            cwd=str(PROJECT_DIR),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as e:
        log(f"ERROR: failed to launch wake.sh: {e}")


def main() -> int:
    log(f"starting (poll={POLL_SECONDS}s, schedule={SCHEDULE_FILE})")
    fired_nightly_this_minute = set()
    fired_one_off_this_run = set()
    last_emergency_fire = None
    last_minute_bucket = ""

    while True:
        now = datetime.now()
        minute_bucket = now.strftime("%Y-%m-%d %H:%M")
        if minute_bucket != last_minute_bucket:
            fired_nightly_this_minute.clear()
            last_minute_bucket = minute_bucket

        is_emergency, interval_min = emergency_state()

        if is_emergency:
            due = (
                last_emergency_fire is None
                or (now - last_emergency_fire).total_seconds() >= interval_min * 60
            )
            if due:
                fire_wake("emergency", f"emergency-interval-{interval_min}m")
                last_emergency_fire = now
        else:
            last_emergency_fire = None
            schedule = load_schedule()
            hhmm = now.strftime("%H:%M")

            if hhmm in nightly_triggers(schedule) and hhmm not in fired_nightly_this_minute:
                fire_wake("nightly", hhmm)
                fired_nightly_this_minute.add(hhmm)

            for key, entry in due_one_offs(schedule, now, fired_one_off_this_run):
                trig = entry.get("trigger", "manual")
                label = entry.get("label", entry.get("datetime", str(key)))
                fire_wake(trig, f"one_off:{label}")
                fired_one_off_this_run.add(key)

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
