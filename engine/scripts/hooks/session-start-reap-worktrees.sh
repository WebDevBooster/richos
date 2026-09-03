#!/usr/bin/env bash
#
# session-start-reap-worktrees.sh — SessionStart hook. CRASH RECOVERY for the
# worktree transactions, plus a read-only inventory. It deletes nothing itself
# and infers nothing about any agent's liveness.
#
# ===========================================================================
# WHAT CHANGED ON 2026-09-03, AND WHY
# ===========================================================================
# Until now this hook ran scripts/reap-stale-worktrees.sh with --execute at
# every session start: a sweep that DECIDED, from locks, names, transcripts and
# process tables, whether an agent might still return, and removed its
# worktree when it decided not. Nine rounds of that design failed in nine
# different shapes (richos-hq/wiki/worktree-lifecycle.md §14), the last one by
# removing a live agent's worktree. The CEO's ruling ended the question:
#
#     The system should stop trying to discover whether the agent might
#     return. It is forbidden to return.
#
# So removal is no longer a decision any sweep makes. A worktree is owned by
# a TRANSACTION bound at spawn to the platform's agent id (scripts/lib/
# worktree-transactions.py); its first terminal event (SubagentStop or
# WorktreeRemove, terminalize-agent-worktrees.sh) claims that transaction and
# quarantines every member; and the persistent reconciler
# (scripts/reconcile-terminal-worktrees.py, driven by launchd) captures,
# verifies, unregisters and removes them. Specification: femcboost
# docs/plans/worktree-real-fix-2026-09-03.md.
#
# THIS HOOK'S TWO JOBS NOW:
#   1. RECOVERY. Run the reconciler with a short time budget, so a
#      transaction a crash left mid-way is resumed at the next session start
#      even if launchd is not installed on this machine. SessionStart is NOT
#      the scheduler — launchd is — and nothing waits for a later session.
#   2. INVENTORY. Run the reaper in DRY-RUN (report only, never --execute,
#      never --unlock-stale) so the session opens with the same denominator it
#      always had: every repository, every worktree, and the ones nothing
#      owns. That count is the "unbound RichOS-created worktrees" figure of
#      the definition of done, and it is reported, never acted on.
#
# LOG-ONLY / NEVER BLOCKS: this hook ALWAYS exits 0 and NEVER holds up a
# session start. Every failure is announced into the orchestrator's context
# rather than swallowed.
#
# TEST OVERRIDES: REAP_WORKTREES_ROOT retargets the inventory at another repo
# root and suppresses discovery; RICHOS_WORKTREE_TX_DIR retargets the
# transaction store. Under REAP_WORKTREES_ROOT the ledger, projects and
# sessions paths are pinned inside the sandbox, as before.
#
# NOTE: hooks are snapshotted per session, so this hook takes effect from the
# NEXT session. It assumes nothing about being live in the session that adds it.

set -o pipefail

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/session-start-reap-worktrees.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

# NOTE ON STDIN — this hook does NOT read the payload (see the previous
# version's measurement: an inherited pipe nobody closes hangs an unconditional
# `cat` for 92 seconds inside the probe; CLAUDE_PROJECT_DIR outranks the
# payload cwd anyway).

if [ -n "${REAP_WORKTREES_ROOT:-}" ]; then
    export REAP_WORKTREE_LEDGER="${REAP_WORKTREE_LEDGER:-$REAP_WORKTREES_ROOT/.claude/state/worktree-ledger.jsonl}"
    export REAP_PROJECTS_DIR="${REAP_PROJECTS_DIR:-$REAP_WORKTREES_ROOT/.claude/projects-sandbox}"
    export RICHOS_SESSIONS_DIR="${RICHOS_SESSIONS_DIR:-$REAP_WORKTREES_ROOT/.claude/sessions-sandbox}"
fi

REAPER="$ENGINE_ROOT/scripts/reap-stale-worktrees.sh"
RECONCILER="$ENGINE_ROOT/scripts/reconcile-terminal-worktrees.py"
: "${SESSION_START_RECONCILE_BUDGET:=20}"

if resolve_entity_root ""; then
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-$RICHOS_ENTITY_ROOT_RESOLVED}"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-}"
else
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-}"
fi

# --- 1. RECOVERY: the reconciler, with a budget --------------------------------
RECONCILE_SUMMARY=""
if [ ! -f "$RECONCILER" ]; then
    printf '%s\n' "$(require_asset "$RECONCILER" "scripts/hooks/session-start-reap-worktrees.sh" "the worktree reconciler (an ENGINE asset)")" >&2
    RECONCILE_SUMMARY="ENGINE INSTALL FAILURE — scripts/reconcile-terminal-worktrees.py is missing at $RECONCILER; no terminal worktree transaction was recovered."
elif ! command -v python3 >/dev/null 2>&1; then
    RECONCILE_SUMMARY="RECONCILER NOT RUN — python3 is unavailable; terminal worktree transactions were not recovered."
