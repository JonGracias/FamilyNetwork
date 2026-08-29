# Runbook — publish `jellyfin.datakiin.com` (the port-forward chain)

> 🔴 **STOP — STALE AS OF 2026-08-29.** Danny's house moved from **Comcast to Verizon Fios**, so `10.0.0.1`, the `10.0.0.x` FortiGate WAN address, and the public IP `73.132.162.205` used throughout this runbook **no longer exist**. The *shape* of the chain is still correct (two NATs in series; the VIP's external IP is the FortiGate's own WAN address, never the public one) — but every *value* below must be re-measured before anyone follows a step, and the Step 5 `--resolve` checks currently target a dead address. **Do not hand this to Danny in its current state.** See the 2026-08-29 entry in [`CLAUDE.md`](CLAUDE.md).

**Goal:** make Caddy on labserver reachable from the internet on TCP 443.
**Status of everything else:** ✅ done — Caddy is deployed, holds a real Let's Encrypt cert, and serves Jellyfin correctly on `192.168.50.10:443`. This runbook is the last hop.

**Who does what: Danny does Steps 1–4.** Both devices are at his house — the Comcast router (`10.0.0.1`) *and* the FortiGate — and Jon has no network path to either. Jon does Step 5 (verification from Romulus) and Step 6 (DNS, in Cloudflare).

> ⚠️ **This is a double-NAT setup.** Two devices do NAT in series:
> ```
> internet → Comcast router (10.0.0.1) → FortiGate WAN (10.0.0.x) → labserver (192.168.50.10)
> ```
> Both must forward, and **the FortiGate's VIP "external IP" is its own WAN address (`10.0.0.x`), NOT the public IP `73.132.162.205`.** Getting this wrong is the single most common failure here — the public IP belongs to the Comcast router, which is the only device that ever sees it.

---

## Order of operations

