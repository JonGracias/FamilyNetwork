#!/usr/bin/env bash
# =============================================================================
# scaffold-datakiin-env.sh
# Builds the /srv/datakiin working environment: docs, container stacks, and
# project slots. ARCHITECTURE ONLY -- creates no containers and starts no
# services. Nothing here touches the running Jellyfin/Samba install.
#
# Idempotent: safe to re-run. Existing files are left alone unless --force.
#   bash scaffold-datakiin-env.sh
# =============================================================================
set -euo pipefail

ROOT="${DATAKIIN_ROOT:-/srv/datakiin}"
DOMAIN="${DATAKIIN_DOMAIN:-datakiin.com}"
FORCE="${1:-}"

[ -d "$ROOT" ] || { echo "ERROR: $ROOT does not exist or is not mounted."; exit 1; }
mountpoint -q "$ROOT" || echo "WARNING: $ROOT is not a mountpoint -- continuing anyway."

w() { # w <path> <<'EOF' ... EOF   -- write file unless it exists
  local p="$1"
  if [ -e "$p" ] && [ "$FORCE" != "--force" ]; then echo "  skip (exists): ${p#$ROOT/}"; cat >/dev/null; return; fi
  mkdir -p "$(dirname "$p")"; cat > "$p"; echo "  wrote: ${p#$ROOT/}"
}

echo "Scaffolding $ROOT (domain: $DOMAIN)"
mkdir -p "$ROOT"/{stacks,projects,data,backups,docs,bin,secrets}
mkdir -p "$ROOT"/stacks/{cloudflared,ollama,jellyfin,immich,nextcloud}
mkdir -p "$ROOT"/projects/{linenlady,minecraftserver}
mkdir -p "$ROOT"/data/{ollama,jellyfin,immich,nextcloud}
chmod 700 "$ROOT/secrets"

# ---------------------------------------------------------------- CLAUDE.md --
w "$ROOT/CLAUDE.md" <<EOF
# Datakiin Environment (labserver:$ROOT)

