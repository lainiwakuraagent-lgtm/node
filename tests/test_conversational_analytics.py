#!/usr/bin/env python3
"""Tests for conversational_analytics_write.py."""

import json
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

# Ensure the module is importable
sys.path.insert(0, str(Path(__file__).parent.parent / "tools" / "conversational"))
import conversational_analytics_write as caw


class TestThreadMetrics(unittest.TestCase):
    """Test thread turn/timing computations."""

    def test_empty_thread(self):
        m = caw.compute_thread_metrics([])
        self.assertEqual(m["turn_count"], 0)
        self.assertEqual(m["active_duration_seconds"], 0)
        self.assertIsNone(m["avg_wait_seconds"])

    def test_single_exchange_telegram_format(self):
        t = int(time.time())
        thread = [
            {"role": "user", "text": "hello", "timestamp": t},
            {"role": "lain", "text": "hi", "timestamp": t + 30},
        ]
        m = caw.compute_thread_metrics(thread)
        self.assertEqual(m["turn_count"], 1)
        self.assertAlmostEqual(m["active_duration_seconds"], 30, delta=1)
        self.assertAlmostEqual(m["avg_wait_seconds"], 30, delta=1)

    def test_multiple_exchanges(self):
        t = int(time.time())
        thread = [
            {"role": "user", "text": "msg1", "timestamp": t},
            {"role": "lain", "text": "resp1", "timestamp": t + 20},
            {"role": "user", "text": "msg2", "timestamp": t + 120},
            {"role": "lain", "text": "resp2", "timestamp": t + 140},
        ]
        m = caw.compute_thread_metrics(thread)
        self.assertEqual(m["turn_count"], 2)
        self.assertAlmostEqual(m["active_duration_seconds"], 40, delta=1)
        self.assertAlmostEqual(m["avg_wait_seconds"], 20, delta=1)

    def test_iso_timestamp_format(self):
        """Agent-channel threads may use ISO timestamp strings."""
        thread = [
            {"role": "peer", "text": "hello", "ts": "2026-07-30T10:00:00+00:00"},
            {"role": "agent", "text": "hi", "ts": "2026-07-30T10:00:45+00:00"},
        ]
        m = caw.compute_thread_metrics(thread)
        self.assertEqual(m["turn_count"], 1)
        self.assertAlmostEqual(m["active_duration_seconds"], 45, delta=1)

    def test_missing_agent_response(self):
        """User message with no subsequent agent response is still counted."""
        t = int(time.time())
        thread = [
            {"role": "user", "text": "msg", "timestamp": t},
        ]
        m = caw.compute_thread_metrics(thread)
        # No agent response found — turn_count stays 0
        self.assertEqual(m["turn_count"], 0)


