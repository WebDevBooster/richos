#!/usr/bin/env bash
#
# notice-escalations.sh — NON-BLOCKING Stop hook. A TURN DOES NOT END QUIETLY
#                          WHILE A TEAMMATE'S ESCALATION IS SITTING UNREAD.
#
# The predicate, and the argument for every constant, is in
# scripts/lib/escalations.py. Read that first. This file is the wiring and the
# one sentence.
#
# ===========================================================================
# THE FAILURE
# ===========================================================================
# On 2026-09-02 two teammates finished their work and each recorded, correctly,
# that a premise in its brief was contradicted by evidence. Both wrote
# `BLOCKED.md` on their own branch because that was the protocol. They were
# found on 2026-09-04 by a worktree cleanup, because somebody was counting
# directories. NEITHER WAS A STALL and both were right to be written; what
# failed was the channel.
#
# A file on a teammate's branch is visible only to whoever merges that branch,
# and the teammate cannot see whether its branch was ever merged. So the
# escalation now goes to a ledger outside every repository
# (scripts/lib/escalations.py) and THIS is the half that makes it arrive: every
# turn ends here, and a turn that ends with an unacknowledged escalation says so.
#
# ===========================================================================
# WHY IT REPORTS AND DOES NOT BLOCK
# ===========================================================================
# The standing bar in this engine is that a deliverable which only reports has
# failed unless the report IS the mechanism. Here it is. Nothing was ever
# missing except the reading: both escalations existed, in git, in full, for two
# days. The artifact that changes the outcome is the ARRIVAL, on the one channel
# measured to reach the operator, in the turn after it is raised.
#
# Blocking would be the wrong instrument, for the reason guard-inflight-notify.sh
# gives one event over: it would refuse the LEAD's turn until a third party's
# question has been answered, which is how a guard wedges a session. Worse, it
# would make raising an escalation an act that stops the lead working — and a
# teammate who learns that stops raising them. The escalation channel dies the
# moment it becomes expensive to use.
#
# NO ESCAPE HATCH AND NO CONFIG KEY, for the reason notice-waiver-repetition.sh
# states: an opt-out on the thing that watches for unread escalations is absurd,
# and its absence is why this notice cannot decay.
#
# ===========================================================================
# IT SAYS "THIS IS NOT A STALL" EVERY TIME, AND THAT IS DELIBERATE
# ===========================================================================
# The predicate carries each escalation's `state`, and the sentence names it.
# When nothing outstanding is `stopped`, the line says so in words: the work is
# done or continuing. A notice that read every escalation as a failure would
# teach teammates that raising one gets them treated as stalled, and the next
# correct escalation would not be written at all.
#
# ===========================================================================
# ONE LINE, STATE-CHANGE DE-DUPLICATED — AND IT GETS LOUDER
# ===========================================================================
# systemMessage via scripts/lib/stop-hook-notice.sh, the only channel measured
# to reach the operator (see that file's table). A condition repeated under
# every turn is a condition the eye is trained to skip.
#
# But pure de-duplication has a failure mode this hook cannot afford: a
# condition that never changes is announced once and then never again, and THE
# ORIGINALS SAT FOR TWO DAYS. So the state key the predicate returns carries an
# AGE BUCKET per escalation (1h / 24h / 72h), and crossing a boundary is a state
# change. The ledger stop-hook-notice.sh de-duplicates against is keyed per
# SESSION, so a new session re-announces everything outstanding from scratch.
# Silence about an escalation only ever means "still what I told you this
# session" — never "nobody has one".
#
# NOT SCOPED TO A REPOSITORY, deliberately. A session seated in one repository
# with teammates in worktrees of another is the NORMAL shape of this operation;
# a notice that reported only escalations raised in the seat's own repository
# would hide the common case. It stands down only where the engine is not
# adopted at all, because the plugin loads in every directory on the machine.
#
# NOTE: hooks are snapshotted at session start. This one is INERT until the
# next session — it assumes nothing about being live in the session that adds it.
#
# UNEVALUATED-PAYLOAD-EXEMPT: payload-independent — the predicate is the escalation ledger, and this hook already
# announces when that predicate is unavailable — 'ESCALATION WATCH IS OFF' and
# 'ESCALATION WATCH PRODUCED NOTHING'. That is this same property implemented
# for a different input.
#
# WHY THIS ONE NEEDS A DECLARATION WHERE THE OTHER EXEMPT HOOKS DO NOT.
# scripts/hooks/unevaluated-payload.test.sh derives every registered PreToolUse
# and Stop hook from hooks/hooks.json and drives each with an empty, a truncated
# and a non-JSON payload. A hook that REFUSES them is proven fail-closed by that
# alone; a hook that ANNOUNCES on them is proven audible by that alone; neither
# needs a word in its source. But a hook that is SILENT on all four looks
# identical whether its predicate never needed the payload or its predicate was
# silently lost — which is the whole defect, and it is the one thing driving a
# hook cannot tell you. So payload-independence is the single class that must be
# CLAIMED by a person, and the suite then holds the claim to its consequence:
# the output must be identical on all four payloads. An undeclared silent hook
# fails that suite; a falsely declared one fails it too.

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
        echo "  hook: scripts/hooks/notice-escalations.sh"
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

