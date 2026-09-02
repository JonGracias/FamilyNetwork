#!/usr/bin/env bash
#
# setup-labserver-msg.sh
# ---------------------------------------------------------------------------
# Installs `hey` on labserver: a shared, on-box text conversation between the
# local users (Jon <-> Danny), with unsolicited notification in BOTH directions.
#
# Entirely local. No network service, no port, no ufw change, no third party,
# nothing leaves the box. It is a shared append-only file plus a shell hook.
#
# How the "unsolicited" part works, without any privilege tricks:
#   * live shell    -> a PROMPT_COMMAND hook prints new messages just before
#                      the user's next prompt (one stat per prompt)
#   * at login      -> /etc/profile.d shows anything unread
#   * not logged in -> it waits in the log; nothing is lost
#
# `wall`/`write` are deliberately NOT used: Debian 13 ships wall without setgid
# tty (post-wallescape CVE-2024-28085), so an unprivileged user cannot write to
# another user's pty anyway. The prompt hook gets the same effect, safely.
#
# Unread is tracked by BYTE OFFSET, not timestamp. An earlier version compared
# the read-marker's whole-second mtime against message timestamps while the
# "new mail?" test compared file mtimes at nanosecond precision -- so a message
# sent and read inside the same second was marked read without being shown.
# Offsets are exact and immune to clock granularity.
#
# Run this ON labserver as a user with sudo. Safe to run more than once:
# re-running only refreshes /usr/local/bin/hey and the hook. An existing
# chat.log is never touched.
#
#   bash setup-labserver-msg.sh
# ---------------------------------------------------------------------------
set -euo pipefail

SPOOL="/srv/msg"
LOG="${SPOOL}/chat.log"
GROUP="users"          # already contains deks, jony, jose
CMD="/usr/local/bin/hey"
HOOK="/etc/profile.d/zz-hey.sh"

echo "Spool   : $SPOOL"
echo "Command : $CMD"
echo "Hook    : $HOOK"
echo "Group   : $GROUP"
echo

echo "[1/5] Checking the shared group..."
if ! getent group "$GROUP" >/dev/null; then
  echo "   ERROR: group '$GROUP' does not exist -- aborting."
  exit 1
fi
echo "   $GROUP: $(getent group "$GROUP")"

echo "[2/5] Creating the spool..."
# 3775 = setgid (files inherit group $GROUP) + sticky (you can only delete
# your own read-markers, not someone else's).
sudo install -d -m 3775 -o root -g "$GROUP" "$SPOOL"
if [ ! -f "$LOG" ]; then
  sudo touch "$LOG"
  echo "   created $LOG"
else
  echo "   $LOG already exists -- left intact ($(wc -l <"$LOG") message(s))"
fi
sudo chown root:"$GROUP" "$LOG"
sudo chmod 664 "$LOG"
ls -ld "$SPOOL" "$LOG" | sed 's/^/   /'

echo "[3/5] Installing $CMD ..."
TMP="$(mktemp)"; trap 'rm -f "$TMP" "$TMP.hook"' EXIT
cat >"$TMP" <<'HEYEOF'
#!/usr/bin/env bash
# hey -- shared on-box conversation. See setup-labserver-msg.sh in the
# DG3030 repo. Local only: appends to /srv/msg/chat.log, talks to nothing.
set -uo pipefail

SPOOL="/srv/msg"
LOG="${SPOOL}/chat.log"
ME="$(id -un)"
MARK="${SPOOL}/.read.${ME}"
TAB="$(printf '\t')"

[ -r "$LOG" ] || { echo "hey: $LOG not readable -- is the spool set up?" >&2; exit 1; }

size() { stat -c %s "$LOG" 2>/dev/null || echo 0; }

# Bytes of the log this user has already been shown.
seen() {
  local n s
  n="$(cat "$MARK" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  s="$(size)"
  [ "$n" -gt "$s" ] && n=0          # log truncated or rotated -> start over
  echo "$n"
}

mark_read() { size >"$MARK" 2>/dev/null || true; }

unread_raw() { tail -c "+$(( $(seen) + 1 ))" "$LOG" 2>/dev/null; }

# Notification form: the message text and nothing else.
bare() { cut -d"$TAB" -f3- ; }

# History form: timestamp + who + text.
fmt() {
  awk -F'\t' '{ split($1, t, "|"); printf "  \033[2m%s\033[0m \033[1m%-6s\033[0m %s\n", t[1], $2, $3 }'
}

