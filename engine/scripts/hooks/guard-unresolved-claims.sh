#!/usr/bin/env bash
#
# guard-unresolved-claims.sh — BLOCKING Stop hook. The first enforcement point
# in this engine that observes the ORCHESTRATOR'S BEHAVIOR rather than the
# repository's state.
#
# WHY A Stop HOOK, AND WHAT WAS VERIFIED BEFORE BUILDING ON IT
#   Every other guard here is PreToolUse/PostToolUse/SessionStart — they watch
#   the repo. Two recurring failures happen inside the turn itself, where no
#   repository hook can see them:
#     1. ending a turn by NAMING the next step instead of taking it
#     2. writing an action claim -- "dispatching it now" -- with no
#        corresponding tool call
#   Both happen at exactly the boundary a Stop hook fires on.
#
#   Verified against the SHIPPING BINARY (2.1.251), not documentation:
#     * `Stop` is in the binary's own hook-event list, alongside `StopFailure`
#       and `SubagentStop`.
#     * A Stop hook CAN BLOCK. The binary carries the string "A hook blocked the
#       turn from ending", the telemetry counter `tengu_stop_hook_block_count`,
#       and `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`. Confirmed live: a Stop hook
#       exiting 2 with stderr stopped the turn, the stderr reached the model,
#       and the model acted on it.
#     * The payload carries `transcript_path`, `last_assistant_message`,
#       `stop_hook_active`, `prompt_id`, `background_tasks`, `session_crons`.
#     * The transcript IS readable at Stop time and already holds this turn's
#       tool_use and tool_result records — but NOT the final assistant text,
#       which has not been flushed yet. That is why the message is read from
#       `last_assistant_message` and only the tool traffic from the transcript.
#     * `stop_hook_active` is true on the re-fire after a block, so the gate can
#       stand itself down and never strand a session.
#
# WHAT BLOCKS AND WHAT ONLY REPORTS
#   Blocking: unresolved AGENT NAMES, unresolved COMMIT SHAs, and a BARE-ROLE
#     in-flight claim about a role never dispatched in this session.
#   Reporting: unresolved FILE PATHS, a prose in-flight-dispatch signal, that
#     signal narrowed to messages naming no agent, and a bare-role claim about
#     a role that ran EARLIER and is not running now.
#   The full reasoning — monotonic vs shrinking ground truth, the grounding
#   relaxation, and the measured numbers behind each choice — is in the module
#   docstring of guard-unresolved-claims.py, which is the analysis half.
#
#   Measured on 468 real orchestrator turns across six sessions:
#     agent names   5 tokens    0 false positives
#     commit SHAs   262 tokens  0 false positives
#     file paths    572 tokens  15 false positives (2.6%) -> REPORT ONLY
#     prose signal  418 turns   1 true / 5 false (17% precision) -> REPORT ONLY
#
#   Re-measured 2026-08-31 on 4,134 turns / 3,532 final messages, for the
#   bare-role work. THE NUMBERS DECIDED WHICH HALF BLOCKS:
#     bare-role extraction   103 hits, 103 genuine teammate references (103/103)
#     ...never-dispatched      0 fires -> 0 FP, and 0 TP: it guards a case this
#                              corpus does not contain. BLOCKS, costing nothing.
#     ...spawned-but-not-live  the half that catches the 2026-08-31 failure, and
#                              its FP rate CANNOT be measured — past rosters are
#                              not retained. REPORTS until it can be.
#     prose + names-nobody   29 of the 30 prose hits name nobody, so the filter
#                            removes ONE IN THIRTY: 3 true / 29 = 10.3%, against
#                            the 17% it was proposed to replace. REPORT ONLY.
#
# FAIL-OPEN, DELIBERATELY, AND ONLY HERE
#   Every other blocking guard in this engine fails CLOSED. This one does not,
#   and the asymmetry is intentional. A PreToolUse guard that fails closed
#   refuses one tool call. A Stop guard that fails closed refuses to let the
#   session END — it re-fires on every retry until the binary's block cap gives
#   up, and the operator watches a wedged session. The thing being protected
#   here is report integrity, not containment of a destructive act. So a broken
#   install, an unparseable payload, a resolver error or an unreadable
#   transcript all pass the turn through.
#
#   FAILING OPEN IS ONLY DEFENSIBLE IF IT IS SEEN, and for a while it was not.
#   All four ways this guard stops enforcing — stood down by config, no
#   python3, no analyzer, no resolvable root — announced themselves on STDERR
#   and exited 0. Measured against 2.1.251: a Stop hook's stderr AND its plain
#   stdout are both filed into the transcript as a `hook_success` attachment
#   and shown to the operator NOWHERE. So this guard could be switched off and
#   the operator's only evidence that it was protecting him was that it was
#   quiet — which is also exactly what being disabled looks like. Its own
#   header called that "a defense that decays into a rumour" and then built
#   one. The notices now go through scripts/lib/stop-hook-notice.sh, on the one
#   channel proven to reach him. engine-status.sh announces BROKEN at session
#   start as well, but it speaks once, at startup, about a different question.
#
# WHEN IT TAKES EFFECT
#   Hooks snapshot at session start. Installing this changes nothing in the
#   session that installs it; it begins enforcing in the NEXT session.
#
# Exit codes (Claude Code Stop convention):
#   0  nothing unresolved, not adopted, not evaluable, or anything went wrong
#   2  BLOCKED — an identifier in the final message resolves against nothing
#
# Self-test:  scripts/hooks/guard-unresolved-claims.sh --self-test

