#!/usr/bin/env bash
# run-probe-direct.sh <probe-path-relative-to-worktree> <label>
# Runs ONE reviewer probe directly, fully sandboxed (HOME, CLAUDE_CONFIG_DIR,
# RICHOS_WORKSPACES_DIR, RICHOS_SESSIONS_DIR all under the scratchpad), so the
# case the runner only names in its summary can be read in full.
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/m3
W=/Users/alex/ab/richos-wt/zach-fable-m3
P="${1:?probe}"; LABEL="${2:?label}"; shift 2   # remaining arguments go to the probe
export HOME="$S/outer-sandbox/home-$LABEL" CLAUDE_CONFIG_DIR="$S/outer-sandbox/home-$LABEL/.claude" RICHOS_WORKSPACES_DIR="$S/outer-sandbox/ws-$LABEL" RICHOS_SESSIONS_DIR="$S/outer-sandbox/sessions-$LABEL"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$RICHOS_WORKSPACES_DIR" "$RICHOS_SESSIONS_DIR"
OUT="$S/probe-direct-$LABEL.txt"
{
  echo "probe: $P  started: $(date -u +%FT%TZ)  HEAD: $(git -C "$W" rev-parse HEAD)"
  (cd "$W" && python3 "$P" "$@"); rc=$?
  echo "exit: $rc"
} > "$OUT" 2>&1
echo "wrote $OUT"; tail -2 "$OUT"
