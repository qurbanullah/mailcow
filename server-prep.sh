#!/usr/bin/env bash
# =============================================================================
# Prepare the VPS for mailcow: create a sudo user, copy SSH keys, change the
# SSH port, and optionally disable root SSH login.
#
# Values (user, SSH port, IP) come from mailcow.env.
# Command-line flags below override the config file.
#
# Usage (run ON the VPS, as root):
#   sudo ./server-prep.sh                     # uses mailcow.env
#   sudo ./server-prep.sh htasolnet           # explicit username
#   sudo ./server-prep.sh --ssh-port 63521    # explicit port
#   sudo ./server-prep.sh --disable-root-ssh
#
# WARNING about --ssh-port / --disable-root-ssh:
#   Only switch ports / disable root AFTER you verified in a SECOND terminal
#   that you can log in as the new user (ssh -p <port> <user>@<ip>). If you
#   lock yourself out, use the Contabo VNC/console to recover.
#
# NOTE on Ubuntu 22.04+ / Debian 12+:
#   sshd is usually socket-activated (ssh.socket starts ssh.service on demand)
#   instead of a long-lived sshd.service. This script handles BOTH models:
#   when ssh.socket is enabled it updates the socket listener as well as
#   sshd_config, and config changes are applied via HUP reloads, never blind
#   restarts of the socket.
# =============================================================================
set -euo pipefail

# --- shared helpers & project config (mailcow.env) ----------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

USERNAME=""
DISABLE_ROOT_SSH="n"
SSH_PORT_ARG=""

usage() {
  echo "Usage: sudo $0 [username] [--ssh-port <port>] [--disable-root-ssh]"
  echo
  echo "Values are read from mailcow.env; flags take precedence."
}

while (( $# > 0 )); do
  case "$1" in
    --disable-root-ssh) DISABLE_ROOT_SSH="y"; shift ;;
    --ssh-port)         SSH_PORT_ARG="${2:-}"; shift 2 || shift ;;
    -h|--help)          usage; exit 0 ;;
    --*)                echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                  USERNAME="$1"; shift ;;
  esac
done

load_project_config

# --- resolve final values: flag > env > mailcow.env > default ------------------
USERNAME="${USERNAME:-${VPS_USER:-htasolnet}}"
IP="${IP:-169.58.248.84}"
SSH_PORT="${SSH_PORT_ARG:-${SSH_PORT:-}}"

