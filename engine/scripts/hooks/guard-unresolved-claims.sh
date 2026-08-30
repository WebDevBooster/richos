#!/usr/bin/env bash
#
# guard-unresolved-claims.sh — BLOCKING Stop hook. The first enforcement point
# in this engine that observes the ORCHESTRATOR'S BEHAVIOUR rather than the
# repository's state.
#
# WHY A Stop HOOK, AND WHAT WAS VERIFIED BEFORE BUILDING ON IT
#   Every other guard here is PreToolUse/PostToolUse/SessionStart — they watch
#   the repo. Two recurring failures happen inside the turn itself, where no
#   repository hook can see them:
#     1. ending a turn by NAMING the next step instead of taking it
#     2. writing an action claim ("dispatching it rather than queuing it") with
#        no corresponding tool call
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
#   Blocking: unresolved AGENT NAMES and unresolved COMMIT SHAs.
#   Reporting: unresolved FILE PATHS, and a prose in-flight-dispatch signal.
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
# FAIL-OPEN, DELIBERATELY, AND ONLY HERE
#   Every other blocking guard in this engine fails CLOSED. This one does not,
#   and the asymmetry is intentional. A PreToolUse guard that fails closed
#   refuses one tool call. A Stop guard that fails closed refuses to let the
#   session END — it re-fires on every retry until the binary's block cap gives
#   up, and the operator watches a wedged session. The thing being protected
#   here is report integrity, not containment of a destructive act. So a broken
#   install, an unparseable payload, a resolver error or an unreadable
#   transcript all pass the turn through, and the broken-install case SAYS SO on
#   stderr rather than dying quietly. engine-status.sh announces BROKEN at
#   session start anyway.
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
        echo "  It will not guess, and it will not carry on quietly — a defence"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

# Resolve the governed repository. Three outcomes — but unlike a PreToolUse
# guard, ALL THREE let the turn end. See "FAIL-OPEN, DELIBERATELY" above.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    root_failure_banner "scripts/hooks/guard-unresolved-claims.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CHECK_UNRESOLVED_CLAIMS:=1}"

if [ "$CHECK_UNRESOLVED_CLAIMS" = "0" ]; then
    # Never a silent permission: an opt-out that cannot be seen is a defence
    # that decays into a rumour.
    echo "claim check STOOD DOWN by CHECK_UNRESOLVED_CLAIMS=0 in $CONFIG $HOOK_TAG" >&2
    exit 0
fi

# python3 is the analysis half's only dependency. Absent, the turn ends — this
# guard never turns a missing interpreter into an unendable session.
if ! command -v python3 >/dev/null 2>&1; then
    echo "claim check SKIPPED: python3 not on PATH $HOOK_TAG" >&2
    exit 0
fi

ANALYZER="$SCRIPT_DIR/guard-unresolved-claims.py"
if [ ! -f "$ANALYZER" ]; then
    echo "claim check SKIPPED: analyzer missing at $ANALYZER $HOOK_TAG" >&2
    exit 0
fi

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
