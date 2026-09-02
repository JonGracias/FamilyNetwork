# `nextcloud/` — movie, home-video + music ingest

Authenticated upload point at **`cloud.datakiin.com`**. Contributors upload
large files; they land directly in the folders Jellyfin scans.

**Danny does not use this.** He is on the LAN and already has a writable Samba
share (`\\labserver\Media`) — gigabit, no size limit, nothing in the path.
Point him there.

## Why Nextcloud and not something lighter

Uploads are multi-GB and batchy, over residential upload links. A plain form
upload is a single POST: if it dies three hours in, it starts over. Nextcloud
chunks and resumes. That is the whole reason for the extra weight of a
database and a Redis instance.

## Three libraries, because the type decides the behaviour

Jellyfin's library **type** controls whether it scrapes metadata, so the three
kinds of content cannot share a folder.

| Folder | Jellyfin library type | For |
|---|---|---|
| `/srv/datakiin/data/media/movies` | **Movies** | Commercial films — gets posters, cast, synopsis from TMDB |
| `/srv/datakiin/data/media/home-videos` | **Home Videos & Photos** | Family footage — no scraping, no failed matches |
| `/srv/datakiin/data/media/music` | **Music** | 🆕 Jose's collection — see below |

Put family footage in a Movies library and Jellyfin tries to match
`Christmas 2004.mkv` against TMDB, fails, and displays it as an unidentified
mess. Put a real film in a Home Videos library and you get no poster, no
synopsis, no metadata at all.

### 🎵 Music — added 2026-09-02

**The requirement:** Jose wants to replace Spotify with music he already
owns. That is a different shape of problem from the video libraries and it
changes several assumptions.

**Music is effectively free on the VPS link.** This is the one library that
costs nothing to worry about:

| Content | Rate | GB/hour | Hours per 1 TB |
|---|---|---|---|
| MP3 320 kbps | 0.32 Mbps | 0.14 | **~7,100** |
| FLAC (lossless) | ~1 Mbps | 0.45 | **~2,200** |
| *(1080p video, for contrast)* | *8 Mbps* | *3.6* | *277* |

Four hours a day of FLAC, every day, is about **54 GB/month** — roughly 5% of
the quota. Video is the only thing that can exhaust the transfer allowance;
music never will.

**Audio transcoding uses the CPU, never NVENC.** The measured 8-session cap is
video-only, so music cannot compete with anyone watching a film. The i7
handles audio transcodes without noticing. And the recommended 10–12 Mbps
remote bitrate cap sits ~10× above any audio bitrate, so **one policy covers
both** — no separate music tier is needed.

**⚠️ Tags matter more than filenames here, unlike the video libraries.**
Jellyfin parses the *path* for films but reads embedded **ID3 / Vorbis tags**
for music. A collection accumulated over years will have uneven tagging, and
that — not the folder layout — decides whether the result looks like Spotify
or like a junk drawer. Run it through **MusicBrainz Picard** *before* import;
fixing it afterwards means re-scanning the library.

Folder layout that Jellyfin expects:

```
music/
  Artist Name/
    Album Name (Year)/
      01 Track Title.flac
```

**📱 Use Finamp, not the Jellyfin app.** The main Jellyfin client is built
around video and is poor for music. Finamp (iOS/Android) is a dedicated
Jellyfin music client with proper queues, playlists and album browsing.

🎯 **Finamp's offline downloads are the real bandwidth lever.** An album
downloaded once over Wi-Fi plays all month for zero further transfer, which
turns even the heaviest music user into a rounding error against the quota.

**⚠️ Set expectations: this replaces Spotify's library, not its discovery.**
No algorithmic recommendations, no Discover Weekly, no new releases he does
not already own. Jellyfin offers playlists and an "Instant Mix" shuffle and
little else. A straight upgrade for replaying an owned collection — no
substitute for finding new music.

**Storage goes on `/srv/datakiin`**, same as the other two, because `/mnt/media`
is owned by `deks` and `jony` cannot write there. Music is small relative to
video, so the 3.6 TB free is a non-issue.

#### ✅ Ingest decided 2026-09-02 — Jose is REMOTE

