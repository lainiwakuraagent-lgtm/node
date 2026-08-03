---
name: sop-self-arch
description: Procedure for tasks tagged self-arch — any change to the agent's own bootstrap, identity, credential, or dispatch machinery, where a broken change can be invisible to the session that made it. Pairs with prompts/reference/architecture.md for the map; this file is the procedure.
---

# SOP — Self-Architecture Safety

## Why this SOP is different from the others

Every other SOP relies on this session, or a future one, noticing something went
wrong and fixing it. This category breaks that assumption at the root: if the
mechanism that lets a session start at all is what broke, there is no future session
to notice. The failure is invisible from the inside, by construction. That's the
specific thing this SOP exists to guard against — not "be careful," a concrete
procedure for a category where the normal self-check loop structurally cannot work.

## When this applies

Any task touching one of the four blast-radius categories in
`prompts/reference/architecture.md` §9 (bootstrap/wake chain, identity/memory chain,
credential/config chain, dispatch/routing logic) — that file owns the canonical list;
this file doesn't keep its own copy, so the two can't drift apart the way the
`--validate-all` hardcoded tag list did. Read that section before starting, and
identify which categor(ies) apply — verification differs by category (see Procedure
step 2). If a future clone adds new session types, changes to the dispatcher for that
reason fall under this same SOP; a more specialized SOP for "adding a session type"
can split off later if that becomes a repeated pattern, not before.

## Procedure

1. **Name which categor(ies) the task touches**, from the list above, explicitly —
   don't proceed on a vague sense that "this is probably fine."
2. **Verify out-of-band, matched to the category** — never rely on the normal
   same-session self-check for this class of change, since it cannot observe the
   failure mode that actually matters here:
   - *Bootstrap/wake*: actually invoke the real wake entrypoint end-to-end and
     confirm it hands off to a real session — not a read-through of the diff.
   - *Identity/memory*: confirm whatever reads these files (the splice/read chain)
     still parses the result correctly, and that the change was an edit-in-place or
     append where that's the convention, not an accidental truncation/overwrite.
   - *Credential/config*: confirm a fresh session can actually authenticate and
     reach the tools that depend on this — not just that the file's syntax is valid.
   - *Dispatch/routing*: trace at least one concrete real task/session state through
     the changed logic by hand or with a dry run, and confirm it resolves to the
     intended session type. "Looks right on read" is exactly how the current known
     misrouting bug happened.
3. **Escalate before merging, not after something breaks.** This category matches
   `skills/escalation/SKILL.md`'s own recognition criteria by default — irreversible,
   high blast radius, no safe fallback if wrong. Run it through `sop-escalation`
   before the change goes live, every time, not as a judgment call per instance.
4. **Rollback must be owner-executable, not agent-executable.** The usual assumption
   — a future session can act on the Rollback field — is exactly what might be false
   here. Record the literal recovery command *for the owner* in the task's Rollback
   section, since a future session may not exist, or may exist but be degraded.
5. **Isolate.** A change in this category never rides along with unrelated work in
   the same task — its own task, its own narrow diff, nothing bundled that would
   widen what has to be understood to safely revert it.

## Definition of done

- The touched categor(ies) are named explicitly.
- Out-of-band verification matched to the category actually happened (not a diff
  read-through) — state what was run and what it confirmed.
- The change was escalated per `sop-escalation` before merging.
- The task's Rollback section contains an owner-executable recovery step.
- Nothing unrelated is bundled into the same task.

## Do not

- Treat a change in this category as done because it "looks right" and the normal
  post-MVP self-check loop passed — that loop cannot see this category's actual
  failure mode.
- Skip escalation because the change seems small — size is not the risk signal here,
  blast radius and detectability are.
- Write a Rollback section that assumes a future agent session will be the one
  executing it.
