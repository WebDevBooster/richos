#!/usr/bin/env bash
#
# session-start-reap-worktrees.mutation.sh — PROVES the SessionStart wrapper's
# suite CAN FAIL, one property at a time. Invoked by
# session-start-reap-worktrees.test.sh; the loop is scripts/lib/mutation-harness.sh.
# Case ids (W03 etc.) are the ones that suite prints on both PASS and FAIL.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "session-start-reap-worktrees (recovery + inventory)" "scripts/hooks/session-start-reap-worktrees.test.sh"

W="scripts/hooks/session-start-reap-worktrees.sh"

mutant execute-is-back "W03" "$W" \
    'RAW_OUTPUT="$("$REAPER" "$SWEEP_ROOT" $DISCOVER_ARGS 2>&1)" || true' \
    'RAW_OUTPUT="$("$REAPER" "$SWEEP_ROOT" --execute --unlock-stale $DISCOVER_ARGS 2>&1)" || true' \
    "the old sweep would be back: a liveness inference deleting a worktree at every session start, the 2026-09-02 shape."

mutant reconciler-not-run "W07" "$W" \
    'RECONCILE_RAW="$(python3 "$RECONCILER" --max-seconds "$SESSION_START_RECONCILE_BUDGET" 2>&1)" || true' \
    'RECONCILE_RAW="{\"reconciled\": 0, \"status\": {\"done\": true, \"definition_of_done\": {}}}"' \
    "a transaction a crash left mid-way would wait for launchd forever on a machine where launchd was never installed."

mutant budget-not-passed "W11" "$W" \
    '--max-seconds "$SESSION_START_RECONCILE_BUDGET"' \
    '--max-seconds 3600' \
    "a session start could be held for as long as the backlog takes to capture."

mutant missing-reconciler-silent "W12" "$W" \
    '    RECONCILE_SUMMARY="ENGINE INSTALL FAILURE — scripts/reconcile-terminal-worktrees.py is missing at $RECONCILER; no terminal worktree transaction was recovered."' \
    '    RECONCILE_SUMMARY="worktree reconciler: DONE (zero dead worktrees)"' \
    "a broken engine install would report a clean lifecycle at every session start."

mutation_end
