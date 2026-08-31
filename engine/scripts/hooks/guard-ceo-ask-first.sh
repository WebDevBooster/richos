#!/usr/bin/env bash
#
# guard-ceo-ask-first.sh — BLOCKING PreToolUse guard on the Agent tool.
#
# REFUSES TO DISPATCH A TEAMMATE WHILE A PREPARED CEO DECISION HAS NEVER BEEN
# PUT TO HIM THIS SESSION.
#
# The predicate — what counts as prepared, what counts as an ask, where the
# ledger lives and the full fail-open/fail-closed argument — lives in
# scripts/lib/ceo-asks.sh and NOWHERE ELSE. Read that file first; this one is
# the wiring and the refusal.
#
# ===========================================================================
# THE FAILURE
# ===========================================================================
# 2026-08-31. The previous session ended having PREPARED two decisions for the
# CEO. The next session opened, he asked "what's next", and the orchestrator
# answered with a backlog report and dispatched an engineer. The prepared
# questions were never put to him. He asked three times — the last in capitals —
# before his own question reached him.
#
# Every guard was green throughout. ceo-todos-lint.sh passed. row-currency-lint
# .sh passed. The commit guards passed. THE RECORD WAS PERFECT AND NOBODY HAD
# BEEN ASKED ANYTHING. Every mechanism in this engine verifies the record; none
# of them verifies the conversation.
#
# THE CEO'S RULING, 2026-08-31, given in these words when he was asked whether
# this should block work or merely notify loudly: "Block work until asked." He
# was offered the notify-only option and did not take it. This is a BLOCK.
#
# ===========================================================================
# WHY THE Agent EVENT, AND NOTHING ELSE
# ===========================================================================
# Dispatching a teammate is the exact act that beat the ask that morning: he
# asked what was next, and what happened next was an engineer being spawned.
# MOTION IS WHAT WINS, so motion is what gets blocked. The alternatives, argued
# from what the operator experiences rather than left to be re-derived:
#
#   Stop, blocking the turn — REJECTED. A turn that ends because he interrupted,
#     or ends in order to answer him, is a turn ending correctly. Refusing those
#     makes this something to switch off, and a guard people disable protects
#     nothing. The Stop event carries the NOTICE (notice-ceo-unasked.sh), which
#     is the honest use of it.
#   Every Bash call — REJECTED. Reading a file is not what beat the ask, and a
#     gate that fires on everything is a gate nobody can work behind. That
#     design was tried in this repository's history (the every-Bash-call data
#     contract gate) and was retired for exactly this reason.
#   SendMessage — REJECTED. It is the follow-up to a dispatch, not the dispatch.
#     Blocking it strands teammates that are already running.
#
# ===========================================================================
# ONE ITEM, NOT ALL OF THEM
# ===========================================================================
# The rule is AT LEAST ONE prepared item put to him per session. Thirteen are
# open as this ships. A gate that demanded all thirteen before any teammate
# could be dispatched would be the same wall this exists to remove, and it would
# be switched off within a day. One is the floor that makes the conversation
# happen; notice-ceo-unasked.sh carries the remaining twelve to the end of every
# turn, where they belong, without blocking anything.
#
# ===========================================================================
# THE ESCAPE HATCH — a live prompt line, logged
# ===========================================================================
#     ceo-queue-deferred: <reason>
#
# anywhere on its own line in the Agent spawn prompt. It permits that ONE
# dispatch and appends to <entity root>/.claude/state/ceo-queue-defers.log. Same
# idiom as guard-worktree-isolation.sh's `main-checkout-run:` and
# guard-resume-isolation.sh's `resume-ack:`. When the CEO says "get on with it",
# nothing wedges — and the fact that he said it survives the session.
#
# It is a FALLBACK OPT-OUT, not a security boundary. A reason is REQUIRED
# (`ceo-queue-deferred:` with nothing after it does not count), because a bare
# token is something a reflex types and a reason is something a person writes.
#
# ===========================================================================
# FAIL-OPEN vs FAIL-CLOSED — the deliberate choice
# ===========================================================================
# Three states, and the middle one is the whole argument. The reasoning is in
# scripts/lib/ceo-asks.sh; the summary, because a reader of this file is
# entitled to it without a second hop:
#
#   NOT-DECLARED (no CEO queue in this repository)   -> STAND DOWN, silent.
#     The engine loads at USER scope in every directory on the machine. A
#     repository that never declared a CEO queue has no protection to lose, and
#     a notice in each would be the noise this engine already decided not to
#     make.
#   BROKEN (a queue IS declared and cannot be read)  -> FAIL OPEN, LOUD.
#     Open, because a guard that wedges every dispatch over its own plumbing is
#     a guard that gets switched off, and a switched-off guard protects nothing
#     forever. Loud, because "declared and unreadable" is exactly a defense
#     reporting 'on' while protecting nothing.
#   DECLARED, READABLE, holding prepared items       -> FAIL CLOSED. Block.
#
# NOTE ON THE LOUD CHANNEL. On a PASSING exit this hook announces a BROKEN queue
# on stderr and as a `systemMessage`. THE systemMessage CHANNEL IS PROVEN FOR
# Stop HOOKS AND ONLY FOR Stop HOOKS (scripts/lib/stop-hook-notice.sh carries
# the measurement); whether it reaches the operator from PreToolUse is
# UNVERIFIED. That is why notice-ceo-unasked.sh reports the same BROKEN state at
# the end of every turn through the channel that IS measured. This hook's
# loudness is best-effort; the Stop notice's is the guarantee.
#
# NOTE: hooks are snapshotted at session start. This one is INERT until the next
# session — it assumes nothing about being live in the session that adds it.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || exit 0

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
        echo "  hook: scripts/hooks/guard-ceo-ask-first.sh"
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

