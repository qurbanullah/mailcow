#!/usr/bin/env bash
# =============================================================================
# Restore a mailcow backup from IDrive e2 (restic)
#
# Usage:
#   sudo /opt/mailcow-backup/restore.sh                # list snapshots
#   sudo /opt/mailcow-backup/restore.sh <snapshot-id>  # restore that snapshot
#
# What happens:
#   1. the chosen restic snapshot is downloaded to the local staging area
#   2. the official mailcow restore tool starts interactively, where you pick
#      which dataset(s) to restore (maildir, redis, rspamd, postfix, SQL, ...)
#
# WARNING: restoring SQL / vmail OVERWRITES live data. Read the prompts.
# =============================================================================
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BACKUP_DIR}/mailcow-backup.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

if [[ "${RESTIC_PASSWORD:-}" == "CHANGE_ME"* ]]; then
  echo "ERROR: configure ${ENV_FILE} first." >&2
  exit 1
fi

MAILCOW_DIR="${MAILCOW_INSTALL_DIR:-/opt/mailcow-dockerized}"
STAGING_DIR="${BACKUP_STAGING_DIR:-/var/backups/mailcow}"
RESTORE_ROOT="${STAGING_DIR}/restore"
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
  docker run --rm \
    "${RESTIC_ENV[@]}" \
    "${AWS_ENV[@]}" \
    -v "${RESTORE_ROOT}:/restore" \
    "${RESTIC_IMAGE}" \
    "${extra[@]}" \
    "$@"
}

SNAP_ID="${1:-}"

# --- 1. list snapshots / validate selection -----------------------------------
if [[ -z "${SNAP_ID}" ]]; then
  echo "Snapshots currently stored in the restic repository:"
  run_restic snapshots
  echo
  echo "Re-run with a snapshot id, e.g.:"
  echo "  sudo ${BACKUP_DIR}/restore.sh latest"
  echo "  sudo ${BACKUP_DIR}/restore.sh <hex-snapshot-id>"
  exit 0
fi

# --- 2. download snapshot ------------------------------------------------------
mkdir -p "${RESTORE_ROOT}"
echo "Restoring snapshot '${SNAP_ID}' to ${RESTORE_ROOT} ..."
run_restic restore "${SNAP_ID}" --target /restore

FOLDER="$(ls -1dt "${RESTORE_ROOT}"/data/mailcow-* 2>/dev/null | head -n1 || true)"
if [[ -z "${FOLDER}" ]]; then
  echo "ERROR: the snapshot '${SNAP_ID}' does not contain a mailcow backup folder." >&2
  echo "Pick a snapshot from the 'mailcow' tag (not 'mailcow-config')." >&2
  exit 1
fi

echo
echo "Restored backup folder: ${FOLDER}"
echo
echo "Starting the official mailcow restore tool (interactive)..."
echo "Select the dataset(s) you want to restore (e.g. 'all')."
echo
# --- 3. hand off to the interactive official restore tool ----------------------
export MAILCOW_BACKUP_LOCATION="$(dirname "${FOLDER}")"
cd "${MAILCOW_DIR}"
exec "${MAILCOW_DIR}/helper-scripts/backup_and_restore.sh" restore
