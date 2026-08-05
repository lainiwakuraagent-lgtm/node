# Dockerfile — blank_node agent image (supervisord process backend).
#
# Generic, not baked per-agent: AGENT_NAME/OWNER_NAME/credentials/etc. are
# supplied at `docker run`/compose time via env vars, applied by
# entrypoint.sh (which runs install.sh --non-interactive) against a
# persistent volume. One image, many containers.

FROM python:3.12-slim

# git/curl/ca-certificates: cloning + the many HTTP calls throughout the
# harness (Nexus, Telegram, Honcho). bash: every script here assumes it, not
# sh. build-essential/libffi-dev: khal's dependency chain needs a compiler on
# a slim image. nodejs/npm: the Claude Code CLI ships as an npm package.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      bash \
      build-essential \
      libffi-dev \
      nodejs \
      npm \
      sqlite3 \
      procps \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI. Auth is deliberately NOT done at build time — it's
# interactive OAuth, the one step install.sh's own docs already call out as
# unavoidable (see skills/sop-new-agent-deployment). Run it once per
# container/volume lifetime via: docker exec -it <container> claude auth login
RUN npm install -g @anthropic-ai/claude-code

# supervisord — the systemd replacement (see scripts/docker/supervisord.conf).
# khal — same package install.sh's Step 8b would otherwise do per-container;
# baking it here makes that step a fast per-agent-config-only pass at runtime.
RUN pip install --no-cache-dir supervisor khal

# Non-root agent user. Claude CLI refuses --dangerously-skip-permissions when
# running as root — all supervised programs (claude, python scripts) must run
# as a non-root uid. supervisord itself still starts as root (PID 1) so it can
# bind to /tmp/supervisor.sock and fix volume ownership on start; individual
# programs use user=agent in supervisord.conf.
RUN useradd -m -u 1000 -s /bin/bash agent

WORKDIR /app

# Loom, pinned and shared across every agent built from this image (Loom
# itself doesn't vary per agent — only the per-agent DB path and bin/loom
# wrapper do, which install.sh's Step 8 still writes at container start).
RUN git clone --quiet https://github.com/lainiwakuraagent-lgtm/loom.git /app/loom \
    && python3 -m venv /app/loom/.venv \
    && /app/loom/.venv/bin/pip install --no-cache-dir -e /app/loom
# Tell wake.sh where loom lives in this container. Without this, wake.sh defaults
# to ~/lain/loom which resolves to /root/lain/loom (missing) in Docker.
ENV LOOM_SRC=/app/loom

# Application code (.git, secrets, and runtime-generated state excluded —
# see .dockerignore).
COPY . /app

RUN chmod +x /app/scripts/docker/entrypoint.sh /app/install.sh \
    && chown -R agent:agent /app /home/agent

ENTRYPOINT ["/app/scripts/docker/entrypoint.sh"]
