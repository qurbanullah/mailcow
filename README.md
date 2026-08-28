# mailcow deployment — `htasol.net` on Contabo VPS

Fully automated, enterprise-grade mailcow mail server on
**`mail.htasol.net`** (`169.58.248.84`), with nightly encrypted backups to
**IDrive e2** object storage via **restic**.

```
mailcow/
├── README.md                    <- this runbook (start here)
├── .gitignore                   <- keeps real config/credentials out of git
├── mailcow.env.example          <- project config template (copy to mailcow.env)
├── lib.sh                       <- shared helpers + mailcow.env loader
├── server-prep.sh               <- create sudo user, change SSH port, disable root SSH
├── deploy.sh                    <- one-shot installer (run on the VPS)
├── firewall.sh                  <- UFW rules for mail + web ports
├── verify.sh                    <- post-deploy verification suite
├── sysctl-mailcow.conf          <- kernel tuning for mail load
├── dns-records.md               <- every DNS record you must create
└── backup/
    ├── backup.sh                <- mailcow backup -> restic -> IDrive e2
    ├── restore.sh               <- restic -> local -> official restore tool
    ├── restic-check.sh          <- monthly repo health check
    ├── mailcow-backup.env.example <- credentials/tuning (CHANGE_ME!)
    ├── mailcow-backup.service   <- systemd unit (oneshot)
    └── mailcow-backup.timer     <- daily 01:30 schedule
```

**Configuration:** all project values (hostname, domain, IPs, VPS user, SSH
port, timezone, install paths, firewall) live in one file - **`mailcow.env`**
(copy of `mailcow.env.example`). Every script reads it; per-run environment
variables and command-line flags take precedence. There is nothing to edit
inside the scripts themselves.

**Git / security:** this repository is safe to push to GitHub - it contains
only `.example` templates with placeholder values (`CHANGE_ME_...`). The
`.gitignore` blocks the real files (`mailcow.env`, `backup/mailcow-backup.env`,
`mailcow.conf`, keys/certs, backups), so never `git add -f` those. The
mailcow default admin password `moohoo` shown in the README is upstream's
public default - change it immediately after first login.

---

## 0. Review of your pre-flight tests

| Check | Result | Meaning / action |
|---|---|---|
| `ping mail.htasol.net` → `169.58.248.84` | ✅ | A record works; hostname resolves to your Contabo VPS. Good to go. |
| AAAA record | ⚠️ publish | VPS has a global IPv6: `2a02:c207:2353:8454::1` (verified). Add `AAAA mail → 2a02:c207:2353:8454::1`. deploy.sh keeps `ENABLE_IPV6=true` automatically. |
| `telnet smtp.gmail.com 25` (your PC) | ✅ | Your local network allows outbound port 25. |
| Outbound 25 from the VPS | ✅ | `telnet smtp.gmail.com 25` from the VPS connects and returns the `220` banner (it even went over IPv6 — dual-stack delivery works). |
| Inbound 25 to the VPS | ❓ test it | From outside: `nc -vz 169.58.248.84 25`. Also check the **Contabo panel firewall** isn't blocking. |
| MX / SPF / DMARC records | ✅ done | `MX htasol.net → mail.htasol.net.`, SPF `~all`, DMARC `p=quarantine` — all published and verified. |
| PTR / reverse DNS ("DNS pointer") | ✅ done | `ping` now answers from `mail.htasol.net` — reverse DNS resolves correctly. Optional: also set IPv6 rDNS for `2a02:c207:2353:8454::1`. |
| DKIM | ⏳ pending | Generated in the mailcow UI after first login; publish the TXT record. |
| IP reputation | ❓ check | Test `169.58.248.84` on mxtoolbox.com (blacklist check) — Contabo ranges are sometimes listed; SPF/DKIM/DMARC + PTR fix most of it. |

**Verdict: A, AAAA, MX, SPF, DMARC, PTR and outbound port 25 are all
confirmed. The only DNS item left is DKIM, which is generated in the mailcow
UI after first login — all covered in `dns-records.md`.**

---

## 1. Server requirements

- **OS:** Debian 12 (recommended) or Ubuntu LTS 22.04/24.04/26.04
- **RAM:** ≥ 4 GB (with 2.5 GB, deploy.sh automatically disables ClamAV to avoid OOM)
- **Disk:** mailbox size × 2 for the backup staging area + Docker images
  (start with ≥ 50 GB; grow with the mailboxes)
