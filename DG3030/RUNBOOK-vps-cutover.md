# RUNBOOK — point Caddy at the VPS tunnel and go public

**Written 2026-09-02.** Replaces the since-deleted `RUNBOOK-port-forward.md`,
which is obsolete: it targets the dead Comcast WAN and a port-forward chain we
no longer intend to build.

**Where we are.** The VPS (`172.233.207.73`) is rented, hardened and running
nginx's stream proxy on `:443`. The WireGuard tunnel is up and verified
(`10.10.0.1` ↔ `10.10.0.2`, 5.98 ms, 0% loss). ✅ **COMPLETE — Caddy now listens on
the tunnel and `https://watch.datakiin.com` is live.** Kept as the record of how, and as the rollback procedure.

**What you are changing.** Two files on labserver, one `docker compose`
recreate, one DNS record. Everything is on machines we control; **nothing here
needs Danny, and nothing here opens an inbound port anywhere.**

**Time:** about 20 minutes, most of it verification.

---

> ## ✅ STEPS 1–5 COMPLETED 2026-09-02 — the public path is live
>
> | Step | Result |
> |---|---|
> | 1. Backups | `*.bak-prevps-20260902`, checksummed identical to the live files |
> | 2. Copy | box matches repo: Caddyfile `009cb7b0…`, compose.yml `38b56004…`; `.env` untouched |
> | 3. Recreate | clean, no errors |
> | 4b. Listeners | `192.168.50.10:443` + `10.10.0.2:443`, **no UDP** |
> | 4c. Certificate | `CN=*.datakiin.com`, Let's Encrypt `YE1`, valid to 1 Dec 2026 |
> | 4d. **LAN-direct** | ✅ **`http=302 verify=0 proto=2`** — the flagged risk did not materialise |
> | 4e. VPS → Caddy | `443 OPEN over tunnel` |
> | 5. Outside-in | ✅ **`http=302 verify=0`**, `connect=0.036s`, wildcard cert seen from outside |
> | HTTP/2 | `ALPN: server accepted h2` through the tunnel |
>
> ✅ **Step 6 (DNS) done too.** `watch.datakiin.com` resolves to
> **`172.233.207.73`** — and because it answers with the Linode address rather
> than Cloudflare anycast (`104.21.x` / `172.67.x`), **grey cloud is confirmed
> correct**, not merely intended. End-to-end with real DNS and no `--resolve`:
> `http=302 verify=0`. The Jellyfin login page loads in a browser with no
> certificate warning.
>
> ⏳ **Only Step 7 remains, and it is Danny's** — the Jellyfin Known-proxies
> setting. Everything on our side of the line is finished.
>
> 🔤 **Hostname changed to `watch.datakiin.com` after the fact** (was
> `jellyfin`) — the family should not need to know what Jellyfin is to read the
> address off a text message. **The wildcard cert made this free:** no reissue,
> no ACME round-trip, no new Certificate Transparency entry. The Caddyfile
> matcher is now `@watch host watch.datakiin.com` and the file checksum moved
> `009cb7b0…` → **`10694b9a…`**, deployed and live. Commands below use the new
> name throughout.
>
> 📌 A `302` rather than `200` at `/` is Jellyfin redirecting to `/web/` — normal,
> and the opposite of a `502`, which is what a broken upstream would give.

---

## Pre-flight — confirm the starting state

Run this first. If any line disagrees with the expected column, **stop** and
work out why before continuing.

```bash
ssh labserver 'ip -brief addr show wg0; sha256sum /srv/datakiin/stacks/caddy/Caddyfile /srv/datakiin/stacks/caddy/compose.yml; sudo docker ps --filter name=caddy --format "{{.Names}} {{.Status}}"'
```

| Expected | |
|---|---|
| `wg0 ... 10.10.0.2/24` | tunnel is up |
| Caddyfile `0e3598de…` | box still has the single-site version |
| compose.yml `91d27a9a…` | box still has the LAN-only publish |
| `caddy Up …` | container running |

⚠️ **If `wg0` is missing**, the tunnel did not survive a reboot. Bring it back
with `sudo systemctl start wg-quick@wg0` before going on — Step 3 will fail
outright without it, because Docker cannot publish on an address that does not
exist.

---

## Step 1 — Back up the box copies

Do this even though the files are in git. It makes rollback a single command
instead of a scp round-trip.

```bash
ssh labserver 'cd /srv/datakiin/stacks/caddy && cp Caddyfile Caddyfile.bak-prevps-20260902 && cp compose.yml compose.yml.bak-prevps-20260902 && ls -la *.bak-prevps-*'
```

---

## Step 2 — Copy the two edited files up

