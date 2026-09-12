#!/usr/bin/env bash
# run-fourteen.sh <label> [with-mutants]
# Runs the fourteen-check harness from the zach-fable-m3 worktree, sandboxed
# by the harness itself (HOME / CLAUDE_CONFIG_DIR redirected inside it), with an
# OUTER sandbox exported on top so the operator's real ledgers are never the target.
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/m3
W=/Users/alex/ab/richos-wt/zach-fable-m3
export CLAUDE_CONFIG_DIR="$S/outer-sandbox/config" RICHOS_WORKSPACES_DIR="$S/outer-sandbox/ws" RICHOS_SESSIONS_DIR="$S/outer-sandbox/sessions"
mkdir -p "$CLAUDE_CONFIG_DIR" "$RICHOS_WORKSPACES_DIR" "$RICHOS_SESSIONS_DIR"
LABEL="${1:-run}"; MUT="${2:-}"
mkdir -p "$S/$LABEL"
OUT="$S/$LABEL/fourteen.txt"
{
  echo "label: $LABEL  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | grep -v 'round7-fixes-2026-09-12' | wc -l | tr -d ' ')"
  echo "outer sandbox: CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR RICHOS_WORKSPACES_DIR=$RICHOS_WORKSPACES_DIR RICHOS_SESSIONS_DIR=$RICHOS_SESSIONS_DIR"
  if [ "$MUT" = "with-mutants" ]; then
    (cd "$W" && bash engine/scripts/workspace-spec-fourteen.test.sh); rc=$?
  else
    (cd "$W" && RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh); rc=$?
  fi
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
tail -3 "$OUT"
