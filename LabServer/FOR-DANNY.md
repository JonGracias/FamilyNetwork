# labserver → Jellyfin on the internet — what's done, what I need from you

**From:** Jon · **Date:** 2026-08-14 · **For:** Danny, when you're back Sunday

> 🔴 **Out of date as of 2026-08-29 — do not send this version.** Danny took the Fios upgrade suggested at the bottom of this document — in fact he took **5 Gig, not the 300/300 costed here** — so the Comcast router, the `10.0.0.x` addresses and the public IP `73.132.162.205` throughout are all gone, and the 41 Mbps capacity section is superseded by a symmetric line. The ⚡ ACTION steps still need doing — their values need re-measuring first. Rewrite against the new network before handing it over.

Short version: **the server side is finished and tested.** Jellyfin has a real HTTPS certificate and a working reverse proxy. The only thing standing between it and the family being able to watch from anywhere is **two port-forward rules — one on your Comcast router, one on the FortiGate.** Those are on your hardware, so they need you.

Everything below is either *context so you can sanity-check what I did*, or *a thing I need from you*. The **⚡ ACTION** markers are the parts that need your hands.

---

## 1. What's built and working

| Piece | Status |
|---|---|
| Caddy reverse proxy (in Docker) | ✅ running |
| HTTPS certificate for `jellyfin.datakiin.com` | ✅ real Let's Encrypt cert, valid to 12 Nov 2026, auto-renews |
| Proxy → your Jellyfin | ✅ verified, returns your library |
| Karla's isolation | ✅ re-tested after every single change, still holding |

The proxy listens on **`192.168.50.10:443`** and forwards to your existing Jellyfin on port 8096. I did **not** move, containerise, or reconfigure your Jellyfin — it's the same install you've always had, just with a proxy in front of it.

**The cert was issued without opening any ports.** It uses a DNS-based challenge through the Cloudflare API, so there was never an inbound hole for it, and there never will be. This also means **we never need port 80** — please don't forward it.

### What is NOT currently reachable from the internet

Nothing. Right now `192.168.50.10:443` is only reachable from labserver's own network segment. Until you add the forwards, the outside world cannot reach it at all.

---

## 2. What I changed on your machine

Full list, so nothing is a surprise:

| Change | Detail |
|---|---|
| Installed Docker | official Docker repo, `docker-ce` + Compose v2 |
| Installed Caddy | in a container, at `/srv/datakiin/stacks/caddy/` |
| Installed cloudflared | for a test page, `lab.datakiin.com` |
| Rebound Ollama | was listening on **all** interfaces with **no authentication** — now loopback-only. See below. |
| ufw rules | re-scoped from `10.0.0.0/24` (the old pre-FortiGate subnet, matching nothing) to `192.168.50.0/24`; added one rule letting the Caddy container reach Jellyfin |
| `/srv/datakiin` | my 4 TB drive, my files only |

**What I did NOT touch:** your Samba config, your Jellyfin settings, your media, your files, your user accounts. Samba's still exactly as you had it.

⚠️ **One thing you should know about:** Ollama was listening on `0.0.0.0:11434` with no authentication, which meant anything on the Tailscale network could use it *and delete your models*. I changed it to listen only on localhost. Nothing you use should notice — the `odin` command still works normally.

ℹ️ Installing Docker flipped the kernel's `ip_forward` from 0 to 1. That's normal and required for containers. It does **not** affect the isolation, because the isolation is enforced on your FortiGate, not on the host.

---

## 3. ⚡ ACTION: the four things I need from you

The chain we're building:

```
internet → Comcast router → FortiGate → labserver:443 → Caddy → Jellyfin
```

> 🔑 **The one thing people get wrong here.** Your FortiGate sits *behind* the Comcast router — I confirmed this by tracing the hops. That means there are **two** NATs, and the FortiGate's VIP "External IP" must be **the FortiGate's own WAN address (a `10.0.0.x`), NOT the public IP `73.132.162.205`.** Only the Comcast router ever sees the public address. Setting the public IP on the VIP produces a setup that looks correct and silently doesn't work.

