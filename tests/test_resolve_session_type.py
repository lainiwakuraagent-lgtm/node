#!/usr/bin/env python3
"""
Unit tests for resolve_session_type.py inbox trigger logic and the
goal/project/task dispatch rules in _check_queue_state().

Run: python3 tests/test_resolve_session_type.py
"""

import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

# Add scripts/executional/ to path so we can import the module directly.
# (Was "scripts/" before the T330 conversational/executional subdir split --
# left the import silently broken, since the module moved but this didn't.)
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts" / "executional"))
from resolve_session_type import (  # noqa: E402
    _cap_is_stale,
    _check_queue_state,
    _clear_philosophy_cap,
    _days_since_last_maintenance,
    _fetch_target_context,
    _inbox_has_pending_tasks,
    _read_cap_active_timestamp,
    _read_default_goal_id,
    load_type_config,
    resolve_type,
)


def _seed_recent_maintenance(project_dir: Path) -> None:
    """Write a session_log.csv with a maintenance entry from ~now.
    Tests that check philosophy-as-fallback need recent maintenance so
    Priority 3c doesn't preempt the philosophy default.
    """
    logs_dir = project_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    (logs_dir / "session_log.csv").write_text(
        f"{ts},maintenance,5,10,recent maintenance seed for test\n",
        encoding="utf-8",
    )


