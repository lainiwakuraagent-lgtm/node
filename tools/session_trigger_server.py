#!/usr/bin/env python3
"""
session_trigger_server.py — Manual session trigger endpoint.

Runs an HTTP server on port 8766 bound to 0.0.0.0 (Tailscale-accessible).
Receives POST /trigger with a secret token and immediately launches a new agent
session by running wake.sh in the background.

Auth: X-Trigger-Token header OR ?token=<value> query param.
Token is stored in state/trigger_token.txt.

iOS Shortcut: POST to http://100.110.36.84:8766/trigger
              Header: X-Trigger-Token: <value from trigger_token.txt>

Usage:
  python3 tools/session_trigger_server.py
"""

import http.server
import json
import logging
import os
import subprocess
import sys
import urllib.parse
from pathlib import Path

PORT = 8766
BIND_HOST = "0.0.0.0"

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
TOKEN_FILE = PROJECT_DIR / "state" / "trigger_token.txt"
WAKE_SH = PROJECT_DIR / "scripts" / "wake.sh"
GOAL_FILE = PROJECT_DIR / "prompts" / "emergency_goal.txt"
GOAL_FILE_FALLBACK = PROJECT_DIR / "prompts" / "default_goal.txt"
PERSONA_FILE = PROJECT_DIR / "prompts" / "persona.txt"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("trigger")


def load_token() -> str:
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text().strip()
    return ""


def fire_session() -> str:
    """Launch wake.sh in background. Returns a status string."""
    if not WAKE_SH.exists():
        return f"wake.sh not found at {WAKE_SH}"

    if GOAL_FILE.exists():
        goal = str(GOAL_FILE)
    elif GOAL_FILE_FALLBACK.exists():
        goal = str(GOAL_FILE_FALLBACK)
        log.info("emergency_goal.txt not found — falling back to default_goal.txt")
    else:
        goal = ""
    persona = str(PERSONA_FILE) if PERSONA_FILE.exists() else ""

    if not goal:
        return "no goal file found — trigger aborted (emergency_goal.txt and default_goal.txt both missing)"

    cmd = ["bash", str(WAKE_SH), goal]
    if persona:
        cmd.append(persona)

    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = "/run/user/1001"
    # Signal to wake.sh that this is a manual trigger — bypasses time window
    env["TRIGGER_MODE"] = "manual"

    subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    log.info("Session trigger fired: %s", " ".join(cmd))
    return "session triggered"


class TriggerHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.info(fmt % args)

    def _send_json(self, code: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok", "service": "session-trigger"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/trigger":
            self._send_json(404, {"error": "not found"})
            return

        # Auth: check header first, then query param
        expected = load_token()
        if not expected:
            self._send_json(500, {"error": "trigger token not configured"})
            return

        token_header = self.headers.get("X-Trigger-Token", "")
        qs = urllib.parse.parse_qs(parsed.query)
        token_qs = qs.get("token", [""])[0]
        provided = token_header or token_qs

        if provided != expected:
            log.warning("Invalid token from %s", self.client_address[0])
            self._send_json(401, {"error": "invalid token"})
            return

        status = fire_session()
        self._send_json(200, {"ok": True, "message": status})


if __name__ == "__main__":
    token = load_token()
    if not token:
        log.warning("No trigger token found at %s — server will reject all requests", TOKEN_FILE)

    log.info("Session trigger server on %s:%d", BIND_HOST, PORT)
    log.info("Wake script: %s", WAKE_SH)
    log.info("Token file: %s", TOKEN_FILE)

    server = http.server.HTTPServer((BIND_HOST, PORT), TriggerHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Stopped")
