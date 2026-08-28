#!/usr/bin/env bash
# =============================================================================
# Restore a SINGLE mailbox from the mailcow backup (IDrive e2 / restic)
#
# Usage:
#   sudo /opt/mailcow-backup/restore-mailbox.sh user@example.com
#   sudo /opt/mailcow-backup/restore-mailbox.sh user@example.com <snapshot-id>
#   sudo /opt/mailcow-backup/restore-mailbox.sh --list
#
# How it works:
#   1. downloads the chosen restic snapshot (default: latest "mailcow" one)
#   2. extracts ONLY that mailbox's Maildir from backup_vmail.tar.zst
#   3. copies it into the live vmail volume (ownership vmail:5000)
#   4. re-syncs dovecot indexes for that user
#
# NOTE: this MERGES with existing data - mail received after the snapshot is
# kept (existing files are not deleted). If the mailbox ACCOUNT itself was
# deleted, recreate it first in the mailcow UI (the account lives in the
# database, not in the backup) - then restore the mail with this script.
# =============================================================================
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BACKUP_DIR}/mailcow-backup.env"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: ${ENV_FILE} not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"

if [[ "${RESTIC_PASSWORD:-}" == "CHANGE_ME"* || -z "${RESTIC_REPOSITORY:-}" ]]; then
  echo "ERROR: configure ${ENV_FILE} first." >&2
  exit 1
fi

MAILCOW_DIR="${MAILCOW_INSTALL_DIR:-/opt/mailcow-dockerized}"
STAGING_DIR="${BACKUP_STAGING_DIR:-/var/backups/mailcow}"
RESTORE_ROOT="${STAGING_DIR}/restore-mailbox"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:latest}"
BACKUP_IMAGE="${BACKUP_IMAGE:-ghcr.io/mailcow/backup:latest}"
RESTIC_HOSTNAME="${RESTIC_HOSTNAME:-$(hostname)}"
VMAIL_UID="${VMAIL_UID:-5000}"   # mailcow's vmail user uid (dovecot container)

info() { echo -e "\e[36m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[ OK ]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
die()  { echo -e "\e[31m[FAIL]\e[0m $*" >&2; exit 1; }

usage() {
  echo "Usage: sudo $0 user@example.com [snapshot-id]"
  echo "       sudo $0 --list"
}

RESTIC_ENV=(
  -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}"
  -e "RESTIC_PASSWORD=${RESTIC_PASSWORD}"
)
AWS_ENV=(
  -e "AWS_ACCESS_KEY_ID=${E2_ACCESS_KEY:-}"
  -e "AWS_SECRET_ACCESS_KEY=${E2_SECRET_KEY:-}"
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

EMAIL="${1:-}"
SNAPSHOT_ID="${2:-latest}"

case "${EMAIL}" in
  --list|-l) run_restic snapshots --tag mailcow --compact; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  ""|"") usage >&2; exit 1 ;;
esac

[[ "${EMAIL}" == *"@"* && "${EMAIL}" != @* ]] || die "invalid email: ${EMAIL} (expected user@example.com)"
DOMAIN="${EMAIL#*@}"
LOCALPART="${EMAIL%@*}"

# --- 1. download the snapshot ---------------------------------------------------
mkdir -p "${RESTORE_ROOT}"
trap 'rm -rf "${RESTORE_ROOT}"' EXIT

info "Restoring snapshot '${SNAPSHOT_ID}' ..."
if [[ "${SNAPSHOT_ID}" == "latest" ]]; then
  run_restic restore latest --tag mailcow --host "${RESTIC_HOSTNAME}" --target /restore
else
  run_restic restore "${SNAPSHOT_ID}" --target /restore
fi

FOLDER="$(ls -1dt "${RESTORE_ROOT}"/data/mailcow-* 2>/dev/null | head -n1 || true)"
[[ -n "${FOLDER}" && -f "${FOLDER}/backup_vmail.tar.zst" ]] \
  || die "no backup_vmail.tar.zst found in snapshot '${SNAPSHOT_ID}' - pick a 'mailcow' tagged snapshot (see --list)"

# --- 2. extract only this mailbox from the vmail archive --------------------------
WORKDIR="$(mktemp -d "${RESTORE_ROOT}/extract.XXXXXX")"
info "Extracting ${EMAIL} from backup_vmail.tar.zst ..."
docker run --rm \
  -v "${FOLDER}:/backup:ro" \
  -v "${WORKDIR}:/extract" \
  "${BACKUP_IMAGE}" /bin/tar \
    --use-compress-program="zstd -d" \
    -x -C /extract \
    -f /backup/backup_vmail.tar.zst \
    "/vmail/${DOMAIN}/${LOCALPART}"

[[ -d "${WORKDIR}/vmail/${DOMAIN}/${LOCALPART}" ]] \
  || die "mailbox ${EMAIL} was not found in this backup snapshot"

# --- 3. copy into the live vmail volume (merge, ownership vmail) ------------------
VMAIL_VOL="$(docker volume ls -qf name=vmail-vol-1 | head -n1)"
[[ -n "${VMAIL_VOL}" ]] || die "vmail docker volume not found - is mailcow installed?"

info "Copying into volume ${VMAIL_VOL} (merge, owner ${VMAIL_UID}:${VMAIL_UID}) ..."
docker run --rm \
  -v "${WORKDIR}:/from:ro" \
  -v "${VMAIL_VOL}:/vmail" \
  "${BACKUP_IMAGE}" /bin/sh -c \
  "mkdir -p '/vmail/${DOMAIN}/${LOCALPART}' && \
   cp -a '/from/vmail/${DOMAIN}/${LOCALPART}/.' '/vmail/${DOMAIN}/${LOCALPART}/' && \
   chown -R ${VMAIL_UID}:${VMAIL_UID} '/vmail/${DOMAIN}/${LOCALPART}'"
ok "mailbox files restored to /vmail/${DOMAIN}/${LOCALPART}"

# --- 4. re-sync dovecot indexes -----------------------------------------------------
DOVECOT="$(docker ps -qf name=dovecot-mailcow)"
if [[ -n "${DOVECOT}" ]]; then
  docker exec "${DOVECOT}" doveadm force-resync -u "${EMAIL}"
  docker exec "${DOVECOT}" doveadm mailbox status -u "${EMAIL}" messages 2>/dev/null \
    && ok "dovecot re-synced for ${EMAIL}" \
    || warn "doveadm status failed for ${EMAIL} - check the mailbox exists in the UI"
else
  warn "dovecot container not running - files restored; run 'doveadm force-resync -u ${EMAIL}' once it is up"
fi

echo
echo "Done. ${EMAIL} has been restored from snapshot '${SNAPSHOT_ID}'."
echo "TIP: if new mail does not show up in the client, re-login or 'doveadm force-resync -u ${EMAIL}'."
