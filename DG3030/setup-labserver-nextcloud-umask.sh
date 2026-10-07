#!/usr/bin/env bash
# setup-labserver-nextcloud-umask.sh
#
# Fixes the 2755 problem: every directory Nextcloud creates inside the media
# mounts arrives group-jony but NOT group-writable, which blocks the documented
# SSH renaming chore inside precisely the folders that hold the content.
#
# TWO HALVES, BOTH REQUIRED -- this is the point of the script:
#   FUTURE  compose.yml sets umask 0002 on the apache process, so newly created
#           dirs are 0775 and files 0664 from now on.
#   PRESENT a one-time chmod repairs what already exists. The umask cannot
#           reach backwards, and the chmod cannot reach forwards -- doing only
#           one of them looks fixed and is not.
#
# Jellyfin is unaffected either way: uid 101, not in group jony, reads through
# the other-bits (dirs stay r-x, files stay r).
#
# RUN ON labserver, AS ROOT:
#   sudo bash setup-labserver-nextcloud-umask.sh --dry-run
#   sudo bash setup-labserver-nextcloud-umask.sh
#
# Idempotent. Safe to re-run.

set -euo pipefail

STACK=/srv/datakiin/stacks/nextcloud
MEDIA=/srv/datakiin/data/media
CONTAINER=nextcloud
DRY_RUN=0
[ "${1-}" = "--dry-run" ] && DRY_RUN=1

# Under --dry-run nothing is applied, so the closing checks re-read the SAME
# state as the opening ones. Labelling those "AFTER" made a dry run print
# "expect 0" against 3, and "STILL NOT WRITABLE", which reads as a failed fix
# rather than as a preview. Label them for what they are.
if [ "$DRY_RUN" = 1 ]; then
  PHASE="UNCHANGED (dry run)"
else
  PHASE="AFTER"
fi

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- diagnose
say "BEFORE -- apache process umask (the authority, not a fresh shell)"
# /proc/PID/status exposes Umask. A `docker exec sh -c umask` would report the
# NEW shell's umask and tell you nothing about the running server.
docker exec "$CONTAINER" grep -H Umask /proc/1/status 2>/dev/null \
  || echo "  (could not read; container may not be running)"

say "BEFORE -- directory modes in the ingest tree"
find "$MEDIA" -type d -printf '%M %u:%G  %p\n' | head -20
echo "  non-group-writable dirs: $(find "$MEDIA" -type d ! -perm -g=w | wc -l)"

say "compose.yml: is the umask command present?"
if grep -q 'umask 0002 && exec apache2-foreground' "$STACK/compose.yml"; then
  echo "  YES -- already patched"
  PATCHED=1
else
  echo "  NO -- the file on the box predates this fix."
  echo "  Copy the repo's nextcloud/compose.yml over $STACK/compose.yml first,"
  echo "  then re-run. Not editing it from here: the repo is the source of"
  echo "  truth and the box is meant to stay byte-identical to it."
  PATCHED=0
fi

# ------------------------------------------------------------ future files
if [ "$PATCHED" = 1 ]; then
  say "Recreating the container so the new command takes effect"
  # --force-recreate, not restart: a plain restart reuses the old container
  # config and would come back with the same umask, looking like the fix failed.
  run docker compose -f "$STACK/compose.yml" --project-directory "$STACK" up -d --force-recreate app
else
  say "SKIPPING recreate -- compose.yml is not patched yet"
fi

# ----------------------------------------------------------- existing files
say "Repairing modes on what already exists"
echo "  dirs  -> 2775 (group-writable + setgid, so the chore works and children inherit)"
echo "  files -> 0664 (group-writable; other keeps r, which is all Jellyfin needs)"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] would chmod $(find "$MEDIA" -type d ! -perm 2775 | wc -l) dirs"
  echo "  [dry-run] would chmod $(find "$MEDIA" -type f ! -perm 0664 | wc -l) files"
else
  find "$MEDIA" -type d -exec chmod 2775 {} +
  find "$MEDIA" -type f -exec chmod 0664 {} +
fi

# ------------------------------------------------------------------ verify
say "$PHASE -- apache process umask"
docker exec "$CONTAINER" grep -H Umask /proc/1/status 2>/dev/null \
  || echo "  (container not running)"
if [ "$DRY_RUN" = 1 ]; then echo "  (still 0022 -- correct, nothing was applied; expect 0002 after a real run)"; else echo "  expect Umask: 0002"; fi

say "$PHASE -- directory modes"
find "$MEDIA" -type d -printf '%M %u:%G  %p\n' | head -20
n=$(find "$MEDIA" -type d ! -perm -g=w | wc -l); if [ "$DRY_RUN" = 1 ]; then echo "  non-group-writable dirs: $n  (unchanged -- the repair was not run)"; else echo "  non-group-writable dirs remaining: $n  (expect 0)"; fi

say "$PHASE -- can jony actually write into an uploaded folder?"
# The real test. Mode bits are the mechanism; this is the requirement.
TESTDIR=$(find "$MEDIA" -mindepth 2 -type d | head -1)
if [ -n "${TESTDIR:-}" ]; then
  if sudo -u jony test -w "$TESTDIR"; then
    echo "  WRITABLE by jony: $TESTDIR"
  else
    if [ "$DRY_RUN" = 1 ]; then echo "  not yet writable by jony: $TESTDIR  (expected -- dry run)"; else echo "  !! STILL NOT WRITABLE by jony: $TESTDIR"; fi
  fi
else
  echo "  (no nested directory to test yet)"
fi

say "$PHASE -- Nextcloud still serving?"
docker ps --filter "name=^${CONTAINER}$" --format '  {{.Names}}  {{.Status}}'

cat <<'NEXT'

STILL WORTH DOING, and it is the only real proof:
  Upload a file through https://cloud.datakiin.com into a NEW folder, then
  check that folder on the host:

    ls -ld /srv/datakiin/data/media/<mount>/<new folder>

  Expect drwxrwsr-x. If it is drwxr-sr-x, the umask did not take -- check
  `docker exec nextcloud grep Umask /proc/1/status` rather than guessing.
  Verifying the mode bits above only proves the repair; it does not prove
  the umask, because the repair would produce the same reading either way.
NEXT
