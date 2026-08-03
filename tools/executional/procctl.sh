#!/usr/bin/env bash
# procctl.sh — Process control shim.
#
# Routes start/stop/is-active/restart/list-units calls to the active backend.
# Backend is set by PROCESS_BACKEND in state/agent_config.env; auto-detected
# as "systemd" if systemctl --user responds, else "supervisord".
#
# Usage:  procctl.sh <verb> [args...]
#
# Verbs and args mirror systemctl's calling convention exactly, so call sites
# switch from ["systemctl", "--user", ...] to [str(PROCCTL), ...] unchanged.
#
#   is-active <unit>                      exit 0 + "active" if running
#   start <unit>                          start the unit
#   stop <unit>                           stop the unit
#   restart <unit>                        restart the unit
#   list-units <pattern> [flags...]       list active matching units as JSON
#
# systemd backend: transparent pass-through to "systemctl --user "$@"".
#
# supervisord backend: maps unit names to supervisord program names via the
# convention  foo@bar.service → foo-bar  (@ → -, strip .service).
# list-units returns a JSON array in the same shape as systemctl --output=json.
# NOTE: channel_id values that themselves contain "-" create ambiguity in the
# reverse mapping (prog → unit). Callers that depend on the reconstructed unit
# name must therefore ensure channel IDs do not contain "-", or adopt a
# different name separator in supervisord.conf.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_ENV="${PROJECT_DIR}/state/agent_config.env"

# Source backend config (safe: only reads PROCESS_BACKEND and similar vars)
PROCESS_BACKEND="${PROCESS_BACKEND:-}"
if [[ -f "$CONFIG_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_ENV" 2>/dev/null || true
fi

# Auto-detect if still unset
if [[ -z "${PROCESS_BACKEND:-}" ]]; then
    if systemctl --user status >/dev/null 2>&1; then
        PROCESS_BACKEND="systemd"
    else
        PROCESS_BACKEND="supervisord"
    fi
fi

# ──────────────────────────────── systemd ─────────────────────────────────────

if [[ "${PROCESS_BACKEND}" == "systemd" ]]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    exec systemctl --user "$@"
fi

# ─────────────────────────────── supervisord ──────────────────────────────────

if [[ "${PROCESS_BACKEND}" != "supervisord" ]]; then
    echo "procctl: unknown PROCESS_BACKEND: ${PROCESS_BACKEND}" >&2
    exit 1
fi

# Map unit name → supervisord program name: foo@bar.service → foo-bar
_unit_to_prog() {
    local unit="${1}"
    unit="${unit%.service}"
    unit="${unit//@/-}"
    echo "${unit}"
}

# Extract the template prefix from a glob pattern: foo@*.service → foo
_pattern_prefix() {
    local pattern="${1}"
    pattern="${pattern%%@*}"
    echo "${pattern}"
}

VERB="${1:-}"
shift || true   # remaining args after verb

case "${VERB}" in

  is-active)
    PROG="$(_unit_to_prog "${1:-}")"
    STATUS="$(supervisorctl status "${PROG}" 2>/dev/null || true)"
    if echo "${STATUS}" | grep -q "RUNNING"; then
        echo "active"
        exit 0
    else
        echo "inactive"
        exit 3
    fi
    ;;

  start)
    PROG="$(_unit_to_prog "${1:-}")"
    exec supervisorctl start "${PROG}"
    ;;

  stop)
    PROG="$(_unit_to_prog "${1:-}")"
    exec supervisorctl stop "${PROG}"
    ;;

  restart)
    PROG="$(_unit_to_prog "${1:-}")"
    exec supervisorctl restart "${PROG}"
    ;;

  list-units)
    # Signature: list-units <pattern> [--state=active] [--output=json] [--no-pager]
    # Only <pattern> is used; the flags are accepted but silently ignored since
    # supervisorctl's JSON output is always filtered to RUNNING programs.
    PATTERN="${1:-}"
    PREFIX="$(_pattern_prefix "${PATTERN}")"

    mapfile -t STATUSES < <(supervisorctl status 2>/dev/null || true)
    JSON_UNITS=()
    for LINE in "${STATUSES[@]}"; do
        PROG_NAME="$(echo "${LINE}" | awk '{print $1}')"
        STATE="$(echo "${LINE}" | awk '{print $2}')"
        # Match programs whose name starts with the template prefix followed by -
        if [[ "${PROG_NAME}" == "${PREFIX}-"* ]] && [[ "${STATE}" == "RUNNING" ]]; then
            # Reconstruct unit name: strip prefix-, remainder is the instance id
            INSTANCE="${PROG_NAME#"${PREFIX}-"}"
            UNIT_NAME="${PREFIX}@${INSTANCE}.service"
            JSON_UNITS+=("{\"unit\": \"${UNIT_NAME}\", \"active\": \"active\"}")
        fi
    done

    if [[ ${#JSON_UNITS[@]} -eq 0 ]]; then
        echo "[]"
    else
        JOINED="$(printf '%s,' "${JSON_UNITS[@]}")"
        echo "[${JOINED%,}]"
    fi
    ;;

  *)
    echo "procctl: unknown verb: ${VERB}" >&2
    exit 1
    ;;

esac
