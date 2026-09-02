#!/usr/bin/env bash
#
# diag-labserver-streaming.sh
# ---------------------------------------------------------------------------
# Answers "how many people can actually watch Jellyfin at once?" by measuring
# the two numbers that decide it, instead of guessing:
#
#   1. UPLOAD BANDWIDTH   -- the binding constraint for every remote viewer.
#                            CLAUDE.md flags it ("Upload bandwidth is Danny's
#                            home upload") but nobody has ever measured it.
#   2. GPU ENCODE          -- whether hardware acceleration is actually engaged,
#                            and how many concurrent NVENC sessions the driver
#                            permits before it refuses.
#
# Everything else (62 GiB RAM, NVMe media, 8C/16T) has orders of magnitude of
# headroom and is reported as inventory only.
#
# No root. No installs. No config is modified. Two caveats, stated plainly:
#   - the upload test WRITES a temp file under /tmp and deletes it on exit, and
#     it SENDS ~10 s of random bytes to Cloudflare's public speed endpoint.
#     Random data only -- nothing from the box. Skip it with --no-speed.
#   - --sessions loads the GPU with synthetic encodes for a few seconds. Ollama
#     holds ~5.1 GB VRAM; this needs a few hundred MB per session, so they
#     coexist, but don't run it while someone is mid-movie.
#
# Run ON labserver, or from Romulus:
#     ssh jony@100.86.218.41 'bash -s' < diag-labserver-streaming.sh
#     ssh jony@100.86.218.41 'bash -s' -- --sessions < diag-labserver-streaming.sh
#
#     bash diag-labserver-streaming.sh              # inventory + upload test
#     bash diag-labserver-streaming.sh --sessions   # + probe the NVENC cap
#     bash diag-labserver-streaming.sh --no-speed   # skip the bandwidth test
# ---------------------------------------------------------------------------
set -uo pipefail

DO_SPEED=1
DO_SESSIONS=0
for arg in "$@"; do
  case "$arg" in
    --no-speed)  DO_SPEED=0 ;;
    --sessions)  DO_SESSIONS=1 ;;
    -h|--help)   sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# jellyfin-ffmpeg is the build Jellyfin actually uses -- the distro ffmpeg may
# have different encoders compiled in, so testing the wrong binary would give a
# confident answer about a codepath Jellyfin never takes.
FFMPEG=""
for cand in /usr/lib/jellyfin-ffmpeg/ffmpeg /usr/bin/ffmpeg; do
  [ -x "$cand" ] && { FFMPEG="$cand"; break; }
done

TMPD="$(mktemp -d -t labstream.XXXXXX)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

UP_MBPS=0        # filled in by the bandwidth test
NVENC_CAP=0      # filled in by --sessions
HWACCEL="unknown"

echo "=========================================================="
echo " labserver streaming capacity   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " host: $(hostname)   you: $(id -un)"
echo "=========================================================="
echo

# ---------------------------------------------------------------------------
echo "--- Box state ---"
printf '  uptime   : %s\n' "$(uptime -p)"
printf '  load     : %s  (%s cores)\n' "$(cut -d' ' -f1-3 /proc/loadavg)" "$(nproc)"
printf '  mem free : %s\n' "$(free -h | awk '/^Mem:/ {print $7 " available of " $2}')"
echo

# ---------------------------------------------------------------------------
echo "--- Jellyfin ---"
if systemctl is-active --quiet jellyfin 2>/dev/null; then
  echo "  native jellyfin.service: ACTIVE"
elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qi jellyfin; then
  echo "  containerised jellyfin: RUNNING"
else
  echo "  no running Jellyfin found (native service inactive, no container)"
fi

# Where it listens matters: 0.0.0.0 means every tailnet node can reach it, the
# systemic issue recorded in CLAUDE.md. 127.0.0.1 means Caddy is fronting it.
BIND="$(ss -tlnH 2>/dev/null | awk '$4 ~ /:8096$/ {print $4}' | head -1)"
printf '  listening on 8096      : %s\n' "${BIND:-not listening}"
case "$BIND" in
  0.0.0.0:*|'*':*) echo "    ^ wildcard bind -- reachable from the whole tailnet (see CLAUDE.md)" ;;
