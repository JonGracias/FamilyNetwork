#!/usr/bin/env bash
#
# install-mc-router.sh -- the game half of the public door.
#
# Run ON THE VPS, as root, AFTER setup-vps.sh (needs wg0 up so mc-router has something to
# route to). Idempotent: safe to re-run, including to bump VERSION/SHA256 below.
#
# WHAT THIS ADDS: a single Minecraft-facing TCP listener (25565) that reads the hostname
# out of the client's own handshake and forwards to that world's own port on labserver,
# down the WireGuard tunnel - one game port for every world instead of one forwarded port
# each. It is a plain systemd service, not Docker: this box deliberately has none, and
# Docker writing its own iptables rules around ufw/the Cloud Firewall is a trap this
# project has already documented twice (see vps/README.md).
#
# mcpy owns the routing TABLE (`mcpy mc-router --sync`, from the MinecraftServers repo) -
# this script only gets the BINARY running and watching for that file to appear/change.
#
set -euo pipefail

VERSION=1.46.5
ASSET="mc-router_${VERSION}_linux_amd64.tar.gz"
URL="https://github.com/itzg/mc-router/releases/download/v${VERSION}/${ASSET}"
# Verified against that release's own mc-router_${VERSION}_checksums.txt - read the real
# hash off the release page if bumping VERSION, never carry one forward from memory.
SHA256="a25761e89f17d47526eacc8a37ff1a22db289b51c3ac8dce02082aef76c1cb0b"

ROUTES_PATH=/etc/mc-router/routes.json
BIN_PATH=/usr/local/bin/mc-router

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

echo "==> mc-router ${VERSION} binary"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/$ASSET" "$URL"
echo "${SHA256}  $work/$ASSET" | sha256sum -c -
tar -xzf "$work/$ASSET" -C "$work"
install -m 755 "$work/mc-router" "$BIN_PATH"
"$BIN_PATH" --version || true

echo "==> service account"
id -u mc-router >/dev/null 2>&1 || \
  useradd --system --no-create-home --shell /usr/sbin/nologin mc-router

echo "==> routes.json"
mkdir -p "$(dirname "$ROUTES_PATH")"
if [[ ! -f "$ROUTES_PATH" ]]; then
  # A valid, empty table - so the service starts cleanly before mcpy's first push.
  # `mcpy mc-router --sync` (from the MinecraftServers repo) overwrites this afterwards.
  cat > "$ROUTES_PATH" <<'EOF'
{
  "default-server": null,
  "mappings": {}
}
EOF
fi
chmod 644 "$ROUTES_PATH"

echo "==> systemd unit"
cat > /etc/systemd/system/mc-router.service <<EOF
[Unit]
Description=mc-router - Minecraft handshake-based TCP router
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
User=mc-router
Group=mc-router
ExecStart=${BIN_PATH} -port 25565 -routes-config ${ROUTES_PATH} -routes-config-watch -api-binding 127.0.0.1:8734
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mc-router
systemctl restart mc-router

cat <<EOF

==> DONE.

  mc-router: $(systemctl is-active mc-router) (listening on 25565, admin API on
             127.0.0.1:8734 only - never exposed)
  routes:    ${ROUTES_PATH} ($(wc -l < "$ROUTES_PATH") lines - empty until mcpy pushes)

  Open this in the PROVIDER'S firewall (Linode Cloud Firewall) -- NOT ufw. Docker writes
  its own iptables rules and bypasses ufw entirely; this box has no Docker, but the same
  rule applies to anything installed here later.

      tcp  25565   Minecraft (mc-router)   from anywhere

  From the MinecraftServers repo, once [mc_router] is filled in under
  config/settings.local.toml (backend_host = this tunnel's labserver-side IP, push_host =
  an ssh alias for this box):

      mcpy mc-router --sync --dry-run    # see what would be pushed
      mcpy mc-router --sync              # push it for real

  Verify from a THIRD machine (not labserver, not this VPS):
      nc -zv <THIS-VPS-IP> 25565

EOF
