#!/usr/bin/env bash
#
# collect-worktree-artifacts.sh — mirror a teammate worktree's GITIGNORED
# test/QA evidence into the governed entity's MAIN checkout before the
# worktree is removed.
#
# WHY: committed deliverables (audits, signoffs, code) ride the teammate's
# branch and land via git merge — they never need collection. But test results,
# HTML reports, and screenshots are gitignored; they exist only inside the
# worktree and die with `git worktree remove`. Run this at LAND TIME, right
# BEFORE removing a worktree whose agent ran tests or captured evidence.
#
# The directories to collect are project-specific and read from the governed
# entity's orchestration.config:
#   ARTIFACT_MERGE_DIRS   — merged newest-wins per file, other files preserved.
#   ARTIFACT_REPLACE_DIRS — replaced wholesale (per-run aggregates).
#
# Every collected directory gets a SOURCE.txt stamping collected-at, worktree,
# branch and SHA — provenance by revision, not timestamp.
#
# WHICH REPOSITORY RECEIVES THE EVIDENCE, AND WHOSE LIST IS COLLECTED.
# Resolved by the engine's two-root contract (scripts/lib/resolve-roots.sh):
# $RICHOS_ENTITY_ROOT, else $CLAUDE_PROJECT_DIR, else $PWD — NEVER this
# script's own location, which is the ENGINE and is usually not the repository
# being collected into. Until 2026-09-02 this script resolved `$SCRIPT_DIR/..`:
# run by reference for femcboost it loaded the ENGINE's orchestration.config
# (three directories where femcboost declares nine — both visual-screenshots
# trees and both per-tree playwright-report trees invisible) and rsynced what
# it did find INTO THE ENGINE CHECKOUT. Two collections ran that way ahead of
# worktree removals that day; both trees happened to be docs-only.
#
# FAIL LOUD, NEVER DEFAULT. A run that cannot resolve a governed entity, or
# whose entity carries no orchestration.config, or whose config declares no
# directory list, REFUSES (exit 2) with the root contract's banner. It carries
# no built-in list to fall back on: a step that proceeds on a wrong-but-
# plausible value is worse than one that refuses, because it reports success
# over the evidence it never saved. (A DECLARED empty list is honored — that
# is a statement, not an absence.)
#
# OBSERVABLE. Every run states the entity root it resolved (and how), the
# config file it loaded, and the directories it will collect, with counts — so
# a wrong resolution is visible in the output rather than inferable from what
# is missing.
#
# Usage: scripts/collect-worktree-artifacts.sh <worktree-path>
#   e.g. scripts/collect-worktree-artifacts.sh .claude/worktrees/agent-abc123
#   e.g. RICHOS_ENTITY_ROOT=/path/to/repo <engine>/scripts/collect-worktree-artifacts.sh <worktree-path>
#
# Exit codes:
#   0  collected (or a declared list matched nothing — stated)
#   1  worktree path not found, or asked to collect the entity into itself
#   2  REFUSED: no governed entity, no orchestration.config, or no declared list
#
# Tests: scripts/collect-worktree-artifacts.test.sh (regression + mutations).

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="collect-worktree-artifacts.sh"

# --- 1. Which repository? The root contract, never SCRIPT_DIR/.. ------------
_RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
  echo "[collect] REFUSED — scripts/lib/resolve-roots.sh is missing at $_RR_LIB;" >&2
  echo "          cannot determine which repository receives the evidence. ($TAG)" >&2
  exit 2
fi
# shellcheck source=lib/resolve-roots.sh
. "$_RR_LIB"

if resolve_entity_root ""; then
  MAIN_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
else
  {
    echo "[collect] REFUSED — no governed entity; nothing is collected."
    root_failure_banner "$TAG" \
      "This collector mirrors evidence INTO the governed entity's main checkout and" \
      "reads its directory list FROM that entity's orchestration.config. Without a" \
      "resolved entity there is no destination and no list, and it will NOT guess" \
      "either. Declare the entity: RICHOS_ENTITY_ROOT=<repo> $0 <worktree-path>"
  } >&2
  exit 2  # refuse: no governed entity
fi

# --- 2. Which list? The entity's config file, and nothing else -------------
CONFIG="$MAIN_ROOT/orchestration.config"
if ! require_asset "$CONFIG" "$TAG" "orchestration.config (the ARTIFACT_MERGE_DIRS / ARTIFACT_REPLACE_DIRS source)" >&2; then
  echo "[collect] REFUSED — nothing is collected." >&2
  exit 2  # refuse: config missing
fi
# The list is attributed to the FILE in the output below, so it must come from
# the file: scrub anything inherited from the environment first.
unset ARTIFACT_MERGE_DIRS ARTIFACT_REPLACE_DIRS
# shellcheck disable=SC1090
if ! . "$CONFIG"; then
  echo "[collect] REFUSED — $CONFIG failed to source; nothing is collected. ($TAG)" >&2
  exit 2
fi
if [ -z "${ARTIFACT_MERGE_DIRS+set}" ] && [ -z "${ARTIFACT_REPLACE_DIRS+set}" ]; then
  echo "[collect] REFUSED — $CONFIG declares neither ARTIFACT_MERGE_DIRS nor" >&2
  echo "          ARTIFACT_REPLACE_DIRS. This collector carries no default list:" >&2
  echo "          a built-in guess is how the wrong directories get collected while" >&2
  echo "          the run reports success. Declare the list in that file (an empty" >&2
  echo "          value is a declaration; an absent key is not). ($TAG)" >&2
  exit 2  # refuse: no declared list
fi
: "${ARTIFACT_MERGE_DIRS:=}"
: "${ARTIFACT_REPLACE_DIRS:=}"

# Word splitting is the point: the lists are space-separated, as the loops
# below consume them.
# shellcheck disable=SC2086
count_words() { set -- $1; echo "$#"; }
N_MERGE="$(count_words "$ARTIFACT_MERGE_DIRS")"
N_REPLACE="$(count_words "$ARTIFACT_REPLACE_DIRS")"

# --- 3. Say what was resolved BEFORE touching anything ---------------------
echo "[collect] entity root : $MAIN_ROOT  (${RICHOS_ROOT_STATUS:-?} via ${RICHOS_ROOT_SOURCE:-?})"
echo "[collect] config      : $CONFIG"
echo "[collect] merge dirs   ($N_MERGE): ${ARTIFACT_MERGE_DIRS:-<none>}"
echo "[collect] replace dirs ($N_REPLACE): ${ARTIFACT_REPLACE_DIRS:-<none>}"
if [ "${RICHOS_ROOT_STATUS:-}" = "engine-self" ]; then
  echo "[collect] note        : ${RICHOS_ROOT_REASON:-engine-self}"
fi

# --- 4. The worktree -------------------------------------------------------
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

DECLARED=$((N_MERGE + N_REPLACE))
if [ "$COLLECTED" -eq 0 ]; then
  echo "[collect] none of the $DECLARED declared artifact dir(s) present in $SRC — nothing to collect."
  exit 0
fi

echo "[collect] done — $COLLECTED of $DECLARED declared dir(s) collected into $MAIN_ROOT from $SRC_BRANCH @ ${SRC_SHA:0:12}"