esac

# Active transcodes = live ffmpeg children. This is also the honest way to see
# whether hwaccel is on: the command line names the encoder it chose.
#
# Match on the EXECUTABLE, not anywhere in the command line. The Jellyfin server
# is launched as "jellyfin --ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg", so a plain
# `pgrep -f ffmpeg` matches the server itself and reports a transcode that does
# not exist -- then blames the phantom on software encoding. pgrep -af prints
# "PID cmd args...", so field 2 is the binary: require IT to end in ffmpeg.
FFPROCS="$(pgrep -af 'ffmpeg' 2>/dev/null | grep -v diag-labserver | awk '$2 ~ /(^|\/)ffmpeg$/')"
NTRANS="$(printf '%s' "$FFPROCS" | grep -c . )"
printf '  transcodes right now   : %s\n' "$NTRANS"
if [ "$NTRANS" -gt 0 ]; then
  if printf '%s' "$FFPROCS" | grep -qE 'nvenc|hwaccel[= ]cuda'; then
    HWACCEL="GPU (proven live)"
    echo "    ^ NVENC in the live command line -- hardware encode CONFIRMED in use"
  else
    HWACCEL="CPU (proven live)"
    echo "    ^ NO nvenc in the live command line -- these are SOFTWARE transcodes"
  fi
  printf '%s\n' "$FFPROCS" | cut -c1-160 | sed 's/^/      /'
fi
echo

# ---------------------------------------------------------------------------
echo "--- Hardware acceleration config ---"
# Jellyfin's own setting. /etc/jellyfin is often 0640 root:jellyfin, so an
# unreadable file is expected, not a fault -- fall back to the live evidence.
ENC="/etc/jellyfin/encoding.xml"
if [ -r "$ENC" ]; then
  HWTYPE="$(grep -oPm1 '(?<=<HardwareAccelerationType>)[^<]*' "$ENC")"
  printf '  HardwareAccelerationType : %s\n' "${HWTYPE:-<empty>}"
  case "${HWTYPE,,}" in
    nvenc|cuda) echo "    ^ configured for NVIDIA -- good" ;;
    ''|none)    echo "    ^ NOT CONFIGURED. Every transcode is on the i7 (~3 streams, not ~8)." ;;
    *)          echo "    ^ set to '$HWTYPE', not the NVIDIA path -- check this" ;;
  esac
else
  echo "  $ENC not readable as $(id -un) -- relying on live process evidence above"
fi

if [ -n "$FFMPEG" ]; then
  printf '  ffmpeg in use            : %s\n' "$FFMPEG"
  # </dev/null is REQUIRED, not tidiness. This script is normally run as
  # `ssh host 'bash -s' < diag-...sh`, so the script itself is on stdin --
  # and ffmpeg reads stdin, so it can swallow the rest of the script or
  # return truncated output. Always detach stdin from ffmpeg here.
  NVENC_ENC="$("$FFMPEG" -hide_banner -encoders </dev/null 2>/dev/null \
                | awk '/nvenc/{print $2}' | tr '\n' ' ')"
  if [ -n "$NVENC_ENC" ]; then
    printf '    ^ this build HAS nvenc encoders: %s\n' "$NVENC_ENC"
  else
    # Report what was observed; do NOT assert "GPU encode is impossible".
    # An empty result here has been seen when the probe itself misfired,
    # while the same binary listed nvenc fine when run by hand.
    echo "    ^ no nvenc encoders reported by this probe -- VERIFY BY HAND before"
    echo "      believing it: $FFMPEG -hide_banner -encoders | grep nvenc"
  fi
else
  echo "  no ffmpeg binary found at the usual paths"
fi
echo

