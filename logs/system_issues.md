# System Issues Log

Maintained by maintenance sessions. Updated by reading recent session logs and
identifying recurring or persistent problems.

**Do not edit live during execution sessions.** This file is read and written
only by maintenance sessions, which document what they find without acting on it.

---

## Schema

Each issue entry:

```
### [ISSUE_ID] Short descriptive name

- **Status**: sporadic | persistent | resolved
- **First seen**: YYYY-MM-DD
- **Last seen**: YYYY-MM-DD
- **Recurrence count**: N
- **Evidence**: (session log lines, error messages, or brief description)
- **Assessment**: (what causes it, how serious it is)
- **Decision**: (proposed action, or "monitor", or "accepted as known behavior")
```

---

## Sporadic

*(Issues seen once or intermittently — not yet confirmed as persistent)*

*(empty — no sporadic issues logged yet)*

---

## Persistent

*(Issues seen consistently across multiple sessions)*

*(empty — no persistent issues logged yet)*

---

## Resolved

*(Issues that were fixed or confirmed gone)*

*(empty — no resolved issues yet)*

---

## How to update this file (maintenance sessions)

1. Scan `logs/session_log.csv` and recent `logs/wake.log` for errors or anomalies.
2. If an issue is new: add under `## Sporadic` with today's date.
3. If an issue appears again: increment recurrence_count, update last_seen.
   If it has appeared 3+ times: move to `## Persistent`.
4. If an issue appears fixed: move to `## Resolved` with resolution date and note.
5. For each issue, fill in `## Decision` in `logs/maintenance_decisions.md`
   before the next execution session reviews it.