set -eo pipefail

HOOK_TAG="(hook: scripts/hooks/guard-unresolved-claims.sh)"

# --- self-test dispatch ---------------------------------------------------
# The suite lives in guard-unresolved-claims.test.sh; this flag exists so the
# hook answers the same question every sibling guard answers.
if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/guard-unresolved-claims.test.sh"
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
        echo "  hook: scripts/hooks/guard-unresolved-claims.sh"
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

# Resolve the governed repository. Three outcomes — but unlike a PreToolUse
# guard, ALL THREE let the turn end. See "FAIL-OPEN, DELIBERATELY" above.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    # No entity root, so no ledger: this one announces every turn, and should.
    # A guard that cannot tell which repository it governs is not a guard, and
    # is not entitled to be quiet. The full banner still goes to stderr, where
    # the transcript keeps it for forensics; the operator gets the one line.
    stop_notice_init "guard-unresolved-claims.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "CLAIM CHECK — NOT RUNNING: could not resolve which repository it governs, so no agent name, commit SHA or file path in this turn's report was checked against anything. Candidates examined are in this hook's transcript entry. $HOOK_TAG"
    root_failure_banner "scripts/hooks/guard-unresolved-claims.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CHECK_UNRESOLVED_CLAIMS:=1}"

stop_notice_init "guard-unresolved-claims.sh" "$ENTITY_ROOT" "$INPUT"

if [ "$CHECK_UNRESOLVED_CLAIMS" = "0" ]; then
    # Never a silent permission: an opt-out that cannot be seen is a defense
    # that decays into a rumour. This line used to write that sentence to
    # STDERR, which the operator cannot see — the guard could be switched off
    # and his only evidence it was protecting him was that it was quiet, which
    # is also exactly what being disabled looks like.
    stop_notice_abnormal "stood-down" \
        "CLAIM CHECK — STOOD DOWN by CHECK_UNRESOLVED_CLAIMS=0 in $CONFIG. Agent names, commit SHAs and file paths in this session's reports are NOT being checked against ground truth. $HOOK_TAG"
    exit 0
fi

# python3 is the analysis half's only dependency. Absent, the turn ends — this
# guard never turns a missing interpreter into an unendable session.
if ! command -v python3 >/dev/null 2>&1; then
    stop_notice_abnormal "no-python3" \
        "CLAIM CHECK — NOT RUNNING: python3 is not on PATH, so this session's reports are going out unchecked. An unchecked turn is not a clean one. $HOOK_TAG"
    exit 0
fi

ANALYZER="$SCRIPT_DIR/guard-unresolved-claims.py"
if [ ! -f "$ANALYZER" ]; then
    stop_notice_abnormal "no-analyzer" \
        "CLAIM CHECK — NOT RUNNING: the analyzer is missing at $ANALYZER, so this session's reports are going out unchecked. An unchecked turn is not a clean one. $HOOK_TAG"
    exit 0
fi

# Everything it needs is present and it is about to check this turn. Silent in
# the ordinary case — the whole point is that a working guard says nothing —
# and one line if the previous state was one of the four above, so the operator
# who was told it was off is told it is back. Safe to emit before the analysis:
# a Stop hook may write systemMessage to stdout AND exit 2, verified live, and
# the turn is still refused.
stop_notice_normal \
    "CLAIM CHECK — RUNNING AGAIN. Agent names, commit SHAs and file paths in this turn's report were checked against ground truth. $HOOK_TAG"

set +e
printf '%s' "$INPUT" | RICHOS_CLAIMS_ENTITY_ROOT="$ENTITY_ROOT" \
    RICHOS_CLAIMS_EXTRA_REPOS="${CLAIM_CHECK_EXTRA_REPOS:-}" \
    python3 "$ANALYZER"
RC=$?
set -e

# Only 2 is a block. Anything else — including a crash in the analyzer — lets
# the turn end.
[ "$RC" = "2" ] && exit 2
exit 0