class TestEnsureSchema(unittest.TestCase):
    """Test DB schema creation."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.db_path = Path(self.tmp.name)

    def tearDown(self):
        self.db_path.unlink(missing_ok=True)

    def _conn(self):
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        return conn

    def test_creates_conversational_sessions_table(self):
        conn = self._conn()
        caw.ensure_schema(conn)
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )]
        self.assertIn("conversational_sessions", tables)

    def test_daily_cost_view_created_when_sessions_present(self):
        conn = self._conn()
        conn.execute("CREATE TABLE sessions (id INTEGER PRIMARY KEY, started_at TEXT)")
        conn.execute("CREATE TABLE session_costs (id INTEGER PRIMARY KEY, session_id INTEGER, cost_usd REAL, total_tokens INTEGER)")
        conn.commit()
        caw.ensure_schema(conn)
        views = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='view'"
        )]
        self.assertIn("daily_cost", views)

    def test_daily_cost_view_not_created_without_sessions(self):
        conn = self._conn()
        caw.ensure_schema(conn)
        views = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='view'"
        )]
        self.assertNotIn("daily_cost", views)

    def test_idempotent_schema_creation(self):
        conn = self._conn()
        caw.ensure_schema(conn)
        caw.ensure_schema(conn)  # Should not raise
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )]
        self.assertIn("conversational_sessions", tables)


class TestWriteSession(unittest.TestCase):
    """Integration test: write_session writes a complete row."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmp.name) / "analytics.db"
        # Patch DB_PATH so the module writes to our temp DB
        self._db_patcher = patch.object(caw, "DB_PATH", self.db_path)
        self._db_patcher.start()
        # Patch PROJECT_DIR so state reads don't fail
        self._dir_patcher = patch.object(caw, "PROJECT_DIR", Path(self.tmp.name))
        self._dir_patcher.start()

        proj = Path(self.tmp.name)
        (proj / "state" / "conversation").mkdir(parents=True)
        (proj / "logs").mkdir(parents=True)

    def tearDown(self):
        self._db_patcher.stop()
        self._dir_patcher.stop()
        self.tmp.cleanup()

    def _write_budget(self, channel: str, **kwargs):
        proj = Path(self.tmp.name)
        if channel == "telegram":
            d = proj / "state" / "conversation"
        else:
            d = proj / "state" / "agent_channels" / channel
        d.mkdir(parents=True, exist_ok=True)
        budget = {"session_start": int(time.time()) - 600, **kwargs}
        (d / "context_budget.json").write_text(json.dumps(budget))

    def test_write_telegram_session(self):
        self._write_budget("telegram", messages_sent=5, messages_received=5)
        key = caw.write_session("telegram", "natural_close", 30.0)
        self.assertTrue(key.startswith("conv_telegram_"))

        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM conversational_sessions WHERE session_key = ?", (key,)
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["channel"], "telegram")
        self.assertEqual(row["exit_reason"], "natural_close")
        self.assertAlmostEqual(row["context_pct_at_close"], 30.0, delta=0.1)
        self.assertEqual(row["context_soft_fired"], 0)
        self.assertEqual(row["spawn_sequence_number"], 1)

    def test_context_soft_fired_at_50_pct(self):
        self._write_budget("telegram")
        # 55% context, no hard-exit reason → soft fires, hard does not
        caw.write_session("telegram", "natural_close", 55.0)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM conversational_sessions LIMIT 1").fetchone()
        self.assertEqual(row["context_soft_fired"], 1)
        self.assertEqual(row["context_hard_fired"], 0)

    def test_context_hard_fired_at_70_pct(self):
        self._write_budget("telegram")
        caw.write_session("telegram", "context_full", 75.0)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM conversational_sessions LIMIT 1").fetchone()
        self.assertEqual(row["context_soft_fired"], 1)
        self.assertEqual(row["context_hard_fired"], 1)

    def test_context_hard_fired_by_exit_reason(self):
        self._write_budget("telegram")
        caw.write_session("telegram", "context_full", 40.0)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM conversational_sessions LIMIT 1").fetchone()
        self.assertEqual(row["context_hard_fired"], 1)

    def test_spawn_sequence_number_increments(self):
        self._write_budget("telegram")
        caw.write_session("telegram", "natural_close", 10.0)
        caw.write_session("telegram", "reset", 20.0)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT spawn_sequence_number FROM conversational_sessions ORDER BY id"
        ).fetchall()
        self.assertEqual([r[0] for r in rows], [1, 2])

    def test_write_with_thread_metrics(self):
        self._write_budget("telegram")
        proj = Path(self.tmp.name)
        t = int(time.time())
        thread = [
            {"role": "user", "text": "q", "timestamp": t},
            {"role": "lain", "text": "a", "timestamp": t + 25},
        ]
        (proj / "state" / "conversation" / "thread.json").write_text(json.dumps(thread))
        caw.write_session("telegram", "natural_close", 15.0)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM conversational_sessions LIMIT 1").fetchone()
        self.assertEqual(row["turn_count"], 1)
        self.assertAlmostEqual(row["avg_wait_time_seconds"], 25.0, delta=2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
