#!/usr/bin/env python3
"""
Unit tests for resolve_session_type.py inbox trigger logic.

Tests the _inbox_has_pending_tasks() function and the resolve_type()
function's inbox fallback behavior (Priority 3b).

Run: python3 tests/test_resolve_session_type.py
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

# Add scripts/ to path so we can import the module directly
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
from resolve_session_type import _inbox_has_pending_tasks, resolve_type  # noqa: E402


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

    def test_task_request_unprocessed_returns_true(self):
        self._write_inbox([
            {"type": "task_request", "processed": False, "content": "do X"}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_bug_report_unprocessed_returns_true(self):
        self._write_inbox([
            {"type": "bug_report", "processed": False, "content": "Y is broken"}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_task_comment_unprocessed_returns_true(self):
        """KEY TEST: task_comment must now trigger execution (T233 fix)."""
        self._write_inbox([
            {"type": "task_comment", "task_id": 231, "processed": False,
             "text": "dig deeper into scope design"}
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_task_comment_already_processed_returns_false(self):
        """Processed task_comment must not trigger re-execution."""
        self._write_inbox([
            {"type": "task_comment", "task_id": 231, "processed": True,
             "text": "dig deeper into scope design"}
        ])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_context_update_does_not_trigger_execution(self):
        """context_update is informational — should not force execution."""
        self._write_inbox([
            {"type": "context_update", "processed": False, "content": "repo link: ..."}
        ])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_idea_does_not_trigger_execution(self):
        """idea entries are optional — should not force execution."""
        self._write_inbox([
            {"type": "idea", "processed": False, "content": "what if we..."}
        ])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_mixed_all_processed_returns_false(self):
        """All processed entries — should return false."""
        self._write_inbox([
            {"type": "task_comment", "processed": True},
            {"type": "task_request", "processed": True},
            {"type": "bug_report", "processed": True},
        ])
        self.assertFalse(_inbox_has_pending_tasks(self.project_dir))

    def test_mixed_one_unprocessed_task_comment_returns_true(self):
        """One unprocessed task_comment among processed entries — must trigger."""
        self._write_inbox([
            {"type": "context_update", "processed": False},
            {"type": "task_request", "processed": True},
            {"type": "task_comment", "task_id": 231, "processed": False},
        ])
        self.assertTrue(_inbox_has_pending_tasks(self.project_dir))

    def test_entry_missing_processed_field_treated_as_unprocessed(self):
        """Entries without 'processed' field default to False (unprocessed)."""
        self._write_inbox([
            {"type": "task_comment", "task_id": 231}
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

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write_inbox(self, entries):
        self.inbox_path.write_text(json.dumps(entries), encoding="utf-8")

    def test_empty_queue_and_empty_inbox_resolves_to_philosophy(self):
        """Regression: empty inbox + empty Loom queue → philosophy."""
        self._write_inbox([])
        session_type, source, reason = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy")
        self.assertEqual(source, "default")

    def test_empty_queue_with_task_comment_resolves_to_execution(self):
        """KEY TEST: task_comment in inbox overrides philosophy default."""
        self._write_inbox([
            {"type": "task_comment", "task_id": 231, "processed": False,
             "text": "expand the maintenance plan"}
        ])
        session_type, source, reason = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "execution")
        self.assertEqual(source, "inbox_pending")

    def test_processed_task_comment_still_resolves_to_philosophy(self):
        """Processed comments must not loop-trigger execution."""
        self._write_inbox([
            {"type": "task_comment", "task_id": 231, "processed": True}
        ])
        session_type, source, reason = resolve_type(self.project_dir, "nightly", self.fake_db)
        self.assertEqual(session_type, "philosophy")

    def test_session_type_env_var_wins_over_inbox(self):
        """Priority 1: SESSION_TYPE env var must override inbox trigger."""
        import os
        self._write_inbox([
            {"type": "task_comment", "task_id": 231, "processed": False}
        ])
        orig = os.environ.get("SESSION_TYPE")
        try:
            os.environ["SESSION_TYPE"] = "maintenance"
            session_type, source, _ = resolve_type(self.project_dir, "nightly", self.fake_db)
            self.assertEqual(session_type, "maintenance")
            self.assertEqual(source, "env_var")
        finally:
            if orig is None:
                os.environ.pop("SESSION_TYPE", None)
            else:
                os.environ["SESSION_TYPE"] = orig


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False)
    sys.exit(0 if result.result.wasSuccessful() else 1)
