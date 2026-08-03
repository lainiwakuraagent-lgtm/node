---
name: escalation
description: Standalone discretionary skill (not tag-driven) — recognizing when something is worth escalating. When it applies, hands off to skills/sop-escalation/SKILL.md for the actual mechanics.
---

# Skill — Escalation (recognition)

## When this applies
Any session, any layer, whenever one of these signals shows up — not dispatched by a
task tag the way `sop-*` files are; invoked when the agent itself judges it relevant:

- About to make an irreversible or high-blast-radius call with no clear safe default.
- Found something that contradicts what the owner, or another agent, explicitly said.
- A decision genuinely needs authority this agent doesn't have (budget, credentials,
  architecture direction, anything outside "decide and proceed" per
  `execution_prompt.md`'s own blocker/no-blocker decision tree).
- Something surfaced that the recipient would clearly want to know about even though
  no decision is needed from them (FYI-worthy, not just blocker-worthy).

## Procedure
1. Check the signals above. If none apply, this skill's job is done — proceed normally.
2. If one applies, this **is** escalation-worthy. Follow `skills/sop-escalation/SKILL.md`
   for the actual mechanics (who, what kind of ask, which channel, how it gets logged).
   This file only answers "should I," not "how."

## Definition of done
- A judgment was made, one way or the other, and it wasn't skipped past by default.
- If escalation-worthy, `sop-escalation`'s procedure was actually followed, not just
  noted as "should probably escalate this" and left there.

## Do not
- Use this as a way to avoid a decision that's actually within this agent's own
  authority — recognition isn't a substitute for "decide and proceed" when that's
  what the situation actually calls for.
