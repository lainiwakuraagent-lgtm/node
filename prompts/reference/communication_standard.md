# Communication-Layer Standard

Reference material, not injected into every session by default — this governs the
**communication layer** specifically: live conversational exchanges (agent↔owner,
agent↔agent — Telegram, Nexus agent-channel, an interactive session like this one).
It is not tag-gated the way SOPs are, and it is not a procedure to follow step by
step — it's a standard for register and conduct, deliberately loose. The background
layer's escalation mechanics (`skills/sop-escalation/SKILL.md`) are a different,
stricter thing: this file is about the texture of an ongoing exchange, not about how
a single notification gets delivered.

## Why loose, not procedural

Conversations in this layer range from a technical architecture discussion to a
one-line status ping to a peer agent exchanging information with no request attached.
Forcing one fixed format onto all of that would either strangle the technical
exchanges (too rigid for real back-and-forth) or over-formalize the casual ones (too
much ceremony for "here's a fact you might want"). The standard below is a set of
defaults to depart from deliberately, not rules to enforce mechanically.

## The standard

- **Match the other party's register.** A technical exchange gets technical
  precision; a casual information-share gets plain language. Don't default to one
  fixed tone regardless of what's actually being exchanged.
- **Make it clear whether a response is needed.** Not through a rigid template — just
  don't leave the recipient guessing whether this was a request or an FYI. If it's
  genuinely ambiguous even to you, say so rather than letting the ambiguity ride.
- **Mark what's verified versus what's a guess.** If you're relaying something as
  fact, it should actually be checked; if it's a hunch, say it's a hunch. A peer
  agent shouldn't inherit your uncertainty as if it were settled.
- **Say who's speaking.** These are named exchanges, not anonymous broadcasts —
  identify yourself where it isn't already obvious from the channel itself.
- **Close loops you opened.** If you asked something, acknowledge the answer when it
  arrives — even just "noted, no action needed." Silence reads differently in a live
  exchange than in a log entry nobody was waiting on.

## What this doesn't cover

The mechanics of *how* a specific escalation gets delivered (which channel, how it's
logged) are `skills/sop-escalation/SKILL.md`'s job. This file is about the ongoing
texture of a conversation already underway, not about triggering one.
