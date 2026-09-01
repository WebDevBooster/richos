#!/usr/bin/env bash
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
APP="/Users/alex/ab/richos/.worktrees/echo-opus-p1/app/src-tauri/target/release/bundle/macos/RichOS.app"
mkdir -p "$SCRATCH/fake-engine"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset RICHOS_LORO_DIR LORO_CORPUS LORO_ROOT RICHOS_SERVICE_BIN RICHOS_NODE_BIN RICHOS_WHISPER_BIN RICHOS_FFMPEG_BIN

boot() {
  label="$1"
  echo "########## $label (RICHOS_ENGINE_DIR=$RICHOS_ENGINE_DIR) ##########"
  "$APP/Contents/MacOS/richos-tauri" > "$SCRATCH/boot-$label.log" 2>&1 &
  pid=$!
  n=0
  while [ $n -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -qE "compute lease" "$SCRATCH/boot-$label.log" 2>/dev/null && break
    n=$((n+1))
    /bin/sleep 1
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  cat "$SCRATCH/boot-$label.log"
  echo
}

echo "node -> $(command -v node || echo NONE)"
export RICHOS_ENGINE_DIR="$SCRATCH/fake-engine"
boot engine-ok
export RICHOS_ENGINE_DIR="$SCRATCH/no-such-engine-dir"
boot engine-missing
