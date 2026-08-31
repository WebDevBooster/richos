#!/usr/bin/env bash
#
# guard-agent-state-claims.sh — NON-BLOCKING Stop hook. A TURN DOES NOT END
#                               QUIETLY WHILE IT CLAIMS A NAMED AGENT IS
#                               FINISHED AND THAT AGENT'S LOCK IS HELD.
#
# The incident, the corpus, the measured constructions, the constructions
# REFUSED and the reason this reports rather than blocks are all in
# guard-agent-state-claims.py, which is the analysis half. Read that first.
# This file is the wiring: resolve the repository, run the check, say the one
# sentence on the one channel that reaches the operator.
#
# ===========================================================================
# WHAT IT ACTUALLY CHECKS
# ===========================================================================
# The final message names a specific agent — `zach-opus-g1`, not "Zach" — and
# says it is completed / done / finished / idle / terminated. The name is joined
# to an agent id through this session's transcript, and that id is put to
# scripts/lib/agent-liveness.py, the SAME resolver remove-agent-worktree.sh
# uses. If the authoritative answer is ALIVE, the turn does not end quietly.
#
# ===========================================================================
# IT REPORTS. IT DOES NOT BLOCK. SAID HERE AS WELL AS IN THE HEADER OF THE
# ANALYZER, BECAUSE A READER OF EITHER FILE IS ENTITLED TO KNOW.
# ===========================================================================
# Two reasons. The harm is a sentence already written, so blocking only delays
# the same correction by a round trip. And the liveness half's false-positive
# rate is UNPROVEN, in those words: lock history is not retained, so it cannot
# be measured on the archive, and there is one known false-positive mode — an
# agent that genuinely finished whose worktree has not yet been reaped still
# reads ALIVE. A guard that blocked on an unmeasured signal would be switched
# off, and being ignored is the failure mode that produced this defect.
#
# The EXTRACTOR half is measured: 5 hits over 4,230 real final messages, 5 of 5
# genuine claims about a named agent's terminal state. The numbers and the
# adjudication are in the analyzer's docstring.
#
# ===========================================================================
# WHEN IT TAKES EFFECT
# ===========================================================================
# Hooks snapshot at session start. Installing this changes nothing in the
# session that installs it; it begins reporting in the NEXT session.
#
# Exit code: 0, always. This hook never refuses a turn.
#
# Self-test:  scripts/hooks/guard-agent-state-claims.sh --self-test

set -eo pipefail

HOOK_TAG="(hook: scripts/hooks/guard-agent-state-claims.sh)"

# --- self-test dispatch ---------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/agent-state-claims.test.sh"
fi

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
        echo "  hook: scripts/hooks/guard-agent-state-claims.sh"
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

# --- NOTICE CHANNEL --------------------------------------------------------
# A Stop hook's stand-down and cannot-run notices go to the OPERATOR, never to
# stderr. The measurement behind that, and the argument for announcing on state
# change rather than every turn, are in scripts/lib/stop-hook-notice.sh. This
# block is byte-identical in every Stop hook and stop-hook-visibility.test.sh
# asserts it, for the reason Layer R asserts the same of the root bootstrap: a
# divergent copy is one hook disagreeing with its siblings about how it tells
# you it has stopped working.
_SHN_LIB="$SCRIPT_DIR/../lib/stop-hook-notice.sh"
if [ -f "$_SHN_LIB" ]; then
    # shellcheck source=../lib/stop-hook-notice.sh
    . "$_SHN_LIB"
else
    # The helper is the thing that makes these notices visible, so its absence
    # must not make them invisible. The hook then announces EVERY turn,
    # undeduplicated, and says why. Degrading toward noise is recoverable by an
    # operator who can read it; degrading toward silence rebuilds the defect.
    stop_notice_init() { :; }
    stop_notice_normal() { :; }
    stop_notice_abnormal() {
        printf '%s\n' "{\"suppressOutput\":true,\"systemMessage\":\"NOTICE HELPER MISSING at $_SHN_LIB, so this is unconditional and undeduplicated: ${2:-}\"}"
        return 0
    }
