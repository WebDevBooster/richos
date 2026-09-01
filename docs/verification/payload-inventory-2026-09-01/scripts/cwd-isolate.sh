#!/usr/bin/env bash
# Isolate the variable: is the "binary was not found" on a customer Mac caused by the
# WORKING DIRECTORY rather than by a missing binary? One variable changes between the runs.
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
APP="$SCRATCH/stage/RichOS-nothing-extra.app"
mkdir -p "$SCRATCH/fake-engine"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset RICHOS_CLAUDE_BIN RICHOS_LORO_DIR LORO_CORPUS LORO_ROOT RICHOS_SERVICE_BIN
export RICHOS_ENTITY=richos
cd /

boot() {
  label="$1"
  echo "### $label — cwd=$(pwd)  RICHOS_ENGINE_DIR=${RICHOS_ENGINE_DIR:-<unset>}"
  "$APP/Contents/MacOS/richos-tauri" > "$SCRATCH/iso-$label.log" 2>&1 &
  pid=$!
  n=0
  while [ $n -lt 25 ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -qE "compute lease" "$SCRATCH/iso-$label.log" 2>/dev/null && break
    n=$((n+1)); /bin/sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -E "compute lease|NO COMPUTE|cause " "$SCRATCH/iso-$label.log"
  echo
}

unset RICHOS_ENGINE_DIR
boot "A-cwd-root-default-enginedir"

export RICHOS_ENGINE_DIR="$SCRATCH/fake-engine"
boot "B-cwd-root-explicit-enginedir"
