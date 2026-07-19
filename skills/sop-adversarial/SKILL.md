---
name: sop-adversarial
version: 1.0.0
description: >
  Adversarial verification pass — used for tasks tagged 'adversarial'.
  The orchestrator automatically runs Finder + Verifier after Reviewer PASS.
curator_guard: permanent
---

# SOP: Adversarial Tag

Tasks tagged `adversarial` receive an extra verification pass after the
normal Verifier + Reviewer chain. This is opt-in — the tag must be
explicitly set on the task.

## What this means for task authors

When tagging a task `adversarial`:
- The orchestrator will run a Finder agent (adversarial, minimal context)
  after Reviewer PASS
- The Finder will look for flaws in the artifact
- An Adversarial Verifier will judge each finding (CONFIRMED/DISMISSED/DEFERRED)
- CONFIRMED finding → task transitions to needs_plan (counts as retry attempt)
- DEFERRED finding → written to task notes for next planning session

## When to tag a task 'adversarial'

Use this tag for:
- Security-sensitive changes (auth, permissions, data handling)
- Infrastructure changes with broad blast radius
- Any implementation where "trust but verify" isn't strong enough

## Phase 1 scope

Per-task adversarial pass only. Phase 2 (per-goal/milestone) and Phase 3
(per-architecture/maintenance) are not yet implemented.

Design: memory/work/adversarial_verifier_design.md
