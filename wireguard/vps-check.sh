#!/usr/bin/env bash
# vps-check.sh - read-only state check for the WireGuard relay VPS.
# Changes nothing. Run this FIRST, on the VPS, to find out what is already
# there before any setup script touches the box.
#   sudo bash vps-check.sh
set -uo pipefail

WG_IF="${WG_IF:-wg0}"
ok(){ printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
no(){ printf '  \033[31m[--]\033[0m   %s\n' "$*"; }
warn(){ printf '  \033[33m[!!]\033[0m   %s\n' "$*"; }
hdr(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }

hdr "Host"
echo "  $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") | kernel $(uname -r)"
echo "  hostname: $(hostname)"

hdr "Public address"
WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
WAN_IP=$(ip -4 addr show "${WAN_IF:-lo}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
[ -n "${WAN_IF:-}" ] && ok "WAN interface: $WAN_IF  ip: ${WAN_IP:-unknown}" || no "could not determine WAN interface"
case "$WAN_IP" in
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
    warn "WAN IP is PRIVATE/CGNAT - this VPS is itself behind NAT and cannot"
    warn "serve as a relay. A relay needs a real public IP." ;;
  "") : ;;
  *) ok "WAN IP looks publicly routable" ;;
esac

hdr "WireGuard"
if command -v wg >/dev/null 2>&1; then
  ok "wg installed: $(wg --version 2>/dev/null)"
else
  no "wg NOT installed  ->  apt install wireguard  (setup step 1)"
fi
if [ -f "/etc/wireguard/${WG_IF}.conf" ]; then
  ok "/etc/wireguard/${WG_IF}.conf exists"
  echo "      ListenPort: $(awk -F'= *' '/^ *ListenPort/{print $2}' /etc/wireguard/${WG_IF}.conf 2>/dev/null || echo '(unset)')"
  echo "      Address:    $(awk -F'= *' '/^ *Address/{print $2}' /etc/wireguard/${WG_IF}.conf 2>/dev/null || echo '(unset)')"
  echo "      peers:      $(grep -c '^\[Peer\]' /etc/wireguard/${WG_IF}.conf 2>/dev/null || echo 0)"
else
  no "/etc/wireguard/${WG_IF}.conf missing  ->  setup step 2"
fi
if systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null; then
  ok "wg-quick@${WG_IF} is ACTIVE$(systemctl is-enabled --quiet wg-quick@${WG_IF} 2>/dev/null && echo ' and enabled at boot' || echo ' but NOT enabled at boot')"
else
  no "wg-quick@${WG_IF} not running"
fi

hdr "Tunnel handshake (is home actually connected?)"
if command -v wg >/dev/null 2>&1 && wg show "$WG_IF" >/dev/null 2>&1; then
  wg show "$WG_IF" latest-handshakes 2>/dev/null | while read -r key ts; do
    if [ "${ts:-0}" -eq 0 ] 2>/dev/null; then
      no "peer ${key:0:12}...  NEVER handshaked"
    else
      age=$(( $(date +%s) - ts ))
      if [ "$age" -lt 180 ]; then ok "peer ${key:0:12}...  handshake ${age}s ago - tunnel UP"
      else warn "peer ${key:0:12}...  last handshake ${age}s ago - probably DOWN"; fi
    fi
  done
  [ -z "$(wg show "$WG_IF" peers 2>/dev/null)" ] && no "no peers configured"
else
  no "cannot query - interface $WG_IF is not up"
fi

hdr "IP forwarding (required for any port to reach home)"
v=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
[ "$v" = "1" ] && ok "net.ipv4.ip_forward = 1" || no "net.ipv4.ip_forward = ${v:-?}  -> traffic will NOT be forwarded"
if grep -rqs '^ *net.ipv4.ip_forward *= *1' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null; then
  ok "persisted across reboot"
else
  warn "not persisted - will reset to 0 on reboot unless written to /etc/sysctl.d/"
fi

hdr "Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  warn "ufw is ACTIVE. Two things it will silently break:"
  fp=$(grep -s '^DEFAULT_FORWARD_POLICY' /etc/default/ufw | cut -d'"' -f2)
  [ "$fp" = "ACCEPT" ] && ok "  DEFAULT_FORWARD_POLICY=ACCEPT (good)" \
                       || no  "  DEFAULT_FORWARD_POLICY=${fp:-DROP} - forwarded packets DROPPED. Set to ACCEPT."
  ufw status | grep -qE '51820|WireGuard' && ok "  a 51820/udp rule exists" \
                                          || no  "  no 51820/udp rule - the tunnel cannot be established"
else
  ok "ufw not active (or not installed)"
fi
command -v nft >/dev/null 2>&1 && ok "nftables available: $(nft --version)" \
                               || no "nft NOT installed -> apt install nftables (vps-apply-portmap.sh needs it)"
if nft list table ip familynet_portmap >/dev/null 2>&1; then
  ok "port map table already applied:"
  nft -a list table ip familynet_portmap 2>/dev/null | grep -E 'dnat|comment' | sed 's/^/      /'
else
  no "no familynet_portmap table yet -> run vps-apply-portmap.sh"
fi

hdr "Listening sockets on the public interface"
if command -v ss >/dev/null 2>&1; then
  out=$(ss -lntup 2>/dev/null | awk 'NR==1 || /0\.0\.0\.0|\[::\]/' | head -20)
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  /' || echo "  (nothing listening on a wildcard address)"
else
  echo "  (ss not installed - skipped)"
fi

hdr "Summary"
echo "  Next: fix anything marked [--] above, then run vps-apply-portmap.sh."
echo "  Verify from OUTSIDE the house (phone on cellular, wifi off):"
echo "    nc -vz ${WAN_IP:-<vps-ip>} 25569"
