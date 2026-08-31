#!/usr/bin/env bash
#
# notice-unstarted-rows.sh — NON-BLOCKING Stop hook. A TURN DOES NOT END
#                            QUIETLY WHILE AN UNBLOCKED ROW HAS NOTHING
#                            RUNNING FOR IT.
#
# The argument, the two failure directions it is designed against, and what it
# cannot see are all in scripts/lib/unstarted-rows.sh. Read that first. This
# file is the wiring: resolve the repository, sweep, and say the one sentence.
#
# ===========================================================================
# WHY IT DOES NOT BLOCK
# ===========================================================================
# `Stop` CAN block — that is measured, and guard-idle-land.sh uses it. This one
# deliberately does not, and the reason is that its subject is a judgment the
# hook does not have. "There is an unblocked row and nothing is running for it"
# is a FACT; "and therefore you should not have stopped" is not. A turn that
# ends to ask the CEO a question, or ends because he interrupted, is a turn
# ending correctly with the same set of rows outstanding. Refusing those would
# make the mechanism something to be switched off, and a guard people disable
# protects nothing.
#
# So it states the fact, names the rows, and leaves the decision where it
# belongs — which is the same trade notice-inflight-acks.sh makes, for the same
# reason, one event over.
#
# ===========================================================================
# ONE LINE, STATE-CHANGE DE-DUPLICATED
# ===========================================================================
# systemMessage via scripts/lib/stop-hook-notice.sh, because that is the only
# channel measured to reach the operator (see that file's table). A persistent
# set of rows is announced ONCE; the notice speaks again when the SET changes,
# which is exactly the moment a row is created without being started, and the
# moment one is finally picked up. A condition repeated under every turn is a
# condition the eye is trained to skip.

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
        echo "  hook: scripts/hooks/notice-unstarted-rows.sh"
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
    # Nothing is governed here, so no row of this repository can be unstarted.
    # The plugin loads in every directory on the machine; a notice in each would
    # be noise, and engine-status.sh already announces the stand-down at session
    # start.
    exit 0
else
    # This hook believes it governs something and cannot tell what. It does NOT
    # exit 2 — a Stop hook that blocks on a broken install re-fires to the block
    # cap and strands the session. It says so instead, on the one channel that
    # reaches the operator, and stops.
    root_failure_banner "scripts/hooks/notice-unstarted-rows.sh" >&2
    stop_notice_init "notice-unstarted-rows.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "UNSTARTED-ROW WATCH IS OFF: this hook cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nobody is checking whether an unblocked row has anything running for it — run scripts/unstarted-rows-lint.sh by hand."
    exit 0
fi

stop_notice_init "notice-unstarted-rows.sh" "$ENTITY_ROOT" "$INPUT"

STATE_DIR="$ENTITY_ROOT/.claude/state/unstarted-rows"
RECEIPT="$STATE_DIR/last-sweep.txt"
ADOPTED="$STATE_DIR/adopted.txt"

_UR_LIB="$SCRIPT_DIR/../lib/unstarted-rows.sh"
if [ ! -f "$_UR_LIB" ]; then
    stop_notice_abnormal "no-lib" \
        "UNSTARTED-ROW WATCH IS OFF: scripts/lib/unstarted-rows.sh is missing, so no row was swept. A clean queue and an absent checker must never look the same."
    exit 0
fi
# shellcheck source=../lib/unstarted-rows.sh
. "$_UR_LIB"

RRC=0
ur_resolve "$ENTITY_ROOT" || RRC=$?
if [ "$RRC" -eq 2 ]; then
    UR_VERDICT="BROKEN"
    ur_receipt "$RECEIPT"
    stop_notice_abnormal "broken:$(printf '%s' "${UR_BROKEN_REASON:-}" | cksum | tr -d ' ')" \
        "UNSTARTED-ROW WATCH IS BROKEN, so nothing was swept: ${UR_BROKEN_REASON:-unknown}. Fix it or run scripts/unstarted-rows-lint.sh by hand — do not read this silence as an empty queue."
    exit 0
fi

if [ "$RRC" -eq 1 ]; then
    # STAND-DOWN, WITH A MEMORY. Adoption is the queue record existing, so a
    # stand-down is the ordinary answer in every repository that has no such
    # backlog — and announcing it everywhere would be the noise this engine
    # already decided not to make. But a repository that WAS swept and now
    # stands down has had its queue renamed or deleted underneath it, and that
    # is the "green over an empty set" failure arriving by the back door.
    if [ -s "$ADOPTED" ]; then
        PRIOR="$(cat "$ADOPTED" 2>/dev/null || true)"
        UR_VERDICT="BROKEN"
        UR_BROKEN_REASON="this repository was swept before, against $PRIOR, and now stands down: ${UR_STANDDOWN_REASON:-no reason given}"
        ur_receipt "$RECEIPT"
        stop_notice_abnormal "lost-queue" \
            "UNSTARTED-ROW WATCH LOST ITS QUEUE: it swept $PRIOR before and cannot find it now (${UR_STANDDOWN_REASON:-no reason given}). Every row in it is currently invisible; this is silence caused by a missing file, not by an empty backlog."
        exit 0
    fi
    UR_VERDICT="STOOD-DOWN"
    ur_receipt "$RECEIPT"
    stop_notice_normal ""
    exit 0
fi

# Adopted. Remember it, so a later disappearance is loud rather than quiet.
mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s\n' "$UR_QUEUE_FILE" > "$ADOPTED" 2>/dev/null || true

ur_collect_claims
ur_sweep
ur_receipt "$RECEIPT"

case "$UR_VERDICT" in
    BROKEN)
        stop_notice_abnormal "broken:$(printf '%s' "${UR_BROKEN_REASON:-}" | cksum | tr -d ' ')" \
            "UNSTARTED-ROW WATCH SWEPT NOTHING — the records did not parse: ${UR_BROKEN_REASON:-unknown}. This is not an empty queue; it is an unread one. scripts/unstarted-rows-lint.sh has the detail."
        exit 0 ;;
    SWEPT)
        stop_notice_normal \
            "UNSTARTED-ROW WATCH: clear again — all ${UR_N_ROWS:-0} rows are closed, claimed by a live worktree, or name what they are waiting on."
        exit 0 ;;
esac

# NAMED, NOT COUNTED. A count is a number to get used to; a name is a thing to
# go and start. Six is where one line stops being readable, and the rest are
# reachable in one command rather than lost.
NAMES="$(printf '%s' "$UR_UNSTARTED" | tr ' ' '\n' | head -6 | tr '\n' ' ' | sed 's/ $//' | sed 's/ /, /g')"
MORE=""
[ "${UR_N_UNSTARTED:-0}" -gt 6 ] && MORE=" (+$((UR_N_UNSTARTED - 6)) more)"

stop_notice_abnormal "unstarted:$UR_UNSTARTED" \
    "UNSTARTED WORK, NOTHING RUNNING FOR IT — ${UR_N_UNSTARTED} row(s): ${NAMES}${MORE}. Nothing is named as blocking them and no live worktree claims them, so writing them down is all that has happened. Start one, or say what it waits on: a \`Blocked by\` cell in ${UR_QUEUE_LABEL}, or \`**Blocked:** <who>\` in a ${UR_RECORD_LABEL} row. Detail: scripts/unstarted-rows-lint.sh"
exit 0