Build the forward **before** creating the DNS record. The test in Step 5 works without any DNS, so you can prove the door works first — and the A record (which publishes Danny's home IP) only goes live once there's something behind it.

---

## Step 1 — Pin the FortiGate's WAN address *(do this first)*

❓ **First, ask Danny — he may have already done this.** He installed and configured the FortiGate himself, including the house→labserver rule, so a static WAN is entirely plausible. **We cannot see it from our side**: the address lives on the house LAN, labserver is deliberately blocked from `10.0.0.1`, and the FortiGate's admin interface is **not listening toward labserver** (80/443/8080 all closed — good hygiene on his part, and it also means we cannot self-serve the answer).

- **If it is already static:** record the value, skip to Step 2, and use that address everywhere below.
- **If it is a DHCP lease:** pin it now, as below.

Everything downstream points at this address, so it must stop moving.

✅ **What we *did* verify (2026-08-14, TTL-limited probe from labserver):**

```
ttl=1  192.168.50.1     the FortiGate
ttl=2  10.0.0.1         the Comcast router   <-- confirms the double NAT
ttl=4  68.87.137.141    Comcast infrastructure
```

So the FortiGate **definitely has an interface on `10.0.0.0/24`** and definitely sits behind the house router. What remains unknown is only *which* address it holds and whether it is static.

On the **FortiGate**, set the WAN interface to a **static** address:

| Field | Value |
|---|---|
| Addressing mode | **Manual / Static** |
| IP / Netmask | e.g. **`10.0.0.2/24`** — pick something **outside** the Comcast DHCP pool |
| Gateway | `10.0.0.1` |
| DNS | `1.1.1.1` / `8.8.8.8` (or the router) |

> Setting it statically on the FortiGate depends on nothing from Comcast's app. (A DHCP reservation on the router would also work — the earlier "Comcast can't do reservations" note in our docs was wrong — but the static side is fewer moving parts.)

⚠️ **A drifting WAN lease is the classic silent failure.** It breaks the public door weeks or months later, long after anyone connects the two events.

**Verify:** the FortiGate still reaches the internet after the change, and labserver still has connectivity.

---

## Step 2 — Comcast router: forward 443 to the FortiGate

On the Comcast/Xfinity gateway (`10.0.0.1`, or the Xfinity app):

| Field | Value |
|---|---|
| Service / name | `labserver-https` |
| Protocol | **TCP** |
| External port | **443** |
| Internal port | **443** |
| Destination IP | the FortiGate WAN address from Step 1 (e.g. `10.0.0.2`) |

**Do NOT forward port 80.** DNS-01 issuance means there is no HTTP-01 challenge, now or later. Port 80 buys nothing and costs a hole. *(Comcast blocks inbound 80 on residential anyway — another reason the DNS-01 design was right.)*

**Optional — UDP 443 for HTTP/3.** Caddy advertises `alt-svc: h3=":443"` and its UDP socket is published. If you don't forward UDP 443, clients try HTTP/3, fail, and fall back to TCP — it works, with a small delay on first connection. Either add a second rule for **UDP 443**, or leave it and accept the fallback.

---

## Step 3 — FortiGate: create the VIP

*Policy & Objects → Virtual IPs → Create New → Virtual IP.* (Menu path varies slightly by FortiOS version.)

| Field | Value |
|---|---|
| Name | `vip-labserver-https` |
| Interface | the **WAN** interface |
| Type | **Static NAT** |
| External IP address/range | **the FortiGate's WAN IP** (`10.0.0.2`) — ⚠️ **not** `73.132.162.205` |
| Mapped IP address/range | **`192.168.50.10`** |
| Port forwarding | ✅ **enabled** |
| Protocol | **TCP** |
| External service port | **443** |
| Map to port | **443** |

If you forwarded UDP 443 in Step 2, create a **second VIP** identical to this one but with protocol **UDP**.

---

## Step 4 — FortiGate: the firewall policy *(the VIP does nothing without this)*

A VIP is only a translation rule. Traffic is still denied until a policy permits it.

*Policy & Objects → Firewall Policy → Create New.*

| Field | Value |
|---|---|
| Name | `wan-to-labserver-https` |
| Incoming interface | **WAN** |
| Outgoing interface | the port/VLAN **labserver** is on |
| Source | `all` |
| Destination | **the VIP object** (`vip-labserver-https`) — *not* `all`, *not* a subnet |
| Service | **HTTPS** (443) only — add the UDP service too if using HTTP/3 |
| Action | **ACCEPT** |
| NAT | **OFF** |

⚠️ **Keep it exactly this narrow.** Destination = the VIP object, service = 443. An `any/any` rule here is how a DMZ quietly stops being a DMZ.

⚠️ **NAT must be OFF.** Enabling it source-NATs inbound traffic so every request appears to come from the FortiGate — which breaks Jellyfin's per-client logic and destroys any useful logging.

⚠️ **FortiOS policies are ordered, first-match.** A correct policy sitting below a broader one does nothing. Check its position in the list, not just its contents.

---

## Step 5 — Verify from genuinely outside

"Outside" means **outside Danny's house**, because that is where the NAT chain lives. Which vantage point you need depends on who is testing:

| Tester | Where they are | What to use |
|---|---|---|
| **Jon** | Romulus, his own house — **already external to Danny's network** | ✅ Just run it from Romulus. No cellular needed. |
| **Danny** | inside the house being tested | ⚠️ **Must** use cellular with Wi-Fi off — see below |

This test works **before the DNS record exists**, because `--resolve` supplies the address directly.

**From Romulus (PowerShell):**

```powershell
curl.exe -sv --resolve jellyfin.datakiin.com:443:73.132.162.205 https://jellyfin.datakiin.com/System/Info/Public
```

⚠️ **`curl.exe`, not `curl`** — in PowerShell, bare `curl` is an alias for `Invoke-WebRequest`, which does not understand `--resolve` and will throw a confusing parameter error.

**From Linux/macOS/labserver:**

```bash
curl -sv --resolve jellyfin.datakiin.com:443:73.132.162.205 https://jellyfin.datakiin.com/System/Info/Public
```

**Expected:** HTTP 200, JSON naming `"ServerName":"labserver"` and `"ProductName":"Jellyfin Server"`, with a valid Let's Encrypt cert and no TLS warning.

✅ **This test cannot false-pass over Tailscale, which is why it is trustworthy from Romulus.** Two independent reasons: the target `73.132.162.205` is a public address, not a `100.64.0.0/10` tailnet one, and labserver advertises no subnet routes (`AdvertisedRoutes: None`, a standing rule). More conclusively — **443 is bound to `192.168.50.10` only and is verified *refused* over the tailnet.** There is no tailnet path to port 443 that could produce a spurious 200. A success here is the public path or nothing.

🚫 **Danny must not test from inside the house.** Consumer routers routinely fail hairpin NAT, so a perfectly good forward looks broken from the couch, and an inside failure proves nothing. If he needs to test, the options are: **phone on cellular with Wi-Fi off**, or **tether a laptop to that phone's hotspot** (a real terminal on a real external path — the better choice, since a phone browser can't do `--resolve` and the hostname does not resolve yet).

