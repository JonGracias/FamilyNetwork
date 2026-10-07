# `vps/` — the public door

A small rented box with a static public IPv4. labserver dials **out** to it
over WireGuard; the VPS holds the address the world is given and pushes
traffic back down a tunnel it did not open.

**Why it exists:** it deletes every task that needed Danny at a console — the
443 port-forward, the FortiGate VIP and policy, pinning the FortiGate WAN
static, and the DDNS gap — because nothing inbound is ever required. It also
keeps Danny's home IP off Minecraft's hostile audience.

**What it is not:** it terminates no TLS, holds no certificate, stores no
data, and cannot read a byte of what it relays. If this box is compromised the
attacker gets a relay, not the family's files.

## ✅ RENTED 2026-09-02 — `172.233.207.73`

| | Measured |
|---|---|
| Instance | Linode **Nanode 1 GB**, label `datakiin-relay` |
| Region | **`us-iad`** (Washington, DC) |
| **Public IPv4** | **`172.233.207.73`** |
| Public IPv6 | `2600:3c05::2000:f2ff:fe69:21fe/64` |
| OS | Debian 13 (trixie), kernel 6.12.88, OpenSSH 10.0p2 |
| **Price** | **$5/mo · $0.0075/hr · 1 TB transfer · 1 Gbps out** — read off the order page |
| Firewall | Cloud Firewall `datakiin-relay-fw`, attached at create |
| SSH | alias **`vps`** on Romulus; root, key-only, verified `Permission denied (publickey)` for passwords |
| WireGuard pubkey | `BLe077m+kenV9WWoFzQsITKR20L5ccRGyc6IIOYqyzE=` |

⚠️ **`ping` does not work against this box and that is correct.** The Cloud
Firewall's default inbound policy is DROP and ICMP is not in the allow-list,
so echo requests are dropped while 22, 443 and 51820 answer normally. Use a
TCP probe — the same layer-by-layer reasoning the kids' PCs taught in
[FamilyNetwork](../../CLAUDE.md).

📌 **The `~$5/mo` estimate below was right** — but it is recorded here as
*confirmed* because this file's own standing rule is that a price is worth
nothing until it is read off the page. Two earlier figures in this project
were wrong from memory; this one was checked.

✅ **nginx's default `:80` site removed.** The `nginx-full` install brought up
a default vhost on `0.0.0.0:80` and `[::]:80`. It was already unreachable —
80 is not in the Cloud Firewall — but it was removed anyway rather than left
depending on that, because a bind address is a stronger control than a
firewall rule. `ss -tlnp` now shows **sshd and nothing else.**

## What to rent — the spec that was bought

I can't rent it; that's a purchase with your payment details. Here's the spec
to buy:

| | |
|---|---|
| Provider | **Linode / Akamai** |
| Plan | **Nanode 1 GB** (shared CPU) — 1 vCPU / 1 GB / 25 GB SSD / 1 TB transfer |
| Region | 🎯 **Washington, DC (`us-iad`)** |
| IP | IPv4 included by default — no separate charge, unlike Hetzner |
| Image | **Debian 13** if offered; Debian 12 is fine if not — nothing here depends on the difference |
| SSH key | add Romulus's `id_ed25519.pub` at create time; **disable root password login** |

⚠️ **Verify the price yourself before buying.** Nanode has historically been
around **$5/mo**, but this document has already carried two wrong price
figures quoted from memory (see the correction note below), so treat that as
the expected shape and read the real number off the order page.

📌 **Why not Hetzner, after recommending it twice.** Hetzner is genuinely the
cheap option **in Europe** and is not competitive in the US: the only Ashburn
plan on offer was **CPX11 at $21.09/mo**, roughly triple its EU equivalent for
the same hardware. Two earlier figures in this file — "$4–5/mo, ~20 TB" and
then "€11.99/mo, 0.5 TB" — were **both wrong**, recalled rather than checked.
Recorded rather than quietly overwritten: a cost quoted confidently from
memory is exactly the kind of number that gets built into a plan and never
re-examined. **Read provider pricing off the page, every time.**

📍 **`us-iad` is the same metro as the Hetzner Ashburn option** — IAD is
Dulles/Ashburn. So the latency argument is unchanged: Danny is DC-metro
(Cloudflare serves him from the `IAD` edge, his Verizon upstream hop is East
Coast), and players get sub-20 ms. A European datacenter would add ~90 ms to
every player's ping and send family video across the Atlantic twice.

**1 GB of RAM is not a compromise — it is oversized.** This box terminates no
TLS, stores no data, runs no database and transcodes nothing. WireGuard,
nginx's stream proxy and (later) mc-router come to roughly 100–200 MB
together. What you are buying here is **a public IPv4 address in the right
city**, not compute. The only CPU question is WireGuard encryption, and a
single modern core handles that well past 1 Gbps — already the FortiGate's
ceiling, against a realistic load of ~64 Mbps for eight concurrent transcodes.

**Traffic:** 1 TB included. A 1080p transcode at 8 Mbps burns ~3.6 GB/hour, so
that is roughly **280 hours/month** of remote viewing — comfortable for a
family. Check Linode's current overage rate when you order; it is the one
number worth knowing in advance.

## Order of operations

