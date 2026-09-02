#!/usr/bin/env bash
#
# setup-labserver-postgate.sh
# ---------------------------------------------------------------------------
# Two fixes that both fall out of the FortiGate cutover on 2026-08-13, when
# labserver moved off the house LAN (10.0.0.41/24) onto its own segment
# (192.168.50.10/24) behind the gate.
#
#   1. Rebind Ollama from 0.0.0.0 -> 127.0.0.1.
#      Found listening wildcard on :11434 with NO authentication and proven
#      reachable from Romulus across the tailnet. ufw never sees tailscale0
#      traffic, so only the bind address can close this. Nothing breaks:
#      the only consumer is `odin`, a local CLI client.
#
#   2. Re-scope stale ufw rules onto the current LAN subnet.
#      Every rule still says 10.0.0.0/24 -- a network this box is no longer
#      on -- so the allow-list currently matches nothing.
#
# NO LOCKOUT RISK: admin access is Tailscale, and ufw does not filter
# tailscale0. Even a totally broken ruleset leaves `ssh jony@100.86.218.41`
# working. That is why this is safe to run unattended.
#
# Run ON labserver, needs sudo. Safe to run more than once.
#
#   bash setup-labserver-postgate.sh --dry-run   # show the plan, change nothing
#   bash setup-labserver-postgate.sh             # apply
#   bash setup-labserver-postgate.sh --ollama-only
#   bash setup-labserver-postgate.sh --ufw-only
# ---------------------------------------------------------------------------
set -euo pipefail

DRY=0; DO_OLLAMA=1; DO_UFW=1
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --ollama-only) DO_UFW=0 ;;
    --ufw-only)    DO_OLLAMA=0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '   \033[33mwarn\033[0m  %s\n' "$*"; }
plan() { printf '   \033[36mplan\033[0m  %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then plan "$*"; else eval "$@"; fi; }

STAMP="$(date +%Y%m%d-%H%M%S)"
[ "$DRY" = 1 ] && say "*** DRY RUN -- nothing will be changed ***"

# ===========================================================================
if [ "$DO_OLLAMA" = 1 ]; then
say "[1] Ollama bind address"

OVR=/etc/systemd/system/ollama.service.d/override.conf

if ! systemctl list-unit-files ollama.service >/dev/null 2>&1; then
  warn "ollama.service not present -- skipping"
else
  echo "   before: $(ss -tlnH 2>/dev/null | awk '$4 ~ /:11434$/ {print $4}' | paste -sd' ' -)"

  if [ -f "$OVR" ] && grep -q 'OLLAMA_HOST=127\.0\.0\.1:11434' "$OVR"; then
    ok "already bound to 127.0.0.1 -- nothing to do"
  else
    if [ -f "$OVR" ]; then
      run "sudo cp -a '$OVR' '${OVR}.bak.${STAMP}'"
      ok "backed up -> ${OVR}.bak.${STAMP}"
      # Replace whatever host:port is set with loopback. Handles 0.0.0.0,
      # ::, and a bare wildcard; leaves any other directives untouched.
      run "sudo sed -i -E 's|OLLAMA_HOST=[^\"]*|OLLAMA_HOST=127.0.0.1:11434|' '$OVR'"
    else
      run "sudo mkdir -p '$(dirname "$OVR")'"
      run "sudo tee '$OVR' >/dev/null <<'EOF'
[Service]
Environment=\"OLLAMA_HOST=127.0.0.1:11434\"
EOF"
    fi
    run "sudo systemctl daemon-reload"
    run "sudo systemctl restart ollama"
    [ "$DRY" = 0 ] && sleep 2
    ok "override written, daemon reloaded, service restarted"
  fi

  if [ "$DRY" = 0 ]; then
    AFTER="$(ss -tlnH 2>/dev/null | awk '$4 ~ /:11434$/ {print $4}' | paste -sd' ' -)"
    echo "   after:  ${AFTER:-<not listening>}"
    case "$AFTER" in
      127.0.0.1:11434) ok "VERIFIED loopback-only" ;;
      "")              warn "nothing listening on 11434 -- is ollama running?" ;;
      *)               warn "STILL NOT loopback: '$AFTER' -- investigate" ;;
    esac
    # Prove the tailnet path is closed, from the box itself.
    TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
    if [ -n "$TSIP" ]; then
      if timeout 3 bash -c "echo > /dev/tcp/${TSIP}/11434" 2>/dev/null; then
        warn "11434 still answers on the tailnet address ${TSIP} -- NOT fixed"
      else
        ok "11434 no longer answers on the tailnet address ${TSIP}"
      fi
    fi
  fi
