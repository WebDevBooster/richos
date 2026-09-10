#!/usr/bin/env bash
#
# notice-land-disposition.sh — NON-BLOCKING Stop hook. FINISHED WORK GETS A
#                              DISPOSITION: IT IS LANDED, OR SOMEBODY WROTE
#                              DOWN WHY IT IS NOT.
#
# The mechanism, the measured threshold, the substrate argument and what this
# cannot see are all in scripts/lib/land-disposition.py. Read that first — it is
# the analysis half. This file is the wiring and the one sentence.
#
# ===========================================================================
# THE INCIDENT
# ===========================================================================
# 2026-09-10. Five finished agents, five workspaces held because their branches
# were unmerged, no land, no deadline, no demand, and nobody the hold belonged
# to. The CEO found them by looking at the branch list in his own IDE — one of
# them `echo-opus-win1`, seven commits, the off-screen-window fix he had already
# asked about twice.
#
# Every mechanism involved behaved correctly. The reclamation lane HELD those
# branches precisely because they were unmerged, and holding was right.
# `notice-unlanded-branches.sh` reported them, once, accurately, that morning.
# What was missing was not a louder alarm — an alarm about a hold does not give
# the hold an owner. What was missing was a REQUIREMENT ON THE WORK.
#
# ===========================================================================
# WHY IT REPORTS AND DOES NOT BLOCK
# ===========================================================================
# `land-completeness-2026-09-10.md` R6 requires anything blocking to be measured
# against real work first, and the measurement argues the other way. The demand
# is written into the escalation ledger, WHICH ALREADY ESCALATES ON ITS OWN at
# 1 hour, 24 hours and 72 hours, and which is already read at every session
# start and at every turn end. A block would add refusals without adding
# pressure — and this project killed three guards in one day (`g11`, `g12`,
# `g13`) by making them broad enough that waiving became habitual.
#
# R7 is satisfied for free rather than by design effort: the recovery path is
# `escalate.sh ack <id> --disposition "..."`, which does not run through
# anything this hook could break.
#
# ===========================================================================
# THIS HOOK WRITES. THAT IS UNUSUAL FOR A NOTICE, SO HERE IS THE WHOLE OF IT
# ===========================================================================
# With LAND_DISPOSITION_DEMAND=1 (the default) it appends to
# ~/.claude/state/escalations.jsonl:
#
#   * ONE demand row per (repository, branch, tip) that is finished, unlanded,
#     unheld by anything live, older than the threshold, and not a `codex/`
#     branch. Idempotent on that key, so a standing demand is never duplicated;
#     a NEW COMMIT on the branch is a new key and does raise again, deliberately,
#     because that is new work now at risk.
#   * ONE acknowledgement row per demand WHOSE WORK HAS SINCE LANDED, carrying
#     the integrating SHA. This is what stops the demand becoming a thing to
#     acknowledge by reflex.
#
# Bounded at six raises per turn, which is also the most that can be named in
# one line — a seventh would be a row nothing announced. It NEVER deletes a
# branch, removes a worktree, merges, or moves a ref: every git call underneath
# is a reader, and land-disposition.test.sh refuses the presence of a mutating
# verb rather than trusting anyone to remember.
#
# LAND_DISPOSITION_DEMAND=0 makes this report-only. It is announced when set,
# never silent — an opt-out nobody can see is a defense that decays into a
# rumor, and this hook's entire subject is silence.
#
# ===========================================================================
# WHY IT IS A SEPARATE HOOK FROM notice-unlanded-branches.sh
# ===========================================================================
# They answer different questions and one of them must run when the other has
# nothing to say. `notice-unlanded-branches.sh` answers "is anything ahead of
# main that nobody holds" — a fact about branches. This answers "is anything
# OWED" — a fact about records, and it must still run when the branch sweep is
# empty, because a demand whose work landed has to be CLOSED on exactly those
# turns. Folding this into that file would have made the closing path
# unreachable in the case it matters most.
#
# They do not double up in the operator's scroll: this one names only work that
# is OWED a disposition, and stays quiet about the young findings the other
# reports.
#
# ===========================================================================
# WHEN IT TAKES EFFECT
# ===========================================================================
# Hooks snapshot at session start. Installing this changes NOTHING in the
# session that installs it — it begins reporting in the NEXT session. Verify it
# is live after a restart with:
#     scripts/hooks/notice-land-disposition.sh --self-test
# and by checking the engine-status banner's registered-hook count.
#
# Exit codes: always 0. This hook never refuses a turn.
#
# Self-test:  scripts/hooks/notice-land-disposition.sh --self-test

