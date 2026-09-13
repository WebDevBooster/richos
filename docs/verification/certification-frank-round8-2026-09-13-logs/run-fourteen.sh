#!/usr/bin/env bash
# run-fourteen.sh <label> [with-mutants] — from frank-fable-c9's worktree, sandboxed twice
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/frank-c9
W=/Users/alex/ab/richos-wt/frank-fable-c9
LABEL="${1:-run}"; MUT="${2:-}"
mkdir -p "$S/$LABEL/outer-home/.claude" "$S/$LABEL/outer-ws" "$S/$LABEL/outer-sessions"
export CLAUDE_CONFIG_DIR="$S/$LABEL/outer-home/.claude" RICHOS_WORKSPACES_DIR="$S/$LABEL/outer-ws" RICHOS_SESSIONS_DIR="$S/$LABEL/outer-sessions"
OUT="$S/$LABEL/fourteen.txt"
{
  echo "label: $LABEL  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | wc -l | tr -d ' ')"
  echo "engine: $W/engine  workspaces.py sha256: $(shasum -a 256 "$W/engine/scripts/lib/workspaces.py" | cut -c1-16)  guard sha256: $(shasum -a 256 "$W/engine/scripts/hooks/guard-worktree-removal.sh" | cut -c1-16)"
  echo "load: $(uptime)"
  if [ "$MUT" = "with-mutants" ]; then
    (cd "$W" && bash engine/scripts/workspace-spec-fourteen.test.sh); rc=$?
  else
    (cd "$W" && RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh); rc=$?
  fi
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
tail -3 "$OUT"
