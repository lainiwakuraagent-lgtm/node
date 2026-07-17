---
name: sop-infra
description: Domain SOP for infrastructure/devops work — IaC-first by policy, assessment-driven rather than a fixed toolchain; the actual hosting/scaling choice is deliberately left open for the executional agent to determine from its real environment.
---

# SOP — Infra / DevOps

## When this applies
Any task tagged `infra`: deployment, monitoring, or infrastructure work — as opposed to
application code (`feature`/`bugfix`/`refactor`).

## Procedure
1. **IaC-first, by policy.** Default to expressing the change as version-controlled
   configuration (Terraform, Ansible, docker-compose, systemd units, or whatever fits
   the actual target) rather than a live/ad-hoc action. This is not optional by
   default — ad-hoc action is the exception, reserved for things that genuinely cannot
   be expressed as config, not a shortcut for convenience.
2. **Assess before choosing a toolchain or scale.** There is currently no existing
   devops infrastructure to extend — this is being built from nothing. Before
   proposing an approach, survey what actually exists (or confirm nothing does) rather
   than assuming a specific stack. Default to the simplest viable deployment that meets
   the immediate MVP-scale need, absent a specific reason to do otherwise.
3. **Treat Docker Compose, Kubernetes, or other hosting as options to select once real
   scaling needs are known** — not a decision to make in the abstract, disconnected
   from actual load, team size, or reliability requirements. This choice is
   deliberately not fixed by this SOP; it belongs to whoever is executing against the
   real environment at the time.
4. **If the change genuinely can't be expressed as IaC** (a one-off manual
   intervention, an emergency fix, a provider action with no API/Terraform provider),
   fall back to the ad-hoc path: the task's `Rollback` section must contain either the
   literal undo procedure or an explicit pre-change snapshot/backup step. For anything
   irreversible (no clean undo, no backup possible), the task must go to
   `blocked_owner` rather than proceeding — stop and ask, don't act and hope.

## Definition of done
- **Scope:** the specific infra change described in the task, and which path (IaC or
  ad-hoc exception) was used, stated explicitly.
- **Verification:** for IaC — the applied config produces the expected state (plan/
  apply output, or equivalent for the tool in use). For ad-hoc — the literal command(s)
  confirming the change took effect as intended.
- **Rollback:** for IaC, this is the same as `sop-repo-work` (branch + revert + re-apply
  is the undo primitive). For ad-hoc, the Rollback section is mandatory and load-bearing
  — it is not optional the way it might be for a pure application-code change.

## Do not
- Default to a live/ad-hoc change because it's faster, when the change could be
  expressed as config with a little more effort.
- Guess at a toolchain or scale target without assessing what's actually there —
  this SOP exists specifically so that guess never has to happen in the abstract.
- Proceed on an irreversible ad-hoc action without an owner gate.
