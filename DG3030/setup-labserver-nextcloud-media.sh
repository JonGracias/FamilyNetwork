#!/usr/bin/env bash
# setup-labserver-nextcloud-media.sh
#
# Wires the three media folders into Nextcloud as External Storage (Local)
# mounts, so uploads land as REAL FILES WITH REAL NAMES on the bind-mounted
# tree that Jellyfin reads.
#
# WHY EXTERNAL STORAGE AND NOT A NORMAL NEXTCLOUD FOLDER:
#   Nextcloud's own storage keeps files under data/<user>/files/ with the
#   database as the source of truth for names. Jellyfin, reading the same
#   disk, would see an opaque tree it cannot match to anything. A Local
#   external mount points Nextcloud at a directory that already exists and
#   leaves the filenames alone -- which is the entire requirement here.
#
# RUN ON labserver, AS ROOT (docker needs it; jony is password-sudo):
#   sudo bash setup-labserver-nextcloud-media.sh --dry-run   # look first
#   sudo bash setup-labserver-nextcloud-media.sh
#
# Idempotent: a mount whose datadir already matches is left alone.

set -euo pipefail

CONTAINER="nextcloud"
DRY_RUN=0
[ "${1-}" = "--dry-run" ] && DRY_RUN=1

# The container bind-mounts the WHOLE tree (/srv/datakiin/data/media -> /media),
# so adding a category is a new subdirectory here plus a mount row below --
# never a compose.yml change and never a container restart.
HOST_MEDIA="/srv/datakiin/data/media"

# Nextcloud runs as www-data = uid 33 INSIDE the container. There is no
# www-data:jony pair to name portably from the host, so the numeric uid is the
# reliable form.
NC_UID=33
MEDIA_GROUP="jony"

# mount point (what contributors see) | container path | Jellyfin library
# Mount points are lower-case to match the three that already exist live.
MOUNTS="
movies|/media/movies|Movies
home-videos|/media/home-videos|Home Videos and Photos
music|/media/music|Music
shows|/media/shows|Shows
"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
occ()  { docker exec -u www-data "$CONTAINER" php occ "$@"; }

# ---------------------------------------------------------------- diagnose
say "Container state"
docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}  {{.Status}}  {{.Image}}' \
  | grep . || { echo "FATAL: container '$CONTAINER' is not running."; exit 1; }

say "Nextcloud status"
occ status

say "Users that exist (answers 'which admin password is current?')"
occ user:list

say "Media tree as the container sees it"
docker exec "$CONTAINER" ls -la /media \
  || { echo "FATAL: /media is not bind-mounted into the container."; exit 1; }

say "Existing external mounts"
occ files_external:list --output=json | python3 -c '
import json,sys
try: rows = json.load(sys.stdin)
except Exception: rows = []
if not rows: print("  (none)")
for r in rows:
    print("  id=%s  point=%-14s datadir=%s" % (
        r.get("mount_id"), r.get("mount_point"),
        (r.get("configuration") or {}).get("datadir","?")))
' || echo "  (files_external not enabled yet)"

# --------------------------------------------------------- host directories
say "Ensuring host directories exist with the right ownership"
# All three bits are load-bearing and each failure looks like a different bug:
#   owner www-data (33)  -> Nextcloud can WRITE uploads.       Wrong: uploads fail.
#   group jony + g+w     -> Jon can rename over SSH.           Wrong: renames fail.
#   setgid (2xxx)        -> new subfolders inherit group jony. Wrong: breaks later, not now.
#   files land 0644      -> Jellyfin (uid 101, NOT in jony) reads via other-bits.
# A plain `mkdir` as root gets ALL of these wrong, which is why this block
# exists rather than trusting the directory to already be there.
printf '%s\n' "$MOUNTS" | while IFS='|' read -r point cpath jflib; do
  [ -z "${point:-}" ] && continue
  hpath="$HOST_MEDIA/${cpath#/media/}"
  if [ -d "$hpath" ]; then
    printf '  EXISTS  %-46s ' "$hpath"
  else
    printf '  CREATE  %-46s ' "$hpath"
    run mkdir -p "$hpath"
  fi
  run chown "$NC_UID:$MEDIA_GROUP" "$hpath"
  run chmod 2775 "$hpath"
  [ "$DRY_RUN" = 1 ] || stat -c '%A %u:%G' "$hpath"
  [ "$DRY_RUN" = 1 ] && echo
