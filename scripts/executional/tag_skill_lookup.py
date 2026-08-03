#!/usr/bin/env python3
"""
tag_skill_lookup.py — Resolve a task's SOP tag to a skill file path.

Convention: tag "bugfix" → skill directory "sop-bugfix" → file "skills/sop-bugfix/SKILL.md"

This is a deterministic lookup — exact string match, no fuzzy search,
no agent discretion. If the skill file doesn't exist, fail immediately.

Usage:
    python3 scripts/tag_skill_lookup.py --project-dir /path/to/agent_project --tag bugfix
    python3 scripts/tag_skill_lookup.py --project-dir /path/to/agent_project --list
    python3 scripts/tag_skill_lookup.py --project-dir /path/to/agent_project --validate-all
"""

import argparse
import sys
from pathlib import Path


SKILLS_DIR_NAME = "skills"


def resolve_skill_path(project_dir: Path, tag: str) -> Path | None:
    """Resolve a tag to its skill file path. Returns None if not found."""
    skill_dir = project_dir / SKILLS_DIR_NAME / f"sop-{tag}"
    skill_file = skill_dir / "SKILL.md"
    if skill_file.exists():
        return skill_file
    return None


def parse_skill_description(skill_file: Path) -> str:
    """Extract the one-line `description:` field from a skill file's YAML frontmatter.
    Handles both inline values and folded (`>`) block scalars. Returns "" if absent."""
    try:
        lines = skill_file.read_text().splitlines()
    except OSError:
        return ""
    if not lines or lines[0].strip() != "---":
        return ""
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return ""
    desc_parts: list[str] = []
    collecting = False
    for line in lines[1:end]:
        if collecting:
            if line.strip() and line.startswith((" ", "\t")):
                desc_parts.append(line.strip())
                continue
            break
        if line.startswith("description:"):
            value = line[len("description:"):].strip()
            if value in (">", "|", ">-", "|-"):
                collecting = True
            else:
                desc_parts.append(value.strip("\"'"))
                break
    return " ".join(desc_parts).strip()


def list_available_skills(project_dir: Path) -> list[tuple[str, Path, str]]:
    """List all available sop-* skills as (tag, path, description) tuples."""
    skills_dir = project_dir / SKILLS_DIR_NAME
    if not skills_dir.exists():
        return []
    results = []
    for d in sorted(skills_dir.iterdir()):
        if d.is_dir() and d.name.startswith("sop-"):
            skill_file = d / "SKILL.md"
            if skill_file.exists():
                tag = d.name[4:]  # strip "sop-" prefix
                results.append((tag, skill_file, parse_skill_description(skill_file)))
    return results


def find_broken_skill_dirs(project_dir: Path) -> list[str]:
    """Find sop-* directories with no SKILL.md, or a SKILL.md with no parseable
    description. Self-consistency check against the filesystem — no fixed manifest,
    so it can't go stale the way a hardcoded tag list would."""
    skills_dir = project_dir / SKILLS_DIR_NAME
    if not skills_dir.exists():
        return []
    broken = []
    for d in sorted(skills_dir.iterdir()):
        if d.is_dir() and d.name.startswith("sop-"):
            skill_file = d / "SKILL.md"
            if not skill_file.exists():
                broken.append(f"{d.name} (no SKILL.md)")
            elif not parse_skill_description(skill_file):
                broken.append(f"{d.name} (SKILL.md has no parseable description)")
    return broken


def main():
    parser = argparse.ArgumentParser(description="Tag → skill lookup")
    parser.add_argument("--project-dir", required=True, help="Agent project root")
    parser.add_argument("--tag", default=None, help="Tag to resolve")
    parser.add_argument("--list", action="store_true", help="List all available skills")
    parser.add_argument("--validate-all", action="store_true",
                        help="Check every sop-* directory has a valid, parseable SKILL.md")
    args = parser.parse_args()

    project_dir = Path(args.project_dir).resolve()

    if args.list:
        skills = list_available_skills(project_dir)
        if not skills:
            print("No sop-* skills found in skills/ directory.")
            sys.exit(0)
        for tag, path, desc in skills:
            print(f"  {tag} -> {path}")
            if desc:
                print(f"      {desc}")
        return

    if args.validate_all:
        broken = find_broken_skill_dirs(project_dir)
        if broken:
            print(f"BROKEN sop-* directories: {', '.join(broken)}", file=sys.stderr)
            sys.exit(1)
        skills = list_available_skills(project_dir)
        print(f"All {len(skills)} sop-* directories are self-consistent "
              f"(no fixed manifest — this check can't go stale).")
        return

    if not args.tag:
        print("ERROR: --tag required (or use --list / --validate-all)", file=sys.stderr)
        sys.exit(1)

    path = resolve_skill_path(project_dir, args.tag)
    if path is None:
        print(f"ERROR: No skill file for tag '{args.tag}' "
              f"(expected: {project_dir / SKILLS_DIR_NAME / f'sop-{args.tag}' / 'SKILL.md'})",
              file=sys.stderr)
        sys.exit(1)

    print(str(path))


if __name__ == "__main__":
    main()
