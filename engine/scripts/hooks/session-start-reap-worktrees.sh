#!/usr/bin/env bash
#
# session-start-reap-worktrees.sh — SessionStart hook. Runs
# scripts/reap-stale-worktrees.sh in `--execute --unlock-stale` mode so
# landed-but-never-removed teammate worktrees under .claude/worktrees/agent-*
# get swept automatically at the start of every session, instead of quietly
# accumulating across restarts. In the upstream production project this engine
# was extracted from, 43 stale worktrees had piled up before anyone noticed —
# this hook exists to keep that from recurring anywhere the engine is adopted.
#
# LOG-ONLY / NEVER BLOCKS: mirrors teammate-idle-handoff.sh's fail-open
# contract. Any failure (missing script, git error, unexpected exception,
# missing python3) is swallowed — this hook ALWAYS exits 0 and NEVER holds
# up a session start. The reaper itself is the real safety boundary (four
# gates — not-locked-or-provably-stale, merged, clean, no-live-process —
# plus `git worktree remove`/`git branch -d`, never --force/-D); this hook
# only decides WHEN to invoke it. See scripts/reap-stale-worktrees.sh for the
# full contract and README.md ("What ships") for the shipped description.
#
# FAST WHEN NOTHING TO REAP: each candidate costs a handful of cheap git
# plumbing calls (status --porcelain, merge-base --is-ancestor, pgrep).
# Measured upstream against a real 45-worktree registration (43 candidates):
# ~2.1s wall time in DRY-RUN. Once this hook has run once and the backlog is
# cleared, the steady state (0-3 new worktrees per session) completes in well
# under 2s. Working through a large backlog on first adoption naturally takes
# longer — an acceptable one-time cost, not the steady-state case this timing
# target describes.
#
# Never touches unlanded work: delegates entirely to
# reap-stale-worktrees.sh, which is DRY-RUN by default and only mutates
# under --execute with every removal gated (see that script's header).
#
# Repo-agnostic: resolves the main checkout via
# scripts/lib/resolve-main-checkout.sh (tolerates its absence, falling back
# to plain current-checkout resolution) exactly like the reaper itself, so
# this hook is copy-paste portable to any repo adopting the same
# .claude/worktrees/agent-<hex> convention.
#
# TEST OVERRIDE: REAP_WORKTREES_ROOT retargets the SWEEP at another repo root
# (test-only; never set in a real session — the sibling hooks use the same
# convention, cf. DEFINITION_DRIFT_ROOT). Only the sweep TARGET changes: the
# reaper script itself is still resolved from THIS script's own location, so a
# sandbox sweep still exercises the canonical, sidecar-hashed reaper rather than
# a copy of it. Used by scripts/hooks/session-start-reap-worktrees.test.sh and
# by contract-integrity-probe.sh Layer Q so neither ever mutates a real worktree.
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

# NOTE ON STDIN — this hook does NOT read the payload.
#
# It is a SessionStart hook AND a plain CLI tool, and in the CLI case stdin is
# an inherited pipe that nobody closes, so an unconditional `cat` hangs forever
# (`[ ! -t 0 ]` does not help: an inherited pipe is not a TTY). Measured: 92
# seconds and counting, inside the contract-integrity probe, before this was
# reverted.
#
# It costs nothing, because the payload's `cwd` is a REDUNDANT resolution
# candidate here: CLAUDE_PROJECT_DIR is measured present and correct in a
# plugin-loaded hook's environment at SessionStart (probe, 2026-08-28), and it
# outranks the payload cwd anyway. Paying a hang risk for a candidate that
# never wins is a bad trade.

# TWO ROOTS. The reaper SCRIPT is an ENGINE asset; the tree it SWEEPS is the
# ENTITY. The old code took both from one variable, so a plugin-loaded engine
# looked for its own script inside the session's repository, did not find it,
# and reported "skipped (...)" — indistinguishable from a routine no-op.
REAPER="$ENGINE_ROOT/scripts/reap-stale-worktrees.sh"

if resolve_entity_root ""; then
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-$RICHOS_ENTITY_ROOT_RESOLVED}"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-}"
else
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-}"
fi

if [ "$RICHOS_ROOT_STATUS" = "broken" ] && [ -z "${REAP_WORKTREES_ROOT:-}" ]; then
    # FAIL LOUD. The guard believes it is governing a repository and cannot
    # resolve it. Both channels, because a SessionStart hook must never block:
    # stderr for the operator, additionalContext for the orchestrator.
    BANNER="$(root_failure_banner "scripts/hooks/session-start-reap-worktrees.sh")"
    printf '%s\n' "$BANNER" >&2
    SUMMARY="ROOT RESOLUTION FAILURE — the session-start worktree reaper could not resolve the repository it governs, so NO worktrees were swept and none will be. ${RICHOS_ROOT_REASON}"
elif [ -z "$SWEEP_ROOT" ]; then
    # not-adopted. Announced once, by engine-status.sh, rather than by every
    # hook — but stated plainly here too so this hook's own output can never be
    # read as "swept, nothing found".
    SUMMARY="session-start worktree reap: not run — this repository has not adopted the engine (no orchestration.config at its root). Nothing was swept."
elif [ ! -x "$REAPER" ]; then
    # The ENGINE is broken, not the entity: the reaper is an engine asset and
    # it is missing from the engine's own tree. That is an install failure and
    # it gets said as one, not as "skipped".
    printf '%s\n' "$(require_asset "$REAPER" "scripts/hooks/session-start-reap-worktrees.sh" "the worktree reaper (an ENGINE asset)")" >&2
    SUMMARY="ENGINE INSTALL FAILURE — scripts/reap-stale-worktrees.sh is missing or not executable at $REAPER. No worktrees were swept. This is a broken engine install, NOT a routine skip."
else
    RAW_OUTPUT="$("$REAPER" "$SWEEP_ROOT" --execute --unlock-stale 2>&1)" || true
    SUMMARY_LINE="$(printf '%s\n' "$RAW_OUTPUT" | grep -m1 '^=== summary' || true)"
    if [ -n "$SUMMARY_LINE" ]; then
        SUMMARY="session-start worktree reap [$SWEEP_ROOT]: ${SUMMARY_LINE#=== }"
    else
        SUMMARY="session-start worktree reap [$SWEEP_ROOT]: ran but produced no summary line — check reaper output manually if worktrees seem stuck"
    fi
fi

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
    # No python3 — degrade to a minimal hand-escaped JSON line rather than
    # emitting nothing.
    ESCAPED="${SUMMARY//\\/\\\\}"
    ESCAPED="${ESCAPED//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$ESCAPED"
fi

exit 0
