# DG3030 — Datakiin Homelab

Outward-facing, self-hosted homelab built on **Danny Gracias's (DG3030) dedicated server**, administered remotely by Jon from Romulus. This folder is the working root for the build: infra, networking, service setup, and diagnostics. Spun out of [FamilyNetwork](../CLAUDE.md) on 2026-08-10.

## Role

Same hat as FamilyNetwork: a seasoned IT technician (CompTIA A+/Network+), **diagnostic-first, least-exposure, one-change-at-a-time, document-as-you-go.** Ping/port-test/read state before changing anything.

**This machine IS ours to break.** Danny granted full trust and permission to Jon — **with one boundary: never delete or tamper with data that belongs to Danny.** Break the config, not his files.

## Scope

- **In scope:** remote access (SSH over Tailscale), the container host, Caddy + Let's Encrypt, Cloudflare tunnels, a rented VPS relay for game traffic, storage, per-service setup (Jellyfin, Immich, Nextcloud, emulators, local AI), diagnostics, documentation.
- **In scope (CHANGED 2026-08-13):** the **Minecraft server software itself** — worlds, packs, plugins, server management. **All of it eventually lives on this machine**, along with the MC website. **Romulus becomes a development machine only.** This reverses the earlier "separate project/agent" boundary that still applies over in [FamilyNetwork](../CLAUDE.md).
- **Authorization:** Danny owns the server and handed Jon the login deliberately. ✅ **Confirmed 2026-08-13: Danny approached Jon to build this and gave full permission to carry on, including making the box internet-facing.** Jon funds it. The one boundary that does *not* come from Danny is [Karla's isolation requirement](#-karlas-isolation-requirement--the-hard-constraint) — honour it as written.

## The players

| Machine   | Address | Where | OS / notes |
|-----------|---------|-------|------------|
| Romulus   | `100.118.236.2` (TS) | Jon's house | Admin workstation → **dev machine only** going forward. Tailscale as `jon.gracias@`. Holds SSH keypair `jon@romulus`. |
| labserver | **`100.86.218.41` (TS)** · LAN `192.168.50.10` | **Danny's house** | **The workhorse.** Debian 13 (trixie). ASUS PRIME Z490-A, **i7-10700 (8C/16T)**, **62 GB RAM** + 49 GB swap, **RTX 3060 12 GB**. ~3.7 TB free. Owned by `DG3030@`, FQDN `labserver.tail663992.ts.net`. Runs **Jellyfin** (8096) + **Samba**. Login `jony`, key auth, password-required sudo. |
| FortiGate 40F | `192.168.50.1` | Danny's house | 🆕 **The gate.** Installed by Danny 2026-08-13. 5× GbE, no Wi-Fi radio. labserver now sits behind it, isolated from the house LAN. |
| **datakiin-relay** | **`172.233.207.73`** · tunnel `10.10.0.1` | Linode `us-iad` | 🆕 **The public door.** Rented 2026-09-02. Nanode 1 GB, Debian 13, $5/mo. Stateless relay — **terminates no TLS, holds no cert, stores no data.** SSH alias `vps`, root + key only. Rebuildable from [`vps/setup-vps.sh`](vps/setup-vps.sh). |
| Ryzen mini (K11) | — | — | ❌ **SCRAPPED.** labserver's 62 GB RAM + RTX 3060 host everything. Not needed, not planned. |
| Storage | on labserver | Danny's house | **Nothing to buy** — ~3.7 TB free across 3× NVMe + a 2 TB HDD, plus Jon's dedicated 4 TB at `/srv/datakiin`. |

## Access

- **Transport is Tailscale — this is how every command in this project actually runs.**
  - 📌 **Correction (2026-08-13).** An annotation in the previous draft read *"this did not work and we are straight only SSH."* That conflates two different things. **`100.86.218.41` is a Tailscale IP** (`100.64.0.0/10` is Tailscale's range) and `ip -brief addr` shows it on the **`tailscale0`** interface. Every diagnostic in this document was collected over that address. The mesh is in use and load-bearing.
  - What *was* ruled out and switched off is **Tailscale's built-in SSH feature** (`tailscale set --ssh=false`) — it cannot authorize a user on a node that is only *shared* in, and while enabled it grabs port 22 ahead of the real sshd. Port 22 is plain key-based OpenSSH. **"Tailscale SSH is off" ≠ "we aren't using Tailscale."**
  - 🔥 **Proof it matters:** when Danny installed the FortiGate, labserver moved from `10.0.0.41` to `192.168.50.10` behind a new NAT with no inbound forward. Anything pointed at a LAN IP would have been cut off instantly. Tailscale is outbound-initiated, so **access survived the topology change without a single config edit.**
- **Auth: key-based SSH only.** Romulus's `id_ed25519.pub` (`jon@romulus`) is the authorized key. Claude never types passwords into prompts.
- [`setup-labserver-access.sh`](setup-labserver-access.sh) — the script that established access. Run **on labserver** by a sudo user (`bash setup-labserver-access.sh [user]`, defaults to `jony`). Disables Tailscale SSH, appends Romulus's key to `~/.ssh/authorized_keys`, fixes `700`/`600` modes. Idempotent.
- Tailscale CLI on Romulus: `C:\Program Files\Tailscale\tailscale.exe` (not on PATH).
- MagicDNS short name `labserver` did not resolve from Romulus (2026-08-10) — use the IP or FQDN.
- ⏳ **TODO:** `~/.ssh/config` alias `labserver` → `HostName 100.86.218.41`, `User jony`.

## 🚨 Karla's isolation requirement — the hard constraint

**Karla is Danny's wife. Her job is sensitive and she does not want the household's computers reachable from labserver.** This is the **top constraint on the project** — above convenience, above cost, above every service on the roadmap.

She is right to ask. **We are deliberately turning labserver into an internet-facing machine**, which raises the odds it is eventually compromised (a Minecraft plugin RCE, an exposed model API, a stale container). Until 2026-08-13 that box sat on the **same Ethernet segment as her work machine** — its own ARP cache held a house machine's MAC. An internet-facing host on a flat home LAN is the textbook pivot.

> ✅ **RE-VERIFIED 2026-09-01 against the new Fios subnet — isolation HOLDS, and we now know why.** The 🔴 STALE warning that stood here (raised 2026-08-29, when the ISP swap deleted the `10.0.0.0/24` this section measures against) is resolved. The method below was always right; only the address moved.
>
> **New house gateway derived, not guessed** — TTL-limited probe from labserver toward `1.1.1.1`: `ttl=1` → `192.168.50.1` (the FortiGate), **`ttl=2` → `192.168.1.1`** (the Fios router), `ttl=3` → `169.254.3.1`, `ttl=4` → `100.41.33.70` (Verizon). The double-NAT topology survived the swap.
>
> | Probe against `192.168.1.1` | Result |
> |---|---|
> | `ip route get` | route **exists** via `192.168.50.1` → traffic is **dropped by policy**, not merely unrouted |
> | ICMP ×3 | **100% packet loss** |
> | TCP 80 / 443 / 53 / 22 / 8080 | **all blocked** |
> | sweep of other `192.168.1.x` hosts | nothing answered |
> | **control** `1.1.1.1:443` and `:53` | **reachable** — so the test is valid, not a general outage |
>
> 🎯 **This answers the question the warning posed.** The FortiGate deny was **not** written against a `10.0.0.0/24` address object — it is blocking a subnet that *did not exist when the policy was authored*, so it must be interface- or zone-based. Had it been address-object based, Karla's protection would have silently become a no-op behind a green UI.
>
> ⚠️ **Do not read that as vindication.** We did not design it that way and could not have said which it was; the good outcome was Danny's config choice, not our control. **Still ask him to confirm the policy is interface-to-interface**, so the next upstream change is a non-event rather than another unverified period.

### ✅ SOLVED AND VERIFIED 2026-08-13 — the FortiGate is in

Danny installed his **FortiGate 40F** during a shutdown he requested. labserver came back on a different network, and the isolation now **measures** as working.

| | before | after |
|---|---|---|
| labserver LAN address | `10.0.0.41/24` — **on the house LAN** | **`192.168.50.10/24`** |
| default gateway | `10.0.0.1` (house router) | **`192.168.50.1`** (the FortiGate) |
| public IPv6 on `enp2s0f0` | `<DANNY-WAN-V6>` | **gone** — link-local only |
| WAN IP (unchanged) | `<DANNY-WAN-COMCAST>` | `<DANNY-WAN-COMCAST>` |

**The empirical test** — probed the house **gateway only** (`10.0.0.1`, infrastructure; deliberately *not* a personal machine):

```
route to 10.0.0.1        via 192.168.50.1   (route exists → traffic is DROPPED, not merely unrouted)
ICMP    10.0.0.1         100% packet loss
TCP     10.0.0.1:80      blocked
TCP     10.0.0.1:443     blocked
TCP     10.0.0.1:53      blocked
control TCP 1.1.1.1:443  reachable          (internet unaffected)
```

⚠️ **ICMP-blocked does not imply TCP-blocked** — a ping-only test would have been a false pass. Both halves are now satisfied: labserver is on its **own broadcast domain** (ARP spoofing structurally impossible) *and* **cannot route to the house subnet** (the L3 half).

**Still to confirm with Danny:** whether Karla also got her own VLAN; whether labserver's segment is a true DMZ (explicit deny → house) or a separate subnet that happens to filter; and the port/switch layout. *The measurement proves the effect, not the configuration.*

✅ **Topology partially confirmed 2026-08-14 — the FortiGate is behind the house router (double NAT), measured not assumed.** A TTL-limited probe from labserver toward `1.1.1.1`:

```
ttl=1  192.168.50.1     the FortiGate
ttl=2  10.0.0.1         the Comcast router
ttl=4  68.87.137.141    Comcast infrastructure
```

So the FortiGate holds an interface on `10.0.0.0/24` and the Comcast gateway is **not** bridged. This matters concretely: it is what makes the port-forward a **two-hop** chain, and it fixes the FortiGate VIP's "external IP" as its own `10.0.0.x` WAN address rather than the public `<DANNY-WAN-COMCAST>`. Had the gateway been bridged, the router forward would not exist and the VIP would take the public IP — a materially different build.

⚠️ **Still unknown: the FortiGate's actual WAN address, and whether it is static or a DHCP lease.** Unknowable from our side — labserver is blocked from `10.0.0.1` by design, and the FortiGate's admin interface is **not listening toward labserver** (`192.168.50.1` closed on 80/443/8080, which is correct hygiene). **Ask Danny; he may have set it statically already.** ⚠️ Note that nothing in this repo ever *measured* it as DHCP — an earlier draft of the runbook asserted it was, which was intent restated as fact.

### ⚠️ Why a host firewall was never going to be enough

Never let anyone (including us) call this solved with `ufw deny out to 10.0.0.0/24`. That rule is enforced **by the machine we are assuming gets owned** — root flushes it. Worse, on a shared L2 segment a rooted box can **ARP-spoof** regardless of its own ruleset. Host rules are additive; they are never the primary control. The isolation had to live *off* the host, and now does.

<details>
<summary><b>How ARP spoofing works</b> — the attack the separate broadcast domain kills</summary>

Ethernet delivers frames by **MAC**, not IP. Before Karla's PC can reach the gateway it must learn `10.0.0.1`'s MAC. **ARP** is that lookup: broadcast *"who has 10.0.0.1?"*, cache whoever answers. Real values observed on that segment — gateway `10.0.0.1` = `b8:a5:35:90:ea:09`, a house machine `10.0.0.181` = `7c:8a:e1:e3:dd:84`, labserver = `1a:4b:24:a0:f1:3a`.

**The flaw: ARP (RFC 826, 1982) has no authentication.** Replies aren't matched to requests and hosts accept unsolicited ones ("gratuitous ARP"). So a rooted labserver simply announces a lie:

```
normal     Karla's PC ──► b8:a5:35:90:ea:09 (real router) ──► internet

poisoned   labserver broadcasts "10.0.0.1 is at 1a:4b:24:a0:f1:3a"
           Karla's PC ──► 1a:4b:24:a0:f1:3a (labserver) ──► router ──► internet
                                    └── reads / drops / delays everything
```

Send the mirror lie to the router and it sits in the middle of **both** directions.

**What it yields:** HTTPS payloads stay encrypted — this is not "reads her documents." What leaks is **destination metadata**: DNS queries, TLS SNI, timing, volume. Every domain she visits, which corporate/VPN endpoints she reaches, when and how much. For a sensitive job that pattern *is* the sensitive thing. The attacker can also drop or delay traffic at will and forge responses to anything unencrypted.

**Why the gate kills it:** ARP is **broadcast-scoped** — it never leaves its own broadcast domain. On `192.168.50.0/24` behind the FortiGate, labserver's ARP frames physically cannot reach `10.0.0.0/24`. It can't answer for `10.0.0.1` because it never hears the query. Layer 2 terminates at the gate; only routed IP packets pass, and those are dropped by policy.

</details>

<details>
<summary><b>What a DMZ is</b> — and the consumer-router trap that shares the name</summary>

A **DMZ is a network segment holding the machines that must accept connections from strangers**, placed so that when one is compromised the attacker has landed somewhere with nothing worth reaching.

**It is defined by its traffic policy, not by where the cable goes:**

| Direction | Policy |
|---|---|
| Internet → DMZ | allow, **only the published ports** (here: 443) |
| DMZ → Internet | allow (updates, DNS, outbound tunnels) |
| **DMZ → internal LAN** | 🚫 **DENY — this single rule is the whole point** |
| internal LAN → DMZ | allow *only if something still needs it* |

Strip out the deny and it isn't a DMZ, it's a VLAN.

⚠️ **Not the "DMZ host" checkbox on consumer routers.** That forwards *every* inbound port to one internal IP and leaves it on the ordinary LAN with full reach into everything — maximum exposure, zero containment. The name is simply misused. Build a real one on the FortiGate: own interface/VLAN plus the policies above.

- ✅ **Tailscale admin works from inside a DMZ with no inbound hole** — outbound-initiated, so it needs nothing from the `Internet → DMZ` row. Already proven by the FortiGate cutover.
- 🔗 **`LAN → DMZ` is where the Samba decision lands** (below): keep Samba and that row must allow `445` from the house; retire it and the row can be denied outright.

**What a DMZ does *not* do:** it doesn't stop the service being compromised, only limits where the attacker goes next; and it does **not protect labserver's own data** — Immich photos and Nextcloud files live *in* the DMZ, so a breach exposes them regardless. Segmentation protects the *house*, not the server's contents. Per-service auth and off-box backups cover that.

</details>

### ✅ The Samba "cost" — DISSOLVED 2026-08-13, not traded away

We expected a painful choice: Samba (`445/139/137/138`, sharing `Media`/`Shared`/`Projects`/`homes` off `/mnt/media`) and LAN Jellyfin (`8096`) looked incompatible with isolation, forcing Danny to migrate to Nextcloud/SFTP or lose his shares. **He solved it himself — he has a FortiGate rule permitting the house to reach labserver.**

**The two requirements were never actually in conflict, because the requirement is *directional*:**

- Karla's concern is **labserver → house** (a compromised server pivoting into her machine).
- Danny's rule is **house → labserver** — the opposite direction.
- A stateful firewall lets *return* traffic flow for a connection the house initiated. That is not labserver initiating anything, so it grants no pivot.

✅ **Re-verified after the rule was added** (do not take this on trust — a new policy is exactly what can silently widen things): labserver → `10.0.0.1` is **still blocked on ICMP and TCP 80/443/53**, while `1.1.1.1:443` still works. **Isolation intact, shares preserved, no trade made.**

⚠️ **The one residual, stated honestly:** a compromised labserver still *serves* SMB to whichever house machines connect to it, so it could attack those clients (malicious-server→client exploits, or planting files in a share that later get run). That is far narrower than L2 adjacency — it only touches machines that voluntarily connect — but it is not zero. Not worth acting on now; worth knowing.

### ❓ Open questions for Danny (phone — see Presence + messaging)

1. Is Karla's "company firewall" an **employer-issued appliance** or did he mean the FortiGate? If employer kit: **hands off** — that is their security domain and their requirements win.
2. Is Karla on **Ethernet or Wi-Fi**? The 40F has **no Wi-Fi radio**. Ethernet → her own port, trivial. Wi-Fi → her VLAN needs an AP that maps SSIDs to 802.1Q tags, which most consumer routers in AP mode **cannot** do.
3. **Managed 802.1Q switch, or one FortiGate port per segment?** ⚠️ An unmanaged switch silently collapses VLANs — two devices on the same dumb switch are on the same segment no matter what the firewall UI says.
4. Any **support entitlement** on the 40F? Basic firewall/NAT/VLAN/VIP work unlicensed (all we need); what lapses is **FortiOS firmware updates**, and FortiOS CVEs cluster in **SSL-VPN and the admin interface** — so keep SSL-VPN off and management off any WAN-facing interface.
5. **Samba + LAN Jellyfin** — move or drop?
6. 🆕 **Is the FortiGate's WAN address already static, and what is it?** Needed for the port-forward (it is the VIP's "external IP" and the router forward's target). Unknowable from our side. If it is still a DHCP lease from the house router, pin it — a drifting lease breaks the public door silently, months later.
7. 🆕 **What is the Comcast router's DHCP pool range?** So the static WAN address is chosen outside it and cannot later collide with a handed-out lease.

> ⚠️ **Port budget is exactly tight:** WAN + house + DMZ + Karla + AP uplink = 5 of 5 GbE ports. No slack.
>
> 🔒 **The one permanent host rule:** **never `--advertise-routes`** from labserver — that would put the whole tailnet onto Karla's segment in one command. Verified clean: `AdvertisedRoutes: None`.
>
> 📌 **Correction 2026-08-13 — "`ip_forward` stays `0`" is obsolete, and how it died is the point.** That was recorded here as a standing safety property. **Installing Docker silently flipped it to `1`** (containers cannot route out otherwise), and nothing warned us. **Do not set it back** — that would break container networking, and it is no longer the control.
>
> It never should have been. Isolation is enforced **at the FortiGate, off the host** — re-tested immediately after the Docker install and still holding (`10.0.0.1` blocked on ICMP and TCP 80/443, `1.1.1.1:443` fine). Had we been leaning on a host-level kernel flag, a routine `apt install` would have quietly removed Karla's protection and no alarm would have sounded. **This is the "host-based controls are an honor system" argument demonstrating itself, benignly, in about ninety seconds.**

## Architecture — everything goes out, nothing comes in from the LAN

**Revised 2026-08-13.** The original design put family services on the Tailscale mesh and used network membership as authentication. **That model is retired.** The family reaches every service **over the internet** — including Jellyfin via the official Android/iOS/TV apps — and labserver talks to the house LAN not at all.

The shift to internalize: **we traded "network membership = auth" for "real application auth + isolation."** The mesh used to *be* the access control. Now every service must carry its own authentication, because the network no longer gates anything.

| Service | Traffic | Door | Auth |
|---|---|---|---|
| `play.datakiin.com` — install scripts, portfolio | HTTP | **Cloudflare Tunnel** | none needed (public by design) |
| **Minecraft** instances | raw TCP + UDP (voice) | **a VPS we rent** — WireGuard back to labserver, mc-router on the VPS | game-level |
| **Jellyfin** + phone/TV apps | HTTP, heavy video | 🔄 **VPS relay → Caddy on labserver** (was: forwarded 443) | Jellyfin accounts |
| **Nextcloud** — movie + home-video ingest | HTTP, large uploads | 🔄 **VPS relay → same Caddy** | Nextcloud accounts |
| **Immich** | HTTP | same Caddy | app accounts |
| **odin / Ollama** | HTTP API | Caddy **with auth in front** | ❗ Ollama has **none** — blocker |
| **Admin (Jon's SSH)** | SSH | **Tailscale** — no public port 22 | SSH keys |

**Tailscale is not dropped — its job changed.** It stops being the family's access path and becomes the **admin plane**: Jon's SSH, no exposed port 22, no brute-force surface, and it survives topology changes (proven by the FortiGate cutover).

### Two blockers that bite if ignored

1. **Do not put Jellyfin behind a free Cloudflare Tunnel.** Cloudflare's self-serve terms restrict serving large volumes of non-HTML content (video) through the free CDN; Jellyfin-over-tunnel is a widely reported cause of account warnings and termination. Verify against current terms before relying on it; until then treat it as **disqualifying for media**. Cloudflare stays right for `play.datakiin.com`, which is text and scripts.
2. **Ollama has no authentication of any kind.** Exposing `odin` as-is hands the world a free GPU *and* an API that can pull and **delete** models. It must sit behind something that authenticates — Caddy basic auth, Open WebUI accounts, or Cloudflare Access. Rate-limit it. This is why the current `0.0.0.0` bind must be fixed **before** anything public ships.

## The front door — Caddy, no VPS for the web door (decided 2026-08-13)

> 📌 **PARTIALLY REVERSED 2026-09-01 — the media door moves onto the VPS too.** This heading has now been narrowed twice: first on 2026-08-27 (games), now again for **Jellyfin and Nextcloud**. What survives unchanged is **websites**, which stay on the Cloudflare Tunnel for a reason this section never weighed: the tunnel is free, absorbs DDoS, and costs the VPS no bandwidth.
>
> **The reversal is not about anonymity** — the "hide the IP only from hostile audiences" argument below is still correct and still says family video does not need hiding. It is about **dependency**: every remaining task on the media door needed Danny at a console on a brand-new Fios router, and the VPS deletes all of them at once. Cost was never the deciding factor either way; ~€4/mo was already committed for games.
>
> ⚠️ **One boundary this creates:** Cloudflare **terminates TLS at its edge and can read anything crossing the tunnel.** Fine for `lab.datakiin.com` (public static content); disqualifying for Nextcloud or Jellyfin. That is now a *second, independent* reason those stay off the tunnel, alongside the video terms-of-service issue.


### Why no VPS *for the web and media doors*

📌 **Scoped 2026-08-27.** This section originally read as a blanket "no VPS." It is not one any more: the **game door now runs on a rented VPS** (see "The game door" below). Everything here is still correct **for HTTP** — web, Jellyfin, Immich, Nextcloud — and those doors stay VPS-free. What changed is that a different door, carrying a different protocol for a different audience, reached a different answer for a reason this section never weighed.

**A reverse proxy and a VPS are not alternatives.** The proxy terminates TLS and routes hostnames to backends — you need one either way. A VPS is merely *a public IP that isn't your house*. The real question is **where the proxy runs and how traffic reaches it**.

✅ **Verified: the WAN IP is `<DANNY-WAN-COMCAST>` — a real routable Comcast address, NOT CGNAT** (`100.64.0.0/10`). Inbound port-forwarding is therefore available, and that single fact is what makes the free path work. Under CGNAT a relay would have been compulsory.

**Result for the web/media doors: $0/mo recurring, $0 one-time** (the FortiGate was already owned). The earlier "~$15–30/mo, VPS required" estimate is **withdrawn**. ⚠️ The *project* total is no longer $0 — the game door's VPS runs roughly **$4–5/mo**; see Cost.

### Why Caddy and not nginx or Apache

**Decision: Caddy for everything. One proxy, not two.**

The tempting split — "Caddy for the easy things, nginx for Jellyfin" — is backwards. Jellyfin is precisely where Caddy is *simpler*; the long nginx Jellyfin configs online are long because nginx must be told what Caddy does by default.

| | Caddy | nginx | Apache |
|---|---|---|---|
| WebSockets (Jellyfin needs them) | automatic | explicit `Upgrade`/`Connection` headers | `mod_proxy_wstunnel`, fussier |
| Streaming / range requests | streams by default | often needs `proxy_buffering off` | heavier process model |
| HTTP/2 + HTTP/3, modern TLS | on by default | configure it | configure it |
| Cert issuance + renewal | **built in** | certbot + renewal cron | certbot + renewal cron |
| DNS-01 wildcard | plugin, then automatic | manual hooks | manual hooks |

**Running two proxies is the actual mistake:** only one process binds `:443`, so a split means chaining them; you'd maintain two TLS mechanisms, two config languages, and two places to look when something 502s. It also fails the Danny test — the other admin has to be able to fix this at the console. (Same reasoning that settled Kubernetes.)

**The feature that decides it:** DNS-01 wildcard issuance via the **Cloudflare API** — DNS is already there, so `*.datakiin.com` needs **no port 80 hole**, and adding a service is three lines with zero certificate work:

```caddy
watch.datakiin.com {
    reverse_proxy 127.0.0.1:8096
}
```

⚠️ **One wrinkle:** the Cloudflare DNS module is **not in the stock Caddy binary**. Use an `xcaddy` build or a prebuilt image containing the module. One-time setup, then invisible.

**When nginx would win:** fine-grained rate limiting or a caching layer. The only candidate on this roadmap is the odin auth/rate-limit story, and Caddy handles basic rate limiting fine. Revisit only if that proves false.

### ✅ DEPLOYED AND VERIFIED 2026-08-14 — real Let's Encrypt cert, DNS-01, no port 80

The stack lives in [`caddy/`](caddy/) (Dockerfile · compose.yml · Caddyfile · .env.example) and is deployed on the box at **`/srv/datakiin/stacks/caddy/`**. All four files are **byte-identical to the repo copies** (sha256 compared 2026-08-14) — the box is not drifting from version control.

**The build:** `caddy:2-builder` → `xcaddy build --with github.com/caddy-dns/cloudflare` → binary copied onto `caddy:2`. Tagged `caddy-cloudflare:local`. Built from the **official** Caddy builder rather than a third-party `caddy-cloudflare` image, deliberately: this process terminates TLS for the family's services, so nothing unvetted goes in it.

| Check | Result |
|---|---|
| Caddy process | pid 11758, `caddy run --config /etc/caddy/Caddyfile` |
| Container IP | `172.20.0.4` on the external `edge` network |
| Published ports | **`192.168.50.10:443` tcp + udp only** — HTTP/3 socket confirmed present |
| **Bound to `0.0.0.0`?** | ✅ **No.** `ss` shows `192.168.50.10:443`, and from **Romulus** 443 is **refused** while 22 still answers |
| Cert issuer | **`C=US, O=Let's Encrypt, CN=YE1`** — *not* the internal self-signed fallback |
| Chain | leaf → LE `YE1` → `ISRG Root YE` → `ISRG Root X2` → `ISRG Root X1` |
| Validity | `notBefore Aug 14 12:38:43 2026` · `notAfter Nov 12 2026` |
| SAN | `DNS:watch.datakiin.com` |
| **Trust-store validation** | ✅ `curl` **without `-k`** → `ssl_verify_result=0` |
| Proxy → Jellyfin | **HTTP 200**, `via: 1.1 Caddy`, `server: Kestrel`, Jellyfin **10.11.11** JSON |
| Unknown SNI | connection closed — **no default site**, nothing served by accident |
| Isolation after deploy | ✅ `10.0.0.1` still blocked on **80 and 443**; `1.1.1.1:443` fine |

✅ **DNS-01 worked with no A record in existence.** `watch.datakiin.com` is **NXDOMAIN in public DNS** and the cert issued anyway — because DNS-01 only requires the API to create and remove a `_acme-challenge.jellyfin` TXT record. Issuance never needs the hostname to resolve, and never needs port 80. That is the whole argument for DNS-01 demonstrating itself.

⚠️ **`reverse_proxy host.docker.internal:8096`, not `127.0.0.1:8096`.** Inside a container `127.0.0.1` is the *container's own* loopback — it would never reach Danny's native Jellyfin. `extra_hosts: host.docker.internal:host-gateway` maps to the `edge` bridge gateway **`172.20.0.1`**, and Jellyfin's own reply confirms the path: `"LocalAddress":"http://172.20.0.1:8096"`. The generic three-line snippet earlier in this document assumes a containerised backend; **a host-native backend needs the host-gateway form.**

### ✅ RESOLVED — the one-off 502, and the ufw rule that fixed it

The Caddy log contains exactly **one** 502 and **one** `i/o timeout` across the container's whole life:

```
13:37:13  certificate obtained successfully   watch.datakiin.com
13:39:56  dial tcp 172.17.0.1:8096: i/o timeout   status 502   duration 3.00s
```

**What the upstream actually is — measured, not inferred.** `getent ahosts host.docker.internal` inside the container returns a **single** address, and `/etc/hosts` holds one line:

```
172.17.0.1      host.docker.internal
```

So `host-gateway` maps to **`docker0`** (`172.17.0.1`) — which is **`DOWN`**, because every stack here uses the `edge` bridge and nothing is attached to the default one. The container is on `172.20.0.4`.

**Why it works anyway.** ufw gained a rule that is not in the documented six:

```
8096/tcp    ALLOW IN    172.20.0.0/14
```

**ufw matches on source address and destination *port*, not destination IP.** The container's source `172.20.0.4` falls inside `172.20.0.0/14`, so its packets to port 8096 are accepted **whichever host IP they target** — including `172.17.0.1`. Jellyfin binds `0.0.0.0`, the host treats `172.17.0.1` as local even with the interface down, and the request completes.

📌 **Two corrections to earlier drafts of this section, both worth keeping as reasoning errors:**

1. **"Intermittent 502" was wrong.** The inference was: same pid, never restarted, so nothing could have fixed it — therefore it must be per-request instability. That reasoning ignored that **the fix lived outside the process.** Adding a ufw rule changes the kernel's packet handling with no restart, no reload, and no trace in the application log. A long-running process can start succeeding for reasons that have nothing to do with the process.
2. **The multi-address theory was wrong.** `host.docker.internal` resolves to exactly one address. The theory was never tested before being written down — `getent` settled it in one command.

**Sequence that fits all the evidence:** container starts 13:37:02 → cert issued 13:37:13 → first request 13:39:56 dials `172.17.0.1:8096`, ufw has no rule for source `172.20.0.0/14`, packet is **DROPped** (hence `i/o timeout` at exactly 3.00 s, not `connection refused`) → the `8096/tcp ALLOW IN 172.20.0.0/14` rule is added → every request since succeeds. Zero further 502s.

### 🟡 Still worth tightening (robustness, not a defect)

It works, it is stable, and **it should not block the public launch.** But the path is more fragile than it needs to be:

- Traffic goes container → its gateway `172.20.0.1` → back to the host's **`172.17.0.1`, an address on a DOWN interface.** It resolves today because Linux keeps the address locally routable; that is a quiet dependency on a bridge nothing uses.
- The permitting rule spans **`172.20.0.0/14` — 262,144 addresses**, covering every current *and future* docker bridge. Any container in any later stack can reach Jellyfin on 8096. Jellyfin requires auth so this is not alarming, but it is far broader than the one gateway that needs it.

**The tightening, when convenient — two changes that belong together:**

```yaml
# caddy/compose.yml — name the live gateway instead of the host-gateway magic
extra_hosts:
  - "host.docker.internal:172.20.0.1"   # the edge bridge, NOT the DOWN docker0
```

```bash
sudo ufw delete allow from 172.20.0.0/14 to any port 8096 proto tcp
sudo ufw allow from 172.20.0.0/24 to any port 8096 proto tcp comment 'Caddy container -> native Jellyfin'
```

⚠️ **Do these as one change and re-test**, since narrowing the rule while the upstream still points at `172.17.0.1` is harmless (source still matches) but narrowing it *after* the `edge` network is ever recreated on a different subnet would break the proxy. `172.20.0.1` moves if `edge` is rebuilt — **re-check both lines if that happens.**

⚠️ **This whole path becomes load-bearing the moment Jellyfin is rebound off `0.0.0.0`** (see the Jellyfin bind note above). Today it survives partly because Jellyfin listens on every interface.

### 🔴 INCIDENT 2026-09-01 — Caddy came back from the reboot with no network at all

After the Fios-swap power-off, labserver booted 08:29 and Caddy's container started with it — and served nothing. `192.168.50.10:443` refused, and the log filled with ACME failures reading `lookup acme-v02.api.letsencrypt.org on [::1]:53: connection refused`, every 10 minutes.

**Root cause, measured:** the container had **no network interface but loopback**.

```
/proc/<caddy>/net/dev  ->  lo          (nginx and cloudflared both had lo + eth0)
```

No `eth0`, no route, no `172.20.0.x` address: it never joined the `edge` bridge. Every symptom follows from that one fact — a container with no endpoint cannot have a published port, cannot be reached at any bridge address, and cannot resolve DNS, so its resolver falls back to `::1:53` where nothing listens. Caddy itself was healthy and still holding a valid cert; it was listening on `[::]:443` inside a namespace nothing could route to.

**Fix — recreate, do not restart.** `docker restart` reuses the existing (broken) network config and comes back identical:

```bash
cd /srv/datakiin/stacks/caddy && sudo docker compose up -d --force-recreate
```

✅ **Verified after the fix:** container has `lo + eth0`; host shows `192.168.50.10:443` on **TCP and UDP** (the HTTP/3 socket is back); and from **Romulus**, through an SSH tunnel so the handshake terminated on Windows against its own certificate store — `http=200`, `ssl_verify_result=0`, issuer `C=US, O=Let's Encrypt, CN=YE1`, valid to 12 Nov 2026.

⚠️ **Two diagnostic errors were made getting here, both worth keeping:**

1. **Read `/proc/PID/net/tcp` only, and concluded "Caddy is serving no sites."** That file is **IPv4 only**. A Go server binding `:443` creates a dual-stack socket that appears *exclusively* in `net/tcp6`. The real listener list was there the whole time. **Check both files, or you will confidently declare a listening service dead.**
2. **Used `strtonum()` in an awk one-liner.** That is a **gawk** extension; Debian ships **mawk**, which errors out and prints nothing — which read as "the state changed" rather than "my parser broke." A second, differently-written probe minutes earlier had worked. **When output changes and the system did not, suspect the tool.**

Also disproved: the first hypothesis was a DHCP race — Docker binding `192.168.50.10:443` before the interface had its address. Plausible, wrong, and it survived only until the logs were read. **The logs named the actual failure in their first line.**

### 📋 ufw rules observed 2026-08-14 that are NOT in the documented six

`ufw status verbose` shows three additions beyond the post-FortiGate allow-list recorded above. Noting them so the next reader is not confused by the mismatch — **neither was added by this work**:

| Rule | Note |
|---|---|
| `8096/tcp ALLOW IN 172.20.0.0/14` | What makes Caddy→Jellyfin work. See above. |
| `445/tcp on tailscale0 ALLOW IN Anywhere` | "Samba via Tailscale". ⚠️ Probably **redundant** — this document's own finding is that **Tailscale installs its own netfilter accept rules and ufw does not gate `tailscale0` traffic at all.** The rule is harmless but likely does nothing; if it was added believing it *enabled* the access, that belief is worth correcting. |
| `445/tcp (v6) on tailscale0 ALLOW IN Anywhere (v6)` | Same, IPv6. |

`Default: deny (incoming), allow (outgoing), **deny (routed)**` — the routed default is correct and worth keeping.

### The two steps still needed to make it public

> 📕 **OBSOLETE 2026-09-01.** Both steps below assumed traffic arrives through Danny's router. Under the VPS design it does not: there is **no port-forward, no VIP, no FortiGate policy**, and the DNS record points at the VPS rather than a house IP that needs DDNS. Kept for the reasoning, not as work to do. The live plan is in the Status section.


Everything on the labserver side is done. Until both of these land, the door is reachable **only from labserver's own LAN segment** — where it is verified working end-to-end with a publicly-trusted cert. Neither is a failure of this build.

#### Step 1 — DNS: `watch.datakiin.com` (Jon, Cloudflare dashboard, 2 minutes)

The name is **NXDOMAIN** today — confirmed from both Romulus and labserver, with `lab.datakiin.com` as a working control.

Cloudflare → `datakiin.com` → **DNS** → **Records** → **Add record**:

| Field | Value |
|---|---|
| Type | **A** |
| Name | `jellyfin` |
| IPv4 address | **`<DANNY-WAN-COMCAST>`** (Danny's WAN — *not* Jon's) |
| Proxy status | 🔘 **DNS only — grey cloud** |
| TTL | Auto (drop to 2 min while testing) |

⚠️ **Grey cloud is mandatory, and the dashboard defaults to orange.** Proxying routes family video through Cloudflare's free CDN — the exact terms-of-service risk under "Two blockers that bite if ignored," and the entire reason Jellyfin gets its own Caddy door instead of riding the tunnel. One default toggle silently reverses that decision.

**A record, not AAAA:** labserver's public IPv6 disappeared when the FortiGate went in (`enp2s0f0` is link-local only now). There is nothing to point an AAAA at.

🔴 **The DDNS gap — the trap in this step.** Comcast IPs are dynamic, and the existing Cloudflare-DDNS script updates **`home.datakiin.com`, which tracks *Jon's* house (`<JON-WAN>`, the Romulus origin)**. Danny's WAN (`<DANNY-WAN-COMCAST>`) is a **different address with no DDNS at all**. So:

- ❌ **Do not CNAME `jellyfin` → `home.datakiin.com`** — that points at the wrong house entirely.
- A bare A record works **until Danny's lease changes**, then the door silently dies.
- ✅ **Better shape, one extra record:** create **`dg.datakiin.com` A → `<DANNY-WAN-COMCAST>`** (grey cloud) as the single place Danny's IP is written, point **`jellyfin` CNAME → `dg.datakiin.com`** (grey cloud), and run a DDNS updater **on labserver** against `dg`. Every future labserver hostname is then one CNAME, and the address lives in exactly one record — the same "never hard-code the address" reasoning that keeps `HostName` names in `~/.ssh/config`. The existing `CF_API_TOKEN` (Zone.DNS:Edit on `datakiin.com`) already has the permission to drive it.
- Start with the plain A record to prove the chain, but **add DDNS before anyone relies on this.**

Accepted by design: this record **publishes Danny's home IP**. That is the trade recorded under "Anonymity is per-audience" — and the reason Minecraft goes out through a VPS relay instead.

#### Step 2 — The port-forward chain (needs Danny: router + FortiGate)

📕 **The step-by-step that lived here (`RUNBOOK-port-forward.md`) was DELETED 2026-09-02** — the VPS design removed this whole chain. Kept below only as the reasoning behind a path not taken.

```
internet → Comcast router 10.0.0.1 → [forward 443] → FortiGate WAN
         → [VIP 443] → labserver 192.168.50.10:443 → Caddy
```

⚠️ **This is a double NAT, and it sets the one value people get wrong:** the FortiGate's VIP **external IP is its own WAN address (`10.0.0.x`), not the public `<DANNY-WAN-COMCAST>`.** Only the Comcast router ever sees the public address.

1. **Pin the FortiGate's WAN address first.** It currently takes a DHCP lease from the house router. Set it **static** on the FortiGate, outside the router's DHCP pool. A drifting lease breaks the forward months later, silently — and doing it on the FortiGate depends on nothing from Comcast's app.
2. **House router:** forward **TCP 443** → the FortiGate's (now static) WAN address.
3. **FortiGate VIP:** external interface `wan`, external IP = FortiGate WAN, mapped IP `192.168.50.10`, port-forward `443 → 443`.
4. **FortiGate policy — the VIP alone does nothing without it.** `wan → labserver's segment`, destination = **the VIP object only**, service = **HTTPS/443 only**, action ACCEPT. ⚠️ Keep it that narrow; an `any/any` here is how a DMZ quietly stops being one.
5. **Do NOT forward port 80.** DNS-01 means there is no HTTP-01 challenge and never will be.
6. **HTTP/3 is optional but decide deliberately.** Caddy advertises `alt-svc: h3=":443"` and the UDP socket is published. If **UDP 443** is not also forwarded, clients attempt h3, fail, and fall back to TCP — it works, with a first-connection delay. Either forward UDP 443 too, or turn h3 off.

**Verify from genuinely outside — a phone on cellular, Wi-Fi off.** Testing from inside the house is a false negative: consumer routers routinely fail hairpin NAT, so a working forward can look broken from the couch.

🚨 **Re-run the isolation test immediately after these policy changes.** A new firewall policy is exactly the event that can silently widen reach, and this document's own history has two examples of a security property dying to a routine change. Confirm `10.0.0.1` is still blocked on ICMP **and** TCP 80/443/53 while `1.1.1.1:443` still works.

**Then, before handing the URL to family:** confirm Jellyfin's "allow remote connections" is on, and set **per-user remote bitrate caps** — the doc's measured conclusion is that capping remote users at 4 Mbps/720p roughly doubles concurrent viewers, and it is a far bigger lever than any infrastructure change.

### Anonymity is per-audience, not per-server

The insight that collapsed this build from ~$15/mo to the media doors costing nothing. "Hide the home IP" is not a blanket rule — it depends entirely on **who is on the other end**:

- **Minecraft players are untrusted strangers.** Griefers DDoSing a server's home connection is common and would take Danny's whole household offline. This door **must** hide the IP → **a VPS relay we rent**.
- **Jellyfin viewers are your own family.** Paying to hide an address from people who already know it buys nothing.

Spend the free IP-hiding where the hostile audience actually is.

### The game door — a VPS relay, not playit.gg (decided 2026-08-27)

🔄 **This reverses the earlier playit.gg decision.** Recorded rather than edited away, because the reasoning that picked playit.gg is still sound and only its *arithmetic* stopped fitting. The principle above is unchanged: game traffic must not publish Danny's home IP. Only the mechanism that implements it changed.

**The shape:** a small VPS with a public IPv4. **labserver dials *out* to it over WireGuard**; the VPS holds the address players are given and pushes traffic back down a tunnel it did not open.

- **mc-router runs on the VPS**, terminating TCP 25565 there and routing by the hostname in the Minecraft handshake — so every world shares one game port. It works because the handshake carries **the address the player typed**, not the one DNS resolved to.
- **Voice is plain UDP forwarding** down the same tunnel — one firewall range rule (e.g. `24454-24473/udp`), not one router entry per world. mc-router speaks only the Minecraft TCP protocol and cannot multiplex UDP.
- ⚠️ **Use the provider's firewall, not `ufw` on the VPS.** Docker writes its own iptables rules and bypasses ufw — the same trap already documented under Lessons, and the reason a port you believe is closed stays open.

**Why it replaced playit.gg**, in order of weight:

1. **The free tier caps at 4 ports; Premium is $3/mo for 16.** The Minecraft project now runs **11 worlds**, each needing a TCP port (game) and a UDP port (simple-voice-chat) = **22 ports**. Neither tier covers it. mc-router collapses the TCP side to one port, which helps enormously — but voice is UDP and stays one port per world, so the ceiling still binds.
2. **~€4/mo buys unlimited ports, a chosen datacenter, and no third party in the critical path.** At that price the comparison is not close.
3. **It removes an external service from the family's infrastructure.** playit.gg's outages, terms and free-tier policy are all things nobody here controls.

**It satisfies the constraint playit.gg was chosen for, and tightens two others:**

- **Danny's home IP is never published to players.** Game hostnames point at the VPS. A griefer floods a €4 box we can rebuild, not the household's uplink.
- **No inbound rule anywhere** — no port-forward on Comcast's router, no VIP or policy on the FortiGate, for game traffic. NAT only blocks connections nobody asked for, and labserver asked for this one. Same property that already makes Tailscale and `lab.datakiin.com` work from inside the DMZ; **double NAT stops being a problem to solve.**
- **Karla's isolation is unaffected and arguably better**, because the game door stops requiring a hole at the perimeter at all.

✅ **Status 2026-09-02: the VPS and the tunnel are BUILT** — Linode Nanode 1 GB at `172.233.207.73` (`us-iad`, $5/mo), WireGuard up at `10.10.0.1` ↔ `10.10.0.2`. **What is not built is the game half:** mc-router is not installed, and `25565/tcp` + the `24454-24473/udp` voice range are deliberately **not open** in the Cloud Firewall. The relay currently carries HTTPS only. *(Superseded note: "decided, not yet built; Hetzner discussed at ~€4/mo, not a decision" — Hetzner was dropped, see the Cost section.)* 🔗 The Minecraft-side detail — mc-router, `voice_host`, the per-world SRV records — lives in [`MinecraftServers/CLAUDE.md`](../../MinecraftServers/CLAUDE.md); that document is the authority on the game specifics, this one on the household network.

### What publishing `watch.datakiin.com` does and does not expose

Precise, because these two risks get conflated constantly.

**What the DNS record reveals:** the IP, to anyone querying public DNS. From an IP you get **the ISP (Comcast) and a rough area** — residential geo-IP resolves to city/ISP-hub level and is routinely wrong by tens of miles. **An IP does not reveal a street address**; IP → subscriber identity requires a legal request to Comcast.

**What it does NOT do — it does not expose the LAN.** A DNS record is a name→number mapping; it opens nothing. Reachability comes only from the **port-forward**, which forwards exactly one port to exactly one host. Karla's machines are not reachable through it, and no amount of DNS querying changes that.

**The two real risks, kept separate:**

1. **DDoS / being a known target.** A published IP can be flooded, taking the *household's uplink* down — not the LAN. This is the common practical risk and exactly why the **Minecraft** door goes out through a VPS instead.
2. **Pivot after compromise.** If labserver is breached *through* the service behind that port, the attacker becomes a host on the network — Karla's risk. The DNS record isn't the cause; **exposing a service at all** is. The FortiGate makes the consequence survivable.

### What the media hostnames give up by staying off the VPS, honestly

A VPS now exists — for games. The media hostnames still come straight in through Danny's WAN, and that is a **live option, not a settled decision**: routing them over the relay too is possible and has not been evaluated. What it would cost is unmeasured; what staying costs is this:

- **The home IP is published in DNS** for the media hostnames — ISP + approximate metro, not an address, and **no LAN exposure**.
- **A DDoS against that IP takes the household offline.** Mitigated by keeping the DDoS magnet (games) off it and on the VPS.
- **Comcast's IP is dynamic** → needs DDNS. Already solved: a working Cloudflare-DDNS script exists in the Datakiin setup.
- **Upload bandwidth is Danny's home upload.** The VPS would not fix this — it would add a second bottleneck in front of the same 41 Mbps.

**What would move the media hostnames behind the VPS too:** they need anonymity as well, Comcast starts blocking inbound 443, or the connection later moves behind CGNAT. 📌 **None of those fired.** The VPS arrived for a **fourth** reason this list never anticipated — playit.gg's port limits do not fit 11 worlds with voice chat — and it is worth saying so plainly rather than back-dating a condition that was never met.

### Port-forward chain

Comcast → house router `10.0.0.1` → **forward 443** → FortiGate WAN → **VIP 443** → labserver `192.168.50.10:443` → Caddy.

⚠️ **The FortiGate WAN address must be static** (or reserved) — a drifting lease silently breaks the public door months later. Set it statically on the FortiGate: nothing depends on Comcast's UI that way.

> 📌 **Correction (2026-08-13):** this doc and [FamilyNetwork](../CLAUDE.md) both claimed **Comcast/Xfinity cannot do DHCP reservations**. **That is wrong — Jon found a way.** Method not captured yet; write it up when convenient. It doesn't change the plan — a static WAN IP on the FortiGate achieves the same thing without depending on Comcast's app, so prefer that.

**Skip forwarding port 80** — DNS-01 via the Cloudflare API means no HTTP-01 challenge and no port 80 hole, and it works for wildcards.

## Privacy model

Three goals, not two:

- **Anonymity** — hide the home IP where the audience is hostile (games). Accepted as published for family-facing media hostnames.
- **Access control** — was "keep it off the public internet." **No longer available**, because the family is deliberately coming in over the internet. Replaced by **real authentication on every service**, at the application or proxy layer. Private photos and files never sit on a no-auth endpoint — and no network boundary backstops a mistake any more.
- **Blast radius** — 🚨 **top priority.** Assume labserver gets popped; it must not reach anything that matters. ✅ Now enforced by the FortiGate and verified.

### Cost

**Jon pays for everything** (confirmed 2026-08-13), which makes "cheap" a real constraint rather than a preference.

- **$5/mo recurring** — the VPS, and nothing else. ✅ **Confirmed 2026-09-02** off Linode's own order page (Nanode 1 GB, `us-iad`, $0.0075/hr, 1 TB transfer) rather than from memory — the first price figure in this project that was *read*, and the `~$5` estimate turned out to be right. 📌 **Revised 2026-08-27**; this line read **$0/mo** while the game door was playit.gg's free tier, then **~$4–5/mo** as an estimate. See "The game door" for why the free tier stopped fitting.
- **$0/mo for the web and media doors** — Caddy + port-forward + Let's Encrypt, and the Cloudflare Tunnel free tier. Those still need no VPS.
- **$0 one-time** — the FortiGate 40F was already owned. The ~$30 OpenWrt router considered earlier is **cancelled**.
- Plus electricity and a little Claude API.

## Conventions

- ed25519 keys, `~/.ssh/config` host aliases, key auth only.
- Diagnose before changing; read-only first (specs, logs) before any modification.
- Services run in **containers** (isolation + easy teardown). Document every new machine, service, port, or tunnel here.
- **Bind addresses, not firewall rules** — `127.0.0.1:PORT:PORT` for anything Caddy fronts. Never a bare `PORT:PORT`.
- Nothing secret in any repo (public keys fine; passwords/private keys/tunnel tokens never).
- 🏠 **Never write a residential WAN address into this repo — use a placeholder.** Adopted 2026-09-02. The repo is public, so a literal home IP is published to anyone who reads it, and **it belongs to a third party who did not choose that.** Placeholders in use:

  | Placeholder | Means |
  |---|---|
  | `<DANNY-WAN>` | Danny's current Verizon Fios WAN |
  | `<DANNY-WAN-COMCAST>` | his previous Comcast WAN (historical references) |
  | `<DANNY-WAN-V6>` | the public IPv6 labserver held before the FortiGate |
  | `<JON-WAN>` | Romulus's house WAN |

  **This costs nothing operationally** — every one of these is re-derivable in seconds from a machine that has access (`curl -4 ifconfig.me`, `wg show`, a `ttl=2` traceroute hop), so the digits were never load-bearing. What the docs actually need is *which* address is meant, and the placeholder says that better than a number that drifts anyway.

  ⚠️ **Addresses that are fine to write literally:** the VPS (`172.233.207.73` — published in DNS by design), tailnet addresses (`100.64.0.0/10`, unroutable from outside), and every RFC1918 LAN address. The rule is about **residential** WANs specifically.

  📌 **Going forward only — history was deliberately not rewritten.** The old values sit in commits up to `8af266c` and in any clone or fork made before then. Scrubbing forward is cheap; rewriting public history is messy and would not recall what is already distributed. **Do not read the absence of literals as the absence of exposure.**

## Container runtime — Docker, not Kubernetes (decided 2026-08-13)

**Docker Engine + Compose v2. No Kubernetes, no k3s.** Written down because it will get asked again.

Kubernetes is a *cluster* orchestrator — scheduling across nodes, failover, drain-and-migrate. All of it needs **more than one node**. labserver is one node, so every one of those features is inert while the overhead is fully present:

- **Cost with no return.** Even k3s runs a control plane (API server, scheduler, controller-manager, etcd/sqlite) burning RAM and writing constantly, on a box that also transcodes video and holds an 8B model in VRAM.
- **It fights the security model.** "Bind to loopback" is one string in compose: `127.0.0.1:8096:8096`. In k8s the same intent needs a Service + Ingress + NetworkPolicy, with more ways to leak.
- **It fights the hardware.** GPU is `--gpus all` vs. the NVIDIA device plugin and a RuntimeClass. Storage is a bind mount vs. PV/PVC/StorageClass for what is literally a folder.
- **Danny has to be able to fix it.** `docker compose up -d` is legible; a broken kubelet is not.
- **The work is already done in compose.** Every stack in `/srv/datakiin/stacks/` is an authored `compose.yml`.

**When to revisit:** a genuine second node appears (the mini is scrapped, so this is remote), or Jon wants k8s **as a skill** — a learning goal, not an infra goal, and not on the box holding the family's photos. Then: k3s, not kubeadm.

✅ **INSTALLED 2026-08-13.** `docker-ce` **29.7.2**, `containerd.io` 2.3.3, **Compose v5.4.0**, buildx 0.36.1 — from Docker's official trixie repo (which does publish for trixie; the script's bookworm fallback was not needed). `hello-world` pulled and ran. `docker.service` active and enabled.

- **`daemon.json` confirmed applied:** the `edge` network came up on **`172.20.0.1/24`**, straight out of the pinned `172.20.0.0/14` pool. (`docker0` remains `172.17.0.1/16` — the built-in default bridge is governed by `bip`, not `default-address-pools`, and 172.17 collides with nothing here.)
- **`edge` network created** (`4b5981485049`) — external, so tearing down a stack cannot take the tunnel's network with it.
- **`jony` deliberately NOT added to the `docker` group** — `sudo docker …` for now.
- ⚠️ **Docker flipped `ip_forward` 0 → 1.** Expected and required; see the correction under Karla's requirement. Isolation re-verified intact afterwards.

- [`setup-labserver-docker.sh`](setup-labserver-docker.sh) — the same steps as a repeatable script (run by hand this time, since Jon was already in an SSH session). Idempotent. Installs `docker-ce` + `docker-compose-plugin` from Docker's official apt repo (Debian's `docker.io`/`docker-compose` v1 are too old; the script *refuses to run* if they're present rather than fighting a mixed install). Caps json-file logs at 10m×3, pins bridge pools to `172.20.0.0/14` so they cannot collide with `192.168.50.0/24`, `10.0.0.0/24` or the `100.64.0.0/10` tailnet, sets `live-restore`, and creates the external `edge` network. Touches **no ufw rule** and **publishes no port**.
- **`data-root` stays on the NVMe** (`/var/lib/docker`, 833 G free on `/`). Images and layers want fast storage; `/srv/datakiin` is the 5.3-year-old enterprise pull that is "never the sole copy." Bulk data is **bind-mounted** from `/srv/datakiin/data/`.
- ⚠️ **`docker` group = passwordless root.** Anyone in it can `docker run -v /:/host` and own the machine, quietly cancelling the password-required sudo Danny configured. The script does **not** add `jony` by default (`sudo docker …`); `--docker-group` opts in. **Danny's call.**

## labserver — specs

- **Machine:** ASUS PRIME Z490-A, bare metal. **i7-10700** (8C/16T, 4.8 GHz), **62 GiB RAM**, 49 GiB swap. Debian 13 / kernel 6.12.
- **GPU:** **NVIDIA RTX 3060 12 GB (GA106, Ampere)** — installed 2026-08-11. ✅ Proprietary driver 550.163.01 + CUDA 12.4 (nouveau blacklisted and baked into initramfs, DKMS `nvidia-current`, `nvidia-smi` shows 12288 MiB). Tensor cores + 12 GB → 13B-class quantized models fully on-GPU. Install path: enable `non-free` apt component (was missing) → `apt install linux-headers-amd64 nvidia-driver` → reboot. Secure Boot off, no MOK signing needed.
- **Storage (~5.6 TB free) — ✅ re-measured 2026-09-02:**
  - `nvme0n1p2` SK hynix PC611 1 TB → `/` (889 G, **827 G free**) + EFI + 49 G swap
  - **`nvme2n1p1`** Kingston 1 TB → `/mnt/media` (916 G, 55 G used — **815 G free**, Jellyfin lib)
  - **`nvme1n1p2`** Crucial P3 500 GB → `/mnt/backup` (458 G, **435 G free**, ~empty)
  - ⚠️ **The `nvme1n1` / `nvme2n1` names SWAPPED between 2026-08-11 and 2026-09-02.** The 1 TB Kingston is now `nvme2n1` and the 500 GB Crucial is now `nvme1n1` — the reverse of what this document recorded. **Nothing moved physically; NVMe enumeration order is not stable across reboots.** The mount points are correct because `/etc/fstab` keys on UUID. Same lesson as `HostName` names in `~/.ssh/config` and the interface-name rule for Samba: **never key anything on `/dev/nvmeXn1`** — a script that did would now be writing to the wrong disk.
  - `sda` Seagate ST2000LM007 2 TB HDD → ext4 label `archive` at `/srv/archive` (was `/mnt/storage2`; changed by someone other than us — open item (d))
  - `sdb1` Seagate ST4000NM0085 4 TB → `/srv/datakiin` (see Jon's environment)
- **Network — ✅ re-measured 2026-09-01, post-Fios.** LAN address, gateway and tailnet address all **unchanged** by the ISP swap. New public WAN **`<DANNY-WAN>`** (Verizon; the Comcast `<DANNY-WAN-COMCAST>` is gone), new house gateway **`192.168.1.1`**. **`enp2s0f0` negotiates 1000 Mb/s — the GbE cap is confirmed, not assumed**, so labserver's segment can never see the 5 Gig no matter what the ONT delivers.
- **Network (as of 2026-08-13, post-FortiGate):**
  - `enp2s0f0` UP at **`192.168.50.10/24`**, gw **`192.168.50.1`** (FortiGate). Public IPv6 **no longer present** — link-local only.
  - `tailscale0` **`100.86.218.41/32`** — **the stable address. Always use this.** The LAN address has now moved twice (`.40` → `.41` → `192.168.50.10`); never hard-code it.
  - 📌 **Correction:** an annotation in the previous draft asked whether `192.168.50.x` was "the tailscale IP" and answered yes. **It is not.** Tailscale uses `100.64.0.0/10`; `192.168.50.0/24` is the **FortiGate's LAN subnet**. The stray `192.168.50.0:68` dhcpcd socket seen on 2026-08-10 was foreshadowing this subnet before it existed.
  - Second NIC `enp2s0f1` + `enp6s0` present but DOWN.
- **Already running — ✅ verified active 2026-09-02:** `jellyfin.service` (8096), Samba (`smbd`/`nmbd`/`winbind`, 445/139/137/138), `smartmontools`, `unattended-upgrades`, sshd, tailscaled, Docker, **`wg-quick@wg0`** (the VPS tunnel), cloudflared + the `web` static site, and **`caddy` on `192.168.50.10:443` + `10.10.0.2:443`**. Plus Danny's Apache (`*:80`, `127.0.0.1:8090`). Kernel `6.12.107+deb13-amd64`.
- **NOT installed:** Podman, Java, `nvidia-container-toolkit`. *(Docker, cloudflared and Caddy were all on this list until 2026-08-13/14 — they are installed now.)*
- ⚠️ **Changes made by Danny, found 2026-09-01 (not ours, not requested):** **Apache 2.4.68** installed and listening on **`*:80`** (Debian default page; wildcard bind, so it answers from every tailnet node — ufw does not gate `tailscale0`) plus `127.0.0.1:8090` serving a directory index; **`tailscale serve`** publishing that index at `https://labserver.tail663992.ts.net` (✅ **Funnel is OFF** — tailnet-only, not public); and the host `/etc/resolv.conf` now points at **Tailscale MagicDNS** (`100.100.100.100`, `search tail663992.ts.net`). None of it breaks anything — container DNS still works, since cloudflared resolves fine through the same inherited config. Recorded so the next reader is not confused by sockets this document never mentioned.
- **Listening sockets — ✅ RE-READ 2026-09-02** (`ss -tln`, the only authority — see the lesson about trusting docs). This is the complete current list, not a selection:

  | Socket | Service | Reachable from tailnet? |
  |---|---|---|
  | `192.168.50.10:443` **tcp only** | **Caddy** (container) — house door | ❌ no — LAN-bound by design |
  | **`10.10.0.2:443`** tcp | **Caddy — the public door**, via the WireGuard tunnel from the VPS | ❌ no — tunnel-bound |
  | `100.86.218.41:443` + `[fd7a:115c:a1e0::4b01:dabb]:443` | **`tailscale serve`** (Danny's Apache index) — *not* Caddy | ✅ yes, tailnet only (Funnel off) |
  | `*:80` | **Apache** (Danny's, Debian default page) | ⚠️ yes — wildcard bind |
  | `127.0.0.1:8090` | Apache directory index (Danny's) | ❌ no |
  | `127.0.0.1:11434` | Ollama | ❌ no — fixed 2026-08-13 |
  | `0.0.0.0:22` | sshd | ✅ yes (intended — the admin plane) |
  | `0.0.0.0:8096` | Jellyfin (native) | ⚠️ **yes** — pre-existing wildcard bind, see below |
  | `0.0.0.0:445` / `:139` | Samba | ⚠️ yes — Danny's service, propose don't edit |

  ⚠️ **No UDP 443 any more.** The 2026-08-14 table listed `192.168.50.10:443` as *tcp+udp*; HTTP/3 was turned off during the VPS cutover (`protocols h1 h2`) because nginx's stream module cannot relay QUIC and `443/udp` is closed at the Linode Cloud Firewall. The UDP publish was removed from `compose.yml` to match, rather than leaving a socket advertising an endpoint the public path cannot reach.

  📌 **Four sockets on 443, only two of them Caddy's.** The two tailnet ones belong to `tailscale serve`. Anyone reading `ss` output here and assuming Caddy bound wildcard would be wrong — check the address, not just the port.
- **ufw allow-list — ✅ RE-SCOPED 2026-08-13.** `Default: deny (incoming), allow (outgoing)`, `IPV6=yes`. Six rules, unchanged in ports, now all sourced from the post-FortiGate subnet:

  | Port | Proto | From |
  |---|---|---|
  | 22 | tcp | `192.168.50.0/24` |
  | 8096 | tcp | `192.168.50.0/24` |
  | 445 | tcp | `192.168.50.0/24` |
  | 139 | tcp | `192.168.50.0/24` |
  | 137 | udp | `192.168.50.0/24` |
  | 138 | udp | `192.168.50.0/24` |

  They previously all read `10.0.0.0/24` — a network this box left when the FortiGate went in, so the allow-list had been matching nothing. Each new rule was added *before* the old one was deleted, so no window was left uncovered. **This preserved intent; it did not restore Danny's access** — his machines are on the far side of the gate where ufw has no say (see the Samba decision).
  - ⚠️ **ufw does NOT gate tailnet traffic.** Tailscale installs its own netfilter accept rules for `tailscale0`, which is why SSH to `100.86.218.41` works with no matching ufw rule. Anything bound to `0.0.0.0` is reachable by **every node on the tailnet**; the real gate there is tailnet ACL/sharing, not ufw.
  - 📋 **This is systemic, not an Ollama quirk — measured 2026-08-13.** From Romulus, `100.86.218.41` answers on **445, 139 and 8096** as well. All three bind `0.0.0.0`, so the re-scoped ufw rules do not touch them. **Severity is much lower than Ollama was** — Samba and Jellyfin both require authentication, where Ollama required none — and the tailnet is only three nodes (labserver, Danny's iPhone, Romulus). But the pattern will repeat for every future service that binds wildcard. **Fixes, when convenient rather than urgent:**
    - **Jellyfin** → ~~`127.0.0.1` once Caddy fronts it (happening anyway)~~ ⚠️ **REVISED 2026-08-14 — Caddy now fronts it, and `127.0.0.1` would BREAK it.** Caddy is in a container and reaches Jellyfin over the `edge` bridge gateway `172.20.0.1`, so a loopback-only Jellyfin becomes unreachable to its own reverse proxy. Re-confirmed still `0.0.0.0:8096` and still answering from Romulus on the tailnet. The correct fix is to bind Jellyfin to **loopback + the bridge** (`127.0.0.1` and `172.20.0.1`), or set `bind-address` to the LAN IP and let Caddy use that — **not** plain loopback. Verify with `ss -tlnp | grep 8096` and a probe from Romulus (expect refused) *and* a `curl` through Caddy (expect still 200). Low urgency: Jellyfin requires auth and the tailnet is three nodes.
    - **Samba** → in the `[global]` section of `smb.conf`:
      ```ini
      interfaces = lo enp2s0f0
      bind interfaces only = yes
      ```
      ⚠️ **Both lines are required.** `interfaces` alone does *not* restrict the listening sockets — on its own it only governs which interfaces Samba advertises and browses on. `bind interfaces only = yes` is what actually makes `smbd`/`nmbd` bind to just that list. Setting the first without the second is a classic mistake that looks applied and changes nothing.
      ⚠️ **Name the interface, not the IP.** `enp2s0f0` survives address drift; this box has moved three times in four days (`10.0.0.40` → `.41` → `192.168.50.10`), and a hardcoded IP would silently stop matching.
      ⚠️ **Keep `lo` in the list.** With `bind interfaces only = yes`, dropping loopback breaks local tools that connect to `127.0.0.1` — `smbpasswd` in particular.
      Verify with `ss -tlnp | grep 445` (expect `192.168.50.10:445`, not `0.0.0.0:445`) and a probe from Romulus to `100.86.218.41:445` (expect refused). Needs `systemctl restart smbd nmbd`, which drops open sessions — do it when nobody is using the shares.
    - ⚠️ **Samba is Danny's service — propose, do not edit unilaterally.**
  - ✅ **Ollama exposure — FOUND AND FIXED 2026-08-13.** *Found:* `/etc/systemd/system/ollama.service.d/override.conf` set `Environment="OLLAMA_HOST=0.0.0.0:11434"`, `ss` showed a wildcard `*:11434`, and from Romulus `http://100.86.218.41:11434/api/tags` returned the model list with **no authentication** — unauthenticated use of an API that can pull and **delete** models, exposed to every node on the tailnet. ufw was not what failed: 11434 was never in its allow-list and the public-IPv6 probe was correctly blocked. The hole was the tailnet gap above. *Fixed:* override rewritten to `127.0.0.1:11434` (original backed up), `daemon-reload` + restart. **Verified three ways** — `ss` shows `LISTEN 127.0.0.1:11434`; a TCP probe to the tailnet address from the box is refused; and **independently from Romulus, port 11434 is REFUSED and the API is unreachable, while port 22 still answers** (so the admin plane is intact and the test wasn't a general connectivity failure). `odin` unaffected — it is a loopback client.
- **sudo:** `jony` is in `sudo` but **password-required**. Claude cannot run root commands non-interactively; Jon runs sudo steps at his own prompt.

### Streaming capacity — measure it, don't guess

- [`diag-labserver-streaming.sh`](diag-labserver-streaming.sh) — read-only, no root, no installs. Answers *"how many people can watch Jellyfin at once?"* by measuring the only two numbers that decide it: **home upload bandwidth** (Cloudflare's public endpoint via `curl`, adaptively sized to ~10 s of transfer) and **GPU encode** (is hwaccel actually engaged, and how many concurrent NVENC sessions does driver 550 permit). Ends in a bitrate→viewers table. Run as `ssh jony@100.86.218.41 'bash -s' < diag-labserver-streaming.sh`; add `--sessions` to probe the NVENC cap, `--no-speed` to skip the bandwidth test.
  - **Not purely read-only, stated honestly:** writes a temp payload under `/tmp` (removed on exit) and uploads random bytes to Cloudflare. `--sessions` loads the GPU for a few seconds — don't run it mid-movie.
- 📌 **Containerising Jellyfin does not raise the user ceiling.** Same process, same NVENC chip, same uplink; Docker buys isolation and teardown (see Conventions), not concurrency. Real horizontal scale needs a second node, and the mini is scrapped.
> 🔄 **SUPERSEDED 2026-08-29 — the 41 Mbps below was Comcast's. Danny moved to Verizon Fios 5 Gig (symmetric, $104.99/mo).** The measurement *method* and the NVENC findings stand; the bandwidth number and every conclusion hanging off it are void. **The binding constraint has moved twice over:**
>
> | Constraint | Old (Comcast) | New (Fios 5 Gig) |
> |---|---|---|
> | Upload | **41 Mbps — bound first** | ~5000 Mbps at the ONT |
> | Path to labserver | n/a | 🚧 **~1 Gbps — the FortiGate 40F's five ports are all *GbE*.** Every packet to labserver crosses it, so that segment can never see 5 Gig |
> | NVENC sessions | 8, never reached | ✅ **8 — this now binds, by roughly 15×** |
>
> **What this changes, concretely:**
> - ✅ **Egress traffic-shaping is no longer required.** It was "required before the family gets the URL" solely because 4× 1080p ate 32 of 41 Mbps and would have degraded Karla's work calls. Eight simultaneous transcodes now total ~64 Mbps of ~1000. **The household-disruption argument is gone** — drop the item.
> - ✅ **"4K remote is off the table" is void.** One 4K direct play (~40 Mbps) exceeded the *entire* old uplink; it is now ~4% of the path — and direct play consumes **no NVENC session at all**.
> - 🔄 **The tuning lever inverts.** Capping remote users at 4 Mbps/720p was the single biggest win while bandwidth bound. Now that **NVENC** binds, the win is **avoiding transcodes entirely**: a client that direct-plays costs zero sessions, so bitrates should stay *high enough that clients don't request a transcode*. The old advice is now actively counterproductive — do not carry it forward.
> - ⚠️ **Jellyfin's Known-proxies item still stands.** It was never a bandwidth issue — it governs whether Jellyfin sees real client IPs at all, which affects logging and any per-user policy. Unchanged.
> - 🚨 **Do NOT bypass the FortiGate to chase the 5 Gig.** That gate is Karla's isolation. 1 Gbps is 24× the old uplink and ~15× what the GPU can produce; there is nothing to gain and everything to lose. If >1 Gbps to the server segment is ever genuinely needed, that is a *firewall upgrade* (a 2.5G-capable model), never a removal.
>
> ⚠️ **Still to measure, do not assume:** labserver's own link speed (`ethtool enp2s0f0 | grep Speed` — the Z490-A's onboard NIC is gigabit and it is unconfirmed which interface is actually in use), and real end-to-end throughput. Re-run [`diag-labserver-streaming.sh`](diag-labserver-streaming.sh) rather than trusting the arithmetic above.

### ✅ MEASURED 2026-08-14 — upload is the ceiling, and it is 41 Mbps

Run while Danny was away, which is the only time `--sessions` (GPU load) and the bandwidth test are polite to run at all.

| Quantity | Measured |
|---|---|
| **Upload bandwidth** | **41.0 Mbps** (best of 2, Cloudflare `speed.cloudflare.com/__up`) |
| Budget for streaming | **32.8 Mbps** (20% headroom) |
| **NVENC concurrent cap** | **8 sessions** — 9th refused. Real number for this driver, not the folklore 5. |
| GPU | RTX 3060, 12 GB, **2 MiB used, 0%** — completely idle |
| jellyfin-ffmpeg | 7.1.4, hwaccels `cuda vaapi qsv drm opencl vulkan` |
| NVENC codecs **actually usable** | ✅ `h264_nvenc`, ✅ `hevc_nvenc` — ❌ **`av1_nvenc` fails: "No capable devices found"** |

⚠️ **The ffmpeg binary listing an encoder does not mean the GPU can run it.** `av1_nvenc` appears in `-encoders` and dies at runtime: **Ampere (GA106) does AV1 *decode* only; AV1 *encode* starts at Ada / RTX 40.** Test the encoder, don't read the list — one `-f lavfi -i testsrc ... -c:v <enc> -f null -` settles it in a second. **HEVC is therefore the codec lever here, not AV1.**

**Concurrent remote viewers at 32.8 Mbps:**

| Scenario | Per stream | Viewers |
|---|---|---|
| 720p transcode | 4 Mbps | **8** |
| 1080p transcode | 8 Mbps | **4** |
| 1080p direct play | 10 Mbps | **3** |
| 1080p remux direct play | 20 Mbps | 1 |
| 4K direct play | 40 Mbps | **0** — does not fit, at all |

🚨 **A saturated uplink degrades the whole household, and the "20% headroom" above does NOT prevent that.** The headroom is margin so the streams themselves don't stutter — it reserves nothing. 4× 1080p consumes 32 of 41 Mbps, and at that utilisation TCP ACKs queue (slowing *downloads* too) and bufferbloat pushes latency from ~10 ms into the hundreds. **Video calls are the worst-affected application, which means Karla's work calls are the exposed thing** — the one household member this project is under obligation to not disrupt. Jellyfin and a Zoom call compete as equals; nothing arbitrates.
**Fix: traffic-shape labserver's egress on the FortiGate** (cap ~25 Mbps, leaving ~16 for the house). Off-host, on hardware already owned, and it makes the optional service yield to the residents. **Treat as required before the family gets the URL.** A symmetric fibre line would dissolve the problem instead — the stronger argument for Fios than the 10-user target.

🚩 **LAN viewers do NOT consume any of this.** House traffic goes house → FortiGate → labserver over gigabit Ethernet and never touches the uplink: zero impact on the household's internet, and **4K direct play is comfortable locally while being flatly impossible remotely** (40 Mbps > the whole uplink). The only resource LAN and remote viewers share is the 8-session NVENC pool, and local clients usually direct-play, which uses none. Tell house users the **LAN address** — using the public hostname from inside makes traffic attempt a hairpin most consumer routers refuse.

🔴 **The bitrate cap silently does nothing unless Jellyfin trusts the proxy.** Jellyfin classifies local-vs-remote by client IP, and every internet viewer now arrives via Caddy at **`172.20.0.4`** — an address inside labserver's own network. Without the proxy registered under *Dashboard → Networking → Known proxies*, Jellyfin files every remote viewer as **local** and applies **no limit**, defeating the one control protecting the uplink (and therefore Karla's calls). Caddy sends `X-Forwarded-For` by default; Jellyfin must be told to honour it. **Unverified — `network.xml` is root-owned.** Confirm empirically once public: stream from outside and check the dashboard shows a real client IP, not `172.20.0.4`. Generalises: **any auth, rate-limit, or geo rule keyed on client IP is wrong until the proxy is trusted.**

📌 **The uplink binds long before the hardware does.** A 12 GB RTX 3060 that can encode 8 streams sits behind a pipe that carries 4 of them at 1080p. Every hardware upgrade path is pointless here; **the only levers that move the number are bitrate caps and codec choice.** Capping remote users at 4 Mbps/720p roughly doubles the audience and is worth doing before anyone gets the URL.

⚠️ **4K remote is off the table** — one 4K direct-play stream exceeds the entire household uplink. Not a tuning problem; a physics problem.

❓ **Still unknown: whether Jellyfin is actually *configured* to use NVENC.** `/etc/jellyfin/encoding.xml` is `root:jellyfin` and unreadable as `jony`, and nothing was transcoding during the run, so there was no live process to read the encoder off. The *capability* is proven (the binary has the encoders; the GPU accepted 8 sessions) — the *setting* is not. **Check Jellyfin Dashboard → Playback → Transcoding → Hardware acceleration = NVENC.** If it is off, every transcode lands on the i7 and the practical ceiling drops to ~3 regardless of the table above. Danny's service — propose, don't edit.

- **The ceilings, in order of which one binds:** **upload bandwidth (41 Mbps — MEASURED, and it binds first)** → CPU (~3× 1080p if hwaccel is off) → NVENC session cap (8, measured) → RAM/disk (never). 62 GB and NVMe are irrelevant here.
- ⚠️ **`nvidia-container-toolkit` is NOT installed.** A containerised Jellyfin without it gets no GPU and falls back to CPU **silently** — roughly 8 streams down to 3. This is the one way the migration makes things *worse*; install it first. The script checks for it.
- **The lever that actually helps** is per-user remote bitrate limits in Jellyfin, not infrastructure. Capping remote users at 4 Mbps/720p roughly doubles how many fit in the same uplink.

## Presence + messaging (built 2026-08-13)

**Who else is on the box.** Danny's account is **`deks` (uid 1000)**; `jose` (1002) has never logged in. Danny works **two ways**: SSH from his LAN boxes and **physically at the console on seat0/tty1**. He does not camp sessions — 21 logins / 13 h over 30 days, mostly minutes, cleanly closed. Jon leaves sessions open for 7–11 h, so "logged in" is a good activity proxy for Danny and a poor one for Jon.

- [`diag-labserver-logins.sh`](diag-labserver-logins.sh) — read-only, no root, no installs. Live sessions (console vs ssh, idle), a plain-English verdict, per-user activity, login history. Run as `ssh jony@100.86.218.41 'bash -s' < diag-labserver-logins.sh [days]`.
- [`watch-labserver-logins.ps1`](watch-labserver-logins.ps1) — runs **on Romulus**, hourly task `DG3030 - labserver login watch`. Polls sessions + new `hey` messages, appends `logs/labserver-logins.csv` and `logs/labserver-chat.log`, writes `ALERT-labserver.txt` to the desktop when Danny appears or messages. `-Install` / `-Uninstall`.
  - `-Install` writes **`watch-labserver-hidden.vbs`**, a `wscript` shim that launches the watcher with no console flash. **Generated, machine-specific, gitignored** — don't commit or hand-edit; re-run `-Install`.
  - State in `logs/` (gitignored): `labserver-logins.csv`, `labserver-chat.log`, `.labserver-watch-state` (byte offset seen).
- [`setup-labserver-msg.sh`](setup-labserver-msg.sh) — ✅ **INSTALLED + LIVE.** Installs `hey`: a shared on-box conversation in `/srv/msg/chat.log`, group `users`, with `/etc/profile.d` + `PROMPT_COMMAND` hooks so unread messages appear at login *and* before the next prompt of an already-open shell. Local only — no port, no daemon, no ufw change, nothing leaves the box.
  - On-box state: `/usr/local/bin/hey`; spool `/srv/msg` is `root:users 2775` **setgid + sticky**; `chat.log` `rw-rw-r-- root:users`; per-user markers `/srv/msg/.read.<user>` hold a **byte offset**; hook at `/etc/profile.d/zz-hey.sh`.
  - ✅ **BOTH HALVES PROVEN 2026-08-13.** Write path verified earlier (post → log → Romulus watcher mirror). **Read path verified 14:26** — after the 14:13 reboot, `/srv/msg/.read.deks` advanced **twice on its own** (14:23 at offset 194, then 14:26:25 picking up a message posted at 14:26) with no action from us. A marker only advances when `hey` actually executes in that user's shell, so delivery to a **second user** is confirmed, and confirmed surviving a reboot with spool state intact.
  - ✅ **CLOSED 2026-09-01 — `deks` has used it.** Two messages from him in `/srv/msg/chat.log` dated **2026-08-19 09:42**, unprompted and conversational ("also i just wanted to use hey right quick lol"). Both halves of the tool are now proven in the field, and the diagnosis below was right: it was the timing, and a fresh login shell fixed it. Superseded note follows.
  - ⚠️ ~~**`deks` has still never posted a message**~~, and reported that "hey didn't work." Two likely causes, both benign:
    1. **Timing.** The hook was written 09:52 and the binary 10:01, but Danny's console session started **08:37** — `/etc/profile.d` only runs for *new* login shells, so that session never had the hook. His post-reboot session does. **Likely already fixed; just ask him to retry.**
    2. **Shell quoting.** See the lesson below — an apostrophe is the probable culprit.
  - 📉 **DEPRIORITISED — Jon and Danny talk on the phone.** Every real request (including "shut the server down") arrived verbally. Leave `hey` installed; don't invest further. The genuinely useful half was the **presence check**, not the messaging.

## Jon's environment — `/srv/datakiin` (built 2026-08-11)

Dedicated **4 TB drive** (`/dev/sdb1`, label **DATAKIIN**, ext4, mounted **by UUID**, owned by `jony`). Built by [`scaffold-datakiin-env.sh`](scaffold-datakiin-env.sh) — idempotent, re-runnable, version-controlled.

- **Drive provenance:** used Seagate ST4000NM0085 enterprise pull (SN ZC1DHDEG). SMART at setup: **0 reallocated / 0 pending / 0 uncorrectable / 0 CRC** but **46,812 power-on hours (~5.3 yrs)**, G-Sense 34,401. Fine for working data, **never the sole copy**. Stale `ufs` signature wiped with `wipefs` before mkfs. 4Kn sectors.
- ✅ **Long self-test PASSED 2026-08-11** — `Extended offline / Completed without error`, full 4 TB surface read, zero read errors. Health quartet (5/197/198/199) all zero as of 2026-08-12. Thermal curve in smartd's attrlog corroborates the full ~8 h window. **Caveat stands:** media proven good, but 5.3 years of power-on hours is the risk — never the sole copy.
- **Layout:** `stacks/` (compose per service, **authored not deployed**), `projects/` (linenlady, minecraftserver), `data/` (bind-mount volumes), `backups/`, `docs/`, `bin/health.sh`, `secrets/` (0700, gitignored).
- **Stacks staged:** cloudflared, ollama (+open-webui), jellyfin, immich, nextcloud — all loopback-bound by default; nothing started.
- 🆕 **[`nextcloud/`](nextcloud/) — authored 2026-09-01, NOT deployed.** The real movie/home-video ingest stack, replacing the scaffold placeholder (which was MariaDB, no Redis, no media path, no proxy config). Postgres 16 + Redis + `nextcloud:30-apache`. **Publishes no host port** — Caddy reaches it by container name over `edge`. Redis is not optional here: without it Nextcloud falls back to database file locking, which throws spurious "file is locked" errors under exactly the big concurrent uploads this exists for. Bind-mounts `/srv/datakiin/data/media` so uploads land as **real files with real names** via External Storage; Nextcloud's internal object store would be invisible to Jellyfin.
  - **Two Jellyfin libraries, because the library TYPE decides behaviour:** `media/movies` → type **Movies** (scrapes TMDB, needs `Title (Year)/Title (Year).mkv`, `[imdbid-tt...]` to pin a wrong match) and `media/home-videos` → type **Home Videos & Photos** (no scraping). Family footage in a Movies library fails to match and displays as a mess; a real film in a Home Videos library gets no metadata at all. ⚠️ **Uploads do not arrive correctly named — renaming is the real ongoing chore**, not the transfer.
  - Added to Danny's **existing** Jellyfin as new libraries. `/mnt/media` is owned by `deks` and `jony` **cannot write there**; these live on Jon's own drive instead, which is the writable half of the arrangement.
- 🗑️ **`files/` (Syncthing + FileBrowser) — DELETED 2026-09-01.** Authored and removed the same day: Syncthing mirrors rather than uploads, so it was the wrong shape once the requirement turned out to be many-to-one ingest. FileBrowser went with it because Nextcloud's own web UI already does the renaming it would have been kept for. See the tool-fit lesson.
- 🔐 **Wildcard cert decision (2026-09-01).** The repo Caddyfile now issues one **`*.datakiin.com`** instead of one cert per hostname, because **every certificate a public CA issues is published to Certificate Transparency logs** — so issuing for `cloud.datakiin.com` announces that hostname worldwide within seconds, with no DNS record and no reachability needed. A wildcard shows only `*.datakiin.com`. Only possible because issuance is DNS-01; HTTP-01 cannot do wildcards. ⚠️ **Add new services as a matcher + `handle` block inside that site**, never as a new top-level block, or Caddy issues a separate cert and publishes the name anyway.
- ## 🎉 **[`web/`](web/) — PUBLIC PATH PROVEN, LIVE 2026-08-13 at `lab.datakiin.com`**

  The first thing on labserver reachable from the open internet, and deliberately a page nobody cares about rather than a real service. A boring `nginx:alpine` static site at `/srv/datakiin/stacks/web/`, **publishing no host ports** — it joins the external `edge` network that cloudflared also joins, so the *only* route in is the tunnel. *(The `nginx:alpine` here is a static file server inside a container, not the reverse proxy — it does not conflict with the Caddy decision.)*

  **Verified from Romulus:**

  | Check | Result |
  |---|---|
  | `https://lab.datakiin.com` | **200**, 3997 bytes, title `datakiin — lab` |
  | Served by | `Server: cloudflare`, `CF-RAY … -IAD` (Ashburn edge) |
  | `Server-Timing` | `cfEdge;dur=13, cfOrigin;dur=28` — tunnel live, 28 ms to origin |
  | DNS `A` / `AAAA` | Cloudflare anycast only (`172.67.171.159`, `104.21.71.201`, `2606:4700:…`) |
  | **Origin IP `<DANNY-WAN-COMCAST>`** | ✅ **absent from every DNS record and every response header** |
  | Inbound ports opened | **none** — no port-forward, no FortiGate VIP, nothing on ufw |

  **The full path:** internet → Cloudflare edge → tunnel (outbound-initiated from labserver) → `edge` bridge → nginx. Nothing listens on labserver's LAN or tailnet for this, and the FortiGate needed no hole. This is the pattern every HTTP service should copy.

  ⚠️ **One setting still to flip:** plain `http://lab.datakiin.com` returns 200 rather than redirecting — turn on **Always Use HTTPS** in the Cloudflare dashboard (SSL/TLS → Edge Certificates). Harmless for a static page with no auth; **not** harmless once Immich/Nextcloud sit behind this.

  📌 **Fixed during deploy:** `stacks/cloudflared/compose.yml` declared the `edge` network without `external: true`, unlike the web stack — compose would have tried to manage a network created outside it. Corrected on the box *and* in [`scaffold-datakiin-env.sh`](scaffold-datakiin-env.sh) so it does not regenerate.
- **Ollama:** installed **natively** (v0.32.9), `llama3.1:8b`, verified **100% GPU**, 5.1 GB VRAM, ~75 tok/s. The container stack is an alternative — don't run both on 11434.
- **`odin` (system-wide):** `/usr/local/bin/odin` is a two-line wrapper — `exec ollama run llama3.1:8b "$@"`. Any local user types `odin` for a chat or `odin "question"` for one-shot. Installed by [`setup-labserver-ollama-cmd.sh`](setup-labserver-ollama-cmd.sh). **The wrapper is local-only by construction**; the *service* it talks to is the `0.0.0.0` problem, not `odin`.
- ⚠️ **Port 8096 conflict:** the containerized Jellyfin stack collides with Danny's native Jellyfin. Decide adopt-vs-migrate before deploying.

## Reference — how the *existing* Datakiin setup exposes things (verified 2026-08-10)

- Cloudflare tunnel **"Datakiin"** (id `b211b53a…`, origin Romulus `<JON-WAN>`) carries **web only**: `datakiin.com`, `play.datakiin.com`.
- Minecraft `survival.datakiin.com` is **NOT tunneled** — CNAME → `home.datakiin.com` → Comcast IP (Cloudflare-DDNS script), SRV `_minecraft._tcp` → port 25569, router port-forward. Live: v26.1.2 "Ridgehollow Survival".
- The game door was already a direct port-forward + SRV, exactly because Cloudflare can't carry game packets. For the public build, swap that direct exposure for **the VPS relay** so the home IP isn't published to players. **This whole setup migrates off Romulus onto labserver** — see Scope.

## Status / next steps

> ✅ **RESOLVED 2026-09-01 — labserver is back and the Fios swap is fully measured.** The 🔴 ACTIVE block that stood here (2026-08-29) is answered. Danny powered the box back on; it booted **2026-09-01 08:29** and needed no reconfiguration at all.
>
> | Value | Before (Comcast) | Now (Fios), measured 2026-09-01 |
> |---|---|---|
> | Public WAN | `<DANNY-WAN-COMCAST>` | **`<DANNY-WAN>`** (Verizon) |
> | House gateway | `10.0.0.1` | **`192.168.1.1`** — read off the `ttl=2` hop, not guessed |
> | labserver LAN | `192.168.50.10` | ✅ **unchanged** — the FortiGate survived the swap |
> | Default route | `192.168.50.1` | ✅ **unchanged** |
> | `enp2s0f0` link speed | assumed GbE | ✅ **1000 Mb/s — confirmed.** The predicted cap is real |
> | Karla's isolation | 🚨 unverified | ✅ **VERIFIED** — see the FortiGate section |
> | Tailscale `100.86.218.41` | unchanged | ✅ **unchanged — a fifth topology change survived with zero config edits** |
>
> ⚠️ **One prediction in the old block was wrong, and it is worth keeping.** It said the FortiGate WAN "**will not reach the internet until reconfigured**." It reconfigured itself: the WAN interface evidently held a **DHCP lease**, not the static address the runbook assumed, so it simply took a new one from the Fios router and carried on. The doc had already flagged that nothing here ever *measured* it as DHCP — that caveat was correct and the confident prediction built on top of it was not. **A stated uncertainty does not stop propagating just because a later paragraph sounds sure.**
>
> ➖ Steps 1–4 of the old checklist are done. **Step 5 — redo the port-forward chain — is now MOOT**, designed out entirely by the consolidation below.

> ▶️ **ACTIVE 2026-09-01 — consolidation onto labserver, everything public via a WireGuard VPS**
>
> Jon's goal, stated 2026-09-01: run the Minecraft servers, Jellyfin, websites and a large-file upload point on labserver in Docker, with public traffic reaching it through the rented VPS rather than a hole in Danny's router. 📗 Full phased plan, diagram and verification steps: **[Datakiin Consolidation artifact](https://claude.ai/code/artifact/4d8bebff-510e-4f23-a41d-03848d559d41)**.
>
> **Decisions taken 2026-09-01:**
>
> | Question | Decision | Why |
> |---|---|---|
> | Jellyfin | **stays native, Caddy fronts it** | Danny's service works; containerising needs `nvidia-container-toolkit` first or transcoding silently drops to CPU (8 streams → ~3) |
> | Websites | **stay on the Cloudflare Tunnel** | free, absorbs DDoS, zero VPS bandwidth. The video ToS problem never applied to static content |
> | Large uploads | **Nextcloud** | uploads are multi-GB and batchy; it chunks and resumes. A single-POST uploader loses a 20 GB transfer to one dropped connection |
> | Who uploads | **Danny on Samba; everyone else public with a login** | Danny is on the LAN and already has a writable share. Others get a page with nothing to install |
> | Threat model | **in-transit confidentiality only** | ✅ **Clarified by Jon 2026-09-01: Danny seeing the data is fine; the concern is interception by people outside the family network.** TLS already solves this in full |
>
> **What the VPS design deletes** — all of it blocked on Danny doing console work on a brand-new Fios router, and none of it now needed: the 443 port-forward, the FortiGate VIP and its wan→DMZ policy, pinning the FortiGate WAN static, and the `dg.datakiin.com` DDNS gap. Every path is outbound-initiated, so NAT is never asked for permission. 📕 **`RUNBOOK-port-forward.md` was therefore OBSOLETE, not merely stale** — it targeted the dead Comcast WAN *and* a chain we no longer intend to build. **Deleted 2026-09-02**; recoverable at `HEAD:LabServer/RUNBOOK-port-forward.md`.
>
> **Order of work:**
> 1. ~~Recover Caddy~~ ✅ **DONE 2026-09-01** — see the incident below.
> 2. 🟡 **Deploy Nextcloud + the wildcard Caddyfile together** — authored in [`nextcloud/`](nextcloud/), not deployed. ⚠️ **The repo Caddyfile is deliberately ahead of the box** (repo `a5575a0b…`, box `0e3598de…`): the box still serves the single-site version. Pushing it **issues a fresh `*.datakiin.com` certificate**, so do it on purpose, alongside Nextcloud, not as a side effect.
> 3. 🌐 **Stand up the VPS + WireGuard** — 🟡 **BOX RENTED AND HARDENED 2026-09-02; tunnel half-built.**
>
>    | | |
>    |---|---|
>    | Instance | Linode **Nanode 1 GB**, Debian 13 (trixie), kernel 6.12.88, label `datakiin-relay` |
>    | Region | **`us-iad`** (Washington, DC) |
>    | **Public IPv4** | **`172.233.207.73`** |
>    | Public IPv6 | `2600:3c05::2000:f2ff:fe69:21fe/64` — **it has one**, so firewall sources must cover v6 |
>    | **Price** | ✅ **$5/mo ($0.0075/hr) — read off the order page, not recalled.** 1 vCPU / 1 GB / 25 GB / 1 TB transfer / 1 Gbps out |
>    | Disk encryption | on (free; covers datacenter disk disposal/RMA, nothing else) |
>    | Backups | **off** — $2/mo to protect a stateless box `setup-vps.sh` rebuilds in ten minutes |
>
>    **Cloud Firewall `datakiin-relay-fw`**, attached at create (the newer *Linode Interfaces* model exposes a "Public Interface Firewall" field on the create form, so no unfirewalled window). Default inbound **DROP**, outbound **ACCEPT**; inbound allows only **51820/udp**, **443/tcp**, **22/tcp** from all IPv4+IPv6. ⚠️ **ICMP is therefore dropped — `ping` is not a liveness test for this box.** The `ssh-temp` rule is labelled for deletion once the tunnel is up and admin moves to `10.10.0.1`. Deliberately **no 443/udp** (HTTP/3 not forwarded).
>
>    **SSH hardened and verified both ways.** Linode shipped it `permitrootlogin yes` / `passwordauthentication yes`; a drop-in at `/etc/ssh/sshd_config.d/10-datakiin.conf` sets `PermitRootLogin prohibit-password` + `PasswordAuthentication no` + `KbdInteractiveAuthentication no`, validated with `sshd -t` **before** the restart. Verified: key auth succeeds under `StrictHostKeyChecking=yes`, and password auth returns **`Permission denied (publickey)`** — the same two-sided proof used on Remus and Bubba. Host keys were **pre-staged into `known_hosts` from `ssh-keyscan`**, so the first real connect never prompted; ed25519 fingerprint `SHA256:FZMOiNW2rK+vQZWCcd1ls9ka7Jk0BTF/+QEz0/aRF4w`. ⚠️ **That is trust-on-first-use** — there was no prior record to compare against, unlike the Remus rename. Confirmable against the Lish console if it ever matters. Hostname set to `datakiin-relay` (Linode leaves it `localhost`).
>
>    `~/.ssh/config` on Romulus gained **`vps`** and **`labserver`** aliases — the latter closes the long-standing TODO under Access. Backups at `~/.ssh/config.bak-prevps-20260902` and `~/.ssh/known_hosts.bak-prevps-20260902`.
>
>    **`setup-vps.sh` pass 1 run** — `wireguard-tools` + `nginx-full` (1.26.3) installed, keypair generated. **VPS WireGuard public key: `BLe077m+kenV9WWoFzQsITKR20L5ccRGyc6IIOYqyzE=`.** ✅ nginx's default `:80` vhost was removed straight after (unreachable anyway — 80 is not in the firewall — but a bind address beats relying on a firewall rule). `ss -tlnp` on the box now shows **sshd and nothing else**.
>
>    ✅ **TUNNEL UP 2026-09-02.** All four passes run; labserver's pubkey `TXj5F/zRUranFo6czqbE3RKmfUCw6Qn/hW8n9IIAKy0=`, VPS `10.10.0.1`, labserver `10.10.0.2`, handshake established both directions, **0% loss, RTT 5.98 ms**.
>
>    🔥 **The design's central claim is now measured, not argued.** The VPS config has **no `Endpoint` line** for labserver — it learned the address from the first handshake and `wg show` on the VPS reports `endpoint: <DANNY-WAN>:57521`, Danny's Fios WAN. So the VPS can push traffic down a tunnel it did not open, with **no port-forward on the Fios router and no VIP or policy on the FortiGate.** That is what deletes every task that needed Danny at a console, and it is why the whole port-forward chain is obsolete rather than merely stale. The 5.98 ms also validates the `us-iad` choice empirically — it was picked on the argument that Danny is DC-metro.
>
>    ✅ **Isolation re-tested immediately after, per the standing rule** — labserver → `192.168.1.1`: route exists via `192.168.50.1` (so traffic is *dropped by policy*, not merely unrouted), ICMP **100% loss**, TCP **80/443/53/22/8080 all blocked**, control `1.1.1.1` on 443 and 53 **reachable** so the test is valid. Karla's protection is untouched, as predicted — the tunnel opens nothing inbound at the perimeter.
>
>    📗 **Step-by-step for what remains: [`RUNBOOK-vps-cutover.md`](RUNBOOK-vps-cutover.md)** — pre-flight state check, the two file copies, the recreate, five verification steps, the outside-in proof, DNS, the Jellyfin known-proxies ask for Danny, and a one-command rollback.
>
>    ## 🎉 **PUBLIC PATH LIVE 2026-09-02 — the whole chain works end to end**
>
>    Caddy deployed with the tunnel publish and PROXY protocol; box and repo byte-identical again (Caddyfile `009cb7b0…`, compose.yml `38b56004…`; backups `*.bak-prevps-20260902`).
>
>    | Check | Result |
>    |---|---|
>    | Listeners | **`192.168.50.10:443`** (house) + **`10.10.0.2:443`** (tunnel). **No UDP 443** — h3 off to match the VPS |
>    | Certificate | **`CN=*.datakiin.com`**, `C=US, O=Let's Encrypt, CN=YE1`, `Sep 2 14:08:10` → `Dec 1 2026` |
>    | LAN-direct | **`http=302 verify=0 proto=2`** |
>    | VPS → Caddy | `443 OPEN over tunnel` |
>    | **Outside-in from Romulus** | **`http=302 verify=0`**, issuer Let's Encrypt, wildcard subject — `connect=0.036s total=0.225s` |
>    | HTTP/2 through the tunnel | **`ALPN: server accepted h2`** |
>
>    **The live path: internet → VPS `172.233.207.73:443` → nginx stream → WireGuard → Caddy `10.10.0.2:443` → Jellyfin.** No inbound rule at Danny's perimeter; no port-forward, no VIP, no FortiGate policy.
>
>    ✅ **The `proxy_protocol` LAN risk resolved in the good direction.** The concern was that `listener_wrappers` applies to *both* published addresses while house clients send no PROXY header. Caddy's `allow 10.10.0.1/32` does make the header **optional** for other sources — measured, not assumed: LAN-direct returns 302 over h2. **Had it gone the other way, every house client would have broken**, which is why it was tested before being believed.
>
>    ✅ **PROXY protocol is provably being parsed** — not by reading a log, but because the public path works *at all*. If Caddy were not handling the header it would read `PROXY TCP4 …` as a TLS ClientHello and every connection through the VPS would fail. What remains unproven is that the client IP *propagates to Jellyfin*, which is exactly what the Known-proxies step verifies.
>
>    🟡 **Caddy has no `log` directive**, so it emits errors but **no access log**. A public-facing proxy with no request log is a real gap — worth adding independently of this work.
>
>    ## 🎉 **`https://watch.datakiin.com` IS LIVE — DNS in, browser-verified 2026-09-02**
>
>    | Check | Result |
>    |---|---|
>    | DNS | `watch.datakiin.com` → **`172.233.207.73`** |
>    | **Grey cloud** | ✅ **confirmed by measurement** — the answer is the Linode address, not Cloudflare anycast (`104.21.x` / `172.67.x`). Proxied would have meant family video crossing Cloudflare's CDN, the exact ToS risk this whole door exists to avoid |
>    | End-to-end, real DNS, no `--resolve` | **`http=302 verify=0 remote_ip=172.233.207.73`** |
>    | Browser | Jellyfin login page renders, **no certificate warning** |
>
>    🔤 **The hostname is `watch`, not `jellyfin`.** Chosen so family reading it off a text message need not know what Jellyfin is. **The rename cost nothing** — the wildcard cert already covered it, so there was no reissue, no ACME round-trip and no new Certificate Transparency entry; only the Caddyfile matcher (`@watch host watch.datakiin.com`) and the DNS record changed. ⚠️ **Those two must always agree:** a DNS name with no matching `@` block falls through to `handle { abort }`, so TLS completes and the connection then closes — which reads as a broken server, not a config mismatch.
>
>    ⏳ **One step remains and it is Danny's:** **Jellyfin → Networking → Known proxies → `172.20.0.0/24`**. Until it lands, Jellyfin files every internet viewer as *local* and applies **no remote bitrate cap**. Ask for the NVENC confirmation at the same time (Playback → Transcoding → Hardware acceleration) — the 8-session capability is measured but the *setting* has never been read.
>
>    ✅ **The DDNS gap is deleted, not solved.** Every earlier draft needed a dynamic-DNS updater because the record pointed at a residential IP on a changing lease — hence the planned `dg.datakiin.com` indirection. **A Linode address is static.** Write the record once; `dg.datakiin.com` is no longer needed and should be dropped rather than built.
>
>    Original authoring note: ✅ **fully authored 2026-09-01 in [`vps/`](vps/)** (`setup-vps.sh`, `setup-labserver-wireguard.sh`, `nginx-stream.conf`, README with the rental spec). Chosen **Linode Nanode 1 GB, Washington DC (`us-iad`)**, ~$5/mo expected, 1 TB traffic, IPv4 included. ⚠️ **Hetzner was recommended twice and dropped:** it is cheap in the EU and not in the US — the only Ashburn plan was **CPX11 at $21.09/mo**, ~3× its EU equivalent. 📌 **Three price figures were quoted in this project from memory and two were flatly wrong** ("$4–5/mo, ~20 TB", then "€11.99/mo, 0.5 TB"). `us-iad` is the same metro as Ashburn, so the Minecraft-latency argument is unchanged. The [`vps/`](vps/) scripts are provider-agnostic — only the firewall step differs. Ashburn is chosen for Minecraft latency: Danny is DC-metro (Cloudflare serves him from `IAD`, his Verizon hop is East Coast). Tunnel subnet **`10.10.0.0/24`**, checked against every subnet in play. Everything public depends on this step.
> 4. ⛏️ **Migrate Minecraft off Romulus.**
>
> **Open:** `files/` (Syncthing + FileBrowser) is authored but **orphaned** — Syncthing was the wrong tool once the requirement turned out to be many-to-one ingest rather than mirroring. Either delete it or keep FileBrowser alone for renaming uploads into Jellyfin's convention.

> ▶️ **ACTIVE 2026-08-13**
>
> **Just landed — the isolation.** Danny installed the FortiGate 40F and labserver is now on `192.168.50.0/24`, **verified unable to reach the house LAN** at both ICMP and TCP while the internet still works. Karla's requirement is satisfied in effect; the remaining questions are about *configuration detail*, not whether it works. This was the gate on everything else.
>
> **Order of work:**
> 1. ~~Rebind Ollama~~ ✅ **DONE 2026-08-13**, verified from Romulus (11434 refused, API unreachable, 22 still up).
> 2. ~~Re-scope ufw~~ ✅ **DONE 2026-08-13** — six rules moved `10.0.0.0/24` → `192.168.50.0/24`.
>    - 🗑️ **`FOR-DANNY.md` and `RUNBOOK-port-forward.md` were DELETED 2026-09-02.** Both documented the port-forward chain, and the VPS design deleted that chain entirely — so both had become instructions for work that must *not* be done. `FOR-DANNY.md` was the dangerous one: it told Danny to point DNS at his own WAN and open 443 at his perimeter, which would have punched a hole for no reason. Recoverable from git at `HEAD:LabServer/FOR-DANNY.md` and `HEAD:LabServer/RUNBOOK-port-forward.md` if the history is ever wanted. **What Danny is actually asked for now is two settings, both in Jellyfin** — see the Known-proxies and NVENC items in the status section. If a fresh handoff doc is ever needed, write it against the VPS design rather than reviving either file.
- [`setup-labserver-postgate.sh`](setup-labserver-postgate.sh) does both idempotently (`--dry-run`, `--ollama-only`, `--ufw-only`) and **derives the LAN subnet at runtime rather than hard-coding it**. Both fixes were run by hand this time because Jon was already in an SSH session; the script is kept as the repeatable record and is the better path next time — this address has now moved three times in four days.
> 3. 🗣️ **Phone Danny** — the five questions under Karla's requirement, especially Samba and the company-firewall ambiguity.
> 4. 🐳 **Install Docker** — [`setup-labserver-docker.sh`](setup-labserver-docker.sh) is written and waiting.
> 5. ~~🌐 **Public path proof**~~ ✅ **DONE 2026-08-13 — `lab.datakiin.com` is live** through a new `labserver` tunnel, origin IP hidden, zero inbound ports. The domain-plan blocker is resolved: **subdomains under `datakiin.com`**, starting with `lab`. The existing `Datakiin` tunnel on Romulus was left untouched.
> 6. ~~🔐 **Caddy + Let's Encrypt (DNS-01)** on labserver~~ ✅ **DEPLOYED 2026-08-14** — real LE cert for `watch.datakiin.com`, trust-store validated, proxying to Danny's native Jellyfin, 443 bound to the LAN IP only (refused from the tailnet), isolation re-verified intact.
>    - ✅ The single 502 in the log was a **one-off during setup**, fixed by a ufw rule (`8096/tcp from 172.20.0.0/14`) before it was ever noticed. Not intermittent, not a blocker. A 🟡 **robustness tidy-up** (pin `extra_hosts` to `172.20.0.1`, narrow the `/14` to `/24`) is written up but explicitly **does not gate the launch**.
>    - **Next: the two off-box steps** — the **`jellyfin` A record** (currently NXDOMAIN — grey cloud, plus the DDNS gap) and the **port-forward chain** with Danny. Both written out under "The two steps still needed."
>    - Then the **odin auth layer**.
> 7. ⛏️ **Migrate the Minecraft stack** off Romulus (newly in scope).
> 8. 🌐 **Game-door VPS** — ✅ **box + tunnel BUILT 2026-09-02** (`172.233.207.73`, WireGuard `10.10.0.1` ↔ `10.10.0.2`, Linode Cloud Firewall). ⏳ **Game half still to do:** mc-router on the VPS for TCP 25565 and the `24454-24473/udp` voice range, plus the matching firewall rules — deliberately not open yet. **Needs nothing from Danny** — no router forward, no FortiGate rule — which is most of the point. See "The game door"; the Minecraft-side detail is in [`MinecraftServers/CLAUDE.md`](../../MinecraftServers/CLAUDE.md).
>
> ✅ **Settled:** Danny asked for this and consents; Jon pays; ~$4–5/mo recurring (the game-door VPS) and $0 one-time; Docker not Kubernetes; Caddy not nginx/Apache; **no VPS for the web door** (a VPS does carry game traffic — decided 2026-08-27); mini scrapped.
>
> **Open items:** ~~(a) re-scope ufw~~ **CLOSED**; (b) confirm the **domain plan** for hostnames (scaffold assumes subdomains under `datakiin.com`) — **blocks the web deploy**; (c) install Docker; (d) reconcile `sda` — now ext4 label `archive` at `/srv/archive` (docs said `/mnt/storage2`) with a new `/var/log/lab-backup.log`; find out what changed; (e) confirm the FortiGate's actual config with Danny.

**Done:** ~~reach the server~~ (2026-08-10, Tailscale share) · ~~get in + pull specs~~ (key auth as `jony`) · ~~storage decision~~ (nothing to buy) · ~~security preflight~~ (ufw active, external IPv6 probes closed) · ~~container runtime decision~~ · ~~reverse proxy decision~~ · ~~VPS question~~ (re-answered 2026-08-27 — no for the web/media doors, **yes for the game door**) · ~~Karla's isolation~~ (FortiGate, verified) · ~~messaging read-path proof~~ · ~~Caddy + LE DNS-01 deployed~~ (2026-08-14) · ~~streaming capacity measured~~ (2026-08-14 — 41 Mbps up, NVENC cap 8; the uplink binds first)

## Lessons learned

**Networking + exposure**

- **A bind address is a stronger control than a firewall rule, because it fails closed.** A firewall must be present, correct, *and* active to say no — turn it off, or route around it as Docker and Tailscale both do, and everything behind it is open. A bind address is a property of the socket: if nothing listens on that interface, there is no connection to filter. Same lesson the kids' PCs taught in [FamilyNetwork](../CLAUDE.md).
- **Don't trust your own docs about a bind address — run `ss`.** This doc asserted for two days that Ollama was on `127.0.0.1` because that was the *intent*; a systemd override said `0.0.0.0` and it had been listening tailnet-wide the whole time. Intent in a comment is not configuration. `ss -tlnp` is the only authority on what is listening; `systemctl show <svc> -p Environment` on why.
- ⚠️ **Docker publishes ports *around* ufw, not through it.** The daemon writes its own `DOCKER`/`DOCKER-USER` chains and DNATs published ports before ufw's INPUT rules are consulted. A bare `ports: ["8096:8096"]` is reachable from the whole LAN *and* every tailnet node while `ufw status` still reads "deny". The fix is the **bind address**: `127.0.0.1:8096:8096`, or publish nothing and use the shared `edge` network. Belt-and-braces: a default-deny in `DOCKER-USER`, which *is* consulted for forwarded traffic.
- **"The firewall will stop it" is not an answer when the firewall runs on the machine you assume gets compromised.** Host-based egress rules protecting a *third party* are enforced by the untrusted host itself — root flushes them. Worse, same-L2 adjacency lets a rooted box ARP-spoof its neighbours regardless of its own ruleset. Isolation must live **off** that host: VLAN, guest network, or a firewall in between.
- **A routine `apt install` can silently delete a security property you wrote down as permanent.** This doc recorded `ip_forward = 0` as a standing guarantee for Karla; installing Docker set it to `1` with no prompt and no warning, because containers cannot route out otherwise. Nothing was harmed **only because the real control lives on the FortiGate, off the host** — verified still holding minutes later. If a safety property can be revoked by a package postinst script, it was never a control; it was a coincidence you were monitoring. Put the control somewhere the workload cannot reach, and **re-test the property after any install that touches networking.**
- **Isolation requirements are directional — check which way before assuming a conflict.** "labserver must not reach the house" and "the house must reach labserver's file shares" sound contradictory and are not: one is outbound from the untrusted host, the other inbound to it, and a stateful firewall's return traffic grants no pivot. We had queued a painful Samba-vs-isolation decision for Danny; the right question dissolved it. **Ask "in which direction?" before designing a trade-off around a constraint.**
- ⚠️ **Changing ISP deletes the subnet your security policy is written against — and the policy keeps looking correct.** Danny swapping Comcast for Fios (2026-08-29) removed `10.0.0.0/24` from existence. Every rule, probe and runbook value keyed to that subnet is now matching nothing, **including the FortiGate deny that is Karla's protection** — if it was written as a `10.0.0.0/24` address object rather than interface-to-interface, isolation silently became a no-op with a green UI. This is the third instance of the same failure in this project (ufw rules left pointing at `10.0.0.0/24` after the FortiGate cutover; `ip_forward` flipped by a Docker install), so the general form is worth stating: **a control expressed as a literal address is only as durable as the network it names.** Prefer interfaces, zones and names over addresses — the same reasoning that keeps `HostName` names in `~/.ssh/config` and made Tailscale survive four address changes without an edit. And **re-verify every address-keyed control after any upstream change, not just after changes you made.**
- 🚧 **Bandwidth bought past your narrowest device is bandwidth you cannot use — and the narrow device is never the one you were thinking about.** Danny replaced a 41 Mbps Comcast uplink with **Fios 5 Gig symmetric**, a ~122× increase that labserver will never see: every packet to it crosses a **FortiGate 40F, whose five ports are all GbE**. Meanwhile the service ceiling had already moved somewhere else entirely — NVENC's measured **8-session cap** now binds ~15× before either bandwidth number matters. **When a bottleneck moves, go find the new one before celebrating**, and enumerate the *intermediate hops*, not just the endpoints. Corollary with teeth here: the right response to the GbE cap is **not** to take the firewall out of the path — it is the control protecting Karla, and 1 Gbps is already 24× what we had.
- 📌 **An upgrade you recommended is still a change you have to absorb.** Fios was our suggestion, correctly — a symmetric line dissolves the 41 Mbps ceiling that no hardware could move. It also invalidated the public IP, the house gateway, the double-NAT hop map, the whole port-forward runbook and the entire streaming-capacity analysis in one evening. **Recommending an infrastructure change means owning the re-measurement it forces**; budget for that when you write the recommendation, and say so in it. The since-deleted `FOR-DANNY.md` did flag "downtime plus redoing the FortiGate WAN setup", which is why this is a chore and not a surprise.
- **ICMP-blocked does not mean TCP-blocked.** Verifying isolation with `ping` alone is a false pass. Probe actual TCP ports, and probe **infrastructure (the gateway), not someone's personal machine**.
- **Verify segmentation empirically, never from the config screen.** FortiOS policies are ordered, first-match; a deny placed below a general allow looks identical in the UI and does nothing. The deliverable is a test result.
- **Count a free tier's limits against your actual scale before building on it.** playit.gg was the right answer for the game door and stayed right for months; it died to arithmetic, not to a flaw. Eleven worlds × (one TCP game port + one UDP voice port) is 22, against a free-tier cap of 4 and a paid cap of 16 — so the tier that fit at pilot size fit nothing at real size. **A $3/mo tier that does not cover the requirement loses to a €4/mo one that does, and the number that decides it is a port count nobody had multiplied out.** Related: mc-router collapses the TCP side to one port, which is a genuinely large win, and it still does not save the free tier — because UDP cannot be multiplexed the same way and voice is the half that sets the ceiling. **Check whether the clever fix applies to *both* halves of the requirement.**
- **A blanket decision recorded in a heading outlives the reasoning that produced it.** "The front door — Caddy, no VPS" was true of the door being discussed and read as true of the whole project; when the game door reached the opposite answer, the heading was the thing most likely to be believed over the body text. **Scope a decision to the case it was argued for**, especially in a heading — and when reversing one, leave the reversal visible rather than editing it away, or the next reader rediscovers the trade-off the hard way.
- **Anonymity is per-audience, not per-server.** Hiding the origin IP from anonymous Minecraft players prevents a real DDoS; hiding it from your own family prevents nothing. Sorting services by *who is on the other end* is what collapsed this build from ~$15/mo to ~$4/mo — the media doors free, the one hostile-audience door paid for on its own merits.
- **Check for CGNAT before designing the front door.** A WAN IP in `100.64.0.0/10` means no inbound forward is possible and a relay becomes compulsory; a routable address makes the free path viable. One `curl ifconfig.me` decides a $60/yr line item.
- **A reverse proxy and a VPS are not alternatives.** The proxy terminates TLS and routes hostnames — needed either way. The VPS is just *a public IP somewhere else*. Ask "where does the proxy run and how does traffic reach it," not "nginx or VPS."
- **Run one reverse proxy, not two.** Only one process binds `:443`; a split means chaining them plus two cert mechanisms, two config languages, and two places to debug a 502.
- Cloudflare Tunnel is HTTP-only; game/raw-TCP can't ride it (needs paid Spectrum). That fact has not changed — what changed is the alternative: game traffic now goes out through **our own VPS relay**, not playit.gg.
- **The Cloudflare dashboard hands you an install *command*, not a token.** Pasting the whole `cloudflared service install eyJ…` line into `TUNNEL_TOKEN` yields `Provided Tunnel token is not valid`. The token is only the trailing argument, and it always starts **`eyJ`** (base64 for `{"a"` — a JSON blob of account id, tunnel id and secret). Sanity-check a credential by **shape, not by eye**: length, prefix, and "does it contain spaces" caught this in one command without ever printing the secret.
- **Cloudflare `530` means the tunnel has no live connections** (error 1033 wrapped), not that DNS or the hostname mapping is wrong. Check the connector is actually running before touching anything in the dashboard — `pgrep -af cloudflared` and an established outbound socket on **7844** answer it without needing docker access.
- ⚠️ **`host-gateway` resolves to `docker0` — which is DOWN if every stack uses a user-defined network.** `extra_hosts: host.docker.internal:host-gateway` points at the *default* bridge (`172.17.0.1`), not at the network the container is actually on. Here that address belongs to a bridge nothing is attached to. It still works, but only because ufw's rule is **source**-matched and Linux keeps a down interface's address locally routable — a lot of coincidence to rest a family service on. Name the live gateway explicitly. When a proxy 502s, the upstream IP is **in the log**: `dial tcp <IP>` identifies the culprit instantly.
- **ufw rules match source address + destination PORT, not destination IP.** `allow from 172.20.0.0/14 to any port 8096` permits that source to hit port 8096 on *every* address the host owns — including a different bridge's IP. This is why the proxy works while dialing an interface that is down, and why reading the rule as "allow the edge bridge to reach itself" would be wrong. It also means such a rule is broader than it looks: a `/14` covers every present and future docker bridge.
- **`i/o timeout` vs `connection refused` tells you firewall-vs-nothing-listening.** A silent DROP (firewall) times out; a closed port answers with RST immediately. The 3.00 s duration in a 502 log line is itself the diagnosis.
- 🔁 **A long-running process can start succeeding without restarting, because the fix lived outside it.** Reasoning error made and corrected in one session: Caddy logged a 502, then served 8/8 clean 200s ~80 min later from the *same pid*, so "no restart ⇒ nothing was fixed ⇒ it must be intermittent" — and a whole intermittent-failure theory got written up. Wrong. **A ufw rule was added in between**, changing kernel packet handling with no restart, no reload, and no entry in the application log. Before theorising about an application, ask what changed in the *environment* around it.
- **Count the occurrences before escalating a log line.** `grep -c 'i/o timeout'` returned **1**. One 502 across the container's entire life is a transient during setup; the same line seen once and assumed recurring produced an urgent "do not ship" recommendation that the evidence never supported. Severity is a frequency question, and it costs one `grep -c` to answer.
- **Test the cheap hypothesis before writing it down as likely.** "`host.docker.internal` probably resolves to both addresses" was plausible, load-bearing, and settled by a single `getent ahosts` — which returned exactly one address. The command was available the whole time; the theory got written first.
- ⚠️ **Putting a reverse proxy in front of a service breaks everything the service keys on client IP** — and it breaks *silently*, in the permissive direction. Every request now arrives from the proxy, so Jellyfin's local-vs-remote test, rate limits, geo rules and per-client logging all see one address inside the trusted network and conclude "this is a LAN user, no restrictions." The mitigation you were relying on evaporates while the service still looks healthy. **Register the proxy as trusted (Jellyfin: Known proxies) so `X-Forwarded-For` is honoured, and verify with a real external request** — the setting is easy to believe and cheap to test. Ask this of any service the moment you front it.
- **`127.0.0.1` inside a container is the container, not the host** — the single most common reverse-proxy-in-Docker mistake. A proxy container fronting a **host-native** backend needs `extra_hosts: host.docker.internal:host-gateway` and `reverse_proxy host.docker.internal:PORT`. The generic "just point it at `127.0.0.1:8096`" snippet is correct only when the proxy runs on the host or the backend is another container. Confirm which side of the boundary the backend is on *before* copying a config snippet.
- **Container→host traffic goes through the INPUT chain, so ufw DOES apply to it** — unlike published-port traffic, which Docker DNATs in FORWARD and which ufw never sees. This is the mirror image of the "Docker publishes around ufw" lesson and it catches people the other way: the firewall you thought was bypassed is suddenly the thing blocking your proxy. A host-native backend bound to `0.0.0.0` works by luck; tighten that bind and the ufw rule becomes load-bearing.
- **DNS-01 issues a valid cert for a hostname that does not resolve.** The challenge only creates and removes a `_acme-challenge` TXT record, so a working, publicly-trusted cert proves *nothing* about whether the name is reachable — no A record, no port-forward, no listener required. Don't read "the cert issued" as "the service is live," and don't debug a missing A record by re-issuing certs.
- **Verify a cert with `curl` WITHOUT `-k`, and read the issuer.** Caddy falls back to its own internal CA when ACME fails, and that fallback serves HTTPS perfectly happily — `-k` makes a self-signed fallback and a real Let's Encrypt cert look identical. `ssl_verify_result=0` plus `issuer=... O=Let's Encrypt` is the actual test; anything else is confirmation bias with a padlock on it.
- ⚠️ **Cloudflare's orange cloud can silently undo a deliberate architecture decision.** Jellyfin gets its own Caddy + port-forward door *specifically* so family video does not traverse Cloudflare's free CDN (a terms-of-service risk). Proxying the DNS record — one toggle, the dashboard default — puts the video right back through Cloudflare while everything still appears to work. **Media hostnames must be DNS-only / grey cloud.** When a design exists to avoid a provider, check the provider isn't re-inserted by a default.
- **A tunnel opens no inbound port, which is why it composes with strict isolation.** `lab.datakiin.com` is public while the FortiGate has no VIP, the router has no forward, and ufw has no rule — the connector dials *out*. Same property that keeps Tailscale working from inside a DMZ. Prefer outbound-initiated doors wherever the traffic is HTTP.
- **An outbound-initiated admin plane survives topology changes.** When the FortiGate re-addressed labserver behind a new NAT, Tailscale kept working with zero config edits — anything pinned to a LAN IP would have been cut off. Also why admin needs no inbound hole in a DMZ.
- Making a box internet-facing changes the risk profile of **everyone sharing its network** — a household decision, not just an admin one. Ask before building.

- **Ask who exactly you are hiding from, before designing any of it.** A privacy requirement was read as "untraceable, encrypted end to end," and a large design followed: disk encryption, Nextcloud E2EE, anonymous upload links, per-site proxy config to avoid logging client IPs. One clarifying sentence from Jon — *"I'm only worried about during transit, Danny should be able to see it"* — deleted all of it, because **TLS already solved the actual requirement and had done since 14 August.** Two of the discarded items were actively harmful: E2EE would have broken Jellyfin playback outright, and dropping real client IPs would have disabled brute-force protection on a public login page. **The threat-model question is the cheapest design step available, and skipping it builds defences against the wrong adversary.**
- ⚠️ **Encryption at rest cannot hide data from a service that has to decode it.** Jellyfin must read, transcode and stream these files, so plaintext is required at runtime and the key lives on the running machine. LUKS therefore protects a drive that *leaves the building* — theft, RMA, disposal — and nothing else. Nextcloud's E2EE app fails harder: it means the server itself cannot read the files, so External Storage and Jellyfin both see ciphertext and playback stops. **"Encrypt it" is not one capability — name the observer it must exclude, then check whether your own stack is on that list.**
- 🔓 **Certificate Transparency publishes every hostname you obtain a certificate for, within seconds.** No DNS record needed, no reachability needed — the logs are public and scrapers watch the feeds specifically for fresh names to probe. **"Nobody knows the URL" has never been a control.** A wildcard cert collapses the leak to the apex, and is only available via DNS-01.
- ⚠️ **A tunnel that terminates TLS is not a private path.** Cloudflare decrypts everything crossing its tunnel at the edge — fine for public static content, disqualifying for anything private. This is a *second, independent* reason Jellyfin and Nextcloud stay off the tunnel, alongside the video terms-of-service issue. **A provider that terminates your TLS is inside your trust boundary whether you put them there deliberately or not.**
- **Match the tool to the traffic shape, not to the word in the request.** "File sharing" sounded like Syncthing. Syncthing **mirrors**: every peer receives a full copy of the shared folder, so Danny and Jose joining a movie library would each have pulled down the entire library. The real requirement was **many-to-one ingest of large files** — an upload problem. Related: the right answer differed *per contributor*, since Danny is on the LAN with a writable Samba share that needed nothing built, while remote contributors needed chunked resumable HTTP. **Standardising everyone onto one tool would have made the best-served user worse off.**
- 📌 **A stated uncertainty does not stop propagating just because a later paragraph sounds confident.** This document correctly noted that nothing here ever *measured* the FortiGate's WAN as static — then predicted it "will not reach the internet until reconfigured" after the ISP swap. It reconfigured itself: the interface held a DHCP lease, took a new one from the Fios router, and carried on. **Carry the hedge forward into every conclusion built on it, or the caveat becomes a footnote under a confident wrong answer.**

**The box**

- **You can read SMART history without root.** `smartctl` needs raw device access, but `smartd` writes **world-readable** state to `/var/lib/smartmontools/`: `attrlog.*.csv` is a 30-minute time series of every attribute. Gives attribute *history* that plain `smartctl -A` doesn't. What it lacks is the self-test log — for pass/fail you still need root.
- **Drive temperature is a load telemetry channel.** On an idle disk the attrlog temperature curve reveals when a long self-test actually ran and stopped — ramp, plateau, cooldown.
- CSV attrlog decoding: rows are `timestamp; id;normalized;raw; …`. Seagate packs extra data into raw values — attribute 194's temperature is the **low byte** (`raw % 256`).
- `jony` is password-required sudo and **not** in `adm`/`systemd-journal`/`disk`; `kernel.dmesg_restrict=1`. Over non-interactive SSH: no `journalctl`, no `dmesg`, no raw devices. Plan diagnostics around world-readable state files, or hand Jon one command for his own prompt.
- **Debian 13 dropped classic utmp.** `/run/utmp` is gone and `last` isn't installed. The replacement is **`/var/log/wtmp.db`, a world-readable SQLite file** — full login history as an ordinary user.
- **`wtmp.db` records SSH logins ONLY.** A console login on seat0/tty1 never appears. A presence check built on wtmp alone reports "nobody is here" while someone sits at the keyboard. **`loginctl list-sessions` is the authority for who is live** (filter `CLASS == user`; `manager` rows are the per-user systemd instance).
- A `NULL` Logout in wtmp.db means "still open" **or** "died uncleanly." Discard open rows predating the current boot or a reboot leaves a ghost user logged in forever.
- Kubernetes on one node is all cost and no benefit — multi-node scheduling, failover and drain-and-migrate are inert without a second node while the control-plane overhead is fully present. Reach for k3s when a second node exists, not before.

- 🔴 **A container can run perfectly while having no network interface at all — and every symptom points somewhere else.** After a reboot Caddy's container came up with only `lo`: no `eth0`, no route, never attached to its `edge` network. That one fact produced a refused published port, unreachability at every bridge address, and ACME failures reading `lookup ... on [::1]:53: connection refused` — because a namespace with no network cannot reach Docker's embedded DNS, so the resolver falls back to loopback where nothing listens. The process was healthy and listening the whole time, on an island. **Check `/proc/PID/net/dev` for `eth0` before theorising about the application**, and compare against a container that works.
- ⚠️ **`docker restart` cannot repair a broken container network — it reuses the same config.** The fix is `up -d --force-recreate`. Restarting is the obvious first move, comes back identical, and reads as "the problem is deeper than it is."

**Scripting + tooling**

- Scheduled tasks flash a console because **`powershell.exe` allocates one before `-WindowStyle Hidden` applies**. Fixes: `LogonType S4U` (session 0, needs elevation, can't toast) or a **`wscript.exe` .vbs shim** (GUI-subsystem host, hidden from the outset, no admin needed).
- **Keep scheduled-task `.ps1` files pure ASCII.** Task Scheduler runs PowerShell 5.1, which reads `.ps1` as ANSI — one em-dash shreds string literals into parse errors. `pwsh` 7 parses it fine, so it works interactively and fails only from the task. Save UTF-8 **with BOM**.
- Passing a quoted `python3 -c "..."` through PowerShell to `ssh` doesn't survive two argument parsers. **Pipe the script to `python3 -` on stdin** — no quoting layer at all.
- Running `ssh user@host` from a shell *already on* that host fails with `Permission denied (publickey)` — the private key lives on the workstation. Give bare commands when the target shell is already the server.
- **Track "unread" by byte offset, never by timestamp.** Mixing whole-second mtimes with nanosecond comparisons means a message sent and read inside the same second is marked read without ever being displayed — a silently lost message. Append-only log + stored byte offset is exact and has no clock race.
- Debian ships **`wall` without setgid `tty`** (post-`wallescape`, CVE-2024-28085), so an unprivileged user can't write to another's pty; `write`/`talk` aren't installed. To notify a logged-in user without root, use a `PROMPT_COMMAND` hook.
- A shared multi-user spool wants **setgid + sticky** (`root:users 2775`), not just group-write. Setgid makes files inherit the `users` group so the next reader can read them; sticky stops one user deleting another's marker.
- **Sending is not receiving.** Confirming a message was written, logged and mirrored proves only the write path. *(Now closed: the read path was proven observationally by watching another user's byte-offset marker advance on its own.)*
- **`/etc/profile.d` only runs for NEW login shells.** Installing a hook does nothing for sessions already open — which is why the first user to "try it" right after install reports that it doesn't work. Have them start a fresh session before diagnosing anything deeper.
- ⚠️ **`pgrep -f ffmpeg` matches the Jellyfin *server*, not a transcode.** Jellyfin launches as `jellyfin --ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg`, so the string appears in its own argv. [`diag-labserver-streaming.sh`](diag-labserver-streaming.sh) counted that as a live transcode, found no `nvenc` in the (server's) command line, and concluded **"these are SOFTWARE transcodes"** — a scary, wrong headline generated from a process that was not transcoding at all. **Match the executable (field 2 of `pgrep -af`), not the whole command line.** A `--flag=/path/to/x` argument makes any tool look like it is running `x`.
- ⚠️ **ffmpeg reads stdin, which corrupts it inside a `bash -s` script piped over ssh.** The script *is* stdin in that pattern, so ffmpeg can consume it or return truncated output. Same run reported jellyfin-ffmpeg had **no nvenc encoders** while running the identical command by hand listed three. **Always give ffmpeg `</dev/null` (or `-nostdin`) in a piped script.** Related to the existing lesson about piping scripts to `python3 -`.
- **A diagnostic that states conclusions must be at least as trustworthy as the thing it diagnoses.** Two bugs in one script produced two confident, false, alarming claims — "software transcoding" and "GPU encode is impossible" — either of which could have triggered real remediation work on a system that was fine. Diagnostics should **print what they observed** and hedge the inference; "no nvenc reported by this probe, verify by hand" costs nothing and cannot mislead.
- **Check what is already listening before deploying — the thing may already be deployed.** This deploy turned out to be already done and healthy; `ss -tln` showed `192.168.50.10:443` occupied before a single change was made. Re-running `compose up --build` would have been harmless here but is not always: it rebuilds, recreates and briefly drops the service. **`ss` + `pgrep` cost two seconds and reframed the whole task from "deploy" to "verify."**
- **Checksum the deployed copy against the repo copy.** `sha256sum` on both sides of an SSH connection is the cheapest possible answer to "is the box running what version control says it is." All four Caddy files matched; had one drifted, every conclusion drawn from reading the repo would have been about a file that isn't running.
- **Sanity-check a credential by shape, never by printing it.** `.env` was validated as length 53, no whitespace, no quotes, no CR, `[A-Za-z0-9_-]` only — enough to rule out every common paste error (wrapped quotes, trailing `\r` from Windows, the whole install command pasted instead of the token) without the secret ever entering a transcript. Same technique that caught the `eyJ` tunnel-token mistake.
- **Unquoted shell arguments are a UX trap for non-technical users.** `hey it's broken` leaves bash at a `>` continuation prompt — indistinguishable from a hang. `>` silently redirects the message into a file; `&` backgrounds it. Any tool taking free text from a shell should offer an **interactive `read -r` prompt** as the primary path, where the shell never parses the input at all.
- ⚠️ **`/proc/PID/net/tcp` is IPv4 ONLY — dual-stack listeners live in `net/tcp6`.** Reading only the first file showed Caddy holding nothing but its admin socket, which produced a confident and completely wrong "Caddy is serving no sites." It was listening on `[::]:443` and `[::]:80` the entire time. A Go server binding `:443` creates one dual-stack socket that appears **exclusively** in `tcp6`. **Read both, or declare a healthy service dead.**
- ⚠️ **`/dev/nvmeXn1` numbering is not stable across reboots.** Between 2026-08-11 and 2026-09-02 the 1 TB Kingston moved from `nvme1n1` to `nvme2n1` and the 500 GB Crucial went the other way, with nothing physically touched. The mounts stayed correct **only because `/etc/fstab` keys on UUID** — a script or a backup job that named `/dev/nvme1n1` would now be writing to a different disk, silently and with no error. Same family as the ufw rules left pointing at a dead subnet and the FortiGate policy written against `10.0.0.0/24`: **a control expressed as a literal identifier is only as durable as the thing it names.** Use UUIDs for disks, interface names for NICs, hostnames for hosts.
- ⚠️ **Two different `curl` binaries are not a controlled comparison.** The public path reported `proto=1.1` while LAN-direct reported `proto=2`, which read as "something in the nginx/WireGuard chain is downgrading HTTP/2" — a plausible, interesting, entirely fictional finding. The LAN test had run on **labserver's** curl and the public test on **Romulus's Git Bash curl, which has no HTTP/2 support at all** (`--http2` errors out; `-v` shows no ALPN lines). Re-run from an h2-capable client and the tunnel negotiates `h2` fine. **Hold the client constant when comparing two network paths**, and when a protocol-level difference appears between two hosts, check the tools before theorising about the wire. Same family as the mawk and `pgrep -f ffmpeg` errors below.
- ⚠️ **`strtonum()` is a gawk extension; Debian ships mawk, which fails and prints nothing.** An awk probe that had worked minutes earlier was rewritten using `strtonum`, produced empty output, and read as "the container restarted and the state changed" — when the state was identical and only the parser had broken. **When output changes and the system demonstrably did not, suspect the tool before the system.** Same family as the `pgrep -f ffmpeg` and Event-ID-without-provider errors already recorded here.
- **Long heredocs piped to an interpreter are fragile in this environment; write the script to a file and run it.** Two multi-hundred-line `<<'PY'` blocks died with `unexpected EOF while looking for matching quote` despite being correctly quoted, while short ones in the same session worked fine. Not worth debugging — `Write` the script, then execute it.