set -eo pipefail

HOOK_TAG="(hook: scripts/hooks/notice-land-disposition.sh)"

if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/land-disposition.test.sh"
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
        echo "  hook: scripts/hooks/notice-land-disposition.sh"
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
    # Nothing is governed here. The plugin loads in every directory on the
    # machine and a notice in each would be the noise this engine already
    # decided not to make.
    exit 0
else
    stop_notice_init "notice-land-disposition.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "LAND-DISPOSITION WATCH IS OFF: this hook cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is asking whether finished work is landed or held for a written reason. $HOOK_TAG"
    root_failure_banner "scripts/hooks/notice-land-disposition.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CHECK_LAND_DISPOSITION:=1}"
: "${LAND_DISPOSITION_DEMAND:=1}"
: "${LAND_DISPOSITION_DEMAND_HOURS:=3}"

stop_notice_init "notice-land-disposition.sh" "$ENTITY_ROOT" "$INPUT"

# --- UNEVALUATED-PAYLOAD NOTICE --------------------------------------------
# THIS HOOK IS NOT PAYLOAD-INDEPENDENT AND MUST NOT CLAIM TO BE. The set of
# repositories it sweeps comes from the payload's session_id joined against the
# worktree ledger, and on this machine that is the difference between sweeping
# one repository and sweeping five. A degraded payload therefore produces a
# NARROWER sweep reported in the same words as a full one, which is the defect
# this engine names most often. So it says so instead — and it does NOT write
# demands from a payload it could not read, because a demand raised against a
# half-swept world is a record with a wrong premise in it.
_UE_LIB="$SCRIPT_DIR/../lib/unevaluated-notice.sh"
if [ -f "$_UE_LIB" ]; then
    # shellcheck source=../lib/unevaluated-notice.sh
    . "$_UE_LIB"
    if _UE_REASON="$(richos_payload_unreadable "$INPUT")"; then
        # ONE LINE for the call itself, deliberately: stop-hook-visibility.test.sh
        # proves its case 3a by sed-ing out every such call, and a multi-line
        # continuation would leave the argument lines behind as orphaned commands.
        _UE_MSG="$(unevaluated_sentence "notice-land-disposition.sh" \
            "whether this session left finished work that is neither landed nor held for a written reason" \
            "$_UE_REASON" turn)"
        stop_notice_abnormal "payload-unreadable:$_UE_REASON" "$_UE_MSG"
        exit 0
    fi
fi

if [ "$CHECK_LAND_DISPOSITION" = "0" ]; then
    # Never a silent permission. An opt-out the operator cannot see is a defense
    # that decays into a rumor.
    stop_notice_abnormal "stood-down" \
        "LAND-DISPOSITION WATCH — STOOD DOWN by CHECK_LAND_DISPOSITION=0 in $CONFIG. Finished work that is neither landed nor held for a written reason is NOT being demanded, so a hold can stand for days with nobody it belongs to. $HOOK_TAG"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    stop_notice_abnormal "no-python3" \
        "LAND-DISPOSITION WATCH — NOT RUNNING: python3 is not on PATH, so nothing asked whether finished work is landed or held this turn. $HOOK_TAG"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    stop_notice_abnormal "no-git" \
        "LAND-DISPOSITION WATCH — NOT RUNNING: git is not on PATH, so nothing asked whether finished work is landed or held this turn. $HOOK_TAG"
    exit 0
fi

ANALYZER="$SCRIPT_DIR/../lib/land-disposition.py"
if [ ! -f "$ANALYZER" ]; then
    stop_notice_abnormal "no-analyzer" \
        "LAND-DISPOSITION WATCH — NOT RUNNING: the analyzer is missing at $ANALYZER. A clean main and an absent checker must never look the same. $HOOK_TAG"
    exit 0
fi

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(str(d.get("session_id", "") or "") if isinstance(d, dict) else "")
except Exception:
    print("")
' 2>/dev/null || true)"

DEMAND_ARG=()
[ "$LAND_DISPOSITION_DEMAND" = "1" ] && DEMAND_ARG=(--demand)

