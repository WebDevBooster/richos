#!/usr/bin/env bash
# run-unit.sh <label> [TestClass-or-test ...]
# workspaces.test.py from the zach-fable-m5 worktree, sandboxed twice (the file
# redirects HOME/CLAUDE_CONFIG_DIR itself; this wrapper exports the outer
# sandbox too). No arguments after the label = every test.
set -uo pipefail
S="${RICHOS_R8_SCRATCH:-/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad}"
W="${RICHOS_R8_WORKTREE:-/Users/alex/ab/richos-wt/zach-fable-m5}"
LABEL="${1:-unit}"; shift || true
mkdir -p "$S/$LABEL/outer-home/.claude" "$S/$LABEL/outer-ws" "$S/$LABEL/outer-sessions"
export CLAUDE_CONFIG_DIR="$S/$LABEL/outer-home/.claude" RICHOS_WORKSPACES_DIR="$S/$LABEL/outer-ws" RICHOS_SESSIONS_DIR="$S/$LABEL/outer-sessions"
OUT="$S/$LABEL/unit.txt"
{
  echo "label: $LABEL  started: $(date -u +%FT%TZ)  args: $*"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | wc -l | tr -d ' ')"
  echo "engine: $W/engine  workspaces.py sha256: $(shasum -a 256 "$W/engine/scripts/lib/workspaces.py" | cut -c1-16)"
  (cd "$W" && python3 -B -W ignore engine/scripts/lib/workspaces.test.py "$@"); rc=$?
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
grep -E '^  FAIL|^=== workspaces|^exit:' "$OUT"