He is not on the house LAN, so **Samba is not available to him** and Nextcloud
is his path. That is the whole reason this stack exists; Danny, who *is* on the
LAN, should still be pointed at the Samba share instead.

**Two different problems, two different answers:**

| | Route | Why |
|---|---|---|
| **Initial bulk load** | 🚚 **Sneakernet — a USB drive** | Days of upload, and ~30% of a month's VPS transfer |
| **Every addition after** | 🌐 **Nextcloud web UI** | Seconds to minutes; the network path is right for this |

**The incremental case is a non-issue.** Ten songs is ~100 MB as MP3 320 or
~350 MB as FLAC — under a minute to a few minutes on any normal upload, and
0.035% of the monthly quota at worst. Nextcloud chunks and resumes, so a flaky
link handles that size without trouble.

⚠️ **Uploads consume the VPS transfer quota too, roughly 1:1 — this is not
obvious.** Linode meters outbound only, so an upload *looks* free. But traffic
passing through a relay leaves twice: it arrives from the contributor on `eth0`
(free), then the VPS forwards it down the WireGuard tunnel to labserver, which
**exits on `eth0` as encapsulated UDP and is metered**. The counters show this
shape already (`eth0 rx 1.73 GB` vs `wg0 rx 1.65 GB`). Irrelevant for ten songs;
decisive for a 300 GB library. **Confirm it empirically** with
`vnstat -i eth0 -m` either side of a known-size upload before trusting the 1:1.

🚚 **The open question on sneakernet is delivery.** "Carry a drive over" assumes
physical proximity that a remote contributor does not have — the drive has to be
mailed to Danny or wait for a visit. If neither is practical, uploading over the
network is the fallback: budget days, and **split it across two billing months**
rather than discovering Linode's overage rate the expensive way. (That rate is
still unrecorded — see the VPS README.)

⚠️ **Do not point the Nextcloud desktop sync client at the music folder.** Sync
is bidirectional; he would pull the entire library back down. That is the same
mirroring trap that got Syncthing rejected for this job. **Web UI upload only**
for contributors.

### Naming, for the Movies library only

Jellyfin matches on the folder and file name. This layout works:

```
movies/
  The Thing (1982)/
    The Thing (1982).mkv
```

If a title matches wrongly (remakes and common words are the usual culprits),
pin it by ID and Jellyfin stops guessing:

```
  The Thing (1982) [imdbid-tt0084787]/
```

⚠️ **Uploads do not arrive correctly named.** Someone has to rename into this
shape after upload — Nextcloud's web UI does it fine. Budget for that step;
it is the real ongoing friction in this setup, not the transfer.

Home videos need none of this. Any filename works.

## Prepare the host first

```bash
sudo mkdir -p /srv/datakiin/data/media/{movies,home-videos,music}
sudo mkdir -p /srv/datakiin/data/nextcloud/{html,db}

# Owner jony, group www-data(33) so BOTH can write; setgid so new files
# inherit the group; other-readable so jellyfin (uid 101) can read them.
sudo chown -R 1001:33 /srv/datakiin/data/media
sudo chmod -R 2775    /srv/datakiin/data/media
```

## Deploy — Caddy moves WITH this stack, not before it

📌 **RESOLVED 2026-09-02 — the drift is gone and the wildcard cert is already
issued.** This section used to warn that the repo Caddyfile was deliberately
ahead of the box (box `0e3598de…` single-site, repo `a5575a0b…` wildcard). The
VPS cutover deployed the wildcard version, so labserver now runs
`10694b9a…` — which **already contains the `cloud.datakiin.com` handler** and
holds a live `*.datakiin.com` certificate valid to 1 Dec 2026.

**What that changes for this stack:** deploying Nextcloud no longer triggers a
certificate event, and no Caddy change is required at all. `cloud.datakiin.com`
is already routed — it simply returns **502** until the `nextcloud` container
exists on the `edge` network. Bring the stack up, add the DNS record, done.

⚠️ **One thing did not change:** the Caddyfile reaches Nextcloud by **container
name** over `edge`, so the container must be named `nextcloud` and must join
that network, or the 502 persists with a healthy-looking Caddy.

