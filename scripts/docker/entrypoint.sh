#!/usr/bin/env bash
# scripts/docker/entrypoint.sh — container entrypoint.
#
# Idempotent: runs install.sh --non-interactive on every container start
# against the (persistent, volume-backed) state/identity/memory/logs
# directories, then hands off to supervisord as PID 1. Re-running install.sh
# every start is intentional, not wasteful — it's how env-var-driven config
# (TELEGRAM_TOKEN, NEXUS_URL, HONCHO_URL, ... passed via `docker run -e`)
# takes effect on restart, matching install.sh's existing idempotent design
# (Step 6's Nexus registration already treats 409 as success, etc).
#
# Loom and khal are NOT skipped here even though the Dockerfile bakes the
# shared git clone/venv/binary at build time: install.sh's Steps 8/8b still
# do per-agent work every run regardless (the bin/loom wrapper and LOOM_DB
# path are keyed by AGENT_NAME; khal.cfg is written per agent too) — they
# just detect the binary/venv already present and skip straight to that part,
# so re-running is fast, not wasteful.
#
# --i-know-this-is-the-template: install.sh's guard against installing into
# the template checkout in place is exactly wrong here — a Docker container
# built from this checkout *is* meant to become a live agent instance. The
# guard's own detection (git origin remote) won't even fire since .git is
# excluded from the build context (see .dockerignore), but this is kept as
# a defensive belt-and-suspenders in case that ever changes.

set -euo pipefail

PROJECT_DIR="/app"
cd "$PROJECT_DIR"

mkdir -p state/supervisor_channels.d logs

# Fix volume ownership: named volumes are created by Docker with root:root even
# when the image user is agent. entrypoint.sh runs as root (PID 1 on first
# start) so we can chown the volume mount points before dropping to agent.
# This is a no-op on subsequent starts if already owned correctly.
chown -R agent:agent \
    /app/state /app/identity /app/memory /app/config \
    /app/logs /app/prompts /app/inbox \
    /home/agent 2>/dev/null || true

echo "[entrypoint] Running install.sh as agent (non-interactive, idempotent) ..."
su agent -c "
  cd /app
  bash install.sh \
    --non-interactive \
    --i-know-this-is-the-template
"

echo "[entrypoint] install.sh done. Handing off to supervisord."
exec supervisord -c "${PROJECT_DIR}/scripts/docker/supervisord.conf"
