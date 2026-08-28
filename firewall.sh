#!/usr/bin/env bash
# =============================================================================
# UFW firewall rules for a mailcow email server
#
# Usage:  sudo ./firewall.sh [ssh-port ...]   (default: 22; multiple ports allowed)
#
# Passing more than one SSH port is useful during migration (e.g. keep 22
# open while moving sshd to 63521).
#
# NOTE about Docker: containers publish their ports through Docker's own
# iptables chains, which UFW does not manage. mailcow only publishes the mail
# and web ports listed below, so this is expected - UFW protects the host
# itself and makes the allowed set explicit. For extra protection (e.g. the
# web UI only from certain IPs) use the Contabo panel firewall or a
# reverse proxy / fail2ban.
# =============================================================================
set -euo pipefail

# --- shared helpers & project config (mailcow.env) -------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_project_config

# SSH port(s): command-line arguments (can be more than one) > mailcow.env > 22
if (( $# >= 1 )); then
  SSH_PORTS=("$@")
else
  SSH_PORTS=("${SSH_PORT:-22}")
fi
for p in "${SSH_PORTS[@]}"; do
  [[ "${p}" =~ ^[0-9]+$ ]] || die "SSH port must be a number (got: ${p})"
done

command -v ufw >/dev/null 2>&1 || { echo "ufw is not installed" >&2; exit 1; }

echo "Configuring UFW for mailcow (SSH port(s): ${SSH_PORTS[*]})..."

ufw --force reset >/dev/null 2>&1 || true

ufw default deny incoming
ufw default allow outgoing

# SSH - keep your remote access!
for p in "${SSH_PORTS[@]}"; do
  ufw allow "${p}"/tcp comment 'SSH'
done

# Web (mailcow UI, SOGo webmail/DAV, Let's Encrypt ACME)
ufw allow 80/tcp  comment 'HTTP (Let''s Encrypt / UI redirect)'
ufw allow 443/tcp comment 'HTTPS (mailcow UI / SOGo / autodiscover)'

# SMTP
ufw allow 25/tcp  comment 'SMTP (MX inbound + outbound delivery)'
ufw allow 465/tcp comment 'SMTPS (implicit-TLS submission)'
ufw allow 587/tcp comment 'SMTP submission (STARTTLS)'

# IMAP / POP3
ufw allow 143/tcp comment 'IMAP (STARTTLS)'
ufw allow 993/tcp comment 'IMAPS'
ufw allow 110/tcp comment 'POP3 (STARTTLS)'
ufw allow 995/tcp comment 'POP3S'

# ManageSieve (SOGo mail filters) - restrict to your office/client IPs if you can
ufw allow 4190/tcp comment 'ManageSieve (optional)'

ufw --force enable
ufw status verbose
