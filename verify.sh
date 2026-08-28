#!/usr/bin/env bash
# =============================================================================
# Post-deployment verification for the htasol.net mailcow server
#
# Usage:   sudo ./verify.sh
# Checks:  DNS (A/AAAA/MX/SPF/DMARC/DKIM/PTR), open ports, SMTP banner,
#          TLS certificates, mailcow containers/watchdog, UI, restic repo
# =============================================================================
set -uo pipefail

# --- shared helpers & project config (mailcow.env) -------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}") && pwd")/lib.sh"
load_project_config

DOMAIN="${DOMAIN:-htasol.net}"
MAIL_HOST="${MAIL_HOST:-${MAILCOW_HOSTNAME:-mail.htasol.net}}"
IP="${IP:-169.58.248.84}"
IPV6="${IPV6:-2a02:c207:2353:8454::1}"
MAILCOW_DIR="${MAILCOW_DIR:-${INSTALL_DIR:-/opt/mailcow-dockerized}}"
BACKUP_DIR="${BACKUP_DIR:-/opt/mailcow-backup}"

PASS=0; FAIL=0; WARN=0

ok()   { PASS=$((PASS+1)); echo -e "\e[32m  [ OK ]\e[0m $*"; }
warn() { WARN=$((WARN+1)); echo -e "\e[33m  [WARN]\e[0m $*"; }
bad()  { FAIL=$((FAIL+1)); echo -e "\e[31m  [FAIL]\e[0m $*"; }
sec()  { echo; echo -e "\e[36m== $* ==\e[0m"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
sec "DNS"
a="$(dig +short A "${MAIL_HOST}" 2>/dev/null | tail -n1)"
if [[ "${a}" == "${IP}" ]]; then ok "A ${MAIL_HOST} -> ${a}"; else bad "A ${MAIL_HOST} -> '${a}' (expected ${IP})"; fi

if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  aaaa="$(dig +short AAAA "${MAIL_HOST}" 2>/dev/null | tail -n1)"
  if [[ -z "${aaaa}" ]]; then
    warn "VPS has IPv6 but no AAAA record for ${MAIL_HOST}"
  elif [[ -n "${IPV6}" && "${aaaa}" == "${IPV6}" ]]; then
    ok "AAAA ${MAIL_HOST} -> ${aaaa}"
  elif [[ -n "${IPV6}" ]]; then
    warn "AAAA ${MAIL_HOST} -> ${aaaa} (expected ${IPV6})"
  else
    ok "AAAA ${MAIL_HOST} -> ${aaaa}"
  fi
else
  aaaa="$(dig +short AAAA "${MAIL_HOST}" 2>/dev/null | tail -n1)"
  if [[ -n "${aaaa}" ]]; then warn "VPS has no global IPv6 but an AAAA record exists - remove it or enable IPv6"; else ok "No AAAA needed (no IPv6 on VPS)"; fi
fi

mx="$(dig +short MX "${DOMAIN}" 2>/dev/null | tr '\n' ' ')"
if echo "${mx}" | grep -q "${MAIL_HOST}"; then ok "MX ${DOMAIN} -> ${mx}"; else bad "MX ${DOMAIN} -> '${mx}' (expected mail.htasol.net)"; fi

spf="$(dig +short TXT "${DOMAIN}" 2>/dev/null | grep -i spf | tr '\n' ' ')"
if [[ -n "${spf}" ]]; then ok "SPF ${DOMAIN} -> ${spf}"; else bad "SPF record missing for ${DOMAIN}"; fi

dmarc="$(dig +short TXT "_dmarc.${DOMAIN}" 2>/dev/null | tr '\n' ' ')"
if [[ -n "${dmarc}" ]]; then ok "DMARC _dmarc.${DOMAIN} -> ${dmarc}"; else warn "DMARC record missing for ${DOMAIN}"; fi

dkim="$(dig +short TXT "dkim._domainkey.${DOMAIN}" 2>/dev/null | tr '\n' ' ')"
if [[ -n "${dkim}" ]]; then ok "DKIM dkim._domainkey.${DOMAIN} found"; else warn "DKIM TXT record not found (add it from mailcow UI -> ARC/DKIM keys)"; fi

ptr="$(dig +short -x "${IP}" 2>/dev/null | tail -n1 | sed 's/\.$//')"
if [[ "${ptr}" == "${MAIL_HOST}" ]]; then ok "PTR ${IP} -> ${ptr}"; else warn "PTR ${IP} -> '${ptr}' (expected ${MAIL_HOST}; set it at Contabo!)"; fi

# ----------------------------------------------------------------------------
sec "Listening ports (host)"
ports="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ':(25|80|110|143|443|465|587|993|995|4190)$' | sed 's/.*://' | sort -un | tr '\n' ' ')"
echo "  listening: ${ports}"
for p in 25 80 443 465 587 993; do
  echo "${ports}" | grep -qw "${p}" && ok "port ${p} listening" || bad "port ${p} NOT listening"
done

# ----------------------------------------------------------------------------
sec "External reachability (best-effort, from this server)"
for p in 25 80 443 465 587 993; do
  if timeout 6 bash -c "exec 3<>/dev/tcp/${IP}/${p}" 2>/dev/null; then
    ok "port ${p} reachable on ${IP}"
  else
    warn "port ${p} not reachable on ${IP} - check Contabo panel firewall / UFW"
  fi
done

# ----------------------------------------------------------------------------
sec "SMTP banner"
banner="$(IP="${IP}" timeout 8 bash -c 'exec 3<>/dev/tcp/${IP}/25; IFS= read -r -t 5 line <&3; printf "%s\n" "$line"' 2>/dev/null || true)"
if echo "${banner}" | grep -q "220"; then ok "SMTP banner: ${banner}"; else bad "no SMTP banner received: '${banner}'"; fi

# ----------------------------------------------------------------------------
sec "Outbound port 25 from this VPS (to Gmail)"
out25="$(timeout 8 bash -c 'exec 3<>/dev/tcp/smtp.gmail.com/25; IFS= read -r -t 5 line <&3; printf "%s\n" "$line"' 2>/dev/null || true)"
if echo "${out25}" | grep -q "220"; then ok "outbound 25 works: ${out25}"; else bad "outbound port 25 blocked/failed: '${out25}'"; fi

# ----------------------------------------------------------------------------
sec "TLS certificates (${MAIL_HOST})"
for p in 443 993 465 587; do
  out="$(echo | timeout 8 openssl s_client -connect "${IP}:${p}" -servername "${MAIL_HOST}" 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then ok "port ${p} certificate:"; echo "      $(echo "${out}" | tr '\n' ' ')"; else bad "no valid certificate on port ${p}"; fi
done

# ----------------------------------------------------------------------------
sec "mailcow stack"
if [[ -d "${MAILCOW_DIR}" ]]; then
  cd "${MAILCOW_DIR}"
  if have docker; then
    docker compose ps --format "table {{.Name}}\t{{.Status}}" | grep -E 'Up|NAME' | sed 's/^/  /' || true
    up_count="$(docker compose ps --format '{{.Status}}' 2>/dev/null | grep -c '^Up' || true)"
    total="$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l)"
    if [[ "${total}" -eq 0 ]]; then
      bad "no mailcow containers found - is the stack running? (cd ${MAILCOW_DIR} && docker compose up -d)"
    elif [[ "${up_count}" -ge "${total}" ]]; then ok "all ${total} containers are Up"; else bad "only ${up_count}/${total} containers are Up"; fi
    if docker ps --format '{{.Names}}' | grep -q watchdog-mailcow; then
      ok "watchdog-mailcow is running"
    else
      bad "watchdog-mailcow is not running"
    fi
  else
    warn "docker CLI not found"
  fi
else
  warn "${MAILCOW_DIR} not found - is mailcow installed?"
fi

# ----------------------------------------------------------------------------
sec "mailcow UI"
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://127.0.0.1/ 2>/dev/null || true)"
if [[ "${code}" == "200" || "${code}" == "301" || "${code}" == "302" ]]; then ok "UI responds on https://127.0.0.1/ (HTTP ${code})"; else bad "UI did not respond (HTTP '${code}')"; fi

# ----------------------------------------------------------------------------
sec "restic backup repository (IDrive e2)"
if [[ -f "${BACKUP_DIR}/mailcow-backup.env" ]]; then
  # shellcheck source=/dev/null
  source "${BACKUP_DIR}/mailcow-backup.env"
  if [[ "${RESTIC_PASSWORD:-}" == "CHANGE_ME"* ]]; then
    warn "backup credentials not configured yet - edit ${BACKUP_DIR}/mailcow-backup.env"
  else
    RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:latest}"
    if timeout 60 docker run --rm \
      -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}" \
      -e "RESTIC_PASSWORD=${RESTIC_PASSWORD}" \
      -e "AWS_ACCESS_KEY_ID=${E2_ACCESS_KEY}" \
      -e "AWS_SECRET_ACCESS_KEY=${E2_SECRET_KEY}" \
      ${AWS_DEFAULT_REGION:+-e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"} \
      "${RESTIC_IMAGE}" snapshots --latest --compact 2>/dev/null; then
      ok "restic repository reachable, latest snapshot listed above"
    else
      bad "restic repository not reachable / no snapshots yet - run: sudo ${BACKUP_DIR}/backup.sh"
    fi
  fi
else
  warn "no backup config at ${BACKUP_DIR}/mailcow-backup.env"
fi

# ----------------------------------------------------------------------------
echo
echo "==================== SUMMARY ===================="
echo -e "  \e[32mPass: ${PASS}\e[0m   \e[33mWarn: ${WARN}\e[0m   \e[31mFail: ${FAIL}\e[0m"
echo "================================================="
exit 0
