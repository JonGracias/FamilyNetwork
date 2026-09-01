# WireGuard relay: getting services out through the double NAT

## The short answer: you almost certainly do not need Danny

The instinct — "we're double NATed, so someone has to forward a port, and Danny
owns the outer router" — is correct for the *direct* approach and is exactly why
that approach is the wrong one here. A VPS relay removes the dependency entirely.

WireGuard between home and a VPS is established by the **home** box dialling
**out**. Outbound UDP already works through both layers of NAT — it is the same
mechanism that lets a browser load a page. Once that tunnel is up it is
bidirectional, so the VPS can push traffic back down it to reach home.

Nothing inbound is ever opened at home. **No forward on Danny's router, and none
on the inner router either.**

```
            player                          Danny's router      your router
              |                                    |                 |
              v                                    v                 v
   survival.datakiin.com:25569            +--------------------------------+
              |                           |     double NAT, unchanged      |
              v                           |     nothing forwarded here     |
    +-------------------+                 +--------------------------------+
    |       VPS         |                              ^
    |  public IP        |                              |
    |  wg0 = 10.8.0.1   |  <=== WireGuard tunnel ======+
    |  nftables DNAT    |       (opened OUTBOUND by Romulus,
    +-------------------+        held open by PersistentKeepalive)
                                             |
                                             v
                                   Romulus  wg0 = 10.8.0.2
                                   Minecraft / Jellyfin / web
```

## What is actually broken today

Measured 2026-09-01 from DNS (public records, no access to your machines needed):

| Name | Resolves to | Meaning |
|---|---|---|
| `survival.datakiin.com` | CNAME -> `home.datakiin.com` -> `76.100.245.192` | **points at the house**, behind the double NAT |
| `home.datakiin.com` | `76.100.245.192` | the residential WAN address |
| `datakiin.com`, `play.datakiin.com`, `api.datakiin.com` | Cloudflare (`2606:4700:...`) | already fronted by Cloudflare |
| `vps.` / `wg.` / `mc.` / `jellyfin.` `.datakiin.com` | *(no record)* | **no VPS is in DNS yet** |

So the installers already shipped to players (`survival.datakiin.com:25569` for
normal-survival, `:25568` for superflat) point at an address that cannot accept
inbound connections. That is the bug. The relay fixes it by making that name
resolve to something that *can*.

> **Not verified:** whether those ports are open, and whether a VPS exists at
> all. Port reachability could not be tested from the environment this was
> written in (it has no arbitrary outbound TCP — every control host failed too,
> so a "closed" result there means nothing). Run `vps-check.sh` on the VPS, and
> test reachability from a phone on cellular with wifi off.

## Steps

1. **A VPS with a real public IP.** Any $5/mo box. Confirm with `vps-check.sh` —
   it flags a VPS that is itself behind NAT/CGNAT, which cannot relay.
2. **On the VPS**, `bash vps-check.sh` first. It changes nothing and tells you
   which of the following you still need.
3. **On the VPS**, install WireGuard, generate a server key, and create
   `/etc/wireguard/wg0.conf`:
   ```ini
   [Interface]
   Address    = 10.8.0.1/24
   ListenPort = 51820
   PrivateKey = <server private key>
   ```
   Open **UDP 51820** in the provider's cloud firewall *and* in ufw. This is the
   one genuinely public port, and it is the only one — WireGuard does not reply
   to unauthenticated packets, so it does not answer scanners.
4. **On Romulus**, run `setup-romulus-wg.ps1 -VpsEndpoint <vps>:51820`. It prints
   Romulus's public key and stops. Add the printed `[Peer]` block to the VPS,
   `systemctl restart wg-quick@wg0`, then re-run the script with
   `-VpsPublicKey '<vps server public key>'` to finish.
5. **On the VPS**, edit `portmap.conf`, then `sudo bash vps-apply-portmap.sh`.
6. **DNS cutover** — see below.

## The port map, and "do we have to tie it to one instance?"

No. That is what the ranges in `portmap.conf` are for.

`minecraft-java` forwards **25560-25579** as a block. Adding a new world is then
a purely local change: bind the server to any free port in that range and it is
public immediately — no VPS edit, no re-apply, no downtime, nobody logged into
anything. Same for `minecraft-voice` on **24450-24469** (Simple Voice Chat needs
one UDP port per server; set `port=` in each world's
`config/voicechat/voicechat-server.properties`).

