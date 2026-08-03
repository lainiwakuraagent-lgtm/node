#!/usr/bin/env python3
"""
splice_prompt.py <core_dir> <goal_file> <output_file> [persona_file]

Concatenates the core prompt files from <core_dir>, in the fixed order
below, then replaces {{GOAL_PLACEHOLDER}}, {{PERSONA_PLACEHOLDER}}, and
{{SESSION_TYPE}} with the literal contents of the given files (goal/persona)
and the CURRENT_SESSION_TYPE env var respectively.

Core files are assembled as: baseline -> orientation -> memory_read (which
ends in the {{GOAL_PLACEHOLDER}} slot) -> memory_write (which ends in the
{{PERSONA_PLACEHOLDER}} slot). This order is deliberate — see baseline.md's
"What follows" section for the reasoning — and is not configurable via argv;
change CORE_FILES below if the composition itself needs to change.

All file reads are done by paths passed as argv -- no shell interpolation
of file contents into source code -- so arbitrary text (quotes, backslashes,
braces, anything) in the goal/persona files is handled safely.
"""
import os
import sys
from pathlib import Path

CORE_FILES = ["baseline.md", "orientation.md", "memory_read.md", "memory_write.md"]


def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <core_dir> <goal_file> <output_file> [persona_file]",
              file=sys.stderr)
        sys.exit(1)

    core_dir = Path(sys.argv[1])
    goal_path = sys.argv[2]
    output_path = sys.argv[3]
    persona_path = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None

    parts = []
    for name in CORE_FILES:
        f = core_dir / name
        if not f.exists():
            print(f"WARNING: core template missing, skipping: {f}", file=sys.stderr)
            continue
        parts.append(f.read_text(encoding="utf-8").strip())
    template = "\n\n---\n\n".join(parts)

    with open(goal_path, "r", encoding="utf-8") as f:
        goal = f.read().strip()

    if persona_path:
        with open(persona_path, "r", encoding="utf-8") as f:
            persona = f.read().strip()
    else:
        persona = "(no persona defined -- proceed as a neutral capable agent)"

    session_type = os.environ.get("CURRENT_SESSION_TYPE", "unknown")

    if "{{GOAL_PLACEHOLDER}}" not in template:
        print("WARNING: {{GOAL_PLACEHOLDER}} not found in assembled core template", file=sys.stderr)
    if "{{PERSONA_PLACEHOLDER}}" not in template:
        print("WARNING: {{PERSONA_PLACEHOLDER}} not found in assembled core template", file=sys.stderr)
    if "{{SESSION_TYPE}}" not in template:
        print("WARNING: {{SESSION_TYPE}} not found in assembled core template", file=sys.stderr)

    composed = template.replace("{{GOAL_PLACEHOLDER}}", goal)
    composed = composed.replace("{{PERSONA_PLACEHOLDER}}", persona)
    composed = composed.replace("{{SESSION_TYPE}}", session_type)

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(composed)


if __name__ == "__main__":
    main()
