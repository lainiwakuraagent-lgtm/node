---
name: sop-deployment
description: Procedure for tasks tagged deployment — moving an artifact from local development to a live environment where it runs persistently.
---

# SOP — Deployment

## When this applies
Any task tagged `deployment`: installing services, running bootstrap scripts,
pushing agent configs to remote machines, verifying first run.

## Procedure

1. **Pre-flight.** Check: PAT health (200), target machine reachable (SSH test),
   blank_node in sync (drift_report.py), credentials provisioned.

2. **Identify rollback.** Before deploying, know how to undo. If rollback takes >5 min,
   commit current state first.

3. **Execute deployment steps.** Follow the plan from the design/spec doc.
   One component at a time — do not pipeline multiple service installs.

4. **Verify.** Do NOT mark done without evidence:
   - `systemctl --user is-active {service}` → `active`
   - First log entry in the appropriate log file
   - End-to-end communication test (if service communicates with other services)

5. **Document.** Update `memory/work/pending_decisions.md` with what was deployed,
   where, and any followup actions.

## Definition of done
- Service(s) running (confirmed by status check, not assumption)
- Log evidence of first successful execution
- pending_decisions.md updated

## Full SOP
See: `memory/work/sop/sop_deployment.md` and `memory/work/sop/sop_agent_architecture.md`