From the repo root on Romulus (`U:\FamilyNetwork\DG3030`):

```bash
scp caddy/Caddyfile caddy/compose.yml labserver:/srv/datakiin/stacks/caddy/
```

🚨 **Copy exactly those two files. Never `scp caddy/* `.** The box holds a
`.env` containing `CF_API_TOKEN` that is **not in the repo and must not be** —
a wildcard copy would either overwrite it with nothing or drag the secret into
version control. `jony` owns the directory, so no `sudo` is needed for this.

Confirm the box now matches the repo:

```bash
ssh labserver 'sha256sum /srv/datakiin/stacks/caddy/Caddyfile /srv/datakiin/stacks/caddy/compose.yml'
```

| Expected | |
|---|---|
| Caddyfile **`10694b9a…`** | wildcard + proxy_protocol + the `watch` matcher. *(Was `009cb7b0…` before the hostname rename — see the note at the top.)* |
| compose.yml `38b56004…` | LAN publish + tunnel publish, no UDP |

---

## Step 3 — Recreate the container

```bash
ssh -t labserver 'cd /srv/datakiin/stacks/caddy && sudo docker compose up -d --force-recreate'
```

**`--force-recreate`, not `restart`.** A plain restart reuses the existing
container's network and port config, so it would come back with the old
publish list and none of this would take effect. This is the same lesson the
2026-09-01 Caddy incident taught the hard way.

No `--build` — the `Dockerfile` is unchanged (`d2722e15…` on both sides) and
the `caddy-cloudflare:local` image is already built.

⚠️ **This issues a fresh `*.datakiin.com` certificate.** The box has been
running a single-site Caddyfile; the repo version is the wildcard. That is
deliberate and it is the privacy-improving direction — Certificate
Transparency will now show only `*.datakiin.com` instead of publishing each
service name — but it is a real change, so expect ~10–30 seconds of ACME work
in the log before the site answers.

---

## Step 4 — Verify, in this order

### 4a. The container actually has a network interface

```bash
ssh labserver 'sudo docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}={{\$v.IPAddress}} {{end}}" caddy'
```

Expect `edge=172.20.0.x`. **An empty or missing address is the exact failure
from 2026-09-01** — a container that runs perfectly with only loopback,
serving nothing and failing ACME with `lookup ... on [::1]:53`. If you see it,
the fix is another `up -d --force-recreate`, not a restart.

### 4b. Both listeners exist, and no UDP

```bash
ssh labserver 'ss -tlnp | grep 443; echo "--- udp (expect nothing) ---"; ss -ulnp | grep 443 || echo "none, correct"'
```

| Expected | |
|---|---|
| `192.168.50.10:443` | house clients, direct |
| `10.10.0.2:443` | the tunnel — this is the new one |
| no UDP 443 | HTTP/3 is off; the VPS cannot relay QUIC |

### 4c. The certificate is real, and is the wildcard

```bash
ssh labserver 'sudo docker logs caddy 2>&1 | grep -iE "certificate obtained|error" | tail -10'
```

Expect a `certificate obtained successfully` line naming `*.datakiin.com`.

### 4d. ✅ LAN-direct access still works — VERIFIED, was the one uncertainty

```bash
ssh labserver 'curl -sS -o /dev/null -w "http=%{http_code} verify=%{ssl_verify_result}\n" --resolve watch.datakiin.com:443:192.168.50.10 https://watch.datakiin.com/'
```

Measured: **`http=302 verify=0 proto=2`** — the 302 is Jellyfin redirecting to `/web/`.

**Why this step exists.** The `proxy_protocol` listener wrapper applies to
*both* published addresses, and a house client connecting straight to
`192.168.50.10:443` sends **no PROXY header**. Caddy's `allow 10.10.0.1/32`
**does** make the header optional for every other source — now measured, where
before it was only expected. Keep this check whenever the wrapper is touched:
had it gone the other way, **every house client would have broken** while the
public path looked perfect. If it ever returns a TLS error or a hang, the fix is to
split the LAN door onto its own server block.

### 4e. The VPS can now reach Caddy

```bash
ssh vps 'timeout 5 bash -c "</dev/tcp/10.10.0.2/443" && echo "443 OPEN over tunnel" || echo "still closed"'
```

Expect `443 OPEN over tunnel`. Before Step 3 this was closed.

---

## Step 5 — Prove the public path end to end

**Run this from Romulus, not from labserver and not from the VPS.** Romulus is
at your house on a different ISP connection, so this is a genuine outside-in
test. It works with no DNS record because `--resolve` supplies the answer.

```bash
curl -sS -o /dev/null -w "http=%{http_code} verify=%{ssl_verify_result}\n" --resolve watch.datakiin.com:443:172.233.207.73 https://watch.datakiin.com/
```