# announce_broken <one-line> — the best-effort loud channel for a fail-open.
# BOTH stderr and systemMessage, because neither is proven for this event and a
# condition announced on nothing is the defect this whole file is about.
announce_broken() {
    printf '%s\n' "$1" >&2
    SYSMSG="$1" python3 -c '
import json, os
print(json.dumps({"systemMessage": os.environ.get("SYSMSG", "")}))
' 2>/dev/null || true
}

if ! resolve_entity_root "$INPUT"; then
    if [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
        exit 0
    fi
    announce_broken "CEO-ASK GATE IS OFF: it cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is checking whether a prepared CEO decision has been put to him before teammates are dispatched."
    exit 0
fi
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"

_CA_LIB="$SCRIPT_DIR/../lib/ceo-asks.sh"
if [ ! -f "$_CA_LIB" ]; then
    announce_broken "CEO-ASK GATE IS OFF: scripts/lib/ceo-asks.sh is missing at $_CA_LIB, so its entire predicate is absent. Teammate dispatches are UNGATED — a clean run and an absent gate must never look the same."
    exit 0
fi
# shellcheck source=../lib/ceo-asks.sh
. "$_CA_LIB"

if ! ca_require; then
    announce_broken "CEO-ASK GATE IS OFF: $CA_BROKEN. Teammate dispatches are UNGATED."
    exit 0
fi

RRC=0
ca_resolve "$ENTITY_ROOT" || RRC=$?
case "$RRC" in
    0) ;;
    1) exit 0 ;;                    # NOT-DECLARED: no CEO queue here, stand down
    *)
        announce_broken "CEO-ASK GATE IS OFF: this repository DECLARES CEO TODOs and they cannot be read — ${CA_REASON}. Teammate dispatches are UNGATED, and a declared-but-unreadable queue is not an empty one."
        exit 0 ;;
esac

# --- Parse the spawn --------------------------------------------------------
# Only two fields matter: the session id (the ledger is per-session) and the
# prompt (the escape hatch). Newlines are preserved through a \001 placeholder
# so the marker can be matched with a line-start anchor, exactly as
# guard-worktree-isolation.sh does it.
PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("tool_name") not in (None, "", "Agent"):
        raise ValueError("not an Agent spawn")
    ti = d.get("tool_input") or {}
    if not isinstance(ti, dict):
        raise ValueError("tool_input not an object")
    pr = str(ti.get("prompt", "") or "").replace("\t", " ").replace("\n", "\x01")
    print("OK\t%s\t%s\t%s\t%s" % (
        str(d.get("session_id", "") or ""),
        str(ti.get("subagent_type", "") or ""),
        str(ti.get("name", "") or ""),
        pr,
    ))
except Exception:
    print("PARSEFAIL\t\t\t\t")
' 2>/dev/null || printf 'PARSEFAIL\t\t\t\t')"

STATUS="$(printf '%s' "$PARSED" | cut -f1)"
SESSION_ID="$(printf '%s' "$PARSED" | cut -f2)"
SUBAGENT_TYPE="$(printf '%s' "$PARSED" | cut -f3)"
NAME="$(printf '%s' "$PARSED" | cut -f4)"
PROMPT="$(printf '%s' "$PARSED" | cut -f5- | tr '\001' '\n')"

# A spawn payload this guard cannot parse is NOT blocked. Deliberate, and the
# opposite of guard-worktree-isolation.sh's choice on the same event — stated
# rather than left as an inconsistency to be discovered. That guard fails closed
# because an unparseable spawn could be a contract violation it exists to catch.
# This one's subject is not in the payload at all: whether the CEO was asked is
# a fact about the LEDGER, and an unreadable payload tells us nothing about it
# except that we cannot read the escape hatch. Blocking on that would refuse a
# dispatch the operator has no way to permit.
if [ "$STATUS" = "PARSEFAIL" ]; then
    announce_broken "CEO-ASK GATE: could not parse this Agent spawn, so it was not checked and the 'ceo-queue-deferred:' escape hatch could not be read either. This ONE dispatch is ungated."
    exit 0
