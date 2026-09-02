#!/usr/bin/env bash
#
# diag-labserver-logins.sh
# ---------------------------------------------------------------------------
# READ-ONLY. Answers "is anyone else working on labserver right now?" and
# "who has been logging in?" -- with no root, no installs, and no changes to
# the box. Everything it reads is world-readable state:
#
#   loginctl list-sessions   live systemd-logind sessions (all users)
#   /var/log/wtmp.db         Debian 13's login database (sqlite, mode 0644)
#   ps / uptime              running work + load
#
# Debian 13 (trixie) dropped classic utmp -- /run/utmp does not exist and
# `last` is not installed. wtmp.db is the replacement and it is readable by
# anyone, which is why this works as an ordinary user.
#
# Run ON labserver, or from Romulus:
#     ssh jony@100.86.218.41 'bash -s' < diag-labserver-logins.sh
#
#     bash diag-labserver-logins.sh        # default: 14 days of history
#     bash diag-labserver-logins.sh 30     # 30 days
# ---------------------------------------------------------------------------
set -uo pipefail

DAYS="${1:-14}"
ME="$(id -un)"
WTMPDB="/var/log/wtmp.db"

echo "=========================================================="
echo " labserver session report   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " host: $(hostname)   you: $ME   history window: ${DAYS}d"
echo "=========================================================="
echo

echo "--- Box state ---"
printf '  booted   : %s\n' "$(uptime -s)"
printf '  uptime   : %s\n' "$(uptime -p)"
printf '  load     : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
echo

# loginctl is the ONLY authority for who is live. wtmp.db records SSH logins
# only -- a console login on seat0/tty1 never appears in it, so a verdict built
# on wtmp alone reports "nobody here" while someone is sat at the machine.
# Class 'manager' rows are just the per-user systemd instance, not a login.
SESSIONS="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$6=="user"')"

echo "--- Live sessions (systemd-logind) ---"
if [ -z "$SESSIONS" ]; then
  echo "  (none)"
else
  printf '%s\n' "$SESSIONS" | while read -r sid uid user seat leader class tty idle since; do
    if [ "$seat" != "-" ]; then
      where="AT THE MACHINE (console $tty, seat $seat)"
    else
      where="remote/ssh"
    fi
    [ "$idle" = "yes" ] && idle_s="idle ${since:-?}" || idle_s="active"
    printf '  %-8s %-34s %s\n' "$user" "$where" "$idle_s"
  done
fi
echo
echo "--- Live sessions (who) ---"
who 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo

echo "--- Verdict ---"
OTHERS="$(printf '%s\n' "$SESSIONS" | awk -v me="$ME" '$3!=me && $3!="" {print $3}' | sort -u)"
if [ -n "$OTHERS" ]; then
  echo "  SOMEONE ELSE IS ON THE BOX RIGHT NOW: $(echo $OTHERS | tr '\n' ' ')"
  printf '%s\n' "$SESSIONS" | awk -v me="$ME" '$3!=me && $3!="" {
      printf "    %s: %s, idle=%s\n", $3, ($4!="-" ? "at the console (" $7 ")" : "remote/ssh"), $8 }'
  echo "  Coordinate before changing services, mounts, or the firewall."
else
  echo "  No other user has a live session right now."
fi
echo

echo "--- Non-system processes by user ---"
# Anything running under a real (uid>=1000) account, even with no live login:
# a detached job, a build, an editor left open.
ps -eo user:16,uid,etime,comm --no-headers 2>/dev/null \
  | awk '$2>=1000 && $2<65534 {print}' \
  | awk '{c[$1]++; if ($3>m[$1]) m[$1]=$3} END {for (u in c) printf "  %-14s %3d process(es), longest running %s\n", u, c[u], m[u]}' \
  | sort
[ -z "$(ps -eo uid --no-headers | awk '$1>=1000 && $1<65534')" ] && echo "  (none)"
echo