# ---------------------------------------------------------------------------
echo "--- GPU ---"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "  nvidia-smi not found -- no usable GPU, capacity is CPU-bound (~3 x 1080p)"
else
  nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu \
             --format=csv,noheader 2>/dev/null \
    | awk -F', *' '{printf "  %s   driver %s\n  VRAM %s total, %s used   GPU %s\n", $1,$2,$3,$4,$5}'

  # Live NVENC session count, straight from the driver. Not all builds populate
  # it; [N/A] is a reporting gap, not proof of zero.
  SESS="$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader 2>/dev/null)"
  printf '  NVENC sessions active    : %s\n' "${SESS:-unavailable}"

  echo "  VRAM consumers:"
  nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv,noheader 2>/dev/null \
    | sed 's/^/    /' | grep . || echo "    (none)"
  echo "    note: ollama holding ~5 GB is expected and leaves ample room for encode buffers"
fi
echo

# ---------------------------------------------------------------------------
# NVENC concurrent-session cap.
#
# GA106 silicon can encode well over a dozen 1080p streams; the real ceiling is
# NVIDIA's artificial per-driver session limit on GeForce cards, historically
# 3 -> 5 -> 8. Rather than trust a number off the internet for driver 550, start
# encoders one at a time and find where the driver says no.
if [ "$DO_SESSIONS" = 1 ]; then
  echo "--- NVENC concurrent session cap (measured) ---"
  if [ -z "$FFMPEG" ] || ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "  skipped -- needs both ffmpeg and an NVIDIA GPU"
  else
    PIDS=(); MAX=12; CAP=0
    for i in $(seq 1 $MAX); do
      "$FFMPEG" -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 120 \
        -c:v h264_nvenc -b:v 8M -f null - >"$TMPD/enc.$i.log" 2>&1 &
      PIDS+=($!)
      # Session refusal surfaces within a second or two of startup, so a short
      # settle is enough to tell "running" from "rejected".
      sleep 2
      if kill -0 "${PIDS[-1]}" 2>/dev/null && ! grep -qiE 'openencode|out of memory|no capable|not supported' "$TMPD/enc.$i.log"; then
        CAP=$i
        printf '  %2d concurrent : OK\n' "$i"
      else
        printf '  %2d concurrent : REFUSED -- %s\n' "$i" \
          "$(grep -iEm1 'openencode|out of memory|no capable|not supported' "$TMPD/enc.$i.log" | cut -c1-90)"
        break
      fi
    done
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    NVENC_CAP="$CAP"
    if [ "$CAP" -ge "$MAX" ]; then
      echo "  reached the probe ceiling of $MAX with no refusal -- cap is $MAX or higher"
    else
      echo "  MEASURED CAP: $CAP concurrent 1080p NVENC sessions"
    fi
  fi
  echo
fi

# ---------------------------------------------------------------------------
# Upload bandwidth. Sized adaptively: a fixed payload either takes forever on a
# 10 Mbps line or finishes too fast to measure on a 200 Mbps one.
if [ "$DO_SPEED" = 1 ]; then
  echo "--- Upload bandwidth (the binding constraint) ---"
  if ! command -v curl >/dev/null 2>&1; then
    echo "  curl not found -- cannot measure. Install speedtest-cli or test from another box."
  else
    ENDPOINT="https://speed.cloudflare.com/__up"
    measure() {  # $1 = bytes; echoes bytes/sec
      head -c "$1" /dev/urandom > "$TMPD/payload" 2>/dev/null || return 1
      curl -s -o /dev/null --max-time 90 \
           -H 'Content-Type: application/octet-stream' \
           --data-binary "@$TMPD/payload" \
           -w '%{speed_upload}' "$ENDPOINT" 2>/dev/null
    }

    echo "  warming up (6 MB)..."
    WARM="$(measure 6000000)"
    if [ -z "${WARM:-}" ] || awk -v w="${WARM:-0}" 'BEGIN{exit !(w<1000)}'; then
      echo "  test FAILED (no route to the endpoint, or blocked). Nothing was changed."
      echo "  Retry, or run: speedtest-cli --no-download"
    else
      # aim for ~10 s of transfer, clamped to 4-120 MB
      SIZE="$(awk -v w="$WARM" 'BEGIN{s=int(w*10); if(s<4000000)s=4000000; if(s>120000000)s=120000000; print s}')"
      printf '  measuring (%s MB, ~10 s)...\n' "$((SIZE/1000000))"
      BEST=0
      for run in 1 2; do
        R="$(measure "$SIZE")"
        [ -n "${R:-}" ] && BEST="$(awk -v a="$BEST" -v b="$R" 'BEGIN{print (b>a)?b:a}')"
      done
      UP_MBPS="$(awk -v b="$BEST" 'BEGIN{printf "%.1f", b*8/1000000}')"
      printf '  UPLOAD: %s Mbps  (best of 2, via %s)\n' "$UP_MBPS" "$ENDPOINT"
      echo "  note: this is the whole household's uplink, shared with everyone at home."
    fi
  fi
  echo
