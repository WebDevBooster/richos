#!/usr/bin/env bash
#
# notice-ceo-unasked.sh — NON-BLOCKING Stop hook. A TURN DOES NOT END QUIETLY
#                         WHILE A PREPARED CEO DECISION HAS NEVER BEEN PUT TO
#                         HIM THIS SESSION.
#
# The predicate, the failure it exists for and the fail-open/fail-closed
# argument are in scripts/lib/ceo-asks.sh. Read that first. This file is the
# wiring and the one sentence.
#
# ===========================================================================
# WHY IT DOES NOT BLOCK, WHEN ITS SIBLING DOES
# ===========================================================================
# guard-ceo-ask-first.sh BLOCKS a teammate dispatch, on the CEO's explicit
# ruling. This hook deliberately does not block the TURN, and the two are not in
# tension: they are aimed at different things.
#
# Dispatching a teammate is MOTION — the specific act that beat the ask on
# 2026-08-31 — and refusing it costs the operator one question. Ending a turn is
# not motion. A turn that ends BECAUSE he interrupted, or in order to answer
# him, or because the work is done, is a turn ending correctly with the same
# items outstanding. Refusing those would make the whole mechanism something to
# switch off, and a switched-off guard protects nothing forever. The same trade
# notice-unstarted-rows.sh and notice-inflight-acks.sh make, one and two events
# over, for the same reason.
#
# So: the gate is the floor (ONE item), this notice is the completeness (ALL the
# items he has not seen), and neither pretends to be the other.
#
# ===========================================================================
# NAMED, NOT COUNTED — and this is the actual point
# ===========================================================================
# "13 items waiting" is a count. It is also, almost verbatim, the sentence that
# got demoted on the morning this was ordered: the orchestrator had a backlog
# and reported it, and the CEO's own questions stayed inside it. A specific
# answerable question is what got answered in seconds when it finally arrived.
#
# So this notice names ONE item and renders it AS A QUESTION, with the count
# behind it rather than in front of it.
#
# ONE LINE, STATE-CHANGE DE-DUPLICATED, through scripts/lib/stop-hook-notice.sh
# — the only channel measured to reach the operator (that file carries the
# measurement table; on exit 0 the host shows him neither stdout nor stderr).
# The state key is the SET of unasked items, so the notice speaks again the
# moment that set changes — which is exactly the moment one of them is finally
# put to him, and the moment a new one is prepared.

set -eo pipefail

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
        echo "  hook: scripts/hooks/notice-ceo-unasked.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

_SHN_LIB="$SCRIPT_DIR/../lib/stop-hook-notice.sh"
[ -f "$_SHN_LIB" ] || exit 0
# shellcheck source=../lib/stop-hook-notice.sh
. "$_SHN_LIB"

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    # A Stop hook that blocks on a broken install re-fires to the block cap and
    # strands the session. It says so instead, on the one channel that reaches
    # the operator, and stops.
    root_failure_banner "scripts/hooks/notice-ceo-unasked.sh" >&2
    stop_notice_init "notice-ceo-unasked.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "CEO-ASK WATCH IS OFF: this hook cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is checking whether a prepared CEO decision has been put to him — run scripts/ceo-asks-status.sh by hand."
    exit 0
fi

stop_notice_init "notice-ceo-unasked.sh" "$ENTITY_ROOT" "$INPUT"

_CA_LIB="$SCRIPT_DIR/../lib/ceo-asks.sh"
if [ ! -f "$_CA_LIB" ]; then
    stop_notice_abnormal "no-lib" \
        "CEO-ASK WATCH IS OFF: scripts/lib/ceo-asks.sh is missing, so no prepared CEO decision was checked. A clean session and an absent checker must never look the same."
    exit 0
fi
# shellcheck source=../lib/ceo-asks.sh
. "$_CA_LIB"

if ! ca_require; then
    stop_notice_abnormal "cannot-run:$(printf '%s' "$CA_BROKEN" | cksum | tr -d ' ')" \
        "CEO-ASK WATCH IS BROKEN, so nothing was checked: ${CA_BROKEN}. Do not read this silence as an empty list."
    exit 0
fi

RRC=0
ca_resolve "$ENTITY_ROOT" || RRC=$?
case "$RRC" in
    0) ;;
    1)
        # NOT-DECLARED is the ordinary answer in every repository with no CEO
        # list, and announcing it everywhere would be the noise this engine
        # already decided not to make. stop_notice_normal is still called so a
        # repository that RECOVERS from a broken state gets the end of its story.
        stop_notice_normal ""
        exit 0 ;;
    *)
        # THE LOUD FAIL-OPEN. guard-ceo-ask-first.sh also announces this, but on
        # a channel that is unproven for PreToolUse. This is the one that is
        # measured, so this is the guarantee.
        stop_notice_abnormal "broken:$(printf '%s' "$CA_REASON" | cksum | tr -d ' ')" \
            "CEO-ASK WATCH IS BROKEN: this repository DECLARES CEO TODOs and they cannot be read — ${CA_REASON}. Teammate dispatches are UNGATED and no prepared decision is being surfaced. A declared-but-unreadable list is not an empty one."
        exit 0 ;;
esac

# Read here rather than through stop-hook-notice.sh's own extractor: that one is
# private to the de-duplication ledger, and a notice reaching into a sibling's
# internals is a coupling that breaks silently. Same shape as
# notice-inflight-acks.sh's.
SESSION_ID="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(str(d.get("session_id","") or "") if isinstance(d,dict) else "")
except Exception: print("")' 2>/dev/null || true)"

ARC=0
ca_assess "$ENTITY_ROOT" "$SESSION_ID" || ARC=$?
if [ "$ARC" -ge 2 ]; then
    stop_notice_abnormal "assess-broken:$(printf '%s' "${CA_BROKEN:-}" | cksum | tr -d ' ')" \
        "CEO-ASK WATCH SWEPT NOTHING — ${CA_BROKEN:-the predicate could not run}. This is not an empty list; it is an unread one. Detail: scripts/ceo-asks-status.sh"
    exit 0
fi

if [ "${CA_UNASKED:-0}" -eq 0 ]; then
    stop_notice_normal \
        "CEO-ASK WATCH: clear — every prepared item on his TODOs has been put to him this session."
    exit 0
fi

TOP="$(printf '%s\n' "$CA_ASK_LINES" | head -1)"
TOP_ID="$(printf '%s' "$TOP" | cut -f2)"
TOP_ASK="$(printf '%s' "$TOP" | cut -f4)"
IDS="$(printf '%s\n' "$CA_ASK_LINES" | awk -F'\t' '{printf "%s ", $2}')"

MORE=""
if [ "${CA_UNASKED:-0}" -gt 1 ]; then
    MORE=" ${CA_UNASKED} of his prepared items have not been put to him in this session."
fi

stop_notice_abnormal "unasked:$IDS" \
    "HE HAS NOT BEEN ASKED — CEO TODO ${TOP_ID}: ${TOP_ASK}${MORE} Put one to him with AskUserQuestion; asking is what discharges this, not recording it. Full list: scripts/ceo-asks-status.sh"
exit 0
