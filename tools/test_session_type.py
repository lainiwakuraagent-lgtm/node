#!/usr/bin/env python3
"""
test_session_type.py
Task 44 — Integration test: session type flows end to end

Tests:
  1. Resolver: SESSION_TYPE env var override works
  2. Resolver: recurring slot matching (nightly mode)
  3. Resolver: one_off entry fires and marks fired=true
  4. Resolver: default fallback to execution
  5. YAML loading: correct type config returned
  6. Context assembly: context files assembled correctly
  7. analytics_write: CURRENT_SESSION_TYPE env var is read as default

Usage:
  python3 tools/test_session_type.py [--project-dir DIR]

Returns exit code 0 on all pass, 1 if any test fails.
"""

import json
import os
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

# --- Setup ---
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_PROJECT_DIR = SCRIPT_DIR.parent


def project_dir_from_args() -> Path:
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg == "--project-dir" and i < len(sys.argv):
            return Path(sys.argv[i + 1]).resolve()
    return DEFAULT_PROJECT_DIR


PROJECT_DIR = project_dir_from_args()
RESOLVER = PROJECT_DIR / "scripts" / "resolve_session_type.py"

# Insert scripts/ into path so we can import the resolver
sys.path.insert(0, str(PROJECT_DIR / "scripts"))

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
failures = []


def check(name: str, condition: bool, detail: str = ""):
    if condition:
        print(f"  {PASS}  {name}")
    else:
        print(f"  {FAIL}  {name}{f' — {detail}' if detail else ''}")
        failures.append(name)


def run_resolver(project_dir: Path, trigger_mode: str, extra_env: dict = None) -> dict:
    """Run resolve_session_type.py and return parsed JSON output."""
    import subprocess
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        out_path = f.name
    env = os.environ.copy()
    env.pop("SESSION_TYPE", None)  # clean slate
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        [sys.executable, str(RESOLVER),
         "--project-dir", str(project_dir),
         "--trigger-mode", trigger_mode,
         "--output", out_path],
        capture_output=True, text=True, env=env
    )
    if result.returncode != 0:
        return {"_error": result.stderr}
    try:
        return json.loads(Path(out_path).read_text())
    except Exception as e:
        return {"_error": str(e)}
    finally:
        Path(out_path).unlink(missing_ok=True)


def make_schedule(one_off: list = None, recurring: list = None) -> dict:
    return {
        "version": 1,
        "recurring": recurring or [],
        "one_off": one_off or [],
    }


# ===========================================================================
# Test 1: SESSION_TYPE env var override
# ===========================================================================
print("\n[1] SESSION_TYPE env var override")
result = run_resolver(PROJECT_DIR, "nightly", extra_env={"SESSION_TYPE": "philosophy"})
check("session_type=philosophy", result.get("session_type") == "philosophy")
check("resolution_source=env_var", result.get("resolution_source") == "env_var")

# ===========================================================================
# Test 2: Default fallback (no schedule, no env var)
# ===========================================================================
print("\n[2] Default fallback")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    result = run_resolver(tmp, "nightly")
    check("session_type=execution (default)", result.get("session_type") == "execution")
    check("resolution_source=default", result.get("resolution_source") == "default")

# ===========================================================================
# Test 3: Recurring slot matching — nightly, current slot ±10 min
# ===========================================================================
print("\n[3] Recurring slot matching")
now = datetime.now()
# Create a slot that matches "now" exactly
slot_str = now.strftime("%H:%M")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    schedule = make_schedule(recurring=[{
        "slot": slot_str,
        "trigger": "nightly",
        "session_type": "planning",
        "enabled": True,
    }])
    schedule_file = tmp / "config" / "session_schedule.json"
    schedule_file.write_text(json.dumps(schedule))
    result = run_resolver(tmp, "nightly")
    check("matched recurring slot", result.get("session_type") == "planning",
          f"got {result.get('session_type')!r}")
    check("resolution_source=recurring", result.get("resolution_source") == "recurring")

# ===========================================================================
# Test 4: Recurring slot — wrong trigger mode, no match
# ===========================================================================
print("\n[4] Recurring slot — trigger mode mismatch")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    slot_str = now.strftime("%H:%M")
    schedule = make_schedule(recurring=[{
        "slot": slot_str,
        "trigger": "emergency",  # won't match nightly
        "session_type": "maintenance",
        "enabled": True,
    }])
    (tmp / "config" / "session_schedule.json").write_text(json.dumps(schedule))
    result = run_resolver(tmp, "nightly")
    check("no match → default execution", result.get("session_type") == "execution")

# ===========================================================================
# Test 5: One-off entry — fires and marks fired=true
# ===========================================================================
print("\n[5] One-off entry fires and marks fired=true")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    # datetime = now (within tolerance)
    dt_str = now.strftime("%Y-%m-%dT%H:%M:%S")
    schedule = make_schedule(one_off=[{
        "datetime": dt_str,
        "trigger": "manual",
        "session_type": "philosophy",
        "label": "test one-off",
        "fired": False,
    }])
    schedule_file = tmp / "config" / "session_schedule.json"
    schedule_file.write_text(json.dumps(schedule))
    result = run_resolver(tmp, "manual")
    check("one_off matched", result.get("session_type") == "philosophy",
          f"got {result.get('session_type')!r}")
    check("resolution_source=one_off", result.get("resolution_source") == "one_off")
    # Check that fired=true was written back
    updated = json.loads(schedule_file.read_text())
    check("fired=true written back",
          updated["one_off"][0]["fired"] is True,
          f"got {updated['one_off'][0].get('fired')!r}")

