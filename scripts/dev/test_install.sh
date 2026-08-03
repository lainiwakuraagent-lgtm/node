#!/usr/bin/env bash
# scripts/dev/test_install.sh
#
# Run install.sh against a fully disposable clone of blank_node, with
# guaranteed cleanup even on failure or interrupt. Never touches the
# blank_node template itself (install.sh's own guard would refuse that
# anyway — see the --i-know-this-is-the-template check).
#
# Every artifact this creates (clone directory, AGENT_NAME, systemd units,
# Loom DB) is namespaced under one unique tag, so a single run can never be
# confused with — or collide with — a real agent instance.
#
# Usage:
#   bash scripts/dev/test_install.sh                    # default minimal install
#   bash scripts/dev/test_install.sh -- --skip-khal      # extra flags passed to install.sh
#   KEEP_ON_FAILURE=1 bash scripts/dev/test_install.sh   # leave artifacts in place on failure, for debugging
#
# Note: this clones the template's committed HEAD, not uncommitted changes.
# Commit or stash first if you need to test work in progress.
#
# If a run is ever interrupted hard enough to skip cleanup (SIGKILL, host
# reboot), scripts/dev/sweep_test_instances.sh finds and removes anything
# left behind by tag.

set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="${HOME}/lain/_test_instances"
TAG="blanktest-$(date +%Y%m%d%H%M%S)-$$"
TEST_DIR="${TEST_ROOT}/${TAG}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
LOOM_DB="${HOME}/.local/share/loom/${TAG}.db"

# Shared/global files install.sh writes regardless of AGENT_NAME (channel
# templates + the env file that points them at a PROJECT_DIR) — used by
# every agent instance on this machine, not just the one under test. Backed
# up before the install runs and restored unconditionally on exit, so a test
# can never leave the real agents' channel plumbing pointed at a directory
# that's about to be deleted.
SHARED_FILES=(
  "${SYSTEMD_USER_DIR}/lain-channel.env"
  "${SYSTEMD_USER_DIR}/agent-channel@.service"
  "${SYSTEMD_USER_DIR}/channel-duration-watchdog@.service"
  "${SYSTEMD_USER_DIR}/channel-duration-watchdog@.timer"
)
SHARED_BACKUP_DIR="$(mktemp -d)"

KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
_test_failed=0

log()  { printf '[test_install] %s\n' "$*"; }
warn() { printf '[test_install] WARN: %s\n' "$*" >&2; }

cleanup() {
  local exit_code=$?
  [ "$exit_code" -ne 0 ] && _test_failed=1

  if [ "$_test_failed" = "1" ] && [ "$KEEP_ON_FAILURE" = "1" ]; then
    warn "Test failed — KEEP_ON_FAILURE=1, leaving ${TEST_DIR} and tag '${TAG}' artifacts in place for inspection."
    warn "Clean up later with: bash scripts/dev/sweep_test_instances.sh"
    rm -rf "$SHARED_BACKUP_DIR"
    return
  fi

  log "Cleaning up test instance (tag=${TAG}) ..."

  systemctl --user disable --now "${TAG}-night-agent.timer" >/dev/null 2>&1 || true
  systemctl --user stop "${TAG}-night-agent.service" >/dev/null 2>&1 || true
  systemctl --user disable --now "${TAG}-conversation.service" >/dev/null 2>&1 || true
  # channel-duration-watchdog@<dir-basename>.timer -- an INSTANCE of the
  # shared @.timer template (see SHARED_FILES above), keyed by the install
  # directory's basename rather than AGENT_NAME. Since TEST_DIR's basename
  # is the tag itself, this matches; disabling the instance doesn't touch
  # the shared template files.
  systemctl --user disable --now "channel-duration-watchdog@${TAG}.timer" >/dev/null 2>&1 || true
  systemctl --user stop "channel-duration-watchdog@${TAG}.service" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_USER_DIR}/${TAG}-night-agent.service" \
        "${SYSTEMD_USER_DIR}/${TAG}-night-agent.timer" \
        "${SYSTEMD_USER_DIR}/${TAG}-conversation.service" \
        "${SYSTEMD_USER_DIR}/timers.target.wants/${TAG}-night-agent.timer" \
        "${SYSTEMD_USER_DIR}/timers.target.wants/channel-duration-watchdog@${TAG}.timer"
  systemctl --user daemon-reload >/dev/null 2>&1 || true

  rm -f "$LOOM_DB"

  for f in "${SHARED_FILES[@]}"; do
    base="$(basename "$f")"
    if [ -f "${SHARED_BACKUP_DIR}/${base}" ]; then
      cp -f "${SHARED_BACKUP_DIR}/${base}" "$f"
    elif [ -f "${SHARED_BACKUP_DIR}/${base}.absent" ]; then
      rm -f "$f"
    fi
  done
  rm -rf "$SHARED_BACKUP_DIR"

  rm -rf "$TEST_DIR"

  if [ "$_test_failed" = "1" ]; then
    warn "Test FAILED. All test artifacts removed (tag=${TAG})."
  else
    log "Done. Nothing left behind (tag=${TAG})."
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT"

log "Backing up shared systemd files this install may touch ..."
for f in "${SHARED_FILES[@]}"; do
  base="$(basename "$f")"
  if [ -f "$f" ]; then
    cp -f "$f" "${SHARED_BACKUP_DIR}/${base}"
  else
    : > "${SHARED_BACKUP_DIR}/${base}.absent"
  fi
done

log "Cloning blank_node template (committed HEAD) -> ${TEST_DIR} (tag=${TAG}) ..."
git clone --quiet "$TEMPLATE_DIR" "$TEST_DIR"

log "Running install.sh --agent-name ${TAG} (non-interactive, minimal) ..."
bash "${TEST_DIR}/install.sh" \
  --agent-name "$TAG" \
  --owner-name "test" \
  --non-interactive \
  --skip-telegram \
  --skip-nexus \
  --skip-loom \
  --skip-khal \
  --skip-honcho \
  "$@"

log "install.sh completed. Verifying artifacts ..."

if [ ! -f "${TEST_DIR}/state/agent_config.env" ]; then
  warn "state/agent_config.env was not written."
  exit 1
fi
if ! grep -q "^AGENT_NAME=${TAG}\$" "${TEST_DIR}/state/agent_config.env"; then
  warn "AGENT_NAME in agent_config.env does not match the test tag."
  exit 1
fi
if ! systemctl --user is-enabled "${TAG}-night-agent.timer" >/dev/null 2>&1; then
  warn "${TAG}-night-agent.timer was not enabled."
  exit 1
fi

log "PASS — install.sh produced a working node instance (tag=${TAG})."
