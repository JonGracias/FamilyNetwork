#!/usr/bin/env bash
#
# setup-labserver-docker.sh
# ---------------------------------------------------------------------------
# Installs Docker Engine + Compose v2 on labserver (Debian 13 trixie) and
# prepares it for the DG3030 stacks in /srv/datakiin/stacks/.
#
# Deliberately NOT installed here: Kubernetes/k3s (single node -- no benefit),
# and the NVIDIA Container Toolkit (separate change, separate script).
#
# This script does NOT touch ufw, does NOT stop Danny's Jellyfin/Samba, and
# does NOT publish any port. Container port exposure is decided per-stack in
# the compose files -- see the BINDING DISCIPLINE note at the bottom.
#
# Run ON labserver, as a user with sudo. Safe to run more than once.
#
#   bash setup-labserver-docker.sh                 # install, use `sudo docker`
#   bash setup-labserver-docker.sh --docker-group  # ALSO add $USER to `docker`
#                                                  #   (= passwordless root --
#                                                  #    read the warning below)
# ---------------------------------------------------------------------------
set -euo pipefail

ADD_TO_GROUP=0
[ "${1:-}" = "--docker-group" ] && ADD_TO_GROUP=1

TARGET_USER="${SUDO_USER:-$(id -un)}"
STACKS="/srv/datakiin/stacks"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '   \033[33mwarn\033[0m %s\n' "$*"; }

# --------------------------------------------------------------------------
say "[1/7] Preflight"

. /etc/os-release
echo "   distro     : $PRETTY_NAME"
echo "   kernel     : $(uname -r)"
echo "   arch       : $(dpkg --print-architecture)"
echo "   cgroup     : $(stat -fc %T /sys/fs/cgroup)"

[ "$(stat -fc %T /sys/fs/cgroup)" = "cgroup2fs" ] \
  || warn "not cgroup v2 -- Docker will work but resource limits are weaker"

# Debian ships its own docker.io/podman; mixing them with docker-ce is the
# classic broken-install. Refuse rather than fight it.
if dpkg -l 2>/dev/null | grep -qE '^ii\s+(docker\.io|docker-doc|docker-compose|podman|containerd)\s'; then
  echo
  echo "ERROR: conflicting container packages are installed:"
  dpkg -l | grep -E '^ii\s+(docker\.io|docker-doc|docker-compose|podman|containerd)\s' | awk '{print "   " $2}'
  echo "Remove them first, then re-run:  sudo apt-get remove <pkg>..."
  exit 1
fi
ok "no conflicting container packages"

if command -v docker >/dev/null 2>&1; then
  ok "docker already present ($(docker --version 2>/dev/null)) -- continuing (idempotent)"
fi

# Free space where images/volumes actually land.
AVAIL_G="$(df -BG --output=avail /var/lib | tail -1 | tr -dc '0-9')"
echo "   free on /var: ${AVAIL_G}G"
[ "${AVAIL_G:-0}" -ge 20 ] || { echo "ERROR: need >=20G free on /var"; exit 1; }
ok "disk space fine"

# --------------------------------------------------------------------------
say "[2/7] Docker apt repository"

sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/docker.asc ]; then
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
       -o /etc/apt/keyrings/docker.asc
  ok "keyring fetched"
else
  ok "keyring already present"
fi
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Docker publishes per-suite dists. If trixie is not published yet, fall back
# to bookworm -- ABI-compatible for docker-ce and the documented workaround.
SUITE="$VERSION_CODENAME"
if ! curl -fsI "https://download.docker.com/linux/debian/dists/${SUITE}/Release" >/dev/null 2>&1; then
  warn "no Docker repo for '${SUITE}' -- falling back to 'bookworm'"
  SUITE="bookworm"
fi
echo "   using suite: $SUITE"

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${SUITE} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
ok "/etc/apt/sources.list.d/docker.list written"

sudo apt-get update -qq
ok "apt index updated"

# --------------------------------------------------------------------------
say "[3/7] Install engine + compose v2"

sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
ok "$(docker --version)"
ok "$(docker compose version)"

# --------------------------------------------------------------------------
say "[4/7] Daemon config"

