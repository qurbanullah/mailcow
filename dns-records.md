# DNS records for mailcow on `htasol.net`

Server: Contabo VPS `169.58.248.84` (`vmi3538454.contaboserver.net`)
Mail hostname (FQDN): **`mail.htasol.net`**

Two different places own DNS settings here:

1. **Your DNS hosting provider** (where `htasol.net` zone is managed) — A/AAAA,
   MX, TXT, CNAME records.
2. **Contabo** (they own the IP) — the **PTR / reverse DNS "pointer"**. You
   cannot set this at your DNS provider; it must be changed in the Contabo
   Cloud Panel (or via a support ticket). See [PTR record](#ptr-record-reverse-dns--the-dns-pointer).

---

## 1. Required records (create all of these)

| Type | Name (host) | Value | Purpose |
|---|---|---|---|
| A | `mail` | `169.58.248.84` | mailcow hostname — **done, verified by ping** ✅ |
| AAAA | `mail` | `2a02:c207:2353:8454::1` | VPS has a global IPv6 (verified: `ip -6 addr show scope global`) — publish this address so mailcow can use IPv6 for delivery (deploy.sh keeps `ENABLE_IPV6=true` automatically) |
| MX | `@` (`htasol.net`) | `mail.htasol.net.` priority `10` | routes inbound mail to mailcow |
| TXT | `@` (`htasol.net`) | `v=spf1 mx a ip4:169.58.248.84 ~all` | SPF — allows mail from this server. Move to `-all` after DKIM works and you're confident. |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@htasol.net; ruf=mailto:postmaster@htasol.net; fo=1; pct=100` | DMARC policy |
| TXT | `dkim._domainkey` | *(generated in mailcow UI, see below)* | DKIM signing key |
| A | `autodiscover` | `169.58.248.84` | Outlook/Apple automatic account setup |
| A | `autoconfig` | `169.58.248.84` | Thunderbird automatic account setup |
| A | `webmail` *(optional)* | `169.58.248.84` | nicer URL for the webmail/UI (`https://webmail.htasol.net`) |

> If the domain already has TXT/SPF records (e.g. from an old provider),
> merge them instead of replacing (`include:` statements), and only change the
> MX record when you are ready to cut over incoming mail — changing MX moves
> all inbound mail to mailcow immediately.

## 2. DKIM (after first login)

1. Log in to the mailcow UI: `https://mail.htasol.net` (user `admin`).
2. *Configuration → ARC/DKIM keys →* **add key** for domain `htasol.net`.
3. Copy the generated TXT record (`dkim._domainkey`) into your DNS provider.

mailcow signs every outgoing message once this is published.

## 3. PTR record (reverse DNS) — "the DNS pointer"

The reverse DNS for `169.58.248.84` currently resolves correctly — **status: ✅ done**.
`ping mail.htasol.net` now answers from `mail.htasol.net` itself:

```
64 bytes from mail.htasol.net (169.58.248.84)
```

For reference, this is how it was changed (Contabo Cloud Panel → VPS →
*Network / IPs* → edit the reverse DNS of `169.58.248.84`):

```
mail.htasol.net
```

If the panel does not allow self-service, open a Contabo ticket:
> "Please set the PTR record for 169.58.248.84 to `mail.htasol.net`."

Contabo requires the PTR hostname to have a matching A record — already in
place. Propagation of PTR can take 24–72 h.

**Optional:** also set the IPv6 rDNS (PTR in `ip6.arpa`) for
`2a02:c207:2353:8454::1` → `mail.htasol.net` in the same place. IPv4 PTR is
what matters most for deliverability, but setting both is the clean,
enterprise-grade choice.

## 4. Optional enterprise hardening records

| Type | Name | Value | Purpose |
|---|---|---|---|
| TXT | `_mta-sts` | `v=STSv1; id=20260828` | MTA-STS policy discovery |
| A | `mta-sts` | `169.58.248.84` | MTA-STS policy host (served by mailcow) |
| TXT | `_smtp._tls` | `v=TLSRPTv1; rua=mailto:postmaster@htasol.net` | TLS-RPT failure reports |
| TXT | `_adsp` | `dkim=all` *(optional)* | legacy ADSP |

## 5. Verification

After publishing, verify from any machine:

```bash
dig +short A mail.htasol.net
dig +short AAAA mail.htasol.net
dig +short MX htasol.net
dig +short TXT htasol.net | grep spf
dig +short TXT _dmarc.htasol.net
dig +short TXT dkim._domainkey.htasol.net
dig +short -x 169.58.248.84        # PTR -> mail.htasol.net
```

Or run the included `./verify.sh` on the server, which checks all of the above
automatically.

---

## 6. Adding more mail domains (htashop.com, htasync.com, dresslefy.com, htasol.com, ...)

Every additional domain hosted on this mail server needs the same set of
records. For each domain (example uses `htashop.com`):

| Type | Name | Value |
|---|---|---|
| MX | `@` | `mail.htasol.net.` priority `10` |
| TXT | `@` | `v=spf1 mx a ip4:169.58.248.84 ~all` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@htasol.net; ruf=mailto:postmaster@htasol.net; fo=1; pct=100` |
| TXT | `dkim._domainkey` | per-domain key from mailcow UI -> ARC/DKIM keys |
| A | `autodiscover` | `169.58.248.84` (optional - Outlook auto-setup) |
| A | `autoconfig` | `169.58.248.84` (optional - Thunderbird auto-setup) |

> **Copy-paste warning:** copy ONLY the value - never the whole table row.
> The `_dmarc` value must start exactly with `v=DMARC1` - pasting the row
> syntax (`| | TXT | ...`) makes the record unparsable by strict DMARC
> checkers. Clean values to paste:

```
MX        @          ->  mail.htasol.net.  (prio 10)
TXT       @          ->  v=spf1 mx a ip4:169.58.248.84 ~all
TXT       _dmarc     ->  v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@htasol.net; ruf=mailto:postmaster@htasol.net; fo=1; pct=100
```

**Before cutover check:**

- Does the domain already have MX records (Google Workspace, Microsoft, old
  host)? Changing MX moves ALL inbound mail to mailcow immediately - plan it.
- Does it already have an SPF record (other senders)? Merge, do not overwrite
  (keep existing `include:` / `ip4:` mechanisms).
- Only ONE `v=spf1` TXT per domain - multiple SPF records fail SPF.
- DKIM: each domain gets its own key in mailcow UI -> ARC/DKIM keys.

Verify every domain:

```bash
for d in htashop.com htasync.com dresslefy.com htasol.com; do
  echo "== $d"
  dig +short MX $d
  dig +short TXT $d | grep spf
  dig +short TXT _dmarc.$d
  dig +short TXT dkim._domainkey.$d | head -c 60; echo
done
```