# ===========================================================================
# Test 6: One-off — already fired, no match
# ===========================================================================
print("\n[6] One-off already fired — no match")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    dt_str = now.strftime("%Y-%m-%dT%H:%M:%S")
    schedule = make_schedule(one_off=[{
        "datetime": dt_str,
        "trigger": "manual",
        "session_type": "philosophy",
        "label": "already fired",
        "fired": True,  # already done
    }])
    (tmp / "config" / "session_schedule.json").write_text(json.dumps(schedule))
    result = run_resolver(tmp, "manual")
    check("no match → default execution", result.get("session_type") == "execution")

# ===========================================================================
# Test 7: YAML loading — correct type config returned
# ===========================================================================
print("\n[7] YAML type config loading")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    # Write a minimal type YAML
    (tmp / "config" / "session_types" / "maintenance.yaml").write_text(
        'id: maintenance\nname: "Maintenance Session"\nfocus_hint: "maintain the system"\n'
    )
    # No schedule file → falls through to SESSION_TYPE env var
    result = run_resolver(tmp, "nightly", extra_env={"SESSION_TYPE": "maintenance"})
    check("session_type=maintenance loaded", result.get("session_type") == "maintenance")
    check("focus_hint extracted",
          "maintain" in (result.get("focus_hint") or ""),
          f"got {result.get('focus_hint')!r}")

# ===========================================================================
# Test 8: Context assembly — files assembled correctly
# ===========================================================================
print("\n[8] Context assembly")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    (tmp / "memory").mkdir()
    (tmp / "memory" / "notes.md").write_text("hello from context")
    (tmp / "config" / "session_types" / "planning.yaml").write_text(
        'id: planning\nname: "Planning Session"\n'
        'context_files:\n  - memory/notes.md\n'
    )
    result = run_resolver(tmp, "nightly", extra_env={"SESSION_TYPE": "planning"})
    check("context assembled",
          "hello from context" in (result.get("assembled_context") or ""),
          f"got assembled_context={result.get('assembled_context', '')[:60]!r}")

# ===========================================================================
# Test 9: analytics_write.py reads CURRENT_SESSION_TYPE env var
# ===========================================================================
print("\n[9] analytics_write.py reads CURRENT_SESSION_TYPE env var")
analytics_script = PROJECT_DIR / "tools" / "analytics_write.py"
if not analytics_script.exists():
    print("  SKIP  analytics_write.py not found in this project")
else:
    # Read the script and verify the env var is read
    source = analytics_script.read_text()
    check("CURRENT_SESSION_TYPE referenced in source",
          "CURRENT_SESSION_TYPE" in source)
    check("maintenance in choices",
          "maintenance" in source)
    check("philosophy in choices",
          "philosophy" in source)

# ===========================================================================
# Test 10: Recurring slot — days field includes today → matches
# ===========================================================================
print("\n[10] Recurring slot — days field includes today")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    slot_str = now.strftime("%H:%M")
    today_abbr = now.strftime("%a")
    schedule = make_schedule(recurring=[{
        "slot": slot_str,
        "trigger": "nightly",
        "session_type": "planning",
        "enabled": True,
        "days": [today_abbr],
    }])
    (tmp / "config" / "session_schedule.json").write_text(json.dumps(schedule))
    result = run_resolver(tmp, "nightly")
    check("days includes today → matched", result.get("session_type") == "planning",
          f"got {result.get('session_type')!r}")

# ===========================================================================
# Test 11: Recurring slot — days field excludes today → falls through
# ===========================================================================
print("\n[11] Recurring slot — days field excludes today")
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    (tmp / "config" / "session_types").mkdir(parents=True)
    slot_str = now.strftime("%H:%M")
    today_abbr = now.strftime("%a")
    other_days = [d for d in ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] if d != today_abbr]
    schedule = make_schedule(recurring=[{
        "slot": slot_str,
        "trigger": "nightly",
        "session_type": "maintenance",
        "enabled": True,
        "days": other_days[:2],  # two days that are NOT today
    }])
    (tmp / "config" / "session_schedule.json").write_text(json.dumps(schedule))
    result = run_resolver(tmp, "nightly")
    check("days excludes today → default execution", result.get("session_type") == "execution",
          f"got {result.get('session_type')!r}")

# ===========================================================================
# Summary
# ===========================================================================
print(f"\n{'=' * 50}")
total = 11
if failures:
    print(f"RESULT: {len(failures)} test(s) FAILED — {', '.join(failures)}")
    sys.exit(1)
else:
    print(f"RESULT: All checks passed (҂◡_◡)")
    sys.exit(0)
