#!/usr/bin/env python3
"""
khal_schedule_reader.py
Regenerates the `one_off[]` portion of config/session_schedule.json from this
agent's own khal calendar (installed per-agent by install.sh Step 8b).

Scope is deliberately narrow: `windows[]` (nightly-work / nightly-maintenance /
nightly-reflection and their fixed triggers) is never touched by this script —
those stay exactly as configured, so the nightly maintenance window can't be
dropped by calendar mismanagement. Only `one_off[]` entries tagged
`"source": "khal"` are replaced on each sync; any manually-added one_off
entries (source absent or different) are left untouched.

Convention: a khal event counts as a scheduling window only if one of its
categories starts with "blank_node_window:<type>", where <type> is one of
work/maintenance/reflection -- the same WINDOW_TYPE values
resolve_session_type.py already understands. Anything else in the calendar
(unrelated personal events, etc.) is ignored. Example:

  bin/khal new 2026-08-05 14:00 1h "research window" -g "blank_node_window:work"

Designed to be a no-op, not a failure, whenever khal isn't installed or
configured -- calendar-based custom windows are optional; the fixed nightly
schedule must keep working with zero dependency on this script succeeding.

Usage:
  python3 khal_schedule_reader.py sync --schedule-file PATH [--khal-bin PATH] [--days-ahead N]
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta

VALID_TYPES = {"work", "maintenance", "reflection"}
CATEGORY_PREFIX = "blank_node_window:"
# Wider than check_window.py's default 45s one-off tolerance -- these entries
# are caught by an hourly probe timer, not a dedicated per-minute trigger.
DEFAULT_TOLERANCE_SEC = 1800


def find_khal_bin(explicit):
    if explicit:
        return explicit
    here = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(os.path.dirname(here))  # tools/executional -> project root
    wrapper = os.path.join(project_dir, "bin", "khal")
    if os.path.isfile(wrapper) and os.access(wrapper, os.X_OK):
        return wrapper
    from shutil import which
    return which("khal")


def fetch_khal_events(khal_bin, days_ahead):
    start = datetime.now().strftime("%Y-%m-%d")
    end = (datetime.now() + timedelta(days=days_ahead)).strftime("%Y-%m-%d")
    cmd = [khal_bin, "list",
           "--json", "start-date", "--json", "start-time",
           "--json", "title", "--json", "categories", "--json", "uid",
           start, end]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=True)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"WARNING: khal query failed, leaving one_off[] unchanged: {e}", file=sys.stderr)
        return None

    events = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            day_events = json.loads(line)
        except json.JSONDecodeError:
            continue
        events.extend(day_events)
    return events


def khal_events_to_one_off(events):
    entries = []
    for ev in events:
        categories = ev.get("categories") or ""
        window_type = None
        for cat in categories.split(","):
            cat = cat.strip()
            if cat.startswith(CATEGORY_PREFIX):
                window_type = cat[len(CATEGORY_PREFIX):].strip()
                break
        if window_type is None:
            continue  # not a scheduling event -- ignore
        if window_type not in VALID_TYPES:
            print(f"WARNING: khal event '{ev.get('title')}' has unknown window type "
                  f"'{window_type}' (expected one of {sorted(VALID_TYPES)}) -- skipping",
                  file=sys.stderr)
            continue
        try:
            dt = datetime.strptime(f"{ev['start-date']} {ev['start-time']}", "%Y-%m-%d %H:%M")
        except (KeyError, ValueError):
            print(f"WARNING: khal event '{ev.get('title')}' has unparseable start time -- skipping",
                  file=sys.stderr)
            continue
        entries.append({
            "label": ev.get("title", "custom-window"),
            "type": window_type,
            "datetime": dt.isoformat(),
            "fired": False,
            "tolerance_sec": DEFAULT_TOLERANCE_SEC,
            "source": "khal",
            "khal_uid": ev.get("uid", ""),
        })
    return entries


def cmd_sync(args) -> int:
    khal_bin = find_khal_bin(args.khal_bin)
    if not khal_bin:
        print("INFO: no khal binary found -- custom calendar windows unavailable, "
              "schedule file left unchanged.", file=sys.stderr)
        return 0

    try:
        with open(args.schedule_file) as f:
            schedule = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot read schedule file: {e}", file=sys.stderr)
        return 1

    events = fetch_khal_events(khal_bin, args.days_ahead)
    if events is None:
        return 0  # khal query failed -- never let this block the wake chain

    fresh_khal_entries = khal_events_to_one_off(events)

    # Preserve fired-state across regenerations by matching on khal's own UID,
    # so a custom window that already ran doesn't refire on the next sync.
    existing_by_uid = {
        e.get("khal_uid"): e
        for e in schedule.get("one_off", [])
        if e.get("source") == "khal" and e.get("khal_uid")
    }
    for entry in fresh_khal_entries:
        prior = existing_by_uid.get(entry["khal_uid"])
        if prior and prior.get("fired"):
            entry["fired"] = True

    non_khal_entries = [e for e in schedule.get("one_off", []) if e.get("source") != "khal"]
    schedule["one_off"] = non_khal_entries + fresh_khal_entries
    # windows[] (nightly-work/maintenance/reflection) is intentionally never touched.

    tmp = args.schedule_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(schedule, f, indent=2)
    os.replace(tmp, args.schedule_file)
    print(f"synced {len(fresh_khal_entries)} khal-sourced window(s) into one_off[]")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_sync = sub.add_parser("sync")
    p_sync.add_argument("--schedule-file", required=True)
    p_sync.add_argument("--khal-bin", default=None)
    p_sync.add_argument("--days-ahead", type=int, default=14)

    args = parser.parse_args()
    if args.cmd == "sync":
        return cmd_sync(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
