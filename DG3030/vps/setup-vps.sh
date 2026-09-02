#!/usr/bin/env bash
#
# setup-vps.sh -- stand up the public door on a rented VPS.
#
# Run ON THE VPS, as root. Idempotent: safe to re-run.
#
#   Pass 1 (no args)  -- installs packages, generates the keypair, prints the
#                        VPS public key. Take that key to labserver.
#   Pass 2            -- ./setup-vps.sh --peer-pubkey <labserver-public-key>
#                        writes the peer in, brings wg0 up, configures nginx.
#
# WHAT THIS BOX DOES: it is a public IP and nothing else. It terminates no TLS,
# holds no certificate, stores no data, and cannot read a single byte of what
# it relays -- TLS terminates on labserver. If this VPS is compromised the
# attacker gets a relay, not the family's files.
#
set -euo pipefail

WG_IF=wg0
WG_PORT=51820
WG_NET=10.10.0
VPS_WG_ADDR="${WG_NET}.1/24"
LAB_WG_ADDR="${WG_NET}.2"
PEER_PUBKEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer-pubkey) PEER_PUBKEY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# nginx-full carries the stream module on Debian/Ubuntu. Plain "nginx" does
# not always, and a missing stream module fails at reload with a confusing
# "unknown directive" rather than anything about modules.
apt-get install -y -qq wireguard-tools nginx-full

echo "==> wireguard keys"
umask 077
mkdir -p /etc/wireguard
if [[ ! -f /etc/wireguard/private.key ]]; then
  wg genkey > /etc/wireguard/private.key
  echo "    generated a new keypair"
else
  echo "    reusing existing keypair"
fi
wg pubkey < /etc/wireguard/private.key > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

if [[ -z "$PEER_PUBKEY" ]]; then
  cat <<EOF

  ---------------------------------------------------------------
  PASS 1 COMPLETE. This VPS's WireGuard public key is:

      $(cat /etc/wireguard/public.key)

  Next:
    1. Run setup-labserver-wireguard.sh on labserver with this key
       and this VPS's public IP.
    2. It prints labserver's public key. Come back and run:
         ./setup-vps.sh --peer-pubkey <labserver-public-key>
  ---------------------------------------------------------------

EOF
  exit 0
fi

echo "==> ${WG_IF}.conf"
cat > "/etc/wireguard/${WG_IF}.conf" <<EOF
# Managed by setup-vps.sh -- re-run the script rather than hand-editing.
[Interface]
Address    = ${VPS_WG_ADDR}
ListenPort = ${WG_PORT}
PostUp     = wg set %i private-key /etc/wireguard/private.key

[Peer]
# labserver. Deliberately NO Endpoint line: labserver dials OUT and this side
# learns its address from the first handshake. That is what lets the whole
# design work behind Danny's double NAT with no port-forward anywhere.
PublicKey  = ${PEER_PUBKEY}
AllowedIPs = ${LAB_WG_ADDR}/32
EOF
chmod 600 "/etc/wireguard/${WG_IF}.conf"

systemctl enable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || systemctl restart "wg-quick@${WG_IF}"
systemctl restart "wg-quick@${WG_IF}"

echo "==> nginx stream proxy"
mkdir -p /etc/nginx/stream.d
install -m 644 "$(dirname "$0")/nginx-stream.conf" /etc/nginx/stream.d/datakiin.conf 2>/dev/null \
  || echo "    WARNING: nginx-stream.conf not found next to this script; copy it to /etc/nginx/stream.d/datakiin.conf yourself"

# Debian's nginx.conf does not include a stream{} block by default.
if ! grep -q 'stream.d/\*.conf' /etc/nginx/nginx.conf; then
  cat >> /etc/nginx/nginx.conf <<'EOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
  echo "    added stream{} include to nginx.conf"
fi

nginx -t
systemctl reload nginx

cat <<EOF

==> DONE.

  wg:    $(wg show ${WG_IF} 2>/dev/null | head -1 || echo 'not up')
  nginx: $(systemctl is-active nginx)

  Open these in the PROVIDER'S firewall (Hetzner Cloud Firewall, etc.) --
  NOT ufw. If Docker is ever installed on this box it writes its own iptables
  rules and bypasses ufw entirely, so a port you believe is closed stays open.

      udp  ${WG_PORT}   WireGuard      from anywhere
      tcp  443          HTTPS          from anywhere
      tcp  22           SSH            from your address if you can pin it

  Do NOT open udp/443. HTTP/3 is deliberately not forwarded -- see
  nginx-stream.conf for why, and turn h3 off in Caddy to match.

  Verify from a third machine (not labserver, not this VPS):
      curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\\n' \\
        --resolve watch.datakiin.com:443:<THIS-VPS-IP> \\
        https://watch.datakiin.com/

EOF
