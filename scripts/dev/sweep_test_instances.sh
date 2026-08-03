#!/usr/bin/env bash
# scripts/dev/sweep_test_instances.sh
#
# Finds and (optionally) removes anything left behind by test_install.sh
# under the blanktest-* tag — the safety net for the case where a test run
# was killed hard enough (SIGKILL, host reboot mid-test) to skip its own
# cleanup trap, or was left in place deliberately via KEEP_ON_FAILURE=1.
#
# Usage:
#   bash scripts/dev/sweep_test_instances.sh            # list only, no changes
#   bash scripts/dev/sweep_test_instances.sh --force    # list and remove

set -euo pipefail

TEST_ROOT="${HOME}/lain/_test_instances"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
LOOM_DIR="${HOME}/.local/share/loom"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      printf 'Usage: %s [--force]\n' "$0"
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

log() { printf '[sweep] %s\n' "$*"; }

# --- Collect all blanktest-* tags from every possible artifact location ---
declare -A tags=()

if [ -d "$TEST_ROOT" ]; then
  for d in "$TEST_ROOT"/blanktest-*; do
    [ -d "$d" ] || continue
    tags["$(basename "$d")"]=1
  done
fi

for f in "$SYSTEMD_USER_DIR"/blanktest-*-night-agent.timer; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  tags["${base%-night-agent.timer}"]=1
done

# channel-duration-watchdog@<tag>.timer is an INSTANCE of a shared template
# (no unit file of its own), only visible via its enablement symlink -- must
# be discovered separately or a leak here (with no other artifact left)
# would be invisible to this sweep.
for f in "$SYSTEMD_USER_DIR"/timers.target.wants/channel-duration-watchdog@blanktest-*.timer; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  base="${base#channel-duration-watchdog@}"
  tags["${base%.timer}"]=1
done

for f in "$LOOM_DIR"/blanktest-*.db; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  tags["${base%.db}"]=1
done

if [ "${#tags[@]}" -eq 0 ]; then
  log "Nothing to clean up — no blanktest-* artifacts found."
  exit 0
fi

log "Found ${#tags[@]} leftover test instance(s):"
for tag in "${!tags[@]}"; do
  printf '\n  %s\n' "$tag"
  [ -d "${TEST_ROOT}/${tag}" ]                          && printf '    - directory: %s\n' "${TEST_ROOT}/${tag}"
  [ -f "${SYSTEMD_USER_DIR}/${tag}-night-agent.timer" ]   && printf '    - timer:     %s-night-agent.timer\n' "$tag"
  [ -f "${SYSTEMD_USER_DIR}/${tag}-night-agent.service" ] && printf '    - service:   %s-night-agent.service\n' "$tag"
  [ -f "${SYSTEMD_USER_DIR}/${tag}-conversation.service" ] && printf '    - service:   %s-conversation.service\n' "$tag"
  systemctl --user is-enabled "channel-duration-watchdog@${tag}.timer" >/dev/null 2>&1 \
    && printf '    - timer:     channel-duration-watchdog@%s.timer (instance)\n' "$tag"
  [ -f "${LOOM_DIR}/${tag}.db" ]                          && printf '    - loom db:   %s.db\n' "$tag"
done
printf '\n'

if [ "$FORCE" -eq 0 ]; then
  log "Listed only — rerun with --force to remove all of the above."
  exit 0
fi

for tag in "${!tags[@]}"; do
  log "Removing ${tag} ..."
  systemctl --user disable --now "${tag}-night-agent.timer" >/dev/null 2>&1 || true
  systemctl --user stop "${tag}-night-agent.service" >/dev/null 2>&1 || true
  systemctl --user disable --now "${tag}-conversation.service" >/dev/null 2>&1 || true
  systemctl --user disable --now "channel-duration-watchdog@${tag}.timer" >/dev/null 2>&1 || true
  systemctl --user stop "channel-duration-watchdog@${tag}.service" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_USER_DIR}/${tag}-night-agent.service" \
        "${SYSTEMD_USER_DIR}/${tag}-night-agent.timer" \
        "${SYSTEMD_USER_DIR}/${tag}-conversation.service" \
        "${SYSTEMD_USER_DIR}/timers.target.wants/${tag}-night-agent.timer" \
        "${SYSTEMD_USER_DIR}/timers.target.wants/channel-duration-watchdog@${tag}.timer"
  rm -f "${LOOM_DIR}/${tag}.db"
  rm -rf "${TEST_ROOT}/${tag}"
done
systemctl --user daemon-reload >/dev/null 2>&1 || true

log "Removed ${#tags[@]} test instance(s). Nothing left behind."
