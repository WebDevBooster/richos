#!/usr/bin/env bash
#
# collect-worktree-artifacts.sh — mirror a teammate worktree's GITIGNORED
# test/QA evidence into the MAIN checkout before the worktree is removed.
#
# WHY: committed deliverables (audits, signoffs, code) ride the teammate's
# branch and land via git merge — they never need collection. But test results,
# HTML reports, and screenshots are gitignored; they exist only inside the
# worktree and die with `git worktree remove`. Run this at LAND TIME, right
# BEFORE removing a worktree whose agent ran tests or captured evidence.
#
# The directories to collect are project-specific and read from
# orchestration.config:
#   ARTIFACT_MERGE_DIRS   — merged newest-wins per file, other files preserved.
#   ARTIFACT_REPLACE_DIRS — replaced wholesale (per-run aggregates).
#
# Every collected directory gets a SOURCE.txt stamping collected-at, worktree,
# branch and SHA — provenance by revision, not timestamp.
#
# Usage: scripts/collect-worktree-artifacts.sh <worktree-path>
#   e.g. scripts/collect-worktree-artifacts.sh .claude/worktrees/agent-abc123

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$MAIN_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${ARTIFACT_MERGE_DIRS:=test-results output}"
: "${ARTIFACT_REPLACE_DIRS:=playwright-report}"

SRC_INPUT="${1:?usage: collect-worktree-artifacts.sh <worktree-path>}"
SRC="$(cd "$SRC_INPUT" 2>/dev/null && pwd || true)"
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "[collect] worktree path not found: $SRC_INPUT" >&2
  exit 1
fi
if [ "$SRC" = "$MAIN_ROOT" ]; then
  echo "[collect] refusing to collect from the main checkout into itself." >&2
  exit 1
fi

SRC_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
SRC_SHA="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo '?')"

stamp_source() { # <dest-dir>
  {
    echo "collected_at:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "source_worktree: $SRC"
    echo "source_branch:   $SRC_BRANCH"
    echo "source_sha:      $SRC_SHA"
  } > "$1/SOURCE.txt"
}

COLLECTED=0

for d in $ARTIFACT_MERGE_DIRS; do
  if [ -d "$SRC/$d" ]; then
    mkdir -p "$MAIN_ROOT/$d"
    rsync -a "$SRC/$d/" "$MAIN_ROOT/$d/"
    stamp_source "$MAIN_ROOT/$d"
    echo "[collect] merged $d/ (newest-wins, other files preserved)"
    COLLECTED=$((COLLECTED + 1))
  fi
done

for d in $ARTIFACT_REPLACE_DIRS; do
  if [ -d "$SRC/$d" ]; then
    mkdir -p "$MAIN_ROOT/$d"
    rsync -a --delete "$SRC/$d/" "$MAIN_ROOT/$d/"
    stamp_source "$MAIN_ROOT/$d"
    echo "[collect] replaced $d/ (per-run aggregate — see its SOURCE.txt)"
    COLLECTED=$((COLLECTED + 1))
  fi
done

if [ "$COLLECTED" -eq 0 ]; then
  echo "[collect] no known artifact dirs found in $SRC — nothing to collect."
  exit 0
fi

echo "[collect] done — $COLLECTED dir(s) collected from $SRC_BRANCH @ ${SRC_SHA:0:12}"
