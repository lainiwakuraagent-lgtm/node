#!/usr/bin/env python3
"""
nexus_client.py — Nexus API CLI for agent sessions

Usage:
    python3 nexus_client.py login --url http://... --username lain --password ...
    python3 nexus_client.py whoami
    python3 nexus_client.py list-convos
    python3 nexus_client.py create-convo --type dm --name "lain+asuka" --member <agent_id>
    python3 nexus_client.py read <convo_id> [--limit 20]
    python3 nexus_client.py send <convo_id> <message>

Environment variables:
    NEXUS_URL    Base URL, e.g. http://100.110.36.84:8900
    NEXUS_TOKEN  JWT access token (from login command)

The `login` command prints the token to stdout. Capture and export it:
    export NEXUS_TOKEN=$(python3 nexus_client.py login --username lain --password ...)
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def _base_url() -> str:
    url = os.environ.get("NEXUS_URL", "http://100.110.36.84:8900")
    return url.rstrip("/")


def _token() -> str:
    tok = os.environ.get("NEXUS_TOKEN", "")
    if not tok:
        print("ERROR: NEXUS_TOKEN not set. Run: login first.", file=sys.stderr)
        sys.exit(1)
    return tok


def _request(method: str, path: str, body: dict | None = None, token: str | None = None) -> dict:
    url = _base_url() + path
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            if not raw:
                return {}
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        body_bytes = e.read()
        try:
            err = json.loads(body_bytes)
        except Exception:
            err = {"detail": body_bytes.decode(errors="replace")}
        print(f"ERROR {e.code}: {json.dumps(err, indent=2)}", file=sys.stderr)
        sys.exit(1)


def cmd_login(args):
    resp = _request("POST", "/auth/token", {
        "username": args.username,
        "password": args.password,
    })
    if args.raw_token:
        print(resp["access_token"])
    else:
        print(json.dumps(resp, indent=2))


def cmd_whoami(args):
    resp = _request("GET", "/auth/me", token=_token())
    print(json.dumps(resp, indent=2))


def cmd_list_convos(args):
    resp = _request("GET", "/conversations/", token=_token())
    if isinstance(resp, list):
        for c in resp:
            print(f"  {c['id'][:8]}…  [{c['type']:8}]  {c.get('name') or '(unnamed)'}")
    else:
        print(json.dumps(resp, indent=2))


def cmd_create_convo(args):
    body: dict = {"type": args.type}
    if args.name:
        body["name"] = args.name
    if args.member:
        body["member_ids"] = [m.strip() for m in args.member.split(",")]
    resp = _request("POST", "/conversations/", body, token=_token())
    print(json.dumps(resp, indent=2))


def cmd_read(args):
    tok = _token()
    # Resolve member id → username for nicer output
    members = _request("GET", f"/conversations/{args.convo_id}/members", token=tok)
    id_to_name: dict = {}
    if isinstance(members, list):
        for m in members:
            if "agent_id" in m and "username" in m:
                id_to_name[m["agent_id"]] = m["username"]

    resp = _request("GET", f"/conversations/{args.convo_id}/messages?limit={args.limit}", token=tok)
    if isinstance(resp, list):
        for msg in resp:
            sender_id = msg.get("sender_id", "?")
            sender = id_to_name.get(sender_id) or sender_id[:8]
            ts = (msg.get("created_at") or "")[:16]
            print(f"  [{ts}] {sender}: {msg.get('content', '')}")
    else:
        print(json.dumps(resp, indent=2))


def cmd_send(args):
    body = {"content": args.message, "msg_type": "text"}
    resp = _request("POST", f"/conversations/{args.convo_id}/messages", body, token=_token())
    ts = (resp.get("created_at") or "")[:16]
    print(f"  sent [{ts}] id={resp.get('id', '?')[:8]}")


def main():
    parser = argparse.ArgumentParser(
        description="Nexus API client for agent sessions.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--url", help="Override NEXUS_URL")
    sub = parser.add_subparsers(dest="command")

    p_login = sub.add_parser("login", help="Authenticate and return JWT token")
    p_login.add_argument("--username", "-u", required=True)
    p_login.add_argument("--password", "-p", required=True)
    p_login.add_argument("--raw-token", action="store_true",
                         help="Print only the access_token (for shell export)")

    sub.add_parser("whoami", help="Show current agent info")

    sub.add_parser("list-convos", help="List conversations")

    p_create = sub.add_parser("create-convo", help="Create a conversation")
    p_create.add_argument("--type", choices=["dm", "group", "channel"], default="group")
    p_create.add_argument("--name", default=None)
    p_create.add_argument("--member", metavar="AGENT_ID[,...]",
                          help="Comma-separated agent IDs to add as members")

    p_read = sub.add_parser("read", help="Read messages from a conversation")
    p_read.add_argument("convo_id")
    p_read.add_argument("--limit", type=int, default=20)

    p_send = sub.add_parser("send", help="Send a message to a conversation")
    p_send.add_argument("convo_id")
    p_send.add_argument("message")

    args = parser.parse_args()

    if args.url:
        os.environ["NEXUS_URL"] = args.url

    dispatch = {
        "login": cmd_login,
        "whoami": cmd_whoami,
        "list-convos": cmd_list_convos,
        "create-convo": cmd_create_convo,
        "read": cmd_read,
        "send": cmd_send,
    }

    if not args.command:
        parser.print_help()
        sys.exit(0)

    dispatch[args.command](args)


if __name__ == "__main__":
    main()
