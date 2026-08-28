# Standard mailboxes & aliases (enterprise anti-phishing setup)

For the parent company (`htasol.net`) and every brand domain
(`htashop.com`, `htasync.com`, `dresslefy.com`, `htasolc.com`, `htasol.com`, …).

## Principle

- Create **very few real mailboxes** (human-monitored + send-only).
- Everything else is an **alias** pointing at one of those mailboxes.
- **Never enable catch-all** — every guessed address must bounce, not deliver.
- Send-only mailboxes have **IMAP/POP3 disabled** and platform-only credentials.

---

## Step 1 — Real mailboxes to create (3 per brand + 2 central on parent)

### Central mailboxes (on `htasol.net` only)

| Mailbox | Monitored by | Purpose |
|---|---|---|
| `team@htasol.net` | Office staff | Central inbox - all business aliases land here |
| `security@htasol.net` | IT / security | Abuse, security, DMARC & TLS reports (keep separate from business mail) |

### Send-only mailbox (one per domain, including the parent)

| Mailbox | Credentials | Protocols | Purpose |
|---|---|---|---|
| `noreply@htasol.net` | platform-only, strong password | **IMAP/POP3 disabled** | Sender for automated mail |
| `noreply@htashop.com` | platform-only, strong password | IMAP/POP3 disabled | Sender for automated mail |
| `noreply@htasync.com` | platform-only, strong password | IMAP/POP3 disabled | Sender for automated mail |
| `noreply@dresslefy.com` | platform-only, strong password | IMAP/POP3 disabled | Sender for automated mail |
| `noreply@htasolc.com` | platform-only, strong password | IMAP/POP3 disabled | Sender for automated mail |

> The e-commerce platforms authenticate on SMTP submission (port 587) as
> `noreply@<domain>` and send as any of its aliases (`orders@`, `shipping@`, …).

---

## Step 2 — Aliases to create (repeat for EVERY domain D)

### A. RFC / technical aliases (required on every domain)

| Alias | Target mailbox | Why |
|---|---|---|
| `postmaster@D` | auto-created by mailcow ✅ | RFC 5321 mandate |
| `abuse@D` | `security@htasol.net` | RFC 2142 - spam/phishing/abuse reports |
| `security@D` | `security@htasol.net` | security reports |
| `webmaster@D` | `team@htasol.net` | RFC 2142 - website issues |
| `dmarc@htasol.net` (parent only) | `security@htasol.net` | DMARC rua/ruf reports (see Step 3) |
| `tls-report@htasol.net` (parent only) | `security@htasol.net` | MTA-STS TLS-RPT reports (optional) |

### B. Business aliases (every domain D)

| Alias | Target mailbox | Purpose |
|---|---|---|
| `info@D` | `team@htasol.net` | general inquiries |
| `contact@D` | `team@htasol.net` | contact page form |
| `support@D` | `team@htasol.net` | customer support |
| `sales@D` | `team@htasol.net` | sales inquiries |
| `billing@D` | `team@htasol.net` | payments / invoices / refunds |
| `admin@D` | `team@htasol.net` | administrative contact |

### C. Sender aliases (every domain D — all target the local `noreply@D`)

| Alias | Target mailbox | Purpose |
|---|---|---|
| `noreply@D` | real mailbox `noreply@D` | transactional sender (auto-created in Step 1) |
| `orders@D` | `noreply@D` | order confirmations (platform sends from this) |
| `shipping@D` | `noreply@D` | shipping / tracking notifications |
| `marketing@D` | `noreply@D` | newsletters - **must** include `List-Unsubscribe` + double opt-in |

> mailcow: an authenticated user can send from their aliases, so the platform
> logs in as `noreply@D` and can use `orders@D`, `shipping@D`, `marketing@D`
> as `From:` addresses. Receiving aliases (A/B) stay receive-only by default.

---

## Step 3 — DMARC report address (optional but recommended)

Current DMARC records use `rua=mailto:postmaster@htasol.net` (valid - postmaster
exists). For cleaner report handling, create `dmarc@htasol.net` (alias ->
`security@htasol.net`) and update each domain's `_dmarc` TXT:

```
v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:dmarc@htasol.net; ruf=mailto:dmarc@htasol.net; fo=1; pct=100
```

Feed `rua` reports into a parser (e.g. open-source `parsedmarc`, or dmarcian)
and review **weekly**. After 2-4 weeks of clean reports, move `p=quarantine`
to `p=reject` - this is the control that actually stops spoofing of your
domains. Also tighten SPF `~all` -> `-all` once confident.

---

## Step 4 — mailcow steps (per domain)

1. **Mailboxes**: *Configuration → Mail setup* → edit domain → *Add mailbox*
   - create `noreply@D` (strong random password, store in password manager)
   - edit it → uncheck **IMAP / POP3** (send-only) → save
2. **Aliases**: *Configuration → Aliases → Add alias*
   - one per row from tables A/B/C (`Address` = alias, `Goto` = target mailbox)
   - multiple targets allowed, comma-separated
3. Verify: send a test mail to `info@D`, `abuse@D`, `orders@D` → confirm they
   land in the right mailbox / bounce correctly.

---

## Anti-phishing checklist (everything that actually matters)

- [ ] DMARC `p=reject` on all domains (after report review) - **the** control
- [ ] SPF `-all` on all domains
- [ ] DKIM per domain ✅ (done)
- [ ] DMARC reports monitored weekly (parsedmarc/dmarcian)
- [ ] No catch-all aliases
- [ ] No human mailbox with a weak/default password; 2FA on mailcow admins
- [ ] Send-only mailboxes: IMAP/POP3 disabled, credentials only in the platform
- [ ] `abuse@`, `security@` actually monitored
- [ ] MTA-STS + TLS-RPT deployed (records in dns-records.md §4)
- [ ] Typosquat domains registered or monitored (e.g. `htasol-shop.com`)
- [ ] Marketing mail always carries `List-Unsubscribe`