```bash
# 1. Nextcloud first -- Caddy's new site block references it by container
#    name, so bring it up before Caddy tries to resolve "nextcloud".
cd /srv/datakiin/stacks/nextcloud
cp .env.example .env && $EDITOR .env      # fill both passwords
sudo docker compose up -d

# 2. Then push the Caddyfile and reload.
#    (copy the repo Caddyfile to /srv/datakiin/stacks/caddy/Caddyfile first)
cd /srv/datakiin/stacks/caddy
sudo docker compose restart caddy
```

Then verify, from a machine that is NOT labserver — the issuer check is the
part that matters, because Caddy falls back to its own internal CA when ACME
fails and that fallback serves HTTPS perfectly happily:

```bash
curl -sS --resolve cloud.datakiin.com:443:192.168.50.10   -o /dev/null -w "http=%{http_code} verify=%{ssl_verify_result}
"   https://cloud.datakiin.com/
```

Expect `verify=0` and a `Let's Encrypt` issuer. Anything else means the
wildcard did not issue and Caddy is serving its self-signed fallback.

## Wire the folders in — the step that makes this work

Uploads must land as **real files with real names** on disk, not inside
Nextcloud's internal store, or Jellyfin will never see them.

1. Sign in as admin → *Apps* → enable **External storage support**
   (`files_external`, bundled).
2. *Administration settings* → *External storage* → add three mounts:
   - `Movies` → Local → `/media/movies`
   - `Home Videos` → Local → `/media/home-videos`
   - `Music` → Local → `/media/music`
   - Available for: the group you give contributors
3. Upload a test file, then confirm it exists on the host:

```bash
ls -l /srv/datakiin/data/media/movies/
```

## Point Jellyfin at them

Add **two new libraries** to Danny's existing Jellyfin — do not touch his.
`/mnt/media` is owned by `deks` and `jony` cannot write there; that stays as
it is. These live on Jon's own drive instead, which is the writable half of
the arrangement.

Verify Jellyfin can actually read an uploaded file:

```bash
sudo -u jellyfin cat /srv/datakiin/data/media/movies/<file> > /dev/null && echo READABLE
```

If that fails, the permission block above did not take.

## Confidentiality in transit — what protects it

The requirement is narrow and already met: **nobody outside the family
network can read what is being sent.** Danny can; he owns the machine and
that is fine.

| Hop | Protection |
|---|---|
| Uploader's browser → Caddy | **TLS 1.3**, real Let's Encrypt cert, validated against the public trust store |
| Across the rented VPS | **ciphertext only** — TLS terminates on labserver, not the VPS, so the provider relays bytes it cannot read |
| Caddy → Nextcloud | container-to-container on the `edge` bridge, never leaves the host |
| Jellyfin playback | same TLS path — watching is protected identically to uploading |

`Strict-Transport-Security` on this host blocks a downgrade attack, where an
attacker strips TLS on the first connection and the user never notices.

**What an on-path observer still learns:** the hostname (TLS SNI is sent in
the clear), plus sizes and timing. Not content. Fixing SNI would require
Cloudflare's Encrypted Client Hello, which means proxying media through
Cloudflare — deliberately rejected elsewhere in this project.

⚠️ **Never move a private service onto the Cloudflare tunnel.** Cloudflare
terminates TLS at its edge, so it can read anything passing through — fine for
`lab.datakiin.com`, which is public static content, and disqualifying for
Nextcloud or Jellyfin. This is a second, independent reason those stay on the
VPS path, alongside the video terms-of-service issue.

**Danny's Samba path is not encrypted**, but it never leaves his LAN — it goes
house → FortiGate → labserver over Ethernet and never touches the internet.
That is inside the boundary being defended here. (Samba 3 can encrypt with
`smb encrypt = required`, at a throughput cost. His service, his call.)

**Not needed for this threat model:** disk encryption at rest, Nextcloud's
E2EE app (which would break Jellyfin playback outright), and anonymous upload
links. Keep normal accounts — they give quotas and abuse control at no
privacy cost, since the concern is outsiders, not the server operator.
