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
mutation_begin "session-start-reap-worktrees (status + inventory)" "scripts/hooks/session-start-reap-worktrees.test.sh"

W="scripts/hooks/session-start-reap-worktrees.sh"

mutant execute-is-back "W03" "$W" \
    'RAW_OUTPUT="$("$REAPER" "$SWEEP_ROOT" $DISCOVER_ARGS 2>&1)" || true' \
    'RAW_OUTPUT="$("$REAPER" "$SWEEP_ROOT" --execute --unlock-stale $DISCOVER_ARGS 2>&1)" || true' \
    "the old sweep would be back: a liveness inference deleting a worktree at every session start, the 2026-09-02 shape."

mutant reconciler-status-skipped "W07" "$W" \
    'RECONCILE_RAW="$(python3 "$RECONCILER" --status 2>&1)" || true' \
    'RECONCILE_RAW="{\"done\":true,\"definition_of_done\":{}}"' \
    "pending transactions would be falsely reported as done instead of read from status."

mutant recovery-runs-at-session-start "W11" "$W" \
    '--status 2>&1' \
    '--max-seconds 20 2>&1' \
    "a status-only session start would mutate pending recovery records and captures."

mutant missing-reconciler-silent "W12" "$W" \
    '    RECONCILE_SUMMARY="ENGINE INSTALL FAILURE — scripts/reconcile-terminal-worktrees.py is missing at $RECONCILER; no terminal worktree transaction was recovered."' \
    '    RECONCILE_SUMMARY="worktree reconciler: DONE (zero dead worktrees)"' \
    "a broken engine install would report a clean lifecycle at every session start."\n
mutant blocked-word-suppressed "W10b" "$W" \
    '    verdict = "DONE (zero dead worktrees)" if done else ("BLOCKED (%s member(s) cannot proceed by waiting)" % blocked if blocked else "PENDING")' \
    '    verdict = "DONE (zero dead worktrees)" if done else "PENDING"' \
    "a deadlock would lead the session banner with the word PENDING again — the shape of a queue draining, printed over thirty members that no amount of waiting would free (2026-09-04)."

mutation_end