### ⚡ 3.1 — Pin the FortiGate's WAN address

**You may have already done this.** I can't see it from my side — labserver is blocked from reaching `10.0.0.1` by design, and your FortiGate's admin interface isn't listening toward labserver (which is correct, good call).

- **If it's already static:** just tell me the address, and skip to 3.2.
- **If it's still on DHCP from the Comcast router:** please pin it.

| Field | Value |
|---|---|
| Addressing mode | Manual / Static |
| IP | e.g. `10.0.0.2/24` — anything **outside** the router's DHCP pool |
| Gateway | `10.0.0.1` |

*Why:* everything below points at this address. If it's a lease and it changes, the whole thing breaks silently, months later, and nobody connects the two events.

### ⚡ 3.2 — Comcast router: forward 443

| Field | Value |
|---|---|
| Protocol | **TCP** |
| External port | **443** |
| Internal port | **443** |
| Destination | **the FortiGate's WAN address** from 3.1 |

⚠️ **Not `192.168.50.10`.** The Comcast router has no route to that address — it's on the far side of your own firewall. It forwards to the FortiGate; the FortiGate forwards the rest of the way.

🚫 **Do not forward port 80.** We don't need it and don't want it.

*Optional:* also forward **UDP 443** if you want HTTP/3. Without it everything still works, clients just fall back to TCP after a brief delay.

### ⚡ 3.3 — FortiGate: create the VIP

*Policy & Objects → Virtual IPs → Create New*

| Field | Value |
|---|---|
| Name | `vip-labserver-https` |
| Interface | your **WAN** interface |
| Type | Static NAT |
| External IP | **the FortiGate's WAN address** (`10.0.0.x`) ← not the public IP |
| Mapped IP | **`192.168.50.10`** |
| Port forwarding | ✅ enabled |
| Protocol | TCP |
| External port → Map to port | **443 → 443** |

### ⚡ 3.4 — FortiGate: the policy

The VIP does nothing on its own — it's just a translation rule. Traffic stays blocked until a policy allows it.

*Policy & Objects → Firewall Policy → Create New*

| Field | Value |
|---|---|
| Incoming interface | WAN |
| Outgoing interface | the port labserver is on |
| Source | `all` |
| Destination | **the VIP object** — not `all`, not a subnet |
| Service | **HTTPS (443) only** |
| Action | ACCEPT |
| NAT | **OFF** |

🚨 **Please keep this exactly this narrow — this is the Karla part.** A broad `any/any` rule here would undo the containment that's the entire reason you put the FortiGate in. Destination = the VIP object, service = 443, nothing else.

*Why NAT off:* with it on, every viewer appears to Jellyfin as coming from the firewall itself, which breaks per-user handling and makes the logs useless.

---

## 4. Then I do my two bits

Once 3.1–3.4 are in, tell me and I'll:

1. **Test from outside.** I'm at my house on a different connection, so I'm already external to your network — I can verify without you doing anything.
2. **Create the DNS record** for `jellyfin.datakiin.com` pointing at your public IP.
3. **Re-run the isolation test** — I do this after every change that touches firewall rules, and I'll do it again here.

Heads up: the DNS record **publishes your home IP address** to anyone who looks it up. That's normal for self-hosting and it's why the Minecraft server will use a different method (game servers attract people who DDoS home connections; Jellyfin viewers are just family). It reveals your ISP and rough area — not your address — and it does **not** expose anything on your network beyond the one port we forwarded.

---

## 5. Questions I can't answer from my side

1. **Is the FortiGate's WAN address static already, and what is it?** (3.1)
2. **What's the Comcast router's DHCP pool range?** So the static address can't collide with a lease later.
3. **Is Karla on her own VLAN/port**, or just on the regular house LAN? The isolation protects her *from labserver* either way — I'm asking whether you wanted more than that.
4. **Is her "company firewall" employer-issued kit?** If so I'll stay entirely out of it — that's their security domain.
5. **Managed switch or one FortiGate port per segment?** An unmanaged switch silently merges VLANs regardless of what the firewall UI says.
6. **Any support entitlement on the 40F?** Firewall/NAT/VIP all work unlicensed. What lapses is firmware updates — and FortiOS vulnerabilities cluster in SSL-VPN and the admin interface, so worth keeping SSL-VPN off and management off the WAN side.

