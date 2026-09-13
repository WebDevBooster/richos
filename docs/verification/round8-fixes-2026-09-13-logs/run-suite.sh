#!/usr/bin/env bash
# run-suite.sh <label> <suite path relative to the worktree> [args...]
# Any *.test.sh / *.mutation.sh of the engine, from the zach-fable-m5 worktree,
# with the outer sandbox exported so nothing reaches the operator's store.
set -uo pipefail
S="${RICHOS_R8_SCRATCH:-/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad}"
W="${RICHOS_R8_WORKTREE:-/Users/alex/ab/richos-wt/zach-fable-m5}"
LABEL="${1:?label}"; SUITE="${2:?suite}"; shift 2
mkdir -p "$S/$LABEL/outer-home/.claude" "$S/$LABEL/outer-ws" "$S/$LABEL/outer-sessions"
export CLAUDE_CONFIG_DIR="$S/$LABEL/outer-home/.claude" RICHOS_WORKSPACES_DIR="$S/$LABEL/outer-ws" RICHOS_SESSIONS_DIR="$S/$LABEL/outer-sessions"
OUT="$S/$LABEL/suite.txt"
{
  echo "label: $LABEL  suite: $SUITE  started: $(date -u +%FT%TZ)  args: $*"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | wc -l | tr -d ' ')"
  (cd "$W" && bash "$SUITE" "$@"); rc=$?
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
grep -E '^  FAIL|^UNPROVEN|^=== |^exit:|passed|proven' "$OUT" | tail -12
