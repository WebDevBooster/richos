#!/usr/bin/env bash
# run-runner.sh <label> — the probe runner on the REAL manifest of this worktree,
# against a COPY of the operator's workspace store (never the real one), with
# the sessions dir redirected too. Prints the runner's own verdict lines.
set -uo pipefail
S="${RICHOS_R8_SCRATCH:-/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad}"
W="${RICHOS_R8_WORKTREE:-/Users/alex/ab/richos-wt/zach-fable-m5}"
LABEL="${1:-runner}"
mkdir -p "$S/$LABEL"
STORE="$S/$LABEL/store-copy"
rm -rf "$STORE"; cp -R "$HOME/.claude/state/workspaces" "$STORE"
export RICHOS_WORKSPACES_DIR="$STORE" RICHOS_SESSIONS_DIR="$S/$LABEL/sessions"
mkdir -p "$RICHOS_SESSIONS_DIR"
unset RICHOS_SESSION_ID
OUT="$S/$LABEL/runner.txt"
{
  echo "label: $LABEL  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | wc -l | tr -d ' ')"
  echo "store copy: $STORE  (integration record: $(python3 "$W/engine/scripts/lib/workspaces.py" integration --repo /Users/alex/ab/richos 2>&1 | head -1))"
  (cd "$W" && python3 engine/scripts/workspace-probes.py --tree-only); rc=$?
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
grep -E '^(GREEN|RED|RETIRED|UNRUNNABLE|MISSING|UNLISTED|DECLARED) |probes |exit:' "$OUT" | head -40
