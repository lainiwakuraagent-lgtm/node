---
name: sop-new-agent-deployment
description: Procedure for standing up a brand-new blank_node agent instance on a target machine via install.sh --remote. For pushing changes to an already-running agent's install, use sop-deployment instead.
---

# SOP — New Agent Deployment

## When this applies

Provisioning a new agent instance from the blank_node template on a target
machine — local or remote/SSH — for the first time. This is `install.sh`'s
job end-to-end; this SOP is the runbook around it (what to check before,
during, and after).

Not for: pushing an update to an existing agent's install (that's ordinary
deployment — see `sop-deployment`), or disposable install.sh code-change
testing (that's `scripts/dev/test_install.sh`, local-only, throwaway by
design).

## Prerequisites

- SSH key access to the target host (default `~/.ssh/id_ed25519`), target
  reachable over Tailscale.
- GitHub PAT for cloning the blank_node/loom repos — auto-read from
  `identity/credentials.md` if present, or pass `--github-pat`.
- Decided up front: `AGENT_NAME` (slug, lowercase/digits/hyphens/underscores),
  `OWNER_NAME`, and which integrations get configured now vs. deferred
  (Telegram token+chat ID, Nexus URL, Honcho URL+workspace).
- Target machine has (or install.sh will report missing): Python 3.10+, git,
  `systemd --user`. Missing systemd degrades gracefully — install.sh skips
  unit installation and tells you how to run the agent manually instead.

## Procedure

1. **Dry-run first — always.** Costs nothing, catches config mistakes before
   touching the target:
   ```
   bash install.sh --remote --target-host <ip> --target-user <user> \
     --agent-name <name> --owner-name <owner> --non-interactive --dry-run \
     [--telegram-token ... --nexus-url ... ]
   ```
   Read the full step-by-step output, not just the exit code. Fix anything
   that looks wrong before proceeding — a dry-run catching a bad flag is
   free; the same mistake live means cleanup on a shared machine.

2. **Run for real** — identical command, minus `--dry-run`.

3. **Auth Claude CLI on the target.** The one step install.sh cannot
   automate (interactive OAuth):
   ```
   ssh <user>@<host> 'claude auth login'
   ```

4. **Verify — do not mark done without evidence:**
   - `ssh <user>@<host> 'systemctl --user list-timers | grep <agent-name>'`
     → timer present, next-run time sane
   - Trigger a manual wake and confirm a real log entry, rather than waiting
     for the nightly window:
     `ssh <user>@<host> 'TRIGGER_MODE=manual bash <install-path>/scripts/executional/wake.sh'`
     then `tail -30 <install-path>/logs/wake.log`
   - Telegram configured → send it a message, confirm a reply
   - Nexus configured → confirm registration (install.sh prints `agent_id`
     on success, or check via the Nexus API directly)
   - Honcho configured → `honcho_client.py --test-read <peer>` on the
     target; empty output is fine (no data yet), a connection error is not

5. **Document.** Update `memory/work/pending_decisions.md` (or the relevant
   goal's notes) with: what was deployed, where, `AGENT_NAME`, which
   integrations are live vs. deferred, and any manual follow-ups still open.

## Rollback

Nothing in a fresh install is destructive to existing state on the target —
`install.sh` only ever writes under one `AGENT_NAME`'s own paths and
namespaced systemd units. To remove a bad deploy:
```
ssh <user>@<host> 'systemctl --user disable --now <agent-name>-night-agent.timer <agent-name>-conversation.service'
ssh <user>@<host> 'rm -rf <install-path>'
```
Leave alone: `agent-channel@.service`, `channel-duration-watchdog@.{service,timer}`,
`lain-channel.env` in `~/.config/systemd/user/` — these are shared templates
reused by every agent on that host, not this instance's own files. Only
remove them if every agent on the host is being torn down.

## Definition of done

- Timer enabled and active on the target (confirmed by status check, not assumption)
- A real wake produced a log entry — manually triggered or scheduled, either counts
- Every integration configured at install time verified live (message sent,
  registration confirmed, read tested) — "configured" is not "working"
- `pending_decisions.md` updated
