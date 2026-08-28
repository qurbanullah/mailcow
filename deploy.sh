#!/usr/bin/env bash
# =============================================================================
# mailcow - enterprise deployment for htasol.net (Contabo VPS)
#
# Run on the VPS as root:
#     sudo ./deploy.sh
#
# What it does:
#   1. Installs Docker Engine (>= 24) + Docker Compose plugin (Debian/Ubuntu)
#   2. Sets the system timezone (SERVER_TZ, default UTC - industry standard)
#   3. Applies sysctl tuning for a busy mail server
#   4. Clones mailcow-dockerized to /opt/mailcow-dockerized
#   5. Generates mailcow.conf NON-INTERACTIVELY using the official
#      generate_config.sh (env-var driven, no prompts)
#   6. Optionally configures UFW (mail + web ports)
#   7. Starts the stack: docker compose pull && docker compose up -d
#   8. Installs backup tooling (restic -> IDrive e2) + systemd timer
#
# Requirements: Debian 12, or Ubuntu LTS 22.04 / 24.04 / 26.04, root access,
#               ~4 GB RAM (2.5 GB works but ClamAV gets disabled automatically)
# =============================================================================
set -euo pipefail

# --- shared helpers & project config (mailcow.env) -------------------------
# Values are read from mailcow.env; everything below is only a fallback
# default. Per-run environment variables (e.g. MAILCOW_TZ=Asia/Karachi
# sudo ./deploy.sh) win over the config file.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_project_config

# ------------------------------- DEFAULTS -------------------------------
# Mail server hostname (FQDN). Must match an A record of this server!
MAILCOW_HOSTNAME="${MAILCOW_HOSTNAME:-mail.htasol.net}"

# System (OS) timezone, applied with timedatectl. UTC is the industry
# standard for servers (DST-free logs/timers); users still see their own
# local time in SOGo and mail clients.
SERVER_TZ="${SERVER_TZ:-UTC}"

# Timezone for the mailcow containers (UI defaults, container logs).
# UTC recommended; each user can set their own timezone in SOGo/UI.
MAILCOW_TZ="${MAILCOW_TZ:-UTC}"

# mailcow branch: master (stable, recommended) | nightly (unstable)
MAILCOW_BRANCH="${MAILCOW_BRANCH:-master}"

# Install directory on the VPS
INSTALL_DIR="${INSTALL_DIR:-/opt/mailcow-dockerized}"

# Backup tooling locations
BACKUP_DIR="/opt/mailcow-backup"
STAGING_DIR="${STAGING_DIR:-/var/backups/mailcow}"

# Enable UFW firewall? (y/n)
ENABLE_FIREWALL="${ENABLE_FIREWALL:-y}"

# Desired SSH port (mailcow.env / env). setup_firewall always opens the
# port sshd ACTUALLY listens on (detected via sshd -T) so a mismatch can
# never lock you out; if this value differs, both ports are opened.
SSH_PORT="${SSH_PORT:-}"
# -------------------------------------------------------------------------
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(uname -m)"
MEM_TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

info() { echo -e "\e[36m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[ OK ]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
die()  { echo -e "\e[31m[FAIL]\e[0m $*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Please run as root:  sudo ./deploy.sh"
}

install_deps() {
  info "Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y ca-certificates curl git openssl netcat-openbsd ufw jq >/dev/null
  # dig: bind9-dnsutils is the real package on Ubuntu 24.04+/26.04 and Debian 12;
  # dnsutils is only a transitional package there. Older releases need dnsutils.
  if apt-cache show bind9-dnsutils >/dev/null 2>&1; then
    apt-get install -y bind9-dnsutils >/dev/null
  else
    apt-get install -y dnsutils >/dev/null
  fi
  ok "base packages installed"
}

set_server_timezone() {
  if command -v timedatectl >/dev/null 2>&1; then
    local current
    current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ "${current}" != "${SERVER_TZ}" ]]; then
      info "setting system timezone to ${SERVER_TZ} (was: ${current:-unknown})..."
      timedatectl set-timezone "${SERVER_TZ}"
    fi
    ok "system timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo "${SERVER_TZ}")"
  else
    warn "timedatectl not available - set the system timezone to ${SERVER_TZ} manually"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version)"
  else
    info "Installing Docker Engine via official script (get.docker.com)..."
    if ! curl -fsSL https://get.docker.com | sh; then
      warn "get.docker.com failed (new Ubuntu codename?) - falling back to Ubuntu packages"
      apt-get install -y docker.io docker-compose-v2 >/dev/null
    fi
  fi
  command -v docker >/dev/null 2>&1 || die "docker binary not found after install"

  systemctl enable --now docker >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do docker info >/dev/null 2>&1 && break; sleep 3; done

  if ! docker compose version >/dev/null 2>&1; then
    info "Installing docker compose plugin..."
    apt-get install -y docker-compose-plugin >/dev/null 2>&1 \
      || apt-get install -y docker-compose-v2 >/dev/null
  fi

  local version major
  version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  major="$(echo "${version}" | cut -d. -f1)"
  [[ "${major}" =~ ^[0-9]+$ && ${major} -ge 24 ]] || die "mailcow needs Docker >= 24 (found: ${version})"
  ok "Docker ${version} + compose plugin ready"
}

