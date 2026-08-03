#!/usr/bin/env python3
"""
memory_search.py — Search across the agent memory corpus.

Built 2026-07-07 by @Lain. Refactored 2026-08-01 to discover scopes from
whatever actually exists under memory/ instead of a hardcoded path list —
the previous version silently missed new top-level dirs added after it was
written (this is exactly what happened when memory/identity/ and
memory/knowledge/ were split out of memory/work/: nothing broke loudly,
--scope all just quietly stopped covering them) and still referenced a
memory/conversation.md that was never a real path. A fixed list can't stay
correct as the memory structure evolves across template clones; discovery
can.

Usage:
  python3 tools/executional/memory_search.py <query> [options]

Options:
  --scope SCOPE                         see --list-scopes for what's available
                                         (default: all)
  --list-scopes                         print available scopes and exit
  --context N                           lines of context around each match (default: 2)
  --case-sensitive                      (default: case-insensitive)
  --max N                               max matches to display (default: 100)
  --files-only                          show only filenames, no line content

Scopes are discovered at run time from memory/'s actual top-level entries
(one scope per file or directory found there), plus two fixed ones:
  all    -- everything under memory/, recursively
  core   -- the small set of always-relevant navigation files
  logs   -- logs/, for session/wake-log digging

Examples:
  python3 tools/executional/memory_search.py "tailscale ssh"
  python3 tools/executional/memory_search.py "ideapad-5" --scope sessions
  python3 tools/executional/memory_search.py "Phase 4" --context 3 --scope identity
  python3 tools/executional/memory_search.py "relationship_update" --files-only
  python3 tools/executional/memory_search.py --list-scopes
"""

import os
import re
import sys
import argparse
from pathlib import Path

PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", Path(__file__).resolve().parent.parent.parent))
MEMORY_DIR = PROJECT_DIR / "memory"
LOGS_DIR = PROJECT_DIR / "logs"

READABLE_SUFFIXES = {".md", ".txt", ".csv", ".log", ".sh", ".py", ".json"}

# Fixed navigation-file shortlist -- curated, not "whatever happens to be at
# the top level," since not every top-level file belongs in the quick-scan set.
CORE_FILES = ["latest_summary.md", "index.md", "MEMORY_MAP.md",
              "learnings_digest.md", "narrative_log.md"]


def discover_scopes() -> dict:
    """
    Build the scope -> [paths] mapping from what's actually on disk under
    memory/, plus the two fixed scopes (all, core) and logs/. Re-run every
    invocation -- cheap (a single non-recursive listdir), and it means a
    newly-added memory/whatever/ is searchable immediately, no code change.
    """
    scopes = {"all": [MEMORY_DIR], "logs": [LOGS_DIR]}
    scopes["core"] = [MEMORY_DIR / f for f in CORE_FILES]

    if MEMORY_DIR.exists():
        for entry in sorted(MEMORY_DIR.iterdir()):
            if entry.name.startswith("."):
                continue
            if entry.is_dir():
                scopes[entry.name] = [entry]
            elif entry.is_file() and entry.suffix in READABLE_SUFFIXES:
                scopes[entry.stem] = [entry]

    return scopes


def collect_files(paths):
    """Collect all readable files from a list of paths (files or directories)."""
    files = []
    seen = set()
    for p in paths:
        if not p.exists():
            continue
        if p.is_file() and p.suffix in READABLE_SUFFIXES:
            if p not in seen:
                files.append(p)
                seen.add(p)
        elif p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and f.suffix in READABLE_SUFFIXES and f not in seen:
                    files.append(f)
                    seen.add(f)
    return files


def search_file(path, pattern, context_lines):
    """Return list of match records for a file."""
    try:
        text = path.read_text(errors="replace")
        lines = text.splitlines()
    except Exception:
        return []

    results = []
    for i, line in enumerate(lines):
        if pattern.search(line):
            start = max(0, i - context_lines)
            end = min(len(lines), i + context_lines + 1)
            results.append({
                "line_num": i + 1,
                "context": lines[start:end],
                "context_start": start + 1,
            })
    return results


