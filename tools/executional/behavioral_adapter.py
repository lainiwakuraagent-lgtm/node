#!/usr/bin/env python3
"""
behavioral_adapter.py — Pre-session relationship/context generator for blank_node agents.

Reads Honcho's derived representation of a peer (if HONCHO_URL is configured) and
combines it with a live Argus ambient-state snapshot, writing a plain-text context
file that the agent reads at session start.

Relationship context comes from Honcho and nothing else — there is no local
scoring, decay, or profile file.

Usage:
    python3 tools/behavioral_adapter.py \\
        --peer-id andrii \\
        --output state/behavioral_context.txt

    # Dry-run — print to stdout only:
    python3 tools/behavioral_adapter.py --peer-id andrii --dry-run
"""

import json
import argparse
from pathlib import Path
from datetime import date, datetime, timezone

PROJECT_DIR = Path(__file__).parent.parent.parent


# ── Argus context reader ──────────────────────────────────────────────────────

ARGUS_STATE_BEHAVIORS = {
    'working':  ('suppress unsolicited pings', 'Andrii is actively working — keep reports brief.'),
    'gaming':   ('suppress all pings', 'Andrii is gaming — no interruption.'),
    'idle':     ('safe to send', 'Andrii is idle — safe to send; can be thorough.'),
    'resting':  ('suppress', 'Andrii may be sleeping — suppress; queue for next wakeup.'),
    'social':   ('suppress', 'Andrii is on a call/video — suppress.'),
    'learning': ('suppress; brief if urgent', 'Andrii is reading/researching — suppress non-urgent pings.'),
    'mixed':    ('default behavior', 'Unclear state — use warmth calibration defaults.'),
    'unknown':  ('default behavior', 'Argus unreachable — default behavior applies.'),
}

ARGUS_MAX_AGE_SECONDS = 300  # treat as stale if older than 5 minutes


def load_argus_section() -> str:
    """Read state/argus_context.json and return a formatted context section, or ''."""
    argus_file = PROJECT_DIR / 'state' / 'argus_context.json'
    if not argus_file.exists():
        return ''
    try:
        data = json.loads(argus_file.read_text(encoding='utf-8'))
        fetched_raw = data.get('fetched_at', '')
        fetched_at = datetime.fromisoformat(fetched_raw.replace('Z', '+00:00'))
        age_seconds = (datetime.now(timezone.utc) - fetched_at).total_seconds()
        if age_seconds > ARGUS_MAX_AGE_SECONDS:
            return ''  # stale snapshot, don't inject misleading data
        if not data.get('reachable', False):
            return ''  # unreachable = no change to defaults
        argus_state = data.get('state', 'unknown')
        confidence = data.get('confidence', 0.0)
        focus = data.get('focus_vector') or ''
        idle_s = data.get('idle_seconds')
        behavior, interpretation = ARGUS_STATE_BEHAVIORS.get(
            argus_state, ARGUS_STATE_BEHAVIORS['unknown']
        )
        lines = [
            f'OWNER_CONTEXT: {argus_state} (confidence={confidence:.2f})',
        ]
        if focus:
            lines.append(f'OWNER_FOCUS: {focus}')
        if idle_s is not None:
            lines.append(f'OWNER_IDLE: {idle_s}s')
        lines += [
            f'  Behavior: {behavior}',
            f'  {interpretation}',
        ]
        return '\n'.join(lines)
    except (json.JSONDecodeError, ValueError, KeyError, OSError):
        return ''


# ── Honcho context reader ────────────────────────────────────────────────────

def _load_honcho_context(peer_id: str) -> str:
    """Read Honcho's current representation of a peer, non-fatal.

    Returns a non-empty string if HONCHO_URL is configured and Honcho returns
    a representation for this peer. Returns '' in every other case (unconfigured,
    unreachable, no representation yet).
    """
    try:
        import sys as _sys
        _conv_tools_dir = str(Path(__file__).parent.parent / "conversational")
        if _conv_tools_dir not in _sys.path:
            _sys.path.insert(0, _conv_tools_dir)
        from honcho_client import honcho_read_context  # type: ignore
        return honcho_read_context(peer_id)
    except Exception:
        return ''


# ── Context file generator ────────────────────────────────────────────────────

def generate_context(peer_id: str) -> str:
    """Produce the behavioral context text block: Honcho representation + Argus state."""
    today = date.today().isoformat()

    lines = [
        f'# Behavioral Context — generated {today}',
        f'# Peer: {peer_id}',
        '',
    ]

    honcho_ctx = _load_honcho_context(peer_id)
    if honcho_ctx:
        lines += [
            '# HONCHO_CONTEXT',
            honcho_ctx,
            '',
            '# Apply this as a current reading of the relationship, not a script to perform.',
        ]
    else:
        lines += [
            '# No relationship context available (Honcho unconfigured, unreachable, or no',
            '# representation yet for this peer). Proceed at a neutral, professional default.',
        ]

    argus_section = load_argus_section()
    if argus_section:
        lines += ['', argus_section]

    return '\n'.join(lines) + '\n'


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Generate relationship/tone context from Honcho + Argus'
    )
    parser.add_argument('--peer-id', required=True,
                        help='Peer id to read Honcho context for (e.g. the owner handle)')
    parser.add_argument('--output', type=str, default=None,
                        help='Output path for behavioral_context.txt (default: state/behavioral_context.txt)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print context to stdout without writing to disk')
    args = parser.parse_args()

    context = generate_context(args.peer_id)

    if args.dry_run:
        print(context)
        return

    out_path = Path(args.output) if args.output else PROJECT_DIR / 'state' / 'behavioral_context.txt'
    if not out_path.is_absolute():
        out_path = PROJECT_DIR / out_path

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(context, encoding='utf-8')
    print(f'Written: {out_path}')


if __name__ == '__main__':
    main()