apply_sysctl() {
  if [[ -f "${SCRIPT_DIR}/sysctl-mailcow.conf" ]]; then
    install -m 0644 "${SCRIPT_DIR}/sysctl-mailcow.conf" /etc/sysctl.d/99-mailcow.conf
    sysctl --system >/dev/null 2>&1 || true
    ok "sysctl tuning applied (/etc/sysctl.d/99-mailcow.conf)"
  fi
}

clone_mailcow() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    ok "mailcow repo already present: ${INSTALL_DIR}"
    return
  fi
  info "Cloning mailcow-dockerized -> ${INSTALL_DIR} ..."
  git clone https://github.com/mailcow/mailcow-dockerized "${INSTALL_DIR}"
  ok "cloned mailcow-dockerized"
}

generate_config() {
  cd "${INSTALL_DIR}"

  # generate_config.sh requires a .env symlink pointing at mailcow.conf
  [[ -L .env ]] || ln -s mailcow.conf .env

  # Re-runs: preserve DB credentials and ClamAV decision from the old config,
  # and move the old file out of the way so generate_config.sh stays quiet.
  if [[ -f mailcow.conf ]]; then
    info "Existing mailcow.conf found - preserving credentials across re-run"
    # shellcheck disable=SC1091
    source mailcow.conf
    export MAILCOW_DBPASS="${DBPASS:-}"
    export MAILCOW_DBROOT="${DBROOT:-}"
    export MAILCOW_REDISPASS="${REDISPASS:-}"
    export SKIP_CLAMD="${SKIP_CLAMD:-}"
    mv mailcow.conf "mailcow.conf.backup.$(date +%s)"
  fi

  # Non-interactive setup: these env vars make generate_config.sh skip all prompts
  export MAILCOW_HOSTNAME
  export MAILCOW_TZ
  export MAILCOW_BRANCH
  export COMPOSE_VERSION="native"
  if [[ ${MEM_TOTAL_KB} -le 2621440 ]]; then
    export SKIP_CLAMD="${SKIP_CLAMD:-y}"   # <= 2.5 GiB RAM: disable ClamAV
  else
    export SKIP_CLAMD="${SKIP_CLAMD:-n}"
  fi

  info "Running official generate_config.sh (non-interactive)..."
  ./generate_config.sh

  grep -q "^MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}$" mailcow.conf \
    || die "MAILCOW_HOSTNAME not set correctly in mailcow.conf"
  grep -q "^DOCKER_COMPOSE_VERSION=native$" mailcow.conf \
    || sed -i "s/^DOCKER_COMPOSE_VERSION=.*/DOCKER_COMPOSE_VERSION=native/" mailcow.conf

  # If the host has no global IPv6, disable IPv6 inside mailcow (prevents
  # bind errors / open-relay risks) - and remember to drop the AAAA record.
  if ! ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    warn "No global IPv6 on this host - setting ENABLE_IPV6=false"
    warn "If you created an AAAA record for mail.htasol.net, delete it."
    sed -i "s/^ENABLE_IPV6=.*/ENABLE_IPV6=false/" mailcow.conf
  fi
  ok "mailcow.conf generated: ${INSTALL_DIR}/mailcow.conf"
}

setup_firewall() {
  if [[ "${ENABLE_FIREWALL}" == "y" && -f "${SCRIPT_DIR}/firewall.sh" ]]; then
    # The firewall MUST allow the port sshd actually listens on, otherwise a
    # config mismatch locks you out (e.g. mailcow.env says 63521 but sshd is
    # still on 22). When the desired port differs from reality, open both and
    # tell the user to finish the move.
    local actual=""
    actual="$(sshd -T 2>/dev/null | awk '/^port[[:space:]]/ {print $2; exit}' || true)"
    actual="${actual:-22}"
    if [[ -n "${SSH_PORT}" && "${SSH_PORT}" != "${actual}" ]]; then
      warn "mailcow.env sets SSH_PORT=${SSH_PORT} but sshd currently listens on ${actual} - opening BOTH in UFW."
      warn "Finish the move with:  sudo ./server-prep.sh --ssh-port ${SSH_PORT}"
      bash "${SCRIPT_DIR}/firewall.sh" "${actual}" "${SSH_PORT}"
    else
      bash "${SCRIPT_DIR}/firewall.sh" "${actual}"
    fi
  else
    warn "Skipping UFW setup (ENABLE_FIREWALL != y) - open the mail ports in the Contabo panel firewall!"
  fi
}

start_stack() {
  cd "${INSTALL_DIR}"
  info "Pulling mailcow images (this can take several minutes)..."
  # flaky registries / IPv6 paths reset mid-transfer; retry a few times
  local attempts=3 i
  for ((i = 1; i <= attempts; i++)); do
    if docker compose pull; then
      break
    fi
    if (( i < attempts )); then
      warn "image pull failed (attempt ${i}/${attempts}) - retrying in 15s..."
      sleep 15
    else
      die "image pull failed after ${attempts} attempts - check network/IPv6 (see README troubleshooting)"
    fi
  done
  info "Starting mailcow..."
  docker compose up -d
  info "Waiting for containers to come up..."
  sleep 20
  echo
  docker compose ps --format "table {{.Name}}\t{{.Status}}"
}

