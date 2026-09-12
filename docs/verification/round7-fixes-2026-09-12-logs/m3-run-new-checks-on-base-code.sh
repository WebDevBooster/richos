#!/usr/bin/env bash
# run-new-checks-on-base-code.sh — the ROUND-7 harness (its sub-assertions) run
# against the ROUND-6 code: a sandbox copy of this worktree's engine whose
# scripts/lib/workspaces.py and scripts/hooks/guard-worktree-removal.sh are the
# base's (dev/workspace-spec @ fa65987e). Every other file is round 7's. This
# measures which of the new sub-assertions were red BEFORE this round's fixes,
# which is the honest answer to "how many reds on the frozen fourteen".
# Round-7 REPORT run (zach-fable-m3): W is the m3 worktree at 3ff0cefd.
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/m3
W=/Users/alex/ab/richos-wt/zach-fable-m3
export CLAUDE_CONFIG_DIR="$S/outer-sandbox/config" RICHOS_WORKSPACES_DIR="$S/outer-sandbox/ws" RICHOS_SESSIONS_DIR="$S/outer-sandbox/sessions"
mkdir -p "$CLAUDE_CONFIG_DIR" "$RICHOS_WORKSPACES_DIR" "$RICHOS_SESSIONS_DIR"
BASE=fa65987e26fb79e2e51b5dd3839063ba016141c5
D="$(mktemp -d "${TMPDIR:-/tmp}/r7-on-base.XXXXXX")"
mkdir -p "$S/on-base"
OUT="$S/on-base/fourteen.txt"
{
  echo "label: round-7 checks against the round-6 code  started: $(date -u +%FT%TZ)"
  echo "harness: $W @ $(git -C "$W" rev-parse HEAD)   library+guard: $BASE   sandbox: $D"
  cp -R "$W/engine" "$D/engine"
  find "$D/engine" -name '*.sha256' -delete 2>/dev/null
  git -C "$W" show "$BASE:engine/scripts/lib/workspaces.py" > "$D/engine/scripts/lib/workspaces.py"
  git -C "$W" show "$BASE:engine/scripts/hooks/guard-worktree-removal.sh" > "$D/engine/scripts/hooks/guard-worktree-removal.sh"
  echo "library sha256 in sandbox: $(shasum -a 256 "$D/engine/scripts/lib/workspaces.py" | cut -c1-16)  base: $(git -C "$W" show "$BASE:engine/scripts/lib/workspaces.py" | shasum -a 256 | cut -c1-16)"
  echo "guard   sha256 in sandbox: $(shasum -a 256 "$D/engine/scripts/hooks/guard-worktree-removal.sh" | cut -c1-16)  base: $(git -C "$W" show "$BASE:engine/scripts/hooks/guard-worktree-removal.sh" | shasum -a 256 | cut -c1-16)"
  (cd "$D/engine" && RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash scripts/workspace-spec-fourteen.test.sh); rc=$?
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
rm -rf "$D"
grep -E '^      FAIL|CHECKS RUN|FOURTEEN|^exit' "$OUT"
