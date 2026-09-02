#!/usr/bin/env bash
#
# setup-labserver-wireguard.sh -- the labserver end of the VPS tunnel.
#
# Run ON LABSERVER, as root (sudo). Idempotent: safe to re-run.
#
#   Pass 1 (no args)  -- installs wireguard-tools, generates the keypair,
#                        prints labserver's public key. Take it to the VPS.
#   Pass 2            -- ./setup-labserver-wireguard.sh \
#                          --vps-endpoint <vps-ip>:51820 \
#                          --vps-pubkey   <vps-public-key>
#
# DIRECTION MATTERS: labserver dials OUT. Nothing inbound is opened on the
# Fios router or the FortiGate, which is the entire reason this design needs
# nothing from Danny -- and why it leaves Karla's isolation untouched.
#
set -euo pipefail

WG_IF=wg0
WG_ADDR=10.10.0.2/24
VPS_WG_IP=10.10.0.1
VPS_ENDPOINT=""
VPS_PUBKEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vps-endpoint) VPS_ENDPOINT="${2:-}"; shift 2 ;;
    --vps-pubkey)   VPS_PUBKEY="${2:-}";   shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard-tools

echo "==> keys"
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

if [[ -z "$VPS_ENDPOINT" || -z "$VPS_PUBKEY" ]]; then
  cat <<EOF

  ---------------------------------------------------------------
  PASS 1 COMPLETE. labserver's WireGuard public key is:

      $(cat /etc/wireguard/public.key)

  Take it to the VPS:
      ./setup-vps.sh --peer-pubkey $(cat /etc/wireguard/public.key)

  Then come back and re-run this with --vps-endpoint and --vps-pubkey.
  ---------------------------------------------------------------

EOF
  exit 0
fi

echo "==> ${WG_IF}.conf"
cat > "/etc/wireguard/${WG_IF}.conf" <<EOF
# Managed by setup-labserver-wireguard.sh -- re-run rather than hand-editing.
[Interface]
Address    = ${WG_ADDR}
PostUp     = wg set %i private-key /etc/wireguard/private.key

[Peer]
PublicKey  = ${VPS_PUBKEY}
Endpoint   = ${VPS_ENDPOINT}

# ONLY the tunnel subnet. NOT 0.0.0.0/0 -- that would route this box's entire
# internet egress through the VPS, breaking Tailscale's direct paths, hiding
# every client behind one address, and pointlessly paying for bandwidth we
# already have on a 5 Gig line.
AllowedIPs = ${VPS_WG_IP}/32

# The VPS has no Endpoint for us, so this side must keep the NAT mapping
# alive. Without it the tunnel works until the first idle period and then
# silently stops accepting inbound connections until labserver sends
# something -- which looks exactly like an outage nobody caused.
PersistentKeepalive = 25
EOF
chmod 600 "/etc/wireguard/${WG_IF}.conf"

systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
systemctl restart "wg-quick@${WG_IF}"

echo
echo "==> handshake check"
sleep 3
wg show "${WG_IF}"
echo
if ping -c2 -W3 "${VPS_WG_IP}" >/dev/null 2>&1; then
  echo "    ${VPS_WG_IP} reachable over the tunnel -- UP"
else
  echo "    ${VPS_WG_IP} NOT reachable. Check the VPS firewall allows udp/51820 inbound."
fi

cat <<EOF

==> NEXT, on labserver:

  Caddy must listen on the tunnel address and accept PROXY protocol.

  1. caddy/compose.yml -- add the wg0 publish alongside the LAN one:
         ports:
           - "192.168.50.10:443:443"
           - "10.10.0.2:443:443"

     WARNING: this address only exists once wg-quick@wg0 is up. If Docker
     starts first the publish fails. If that bites after a reboot, the fix is
     a drop-in making docker.service wait:
         [Unit]
         After=wg-quick@wg0.service
         Wants=wg-quick@wg0.service

  2. caddy/Caddyfile -- global options block:
         {
             servers {
                 listener_wrappers {
                     proxy_protocol {
                         allow 10.10.0.1/32
                     }
                     tls
                 }
                 protocols h1 h2
             }
         }

     ORDER MATTERS: proxy_protocol must come BEFORE tls in the wrapper list,
     or Caddy tries to parse the PROXY header as TLS and every connection
     fails. "protocols h1 h2" disables HTTP/3, which the VPS does not forward.

  3. Re-verify from a third machine, WITHOUT -k, and read the issuer:
         curl -sS -o /dev/null \\
           -w '%{http_code} verify=%{ssl_verify_result}\\n' \\
           --resolve watch.datakiin.com:443:<VPS-IP> \\
           https://watch.datakiin.com/

  4. 🚨 Re-run the isolation test afterwards. Nothing here should touch it --
     no inbound rule is created anywhere -- but this project has twice had a
     security property die to a change nobody expected to matter.

EOF
