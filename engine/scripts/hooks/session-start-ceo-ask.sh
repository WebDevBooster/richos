#!/usr/bin/env bash
#
# session-start-ceo-ask.sh — SessionStart hook. OPEN WITH HIS QUESTION, NOT
#                            WITH A COUNT OF HIS QUESTIONS.
#
# The predicate is scripts/lib/ceo-asks.sh. This file is four lines of wiring
# and one design decision, and the decision is the whole file.
#
# ===========================================================================
# THE DECISION: A QUESTION, NOT A NUMBER
# ===========================================================================
# On the morning of 2026-08-31 the CEO opened a session and asked "what's next".
# He was given a backlog report — a count and a list of work — and an engineer
# was dispatched. His own prepared questions sat inside that report and were
# never put to him. He asked three times, the last in capitals.
#
# "13 items waiting" is that report in miniature. It is TRUE, it is FINDABLE,
# and it is the exact shape of the thing that got demoted, because a count is
# something to acknowledge and get past. When one of those items was finally
# rendered as a specific answerable question, it was answered in seconds.
#
# So this hook names ONE item and renders it as a question he could answer
# without opening anything, and puts the count BEHIND it rather than in front.
# Same rule notice-unstarted-rows.sh states as "NAMED, NOT COUNTED", applied to
# the one audience that cannot be re-briefed.
#
# TWO CHANNELS, both, always — engine-status.sh's rule and its measurement:
# `hookSpecificOutput.additionalContext` reaches the MODEL and nothing else;
# `systemMessage` reaches the OPERATOR. A question announced only to the model
# is a question the orchestrator may summarize away, which is what happened. A
# question announced only to the operator is one the orchestrator does not know
# it owes. Both, or the announcement has a hole exactly where this defect lives.
#
# IT ANNOUNCES NOTHING when there is no CEO list here, when the list is empty,
# or when every prepared item has already been put to him. Silence is the
# healthy state and is never spent on saying so.
#
# NEVER BLOCKS (SessionStart hooks must not), always exits 0.

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
        echo "  hook: scripts/hooks/session-start-ceo-ask.sh"
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

# NOTE ON STDIN — this hook does NOT read the payload, for the reason
# engine-status.sh documents at length: a SessionStart hook is also runnable as
# a CLI tool, and in that case stdin is an inherited pipe nobody closes, so an
# unconditional `cat` hangs forever. CLAUDE_PROJECT_DIR is measured present and
# correct in a plugin-loaded hook at SessionStart and outranks the payload cwd
# anyway, so the payload carries nothing this needs.
#
# The consequence, stated rather than hidden: the SESSION ID is in the payload,
# so this hook cannot read it. It therefore reports what is prepared, not what
# has been asked — which is correct at session start, where by definition
# nothing has been asked yet.

emit() { # <model-summary> <operator-line>
    SUMMARY="$1" SYSMSG="$2" python3 -c '
import json, os
print(json.dumps({
    "systemMessage": os.environ.get("SYSMSG", ""),
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ.get("SUMMARY", ""),
    },
}))
' 2>/dev/null || true
}

command -v python3 >/dev/null 2>&1 || exit 0

RICHOS_ENTITY_ROOT_RESOLVED=""
resolve_entity_root "" || true
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
[ -n "$ENTITY_ROOT" ] || exit 0

_CA_LIB="$SCRIPT_DIR/../lib/ceo-asks.sh"
[ -f "$_CA_LIB" ] || exit 0
# shellcheck source=../lib/ceo-asks.sh
. "$_CA_LIB"

ca_require || exit 0

RRC=0
ca_resolve "$ENTITY_ROOT" || RRC=$?
case "$RRC" in
    0) ;;
    1) exit 0 ;;
    *)
        emit "The CEO TODOs declared by this repository CANNOT BE READ: ${CA_REASON}. Nothing will be surfaced to him and the CEO-ask gate on teammate dispatches is OFF. Fix the declaration or the record before treating this session's silence as an empty list." \
             "CEO TODOs UNREADABLE: ${CA_REASON} — his list is not being surfaced and the ask gate is off."
        exit 0 ;;
esac

ARC=0
ca_assess "$ENTITY_ROOT" "" || ARC=$?
if [ "$ARC" -ge 2 ]; then
    emit "The CEO TODOs could not be assessed: ${CA_BROKEN:-the predicate could not run}. Treat this as an UNREAD list, not an empty one; scripts/ceo-asks-status.sh has the detail." \
         "CEO TODOs could not be read: ${CA_BROKEN:-predicate failed}."
    exit 0
fi

[ "${CA_UNASKED:-0}" -gt 0 ] || exit 0

TOP="$(printf '%s\n' "$CA_ASK_LINES" | head -1)"
TOP_ID="$(printf '%s' "$TOP" | cut -f2)"
TOP_ASK="$(printf '%s' "$TOP" | cut -f4)"

REST=""
if [ "${CA_UNASKED:-0}" -gt 1 ]; then
    REST=" ($((CA_UNASKED - 1)) more after it — scripts/ceo-asks-status.sh.)"
fi

emit "PUT THIS TO THE CEO BEFORE DISPATCHING ANYONE. His TODO ${TOP_ID}: ${TOP_ASK}${REST} Ask it with the AskUserQuestion tool — a PostToolUse witness records which item the question was actually about, and guard-ceo-ask-first.sh REFUSES every teammate dispatch this session until one of his prepared items has been put to him. Summarizing his list back to him does not count and never has; on 2026-08-31 that is precisely what happened instead of asking." \
     "CEO TODO ${TOP_ID} — ${TOP_ASK}${REST}"
exit 0
