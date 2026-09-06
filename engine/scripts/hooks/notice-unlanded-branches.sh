#!/usr/bin/env bash
#
# notice-unlanded-branches.sh — NON-BLOCKING Stop hook. A TURN DOES NOT END
#                               QUIETLY WHILE FINISHED WORK SITS ON A BRANCH
#                               THAT MAIN HAS NEVER SEEN.
#
# The predicate, the measured narrowings, the liveness rule and what this
# cannot see are all in scripts/lib/unlanded-branches.py. Read that first — it
# is the analysis half. This file is the wiring and the one sentence.
#
# ===========================================================================
# THE INCIDENT
# ===========================================================================
# 2026-09-06. A session ended reporting "Everything is clean and pushed" while
# SIX finished branches sat outside main, one of them the fix for the CEO's own
# complaint that the app steals keyboard focus. Both checks that session ran
# were green AND CORRECT — the working tree was clean, and `main` did match
# `origin/main`. Neither of those two facts can see an unlanded branch, and
# between them they are the whole vocabulary of the word "clean".
#
# Fifty-nine seconds earlier the same session had NAMED two of those branches
# by hand inside escalation acknowledgments, and closed an item citing a signoff
# file that existed only on an unmerged branch. The information was not missing.
# Nothing was standing at the turn end asking for it.
#
# ===========================================================================
# WHY IT REPORTS AND DOES NOT BLOCK
# ===========================================================================
# `Stop` CAN block — that is measured, and guard-idle-land.sh uses it. This one
# deliberately does not, for the reason notice-unstarted-rows.sh gives one event
# over: "there is unlanded work" is a FACT, and "therefore you should not have
# stopped" is a judgment this hook does not have. A turn that ends to ask the
# CEO a question, ends because he interrupted, or ends in the middle of a land
# is a turn ending correctly with branches outstanding. Refusing those would
# make this a thing to switch off, and a guard people disable protects nothing.
#
# ===========================================================================
# SIGNAL QUALITY IS THE WHOLE JOB — the numbers are in the analyzer
# ===========================================================================
# Measured on this machine on 2026-09-06: 201 local branches across five
# repositories, 3 with commits main does not contain, 2 that no live worktree
# holds. A notice keyed on "a branch exists" would have named 201 and been
# muted within a day. The narrowings and the commands that produced every one of
# those numbers are in scripts/lib/unlanded-branches.py; they are not repeated
# here, because a number in two places is a number that will disagree with
# itself.
#
# The two it names today are real: the `BLOCKED.md` escalations of 2026-09-02,
# still outside main four days later.
#
# ===========================================================================
# ONE LINE, STATE-CHANGE DE-DUPLICATED
# ===========================================================================
# systemMessage via scripts/lib/stop-hook-notice.sh, the only channel measured
# to reach the operator (that file carries the table). The state key is the SET
# of findings including each tip SHA, so: a persistent set is announced once, a
# NEW branch going unlanded speaks again, a branch being landed speaks again
# (the set changed), and an agent adding a commit to an already-reported branch
# speaks again — deliberately, because that is new work now at risk.
#
# ===========================================================================
# NOT REGISTERED IN THE PROBE'S LAYER R LIST, AND SAYING SO
# ===========================================================================
# contract-integrity-probe.sh carries a TYPED list (R_ROOTED_HOOKS) of the hooks
# whose root bootstrap it holds byte-identical. This hook is absent from it,
# because that file was owned by another engineer at the moment this was
# written and editing it would have been a collision. Nothing goes red as a
# result — the list is an inventory, not a derivation — which is exactly why it
# is written here rather than left to be noticed: an unlisted hook is one whose
# bootstrap can drift with no check standing over it. Add
# `notice-unlanded-branches` to R_ROOTED_HOOKS. The block below is a byte-exact
# copy of the canonical one until that happens.
#
# ===========================================================================
# WHEN IT TAKES EFFECT
# ===========================================================================
# Hooks snapshot at session start. Installing this changes NOTHING in the
# session that installs it — it begins reporting in the NEXT session. Verify it
# is live after a restart with:
#     scripts/hooks/notice-unlanded-branches.sh --self-test
# and by checking the engine-status banner's registered-hook count.
#
# Exit codes: always 0. This hook never refuses a turn.
#
# Self-test:  scripts/hooks/notice-unlanded-branches.sh --self-test

set -eo pipefail

HOOK_TAG="(hook: scripts/hooks/notice-unlanded-branches.sh)"

if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/unlanded-branches.test.sh"
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
        echo "  hook: scripts/hooks/notice-unlanded-branches.sh"
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
    stop_notice_init "notice-unlanded-branches.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "UNLANDED-BRANCH WATCH IS OFF: this hook cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is checking whether finished work is sitting on a branch main has never seen. $HOOK_TAG"
    root_failure_banner "scripts/hooks/notice-unlanded-branches.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CHECK_UNLANDED_BRANCHES:=1}"

stop_notice_init "notice-unlanded-branches.sh" "$ENTITY_ROOT" "$INPUT"