The two ends need each other's public keys, so it's a two-pass exchange. Keys
are generated **on** each machine and the private half never moves — nothing
secret belongs in this repo.

✅ **ALL FOUR PASSES DONE 2026-09-02 — the tunnel is up.**

| | |
|---|---|
| VPS pubkey | `BLe077m+kenV9WWoFzQsITKR20L5ccRGyc6IIOYqyzE=` — `10.10.0.1` |
| labserver pubkey | `TXj5F/zRUranFo6czqbE3RKmfUCw6Qn/hW8n9IIAKy0=` — `10.10.0.2` |
| Handshake | both directions, `PersistentKeepalive = 25` |
| Latency | **0% loss, RTT 5.98 ms** VPS → labserver |
| Learned endpoint | `<DANNY-WAN>:57521` — Danny's Fios WAN |

🔥 **That last row is the whole design working.** The VPS config has **no
`Endpoint` line** for labserver; it learned the address from the first
handshake. Traffic now flows into Danny's house with **no port-forward on the
Fios router and no VIP or policy on the FortiGate.**

✅ **Isolation re-tested straight afterwards** — `192.168.1.1` still blocked on
ICMP and TCP 80/443/53/22/8080, with `1.1.1.1` reachable as the control.

```bash
# 1. On the VPS — installs packages, makes keys, prints the VPS public key   [DONE]
sudo ./setup-vps.sh

# 2. On labserver — makes keys, prints labserver's public key
sudo ./setup-labserver-wireguard.sh

# 3. Back on the VPS — feed it labserver's key
sudo ./setup-vps.sh --peer-pubkey <labserver-public-key>

# 4. On labserver — feed it the VPS's key and address; brings the tunnel up
sudo ./setup-labserver-wireguard.sh \
  --vps-endpoint <vps-ip>:51820 \
  --vps-pubkey   <vps-public-key>
```

Then follow the "NEXT, on labserver" block that step 4 prints: add the `wg0`
publish to Caddy, add the `proxy_protocol` listener wrapper, disable HTTP/3.

## Firewall — the provider's, not `ufw`

Create a **Linode Cloud Firewall** and attach it to the instance. Set the
default inbound policy to **DROP**, outbound to **ACCEPT**, then allow:

| Port | Proto | From | Why |
|---|---|---|---|
| 51820 | udp | anywhere | WireGuard. labserver dials out, but this side must listen |
| 443 | tcp | anywhere | the public door |
| 22 | tcp | your address if you can pin it | admin |

Later, for Minecraft: `25565/tcp` and the voice range `24454-24473/udp`.

⚠️ **Do not open `443/udp`.** HTTP/3 is deliberately not forwarded — see the
reasoning in [`nginx-stream.conf`](nginx-stream.conf) — and Caddy is told to
stop advertising it.

⚠️ **Use the Cloud Firewall rather than `ufw` on the box.** A cloud firewall
runs **outside the instance**, so nothing running inside can route around it.
`ufw` can be: if Docker is ever installed here it writes its own iptables
rules and DNATs published ports ahead of ufw's INPUT chain, so a port you
believe is closed stays open. That trap is documented twice already in this
project.

## Design notes worth not re-deriving

- **`AllowedIPs = 10.10.0.1/32`, never `0.0.0.0/0`.** Full-tunnel would route
  labserver's entire internet egress through the VPS: it would break
  Tailscale's direct paths, put every outbound connection behind one address,
  and pay for bandwidth already paid for on a 5 Gig line.
- **`PersistentKeepalive = 25` on the labserver side is required.** The VPS
  has no `Endpoint` for us and learns our address from the handshake. Without
  keepalive the NAT mapping expires during idle periods and inbound
  connections silently stop working until labserver sends something — an
  outage with no cause and no log entry.
- **`10.10.0.0/24` was checked against every subnet in play** —
  `192.168.50.0/24` (FortiGate LAN), `192.168.1.0/24` (Fios house),
  `10.0.0.0/24` (Jon's house), `172.16–172.23` (Docker pools),
  `100.64.0.0/10` (tailnet). No collision.
- **nginx proxies, it does not route.** It terminates one TCP connection and
  opens another, so the kernel sizes tunnel-side segments from `wg0`'s MTU.
  That sidesteps the path-MTU black holes that plague routed WireGuard, with
  no MSS clamping.
- **PROXY protocol is not optional.** Without it Caddy sees `10.10.0.1` as the
  client for every request; Jellyfin then files every remote viewer as local
  and applies no bitrate cap, and Nextcloud counts all failed logins against
  one address until it locks out the internet.

- **mc-router's file reload only adds.** `-routes-config-watch` picks up a new route
  the moment `routes.json` changes but keeps one the file dropped until a restart - and a
  restart drops every player. `install-mc-router-sync.sh` (after `install-mc-router.sh`)
  adds a path unit that runs `mc-router-sync` on every change, deleting stale routes
  through mc-router's local API (`127.0.0.1:8734`). Installed and proven 2026-10-07.

## After it's up

🚨 **Re-run the isolation test.** Nothing here opens an inbound rule at
Danny's perimeter, so it should be untouched — but this project has twice had
a security property die to a change nobody expected to matter. Confirm
labserver still cannot reach `192.168.1.1` on ICMP or TCP 80/443/53, with
`1.1.1.1:443` as the control.