_ESC_LIB="$SCRIPT_DIR/../lib/escalations.sh"
[ -f "$_ESC_LIB" ] || exit 0
# shellcheck source=../lib/escalations.sh
. "$_ESC_LIB"

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # No engine here, so no teammate of this operation is raising anything into
    # it. The plugin loads in every directory on the machine; a notice in each
    # would be the noise this engine already refused to make.
    exit 0
else
    # This hook believes it governs something and cannot tell what. It does NOT
    # exit 2 — a Stop hook that blocks on a broken install re-fires to the block
    # cap and strands the session. It says so instead, on the one channel that
    # reaches the operator, and stops.
    root_failure_banner "scripts/hooks/notice-escalations.sh" >&2
    stop_notice_init "notice-escalations.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "ESCALATION WATCH IS OFF: this hook cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nobody is checking whether a teammate raised something nobody has read — run escalate.sh list by hand."
    exit 0
fi

stop_notice_init "notice-escalations.sh" "$ENTITY_ROOT" "$INPUT"

# NO PREDICATE, NO SILENCE. A wrapper that carried on quietly without its
# predicate would be a hook that is wired, hashed, executable and reading
# nothing — the exact shape that left Layer K green over a scanner that never
# ran. An absent reader and a clean report must never look the same.
if ! escalations_require; then
    stop_notice_abnormal "broken" \
        "ESCALATION WATCH IS OFF: $ESCALATIONS_BROKEN. No teammate escalation was read this turn; do not take this silence for an empty ledger — $(escalations_ledger) is the file, read it by hand."
    exit 0
fi

# ONE INVOCATION, THREE LINES: the state key, the count, and the sentence. The
# predicate owns all three, so this wrapper cannot end up telling the operator a
# different number from the one `escalate.sh list` prints.
set +e
SUMMARY="$(escalations_list hook-summary 2>/dev/null)"
RC=$?
set -e

if [ -z "$SUMMARY" ] || [ "$RC" -ge 2 ]; then
    stop_notice_abnormal "predicate-failed" \
        "ESCALATION WATCH PRODUCED NOTHING (exit $RC) over $(escalations_ledger). A teammate escalation raised now would not be announced; this silence is not a clean report — escalate.sh list has the detail."
    exit 0
fi

KEY="$(printf '%s\n' "$SUMMARY" | sed -n '1p')"
LINE="$(printf '%s\n' "$SUMMARY" | sed -n '3,$p' | tr '\n' ' ' | sed 's/ *$//')"

if [ "$KEY" = "clear" ]; then
    # CLEAR. Nothing is said unless the operator was previously told otherwise,
    # in which case he is owed the end of the story.
    stop_notice_normal \
        "ESCALATION WATCH: clear again — every teammate escalation has been acknowledged."
    exit 0
fi

stop_notice_abnormal "$KEY" "$LINE"
exit 0