def format_separator(char="─", width=52):
    return f"╾{'─' * width}╼"


def print_scopes(scopes: dict):
    print("Available scopes (discovered from memory/'s current contents):\n")
    for name, paths in scopes.items():
        existing = [p for p in paths if p.exists()]
        status = "" if existing else "  (empty / not created yet)"
        shown = ", ".join(str(p.relative_to(PROJECT_DIR)) for p in paths[:3])
        print(f"  {name:<20} {shown}{status}")
    print()


def main():
    scopes = discover_scopes()

    parser = argparse.ArgumentParser(
        description="Search the agent memory corpus",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("query", nargs="?", help="Search term (substring, regex-escaped by default)")
    parser.add_argument(
        "--scope",
        default="all",
        help="Which memory scope to search (default: all). See --list-scopes.",
    )
    parser.add_argument(
        "--list-scopes",
        action="store_true",
        help="Print available scopes (discovered from memory/'s current contents) and exit",
    )
    parser.add_argument(
        "--context",
        type=int,
        default=2,
        metavar="N",
        help="Lines of context around each match (default: 2)",
    )
    parser.add_argument(
        "--case-sensitive",
        action="store_true",
        help="Case-sensitive search (default: case-insensitive)",
    )
    parser.add_argument(
        "--max",
        type=int,
        default=100,
        metavar="N",
        help="Max matches to display (default: 100)",
    )
    parser.add_argument(
        "--files-only",
        action="store_true",
        help="List matching filenames only, no line content",
    )

    args = parser.parse_args()

    if args.list_scopes:
        print_scopes(scopes)
        return

    if not args.query:
        parser.error("query is required (or use --list-scopes)")

    if args.scope not in scopes:
        print(f"Unknown scope: {args.scope!r}", file=sys.stderr)
        print_scopes(scopes)
        sys.exit(1)

    flags = 0 if args.case_sensitive else re.IGNORECASE
    try:
        pattern = re.compile(re.escape(args.query), flags)
    except re.error as e:
        print(f"Invalid query: {e}", file=sys.stderr)
        sys.exit(1)

    paths = scopes[args.scope]
    files = collect_files(paths)

    sep = format_separator()
    print(sep)
    mode = "case-sensitive" if args.case_sensitive else "case-insensitive"
    print(f'  memory_search: "{args.query}"')
    print(f"  scope={args.scope}  context={args.context}  {mode}")
    print(sep)
    print()

    total_matches = 0
    file_count = 0
    stopped_early = False

    for fpath in files:
        if total_matches >= args.max:
            stopped_early = True
            break

        matches = search_file(fpath, pattern, args.context)
        if not matches:
            continue

        rel = fpath.relative_to(PROJECT_DIR)
        n = len(matches)
        suffix = "es" if n != 1 else ""
        print(f"── {rel}  ({n} match{suffix})")

        if args.files_only:
            total_matches += n
            file_count += 1
            print()
            continue

        print()

        prev_end = -1
        for m in matches:
            if total_matches >= args.max:
                stopped_early = True
                break

            ctx_start = m["context_start"]
            ctx_end = ctx_start + len(m["context"]) - 1
            match_ln = m["line_num"]

            if prev_end >= 0 and ctx_start > prev_end + 1:
                print(f"   {'·' * 3}")

            for j, ctx_line in enumerate(m["context"]):
                lineno = ctx_start + j
                is_match = (lineno == match_ln)
                marker = "▶" if is_match else " "
                display = ctx_line[:200] + ("…" if len(ctx_line) > 200 else "")
                print(f"   {marker} {lineno:5d} │ {display}")

            prev_end = ctx_end
            total_matches += 1

        print()
        file_count += 1

    if total_matches == 0:
        print("  (no matches found)\n")
    elif stopped_early:
        print(f"  (stopped at {args.max} matches — use --max N for more)\n")

    print(sep)
    file_s = "s" if file_count != 1 else ""
    match_s = "es" if total_matches != 1 else ""
    print(f"  {total_matches} match{match_s} in {file_count} file{file_s}")
    print(sep)


if __name__ == "__main__":
    main()