[[ ${EUID} -eq 0 ]] || die "Run as root:  sudo $0"
[[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username: ${USERNAME}"
if [[ -n "${SSH_PORT}" ]]; then
  if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    die "Invalid SSH port: ${SSH_PORT} (must be 1-65535)"
  fi
fi

# --- 1. create the user ----------------------------------------------------------
if id "${USERNAME}" >/dev/null 2>&1; then
  ok "user ${USERNAME} already exists"
else
  info "creating user ${USERNAME}..."
  useradd --create-home --shell /bin/bash "${USERNAME}"
  ok "user ${USERNAME} created"
fi

# --- 2. sudo ----------------------------------------------------------------------
usermod -aG sudo "${USERNAME}"
ok "${USERNAME} added to the sudo group"

# --- 3. set a password (needed for sudo) -------------------------------------------
if [[ "$(passwd --status "${USERNAME}" 2>/dev/null | awk '{print $2}')" != "P" ]]; then
  info "set a password for ${USERNAME} (needed for sudo):"
  passwd "${USERNAME}"
else
  ok "password already set for ${USERNAME}"
fi

# --- 4. copy root's SSH public keys (so key login works right away) ----------------
if [[ -f /root/.ssh/authorized_keys ]]; then
  install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/.ssh"
  install -m 600 -o "${USERNAME}" -g "${USERNAME}" \
    /root/.ssh/authorized_keys "/home/${USERNAME}/.ssh/authorized_keys"
  ok "copied root's SSH public key(s) to ${USERNAME} -> key login will work"
else
  warn "no /root/.ssh/authorized_keys found - add a key manually or use the password"
fi

# --- 5. (optional) change the SSH port ----------------------------------------------
change_ssh_port() {
  local port="$1"

  info "changing SSH port to ${port}..."
  install -d -m 755 /etc/ssh/sshd_config.d
  printf 'Port %s\n' "${port}" > /etc/ssh/sshd_config.d/99-ssh-port.conf
  chmod 600 /etc/ssh/sshd_config.d/99-ssh-port.conf

  sshd -t || die "sshd config check failed - NOT applied. Revert /etc/ssh/sshd_config.d/99-ssh-port.conf."

  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    # Ubuntu 22.04+ socket activation: the LISTENER is owned by ssh.socket;
    # sshd is started on demand and does not bind Port itself.
    info "ssh.socket is enabled - updating its listener..."
    install -d -m 755 /etc/systemd/system/ssh.socket.d
    # Bind BOTH stacks explicitly: a bare ListenStream=port can come up
    # IPv6-only (net.ipv6.bindv6only / systemd defaults), which silently
    # refuses IPv4 clients -> "Connection refused".
    cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
    # Re-arm a running sshd onto the new socket fd. Existing sessions survive
    # (Ubuntu's unit uses KillMode=process).
    if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null; then
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi
    ok "ssh.socket now listens on ${port}"
  else
    # classic long-lived service: a SIGHUP reload is enough
    if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || { systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true; }
    fi
    ok "ssh service now listens on ${port}"
  fi

  # verify the listener is really bound to the new port
  sleep 1
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"; then
    ok "confirmed: ssh is listening on port ${port}"
  else
    die "ssh is NOT listening on port ${port} - recover via Contabo VNC (journalctl -u ssh)"
  fi

  # firewall: open the new port (and drop the old 22 rule) when UFW is active
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp" comment 'SSH' >/dev/null
    ok "UFW: allowed ${port}/tcp for SSH"
    if [[ "${port}" != "22" ]]; then
      ufw delete allow 22/tcp >/dev/null 2>&1 && ok "UFW: removed the old 22/tcp rule" \
        || warn "UFW: no plain 22/tcp rule to remove (fine)"
    fi
  fi

  warn "from now on connect with:  ssh -p ${port} ${USERNAME}@${IP}"
}

if [[ -n "${SSH_PORT}" ]]; then
  change_ssh_port "${SSH_PORT}"
fi

# --- 6. (optional) disable root SSH login --------------------------------------------
if [[ "${DISABLE_ROOT_SSH}" == "y" ]]; then
  info "disabling root SSH login (PermitRootLogin no)..."
  install -d /etc/ssh/sshd_config.d
  printf 'PermitRootLogin no\n' > /etc/ssh/sshd_config.d/99-disable-root.conf
  chmod 600 /etc/ssh/sshd_config.d/99-disable-root.conf

  sshd -t || die "sshd config check failed - NOT touching ssh. Revert /etc/ssh/sshd_config.d/99-disable-root.conf."

  # Apply the change without breaking the listener (works for both the classic
  # service and the socket-activated model). Never restart the socket here.
  if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null; then
    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
      ok "sshd config reloaded (SIGHUP - new config active)"
    else
      warn "reload not supported - restarting the ssh service instead"
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null \
        || warn "could not restart ssh - config applies on next connection/reboot"
    fi
  else
    # socket-activated and currently idle: no daemon running, nothing to reload;
    # the next connection starts sshd with the already-validated config
    ok "ssh is socket-activated and idle - new config applies on next connection"
  fi
  ok "root SSH login disabled (PermitRootLogin no)"
fi

# --- 7. next steps ----------------------------------------------------------------------
CONNECT_PORT="${SSH_PORT:-22}"
echo
echo "======================================================================"
echo " VPS user setup finished"
echo "======================================================================"
echo
echo " Connect / copy files from your WORKSTATION:"
echo "   ssh  -p ${CONNECT_PORT} ${USERNAME}@${IP}"
echo "   scp  -P ${CONNECT_PORT} -r mailcow ${USERNAME}@${IP}:~/"
echo
echo " Then on the VPS:"
echo "   cd ~/mailcow && sudo ./deploy.sh"
echo
echo " After deploy: configure /opt/mailcow-backup/mailcow-backup.env"
echo " (IDrive e2 credentials) and run:  sudo /opt/mailcow-backup/backup.sh"
echo "======================================================================"
