#!/usr/bin/env bash
# diag-labserver-jellyfin-libs.sh -- READ-ONLY. Changes nothing.
#
# Answers: which Jellyfin libraries exist, what TYPE is each one, what paths
# does it point at, and can the jellyfin user actually READ those paths.
#
# Needs root only because /var/lib/jellyfin is 0750 jellyfin:adm and jony is
# not in adm.
#
#   sudo bash diag-labserver-jellyfin-libs.sh
#
# NOTE the sudo sh -c wrapper used throughout: `sudo cmd /path/*.glob` expands
# the glob as the CALLING user, not root, so it silently fails to expand on a
# directory you cannot traverse and errors on a literal path. Documented trap;
# hit twice already on this box.

set -uo pipefail
ROOT=/var/lib/jellyfin/root/default

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "Jellyfin service"
systemctl is-active jellyfin; systemctl show jellyfin -p User --value

say "Libraries (virtual folders) under $ROOT"
if [ ! -d "$ROOT" ]; then
  echo "  NO LIBRARY ROOT AT ALL -- Jellyfin has never had a library configured."
  exit 0
fi
ls -1 "$ROOT" 2>/dev/null | grep . || echo "  (none -- zero libraries configured)"

say "Per-library detail: TYPE and target paths"
for d in "$ROOT"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  # CollectionType is the field that decides metadata scraping. Empty/absent
  # means "Mixed content", which is almost never what you want.
  ctype=$(grep -ho '<CollectionType>[^<]*' "$d"/options.xml 2>/dev/null | sed 's/.*>//')
  printf '  %-24s type=%s\n' "$name" "${ctype:-<none/mixed>}"
  for lnk in "$d"*.mblink; do
    [ -e "$lnk" ] || continue
    tgt=$(cat "$lnk" 2>/dev/null)
    printf '      -> %s' "$tgt"
    if [ -d "$tgt" ]; then
      # Prove readability as the service account rather than inferring it
      # from the mode bits -- uid 101 is not in group jony and reads this
      # tree entirely through the other-bits.
      if sudo -u jellyfin test -r "$tgt" && sudo -u jellyfin test -x "$tgt"; then
        printf '  [jellyfin CAN read]  files=%s\n' \
          "$(sudo -u jellyfin find "$tgt" -type f 2>/dev/null | wc -l)"
      else
        printf '  [!! jellyfin CANNOT read]\n'
      fi
    else
      printf '  [!! path does not exist]\n'
    fi
  done
done

say "Do the three target dirs exist and can jellyfin read them?"
for p in /srv/datakiin/data/media/movies \
         /srv/datakiin/data/media/home-videos \
         /srv/datakiin/data/media/music; do
  printf '  %-42s ' "$p"
  if [ ! -d "$p" ]; then echo "MISSING"; continue; fi
  if sudo -u jellyfin test -x "$p"; then
    echo "readable by jellyfin, files=$(find "$p" -type f | wc -l)"
  else
    echo "!! NOT readable by jellyfin"
  fi
done
