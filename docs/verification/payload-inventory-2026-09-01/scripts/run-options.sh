#!/usr/bin/env bash
# RUN each assembled bundle. A size that was never executed is not an option, it is a guess.
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
STAGE="$SCRATCH/stage"
mkdir -p "$SCRATCH/fake-engine"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export RICHOS_ENGINE_DIR="$SCRATCH/fake-engine"
unset RICHOS_LORO_DIR LORO_CORPUS LORO_ROOT RICHOS_SERVICE_BIN RICHOS_NODE_BIN RICHOS_WHISPER_BIN RICHOS_FFMPEG_BIN

boot() {
  label="$1"; app="$2"
  echo "########## RUN $label ##########"
  "$app/Contents/MacOS/richos-tauri" > "$SCRATCH/run-$label.log" 2>&1 &
  pid=$!
  n=0
  while [ $n -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -qE "compute lease" "$SCRATCH/run-$label.log" 2>/dev/null && break
    n=$((n+1)); /bin/sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -E "compute lease|NO COMPUTE" "$SCRATCH/run-$label.log"
  echo
}

echo "node on PATH -> $(command -v node || echo NONE)"

# Option 1/D as it behaves when Claude Code IS installed on the machine.
unset RICHOS_CLAUDE_BIN
boot "nothing-extra-claude-present" "$STAGE/RichOS-nothing-extra.app"

# Option 1/D as it behaves when Claude Code is NOT installed (the first-run case D exists for).
RICHOS_CLAUDE_BIN="$SCRATCH/no-such-claude" boot "nothing-extra-claude-absent" "$STAGE/RichOS-nothing-extra.app"

# Option E2 — driving the binary that ships INSIDE the bundle, pristine.
echo "-- the bundled binary answers for itself:"
"$STAGE/RichOS-claude-pristine.app/Contents/Resources/claude" --version
RICHOS_CLAUDE_BIN="$STAGE/RichOS-claude-pristine.app/Contents/Resources/claude" boot "bundled-claude-pristine" "$STAGE/RichOS-claude-pristine.app"

# Option E — the re-signed copy, to show it also runs (and what it cost).
RICHOS_CLAUDE_BIN="$STAGE/RichOS-with-claude.app/Contents/Resources/claude" boot "bundled-claude-resigned" "$STAGE/RichOS-with-claude.app"
