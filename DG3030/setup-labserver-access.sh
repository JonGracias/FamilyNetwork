#!/usr/bin/env bash
#
# setup-labserver-access.sh
# ---------------------------------------------------------------------------
# Grants Romulus (jon@romulus) key-based SSH access to labserver, and turns
# OFF Tailscale SSH on THIS node -- Tailscale SSH cannot authorize a user the
# node is *shared* to (documented limitation), and while it's on it grabs
# port 22 before the normal SSH server, blocking key login too.
#
# Run this ON labserver, as a user with sudo. Safe to run more than once.
#
#   bash setup-labserver-access.sh              # defaults to user 'jony'
#   bash setup-labserver-access.sh someuser     # if the login is different
# ---------------------------------------------------------------------------
set -euo pipefail

TARGET_USER="${1:-jony}"
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGfo0QKJDgkiGTmNtbwUyMfyjqocb5PV613W0Sd+LrHN jon@romulus'

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || { echo "ERROR: user '$TARGET_USER' does not exist on this box."; exit 1; }
echo "Target user : $TARGET_USER"
echo "Home dir    : $HOME_DIR"
echo

echo "[1/3] Disabling Tailscale SSH on labserver (returns port 22 to normal sshd)..."
sudo tailscale set --ssh=false || echo "   note: 'tailscale set --ssh=false' returned nonzero; continuing"

echo "[2/3] Installing Romulus public key..."
sudo mkdir -p "$HOME_DIR/.ssh"
sudo chmod 700 "$HOME_DIR/.ssh"
AK="$HOME_DIR/.ssh/authorized_keys"
sudo touch "$AK"
if sudo grep -qxF "$PUBKEY" "$AK"; then
  echo "   key already present -- not duplicating"
else
  echo "$PUBKEY" | sudo tee -a "$AK" >/dev/null
  echo "   key added"
fi
sudo chmod 600 "$AK"
sudo chown -R "$TARGET_USER": "$HOME_DIR/.ssh"

echo "[3/3] Verifying..."
sudo ls -ld "$HOME_DIR/.ssh"
sudo ls -l  "$AK"
echo
echo "DONE.  Jon can now connect key-only:  ssh ${TARGET_USER}@100.86.218.41"
