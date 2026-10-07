#!/usr/bin/env bash
# diag-labserver-media-verify.sh -- READ-ONLY. Changes nothing.
#
# Settles two questions the previous pass could not:
#   1. Did filesystem_check_changes actually persist? The `files_external:list`
#      table showed an empty Options column BEFORE and AFTER setting it, which
#      is either "it did not take" or "that table does not render it". Only the
#      JSON output distinguishes those.
#   2. Where does Jellyfin actually store a library's CollectionType? The last
#      probe grepped options.xml for <CollectionType> and got nothing for all
#      four libraries -- implausible for libraries named Movies/Music/Shows,
#      so the probe is the prime suspect, not the config.
#
#   sudo bash diag-labserver-media-verify.sh

set -uo pipefail
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "Q1: external mount options, as JSON (the authoritative view)"
docker exec -u www-data nextcloud php occ files_external:list --output=json \
  | tr ',' '\n' | grep -i 'mount_id\|mount_point\|datadir\|option\|filesystem' \
  || echo "  (no output)"

say "Q1b: raw JSON for mount 1 only"
docker exec -u www-data nextcloud php occ files_external:list --output=json \
  | head -c 1200; echo

say "Q2: what files does a Jellyfin library folder actually contain?"
sudo sh -c 'for d in /var/lib/jellyfin/root/default/*/; do
  echo "--- $d"; ls -la "$d"
done'

say "Q2b: full options.xml for the Movies library"
sudo sh -c 'cat "/var/lib/jellyfin/root/default/Movies/options.xml" 2>/dev/null | head -40' \
  || echo "  (none)"

say "Q2c: anything anywhere naming the collection type"
sudo sh -c 'grep -ril "collectiontype\|movies\|tvshows\|homevideos\|music" \
  /var/lib/jellyfin/root/default/ 2>/dev/null | head -20'

say "Q3: Jellyfin library paths, from the library DB view"
sudo sh -c 'ls -la /var/lib/jellyfin/data/ 2>/dev/null | head -20'