else
    RECONCILE_RAW="$(python3 "$RECONCILER" --max-seconds "$SESSION_START_RECONCILE_BUDGET" 2>&1)" || true
    RECONCILE_SUMMARY="$(printf '%s\n' "$RECONCILE_RAW" | python3 -c '
import json, sys
lines = sys.stdin.read().splitlines()
notes = [l for l in lines if l.startswith("reconcile:")]
try:
    d = json.loads(next(l for l in lines if l.startswith("{")))
except Exception:
    d = None
if d is None:
    print("worktree reconciler: ran but produced no status (%s)" % ("; ".join(notes)[:300] or "no output"))
else:
    s = d.get("status", {})
    done = s.get("done")
    dd = s.get("definition_of_done", {})
    print("worktree reconciler: %s — terminal members with a directory present=%s, pending retry=%s, hard failures (dead-present)=%s, transactions touched=%s%s"
          % ("DONE (zero dead worktrees)" if done else "PENDING",
             dd.get("terminal_members_with_a_directory_present"), dd.get("terminal_transactions_pending_normal_retry"),
             dd.get("hard_failures_counted_as_dead_present"), d.get("reconciled"),
             ("; " + "; ".join(notes)[:300]) if notes else ""))
' 2>/dev/null || printf 'worktree reconciler: ran; status unreadable')"
fi

# --- 2. INVENTORY: the reaper in DRY-RUN, never --execute ------------------------
if [ "$RICHOS_ROOT_STATUS" = "broken" ] && [ -z "${REAP_WORKTREES_ROOT:-}" ]; then
    BANNER="$(root_failure_banner "scripts/hooks/session-start-reap-worktrees.sh")"
    printf '%s\n' "$BANNER" >&2
    INVENTORY="ROOT RESOLUTION FAILURE — the worktree inventory could not resolve the repository it governs. ${RICHOS_ROOT_REASON}"
elif [ -z "$SWEEP_ROOT" ]; then
    INVENTORY="worktree inventory: not run — this repository has not adopted the engine (no orchestration.config at its root)."
elif [ ! -x "$REAPER" ]; then
    printf '%s\n' "$(require_asset "$REAPER" "scripts/hooks/session-start-reap-worktrees.sh" "the worktree inventory (an ENGINE asset)")" >&2
    INVENTORY="ENGINE INSTALL FAILURE — scripts/reap-stale-worktrees.sh is missing or not executable at $REAPER. No inventory was taken. This is a broken engine install, NOT a routine skip."
else
    DISCOVER_ARGS="--discover"
    [ -n "${REAP_WORKTREES_ROOT:-}" ] && DISCOVER_ARGS=""
    # DRY-RUN BY CONSTRUCTION: no --execute, no --unlock-stale. This hook has
    # no destructive authority and passes none on.
    # shellcheck disable=SC2086
    RAW_OUTPUT="$("$REAPER" "$SWEEP_ROOT" $DISCOVER_ARGS 2>&1)" || true
    SUMMARY_LINE="$(printf '%s\n' "$RAW_OUTPUT" | grep -m1 '^=== summary' || true)"
    COVERAGE_LINE="$(printf '%s\n' "$RAW_OUTPUT" | grep -m1 '^=== coverage' || true)"
    BLIND_LINES="$(printf '%s\n' "$RAW_OUTPUT" | grep '^=== blind:' | tr '\n' ' ' || true)"
    VERDICT_LINE="$(printf '%s\n' "$RAW_OUTPUT" | grep -m1 '^=== verdict' || true)"
    VERDICT_WORD="$(printf '%s' "$VERDICT_LINE" | sed -n 's/^=== verdict: \([A-Z]*\).*/\1/p')"
    if [ -n "$SUMMARY_LINE" ] && [ "$VERDICT_WORD" = "FAIL" ]; then
        INVENTORY="WORKTREE INVENTORY FAIL [$SWEEP_ROOT] (report only, nothing removed): ${VERDICT_LINE#=== } | ${SUMMARY_LINE#=== } ${COVERAGE_LINE#=== } ${BLIND_LINES}"
    elif [ -n "$SUMMARY_LINE" ]; then
        INVENTORY="worktree inventory [$SWEEP_ROOT] (DRY-RUN, nothing removed): ${VERDICT_LINE#=== } | ${SUMMARY_LINE#=== } ${COVERAGE_LINE#=== } ${BLIND_LINES}"
    else
        INVENTORY="worktree inventory [$SWEEP_ROOT]: ran but produced no summary line — check the reaper's dry-run output manually if worktrees seem stuck"
    fi
fi

SUMMARY="$RECONCILE_SUMMARY || $INVENTORY"

if command -v python3 >/dev/null 2>&1; then
    SUMMARY="$SUMMARY" python3 - <<'PY' 2>/dev/null || true
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ.get("SUMMARY", ""),
    }
}))
PY
else
    ESCAPED="${SUMMARY//\\/\\\\}"
    ESCAPED="${ESCAPED//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$ESCAPED"
fi

exit 0
