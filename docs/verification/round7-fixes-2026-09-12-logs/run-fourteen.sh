#!/usr/bin/env bash
# run-fourteen.sh <label> [with-mutants]
# Runs the fourteen-check harness from the zach-fable-m2 worktree, sandboxed
# by the harness itself (HOME / CLAUDE_CONFIG_DIR redirected inside it).
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad
W=/Users/alex/ab/richos-wt/zach-fable-m2
LABEL="${1:-run}"; MUT="${2:-}"
mkdir -p "$S/$LABEL"
OUT="$S/$LABEL/fourteen.txt"
{
  echo "label: $LABEL  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | wc -l | tr -d ' ')"
  if [ "$MUT" = "with-mutants" ]; then
    (cd "$W" && bash engine/scripts/workspace-spec-fourteen.test.sh); rc=$?
  else
    (cd "$W" && RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh); rc=$?
  fi
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
tail -3 "$OUT"