> ⚠️ Also worth noting: WAN + house + labserver + Karla + an AP uplink = **5 of your 5 ports.** No spare.

---

## 6. Your Jellyfin settings — your call, not mine

I didn't change these. Two are worth doing before the family gets the URL:

**a) Check hardware acceleration is on.** *Dashboard → Playback → Transcoding → Hardware acceleration → NVIDIA NVENC.*

I verified your GPU works and can handle **8 simultaneous transcodes** — but I couldn't read the config file to see whether Jellyfin is set to *use* it. If it's off, every transcode runs on the CPU and you get about 3 streams instead of 8.

**b) Set per-user remote bitrate limits to 4 Mbps.** *Dashboard → Users → each user → remote bitrate limit.*

This is the single biggest thing you can do, and it's free — see the numbers below.

**c) ⚠️ Add Caddy to "Known proxies" — or (b) silently does nothing.** *Dashboard → Networking → Known proxies →* add **`172.20.0.4`**.

Here's the trap. Jellyfin decides whether someone is "remote" from their IP address. But everyone coming in over the internet now arrives **through the proxy**, so unless Jellyfin is told to trust it, every one of them looks like they're connecting from `172.20.0.4` — an address on the server's own network. Jellyfin would file them all as *local* and apply **no bitrate limit at all**.

Everything would look fine. The limit just wouldn't exist, and the first time a few people watch at full quality, the upload saturates and takes the house's internet with it.

I couldn't read this setting from my account, so it needs checking either way. Once we're live I can stream from outside while you watch the Jellyfin dashboard — if it shows my real IP rather than `172.20.0.4`, it's working.

---

## 7. How many people can actually watch — measured, not guessed

