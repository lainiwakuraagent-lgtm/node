---
name: sop-security
description: Starter-scope security SOP — credential and secret hygiene only; never expose environment variables, agent private information, private keys, or authentication credentials publicly. Broader security review is explicitly out of scope for now.
---

# SOP — Security (credential & secret hygiene)

## When this applies
Any task tagged `security`, or any task (regardless of its content-type tag) that
touches credentials, secrets, environment configuration, or agent identity data.
**Deliberately narrow scope**, set this way for now: this SOP covers storage and
exposure of secrets. It does not cover injection vulnerabilities, auth-flow design, or
broader access-control review — those are explicitly left for future expansion by the
executional agent itself, not defined here.

## Procedure
1. **Never write a secret literally into code, logs, task descriptions, commit
   messages, or documentation.** Secrets are referenced by pointer (an env var name, a
   credential-store key, a path) — never by value — anywhere outside the actual
   credential store itself.
2. **Never expose an environment variable's value** in output that another agent,
   another project, or a log file might read. If a task needs to confirm a variable is
   set, confirm presence, not value.
3. **Never expose agent private information** — identity data, internal state, or
   anything analogous to a private key or credential belonging to any agent, not only
   the one executing this task.
4. **When in doubt about whether something counts as a secret, treat it as one.** The
   cost of unnecessary caution here is low; the cost of a leaked credential is not.

## Definition of done
- **Scope:** the specific credential-handling change described in the task.
- **Verification:** a review pass (Reviewer, per its existing cross-domain-reference
  check) confirming no secret value appears in the diff, logs, or any generated
  artifact.
- **Rollback:** if a secret was ever exposed (even briefly, even in a since-reverted
  commit), rotation of that credential is required — a git revert alone does not undo
  exposure, since the value may already have been seen.

## Do not
- Assume a `.gitignore`d file is sufficient protection — check what actually got
  committed, logged, or printed to a session transcript.
- Treat this SOP as covering all of "security" — it doesn't, by design, for now.