install_backup_tooling() {
  local backup_src="${SCRIPT_DIR}/backup"
  [[ -d "${backup_src}" ]] || { warn "backup/ directory missing - skipping backup tooling"; return 0; }

  # Fail with a clear message when the kit is incomplete (instead of a
  # cryptic 'install: No such file or directory').
  local required=(backup.sh restore.sh restic-check.sh mailcow-backup.env mailcow-backup.service mailcow-backup.timer)
  local missing="" f src_env="${backup_src}/mailcow-backup.env"
  for f in "${required[@]}"; do
    [[ -f "${backup_src}/${f}" ]] || missing="${missing} ${f}"
  done
  if [[ -n "${missing}" ]]; then
    die "backup/ tooling is incomplete on this host - missing:${missing}. Run 'git pull' (or re-copy the kit) and re-run deploy.sh."
  fi

  mkdir -p "${BACKUP_DIR}" "${STAGING_DIR}"
  chmod 775 "${STAGING_DIR}"

  install -m 0755 "${backup_src}/backup.sh"       "${BACKUP_DIR}/"
  install -m 0755 "${backup_src}/restore.sh"      "${BACKUP_DIR}/"
  install -m 0755 "${backup_src}/restic-check.sh" "${BACKUP_DIR}/"

  # backup/mailcow-backup.env is the single source for the backup config
  # (credentials are part of the repo - keep the repository private).

  if [[ ! -f "${BACKUP_DIR}/mailcow-backup.env" ]]; then
    install -m 0600 "${src_env}" "${BACKUP_DIR}/mailcow-backup.env"
    ok "installed mailcow-backup.env (${BACKUP_DIR}/mailcow-backup.env)"
  elif grep -q "CHANGE_ME" "${BACKUP_DIR}/mailcow-backup.env" 2>/dev/null && \
       ! grep -q "CHANGE_ME" "${src_env}"; then
    # server copy still has placeholders, repo copy has real credentials -> upgrade
    install -m 0600 "${src_env}" "${BACKUP_DIR}/mailcow-backup.env"
    ok "upgraded the placeholder backup env with your real credentials"
  else
    info "mailcow-backup.env already exists - not overwriting your credentials"
  fi
  sed -i "s|^MAILCOW_INSTALL_DIR=.*|MAILCOW_INSTALL_DIR=\"${INSTALL_DIR}\"|" "${BACKUP_DIR}/mailcow-backup.env"
  sed -i "s|^BACKUP_STAGING_DIR=.*|BACKUP_STAGING_DIR=\"${STAGING_DIR}\"|" "${BACKUP_DIR}/mailcow-backup.env"
  chmod 600 "${BACKUP_DIR}/mailcow-backup.env"

  install -m 0644 "${backup_src}/mailcow-backup.service" /etc/systemd/system/mailcow-backup.service
  install -m 0644 "${backup_src}/mailcow-backup.timer"   /etc/systemd/system/mailcow-backup.timer
  systemctl daemon-reload
  systemctl enable mailcow-backup.timer >/dev/null 2>&1
  ok "Backup tooling installed in ${BACKUP_DIR} (timer enabled, daily 01:30)"
}

summary() {
  echo
  echo "======================================================================"
  echo " mailcow deployment finished"
  echo "======================================================================"
  echo
  echo "  UI:          https://${MAILCOW_HOSTNAME}"
  echo "  Login:       admin   (default password: moohoo - CHANGE IT NOW!)"
  echo "  Install dir: ${INSTALL_DIR}"
  echo
  echo " NEXT STEPS:"
  echo "  1. Log in to the UI, change the admin password, enable 2FA."
  echo "  2. Configuration -> Mail setup: add domain 'htasol.net'."
  echo "  3. Configuration -> ARC/DKIM keys: add key, publish the TXT record."
  echo "  4. Publish MX/SPF/DMARC/autodiscover records (see dns-records.md)."
  echo "  5. Set the PTR record for $(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo 'the VPS IP') to ${MAILCOW_HOSTNAME} at Contabo!"
  echo "  6. Configure backups: edit ${BACKUP_DIR}/mailcow-backup.env"
  echo "     with your IDrive e2 credentials, then run:"
  echo "         sudo ${BACKUP_DIR}/backup.sh"
  echo "  7. Run the verification suite:  sudo ${SCRIPT_DIR}/verify.sh"
  echo
  echo " Backup schedule: daily 01:30 via systemd timer (mailcow-backup.timer)."
  echo "======================================================================"
}

main() {
  require_root
  install_deps
  set_server_timezone
  install_docker
  apply_sysctl
  clone_mailcow
  generate_config
  setup_firewall
  start_stack
  install_backup_tooling
  summary
}

main "$@"