- **Timezone:** deploy.sh sets the server to **UTC** (`SERVER_TZ` in
  `mailcow.env`) — the industry standard: DST-free logs, timers and backup
  runs. Users see their own local time in SOGo and mail clients regardless;
  no per-user change is needed.
- SSH access (root or a sudo user such as `htasolnet`)

## 2. DNS — do this first

Follow `dns-records.md`. Minimum set before install:

- `A mail.htasol.net` → `169.58.248.84` ✅ (already done)
- `AAAA mail.htasol.net` → `2a02:c207:2353:8454::1` (VPS IPv6, verified)
- `MX htasol.net` → `mail.htasol.net.` (prio 10)
- `TXT htasol.net` (SPF) → `v=spf1 mx a ip4:169.58.248.84 ~all`
- **PTR for `169.58.248.84` → `mail.htasol.net`** ✅ (already done at Contabo)

## 3. Install

### 3a. Configure the project (once, on your workstation)

```bash
cp mailcow.env.example mailcow.env
nano mailcow.env      # hostname, domain, IPs, VPS_USER, SSH_PORT, TZ, paths
```

All values the scripts need live here - no hardcoded values inside the
scripts. `SSH_PORT` also switches sshd in step 3c.

### 3b. Upload as root, create the sudo user & switch SSH to a secure port

```bash
# workstation - initial upload (root still has access)
scp -r mailcow root@169.58.248.84:/root/

# VPS (as root): create htasolnet, move sshd to the port from mailcow.env
cd /root/mailcow
sudo ./server-prep.sh
```