Jon's working environment on **labserver**, living on the dedicated 4 TB drive
labelled \`DATAKIIN\` (mounted at \`$ROOT\` by UUID). Self-hosted services run
here in containers, fronted by Cloudflare Tunnel (web) and playit.gg (games).

Repo-side companion: \`FamilyNetwork/DG3030/CLAUDE.md\` (host + network facts).

## Ground rules

- **Architecture first.** Stacks are authored here but **not deployed**. Nothing
  is started until explicitly decided, service by service.
- **Don't disturb the host.** Danny's native Jellyfin + Samba are running on this
  box. Do not stop, reconfigure, or port-collide with them.
- **Two tiers, always.** Decide a service's tier *before* writing its stack:
  - **Public** -- reachable by anyone, origin IP hidden. Web via Cloudflare
    Tunnel; games via playit.gg (tunnels are HTTP-only, they cannot carry
    Minecraft traffic).
  - **Private** -- family only, bound to the Tailscale/LAN interface, never
    published. Membership in the mesh *is* the auth.
- **Bind deliberately.** Private services bind \`127.0.0.1\` or the tailnet IP,
  never \`0.0.0.0\`. The box holds a public IPv6.
- **Data lives under \`$ROOT/data/\`**, not inside containers.
- **Secrets never get committed.** \`$ROOT/secrets/\` is 0700 and gitignored.
- **This drive is a used enterprise disk** (~5.3 yrs powered-on, media clean).
  Fine for working data; **never the only copy** of anything irreplaceable.

## Layout

\`\`\`
$ROOT/
|- CLAUDE.md          this file
|- stacks/            one compose stack per service (authored, NOT running)
|  |- cloudflared/    the public front door (ingress -> services)
|  |- ollama/         local AI (GPU) + web UI
|  |- jellyfin/       media -- containerized successor to the native install
|  |- immich/         photos (private tier)
|  \`- nextcloud/      files/sharing (private tier)
|- projects/          application source (linenlady, minecraftserver, ...)
|- data/              persistent volumes (bind mounts)
|- backups/           local backup targets
|- docs/              port map, runbook, decision log
|- bin/               helper scripts
\`- secrets/           tokens/keys -- 0700, never committed
\`\`\`

## Host facts (see DG3030/CLAUDE.md for detail)

- Debian 13, i7-10700 (8C/16T), 62 GB RAM.
- **GPU: RTX 3060 12 GB**, driver 550.163.01, CUDA 12.4 -- available to Ollama.
- Tailscale \`100.86.218.41\`; LAN \`10.0.0.40\`; ufw active.
- Docker is **not installed yet** -- deliberate. Install when the first stack ships.

## Conventions

- One directory per stack, each with \`compose.yml\`, \`.env.example\`, \`README.md\`.
- Copy \`.env.example\` -> \`.env\` and fill locally; \`.env\` is gitignored.
- Every published hostname gets an entry in \`docs/port-map.md\` **and** in the
  cloudflared ingress -- no undocumented exposure.
- Record every non-obvious choice in \`docs/decisions.md\`.
EOF

# ------------------------------------------------------------------ README --
w "$ROOT/README.md" <<EOF
# datakiin -- working environment

Mounted on the \`DATAKIIN\` 4 TB drive at \`$ROOT\`.

Nothing here is running yet: this is the architecture, staged and documented.
Start with \`CLAUDE.md\`, then \`docs/port-map.md\`.

    stacks/     compose files, authored but not deployed
    projects/   source for linenlady, minecraftserver, ...
    docs/       port map, runbook, decisions
EOF

w "$ROOT/.gitignore" <<'EOF'
.env
secrets/
data/
backups/
*.log
*.bak
EOF

# ------------------------------------------------------------- cloudflared --
w "$ROOT/stacks/cloudflared/README.md" <<EOF
# cloudflared -- the public front door

Terminates public **HTTP(S)** traffic and forwards it to services over the
Docker network. No inbound ports are opened on the router: the tunnel dials out.

## What this can and cannot carry

- **CAN:** anything HTTP -- sites, APIs, dashboards.
- **CANNOT:** Minecraft or other raw TCP/UDP. Cloudflare only proxies arbitrary
  TCP to clients that also run \`cloudflared\`, which public players will not.
  Game traffic uses **playit.gg** instead. (Verified on the existing setup:
  \`survival.datakiin.com\` is a direct port-forward + SRV record, not a tunnel.)

## Auth

Put OAuth in front of admin surfaces with **Cloudflare Access** (Google/GitHub)
-- zero code, and it keeps private tools off the open internet. Private-tier
services should not be published here at all; reach them over Tailscale.

## Setup (when we deploy)

1. Create the tunnel in the Cloudflare dashboard (or \`cloudflared tunnel create\`).
2. Save the token to \`$ROOT/secrets/cloudflared-token\` (0600) or \`.env\`.
3. Map each hostname in \`config/ingress.yml\` and add a CNAME to the tunnel.
4. Update \`docs/port-map.md\` in the same commit.
EOF

w "$ROOT/stacks/cloudflared/compose.yml" <<'EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${TUNNEL_TOKEN:?set TUNNEL_TOKEN in .env}
    networks: [edge]
    # No ports published: the tunnel makes an outbound connection only.

networks:
  edge:
    name: edge
    # external: the `edge` network is created once, outside any stack, so
    # tearing down cloudflared cannot delete the network the other services
    # sit on. Must match stacks/web/compose.yml -- without this, compose
    # tries to manage a network that already exists.
    external: true
EOF

w "$ROOT/stacks/cloudflared/.env.example" <<'EOF'
# Copy to .env and fill in. Never commit .env.
# Cloudflare Zero Trust -> Networks -> Tunnels -> your tunnel -> token
TUNNEL_TOKEN=
EOF

w "$ROOT/stacks/cloudflared/config/ingress.yml" <<EOF
# Reference ingress map (token-run tunnels are configured in the dashboard;
# this file is the source of truth we keep in version control).
#
# PUBLIC tier only. Private services must NOT appear here.
ingress:
  # - hostname: www.$DOMAIN
  #   service: http://web:80
  # - hostname: ai.$DOMAIN          # put Cloudflare Access in front of this
  #   service: http://open-webui:8080
  - service: http_status:404        # required catch-all
EOF

# ------------------------------------------------------------------ ollama --
w "$ROOT/stacks/ollama/README.md" <<EOF
# ollama -- local AI (GPU)

Runs quantized models on the **RTX 3060 12 GB** (driver 550, CUDA 12.4).
Pairs with a Claude-API buffer for online/scientific research: local model for
in-house data (RAG), Claude for the wider web.

**Tier: private.** Bound to localhost/tailnet. If \`open-webui\` is ever
published, it must sit behind **Cloudflare Access**.

## Sizing on 12 GB VRAM

| Model class            | Fit                                   |
|------------------------|---------------------------------------|
| 7-8B quantized         | fully on GPU, fast                    |
| 13-14B quantized       | fits, comfortable                     |
| 30B+                   | partial offload -> CPU + 62 GB RAM     |

## Note

Ollama is currently installed **natively** (\`ollama version 0.32.9\`) and is the
quickest path. This stack is the containerized alternative -- pick one, do not
run both against the same port.
EOF

w "$ROOT/stacks/ollama/compose.yml" <<'EOF'
# NOT DEPLOYED -- architecture only.
# Requires NVIDIA Container Toolkit for GPU passthrough.
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "127.0.0.1:11434:11434"   # private: loopback only
    volumes:
      - /srv/datakiin/data/ollama:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    depends_on: [ollama]
    ports:
      - "127.0.0.1:3000:8080"     # private: publish only behind Access
    environment:
      OLLAMA_BASE_URL: http://ollama:11434
    volumes:
      - /srv/datakiin/data/open-webui:/app/backend/data
EOF

w "$ROOT/stacks/ollama/.env.example" <<'EOF'
# Optional: Claude API key for the research buffer. Never commit .env.
ANTHROPIC_API_KEY=
EOF

# ---------------------------------------------------------------- jellyfin --
w "$ROOT/stacks/jellyfin/README.md" <<EOF
# jellyfin -- media (private tier)

**A native Jellyfin is already running on this host (port 8096) and is Danny's.**
Do not start this stack while that service is active -- it will collide on 8096
and on the library paths.

Decide first:
1. **Leave native as-is** (simplest), or
2. **Migrate to container** -- stop+disable the native unit, import its config,
   then bring this up.

Media currently lives on \`/mnt/media\` (LABMEDIA, ~815 G free); mounted here
read-only so a container bug cannot eat the library.
GPU transcoding via NVENC is available on the RTX 3060 once enabled.
EOF

w "$ROOT/stacks/jellyfin/compose.yml" <<'EOF'
# NOT DEPLOYED -- architecture only. Conflicts with the native jellyfin service.
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"               # NOTE: native jellyfin already owns this port
    volumes:
      - /srv/datakiin/data/jellyfin/config:/config
      - /srv/datakiin/data/jellyfin/cache:/cache
      - /mnt/media:/media:ro
    # Uncomment for NVENC hardware transcoding (needs NVIDIA Container Toolkit):
    # deploy:
    #   resources:
    #     reservations:
    #       devices: [{driver: nvidia, count: all, capabilities: [gpu]}]
EOF

# ------------------------------------------------------------------ immich --
w "$ROOT/stacks/immich/README.md" <<EOF
# immich -- photos (private tier)

Self-hosted photo backup and sharing (the Google Photos replacement). Phone apps
auto-upload. Machine-learning search can use the RTX 3060.

**Private tier, firmly.** Family photos are exactly the data that must never sit
on a public no-auth endpoint. Reach it over Tailscale; do not add it to the
cloudflared ingress.

Storage: \`$ROOT/data/immich\`. Remember this drive is a used disk -- keep a
second copy (e.g. \`/mnt/backup\`) before trusting it with the only originals.
EOF

w "$ROOT/stacks/immich/compose.yml" <<'EOF'
# NOT DEPLOYED -- architecture only. Pin versions before first deploy.
services:
  immich-server:
    image: ghcr.io/immich-app/immich-server:release
    container_name: immich-server
    restart: unless-stopped
    depends_on: [immich-redis, immich-db]
    ports:
      - "127.0.0.1:2283:2283"     # private: loopback / tailnet only
    env_file: [.env]
    volumes:
      - /srv/datakiin/data/immich/library:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:release
    container_name: immich-ml
    restart: unless-stopped
    env_file: [.env]
    volumes:
      - /srv/datakiin/data/immich/model-cache:/cache

  immich-redis:
    image: redis:7-alpine
    container_name: immich-redis
    restart: unless-stopped

  immich-db:
    image: tensorchord/pgvecto-rs:pg14-v0.2.0
    container_name: immich-db
    restart: unless-stopped
    env_file: [.env]
    volumes:
      - /srv/datakiin/data/immich/db:/var/lib/postgresql/data
EOF

w "$ROOT/stacks/immich/.env.example" <<'EOF'
# Copy to .env and fill in. Never commit .env.
DB_PASSWORD=changeme
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
DB_HOSTNAME=immich-db
REDIS_HOSTNAME=immich-redis
IMMICH_VERSION=release
EOF

# --------------------------------------------------------------- nextcloud --
w "$ROOT/stacks/nextcloud/README.md" <<EOF
# nextcloud -- files & sharing (private tier)

File sync/share with public *link* sharing when needed.

**Use SFTP, not FTP.** Plain FTP is cleartext; SSH is already running on this
box, so SFTP is free and encrypted. No FTP server will be deployed.

Samba (445/139) is already serving files natively on this host -- decide whether
Nextcloud supplements it or replaces it before deploying.
EOF

w "$ROOT/stacks/nextcloud/compose.yml" <<'EOF'
# NOT DEPLOYED -- architecture only.
services:
  nextcloud:
    image: nextcloud:stable
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "127.0.0.1:8081:80"       # private by default; publish via tunnel if wanted
    env_file: [.env]
    volumes:
      - /srv/datakiin/data/nextcloud/html:/var/www/html
      - /srv/datakiin/data/nextcloud/data:/var/www/html/data

  nextcloud-db:
    image: mariadb:11
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin-trust-function-creators=1
    env_file: [.env]
    volumes:
      - /srv/datakiin/data/nextcloud/db:/var/lib/mysql
EOF

w "$ROOT/stacks/nextcloud/.env.example" <<'EOF'
# Copy to .env and fill in. Never commit .env.
MYSQL_ROOT_PASSWORD=changeme
MYSQL_PASSWORD=changeme
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_HOST=nextcloud-db
EOF

w "$ROOT/stacks/README.md" <<EOF
# stacks

One directory per service. **None of these are running.** Each has a
\`compose.yml\`, a \`.env.example\`, and a README explaining its tier and gotchas.

| Stack        | Tier    | Status        | Notes                                    |
|--------------|---------|---------------|------------------------------------------|
| cloudflared  | public  | not deployed  | HTTP front door; cannot carry game traffic |
| ollama       | private | native install running | GPU AI; containerize or keep native |
| jellyfin     | private | native install running | port 8096 conflict -- decide first  |
| immich       | private | not deployed  | photos; never publish                     |
| nextcloud    | private | not deployed  | files; SFTP not FTP                       |

Deploy checklist for any stack:
1. Confirm its tier and binding (loopback/tailnet vs published).
2. \`cp .env.example .env\` and fill secrets.
3. Add the hostname to \`docs/port-map.md\` and the cloudflared ingress if public.
4. Install Docker first (not yet installed on this host).
EOF

# ---------------------------------------------------------------- projects --
w "$ROOT/projects/README.md" <<EOF
# projects

Application source. Each project owns its code; deployment goes through a stack
in \`../stacks/\`.

| Project         | What it is                        | Status                    |
|-----------------|-----------------------------------|---------------------------|
| linenlady       | LinenLady site/API + inventory     | source lives on Romulus (U:\\\\LinenLady*) |
| minecraftserver | Minecraft server tooling/instances | **owned by a separate agent** -- infra only here |

Adding a project: create the directory, add a README stating what it is, its
tier, and its data locations; then author a stack for it.
EOF

w "$ROOT/projects/linenlady/README.md" <<EOF
# LinenLady

Business site/API + inventory system. Source currently on Romulus
(\`U:\\LinenLady\`, \`U:\\LinenLady.Api\`, \`U:\\LinenLadyInventorySystem\`).

- **Tier: public** (web) -- publish via Cloudflare Tunnel.
- Admin/API surfaces should sit behind **Cloudflare Access** (OAuth).
- An existing \`linenlady\` tunnel already runs from Romulus; decide whether to
  migrate it here or leave it before changing DNS.
- Nothing deployed here yet.
EOF

w "$ROOT/projects/minecraftserver/README.md" <<EOF
# MinecraftServer

**Scope boundary:** the Minecraft server software (worlds, plugins, instances,
server management) belongs to a **separate project/agent**. This directory only
holds the *infrastructure* concerns: reachability, tunneling, and storage.

- **Tier: public** -- but **not** via Cloudflare Tunnel. Cloudflare cannot carry
  Minecraft's raw TCP to ordinary players. Use **playit.gg**, which also hides
  the home IP (unlike the current direct port-forward that publishes it).
- Existing reference: \`survival.datakiin.com\` -> CNAME \`home.datakiin.com\` ->
  Comcast IP, SRV \`_minecraft._tcp\` -> port 25569, router port-forward.
- Java is not installed on labserver; the separate project owns that decision.
EOF

# -------------------------------------------------------------------- docs --
w "$ROOT/docs/port-map.md" <<EOF
# Port map / exposure register

Every listening service and how (or whether) it is reachable from outside.
**Update this in the same change that exposes anything.**

## Currently listening on labserver (host, not containers)

| Port      | Service        | Bind      | Exposure                                  |
|-----------|----------------|-----------|-------------------------------------------|
| 22        | sshd           | 0.0.0.0   | LAN + tailnet; key-only auth              |
| 8096      | Jellyfin (native) | 0.0.0.0 | LAN + tailnet; blocked externally by ufw  |
| 445 / 139 | Samba          | 0.0.0.0   | LAN; blocked externally by ufw            |
| 137 / 138 | NetBIOS (udp)  | 0.0.0.0   | LAN                                       |
| 41641     | tailscaled     | 0.0.0.0   | tailnet transport                         |
| 11434     | ollama (native)| localhost | local only                                |

Verified 2026-08-10 from off-network over IPv6: 8096/445/139/22 all unreachable.

## Planned (none deployed)

| Hostname                | Tier    | Backend            | Front door         |
|-------------------------|---------|--------------------|--------------------|
| www.$DOMAIN             | public  | web:80             | Cloudflare Tunnel  |
| ai.$DOMAIN              | public* | open-webui:8080    | Tunnel + **Access**|
| immich                  | private | 127.0.0.1:2283     | Tailscale only     |
| nextcloud               | private | 127.0.0.1:8081     | Tailscale only     |
| minecraft               | public  | 25565              | **playit.gg**      |

\\* published but gated by Cloudflare Access OAuth.
EOF

w "$ROOT/docs/runbook.md" <<EOF
# Runbook

## Access
\`\`\`
ssh jony@100.86.218.41        # key auth (jon@romulus); Tailscale transport
\`\`\`
\`jony\` has sudo (password required). Tailscale SSH does **not** work here --
it cannot authorize a user the node is *shared* to.

## Health
\`\`\`
df -h /srv/datakiin                      # environment drive
sudo smartctl -H -A /dev/sdb             # DATAKIIN drive health
sudo smartctl -l selftest /dev/sdb       # surface-test results
nvidia-smi                               # GPU / VRAM
systemctl is-active jellyfin smbd tailscaled ssh
sudo ufw status verbose                  # firewall allow-list
\`\`\`

## Drive
- \`DATAKIIN\` = \`/dev/sdb1\`, mounted at \`$ROOT\` **by UUID** in \`/etc/fstab\`.
- Used enterprise disk (~5.3 yrs powered on, media clean at setup).
  **Keep a second copy of anything irreplaceable** (e.g. on \`/mnt/backup\`).

## Before exposing anything
1. Which tier? Private stays on the tailnet.
2. Bind loopback/tailnet unless it is genuinely public.
3. Add it to \`port-map.md\` + the cloudflared ingress.
4. Re-test from off-network (IPv4 **and** IPv6).
EOF

w "$ROOT/docs/decisions.md" <<EOF
# Decision log

**2026-08-11 -- Environment lives on its own 4 TB drive.** Labelled \`DATAKIIN\`,
mounted by UUID at \`$ROOT\`. Keeps Jon's work separate from Danny's OS and media
drives. Used enterprise disk: clean media, ~5.3 yrs powered-on -> never the sole
copy of irreplaceable data.

**2026-08-11 -- GPU: RTX 3060 12 GB with driver 550 / CUDA 12.4.** Required
enabling the \`non-free\` apt component. Makes labserver the AI host, so the
GMKtec Ryzen mini is no longer needed for local AI.

**2026-08-10 -- Two front doors.** Cloudflare Tunnel is HTTP-only and cannot
carry Minecraft's raw TCP to ordinary players; games use playit.gg. Confirmed
against the live setup, where the game is a port-forward + SRV and only the web
rides the tunnel.

**2026-08-10 -- Privacy: separate anonymity from access control.** Anonymity =
hide the origin IP (tunnel/playit). Access control = keep private data off the
public internet entirely, behind the Tailscale mesh, where membership is the
auth. That is both *less* auth and *more* privacy. OAuth via Cloudflare Access
is for the few public admin surfaces.

**2026-08-10 -- Tailscale SSH rejected.** It cannot authorize a user that a node
is *shared* to (documented limitation), and while enabled it intercepts port 22
and blocks key auth. Using a normal ed25519 key instead.

**2026-08-11 -- Docker deliberately not installed.** Architecture staged first;
runtime goes in when the first stack actually ships.
EOF

# --------------------------------------------------------------------- bin --
w "$ROOT/bin/health.sh" <<'EOF'
#!/usr/bin/env bash
# Read-only health snapshot of the datakiin environment.
set -uo pipefail
echo "=== drive ==="; df -h /srv/datakiin | tail -1
echo "=== gpu ==="; nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader 2>/dev/null || echo "nvidia-smi unavailable"
echo "=== services ==="; for s in jellyfin smbd tailscaled ssh docker; do printf "%s:%s " "$s" "$(systemctl is-active "$s" 2>/dev/null || echo n/a)"; done; echo
echo "=== ollama ==="; command -v ollama >/dev/null && ollama list 2>/dev/null | head -5 || echo "not installed"
echo "=== listening ==="; ss -tln | tail -n +2 | awk '{print $4}' | sort -u
EOF
chmod +x "$ROOT/bin/health.sh" 2>/dev/null || true

echo
echo "Done. Tree:"
find "$ROOT" -maxdepth 2 -not -path '*/data/*' -not -path '*/.git/*' | sed "s|$ROOT|.|" | sort
