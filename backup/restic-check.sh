#!/usr/bin/env bash
# =============================================================================
# restic repository health check (IDrive e2)
#
# Usage:
#   sudo /opt/mailcow-backup/restic-check.sh          # structure check
#   sudo /opt/mailcow-backup/restic-check.sh --data   # also verify 5% of data
#
# Run this monthly (or before/after major changes) as part of your DR routine.
# =============================================================================
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BACKUP_DIR}/mailcow-backup.env"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: ${ENV_FILE} not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"

if [[ "${RESTIC_PASSWORD:-}" == "CHANGE_ME"* ]]; then
  echo "ERROR: configure ${ENV_FILE} first." >&2
  exit 1
fi

RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:latest}"

RESTIC_ENV=(
  -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}"
  -e "RESTIC_PASSWORD=${RESTIC_PASSWORD}"
)
AWS_ENV=(
  -e "AWS_ACCESS_KEY_ID=${E2_ACCESS_KEY}"
  -e "AWS_SECRET_ACCESS_KEY=${E2_SECRET_KEY}"
)
if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_ENV+=(-e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}")
fi

run_restic() {
  local -a extra=()
  if [[ -n "${RESTIC_EXTRA_OPTS:-}" ]]; then
    read -r -a extra <<< "${RESTIC_EXTRA_OPTS}"
  fi
  docker run --rm "${RESTIC_ENV[@]}" "${AWS_ENV[@]}" "${RESTIC_IMAGE}" "${extra[@]}" "$@"
}

echo "==> snapshots (all)"
run_restic snapshots

echo
echo "==> latest snapshot"
run_restic snapshots --latest --compact

echo
echo "==> size of latest snapshot"
run_restic stats --latest

echo
if [[ "${1:-}" == "--data" ]]; then
  echo "==> repository check (structure + 5% of data blocks) - this can take a while"
  run_restic check --read-data-subset=5%
else
  echo "==> repository check (structure only; use --data for block verification)"
  run_restic check
fi

echo
echo "Check finished."
