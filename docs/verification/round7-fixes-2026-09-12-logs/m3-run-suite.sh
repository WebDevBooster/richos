#!/usr/bin/env bash
# run-suite.sh <label> <unit|unit-mut|e2e|probes|probes-mut|removal-guard|removal-guard-mut|completeness|probes-runner>
# Every suite sandboxes itself (HOME / CLAUDE_CONFIG_DIR / RICHOS_WORKSPACES_DIR
# redirected inside); this wrapper only labels and records the run.
# Round-7 REPORT run (zach-fable-m3): W is the m3 worktree at 3ff0cefd, and an
# OUTER sandbox is exported on top of each harness's own, so the operator's real
# ~/.claude/state ledgers are never the target even if a harness forgets.
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/m3
W=/Users/alex/ab/richos-wt/zach-fable-m3
export CLAUDE_CONFIG_DIR="$S/outer-sandbox/config" RICHOS_WORKSPACES_DIR="$S/outer-sandbox/ws" RICHOS_SESSIONS_DIR="$S/outer-sandbox/sessions"
mkdir -p "$CLAUDE_CONFIG_DIR" "$RICHOS_WORKSPACES_DIR" "$RICHOS_SESSIONS_DIR"
LABEL="${1:?label}"; WHAT="${2:?what}"
mkdir -p "$S/$LABEL"
OUT="$S/$LABEL/$WHAT.txt"
{
  echo "label: $LABEL  what: $WHAT  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | grep -v 'round7-fixes-2026-09-12' | wc -l | tr -d ' ')"
  echo "outer sandbox: CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR RICHOS_WORKSPACES_DIR=$RICHOS_WORKSPACES_DIR RICHOS_SESSIONS_DIR=$RICHOS_SESSIONS_DIR"
  cd "$W" || exit 1
  case "$WHAT" in
    unit)          python3 -B -W ignore engine/scripts/lib/workspaces.test.py; rc=$? ;;
    unit-mut)      bash engine/scripts/lib/workspaces.test.sh; rc=$? ;;
    e2e)           bash engine/scripts/workspaces-e2e.test.sh; rc=$? ;;
    probes)        bash engine/scripts/workspace-probes.test.sh; rc=$? ;;
    removal-guard) bash engine/scripts/hooks/guard-worktree-removal.test.sh; rc=$? ;;
    removal-guard-mut) bash engine/scripts/hooks/guard-worktree-removal.mutation.sh; rc=$? ;;
    completeness)  bash engine/scripts/publication-completeness.sh --root "$W"; rc=$? ;;
    probes-mut)    bash engine/scripts/workspace-probes.mutation.sh; rc=$? ;;
    probes-runner) RICHOS_WORKSPACES_DIR="$S/$LABEL/ws-runner" bash -c 'mkdir -p "$RICHOS_WORKSPACES_DIR"; bash engine/scripts/workspaces.sh integration --repo . --branch dev/workspace-spec --why "round 7 report runner check, sandbox store" && python3 engine/scripts/workspace-probes.py --tree-only'; rc=$? ;;
    *) echo "unknown: $WHAT"; rc=99 ;;
  esac
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
tail -4 "$OUT"
