---
name: sop-fleet
description: Domain SOP for cross-project coordination work — establish why projects are being worked on together before anything else, and keep every project's dependencies, environment, and credentials strictly separate.
---

# SOP — Fleet / Multi-Project Coordination

## When this applies
Any task under a coordination project whose purpose is to touch or affect more than
one other project — a fleet-wide library update, a coordinated migration, anything
that isn't naturally scoped to a single repository.

## Procedure
1. **Determine how the target projects actually differ, and why they're being worked
   on together, before touching anything.** Never assume relatedness because two
   projects look similar — establish the actual reason this is a coordinated effort
   rather than N independent tasks. Write this down in the coordination project's own
   directory; it's the reference point for every task that follows.
2. **Track each target project's dependencies separately.** Never merge them into one
   shared list, even if several projects happen to depend on the same library or
   version — a shared list is exactly how "similar" quietly becomes "conflated."
3. **Resolve environment files and credentials strictly per-project.** This is the
   direct, concrete anti-pattern to guard against: Project A must never draw resources
   from Project B's environment, whether that's an environment variable, a credential,
   or a config value. If two target projects genuinely share a credential or resource,
   that sharing must be explicit and recorded, never incidental.
4. **Any actual code change to a target project is decomposed into its own
   properly-scoped task**, dispatched through the normal single-project isolation path
   (its own resolved `project_id`, its own directory, its own credential fetch) — never
   a single session holding two projects' materials at once. The coordination project
   tracks and sequences this; it never bypasses isolation itself.

## Definition of done
- **Scope:** the coordination project's manifest lists exactly which target projects
  are touched and why, kept current as work proceeds.
- **Verification:** each decomposed per-project task is verified independently, through
  its own project's normal pipeline — there is no separate "fleet-level" verification
  beyond the sum of the per-project ones.
- **Rollback:** each per-project task carries its own Rollback per that project's SOP
  (repo-work or infra); the coordination project itself has nothing to roll back since
  it never directly modifies target-project state.

## Do not
- Let the coordination project's session `cd` into a target project's directory and
  edit it directly — that reopens the exact isolation hole this whole design exists to
  close.
- Assume two projects share an environment or credential just because they're part of
  the same coordinated effort.