I measured your upload while you were away (it loads the connection, so I didn't want to do it while anyone was watching).

**Upload: 41 Mbps.** That's the real ceiling, and it's the constraint that matters — not the CPU, not the GPU, not the disks.

| Quality | Per stream | Simultaneous viewers |
|---|---|---|
| 720p | 4 Mbps | **8** |
| 1080p | 8 Mbps | **4** |
| 1080p direct play | 10 Mbps | 3 |
| 4K | 40 Mbps | **0** — one stream is your entire upload |

Your RTX 3060 can encode 8 streams; your internet can carry 4 at 1080p. **The hardware is not the limit — the upload is.** No upgrade to the machine changes any number in that table, which is why capping remote users at 720p is the one lever that genuinely helps: it takes you from 4 viewers to 8.

### ⚠️ What happens to everyone else in the house while people are watching

This is the part I'd think hardest about, and it's the one thing I'd want you to decide **before** the family gets the URL.

Four people watching at 1080p uses **32 of your 41 Mbps**. The problem isn't the 9 Mbps left over — it's what a nearly-full uplink does to the *rest* of the house:

- **Uploads being full slows downloads too.** Acknowledgement packets travel upstream; when they're stuck in a queue, downloads throttle as well.
- **Latency balloons.** With the uplink saturated, packets queue in the modem and round-trips go from ~10 ms to several hundred. Bandwidth still technically flows, but anything interactive feels broken.

| What someone's doing | How it feels |
|---|---|
| **Video call (Zoom/Teams)** | ⚠️ **Worst affected** — calls need upload, which is exactly what's gone. Freezing, choppy audio, drops. |
| Gaming | Bad latency spikes |
| Web browsing | Sluggish |
| Netflix / YouTube | Degraded, but least affected |

**Karla's work calls are the most exposed thing on that list.** I don't want the first sign of this to be a call dropping mid-meeting.

⚠️ **To be straight with you: the "headroom" in my table above does not protect the house.** It's margin so the *streams* don't stutter. Nothing automatically reserves bandwidth for anyone — Jellyfin and a video call compete as equals, and the greedier connection wins.

#### None of this applies to people watching *at home*

Worth being clear, because it changes how you'd think about usage: **anyone watching from inside the house doesn't touch the internet connection at all.** That traffic goes over local Ethernet at gigabit speed and never leaves the building.

| | Watching from outside | Watching at home |
|---|---|---|
| Uses your upload | ✅ yes — the scarce thing | ❌ **no** |
| Affects everyone else's internet | ✅ yes | ❌ no |
| Uses a GPU transcode slot | ✅ yes | ✅ yes |
| 4K | ❌ impossible — one stream > your whole upload | ✅ **fine** |

So 4K at home is comfortable and 4K remotely is off the table, on the same server. The only thing home viewers share with remote ones is the GPU's 8 transcode slots — and home clients usually direct-play, which doesn't use one.

📌 **Tell the household to use the local address, not `jellyfin.datakiin.com`.** If they use the public name from inside the house, their traffic tries to go out to the internet and loop back — which usually just fails, because most home routers don't support that. The public hostname is for family who are *away*.

#### The fix, free, on hardware you already own

**The FortiGate can traffic-shape.** Cap labserver's outbound traffic at ~25 Mbps and the house keeps ~16 Mbps no matter how many people are streaming. Jellyfin buffers instead of Karla's meeting breaking up — which is the right way round.

*Roughly: Policy & Objects → Traffic Shapers → create a shared shaper with a maximum bandwidth, then apply it to the outbound policy for labserver's segment.* You know FortiOS better than I do, so set it up however you normally would — the goal is just **"labserver never gets more than ~25 Mbps up."**

**I'd treat this as required rather than optional**, and I'm happy to help test it: I can generate load from outside and you can watch what the house connection does.

### If you ever want 10 people at 1080p

That needs about **100–125 Mbps upload**, roughly 3× what you have. Cable can't really do it — Xfinity's upload is capped well below download on almost every tier.

**Verizon Fios is symmetric** (upload = download) and covers ~99% of Dale City. The interesting part: their **cheapest** tier is already triple what you'd need.

| Plan | Upload | 1080p viewers | Price |
|---|---|---|---|
| **Fios 300/300** | 300 Mbps | ~24 | **$59.99/mo** |
| Fios 500/500 | 500 Mbps | ~40 | $84.99/mo |

**Entirely your call, and genuinely optional** — this is your bill, your house, and switching ISPs means downtime plus redoing the FortiGate WAN setup. I'm only flagging it because depending on your current Xfinity plan, Fios 300 might cost you the *same or less* for about 7× the upload. Worth a look at your bill; not worth doing for me.

💡 **The stronger reason isn't the viewer count — it's the section above.** On 300 Mbps symmetric, Jellyfin physically can't saturate your uplink, so the "Karla's call breaks up because someone started a movie" problem stops existing instead of needing to be managed with traffic shaping. If you do switch, the shaper becomes unnecessary. If you don't, the shaper is the answer and it works fine.

*(Prices are advertised rates as of Aug 2026 — check the post-promo price.)*

---

## 8. How to undo any of it

Every piece is independently reversible:

| To undo | Do this |
|---|---|
| **Close public access immediately** | Disable the FortiGate policy from 3.4. One click, instant. |
| Remove the forwards | Delete the VIP, then the router rule |
| Stop Caddy | `sudo docker stop caddy` — Jellyfin keeps working normally on your LAN |
| Remove Caddy entirely | `cd /srv/datakiin/stacks/caddy && sudo docker compose down` |
| Put Ollama back on all interfaces | the original config is backed up next to the current one |

Stopping Caddy does **not** affect Jellyfin, Samba, your media, or anything else you use.

---

## 9. The one thing I'd ask you to double-check

After you've made the FortiGate changes, I'll re-run the isolation test — but I'd rather you also eyeball the policy list yourself. FortiOS policies are **ordered, first-match**, so a correctly-written narrow rule sitting *below* a broader one does nothing at all. Worth confirming the new policy is where you expect in the list, not just that it exists.

That's the part protecting Karla's machines, so it's the part worth being fussy about.
