#!/usr/bin/env bash
# =============================================================================
# Shared helpers for the mailcow deployment scripts (this folder).
#
# Sourced by: deploy.sh, server-prep.sh, firewall.sh, verify.sh
#
# Project config:  mailcow.env   (edit directly - it is part of the kit)
#
# Precedence for every value:
#   1. environment variable already set when the script starts
#   2. value from mailcow.env
#   3. built-in default inside the individual script
# =============================================================================

# Project root (this file lives next to the scripts that source it)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/mailcow.env}"

# --- logging -----------------------------------------------------------------
info() { echo -e "\e[36m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[ OK ]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
die()  { echo -e "\e[31m[FAIL]\e[0m $*" >&2; exit 1; }

# --- config loader -------------------------------------------------------------
# Reads mailcow.env (plain "VAR=value" lines - no quotes, no inline comments)
# and assigns each variable ONLY if it is not already set in the environment,
# so per-run overrides like "SSH_PORT=2222 sudo ./deploy.sh" always win.
load_project_config() {
  [[ -f "${CONFIG_FILE}" ]] || return 0
  local line key val
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "${line}" in
      ""|\#*) continue ;;
    esac
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    # only plain identifiers, and never our own machinery
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ "${key}" == "SCRIPT_DIR" || "${key}" == "CONFIG_FILE" ]] && continue
    if [[ -z "${!key:-}" ]]; then
      printf -v "${key}" "%s" "${val}"
    fi
  done < "${CONFIG_FILE}"
}