send() {
  local msg="$*" pending
  [ -n "${msg// /}" ] || return 0
  # Anything already waiting for us must be shown, not swallowed by the
  # mark_read below -- otherwise replying blind eats the other person's line.
  pending="$(unread_raw)"
  # tab-separated: "YYYY-MM-DD HH:MM|epoch <TAB> user <TAB> message"
  printf '%s|%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$(date +%s)" "$ME" "${msg//$'\n'/ }" >>"$LOG" \
    || { echo "hey: cannot write to $LOG (are you in the 'users' group?)" >&2; exit 1; }
  # Advance our own marker: without this your next prompt would announce your
  # own message back to you as unread.
  mark_read
  [ -n "$pending" ] && printf '%s\n' "$pending" | bare
  return 0
}

case "${1-}" in
  -u|--unread)          # print unread and mark read (used by the shell hooks)
    out="$(unread_raw)"
    [ -n "$out" ] && printf '%s\n' "$out" | bare
    mark_read
    ;;
  -c|--check)           # unread count, does NOT mark read
    out="$(unread_raw)"
    [ -n "$out" ] && printf '%s\n' "$out" | wc -l || echo 0
    ;;
  -n|--count)           # cheap boolean for the prompt hook
    [ "$(size)" -gt "$(seen)" ]
    ;;
  -f|--follow)          # live tail
    echo "  (following $LOG -- Ctrl-C to stop)"
    mark_read
    tail -f "$LOG" | fmt
    ;;
  -a|--all)             # whole history, with timestamps and senders
    fmt <"$LOG"; mark_read
    ;;
  -h|--help)
    cat <<'USAGE'
hey -- shared on-box conversation between local users.

  hey                     open the conversation: shows recent messages, then
                          type replies (one per line). Ctrl-D or 'q' to exit.
  hey "message"           send one message and exit
  hey -a, --all           print the whole history (with time and sender)
  hey -u, --unread        print unread message text, mark as read
  hey -f, --follow        live tail (like a chat window)
  hey -c, --check         number of unread messages

New messages appear on their own before your next shell prompt, showing just
the message text. Use `hey -a` when you want to see who said what, and when.

Messages are appended to /srv/msg/chat.log. Everyone in the 'users' group can
read and post. It never leaves this machine.
USAGE
    ;;
  "")                   # interactive
    tail -n 20 "$LOG" | fmt
    mark_read
    echo -e "  \033[2m-- type a message and press Enter. Ctrl-D or 'q' to quit. --\033[0m"
    while IFS= read -r -p "hey> " line; do
      [ "$line" = "q" ] && break
      send "$line"
    done
    echo
    ;;
  *)
    send "$@"
    ;;
esac
HEYEOF

if [ -f "$CMD" ] && sudo cmp -s "$TMP" "$CMD"; then
  echo "   already up to date -- leaving as is"
else
  sudo install -m 755 -o root -g root "$TMP" "$CMD"
  echo "   written (mode 755, root:root)"
fi

echo "[4/5] Installing the notification hook $HOOK ..."
cat >"$TMP.hook" <<'HOOKEOF'
# zz-hey.sh -- shows unread `hey` messages at login, and again before the next
# prompt if one arrives mid-session. Interactive shells only; costs one stat().
case $- in *i*) ;; *) return ;; esac
[ -x /usr/local/bin/hey ] || return

/usr/local/bin/hey --unread 2>/dev/null

__hey_check() {
  if /usr/local/bin/hey --count 2>/dev/null; then
    /usr/local/bin/hey --unread 2>/dev/null
  fi
}
case "${PROMPT_COMMAND-}" in
  *__hey_check*) ;;
  "")  PROMPT_COMMAND="__hey_check" ;;
  *)   PROMPT_COMMAND="${PROMPT_COMMAND%;};__hey_check" ;;
esac
HOOKEOF

if [ -f "$HOOK" ] && sudo cmp -s "$TMP.hook" "$HOOK"; then
  echo "   already up to date -- leaving as is"
else
  sudo install -m 644 -o root -g root "$TMP.hook" "$HOOK"
  echo "   written (mode 644, root:root)"
fi

echo "[5/5] Verifying..."
bash -n "$CMD" && echo "   hey: syntax OK"
bash -n "$HOOK" && echo "   hook: syntax OK"
hash -r 2>/dev/null || true
echo "   $CMD -> $(command -v hey 2>/dev/null || echo 'not on PATH in THIS shell')"
echo
echo "DONE."
echo
echo "Try it:"
echo "    hey \"testing -- Jon\"      # post a message"
echo "    hey                        # open the conversation"
echo "    hey -a                     # history, with time and sender"
echo
echo "New messages now appear as just the message text, on their own line,"
echo "before the recipient's next prompt. The hook only applies to NEW shells --"
echo "existing sessions must re-login to pick it up."