Measured: **`http=302 verify=0 proto=2`** — the 302 is Jellyfin redirecting to `/web/`.

**No `-k`, deliberately.** Caddy falls back to its own internal CA when ACME
fails, and that fallback serves HTTPS perfectly happily — `-k` would make a
self-signed fallback and a real Let's Encrypt cert look identical.
`verify=0` is the actual proof.

If that passes, the whole chain is live: **internet → VPS `:443` → nginx
stream → WireGuard tunnel → Caddy → Jellyfin**, with no inbound rule at
Danny's perimeter.

| Symptom | Where it broke |
|---|---|
| connection refused | VPS nginx not listening, or Cloud Firewall missing 443/tcp |
| hangs, then times out | tunnel down — check `wg show` both ends |
| `502` | Caddy reachable but Jellyfin is not; check `docker logs caddy` |
| `verify` non-zero | ACME failed and Caddy is serving its internal CA |

---

## Step 6 — DNS

Cloudflare → `datakiin.com` → DNS → Add record:

| Field | Value |
|---|---|
| Type | **A** |
| Name | `watch` |
| IPv4 | **`172.233.207.73`** — the VPS, *not* Danny's house |
| Proxy status | 🔘 **DNS only — grey cloud** |
| TTL | Auto |

⚠️ **Grey cloud is mandatory and the dashboard defaults to orange.** Proxying
would route family video through Cloudflare's free CDN — the terms-of-service
risk that is the entire reason media does not ride the tunnel. One default
toggle silently reverses that decision.

✅ **The DDNS gap is gone.** Every previous draft of this plan needed a
dynamic-DNS updater because the record pointed at a residential IP on a
changing lease. **A Linode address is static**, so the record is written once
and never again. The planned `dg.datakiin.com` indirection is no longer needed
— delete that idea rather than building it.

Then re-run Step 5 **without** `--resolve` to confirm real DNS works.

---

## Step 7 — Jellyfin must trust the proxy (ask Danny)

**This is the step that makes Steps 3–6 worth anything, and it is not ours to
change.** Jellyfin is Danny's service — propose, do not edit.

Jellyfin Dashboard → **Networking** → **Known proxies** → add `172.20.0.0/24`.

Without it, Jellyfin sees every internet viewer as coming from the Caddy
container's address, files them all as **local**, and applies **no remote
bitrate limit**. The PROXY protocol work in Step 3 delivers the real client IP
to Caddy, and Caddy passes it on in `X-Forwarded-For` — but Jellyfin ignores
that header from a proxy it has not been told to trust.

**Verify empirically once public:** stream from a phone on cellular and check
Dashboard → Devices shows a real public IP, not `172.20.0.x`.

While you have him: confirm **Playback → Transcoding → Hardware acceleration =
NVENC**. The capability is proven (8 concurrent sessions measured) but the
*setting* has never been read — `encoding.xml` is root-owned. If it is off,
every transcode lands on the CPU and the practical ceiling drops to about 3.

---

## Rollback

Safe at any point. Nothing here is destructive and the old files are two
copies made in Step 1.

```bash
ssh -t labserver 'cd /srv/datakiin/stacks/caddy && cp Caddyfile.bak-prevps-20260902 Caddyfile && cp compose.yml.bak-prevps-20260902 compose.yml && sudo docker compose up -d --force-recreate'
```

That restores the LAN-only single-site Caddy exactly as it was this morning.
The tunnel and the VPS are untouched by a rollback — they are independent and
can stay up.

The issued `*.datakiin.com` certificate is not rolled back and does not need to
be; it sits unused in the `caddy_data` volume and costs nothing.

---

## After this runbook

In rough priority order — none of it blocks the above:

1. **Deploy Nextcloud** — [`nextcloud/`](nextcloud/) is authored, not deployed.
   The Caddyfile already routes `cloud.datakiin.com` to it, so that hostname
   will 502 until the stack is up. Needs its own DNS record, same shape as
   Step 6.
2. **Migrate Minecraft off Romulus**, then add mc-router on the VPS for TCP
   25565 and the voice UDP range — plus the matching Cloud Firewall rules
   (`25565/tcp`, `24454-24473/udp`), which are deliberately not open yet.
3. **Re-run the isolation test** after any further firewall or policy change.
   It passed cleanly after the tunnel went up; it stays a standing obligation,
   not a one-time check.
4. **Optional:** close `22/tcp` on the Cloud Firewall and admin the VPS as
   `ssh -J labserver root@10.10.0.1`. Works today, but it makes VPS admin
   depend on labserver being up. Lish is the break-glass either way. No
   urgency — the port is key-only.