if [ ! -r "$WTMPDB" ]; then
  echo "--- Login history ---"
  echo "  $WTMPDB not readable -- cannot show history."
  exit 0
fi

BOOT_EPOCH="$(date -d "$(uptime -s)" +%s 2>/dev/null || echo 0)"
LIVE_USERS="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ',')"

python3 - "$WTMPDB" "$DAYS" "$ME" "$BOOT_EPOCH" "$LIVE_USERS" <<'PY'
import sqlite3, sys, time, datetime

path, days, me = sys.argv[1], int(sys.argv[2]), sys.argv[3]
boot_us    = int(sys.argv[4]) * 1_000_000
live_users = {u for u in sys.argv[5].split(",") if u}
now_us = int(time.time() * 1_000_000)
since  = now_us - days * 86400 * 1_000_000

con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
cur = con.execute(
    "SELECT User, Login, Logout, TTY, RemoteHost FROM wtmp "
    "WHERE Login >= ? ORDER BY Login DESC", (since,))
rows = cur.fetchall()

def ts(us):
    return datetime.datetime.fromtimestamp(us / 1_000_000).strftime("%Y-%m-%d %H:%M")

def dur(a, b):
    s = int((b - a) / 1_000_000)
    h, rem = divmod(s, 3600)
    return f"{h}h{rem//60:02d}m" if h else f"{rem//60}m"

# --- currently open (no logout recorded) ---
# A NULL Logout means "still open" OR "ended uncleanly" (crash, reboot, killed
# sshd). Anything that started before the current boot is stale, not live --
# without this guard a reboot would report a ghost user as logged in.
open_raw = [r for r in rows if r[2] is None]
open_now = [r for r in open_raw if r[1] >= boot_us]
stale    = [r for r in open_raw if r[1] <  boot_us]
others   = [r for r in open_now if r[0] != me]

print("--- Open SSH logins per wtmp.db (console logins are NOT recorded here) ---")
if not open_now:
    print("  (none)")
for user, login, _, tty, host in open_now:
    tag  = "  <- you" if user == me else ""
    seen = "" if not live_users or user in live_users else "  [no live logind session -- may be stale]"
    print(f"  {user:<10} since {ts(login)}  ({dur(login, now_us)} ago)  {tty or '-':<8} from {host or 'local console'}{tag}{seen}")
for user, login, _, tty, host in stale:
    print(f"  {user:<10} {ts(login)}  STALE (pre-dates the current boot -- session died uncleanly, not live)")
print()

recent = [r for r in rows if r[0] != me]
if recent:
    u, lg, lo, _, _ = recent[0]
    print(f"  Most recent SSH login by someone else: {u} at {ts(lg)}"
          + (f", out {ts(lo)}" if lo else " (still open)"))
    print()

# --- per-user summary ---
print(f"--- Per-user activity, last {days} days ---")
agg = {}
for user, login, logout, tty, host in rows:
    a = agg.setdefault(user, {"n": 0, "secs": 0, "last": 0, "hosts": set()})
    a["n"] += 1
    a["secs"] += int(((logout or now_us) - login) / 1_000_000)
    a["last"] = max(a["last"], login)
    if host:
        a["hosts"].add(host)
if not agg:
    print("  (no logins in window)")
for user, a in sorted(agg.items(), key=lambda kv: -kv[1]["last"]):
    print(f"  {user:<10} {a['n']:>3} login(s)  {a['secs']//3600:>4}h total  "
          f"last {ts(a['last'])}  from: {', '.join(sorted(a['hosts'])) or 'local console'}")
print()

# --- raw tail ---
print(f"--- Login history, last {days} days (newest first) ---")
if not rows:
    print("  (none)")
for user, login, logout, tty, host in rows[:40]:
    out = ts(logout) if logout else "-- still open --"
    print(f"  {user:<10} {ts(login)} -> {out:<16} {dur(login, logout or now_us):>6}  "
          f"{tty or '-':<8} {host or 'local console'}")
PY

echo
echo "(Read-only: nothing on labserver was modified.)"