fi
fi

# ===========================================================================
if [ "$DO_UFW" = 1 ]; then
say "[2] ufw -- re-scope stale subnet rules"

if ! command -v ufw >/dev/null 2>&1; then
  warn "ufw not installed -- skipping"
else
  # Current LAN CIDR, derived not hard-coded: this address has already moved
  # three times (10.0.0.40 -> .41 -> 192.168.50.10). Never bake it in.
  LANIF="$(ip -4 route show default | awk '{print $5; exit}')"
  LANCIDR="$(ip -4 -o addr show dev "$LANIF" | awk '{print $4; exit}')"
  NET="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))" "$LANCIDR")"
  echo "   interface  : $LANIF"
  echo "   address    : $LANCIDR"
  echo "   subnet now : $NET"

  BAK="/root/ufw-rules-backup-${STAMP}.txt"
  run "sudo sh -c 'ufw status numbered > $BAK'"
  ok "current ruleset backed up -> $BAK"

  echo
  echo "   --- current ---"
  sudo ufw status | sed 's/^/   /'

  # Find ALLOW rules whose source is a /24 that is NOT the current subnet.
  # Those are the leftovers from the pre-FortiGate world.
  STALE="$(sudo ufw status \
    | awk -v keep="$NET" '
        /ALLOW/ && $NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ && $NF != keep {
          print $1 "|" $NF
        }' | sort -u)"

  if [ -z "$STALE" ]; then
    ok "no stale subnet rules -- nothing to re-scope"
  else
    echo
    echo "   --- stale rules found ---"
    echo "$STALE" | sed 's/^/   /'
    echo

    echo "$STALE" | while IFS='|' read -r spec old; do
      [ -n "$spec" ] || continue
      port="${spec%%/*}"; proto="${spec##*/}"
      case "$proto" in
        tcp|udp) ;;
        *) warn "skipping '$spec' (no explicit proto -- handle by hand)"; continue ;;
      esac
      # Add the new rule BEFORE deleting the old one, so there is never a
      # window with neither in place.
      run "sudo ufw allow from $NET to any port $port proto $proto"
      run "sudo ufw delete allow from $old to any port $port proto $proto"
      ok "$spec : $old -> $NET"
    done

    echo
    echo "   --- after ---"
    [ "$DRY" = 0 ] && sudo ufw status | sed 's/^/   /'
  fi
fi
fi

# ===========================================================================
cat <<'EOF'

===========================================================================
NOTE -- what this deliberately did NOT decide
---------------------------------------------------------------------------
Re-scoping moved Samba (445/139/137/138) and Jellyfin (8096) onto the new
subnet. That is NOT the same as restoring them for Danny.

His house machines are on 10.0.0.0/24, the far side of the FortiGate. They
reach labserver only if a FortiGate policy lets them -- ufw is downstream of
that and cannot grant it. So these rules now serve whatever else lives on
192.168.50.0/24, which may be nothing but labserver itself.

The real question -- keep Samba and LAN Jellyfin, or move Danny to
Nextcloud/SFTP and a published Jellyfin -- is still HIS to answer. This
script preserves the existing intent so nothing is foreclosed; it does not
answer it. Once he decides, either open the path on the FortiGate or delete
these rules outright.

Next: Caddy will want 443 on this interface. Add it when Caddy lands, not now.
===========================================================================
EOF