This creates `htasolnet`, adds it to the `sudo` group, copies root's SSH
public key(s) so key login works, asks you to set its password (needed for
`sudo`), and moves sshd to the configured port - updating both `sshd_config`
and (on Ubuntu's socket-activated ssh) the `ssh.socket` listener, and
opening the port in UFW if it's already active.

**Stop here and test in a second terminal** before anything else:

```bash
ssh -p 63521 htasolnet@169.58.248.84
```

Then hand the folder over to the new user:

```bash
cp -r /root/mailcow /home/htasolnet/
chown -R htasolnet:htasolnet /home/htasolnet/mailcow
```

### 3c. Deploy as the new user

```bash
ssh -p 63521 htasolnet@169.58.248.84
cd ~/mailcow
sudo ./deploy.sh
```

`deploy.sh` detects the effective sshd port automatically (via `sshd -T`)
and opens it in the firewall - nothing to configure for the port change.
You can override any value per-run, e.g. `sudo MAILCOW_TZ=Asia/Karachi ./deploy.sh`.

### 3d. Disable root SSH login (after you verified the new login!)

Open a **second terminal** and confirm you can log in as `htasolnet`
(`ssh -p 63521 htasolnet@169.58.248.84`). Only then:

```bash
cd ~/mailcow
sudo ./server-prep.sh --disable-root-ssh
```

This sets `PermitRootLogin no` via `/etc/ssh/sshd_config.d/99-disable-root.conf`,
validates the config with `sshd -t`, and applies it with a HUP **reload**
(never a socket restart) - so it works with Ubuntu's socket-activated
`ssh.socket` just as well as with the classic `sshd` service. Keep your
current session open until you are sure the new login works.

`deploy.sh` (idempotent — safe to re-run) will:

1. install Docker ≥ 24 + compose plugin (Debian/Ubuntu via get.docker.com)
2. apply `sysctl-mailcow.conf` tuning
3. clone mailcow to `/opt/mailcow-dockerized`
4. generate `mailcow.conf` **non-interactively** via the official
   `generate_config.sh` (env-var driven: hostname, timezone, branch, DB
   passwords, `DOCKER_COMPOSE_VERSION=native`)
5. configure UFW (SSH + 25, 80, 443, 465, 587, 143, 993, 110, 995, 4190)
6. `docker compose pull && docker compose up -d`
7. install backup tooling to `/opt/mailcow-backup` + enable the daily timer

> Container-published ports (25, 80, 443, …) bypass UFW through Docker's own
> iptables chains — that is expected and correct. UFW protects the host
> services; the exposed set equals the mail/web ports above.

## 4. First login & hardening

1. Open `https://mail.htasol.net`
   (you will get a certificate warning until Let's Encrypt issues the cert —
   it retries automatically; make sure 80/443 are reachable).
2. Login: user **`admin`** / password **`moohoo`** → **change it immediately**,
   enable 2FA (TOTP or WebAuthn).
3. *Configuration → Mail setup:* add domain `htasol.net`.
4. *Configuration → ARC/DKIM keys:* **add key** for `htasol.net`, publish the
   `dkim._domainkey` TXT record.
5. Tighten SPF from `~all` to `-all` once test mail passes.
6. Recommended: set `WATCHDOG_NOTIFY_EMAIL` in
   `/opt/mailcow-dockerized/mailcow.conf` to an external mailbox so the
   watchdog can alert you (`docker compose restart` isn't needed for that
   variable change after `docker compose up -d` re-reads it — see mailcow docs).
7. Deliverability: run `verify.sh`, then send test mails to
   mail-tester.com and check the blacklist status of the IP on mxtoolbox.com.

## 5. Backups to IDrive e2 (restic)

Everything is pre-installed; you only supply credentials.

1. Create an **IDrive e2** bucket (e.g. `mailcow-htasol`) and an E2
   **Access Key** in the IDrive e2 console.
2. Provide the credentials. Either prepare them **before deploy** by editing
   `backup/mailcow-backup.env` in this folder (deploy.sh installs it
automatically; the file is gitignored) — or set them **after deploy**:

   ```bash
   sudo nano /opt/mailcow-backup/mailcow-backup.env
   ```

   Set `E2_ACCESS_KEY`, `E2_SECRET_KEY`, `RESTIC_PASSWORD` (and the bucket
   name / region if you deviated from the defaults).
3. Test once manually:

   ```bash
   sudo /opt/mailcow-backup/backup.sh
   ```

4. Confirm the snapshot landed:

   ```bash
   sudo /opt/mailcow-backup/restic-check.sh
   ```

The systemd timer already runs the backup **daily at 01:30**; verify with
`systemctl list-timers mailcow-backup.timer` and check past runs with
`journalctl -u mailcow-backup.service -e`.

**What gets backed up** (each run):
- full mail data (`vmail`), crypt, Redis, rspamd, postfix data,
  MySQL/MariaDB (consistent `mariabackup`), plus `mailcow.conf`
- mailcow configuration (custom rspamd/dovecot configs, TLS certs, hooks)
  under the `mailcow-config` tag
- retention: 7 daily + 4 weekly + 12 monthly + 2 yearly snapshots, pruned
  automatically; local staging cleaned after 3 days

**Restore procedure** (disaster recovery):

```bash
sudo /opt/mailcow-backup/restore.sh                # list snapshots
sudo /opt/mailcow-backup/restore.sh <snapshot-id>  # download + start restore tool
```

The official interactive restore tool then lets you pick datasets (maildir,
redis, rspamd, postfix, SQL, …). **Restoring SQL/maildir overwrites live
data.** Monthly DR drill: run `restic-check.sh --data` and a test restore.

## 6. Verification

```bash
cd ~/mailcow && sudo ./verify.sh
```

Checks DNS (A/AAAA/MX/SPF/DMARC/DKIM/PTR), listening + reachable ports, SMTP
banner, TLS certs, container health, watchdog, UI and the restic repository.

## 7. Day-to-day operations

| Task | Command |
|---|---|
| Status | `docker compose -f /opt/mailcow-dockerized/docker-compose.yml ps` |
| Update mailcow | `cd /opt/mailcow-dockerized && sudo ./update.sh` |
| Logs | `docker compose logs -f --tail=200` (or per container) |
| Watchdog alerts | via `WATCHDOG_NOTIFY_EMAIL` (set it!) |
| Manual backup | `sudo /opt/mailcow-backup/backup.sh` |
| Backup status | `systemctl list-timers mailcow-backup.timer` ; `journalctl -u mailcow-backup.service -e` |
| Repo health | `sudo /opt/mailcow-backup/restic-check.sh --data` |

## 8. Troubleshooting quick hits

- **Gmail rejects/defers mail** → PTR set? SPF/DKIM/DMARC published? IP
  blacklisted (mxtoolbox)? Outbound 25 open from the VPS?
- **Certificate not issuing** → port 80/443 reachable from outside; A record
  matches; check `docker compose logs acme-mailcow`.
- **No inbound mail** → MX published? port 25 reachable from outside?
  Contabo panel firewall?
- **Backup fails** → `journalctl -u mailcow-backup.service -e`; bucket
  exists? credentials correct? If "bucket not found" errors appear, uncomment
  `RESTIC_EXTRA_OPTS="-o s3.bucket-lookup=path"` in `mailcow-backup.env`.

## 9. Reference

- mailcow install docs: https://docs.mailcow.email/getstarted/install/
- mailcow backup docs: https://docs.mailcow.email/backup_restore/b_n_r-backup/
- restic S3 backend: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#amazon-s3
- IDrive e2: https://www.idrive.com/e2/
