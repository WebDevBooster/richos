#!/usr/bin/env bash
# run-suite.sh <label> <relative suite path> — sandboxed, from frank-fable-c9's worktree
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/frank-c9
W=/Users/alex/ab/richos-wt/frank-fable-c9
LABEL="$1"; SUITE="$2"
mkdir -p "$S/$LABEL/outer-home/.claude" "$S/$LABEL/outer-ws" "$S/$LABEL/outer-sessions"
export CLAUDE_CONFIG_DIR="$S/$LABEL/outer-home/.claude" RICHOS_WORKSPACES_DIR="$S/$LABEL/outer-ws" RICHOS_SESSIONS_DIR="$S/$LABEL/outer-sessions"
OUT="$S/$LABEL/suite.txt"
{
  echo "label: $LABEL  suite: $SUITE  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)"
  echo "load: $(uptime)"
  case "$SUITE" in
    *.py) (cd "$W" && python3 -B -W ignore "$SUITE"); rc=$? ;;
    *)    (cd "$W" && bash "$SUITE"); rc=$? ;;
  esac
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
tail -4 "$OUT"
