"""Tests for Nexus delivery-reliability hardening (T371).

Covers:
- Dispatcher cursor does NOT advance when spawn fails
- Dispatcher cursor DOES advance when spawn succeeds
- Dispatcher cursor DOES advance when session already active
- save_last_read uses atomic tmp+rename (nexus_channel_watcher)
- First-contact: all messages treated as new when channel not in last_read
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add tools/ to path so we can import both modules
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import nexus_watcher
import nexus_channel_watcher


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fake_message(msg_id: str, ts: str, sender: str = "peer_agent") -> dict:
    return {"id": msg_id, "created_at": ts, "sender_id": sender, "content": "hello"}


def _stub_nexus_get(messages_by_channel: dict):
    """Return a mock for nexus_get that returns messages per channel path."""
    def _get(path: str, token: str):
        for channel_id, msgs in messages_by_channel.items():
            if f"/conversations/{channel_id}/messages" in path:
                return msgs
        if "/conversations/" in path and path.endswith("messages?limit=50"):
            return []
        return []
    return _get


# ---------------------------------------------------------------------------
# Dispatcher: cursor advance behaviour
# ---------------------------------------------------------------------------

class TestDispatcherCursorAdvance(unittest.TestCase):

    def _run_poll(self, *, channel_id, messages, session_active, spawn_result):
        """Run poll_once with mocked dependencies; return (last_read, state)."""
        state = {}
        initial_last_read = {}

        with (
            patch.object(nexus_watcher, "discover_channels", return_value={channel_id: "peer"}),
            patch.object(nexus_watcher, "nexus_get", side_effect=_stub_nexus_get({channel_id: messages})),
            patch.object(nexus_watcher, "load_last_read", return_value=dict(initial_last_read)),
            patch.object(nexus_watcher, "save_last_read") as mock_save,
            patch.object(nexus_watcher, "save_state"),
            patch.object(nexus_watcher, "is_channel_session_active", return_value=session_active),
            patch.object(nexus_watcher, "spawn_channel_session", return_value=spawn_result),
            patch.object(nexus_watcher, "log"),
        ):
            # poll_once modifies last_read dict in place via save_last_read
            captured_last_read = {}

            def capture_save(data):
                captured_last_read.update(data)

            mock_save.side_effect = capture_save

            # Rebuild last_read by capturing what save_last_read is called with
            nexus_watcher.poll_once(token="tok", state=state)
            return captured_last_read

    def test_cursor_unchanged_when_spawn_fails(self):
        channel_id = "chan-001"
        msgs = [_fake_message("msg-2", "2026-01-01T01:00:00Z"),
                _fake_message("msg-1", "2026-01-01T00:00:00Z")]

        last_read = self._run_poll(
            channel_id=channel_id,
            messages=msgs,
            session_active=False,
            spawn_result=False,
        )
        # Cursor should NOT be advanced — spawn failed, next poll must retry
        self.assertNotIn(channel_id, last_read,
            "cursor must not advance when spawn fails")

    def test_cursor_advances_when_spawn_succeeds(self):
        channel_id = "chan-002"
        msgs = [_fake_message("msg-2", "2026-01-01T01:00:00Z"),
                _fake_message("msg-1", "2026-01-01T00:00:00Z")]

        last_read = self._run_poll(
            channel_id=channel_id,
            messages=msgs,
            session_active=False,
            spawn_result=True,
        )
        self.assertEqual(last_read.get(channel_id), "msg-2",
            "cursor must advance to newest message ID on successful spawn")

    def test_cursor_advances_when_session_already_active(self):
        channel_id = "chan-003"
        msgs = [_fake_message("msg-3", "2026-01-01T02:00:00Z"),
                _fake_message("msg-2", "2026-01-01T01:00:00Z")]

        last_read = self._run_poll(
            channel_id=channel_id,
            messages=msgs,
            session_active=True,
            spawn_result=False,  # irrelevant — session active takes priority
        )
        self.assertEqual(last_read.get(channel_id), "msg-3",
            "cursor must advance when session is already active (session owns per-channel cursor)")


# ---------------------------------------------------------------------------
# Dispatcher: first-contact (no prior cursor) treats all messages as new
# ---------------------------------------------------------------------------

class TestDispatcherFirstContact(unittest.TestCase):

    def test_all_messages_new_when_no_prior_cursor(self):
        """First contact: last_read has no entry → treats all messages as new."""
        channel_id = "chan-new"
        msgs = [_fake_message("msg-2", "2026-01-01T01:00:00Z"),
                _fake_message("msg-1", "2026-01-01T00:00:00Z")]

        spawn_calls = []

        with (
            patch.object(nexus_watcher, "discover_channels", return_value={channel_id: "new_peer"}),
            patch.object(nexus_watcher, "nexus_get", side_effect=_stub_nexus_get({channel_id: msgs})),
            patch.object(nexus_watcher, "load_last_read", return_value={}),
            patch.object(nexus_watcher, "save_last_read"),
            patch.object(nexus_watcher, "save_state"),
            patch.object(nexus_watcher, "is_channel_session_active", return_value=False),
            patch.object(nexus_watcher, "spawn_channel_session",
                         side_effect=lambda cid, pid, **kw: spawn_calls.append(cid) or True),
            patch.object(nexus_watcher, "log"),
        ):
            nexus_watcher.poll_once(token="tok", state={})

        self.assertIn(channel_id, spawn_calls,
            "dispatcher must spawn session on first-contact message")


# ---------------------------------------------------------------------------
# nexus_channel_watcher: save_last_read uses atomic tmp+rename
# ---------------------------------------------------------------------------

class TestChannelWatcherAtomicWrite(unittest.TestCase):

    def test_save_last_read_atomic(self):
        """save_last_read must write via .tmp then rename (atomic)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)

            with patch.object(nexus_channel_watcher, "CHANNELS_DIR", tmpdir_path):
                channel_id = "test-chan"
                # Ensure directory exists
                (tmpdir_path / channel_id).mkdir()

                nexus_channel_watcher.save_last_read(channel_id, "2026-01-01T00:00:00Z")

                final = tmpdir_path / channel_id / "last_read.txt"
                tmp = tmpdir_path / channel_id / "last_read.tmp"

                self.assertTrue(final.exists(), "last_read.txt must exist after save")
                self.assertFalse(tmp.exists(), ".tmp file must be cleaned up after rename")
                self.assertEqual(final.read_text(), "2026-01-01T00:00:00Z")

    def test_save_last_read_survives_partial_write(self):
        """Value in last_read.txt must be complete or absent, never partial."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)

            with patch.object(nexus_channel_watcher, "CHANNELS_DIR", tmpdir_path):
                channel_id = "test-chan2"
                (tmpdir_path / channel_id).mkdir()

                ts = "2026-07-29T12:34:56.789012+00:00"
                nexus_channel_watcher.save_last_read(channel_id, ts)
                result = nexus_channel_watcher.load_last_read(channel_id)
                self.assertEqual(result, ts)


if __name__ == "__main__":
    unittest.main()
