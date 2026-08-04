"""
Generic Honcho client for blank_node agents.

Configuration is read from the environment (wake.sh sources state/agent_config.env
before sessions start) or from state/agent_config.env directly for standalone use.

Required env vars:
  HONCHO_URL          — base URL of the Honcho server (e.g. http://100.78.161.59:8100)
  HONCHO_WORKSPACE    — workspace ID (e.g. my-agent-workspace)

Optional env vars:
  HONCHO_AUTH_TOKEN   — Bearer token, if AUTH_USE_AUTH is enabled on the server.
                        Omit (or leave empty) if the server runs with auth disabled.

If HONCHO_URL is unset or empty, every function no-ops silently — Honcho is optional,
not every clone will have one configured.

All calls are fire-and-forget: exceptions are logged to logs/wake.log, never raised.

API version: v3
Endpoints:
  POST   /v3/workspaces
  POST   /v3/workspaces/{ws}/peers
  GET    /v3/workspaces/{ws}/peers/{peer}/context
  POST   /v3/workspaces/{ws}/sessions
  POST   /v3/workspaces/{ws}/sessions/{sid}/peers
  POST   /v3/workspaces/{ws}/sessions/{sid}/messages
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Config — resolved once at import time
# ---------------------------------------------------------------------------

def _load_env_file() -> dict:
    """Read key=value pairs from state/agent_config.env relative to project root."""
    script_dir = Path(__file__).resolve().parent
    env_path = script_dir.parent.parent / "state" / "agent_config.env"
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
    """Read from os.environ first; fall through to agent_config.env file."""
    val = os.environ.get(key, "")
    if val:
        return val
    _file_env = _load_env_file()
    return _file_env.get(key, fallback)


HONCHO_BASE: str = _get_cfg("HONCHO_URL")
WORKSPACE: str = _get_cfg("HONCHO_WORKSPACE")
AUTH_TOKEN: str = _get_cfg("HONCHO_AUTH_TOKEN")

MAX_CONTEXT_CHARS = 1600  # ~400 tokens


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _enabled() -> bool:
    return bool(HONCHO_BASE)


def _log(msg: str) -> None:
    script_dir = Path(__file__).resolve().parent
    log_path = script_dir.parent.parent / "logs" / "wake.log"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(log_path, "a") as f:
            f.write(f"[{ts}] honcho_client.py: {msg}\n")
    except OSError:
        pass


def _request(
    method: str,
    path: str,
    body: dict | None = None,
    timeout: int = 10,
) -> dict | list | None:
    if not _enabled():
        return None
    url = f"{HONCHO_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers: dict = {}
    if data:
        headers["Content-Type"] = "application/json"
    if AUTH_TOKEN:
        headers["Authorization"] = f"Bearer {AUTH_TOKEN}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode(errors="replace")[:300]
        _log(f"{method} {path} → HTTP {e.code}: {body_text}")
        return None
    except Exception as e:
        _log(f"{method} {path} → {type(e).__name__}: {e}")
        return None


def _ensure_workspace() -> None:
    _request("POST", f"/v3/workspaces", {"id": WORKSPACE})


def _ensure_peer(peer_id: str) -> None:
    _request("POST", f"/v3/workspaces/{WORKSPACE}/peers", {"id": peer_id})


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def honcho_read_context(peer_id: str) -> str:
    """
    Read Honcho's current representation of a peer.

    Returns the representation string, truncated to ~400 tokens if long.
    Returns empty string if Honcho is unconfigured, unreachable, or has no
    representation for this peer yet.
    """
    if not _enabled():
        return ""
    result = _request("GET", f"/v3/workspaces/{WORKSPACE}/peers/{peer_id}/context")
    if result is None:
        return ""
    rep = result.get("representation", "")
    if not isinstance(rep, str):
        return ""
    if len(rep) > MAX_CONTEXT_CHARS:
        rep = rep[:MAX_CONTEXT_CHARS] + "\n[... truncated]"
    return rep


def honcho_write_session(
    session_id: str,
    peer_id: str,
    messages: list[dict],
    summary: str | None = None,
) -> None:
    """
    Write a completed session's messages to Honcho for Deriver processing.

    session_id   : stable ID for this session (e.g. YYYYMMDD_N or a UUID)
    peer_id      : the observed peer (e.g. the owner's handle)
    messages     : list of {role: str, content: str} dicts
                   role "user" → is_human=True, everything else → assistant
    summary      : optional session summary, prepended as a system message

    No-ops silently if HONCHO_URL is unset. Fire-and-forget — logs errors,
    never raises.
    """
    if not _enabled():
        return
    if not messages and not summary:
        return

    _ensure_workspace()
    _ensure_peer(peer_id)

    session = _request(
        "POST",
        f"/v3/workspaces/{WORKSPACE}/sessions",
        {"id": session_id, "metadata": {}},
    )
    if session is None:
        _log(f"write_session: failed to create/get session {session_id}")
        return

    _request(
        "POST",
        f"/v3/workspaces/{WORKSPACE}/sessions/{session_id}/peers",
        {peer_id: {"observe_me": True, "observe_others": False}},
    )

    batch: list[dict] = []
    if summary:
        batch.append({"content": f"[session summary] {summary}", "peer_id": peer_id, "metadata": {}})

    for msg in messages:
        role = msg.get("role", "assistant")
        content = msg.get("content", "")
        if not content:
            continue
        prefixed = f"{role}: {content}" if role not in ("", "text") else content
        batch.append({"content": prefixed, "peer_id": peer_id, "metadata": {}})

    if not batch:
        return

    for i in range(0, len(batch), 100):
        chunk = batch[i : i + 100]
        result = _request(
            "POST",
            f"/v3/workspaces/{WORKSPACE}/sessions/{session_id}/messages",
            {"messages": chunk},
        )
        if result is None:
            _log(f"write_session: message batch {i // 100} failed for session {session_id}")


# ---------------------------------------------------------------------------
# CLI test helpers
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Honcho client — smoke-test CLI")
    parser.add_argument("--test-read", metavar="PEER", help="Read context for PEER")
    parser.add_argument("--test-write", metavar="PEER", help="Write a test session for PEER")
    args = parser.parse_args()

    if not _enabled():
        print("HONCHO_URL is not configured — set it in state/agent_config.env first.")
        print("Example:  HONCHO_URL=http://100.78.161.59:8100")
        sys.exit(1)

    print(f"Honcho base : {HONCHO_BASE}")
    print(f"Workspace   : {WORKSPACE}")
    print(f"Auth token  : {'(set)' if AUTH_TOKEN else '(none — auth-disabled mode)'}")
    print()

    if args.test_read:
        ctx = honcho_read_context(args.test_read)
        print(f"Context for '{args.test_read}':")
        print(repr(ctx) if not ctx else ctx)

    elif args.test_write:
        import uuid
        sid = f"test-{uuid.uuid4()}"
        msgs = [
            {"role": "user", "content": "Hello from blank_node agent. How are things?"},
            {"role": "assistant", "content": "Operational. The queue is clear tonight."},
        ]
        honcho_write_session(sid, args.test_write, msgs, summary="Standalone smoke-test session.")
        print(f"Wrote test session '{sid}' for peer '{args.test_write}'")
        print("Check Honcho Deriver queue for processing.")

    else:
        parser.print_help()
