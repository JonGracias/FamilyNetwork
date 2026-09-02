#!/usr/bin/env bash
#
# setup-labserver-ollama-cmd.sh
# ---------------------------------------------------------------------------
# Installs a system-wide `odin` command on labserver: any local user (SSH or
# console) types `odin` and gets an interactive chat with the local Ollama model.
#
# Least exposure: this touches NOTHING but /usr/local/bin/odin. No OLLAMA_HOST
# change, no 0.0.0.0 bind, no ufw rules -- Ollama stays on 127.0.0.1:11434 and
# `odin` is a local-only client. Nothing secret is written.
#
# Run this ON labserver, as a user with sudo. Safe to run more than once.
#
#   bash setup-labserver-ollama-cmd.sh                 # defaults to llama3.1:8b
#   bash setup-labserver-ollama-cmd.sh mistral:7b      # different model
# ---------------------------------------------------------------------------
set -euo pipefail

MODEL="${1:-llama3.1:8b}"
CMD_NAME="odin"
TARGET="/usr/local/bin/${CMD_NAME}"

echo "Command : $CMD_NAME"
echo "Model   : $MODEL"
echo "Target  : $TARGET"
echo

echo "[1/5] Checking for the ollama binary..."
if ! command -v ollama >/dev/null 2>&1; then
  echo "   ERROR: 'ollama' not found on PATH. Install Ollama first -- aborting."
  exit 1
fi
echo "   found: $(command -v ollama)  ($(ollama --version 2>/dev/null | tr -d '\r' | head -n1))"

echo "[2/5] Checking the ollama service is active..."
if ! systemctl is-active --quiet ollama; then
  echo "   ERROR: ollama.service is not active ('systemctl status ollama' to see why) -- aborting."
  exit 1
fi
echo "   ollama.service: active"

echo "[3/5] Checking the model is pulled..."
if ollama list 2>/dev/null | awk '{print $1}' | grep -qxF "$MODEL"; then
  echo "   $MODEL present"
else
  echo "   WARNING: '$MODEL' is not in 'ollama list'. Installing the command anyway;"
  echo "            pull it with:  ollama pull $MODEL"
fi

echo "[4/5] Installing $TARGET ..."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat >"$TMP" <<EOF
#!/usr/bin/env bash
exec ollama run ${MODEL} "\$@"
EOF

if [ -f "$TARGET" ] && sudo cmp -s "$TMP" "$TARGET"; then
  echo "   already up to date -- leaving as is"
  sudo chmod 755 "$TARGET"
else
  sudo install -m 755 -o root -g root "$TMP" "$TARGET"
  echo "   written (mode 755, root:root)"
fi

echo "[5/5] Verifying..."
ls -l "$TARGET"
echo "   --- contents ---"
sed 's/^/   /' "$TARGET"
echo "   ----------------"
hash -r 2>/dev/null || true
echo "   resolves to: $(command -v "$CMD_NAME" || echo "NOT ON PATH (is /usr/local/bin in PATH?)")"
echo
echo "DONE.  Any local user can now run:"
echo "    $CMD_NAME                     # interactive chat with $MODEL (Ctrl-D or /bye to exit)"
echo "    $CMD_NAME \"one-shot question\"  # single prompt, prints the answer and exits"
echo
echo "Local only by design: it talks to Ollama on 127.0.0.1:11434. Nothing is exposed."