# Why each setting:
#   log-opts            unbounded json-file logs are the #1 way a homelab
#                       fills its root disk. Cap them.
#   default-address-pools  keep Docker's bridges away from Danny's LAN
#                       (10.0.0.0/24) and the tailnet (100.64.0.0/10).
#   live-restore        containers keep running across a daemon restart --
#                       matters when Jellyfin/Immich are mid-stream.
DAEMON_JSON='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-address-pools": [
    { "base": "172.20.0.0/14", "size": 24 }
  ],
  "live-restore": true
}'

if [ -s /etc/docker/daemon.json ]; then
  if diff -q <(echo "$DAEMON_JSON") /etc/docker/daemon.json >/dev/null 2>&1; then
    ok "daemon.json already correct"
  else
    BAK="/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
    sudo cp -a /etc/docker/daemon.json "$BAK"
    warn "existing daemon.json backed up -> $BAK"
    echo "$DAEMON_JSON" | sudo tee /etc/docker/daemon.json >/dev/null
    ok "daemon.json written"
  fi
else
  sudo mkdir -p /etc/docker
  echo "$DAEMON_JSON" | sudo tee /etc/docker/daemon.json >/dev/null
  ok "daemon.json written"
fi

# --------------------------------------------------------------------------
say "[5/7] Enable + start"

sudo systemctl enable --now docker
sudo systemctl restart docker
sleep 2
systemctl is-active --quiet docker && ok "docker.service active" \
  || { echo "ERROR: docker.service failed"; sudo systemctl status docker --no-pager -l | tail -20; exit 1; }

# --------------------------------------------------------------------------
say "[6/7] The 'edge' network"

# stacks/web/compose.yml (and cloudflared) join this as an EXTERNAL network.
# It is created once, here, so no stack owns it and tearing one down cannot
# take the tunnel's network with it.
if sudo docker network inspect edge >/dev/null 2>&1; then
  ok "network 'edge' already exists"
else
  sudo docker network create edge >/dev/null
  ok "network 'edge' created"
fi

# --------------------------------------------------------------------------
say "[7/7] Smoke test + optional group"

# Pulls the ~20 KB hello-world image from Docker Hub to prove pull + run + net.
if sudo docker run --rm hello-world >/dev/null 2>&1; then
  ok "hello-world ran -- pull, runtime and networking all good"
else
  warn "hello-world failed -- check 'sudo docker info' and outbound HTTPS"
fi

if [ "$ADD_TO_GROUP" = "1" ]; then
  sudo groupadd -f docker
  sudo usermod -aG docker "$TARGET_USER"
  warn "added '$TARGET_USER' to the 'docker' group."
  warn "This is effectively PASSWORDLESS ROOT for that user -- the docker"
  warn "socket can mount / into a container. Log out and back in to apply."
else
  echo "   '$TARGET_USER' NOT added to the 'docker' group (default)."
  echo "   Use 'sudo docker ...'. Re-run with --docker-group to change that,"
  echo "   but read the warning in the header first."
fi

# --------------------------------------------------------------------------
cat <<EOF

===========================================================================
DONE.

  engine   : $(docker --version)
  compose  : $(docker compose version)
  data-root: $(sudo docker info -f '{{.DockerRootDir}}' 2>/dev/null)
  stacks   : $STACKS

BINDING DISCIPLINE -- the one rule that matters on this box
---------------------------------------------------------------------------
Docker inserts its OWN netfilter rules and a published port BYPASSES ufw.
'ufw default deny incoming' will NOT protect a container port. So never
write a bare port mapping in a compose file:

    ports: ["8096:8096"]              # WRONG -- listens on the LAN *and*
                                      # the tailnet, ufw will not stop it

Always bind to an explicit address:

    ports: ["127.0.0.1:8096:8096"]    # loopback only (reverse-proxy it)
    ports: ["100.86.218.41:8096:8096"]# tailnet only (family/private tier)

Or publish nothing at all and let cloudflared reach the container over the
'edge' network -- which is exactly what stacks/web/compose.yml does.

NEXT
---------------------------------------------------------------------------
  * GPU in containers? run setup-labserver-nvidia-toolkit.sh (separate step)
  * public path proof:  cd $STACKS/web && sudo docker compose up -d
    (still needs cloudflared + a decided hostname)
===========================================================================
EOF
