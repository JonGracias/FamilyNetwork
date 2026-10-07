#!/usr/bin/env bash
#
# setup-labserver-caddy-boot.sh -- make the Caddy stack survive a reboot.
#
# WHY THIS EXISTS
# ---------------
# labserver is powered off every night and booted every morning, so "does it
# come back after a reboot" is not a corner case here -- it is the daily
# operating mode. Caddy did not come back on 2026-09-01 or 2026-09-03.
#
# The 2026-09-03 failure named itself in the container's own state:
#
#   failed to bind host port 192.168.50.10:443/tcp: cannot assign requested
#   address
#
# compose.yml publishes two LITERAL host addresses (192.168.50.10:443 and
# 10.10.0.2:443) rather than 0.0.0.0 -- deliberately, because Docker DNATs
# published ports around ufw and a bare "443:443" would expose the proxy to
# every node on the tailnet. The cost of that correct decision is that the
# addresses must EXIST before dockerd starts the container.
#
# They do not, at boot:
#   - /etc/network/interfaces has "allow-hotplug enp2s0f0" + "inet dhcp", so
#     the lease is acquired asynchronously, AFTER networking.service returns.
#   - systemd-networkd-wait-online is DISABLED, so network-online.target is
#     reached without anything having waited for a routable address.
#   - docker.service therefore starts, restores its containers, hits an
#     address that does not exist yet, and gives up.
#
# The proof it is the bind and not something vaguer: cloudflared and the web
# nginx publish NO host ports, and both came back from the same boot without
# a scratch. The only container that failed is the only one that binds a host
# address.
#
# WHAT THIS DOES
# --------------
# Installs a systemd oneshot that waits for every address compose.yml actually
# publishes to appear on the host, and only then brings the stack up.
#
# It uses --force-recreate on purpose, which also repairs the DIFFERENT
# reboot failure seen on 2026-09-01, where the container started but attached
# to no network at all (only "lo", no eth0). A plain "docker restart" reuses
# the broken network config and comes back identical -- recreate does not.
#
# The addresses are PARSED OUT OF compose.yml rather than written here. This
# document's own repeated lesson is that a control expressed as a literal
# address is only as durable as the network it names -- ufw rules left
# pointing at a dead 10.0.0.0/24, a FortiGate policy written against a subnet
# that stopped existing. If compose.yml is ever re-pointed, this waits for the
# new addresses with no edit.
#
# Idempotent. Safe to re-run.
#
# Usage:  sudo bash setup-labserver-caddy-boot.sh
#
set -euo pipefail

STACK_DIR="${STACK_DIR:-/srv/datakiin/stacks/caddy}"
UNIT="/etc/systemd/system/datakiin-caddy.service"
WAITER="/usr/local/bin/wait-for-published-addrs"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run with sudo." >&2
    exit 1
fi

if [[ ! -f "$STACK_DIR/compose.yml" ]]; then
    echo "ERROR: no compose.yml at $STACK_DIR" >&2
    exit 1
fi

echo "==> installing $WAITER"
cat > "$WAITER" <<'WAITER_EOF'
#!/usr/bin/env bash
#
# Block until every literal IPv4 address published by a compose file is
# assigned to some interface on this host. Exits 0 as soon as they all are,
# or 1 on timeout.
#
# Addresses are derived from the compose file, never hardcoded, so this
# keeps working if the stack is re-pointed at different addresses.
#
set -euo pipefail

COMPOSE="${1:?usage: wait-for-published-addrs <compose.yml> [timeout_seconds]}"
TIMEOUT="${2:-120}"

# Pull the host side of "A.B.C.D:hostport:containerport" publish entries.
mapfile -t ADDRS < <(
    grep -oE '"[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+:[0-9]+"' "$COMPOSE" \
        | tr -d '"' | cut -d: -f1 | sort -u
)

if [[ ${#ADDRS[@]} -eq 0 ]]; then
    echo "no literal published addresses in $COMPOSE -- nothing to wait for"
    exit 0
fi

echo "waiting for: ${ADDRS[*]} (timeout ${TIMEOUT}s)"

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
    missing=()
    for a in "${ADDRS[@]}"; do
        # -o gives one line per address; match the address exactly.
        if ! ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 \
             | grep -qxF "$a"; then
            missing+=("$a")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "all published addresses present"
        exit 0
    fi

    if [[ $(date +%s) -ge $deadline ]]; then
        echo "TIMEOUT: still missing: ${missing[*]}" >&2
        exit 1
    fi

    sleep 2
done
WAITER_EOF
chmod 0755 "$WAITER"

echo "==> installing $UNIT"
cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=datakiin Caddy stack (waits for its published addresses first)
Documentation=https://github.com/JonGracias/FamilyNetwork
Requires=docker.service
After=docker.service network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$STACK_DIR

# network-online.target is NOT sufficient on this box: ifupdown's
# allow-hotplug + DHCP means the lease lands after the target is reached, and
# systemd-networkd-wait-online is disabled. Wait for the actual addresses.
ExecStartPre=$WAITER $STACK_DIR/compose.yml 120

# --force-recreate rather than "up -d": it repairs a container that came back
# attached to no network, which is the other way this has failed.
ExecStart=/usr/bin/docker compose up -d --force-recreate
ExecStop=/usr/bin/docker compose stop

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "==> reloading systemd"
systemctl daemon-reload

echo "==> enabling datakiin-caddy.service"
systemctl enable datakiin-caddy.service

cat <<'DONE'

Installed. Nothing has been started or restarted by this script.

Verify the waiter alone (safe, read-only, exits immediately if all present):
    wait-for-published-addrs /srv/datakiin/stacks/caddy/compose.yml 5

Bring the stack up through the new unit:
    sudo systemctl start datakiin-caddy.service
    ss -tln | grep 443

The real test is a reboot -- which on this box happens every morning anyway.
DONE
