#!/usr/bin/env bash
set -uo pipefail
echo "=== whisper-cli on this machine ==="
W=$(command -v whisper-cli || true)
echo "path: ${W:-NONE}"
if [ -n "$W" ]; then
  stat -f '%z %N' "$(readlink -f "$W" 2>/dev/null || echo "$W")"
  echo "--- otool -L ---"
  otool -L "$W" | sed -n '2,20p'
fi
echo "=== ffmpeg ==="
F=$(command -v ffmpeg || true); echo "path: ${F:-NONE}"
[ -n "$F" ] && stat -f '%z %N' "$F"
echo "=== whisper model files on this machine ==="
for d in "$HOME/Models/Whisper" "$HOME/.config/open-wispr/models" "$HOME/.cache/whisper.cpp"; do
  [ -d "$d" ] || { echo "$d: absent"; continue; }
  find "$d" -name '*.bin' -exec stat -f '%z %N' {} \;
done
echo "=== node / npm (the question being answered) ==="
echo "node: $(command -v node || echo NONE)  $(node --version 2>/dev/null)"