# THE RECOVERY LINE IS EMITTED AFTER THE SWEEP, NOT BEFORE. The ledger holds
# ONE state per (session, hook): recording "ok" on entry and the finding
# afterwards makes the two alternate, and the same finding is then announced on
# every single turn — de-duplication defeated by the hook that owns it. That
# bug was caught in notice-unasked-deferral.sh's first run; this hook writes
# both states, so it must write exactly one of them per turn.
set +e
OUT="$(python3 "$ANALYZER" --entity-root "$ENTITY_ROOT" --session "$SESSION_ID" \
        --extra-repos "${UNLANDED_BRANCHES_EXTRA_REPOS:-}" \
        --threshold-hours "$LAND_DISPOSITION_DEMAND_HOURS" \
        "${DEMAND_ARG[@]}" --format hook 2>/dev/null)"
RC=$?
set -e

# 0 nothing owed, 3 something owed, 4 unexamined. Anything else is a crash, and
# a crash must not read as a clean main.
case "$RC" in
    0|3|4) : ;;
    *)
        stop_notice_abnormal "sweep-failed:$RC" \
            "LAND-DISPOSITION WATCH — DID NOT RUN: the check exited $RC without a verdict, so nothing asked whether finished work is landed or held. Do not read this as a clean main; it is an unexamined one. Run scripts/land-disposition.sh by hand. $HOOK_TAG"
        exit 0 ;;
esac

if [ -z "$OUT" ]; then
    stop_notice_abnormal "no-output" \
        "LAND-DISPOSITION WATCH — DID NOT RUN: the check produced no verdict at all. Do not read this as a clean main; it is an unexamined one. Run scripts/land-disposition.sh by hand. $HOOK_TAG"
    exit 0
fi

field() { printf '%s\n' "$OUT" | grep "^$1	" | head -1 | cut -f2- || true; }

STATUS="$(field STATUS)"
REASON="$(field REASON)"
KEY="$(field KEY)"
N="$(field N)"
NRAISED="$(field NRAISED)"
NCLOSED="$(field NCLOSED)"
NUNDECIDED="$(field NUNDECIDED)"
SUMMARY="$(field SUMMARY)"

case "$STATUS" in
    stand-down)
        stop_notice_abnormal "stand-down" \
            "LAND-DISPOSITION WATCH SWEPT NOTHING: ${REASON:-no repository resolved}. This is not a clean main; it is an unread one. $HOOK_TAG"
        exit 0 ;;
    cannot-run)
        stop_notice_abnormal "cannot-run" \
            "LAND-DISPOSITION WATCH — NOT RUNNING: ${REASON:-the check could not be loaded}. Nothing asked whether finished work is landed or held this turn. $HOOK_TAG"
        exit 0 ;;
    partial|swept)
        : ;;
    *)
        stop_notice_abnormal "unknown-status:${STATUS:-empty}" \
            "LAND-DISPOSITION WATCH — UNREADABLE VERDICT ('${STATUS:-empty}'), so nothing here is a statement about main. Run scripts/land-disposition.sh by hand. $HOOK_TAG"
        exit 0 ;;
esac

if [ "${NUNDECIDED:-0}" != "0" ]; then
    # A demand whose work cannot be decided about is NOT a clean state and is
    # not a finding either. It is announced separately so it cannot hide inside
    # either of the two things that look like answers.
    stop_notice_abnormal "undecided:${NUNDECIDED}:${KEY}" \
        "LAND-DISPOSITION: ${NUNDECIDED} standing demand(s) COULD NOT BE DECIDED — the tip they were raised about can no longer be read, so whether that work landed is UNKNOWN and they have NOT been closed. Run scripts/land-disposition.sh. ${SUMMARY:-} $HOOK_TAG"
    exit 0
fi

if [ "${N:-0}" = "0" ] || [ -z "$SUMMARY" ]; then
    RECOVERY="LAND-DISPOSITION: clear again — every piece of finished work is landed, held for a written reason, or held by a live teammate."
    if [ "${NCLOSED:-0}" != "0" ]; then
        RECOVERY="$RECOVERY ${NCLOSED} demand(s) closed themselves because the work landed."
    fi
    stop_notice_normal "$RECOVERY $HOOK_TAG"
    exit 0
fi

# The state key carries the number RAISED as well as the finding set, so the
# turn on which a demand is first written always speaks — a raise is a new
# event, not a persisting condition, and the persisting half is the escalation
# ledger's job rather than this line's.
stop_notice_abnormal "owed:${NRAISED}:${KEY}" "$SUMMARY $HOOK_TAG"
exit 0