**Reading a failure:**

| Symptom | Most likely cause |
|---|---|
| Connection **times out** | A forward is missing or points at the wrong address — Step 2 or Step 3 |
| Connection **refused** | Reached something, but nothing is listening — wrong destination IP in the VIP |
| TLS error / wrong cert | You reached a *different* device — almost always the VIP's external IP is set to the public IP instead of the FortiGate's WAN IP |
| 502 from Caddy | The door works; the Caddy→Jellyfin hop is the problem (see CLAUDE.md) |

---

## Step 6 — Only now, create the DNS record

Once Step 5 passes, add the A record (details in [CLAUDE.md](CLAUDE.md) → "The two steps still needed"):
`jellyfin` → `73.132.162.205`, **DNS-only / grey cloud**, and mind the DDNS gap — Danny's WAN has no dynamic-DNS updater, so a bare A record is correct only until his lease changes.

Re-test with plain `curl https://jellyfin.datakiin.com/System/Info/Public` (no `--resolve`) to confirm DNS resolves to the same working path.

---

## Step 7 — 🚨 Re-run the isolation test *(not optional)*

A new firewall policy is exactly the event that can silently widen reach, and this project has already seen two security properties die to routine changes. **Prove Karla's isolation still holds.** On labserver:

```bash
for p in 80 443 53; do timeout 3 bash -c "echo > /dev/tcp/10.0.0.1/$p" 2>/dev/null && echo "$p REACHABLE - BROKEN" || echo "$p blocked (good)"; done; ping -c2 -W2 10.0.0.1 >/dev/null 2>&1 && echo "ICMP REACHABLE - BROKEN" || echo "ICMP blocked (good)"; timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/443' 2>/dev/null && echo "internet OK" || echo "internet DOWN"
```

**Expected:** `10.0.0.1` blocked on ICMP **and** all three TCP ports, `1.1.1.1:443` reachable. ICMP alone is a false pass — test both.

---

## Step 8 — Before handing the URL to family

- Jellyfin → **Networking**: confirm remote connections are allowed.
- Jellyfin → **Users** → per-user **remote bitrate cap**. Capping remote streams at **4 Mbps / 720p** roughly doubles how many people fit in Danny's upload — a far bigger lever than any infrastructure change, and the uplink is the binding constraint.
- Every account needs a **real password**. The network no longer gates anything; application auth is the only control left.

---

## Rollback

Undo in reverse — each step is independently reversible:

1. Disable the FortiGate policy (Step 4) — instantly closes the door, VIP and forwards left intact.
2. Delete the VIP (Step 3).
3. Remove the router forward (Step 2).
4. Delete the DNS record if it was created.

Disabling the policy alone is enough to shut off public access in one click, which makes it the right panic button.
