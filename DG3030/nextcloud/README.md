# `nextcloud/` — movie + home-video ingest

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

## Two libraries, because the type decides the behaviour

Jellyfin's library **type** controls whether it scrapes metadata, so the two
kinds of content cannot share a folder.

| Folder | Jellyfin library type | For |
|---|---|---|
| `/srv/datakiin/data/media/movies` | **Movies** | Commercial films — gets posters, cast, synopsis from TMDB |
| `/srv/datakiin/data/media/home-videos` | **Home Videos & Photos** | Family footage — no scraping, no failed matches |

Put family footage in a Movies library and Jellyfin tries to match
`Christmas 2004.mkv` against TMDB, fails, and displays it as an unidentified
mess. Put a real film in a Home Videos library and you get no poster, no
synopsis, no metadata at all.

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
sudo mkdir -p /srv/datakiin/data/media/{movies,home-videos}
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
2. *Administration settings* → *External storage* → add two mounts:
   - `Movies` → Local → `/media/movies`
   - `Home Videos` → Local → `/media/home-videos`
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
