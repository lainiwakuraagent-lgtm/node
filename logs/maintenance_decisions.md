# Maintenance Decisions Log

Maintained by maintenance sessions. Each entry documents an observation,
an assessment, and a proposed action. Decisions are NOT acted on here —
they are queued for review in the next execution session.

**Format:** append-only. Never delete or edit past entries. Mark decisions
as acted or deferred by adding a `[ACTED: YYYY-MM-DD]` or `[DEFERRED: reason]`
note below the original entry.

---

## Schema

```
### YYYY-MM-DD — Decision title

**Observation**: What was seen (session logs, file state, error output, etc.)
**Assessment**: What it means and how serious it is.
**Proposed action**: What should be done about it (specific, actionable).
**Priority**: low | medium | high
**Status**: pending | acted | deferred
```

---

## Entries

*(empty — no maintenance decisions logged yet)*

---

## How to use this file (maintenance sessions)

For every issue in `logs/system_issues.md`, or any anomaly found during
the maintenance session, write an entry here with:
- What you observed (cite specific log lines or file states)
- What you think it means
- What should be done
- Priority level

Do not touch implementation files during a maintenance session.
The next execution session reads this file and acts on pending entries.

If a decision was already made and the problem is gone, mark it:
`[ACTED: YYYY-MM-DD — brief description of what was done]`
