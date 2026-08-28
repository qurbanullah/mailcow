#!/usr/bin/env bash
# =============================================================================
# UFW firewall rules for a mailcow email server
#
# Usage:  sudo ./firewall.sh [ssh-port]      (default ssh-port: 22)
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}") && pwd")/lib.sh"
load_project_config

# SSH port: command-line argument > mailcow.env / env > 22
SSH_PORT="${1:-${SSH_PORT:-22}}"
[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "SSH port must be a number (got: ${SSH_PORT})"

command -v ufw >/dev/null 2>&1 || { echo "ufw is not installed" >&2; exit 1; }

echo "Configuring UFW for mailcow (SSH port: ${SSH_PORT})..."

ufw --force reset >/dev/null 2>&1 || true

ufw default deny incoming
ufw default allow outgoing

# SSH - keep your remote access!
ufw allow "${SSH_PORT}"/tcp comment 'SSH'

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