fi

# --- The escape hatch, before the verdict ----------------------------------
DEFER_MARKER=""
if printf '%s' "$PROMPT" | grep -qE "^[[:space:]]*${CA_DEFER_MARKER}[[:space:]]*[^[:space:]].*"; then
    DEFER_MARKER="$(printf '%s' "$PROMPT" \
        | grep -oE "^[[:space:]]*${CA_DEFER_MARKER}[[:space:]]*[^[:space:]].*" \
        | head -1 | sed -E 's/^[[:space:]]*//')"
fi

ARC=0
ca_assess "$ENTITY_ROOT" "$SESSION_ID" || ARC=$?
case "$ARC" in
    0) exit 0 ;;                     # SATISFIED, or nothing prepared
    1) ;;                            # OPEN — a prepared item, no ask this session
    *)
        announce_broken "CEO-ASK GATE IS OFF: ${CA_BROKEN:-the predicate could not run}. Teammate dispatches are UNGATED."
        exit 0 ;;
esac

if [ -n "$DEFER_MARKER" ]; then
    # Auditable fallback opt-out taken. Best-effort log — never fail a spawn
    # because logging failed; the marker itself is the audit trail.
    LOG_DIR="$ENTITY_ROOT/.claude/state"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    {
        printf '%s\tsession=%s\tagent=%s\tname=%s\tprepared=%s\t%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "${SESSION_ID:-<unset>}" \
            "${SUBAGENT_TYPE:-<unset>}" \
            "${NAME:-<unset>}" \
            "${CA_PREPARED:-?}" \
            "$DEFER_MARKER"
    } >>"$LOG_DIR/$CA_DEFER_LOG_NAME" 2>/dev/null || true
    exit 0
fi

# --- REFUSE ----------------------------------------------------------------
# NAMED, NOT COUNTED. "13 items waiting" is the sentence that got demoted on the
# morning this was ordered; a specific answerable question is what got answered
# in seconds. So the refusal carries the top item AS A QUESTION.
TOP="$(printf '%s\n' "$CA_ASK_LINES" | head -1)"
TOP_ID="$(printf '%s' "$TOP" | cut -f2)"
TOP_TITLE="$(printf '%s' "$TOP" | cut -f3)"
TOP_ASK="$(printf '%s' "$TOP" | cut -f4)"

{
    echo "=== A PREPARED CEO DECISION HAS NOT BEEN PUT TO HIM THIS SESSION — REFUSING THIS DISPATCH ==="
    echo "  prepared items : ${CA_PREPARED:-?}"
    echo "  asked this session : ${CA_ASKED:-0}"
    echo ""
    echo "  On 2026-08-31 a session prepared two decisions for the CEO, the next"
    echo "  session opened, he asked \"what's next\", and he got a backlog report"
    echo "  and a dispatched engineer. Every guard was green. Nobody had been"
    echo "  asked anything. Dispatching a teammate is the act that beat the ask,"
    echo "  so it is the act that is blocked."
    echo ""
    echo "  ASK HIM THIS, with the AskUserQuestion tool:"
    echo ""
    echo "    ${TOP_ID}  ${TOP_TITLE}"
    echo "    ${TOP_ASK}"
    echo ""
    echo "  The gate reads the QUESTION TEXT, not an assertion — the question,"
    echo "  its options and their descriptions have to actually be about one of"
    echo "  his prepared items. A question that matches none of them is recorded"
    echo "  UNMATCHED and discharges nothing. ONE prepared item is the whole"
    echo "  requirement for this session; the rest are surfaced at every turn end."
    echo ""
    if [ "${CA_UNASKED:-0}" -gt 1 ] 2>/dev/null; then
        echo "  The others still open this session:"
        printf '%s\n' "$CA_ASK_LINES" | tail -n +2 | head -5 \
            | awk -F'\t' '{printf "    %s  %s\n", $2, $3}'
        if [ "${CA_UNASKED:-0}" -gt 6 ] 2>/dev/null; then
            echo "    (+$((CA_UNASKED - 6)) more — scripts/ceo-asks-status.sh)"
        fi
        echo ""
    fi
    echo "  IF HE HAS ALREADY SAID GET ON WITH IT, say so on the record — add a"
    echo "  line to this spawn prompt:"
    echo ""
    echo "    ${CA_DEFER_MARKER} <reason>"
    echo ""
    echo "  which permits this one dispatch and is logged to"
    echo "  .claude/state/$CA_DEFER_LOG_NAME."
    echo "(hook: scripts/hooks/guard-ceo-ask-first.sh)"
} >&2
exit 2
