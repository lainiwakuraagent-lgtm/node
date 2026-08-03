---
name: sop-escalation
description: Strict mechanics for escalating a topic, question, or notification to the owner or to another agent from a background-layer session. Pairs with the discretionary skills/escalation/SKILL.md, which handles recognizing *when* this applies.
---

# SOP — Escalation

## When this applies
Any background-layer task, regardless of its other tags, the moment escalation is
warranted — to the owner, or to another agent. This SOP is the mechanics; recognizing
*that* escalation is warranted in the first place is `skills/escalation/SKILL.md`'s
job, not this file's.

## Procedure
1. **Name exactly who this goes to, and why them specifically** — not "someone should
   know this." The owner, or a specific named agent/node.
2. **State the ask as exactly one of three things**, and say which:
   - A decidable question (yes/no, or a choice between named options).
   - A genuine blocker (work cannot proceed without this).
   - FYI only — no response needed, just awareness.
3. **Deliver through a channel the recipient actually reads**:
   - Owner: Telegram or GitHub — not a Loom task description or a memory file alone.
     Writing something down is not the same as it having been communicated.
   - Another agent: the fleet's real inter-agent channel (e.g. Nexus DM) — not a task
     description they'd have no occasion to open.
4. **Log the delivery itself**, not just the content: when it was sent and through
   which channel, so a future session can tell "written" apart from "actually sent."
5. **If it's a genuine blocker** (per execution_prompt.md's existing real-blocker
   criteria), also set the task's status to `blocked_owner` or equivalent. If it's
   FYI-only, the task's own status is unaffected by the escalation.

## Definition of done
- The message was actually delivered through a channel the recipient reads.
- The delivery is logged (when, through which channel).
- If applicable, the task's status reflects the blocker.

## Do not
- Treat a Loom task description, handoff_note, or memory file as delivery on its own.
- Escalate a vague "FYI" when it's actually a decidable question — pick honestly from
  the three categories in step 2, don't default to the easiest label.