def _make_scratch_db(db_path: Path) -> sqlite3.Connection:
    """Minimal goals/projects/tasks schema covering exactly the columns
    _check_queue_state()'s queries reference. Self-contained (no dependency
    on the loom package), matching this script's own self-contained style.
    """
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        CREATE TABLE goals (
            id INTEGER PRIMARY KEY,
            name TEXT, status TEXT, priority INTEGER DEFAULT 0,
            blocked_reason TEXT, description TEXT, updated_at TEXT
        );
        CREATE TABLE projects (
            id INTEGER PRIMARY KEY,
            name TEXT, status TEXT, priority INTEGER DEFAULT 0,
            blocked_reason TEXT, description TEXT, goal_id INTEGER, updated_at TEXT
        );
        CREATE TABLE tasks (
            id INTEGER PRIMARY KEY,
            name TEXT, status TEXT, depends TEXT, tags TEXT,
            goal_id INTEGER, project_id INTEGER,
            blocked_reason TEXT, wait_until TEXT, urgency_score REAL DEFAULT 0,
            priority TEXT DEFAULT 'none', updated_at TEXT
        );
        """
    )
    conn.commit()
    return conn


class TestCheckQueueStateWidenedRules(unittest.TestCase):
    """Rules 1-3 widened to cover goals/projects alongside tasks, with
    goal-before-project-before-task ordering when a rule matches at
    multiple levels simultaneously.
    """

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmpdir.name) / "scratch.db"
        self.conn = _make_scratch_db(self.db_path)

    def tearDown(self):
        self.conn.close()
        self.tmpdir.cleanup()

    def test_rule1_goal_desire_beats_project_desire(self):
        self.conn.execute("INSERT INTO goals (id, name, status, priority) VALUES (1, 'G', 'desire', 1)")
        self.conn.execute("INSERT INTO projects (id, name, status, priority) VALUES (1, 'P', 'desire', 99)")
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertEqual(session_type, "evaluation")
        self.assertEqual(target, {"level": "goal", "id": 1})

    def test_rule1_project_desire_matches_when_no_goal_desire(self):
        self.conn.execute("INSERT INTO projects (id, name, status, priority) VALUES (1, 'P', 'desire', 1)")
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertEqual(session_type, "evaluation")
        self.assertEqual(target, {"level": "project", "id": 1})

    def test_rule1_blocked_goal_desire_skipped(self):
        self.conn.execute(
            "INSERT INTO goals (id, name, status, priority, blocked_reason) "
            "VALUES (1, 'G', 'desire', 1, 'blocked_owner')"
        )
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertNotEqual(session_type, "evaluation")

    def test_rule2_goal_needs_plan_beats_project_and_task(self):
        self.conn.execute("INSERT INTO goals (id, name, status, priority) VALUES (1, 'G', 'needs_plan', 1)")
        self.conn.execute("INSERT INTO projects (id, name, status, priority) VALUES (1, 'P', 'needs_plan', 1)")
        self.conn.execute("INSERT INTO tasks (id, name, status) VALUES (1, 'T', 'needs_plan')")
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertEqual(session_type, "planning")
        self.assertEqual(target, {"level": "goal", "id": 1})

    def test_rule2_task_needs_plan_still_respects_dep_gating(self):
        """Pre-existing behavior preserved: a task with an undone dependency is skipped."""
        self.conn.execute("INSERT INTO tasks (id, name, status) VALUES (1, 'Blocker', 'in_progress')")
        self.conn.execute(
            "INSERT INTO tasks (id, name, status, depends) VALUES (2, 'Blocked', 'needs_plan', '[1]')"
        )
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertNotEqual(session_type, "planning")

    def test_rule3_goal_review_beats_task_milestone_review(self):
        self.conn.execute("INSERT INTO goals (id, name, status, priority) VALUES (1, 'G', 'review', 1)")
        self.conn.execute(
            "INSERT INTO tasks (id, name, status, tags) VALUES (1, 'T', 'scheduled', 'milestone_review')"
        )
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertEqual(session_type, "audit")
        self.assertEqual(target, {"level": "goal", "id": 1})

    def test_rule4_execution_stays_task_only(self):
        """A goal/project sitting in scheduled/in_progress must not trigger
        anything by itself — Rule 4 has no goal/project equivalent."""
        self.conn.execute("INSERT INTO goals (id, name, status, priority) VALUES (1, 'G', 'scheduled', 1)")
        self.conn.execute(
            "INSERT INTO tasks (id, name, status) VALUES (1, 'T', 'scheduled')"
        )
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertEqual(session_type, "execution")
        self.assertEqual(target, {"level": "task", "id": 1})

    def test_priority_tiebreak_lower_id_wins_within_a_level(self):
        self.conn.execute("INSERT INTO goals (id, name, status, priority) VALUES (2, 'Second', 'desire', 5)")
        self.conn.execute("INSERT INTO goals (id, name, status, priority) VALUES (1, 'First', 'desire', 5)")
        self.conn.commit()
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertEqual(target, {"level": "goal", "id": 1})

    def test_empty_db_falls_through(self):
        session_type, reason, target = _check_queue_state(self.conn)
        self.assertIsNone(session_type)
        self.assertIsNone(target)


class TestFetchTargetContext(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmpdir.name) / "scratch.db"
        conn = _make_scratch_db(self.db_path)
        conn.execute(
            "INSERT INTO goals (id, name, status, priority, description) "
            "VALUES (1, 'Goal A', 'desire', 3, 'Why this matters')"
        )
        conn.commit()
        conn.close()

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_goal_target_returns_formatted_detail(self):
        text = _fetch_target_context(self.db_path, {"level": "goal", "id": 1})
        self.assertIn("Goal A", text)
        self.assertIn("Why this matters", text)

    def test_task_level_target_returns_empty(self):
        text = _fetch_target_context(self.db_path, {"level": "task", "id": 1})
        self.assertEqual(text, "")

    def test_no_target_returns_empty(self):
        self.assertEqual(_fetch_target_context(self.db_path, None), "")

    def test_unknown_id_returns_empty(self):
        text = _fetch_target_context(self.db_path, {"level": "goal", "id": 999})
        self.assertEqual(text, "")


class TestReadDefaultGoalId(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        (self.project_dir / "state").mkdir(parents=True)
        self.config_path = self.project_dir / "state" / "agent_config.env"

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_no_config_file_returns_none(self):
        self.assertIsNone(_read_default_goal_id(self.project_dir))

    def test_unset_returns_none(self):
        self.config_path.write_text("AGENT_NAME=lain\n", encoding="utf-8")
        self.assertIsNone(_read_default_goal_id(self.project_dir))

    def test_reads_configured_value(self):
        self.config_path.write_text("AGENT_NAME=lain\nDEFAULT_GOAL_ID=7\n", encoding="utf-8")
        self.assertEqual(_read_default_goal_id(self.project_dir), 7)

    def test_ignores_commented_line(self):
        self.config_path.write_text("# DEFAULT_GOAL_ID=7\n", encoding="utf-8")
        self.assertIsNone(_read_default_goal_id(self.project_dir))

    def test_empty_value_returns_none(self):
        self.config_path.write_text("DEFAULT_GOAL_ID=\n", encoding="utf-8")
        self.assertIsNone(_read_default_goal_id(self.project_dir))

    def test_non_integer_value_returns_none(self):
        self.config_path.write_text("DEFAULT_GOAL_ID=notanumber\n", encoding="utf-8")
        self.assertIsNone(_read_default_goal_id(self.project_dir))


class TestResolveTypeDefaultGoalFallback(unittest.TestCase):
    """Priority 4 (empty queue) attaches the configured default goal as target,
    on top of the existing philosophy sub-mode selection — no new session type.
    """

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        (self.project_dir / "state").mkdir(parents=True)
        (self.project_dir / "inbox").mkdir(parents=True)
        (self.project_dir / "inbox" / "pending.json").write_text("[]", encoding="utf-8")
        self.fake_db = self.project_dir / "nonexistent.db"
        # Seed recent maintenance so Priority 3c doesn't preempt philosophy tests.
        _seed_recent_maintenance(self.project_dir)

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_default_goal_attached_when_configured(self):
        (self.project_dir / "state" / "agent_config.env").write_text(
            "DEFAULT_GOAL_ID=3\n", encoding="utf-8"
        )
        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy")
        self.assertEqual(target, {"level": "goal", "id": 3})

    def test_no_target_when_not_configured(self):
        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy")
        self.assertIsNone(target)

    def test_target_still_attached_at_philosophy_cap(self):
        (self.project_dir / "state" / "agent_config.env").write_text(
            "DEFAULT_GOAL_ID=3\n", encoding="utf-8"
        )
        (self.project_dir / "state" / "consecutive_philosophy.count").write_text("3", encoding="utf-8")
        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy_cap")
        self.assertEqual(target, {"level": "goal", "id": 3})


class TestInboxHasPendingTasks(unittest.TestCase):
    """Unit tests for _inbox_has_pending_tasks()."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.inbox_dir = self.project_dir / "inbox"
        self.inbox_dir.mkdir(parents=True)
        self.inbox_path = self.inbox_dir / "pending.json"

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write_inbox(self, entries):
        self.inbox_path.write_text(json.dumps(entries), encoding="utf-8")

    def test_empty_inbox_returns_false(self):
        self._write_inbox([])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_no_inbox_file_returns_false(self):
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_request_kind_task_unprocessed_returns_true(self):
        self._write_inbox([
            {"type": "request", "kind": "task", "processed": False, "content": "do X"}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_request_kind_bug_unprocessed_returns_true(self):
        self._write_inbox([
            {"type": "request", "kind": "bug", "processed": False, "content": "Y is broken"}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_comment_unprocessed_returns_true(self):
        """KEY TEST: comment must trigger execution (T233 fix, carried into the
        2026-08-01 inbox redesign — task_comment renamed to comment)."""
        self._write_inbox([
            {"type": "comment", "target_type": "task", "target_id": 231, "processed": False,
             "content": "dig deeper into scope design"}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_comment_already_processed_returns_false(self):
        """Processed comment must not trigger re-execution."""
        self._write_inbox([
            {"type": "comment", "target_type": "task", "target_id": 231, "processed": True,
             "content": "dig deeper into scope design"}
        ])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_context_update_does_not_trigger_execution(self):
        """context_update is auto-tier (inbox.py applies it directly) — should not force execution."""
        self._write_inbox([
            {"type": "context_update", "processed": False, "content": "repo link: ..."}
        ])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_request_kind_idea_now_triggers(self):
        """Redesign change: idea is now request(kind=idea), and ALL request
        kinds are judgment-tier — an idea sitting unrouted should be as
        visible to the dispatcher as a task, not silently invisible forever
        the way pre-redesign `idea` entries were."""
        self._write_inbox([
            {"type": "request", "kind": "idea", "processed": False, "content": "what if we..."}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_mixed_all_processed_returns_false(self):
        """All processed entries — should return false."""
        self._write_inbox([
            {"type": "comment", "processed": True},
            {"type": "request", "kind": "task", "processed": True},
            {"type": "request", "kind": "bug", "processed": True},
        ])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_mixed_one_unprocessed_comment_returns_true(self):
        """One unprocessed comment among processed/auto-tier entries — must trigger."""
        self._write_inbox([
            {"type": "context_update", "processed": False},
            {"type": "request", "kind": "task", "processed": True},
            {"type": "comment", "target_type": "task", "target_id": 231, "processed": False},
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_entry_missing_processed_field_treated_as_unprocessed(self):
        """Entries without 'processed' field default to False (unprocessed)."""
        self._write_inbox([
            {"type": "comment", "target_type": "task", "target_id": 231}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))


class TestResolveTypeInboxFallback(unittest.TestCase):
    """
    Regression tests for resolve_type() inbox fallback (Priority 3b).
    Uses a non-existent Loom DB to ensure queue_state returns None,
    so the inbox check is the deciding factor.
    """

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.inbox_dir = self.project_dir / "inbox"
        self.inbox_dir.mkdir(parents=True)
        self.inbox_path = self.inbox_dir / "pending.json"
        # Non-existent DB → queue_state returns (None, None) → falls through to inbox check
        self.fake_db = Path(self.tmpdir.name) / "nonexistent.db"
        # Seed recent maintenance so Priority 3c doesn't preempt inbox/philosophy tests.
        _seed_recent_maintenance(self.project_dir)

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write_inbox(self, entries):
        self.inbox_path.write_text(json.dumps(entries), encoding="utf-8")

    def test_empty_queue_and_empty_inbox_resolves_to_philosophy(self):
        """Regression: empty inbox + empty Loom queue → philosophy."""
        self._write_inbox([])
        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy")
        self.assertEqual(source, "default")

    def test_empty_queue_with_comment_resolves_to_planning(self):
        """KEY TEST: unprocessed comment in inbox → planning (T456).
        inbox.py no longer auto-converts request/comment to Loom tasks;
        that judgment belongs to planning, not execution."""
        self._write_inbox([
            {"type": "comment", "target_type": "task", "target_id": 231, "processed": False,
             "content": "expand the maintenance plan"}
        ])
        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "planning")
        self.assertEqual(source, "inbox_pending")

    def test_processed_comment_still_resolves_to_philosophy(self):
        """Processed comments must not loop-trigger execution."""
        self._write_inbox([
            {"type": "comment", "target_type": "task", "target_id": 231, "processed": True}
        ])
        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy")

    def test_session_type_env_var_wins_over_inbox(self):
        """Priority 1: SESSION_TYPE env var must override inbox trigger."""
        import os
        self._write_inbox([
            {"type": "comment", "target_type": "task", "target_id": 231, "processed": False}
        ])
        orig = os.environ.get("SESSION_TYPE")
        try:
            os.environ["SESSION_TYPE"] = "maintenance"
            session_type, source, _, target = resolve_type(self.project_dir, "nightly", self.fake_db)
            self.assertEqual(session_type, "maintenance")
            self.assertEqual(source, "env_var")
        finally:
            if orig is None:
                os.environ.pop("SESSION_TYPE", None)
            else:
                os.environ["SESSION_TYPE"] = orig


class TestMaintenanceFallback(unittest.TestCase):
    """Tests for Priority 3c: maintenance fires when overdue and queue is empty."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        (self.project_dir / "inbox").mkdir(parents=True)
        (self.project_dir / "state").mkdir(parents=True)
        (self.project_dir / "logs").mkdir(parents=True)
        self.fake_db = Path(self.tmpdir.name) / "nonexistent.db"

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_no_maintenance_log_triggers_maintenance(self):
        """No session_log.csv → maintenance is infinitely overdue → fires."""
        session_type, source, reason, _ = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "maintenance")
        self.assertIn("overdue", reason)

    def test_recent_maintenance_allows_philosophy(self):
        """Recent maintenance entry → not overdue → philosophy instead."""
        _seed_recent_maintenance(self.project_dir)
        session_type, source, reason, _ = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy")

    def test_days_since_last_maintenance_with_no_log(self):
        """_days_since_last_maintenance returns 999 when no log file."""
        days = _days_since_last_maintenance(self.project_dir)
        self.assertEqual(days, 999.0)

    def test_days_since_last_maintenance_with_recent_entry(self):
        """_days_since_last_maintenance returns < 1 for a log seeded now."""
        _seed_recent_maintenance(self.project_dir)
        days = _days_since_last_maintenance(self.project_dir)
        self.assertLess(days, 1.0)


class TestPhilosophyTierResolution(unittest.TestCase):
    """Priority 4: all three ladder rungs resolve to the single "philosophy"
    id now (tier carried in consecutive_philosophy_count, not forked into
    separate type ids like the old creative/blocker_resolver split)."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        (self.project_dir / "state").mkdir(parents=True)
        (self.project_dir / "inbox").mkdir(parents=True)
        (self.project_dir / "inbox" / "pending.json").write_text("[]", encoding="utf-8")
        self.fake_db = self.project_dir / "nonexistent.db"
        _seed_recent_maintenance(self.project_dir)

    def tearDown(self):
        self.tmpdir.cleanup()

    def _resolve_at(self, consec):
        (self.project_dir / "state" / "consecutive_philosophy.count").write_text(
            str(consec), encoding="utf-8"
        )
        return resolve_type(self.project_dir, "nightly", self.fake_db)

    def test_tier1_at_consec_zero(self):
        session_type, source, reason, _ = self._resolve_at(0)
        self.assertEqual(session_type, "philosophy")
        self.assertIn("tier 1", reason)

    def test_tier2_at_consec_one(self):
        session_type, source, reason, _ = self._resolve_at(1)
        self.assertEqual(session_type, "philosophy")
        self.assertIn("tier 2", reason)

    def test_tier3_at_consec_two(self):
        session_type, source, reason, _ = self._resolve_at(2)
        self.assertEqual(session_type, "philosophy")
        self.assertIn("tier 3", reason)

    def test_cap_at_consec_three_with_no_prior_cap_file(self):
        """First time hitting the cap (no philosophy_cap.active yet) still
        returns philosophy_cap unconditionally -- staleness only applies to
        an *already active* cap."""
        session_type, source, reason, _ = self._resolve_at(3)
        self.assertEqual(session_type, "philosophy_cap")


class TestLoadTypeConfigPhilosophyScope(unittest.TestCase):
    """load_type_config()'s philosophy scope-merge branch, mirroring the
    existing maintenance scope-rotation branch. Uses an isolated fixture
    (not the real repo's config/) so this doesn't depend on -- or get
    perturbed by -- live state/consecutive_philosophy.count."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        (self.project_dir / "state").mkdir(parents=True)
        types_dir = self.project_dir / "config" / "session_types"
        types_dir.mkdir(parents=True)
        (types_dir / "philosophy.yaml").write_text(
            "prompt_file: \"prompts/session_types/philosophy_prompt.md\"\n"
            "scope_selection: consecutive_philosophy_count\n"
            "scope_count_file: \"state/consecutive_philosophy.count\"\n"
            "context_files:\n  - memory/latest_summary.md\n",
            encoding="utf-8",
        )
        for n, name, slug in ((1, "Wonder & Identity", "wonder"),
                               (2, "Creative Expression", "creative"),
                               (3, "Blocker Resolution", "blocker")):
            (types_dir / f"philosophy_scope{n}.yaml").write_text(
                f"scope_id: {n}\nscope_name: \"{name}\"\nscope_slug: {slug}\n"
                f"context_files:\n  - memory/tier{n}.md\n"
                f"focus_hint: >\n  Tier {n} focus.\n",
                encoding="utf-8",
            )

    def tearDown(self):
        self.tmpdir.cleanup()

    def _config_at(self, consec):
        (self.project_dir / "state" / "consecutive_philosophy.count").write_text(
            str(consec), encoding="utf-8"
        )
        return load_type_config(self.project_dir, "philosophy", target=None)

    def test_tier1_merges_scope1(self):
        config = self._config_at(0)
        self.assertEqual(config["scope_id"], 1)
        self.assertEqual(config["scope_slug"], "wonder")
        self.assertIn("memory/tier1.md", config["context_files"])

    def test_tier2_merges_scope2(self):
        config = self._config_at(1)
        self.assertEqual(config["scope_id"], 2)
        self.assertEqual(config["scope_slug"], "creative")

    def test_tier3_merges_scope3(self):
        config = self._config_at(2)
        self.assertEqual(config["scope_id"], 3)
        self.assertEqual(config["scope_slug"], "blocker")

    def test_missing_count_file_defaults_to_tier1(self):
        config = load_type_config(self.project_dir, "philosophy", target=None)
        self.assertEqual(config["scope_id"], 1)


class TestPhilosophyCapStaleness(unittest.TestCase):
    """Priority 2.5: an already-active cap clears when something genuinely
    new happened since it was set (Loom or inbox), and stays put otherwise
    -- including the anti-gaming case where the only activity predates the
    cap itself (e.g. a task the blocker-resolution session that hit the cap
    created)."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        (self.project_dir / "state").mkdir(parents=True)
        (self.project_dir / "inbox").mkdir(parents=True)
        (self.project_dir / "inbox" / "pending.json").write_text("[]", encoding="utf-8")
        self.db_path = self.project_dir / "scratch.db"
        self.conn = _make_scratch_db(self.db_path)
        (self.project_dir / "state" / "consecutive_philosophy.count").write_text(
            "3", encoding="utf-8"
        )
        _seed_recent_maintenance(self.project_dir)
        self.cap_ts = 1_700_000_000  # arbitrary fixed epoch, well in the past
        (self.project_dir / "state" / "philosophy_cap.active").write_text(
            str(self.cap_ts), encoding="utf-8"
        )

    def tearDown(self):
        self.conn.close()
        self.tmpdir.cleanup()

    def _iso(self, epoch_offset):
        dt = datetime.fromtimestamp(self.cap_ts + epoch_offset, tz=timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_loom_activity_after_cap_clears_it(self):
        self.conn.execute(
            "INSERT INTO tasks (id, name, status, updated_at) VALUES (1, 'T', 'scheduled', ?)",
            (self._iso(+3600),),
        )
        self.conn.commit()
        self.assertTrue(_cap_is_stale(self.project_dir, self.db_path, self.cap_ts))

        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.db_path)
        self.assertNotEqual(session_type, "philosophy_cap")
        self.assertEqual(
            (self.project_dir / "state" / "consecutive_philosophy.count").read_text().strip(), "0"
        )
        self.assertFalse((self.project_dir / "state" / "philosophy_cap.active").exists())

    def test_loom_activity_only_before_cap_does_not_clear_it(self):
        """Anti-gaming case: a task updated *before* the cap was set (e.g. by
        the blocker-resolution session that pushed the counter to 3 in the
        first place) must not be able to clear its own cap."""
        self.conn.execute(
            "INSERT INTO tasks (id, name, status, updated_at) VALUES (1, 'T', 'scheduled', ?)",
            (self._iso(-3600),),
        )
        self.conn.commit()
        self.assertFalse(_cap_is_stale(self.project_dir, self.db_path, self.cap_ts))

        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.db_path)
        self.assertEqual(session_type, "philosophy_cap")

    def test_inbox_activity_after_cap_clears_it(self):
        (self.project_dir / "inbox" / "pending.json").write_text(
            json.dumps([{"type": "comment", "processed": False,
                         "timestamp": self.cap_ts + 3600}]),
            encoding="utf-8",
        )
        self.assertTrue(_cap_is_stale(self.project_dir, self.db_path, self.cap_ts))

    def test_inbox_activity_only_before_cap_does_not_clear_it(self):
        (self.project_dir / "inbox" / "pending.json").write_text(
            json.dumps([{"type": "comment", "processed": False,
                         "timestamp": self.cap_ts - 3600}]),
            encoding="utf-8",
        )
        self.assertFalse(_cap_is_stale(self.project_dir, self.db_path, self.cap_ts))

    def test_no_activity_at_all_keeps_cap(self):
        self.assertFalse(_cap_is_stale(self.project_dir, self.db_path, self.cap_ts))
        session_type, source, reason, target = resolve_type(self.project_dir, "nightly", self.db_path)
        self.assertEqual(session_type, "philosophy_cap")

    def test_clear_philosophy_cap_removes_files_and_resets_count(self):
        notified_file = self.project_dir / "state" / "philosophy_cap_notified_at.txt"
        notified_file.write_text(str(self.cap_ts), encoding="utf-8")
        _clear_philosophy_cap(self.project_dir)
        self.assertFalse((self.project_dir / "state" / "philosophy_cap.active").exists())
        self.assertFalse(notified_file.exists())
        self.assertEqual(
            (self.project_dir / "state" / "consecutive_philosophy.count").read_text().strip(), "0"
        )

    def test_read_cap_active_timestamp_missing_file_returns_none(self):
        (self.project_dir / "state" / "philosophy_cap.active").unlink()
        self.assertIsNone(_read_cap_active_timestamp(self.project_dir))

    def test_read_cap_active_timestamp_reads_value(self):
        self.assertEqual(_read_cap_active_timestamp(self.project_dir), float(self.cap_ts))


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False)
    sys.exit(0 if result.result.wasSuccessful() else 1)