fi

INPUT="$(cat)"

# Resolve the governed repository. Three outcomes, and ALL THREE let the turn
# end — this hook never refuses one. See "IT REPORTS. IT DOES NOT BLOCK." above.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    stop_notice_init "guard-agent-state-claims.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "AGENT-STATE CLAIM CHECK — NOT RUNNING: could not resolve which repository it governs, so nothing this turn said about any agent was checked against that agent's worktree lock. $HOOK_TAG"
    root_failure_banner "scripts/hooks/guard-agent-state-claims.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CHECK_AGENT_STATE_CLAIMS:=1}"

stop_notice_init "guard-agent-state-claims.sh" "$ENTITY_ROOT" "$INPUT"

if [ "$CHECK_AGENT_STATE_CLAIMS" = "0" ]; then
    # Never a silent permission. An opt-out nobody can see is indistinguishable
    # from a guard that is working, which is the shape of the whole defect.
    stop_notice_abnormal "stood-down" \
        "AGENT-STATE CLAIM CHECK — STOOD DOWN by CHECK_AGENT_STATE_CLAIMS=0 in $CONFIG. Statements that a named agent has finished are NOT being checked against its worktree lock. $HOOK_TAG"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    stop_notice_abnormal "no-python3" \
        "AGENT-STATE CLAIM CHECK — NOT RUNNING: python3 is not on PATH, so this turn's statements about agents went out unchecked. $HOOK_TAG"
    exit 0
fi

ANALYZER="$SCRIPT_DIR/guard-agent-state-claims.py"
if [ ! -f "$ANALYZER" ]; then
    stop_notice_abnormal "no-analyzer" \
        "AGENT-STATE CLAIM CHECK — NOT RUNNING: the analyzer is missing at $ANALYZER, so this turn's statements about agents went out unchecked. $HOOK_TAG"
    exit 0
fi

RESOLVER="$ENGINE_ROOT/scripts/lib/agent-liveness.py"
if [ ! -f "$RESOLVER" ]; then
    # This guard decides NOTHING itself. Without the shared resolver there is no
    # authoritative answer to compare a claim against, and comparing against a
    # guess is exactly what went wrong.
    stop_notice_abnormal "no-resolver" \
        "AGENT-STATE CLAIM CHECK — NOT RUNNING: the liveness resolver is missing at $RESOLVER, so nothing decides whether an agent is alive. $HOOK_TAG"
    exit 0
fi

set +e
OUT="$(printf '%s' "$INPUT" | RICHOS_CLAIMS_ENTITY_ROOT="$ENTITY_ROOT" \
    python3 "$ANALYZER" 2>/dev/null)"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
    # A crash in the analyzer is a guard that did not check, not a clean turn.
    stop_notice_abnormal "analyzer-error" \
        "AGENT-STATE CLAIM CHECK — FAILED (exit $RC): this turn's statements about agents went out unchecked. $HOOK_TAG"
    exit 0
fi

# Everything present, and it just ran. Silent in the ordinary case; one line if
# the previous state was one of the abnormal ones above, so the operator who was
# told it was off is told it is back.
stop_notice_normal \
    "AGENT-STATE CLAIM CHECK — RUNNING AGAIN. Statements that a named agent has finished are being checked against its worktree lock. $HOOK_TAG"

case "$OUT" in
    FIRE*)
        KEY="$(printf '%s' "$OUT" | cut -f2)"
        MSG="$(printf '%s' "$OUT" | cut -f3)"
        stop_notice_abnormal "$KEY" "$MSG $HOOK_TAG"
        exit 0
        ;;
esac

# Nothing contradicted. A claim check that agrees says nothing, ever — but the
# state must return to normal so a LATER contradiction is announced rather than
# deduplicated against a stale key.
stop_notice_normal ""
exit 0
