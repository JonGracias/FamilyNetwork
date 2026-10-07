#!/bin/sh
# install-mc-router-sync.sh -- keep mc-router's live routes equal to its routes file.
#
# Run ON THE VPS, as root, AFTER install-mc-router.sh. Idempotent: run it again to update.
#
# mc-router's -routes-config-watch reload only ADDS routes; one the file drops stays live
# until a restart, and a restart drops every player. mc-router-sync.py removes them through
# mc-router's local API instead, every time the file changes (see that script's docstring).
set -eu

here=$(dirname "$0")
install -m 755 "$here/mc-router-sync.py" /usr/local/bin/mc-router-sync

cat > /etc/systemd/system/mc-router-sync.service <<'EOF'
[Unit]
Description=Make mc-router's live routes equal /etc/mc-router/routes.json
After=mc-router.service
Requires=mc-router.service

[Service]
Type=oneshot
User=mc-router
Group=mc-router
ExecStart=/usr/local/bin/mc-router-sync
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
EOF

cat > /etc/systemd/system/mc-router-sync.path <<'EOF'
[Unit]
Description=Sync mc-router whenever its routes file changes

[Path]
PathModified=/etc/mc-router/routes.json

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mc-router-sync.path
# Once now, so whatever is live already matches the file.
systemctl start mc-router-sync.service
journalctl -u mc-router-sync.service -n 5 --no-pager