The two ports already baked into shipped installers are inside the range and
must keep their numbers: **25568 superflat**, **25569 normal-survival**.

To remap something, edit one line and re-run `vps-apply-portmap.sh`. The whole
nftables table is replaced atomically, so it is safe to re-run any time, and it
only ever touches its own table — ufw and anything else are left alone.

### Websites, API and Jellyfin

These are `enabled no` in `portmap.conf` on purpose, because they are a
different shape of problem: you cannot DNAT port 443 to two different sites.
Route by *hostname* instead — forward 80/443 once to a reverse proxy (Caddy or
nginx) at home, and let it dispatch `site-a`, `site-b`, `api` and `jellyfin` by
`Host:` header. One rule, unlimited sites.

Note that `datakiin.com` / `play.datakiin.com` / `api.datakiin.com` currently sit
behind Cloudflare, so only enable `web-http`/`web-https` once you have decided
whether Cloudflare's origin should become the VPS. Nothing about the Minecraft
ports depends on that decision — do the game ports first.

### SSH

`ssh-romulus` is deliberately `no`. Do not publish port 22. The tunnel *is* the
admin path: bring WireGuard up on your laptop as a second peer and `ssh 10.8.0.2`
from anywhere. That is strictly less exposed than a public SSH port and matches
the least-exposure rule in the top-level `CLAUDE.md`.

## DNS cutover

Once `vps-check.sh` is clean and the handshake is up, repoint the game name at
the VPS. Keep `home.datakiin.com` as-is — other things may reference it.

```
survival.datakiin.com.  A  <vps public ip>     # was: CNAME home.datakiin.com
```

Set TTL low (300s) before the change so you can roll back quickly. If
`survival.datakiin.com` is a Cloudflare record, it must be **DNS-only (grey
cloud)** — Cloudflare's orange-cloud proxy handles HTTP only and will silently
break a Minecraft connection.

## What this does and does not do for security

Worth being explicit, since the double NAT is currently doing real work for you:

- The double NAT **stays**. The house remains unreachable from the internet.
  This design does not punch a hole in it, which is precisely why it is better
  than asking Danny to forward ports.
- What *is* exposed moves to the VPS, which is a machine you can firewall,
  patch, and rebuild — and if it is ever compromised, the attacker lands on a
  throwaway box that can only reach the specific ports in `portmap.conf`, not
  the LAN.
- But be clear-eyed: every line you set to `yes` is a service genuinely
  reachable from the whole internet. NAT is no longer protecting those. Their
  own auth and patch level is the protection. That is a real change in posture
  and the reason `ssh`, Jellyfin and the websites start disabled.
- Because the VPS masquerades, servers at home see the connection coming from
  `10.8.0.1` rather than the player's real IP. Minecraft per-IP bans and
  rate-limits are therefore ineffective; the whitelist still works normally.

## If you would rather involve Danny anyway

The alternative is forwarding on both routers: Danny forwards each port on the
outer router to your router's WAN address, and you forward it again to Romulus.
It works, but it is worse on every axis — it needs Danny for every new port,
publishes your home IP, breaks whenever either router's DHCP lease moves, gives
up the double-NAT protection you specifically want to keep, and still cannot do
name-based routing for the two websites.

The one thing genuinely worth asking Danny: **do not** let him put your router in
the outer router's DMZ as a "simpler" fix. That forwards *every* port to you and
is far more exposure than any of this.

## Verify

```bash
# on the VPS
sudo bash vps-check.sh                 # all green
wg show wg0                            # "latest handshake" within ~2 min
ping 10.8.0.2                          # Romulus answers through the tunnel
nft list table ip familynet_portmap    # rules present

# from a phone on CELLULAR, wifi OFF  (testing from inside the house proves nothing)
nc -vz survival.datakiin.com 25569
```

If the handshake is up but a port does not answer, the cause is almost always
one of three things, in this order: `net.ipv4.ip_forward` is 0; ufw's
`DEFAULT_FORWARD_POLICY` is `DROP`; or the Windows firewall on Romulus is not
allowing the tunnel subnet. `vps-check.sh` reports the first two, and
`setup-romulus-wg.ps1` fixes the third.