# --- UNEVALUATED-PAYLOAD NOTICE --------------------------------------------
# THIS HOOK IS NOT PAYLOAD-INDEPENDENT AND MUST NOT CLAIM TO BE. The set of
# repositories it sweeps comes from the payload's session_id joined against the
# worktree ledger, and on this machine that is the difference between sweeping
# one repository and sweeping two — the second being richos, where every
# teammate actually works. A degraded payload therefore produces a NARROWER
# sweep reported in the same words as a full one, which is the defect this
# engine names most often. So it says so instead.
_UE_LIB="$SCRIPT_DIR/../lib/unevaluated-notice.sh"
if [ -f "$_UE_LIB" ]; then
    # shellcheck source=../lib/unevaluated-notice.sh
    . "$_UE_LIB"
    if _UE_REASON="$(richos_payload_unreadable "$INPUT")"; then
        # ONE LINE for the call itself, deliberately: stop-hook-visibility.test.sh
        # proves its case 3a by sed-ing out every such call, and a multi-line
        # continuation would leave the argument lines behind as orphaned commands.
        _UE_MSG="$(unevaluated_sentence "notice-unlanded-branches.sh" \
            "whether this session left finished work on a branch main has never seen" \
            "$_UE_REASON" turn)"
        stop_notice_abnormal "payload-unreadable:$_UE_REASON" "$_UE_MSG"
        exit 0
    fi
fi

if [ "$CHECK_UNLANDED_BRANCHES" = "0" ]; then
    # Never a silent permission. An opt-out the operator cannot see is a defense
    # that decays into a rumor.
    stop_notice_abnormal "stood-down" \
        "UNLANDED-BRANCH WATCH — STOOD DOWN by CHECK_UNLANDED_BRANCHES=0 in $CONFIG. Branches holding finished work outside main are NOT being reported, so a turn may end on the word 'clean' with work stranded. $HOOK_TAG"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    stop_notice_abnormal "no-python3" \
        "UNLANDED-BRANCH WATCH — NOT RUNNING: python3 is not on PATH, so nothing checked whether finished work is sitting outside main this turn. $HOOK_TAG"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    stop_notice_abnormal "no-git" \
        "UNLANDED-BRANCH WATCH — NOT RUNNING: git is not on PATH, so nothing checked whether finished work is sitting outside main this turn. $HOOK_TAG"
    exit 0
fi

SWEEP="$SCRIPT_DIR/../lib/unlanded-branches.py"
if [ ! -f "$SWEEP" ]; then
    stop_notice_abnormal "no-sweep" \
        "UNLANDED-BRANCH WATCH — NOT RUNNING: the sweep is missing at $SWEEP. A clean main and an absent checker must never look the same. $HOOK_TAG"
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

# THE RECOVERY LINE IS EMITTED AFTER THE SWEEP, NOT BEFORE. The ledger holds
# ONE state per (session, hook): recording "ok" on entry and the finding
# afterwards makes the two alternate, and the same finding is then announced on
# every single turn — de-duplication defeated by the hook that owns it. That
# bug was caught in notice-unasked-deferral.sh's first run and its header
# explains it at length; this hook writes both states, so it must write exactly
# one of them per turn.
set +e
OUT="$(python3 "$SWEEP" --entity-root "$ENTITY_ROOT" --session "$SESSION_ID" \
        --extra-repos "${UNLANDED_BRANCHES_EXTRA_REPOS:-}" --format hook 2>/dev/null)"
RC=$?
set -e

if [ "$RC" -ne 0 ] || [ -z "$OUT" ]; then
    stop_notice_abnormal "sweep-failed:$RC" \
        "UNLANDED-BRANCH WATCH — DID NOT RUN: the sweep exited $RC without a verdict, so nothing looked for finished work outside main. Do not read this as a clean main; it is an unexamined one. Run scripts/unlanded-branches-lint.sh by hand. $HOOK_TAG"
    exit 0
fi

field() { printf '%s\n' "$OUT" | grep "^$1	" | head -1 | cut -f2- || true; }

STATUS="$(field STATUS)"
REASON="$(field REASON)"
KEY="$(field KEY)"
N="$(field N)"
SUMMARY="$(field SUMMARY)"

case "$STATUS" in
    stand-down)
        # No repository resolved. Announced rather than silent: this hook
        # believes it governs an adopted root, and an adopted root with no
        # repository behind it is a broken assumption, not an empty result.
        stop_notice_abnormal "stand-down" \
            "UNLANDED-BRANCH WATCH SWEPT NOTHING: ${REASON:-no repository resolved}. This is not a clean main; it is an unread one. $HOOK_TAG"
        exit 0 ;;
    partial)
        : ;;  # some repository could not be answered for; the findings below
              # are still real and the lint script names the gap.
    swept)
        : ;;
    *)
        stop_notice_abnormal "unknown-status:${STATUS:-empty}" \
            "UNLANDED-BRANCH WATCH — UNREADABLE VERDICT ('${STATUS:-empty}'), so nothing here is a statement about main. Run scripts/unlanded-branches-lint.sh by hand. $HOOK_TAG"
        exit 0 ;;
esac

if [ "${N:-0}" = "0" ] || [ -z "$SUMMARY" ]; then
    stop_notice_normal \
        "UNLANDED-BRANCH WATCH: clear again — every branch ahead of main is held by a live teammate, or there are none. $HOOK_TAG"
    exit 0
fi

stop_notice_abnormal "unlanded:$KEY" "$SUMMARY $HOOK_TAG"
exit 0
