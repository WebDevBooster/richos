#!/usr/bin/env bash
#
# notice-unasked-deferral.sh — NON-BLOCKING Stop hook. A TURN DOES NOT END
#                              QUIETLY WHILE IT ANNOUNCES A DEFERRAL THE CEO
#                              WAS NEVER GIVEN THE CHANCE TO CHOOSE.
#
# The predicate, the corpus, the precision number, the constructions that were
# refused and WHY are in guard-unasked-deferral.py. Read that first — it is the
# analysis half. This file is the wiring and the one sentence.
#
# ===========================================================================
# THE RULE
# ===========================================================================
# A turn whose text DEFERS WORK must be paired with one of:
#   1. an AskUserQuestion in the same turn putting the deferral to him, or
#   2. an explicit CEO instruction to defer, already on the record, or
#   3. an Agent spawn in the same turn that actually starts the deferred thing.
# Otherwise this notice names the deferral, quotes the construction it matched,
# and says plainly that a deferral the CEO did not choose is a decision taken on
# his behalf.
#
# ===========================================================================
# WHY IT REPORTS AND DOES NOT BLOCK
# ===========================================================================
# By the time this fires the harm has already happened — the decision was taken
# and announced inside the text the operator is about to read. Blocking cannot
# unsay it. What blocking WOULD do is refuse to let a turn end over a regex on
# PROSE, re-firing to the binary's block cap while the operator watches a wedged
# session, and the first thing a wedged session earns is CHECK_UNASKED_DEFERRAL=0.
#
# That is the exact failure mode that produced this defect: a mechanism that is
# switched off protects nothing forever. The value here is that the CEO sees the
# deferral NAMED in the same turn, instead of having to ask a third time. Same
# trade as notice-ceo-unasked.sh, notice-unstarted-rows.sh and
# notice-inflight-acks.sh, for the same reason.
#
# ===========================================================================
# WHAT IT CANNOT DO, SAID HERE RATHER THAN ENGINEERED AROUND
# ===========================================================================
# THE ORCHESTRATOR CAN PHRASE AROUND ANY WORD LIST, and this one is six patterns
# wide. It catches the NATURAL PHRASING OF AN UNNOTICED HABIT — which is the
# actual failure mode; the specimen was written with no awareness that it was
# taking a decision that belonged to the CEO. It does not and cannot catch
# deliberate evasion. Claiming otherwise would make it a checkbox, and this
# engine's cold open is explicit about what a checkbox is worth.
#
# ===========================================================================
# WHEN IT TAKES EFFECT
# ===========================================================================
# Hooks snapshot at session start. Installing this changes NOTHING in the
# session that installs it — it begins reporting in the NEXT session. Verify it
# is live after a restart with:  scripts/hooks/notice-unasked-deferral.sh --self-test
# and by checking the engine-status banner's registered-hook count.
#
# ONE LINE, STATE-CHANGE DE-DUPLICATED, through scripts/lib/stop-hook-notice.sh
# — the only channel measured to reach the operator (that file carries the
# measurement table; on exit 0 the host shows him neither stdout nor stderr).
# The state key is the construction plus a hash of the quote, so a second
# DIFFERENT deferral speaks again and a re-report of the same one does not.
#
# Exit codes: always 0. This hook never refuses a turn.
#
# Self-test:  scripts/hooks/notice-unasked-deferral.sh --self-test

set -eo pipefail

HOOK_TAG="(hook: scripts/hooks/notice-unasked-deferral.sh)"

if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/unasked-deferral.test.sh"
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
        echo "  hook: scripts/hooks/notice-unasked-deferral.sh"
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

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    stop_notice_init "notice-unasked-deferral.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "DEFERRAL WATCH IS OFF: this hook cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is checking whether this turn deferred something the CEO never chose to defer. $HOOK_TAG"
    root_failure_banner "scripts/hooks/notice-unasked-deferral.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CHECK_UNASKED_DEFERRAL:=1}"

stop_notice_init "notice-unasked-deferral.sh" "$ENTITY_ROOT" "$INPUT"

if [ "$CHECK_UNASKED_DEFERRAL" = "0" ]; then
    # Never a silent permission. An opt-out the operator cannot see is a defense
    # that decays into a rumour — and this particular guard exists precisely
    # because a decision was taken quietly.
    stop_notice_abnormal "stood-down" \
        "DEFERRAL WATCH — STOOD DOWN by CHECK_UNASKED_DEFERRAL=0 in $CONFIG. Turns that postpone work you asked for are NOT being flagged, so a deferral you never chose will pass silently. $HOOK_TAG"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    stop_notice_abnormal "no-python3" \
        "DEFERRAL WATCH — NOT RUNNING: python3 is not on PATH, so this turn was not checked for a deferral you were never asked about. $HOOK_TAG"
    exit 0
fi

ANALYZER="$SCRIPT_DIR/guard-unasked-deferral.py"
if [ ! -f "$ANALYZER" ]; then
    stop_notice_abnormal "no-analyzer" \
        "DEFERRAL WATCH — NOT RUNNING: the analyzer is missing at $ANALYZER, so this turn was not checked for a deferral you were never asked about. $HOOK_TAG"
    exit 0
fi

# THE RECOVERY LINE IS EMITTED AFTER THE ANALYSIS, NOT BEFORE, and the reason
# is a bug this suite caught in its first run. The ledger holds ONE state per
# (session, hook). Recording "ok" on entry and then recording the finding
# afterwards makes the two calls alternate: every turn the finding key replaces
# "ok", every next turn "ok" replaces the finding key, and BOTH of them see a
# changed state and speak. The same deferral was announced on every single turn
# — de-duplication defeated by the hook that owns it.
#
# guard-unresolved-claims.sh announces up front and is right to: its finding
# goes out on exit 2, never through this ledger, so it only ever writes "ok".
# This hook writes both, so it must write exactly one of them per turn.

set +e
FINDING="$(printf '%s' "$INPUT" | python3 "$ANALYZER" 2>/dev/null)"
RC=$?
set -e

# 3 is the only code that means "a deferral fired". Anything else — including a
# crash in the analyzer — ends the turn quietly, because this hook's whole
# premise is that it is cheaper to miss one than to be switched off.
# The healthy-and-clean path. stop_notice_normal is silent unless the previous
# state was one of the stand-downs above, in which case the operator who was
# told this guard was off is told it is back.
notice_clean() {
    stop_notice_normal \
        "DEFERRAL WATCH — RUNNING AGAIN. This turn's text was checked for work postponed without putting the choice to you. $HOOK_TAG"
    exit 0
}

[ "$RC" = "3" ] || notice_clean
[ -n "$FINDING" ] || notice_clean

CONSTRUCTION="$(printf '%s' "$FINDING" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(str(d.get("construction","") or ""))
except Exception: print("")' 2>/dev/null || true)"
QUOTE="$(printf '%s' "$FINDING" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(str(d.get("quote","") or ""))
except Exception: print("")' 2>/dev/null || true)"

[ -n "$QUOTE" ] || notice_clean

# The state key is construction + quote hash: a second, DIFFERENT deferral
# speaks again; the same one restated does not.
KEY="deferral:${CONSTRUCTION}:$(printf '%s' "$QUOTE" | cksum | tr -d ' ')"

stop_notice_abnormal "$KEY" \
    "YOU WERE NOT ASKED — THIS TURN DEFERS WORK: \"${QUOTE}\". A deferral you did not choose is a decision taken on your behalf: the reasoning is the orchestrator's, the consequence is yours. Deferring may well be right — but it is YOUR call, so it goes to you as a question or the work starts now. $HOOK_TAG"
exit 0
