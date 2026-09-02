#!/usr/bin/env bash
#
# setup-labserver-powerctl.sh
# ---------------------------------------------------------------------------
# Lets 'jony' run EXACTLY TWO root commands without a password:
#
#     systemctl poweroff
#     systemctl reboot
#
# Why: jony's sudo is password-required (by Danny's deliberate config), and
# polkit denies power-off to a remote SSH session. So a remote shutdown is
# impossible non-interactively -- see CLAUDE.md "sudo:" note. This drop-in
# opens that one door and nothing else.
#
# Run this ON labserver, as a user with sudo. Safe to run more than once.
#
#   bash setup-labserver-powerctl.sh              # install (defaults to 'jony')
#   bash setup-labserver-powerctl.sh someuser     # different login
#   bash setup-labserver-powerctl.sh --dry-run    # show the file, change nothing
#   bash setup-labserver-powerctl.sh --check      # report current state only
#   bash setup-labserver-powerctl.sh --uninstall  # remove the drop-in
#
# SAFETY: a malformed /etc/sudoers.d file breaks sudo for EVERYONE and is a
# rescue-media recovery. This script therefore builds the file in a temp
# location, validates it with `visudo -cf`, and only then installs it. It
# never edits /etc/sudoers itself.
# ---------------------------------------------------------------------------
set -euo pipefail

# Filename deliberately has NO dot and NO trailing '~': sudo silently IGNORES
# files in sudoers.d containing '.' or ending in '~'. A file named
# "labserver-powerctl.conf" would install cleanly and do nothing at all.
DROPIN_NAME="labserver-powerctl"
DROPIN="/etc/sudoers.d/${DROPIN_NAME}"

MODE="install"
TARGET_USER="jony"
for arg in "$@"; do
  case "$arg" in
    --dry-run)   MODE="dry-run" ;;
    --check)     MODE="check" ;;
    --uninstall) MODE="uninstall" ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    -*)          echo "ERROR: unknown flag '$arg'"; exit 1 ;;
    *)           TARGET_USER="$arg" ;;
  esac
done

getent passwd "$TARGET_USER" >/dev/null \
  || { echo "ERROR: user '$TARGET_USER' does not exist on this box."; exit 1; }

# Resolve systemctl at RUNTIME rather than hard-coding /usr/bin/systemctl.
# sudo matches the command by ABSOLUTE PATH, so a wrong path here yields a
# rule that parses fine and never fires. (Same lesson as postgate deriving
# the LAN subnet at runtime.)
SYSTEMCTL="$(command -v systemctl || true)"
[ -n "$SYSTEMCTL" ] || { echo "ERROR: systemctl not found in PATH."; exit 1; }
SYSTEMCTL="$(readlink -f "$SYSTEMCTL")"

echo "Target user : $TARGET_USER"
echo "systemctl   : $SYSTEMCTL"
echo "Drop-in     : $DROPIN"
echo

# --- state report ----------------------------------------------------------
report_state() {
  echo "--- current state ---"
  if sudo test -f "$DROPIN"; then
    echo "drop-in: PRESENT"
    sudo ls -l "$DROPIN"
    echo "contents:"
    sudo cat "$DROPIN" | sed 's/^/    /'
  else
    echo "drop-in: absent"
  fi
  echo
  echo "effective rules for $TARGET_USER:"
  sudo -l -U "$TARGET_USER" 2>&1 | sed 's/^/    /' || true
}

if [ "$MODE" = "check" ]; then
  report_state
  exit 0
fi

if [ "$MODE" = "uninstall" ]; then
  if sudo test -f "$DROPIN"; then
    sudo rm -f "$DROPIN"
    echo "Removed $DROPIN"
  else
    echo "Nothing to remove; $DROPIN does not exist."
  fi
  sudo visudo -c >/dev/null && echo "sudoers still valid."
  exit 0
fi

# --- build the rule --------------------------------------------------------
# Each command is pinned WITH its argument. sudo matches the full argv, so
# this grants 'systemctl poweroff' and 'systemctl reboot' and denies
# 'systemctl <anything-else>'. Bare '/usr/bin/systemctl' would have been
# unrestricted root (systemctl can edit and start arbitrary units).
read -r -d '' RULE <<EOF || true
# Installed by setup-labserver-powerctl.sh -- DG3030 / Datakiin homelab.
# Purpose: allow remote, non-interactive shutdown & reboot over SSH.
# Scope is intentionally two exact commands. Do NOT widen this to a bare
# path -- '/usr/bin/systemctl' with no argument is full root.
Cmnd_Alias LABSERVER_POWERCTL = ${SYSTEMCTL} poweroff, ${SYSTEMCTL} reboot
${TARGET_USER} ALL=(root) NOPASSWD: LABSERVER_POWERCTL
EOF

if [ "$MODE" = "dry-run" ]; then
  echo "--- would install $DROPIN (mode 0440, root:root) ---"
  printf '%s\n' "$RULE" | sed 's/^/    /'
  echo
  echo "--- validating syntax (no install) ---"
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  printf '%s\n' "$RULE" > "$TMP"
  if visudo -cf "$TMP"; then echo "syntax OK"; else echo "SYNTAX FAILED -- would NOT install"; exit 1; fi
  echo
  report_state
  exit 0
fi

# --- preflight -------------------------------------------------------------
echo "[1/5] Confirming /etc/sudoers.d is actually included..."
if sudo grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
  echo "   includedir present -- drop-ins are read"
else
  echo "   ERROR: /etc/sudoers has no '@includedir /etc/sudoers.d'."
  echo "   A drop-in would be inert. Fix /etc/sudoers by hand with 'sudo visudo' first."
  exit 1
fi

echo "[2/5] Writing candidate to a temp file..."
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$RULE" > "$TMP"
chmod 0440 "$TMP"

echo "[3/5] Validating with visudo BEFORE touching /etc..."
if sudo visudo -cf "$TMP"; then
  echo "   syntax OK"
else
  echo "   ERROR: candidate failed validation. Nothing was installed."
  exit 1
fi

echo "[4/5] Installing..."
if sudo test -f "$DROPIN" && sudo cmp -s "$TMP" "$DROPIN"; then
  echo "   identical file already present -- no change"
else
  sudo install -o root -g root -m 0440 "$TMP" "$DROPIN"
  echo "   installed $DROPIN"
fi

echo "[5/5] Verifying the whole sudoers tree still parses..."
sudo visudo -c

echo
report_state
cat <<EOF

DONE.

Test it from Romulus (should print the two commands, no password prompt):
    ssh ${TARGET_USER}@100.86.218.41 'sudo -n -l'

Then a real remote shutdown becomes:
    ssh ${TARGET_USER}@100.86.218.41 'sudo -n systemctl poweroff'

READ THIS BEFORE YOU USE IT
  * This does NOT give remote power-ON. enp2s0f0 (the live NIC) has PCI
    wakeup 'disabled', and the only NIC with wakeup enabled -- enp6s0 --
    has no cable. Board is an ASUS PRIME Z490-A: no IPMI. Once it is off
    it stays off until someone at Danny's house presses the button.
  * Anyone holding Romulus's SSH key can now power the box off without a
    password. That is denial-of-service reach, not data reach -- but it is
    new reach that did not exist before. The SSH key is the only control.
  * This is Danny's machine and it weakens a restriction Danny chose
    deliberately. Clear it with him before installing.
  * Undo at any time:  bash $(basename "$0") --uninstall
EOF