done

# ------------------------------------------------------------------ enable
say "Enabling files_external"
# Ships with Nextcloud but is disabled by default; creating a mount without
# it silently does nothing useful.
run docker exec -u www-data "$CONTAINER" php occ app:enable files_external

# ------------------------------------------------------------------ create
say "Creating the three Local mounts"
existing=$(occ files_external:list --output=json 2>/dev/null \
  | python3 -c '
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
for r in rows: print((r.get("configuration") or {}).get("datadir",""))
' || true)

printf '%s\n' "$MOUNTS" | while IFS='|' read -r point path jftype; do
  [ -z "${point:-}" ] && continue
  if printf '%s\n' "$existing" | grep -qxF "$path"; then
    echo "  SKIP  $point -> $path (already mounted)"
    continue
  fi
  echo "  ADD   $point -> $path   [Jellyfin library type: $jftype]"
  run docker exec -u www-data "$CONTAINER" php occ \
      files_external:create "$point" local null::null -c "datadir=$path"
done

# ----------------------------------------------------------------- options
say "Setting filesystem_check_changes on every local mount"
# Jon renames uploads into Jellyfin's naming convention from OUTSIDE Nextcloud
# (over SSH). Without this, Nextcloud caches the old listing and the rename is
# invisible in the web UI until something forces a rescan.
occ files_external:list --output=json 2>/dev/null | python3 -c '
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
for r in rows:
    if (r.get("configuration") or {}).get("datadir","").startswith("/media/"):
        print(r.get("mount_id"))
' | while read -r id; do
  [ -z "$id" ] && continue
  echo "  mount $id"
  run docker exec -u www-data "$CONTAINER" php occ \
      files_external:option "$id" filesystem_check_changes 1
done

# ------------------------------------------------------------------ verify
say "VERIFY -- final mount list"
occ files_external:list

say "VERIFY -- each mount answers"
occ files_external:list --output=json 2>/dev/null | python3 -c '
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
for r in rows: print(r.get("mount_id"))
' | while read -r id; do
  [ -z "$id" ] && continue
  printf '  mount %s: ' "$id"
  occ files_external:verify "$id" 2>&1 | tr '\n' ' '; echo
done

say "DONE"
cat <<'NEXT'
Next, on the Jellyfin side. All four libraries ALREADY EXIST and are already
the correct type (verified 2026-09-08 -- the type is a zero-byte marker file
such as movies.collection, not a field in options.xml). So do NOT create new
libraries: that would leave the family with two "Movies" entries.

Dashboard -> Libraries -> <the library> -> "+" under Folders, and ADD:

  Movies                 += /srv/datakiin/data/media/movies
  Home Videos and Photos += /srv/datakiin/data/media/home-videos
  Music                  += /srv/datakiin/data/media/music
  Shows                  += /srv/datakiin/data/media/shows

Each library then has two folders -- Danny's /mnt/media/Media/* and this
ingest tree -- presented as one merged view.

Note these are HOST paths -- Jellyfin is native, not containerised, so it does
not see the container's /media.

TV SHOWS NEED A STRICTER LAYOUT THAN MOVIES. Jellyfin matches episodes from
the path, so uploads have to end up as:

  Series Name (2019)/Season 01/Series Name S01E01.mkv

A loose pile of episode files in shows/ will not match and will display as a
mess -- the same failure mode as putting home videos in a Movies library. This
makes the shows renaming chore materially bigger than the movies one; budget
for it rather than discovering it after a bulk upload.

Jellyfin runs as uid 101 (jellyfin), which is not in group jony. It reads this
tree through the other-bits: every parent directory is o+x and uploads land
0644. Verified 2026-09-08. If a future change tightens those bits, playback
breaks while uploads keep working -- which looks like a Jellyfin bug and is not.
NEXT
