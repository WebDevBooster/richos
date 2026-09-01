#!/usr/bin/env bash
# Same environment as a normal run; the ONLY change is that node is not on PATH.
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
cd /Users/alex/ab/richos/.worktrees/echo-opus-p1/app
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
echo "node on PATH? -> $(command -v node || echo NONE)"
echo "npm  on PATH? -> $(command -v npm  || echo NONE)"
unset RICHOS_LORO_DIR RICHOS_SERVICE_BIN RICHOS_NODE_BIN
./target/release/examples/native_roundtrip "$SCRATCH/nonode-cwd" "Reply with exactly: NODE-FREE-TURN-OK"
echo "EXIT=$?"
