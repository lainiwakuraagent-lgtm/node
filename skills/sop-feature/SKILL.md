---
name: sop-feature
description: Procedure for tasks tagged feature — a decision framework for interface-contract-first vs test-first, chosen by where the actual risk sits, not a fixed method.
---

# SOP — Feature

## When this applies
Any task tagged `feature`: new capability that didn't exist before, as opposed to a
fix (`bugfix`) or a structural change with no new behavior (`refactor`).

## Procedure — choose your lens deliberately, state which one in the task's Scope

There is no single correct method for every feature; picking the wrong one for the
task at hand is itself a mistake worth avoiding. Decide which of these two applies
before writing any code, and say so explicitly:

**Interface-contract-first** — use this when the risk is the *shape* of the thing:
anything exposed to another agent, another project, an external consumer, or a public
API surface. Define the contract (function signature, API schema, message format)
before implementing behind it. Getting the shape wrong is expensive to fix later
because other things will depend on it; getting the internal logic wrong is comparatively
cheap to iterate on.

**Test-first** — use this when the risk is *logic correctness* against an interface
that's already fixed or low-stakes (internal-only, easily changed later). Write the
test describing the desired behavior before the implementation; let the test drive
the shape of the internals.

If genuinely unsure which applies, default to interface-contract-first for anything
another project, agent, or task will depend on, and test-first for everything else.

## Definition of done
- **Scope:** the specific capability described in the task, plus a stated choice of
  which lens was used and why.
- **Verification:** for interface-contract-first, the contract itself plus tests
  proving the implementation satisfies it; for test-first, the tests written before
  implementation, now passing.
- **Rollback:** standard repo-work handling (branch-per-task, merge on pass), unless
  the feature also touches infra/live state, in which case `sop-infra` applies too.

## Do not
- Pick a lens and then silently switch mid-task without updating the Scope — Reviewer
  checks stated approach against what was actually done.
- Treat "it compiles and does something" as done — the chosen lens defines what
  evidence actually proves correctness.
