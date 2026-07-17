---
name: sop-integration
description: Procedure for tasks tagged integration — wiring two separately-built components together so they communicate correctly.
---

# SOP — Integration

## When this applies
Any task tagged `integration`: connecting components that already work independently.
The output is a working message/data flow between them.

## Procedure

1. **Verify components independently.** Both sides must work before wiring.
   Do not debug the connection if one side is broken.

2. **Identify the protocol.** What is the message format, transport, and authentication?
   Name these explicitly before writing any connection code.

3. **Wire minimum viable connection.** Connect the two components with the simplest
   path. One direction first (A→B), then reverse (B→A) if bidirectional.

4. **Send a real message.** Not a synthetic test — an actual payload the system will use.
   Verify the receiving side processes it correctly.

5. **Handle failure modes.** What happens if one side is down? Log the error, do not
   crash. Add to learnings_digest.md if behavior was surprising.

6. **Document the protocol.** Add a note in learnings_digest.md or the relevant
   architecture doc describing how the two components connect.

## Definition of done
- Real message flows end-to-end and is processed correctly
- Failure mode behavior is known (not necessarily handled, but documented)
- Protocol documented in learnings_digest.md or architecture file

## Full SOP
See: `memory/work/sop/sop_integration.md`