fi

# ---------------------------------------------------------------------------
echo "--- Verdict: concurrent viewers ---"
awk -v up="$UP_MBPS" -v cap="$NVENC_CAP" -v hw="$HWACCEL" -v cores="$(nproc)" 'BEGIN {
  if (up+0 <= 0) {
    print "  Upload not measured -- rerun without --no-speed. Without that number"
    print "  any answer here is a guess."
  } else {
    usable = up * 0.8   # leave the household a working connection
    printf "  Upload %.1f Mbps, budgeting %.1f Mbps for streaming (20%% headroom).\n\n", up, usable
    n = split("4 8 10 20 40", br, " ")
    lbl["4"]="720p transcode";        lbl["8"]="1080p transcode"
    lbl["10"]="1080p direct play";    lbl["20"]="1080p remux direct play"
    lbl["40"]="4K direct play"
    printf "    %-26s %-10s %s\n", "scenario", "per stream", "concurrent remote viewers"
    for (i = 1; i <= n; i++) {
      b = br[i]; v = int(usable / b)
      note = ""
      # NVENC only bounds the transcoding rows -- direct play does no encoding.
      if (cap+0 > 0 && (b == 4 || b == 8) && v > cap) { v = cap; note = "  (GPU session cap, not bandwidth)" }
      printf "    %-26s %-10s %d%s\n", lbl[b], b " Mbps", v, note
    }
  }
  print ""
  printf "  Hardware encode: %s\n", hw
  if (hw ~ /^CPU/) printf "    ^ software transcoding on %d cores tops out near 3 x 1080p.\n", cores
  if (cap+0 > 0) printf "  Measured NVENC cap: %d concurrent sessions.\n", cap
  else print "  NVENC cap not measured -- rerun with --sessions."
  print ""
  print "  Levers that actually raise the number:"
  print "    - per-user bitrate limits in Jellyfin (Dashboard > Users > remote ceiling)."
  print "      Capping remote users at 4 Mbps / 720p roughly doubles how many fit."
  print "    - direct play beats transcoding on CPU/GPU but costs MORE bandwidth."
  print "    - Docker does not change any number above. Same process, same uplink."
}'
echo

# ---------------------------------------------------------------------------
# The one way containerising makes things worse: no toolkit, no GPU in the
# container, silent fallback to CPU.
echo "--- Container readiness (if migrating Jellyfin into Docker) ---"
if command -v docker >/dev/null 2>&1; then
  echo "  docker: present"
  if [ -x /usr/bin/nvidia-ctk ] || dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q '^ii'; then
    echo "  nvidia-container-toolkit: INSTALLED -- containers can use the GPU"
  else
    echo "  nvidia-container-toolkit: MISSING"
    echo "    ^ a containerised Jellyfin would get NO GPU and fall back to CPU"
    echo "      silently -- roughly 8 streams down to 3. Install it before migrating."
  fi
else
  echo "  docker not found"
fi
echo

echo "(Read-only: no config, service, or firewall rule on labserver was modified.)"
