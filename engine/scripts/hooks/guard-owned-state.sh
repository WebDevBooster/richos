#!/usr/bin/env bash
#
# guard-owned-state.sh — BLOCKING PreToolUse guard on the Agent tool.
#
# REFUSES TO DISPATCH A TEAMMATE AT UNRELATED WORK WHILE A SYSTEM THE
# ORCHESTRATOR OWNS THE HEALTH OF IS KNOWN-BAD AND NOBODY HAS DONE ANYTHING
# ABOUT IT THIS SESSION.
#
# The inventory, and the argument for every row in it, is in
# `owned-systems.declaration` at the engine root. The predicate — what healthy
# means, how a verdict is taken, how age is derived, what the cache is for —
# is in scripts/lib/owned-systems.py and NOWHERE ELSE. Read those first; this
# file is the wiring and the refusal.
#
# ===========================================================================
# THE FAILURE
# ===========================================================================
# 2026-09-10. The founder found, himself, in one day: a workflow red on main
# for thirteen days, 30 GB of worktrees that nothing would ever reclaim, and
# the engine's own hook text printing on his screen. He was then told the
# owned-outcome PRD would fix the general case, and he answered:
#
#     "even if that PRD were to get magically implemented within the next 5
#      seconds, that still doesn't fully answer the questions I previously
#      raised, does it?"
#
# He was right. That PRD is triggered by an ASSIGNMENT and carries that
# assignment's outcome to completion. EVERY DEFECT HE FOUND THAT DAY WAS
# UNASSIGNED. Nothing pointed at CI. Nothing pointed at the worktrees.
#
# AND THE PART THAT DECIDED THE SHAPE OF THIS FILE: THE WORST OF IT WAS
# ALREADY ON THE SCREEN. That same session's SessionStart notice said "worktree
# reconciler: BLOCKED (46 member(s) cannot proceed by waiting) ... live workers
# positively present=0" and the session read past it and got on with something
# else. Surfacing had already been tried and had already failed, in front of
# him, that morning.
#
# So this does not surface anything. It makes a known-bad state cost the only
# thing that has ever changed behavior here: THE ABILITY TO GET ON WITH
# SOMETHING ELSE.
#
# ===========================================================================
# ONE SYSTEM PER SESSION — THE WHOLE DESIGN IS IN THIS SECTION
# ===========================================================================
# This project has killed three guards (g11/g12/g13) in a single day by making
# them broad enough that waiving became the daily habit. A gate demanding a
# disposition for all six systems would be that guard: six waivers to type at
# the first dispatch of every session, every one of them typed without reading.
# Today's real state — six systems in the declaration, five of them standing —
# would have produced exactly that on day one.
#
# So the requirement is ONE. Precisely:
#
#   * The gate demands a disposition for the SINGLE oldest standing system.
#   * ANY disposition recorded this session satisfies the gate for the whole
#     session. Not one per system. One, total, ever, per session.
#   * A dispatch that ADDRESSES a standing system is itself a disposition, so
#     the natural reply to being refused — putting somebody on the problem —
#     is what clears it. This gate wants to be answered with work, not with a
#     marker.
#
# COST, STATED HONESTLY AND MEASURED RATHER THAN ASSERTED: at most ONE
# deliberate act per session, at the first teammate dispatch, and complete
# silence for the rest of that session. That is the test this engine applies to
# its own gates — "if it fires on ordinary work several times a day it is
# wrong" — and one-per-session passes it by a wide margin.
#
# ONE PER SESSION IS ALSO WHY THE OLDEST IS THE ONE DEMANDED. If the gate named
# whichever system were cheapest to clear, an operator would clear the cheap one
# every session forever and the thirteen-day red would never come up. The
# demanded item is the one that has been standing longest, its age is printed in
# the refusal, and it comes back tomorrow with a bigger number on it.
#
# ===========================================================================
# WHY THE Agent EVENT, AND NOTHING ELSE
# ===========================================================================
# Getting on with something else IS dispatching a teammate: this orchestrator
# does no work directly, so a spawn is the observable form of "moving on". The
# alternatives, argued rather than left to be re-derived:
#
#   Stop, blocking the turn — REJECTED for the reason guard-ceo-ask-first.sh
#     gives on the same choice: a turn that ends because the founder
#     interrupted is a turn ending correctly, and refusing those makes this
#     something to switch off. The end of a turn is a NOTICE's event.
#   Every Bash call — REJECTED. Reading a file is not "getting on with
#     something else", and a gate that fires on everything is a gate nobody can
#     work behind. That exact design was tried in this project's history (the
#     every-Bash-call data-contract gate) and was retired for this reason.
#   The land — REJECTED. Landing a teammate's finished work is the opposite of
#     ignoring an owned system; blocking it strands committed work, which is
#     the `unlanded` row's own failure mode.
#
# ===========================================================================
# WHAT COUNTS AS ADDRESSING IT — AND WHY THE GATE ALLOWS THAT SILENTLY
# ===========================================================================
# Each row declares a `match:` regular expression over the spawn prompt. A
# dispatch that matches a STANDING system is working on it, so it is allowed,
# recorded as the session's disposition, and nothing is printed. A gate that
# lectured the operator at the exact moment he did the right thing would be
# teaching the wrong lesson.
#
# The match is deliberately allowed to be a little broad, because the cost of a
# false ADDRESS is small — it permits one dispatch that was going to be
# permitted by an ack anyway — while the cost of a false REFUSAL is a gate
# routed around. This is the mirror image of guard-stale-staging.sh's scope
# classifier, which is allowed to be broad because a second, narrow fact gates
# it.
#
# ===========================================================================
# THE ESCAPE HATCH — a live prompt line, with a reason, logged
# ===========================================================================
#     owned-state-ack: <system id> — <why this can wait>
#
# anywhere on its own line in the Agent spawn prompt. Same idiom as
# `model-ceiling-ack:`, `main-checkout-run:`, `resume-ack:`,
# `stale-staging-ack:` and `ceo-todos-deferred:`.
#
#   * It must name the DEMANDED system's id. Any other id is refused with the
#     right one printed — that is what stops the cheapest-first rotation.
#   * The reason must be at least 15 characters. A bare marker exempts nothing,
#     because a bare token is something a reflex types and a reason is
#     something a person writes.
#   * It is appended to <entity root>/.claude/state/owned-state-acks.log, which
#     notice-waiver-repetition.py reads: an operator who types the same excuse
#     about the same system session after session gets NAMED for it. That is
#     the anti-habit machinery this engine already ships, and this hatch is
#     wired into it rather than inventing a second one.
#
# ===========================================================================
# FAIL OPEN, AND LOUDLY — the deliberate choice, state by state
# ===========================================================================
#   NOT ADOPTED (no orchestration.config anywhere)  -> STAND DOWN, SILENT.
#     The engine loads at USER scope in every directory on this machine.
#   OWNED_STATE_GATE="0"                            -> STAND DOWN, SILENT.
#     The declared opt-out. Absent means ENABLED, which matches every other
#     guard here: enforcement that has to be switched on is enforcement a fresh
#     clone does not have.
#   DECLARATION MISSING OR MALFORMED                -> ALLOW + ANNOUNCE LOUD.
#     "Declared and unreadable" is a defense reporting 'on' while protecting
#     nothing, and it must never look like a clean run.
#   A CHECK CANNOT BE RUN                           -> that SYSTEM is UNKNOWN,
#     which stands like a red one but sorts below it. An absent check is never
#     a passing check.
#   PAYLOAD UNPARSEABLE                             -> ALLOW + ANNOUNCE. The
#     ack line cannot be read from such a payload either, so refusing would
#     block a dispatch the operator has no way to permit. Same choice, for the
#     same reason, as guard-model-ceiling.sh and guard-stale-staging.sh.
#   python3 MISSING                                 -> ALLOW + ANNOUNCE.
#
# The one thing that is NOT fail-open: scripts/lib/resolve-roots.sh missing
# entirely. That is the shared bootstrap's contract and probe Layer R asserts
# every rooted hook carries it byte-identically.
#
# NOTE: hooks are snapshotted at session start. This one is INERT until the
# next session — it assumes nothing about being live in the session that adds
# it.

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
        echo "  hook: scripts/hooks/guard-owned-state.sh"
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

# announce_off <one-line> — the best-effort loud channel for a fail-open. BOTH
# stderr and systemMessage, because neither is proven for this event and a
# condition announced on nothing is the defect this whole file is about.
announce_off() {
    printf '%s\n' "$1" >&2
    if command -v python3 >/dev/null 2>&1; then
        SYSMSG="$1" python3 -c '
import json, os
print(json.dumps({"systemMessage": os.environ.get("SYSMSG", "")}))
' 2>/dev/null || true
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    announce_off "OWNED-STATE GATE IS OFF: python3 is not on PATH, so no owned system was checked and this dispatch is UNGATED."
    exit 0
fi

if ! resolve_entity_root "$INPUT"; then
    if [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
        exit 0
    fi
    announce_off "OWNED-STATE GATE IS OFF: it cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is checking whether an owned system is standing unaddressed."
    exit 0
fi
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

# --- THE OPT-OUT SWITCH ----------------------------------------------------
# ABSENT MEANS ENABLED. Deliberate and opposite to guard-stale-staging.sh's
# adoption switch: staging is a thing most repositories genuinely do not have,
# while "some system whose health you own is bad and you did nothing" is true
# of every repository an orchestrator runs in. A gate that has to be switched
# on is a gate a fresh clone does not have.
case "${OWNED_STATE_GATE:-1}" in
    0|no|off|false) exit 0 ;;
esac

LIB="$SCRIPT_DIR/../lib/owned-systems.py"
if [ ! -f "$LIB" ]; then
    announce_off "OWNED-STATE GATE IS OFF: scripts/lib/owned-systems.py is missing at $LIB, so its entire predicate is absent. Teammate dispatches are UNGATED — a clean run and an absent gate must never look the same."
    exit 0
fi

# --- UNEVALUATED-PAYLOAD NOTICE --------------------------------------------
# On a payload it cannot read, this guard would otherwise take the SAME silent
# exit 0 that a well-formed payload for a different tool takes. This separates
# the two. NO VERDICT CHANGES — only the silence.
_UE_LIB="$SCRIPT_DIR/../lib/unevaluated-notice.sh"
if [ -f "$_UE_LIB" ]; then
    # shellcheck source=../lib/unevaluated-notice.sh
    . "$_UE_LIB"
    unevaluated_or_continue "guard-owned-state.sh" "$INPUT" \
        "${ENTITY_ROOT:-${SEAT_ROOT:-${RICHOS_ENTITY_ROOT_RESOLVED:-}}}" \
        "whether a system whose health this orchestrator owns is standing unhealthy with nothing done about it this session"
fi

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
# NOT `[ ... ] && [ ... ] && exit 0`. Under `set -e` a trailing false test in an
# && chain is a non-zero return from the last command, which exits the hook
# with 1 — a code the host reads as a hook error rather than a pass.
if [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

# --- Parse the spawn -------------------------------------------------------
# Newlines survive through a \001 placeholder so the ack marker can be matched
# with a line-start anchor, exactly as the other Agent guards do it.
PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
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

if [ "$STATUS" = "PARSEFAIL" ]; then
    announce_off "OWNED-STATE GATE: this Agent spawn could not be parsed, so no owned system was checked and the 'owned-state-ack:' line could not be read either. This ONE dispatch is UNGATED."
    exit 0
fi

# --- IS ANYTHING DEMANDED OF THIS SESSION? ---------------------------------
# The predicate answers three things at once: is anything standing, has this
# session already disposed of something, and if not WHICH system is demanded.
# Cached inside the library, so the checks are run at most once per session.
DRC=0
DEMAND="$(python3 "$LIB" demanded --entity "$ENTITY_ROOT" --engine "$ENGINE_ROOT" \
            --session "$SESSION_ID" 2>/dev/null)" || DRC=$?

case "$DRC" in
    0) exit 0 ;;          # nothing standing, or this session already disposed
    1) ;;                 # a system is demanded
    *)
        announce_off "OWNED-STATE GATE IS OFF: the owned-systems declaration could not be read, so nothing is being watched and this dispatch is UNGATED. Run scripts/owned-state.sh to see the error in full."
        exit 0 ;;
esac

DEMANDED_ID="$(printf '%s' "$DEMAND" | python3 -c 'import json,sys; print(json.load(sys.stdin)["demanded"])' 2>/dev/null || true)"
if [ -z "$DEMANDED_ID" ]; then
    announce_off "OWNED-STATE GATE IS OFF: the predicate reported a standing system but named none, which is a defect in scripts/lib/owned-systems.py. This dispatch is UNGATED."
    exit 0
fi

# --- IS THIS DISPATCH ADDRESSING A STANDING SYSTEM? ------------------------
# Allowed, recorded, SILENT. Putting somebody on the problem is the answer this
# gate is asking for, and being lectured at that moment teaches the wrong
# lesson.
ADDRESSED="$(printf '%s' "$DEMAND" | PROMPT_TEXT="$PROMPT" python3 -c '
import json, os, re, sys
d = json.load(sys.stdin)
prompt = os.environ.get("PROMPT_TEXT", "")
# THE ACK LINE IS NOT PART OF THE PROMPT FOR THIS TEST, and the first version of
# this hook proved why: an ack reading `owned-state-ack: alpha - ...` contains
# the word `alpha`, matched alphas own match pattern, and was recorded as a
# dispatch ADDRESSING the system it was asking to defer. A malformed ack that
# should have been refused sailed through as work. An escape hatch that
# satisfies the gate merely by naming the system is not a hatch, it is a hole.
prompt = "\n".join(l for l in prompt.splitlines()
                   if not re.match(r"^\s*owned-state-ack:", l))
cands = [(d["demanded"], d.get("match", ""))]
for o in d.get("others", []):
    cands.append((o["id"], o.get("match", "")))
for sid, pattern in cands:
    if not pattern:
        continue
    try:
        if re.search(pattern, prompt, re.IGNORECASE):
            print(sid)
            break
    except re.error:
        continue
' 2>/dev/null || true)"

if [ -n "$ADDRESSED" ]; then
    python3 "$LIB" dispose --entity "$ENTITY_ROOT" --session "$SESSION_ID" \
        --system "$ADDRESSED" --how addressed --agent "${NAME:-${SUBAGENT_TYPE:-<unset>}}" \
        --reason "dispatch matched this system's declared match pattern" >/dev/null 2>&1 || true
    exit 0
fi

# --- THE ESCAPE HATCH, BEFORE THE VERDICT ----------------------------------
# ONE extraction, not a test followed by an extraction: two greps with the same
# pattern are two chances to relax one of them and not the other, and the
# resulting hook would test strictly, extract loosely, and behave in a way
# neither pattern describes.
ACK_LINE="$(printf '%s' "$PROMPT" \
    | grep -oE '^[[:space:]]*owned-state-ack:[[:space:]]*[^[:space:]].*' \
    | head -1 | sed -E 's/^[[:space:]]*//' || true)"

if [ -n "$ACK_LINE" ]; then
    # Parsed in python, not sed. The id is the FIRST WHITESPACE-DELIMITED TOKEN
    # with any trailing separator stripped, and the reason is everything after
    # it. A sed expression that split on the first `-` would have mangled every
    # future id with a hyphen in it, which is a defect that shows up only once
    # somebody adds one — the class of bug this project keeps finding in itself.
    ACK_PARSED="$(ACK_BODY="$ACK_LINE" python3 -c '
import os, re
body = re.sub(r"^\s*owned-state-ack:\s*", "", os.environ.get("ACK_BODY", ""))
parts = body.split(None, 1)
sid = re.sub(r"[—:;,\-]+$", "", parts[0]) if parts else ""
rest = parts[1] if len(parts) > 1 else ""
rest = re.sub(r"^[\s—:;,\-]+", "", rest)
print("%s\t%s" % (sid, rest.replace("\t", " ")))
' 2>/dev/null || printf '\t')"
    ACK_ID="$(printf '%s' "$ACK_PARSED" | cut -f1)"
    ACK_REASON="$(printf '%s' "$ACK_PARSED" | cut -f2-)"
    if [ "$ACK_ID" = "$DEMANDED_ID" ] && [ "${#ACK_REASON}" -ge 15 ]; then
        python3 "$LIB" dispose --entity "$ENTITY_ROOT" --session "$SESSION_ID" \
            --system "$DEMANDED_ID" --how ack --agent "${NAME:-${SUBAGENT_TYPE:-<unset>}}" \
            --reason "$ACK_REASON" >/dev/null 2>&1 || true
        exit 0
    fi
    ACK_PROBLEM="the ack names '${ACK_ID:-<nothing>}'"
    [ "$ACK_ID" = "$DEMANDED_ID" ] && ACK_PROBLEM="the ack names the right system but its reason is ${#ACK_REASON} characters, and a reason under 15 is a bare marker"
else
    ACK_PROBLEM=""
fi

# --- REFUSE ----------------------------------------------------------------
# NAMED, DATED AND QUOTED — never counted. "5 systems unhealthy" is the shape
# of sentence the founder read past on the morning this was ordered; the
# evidence line that decided it is the thing that gets acted on.
{
    printf '%s' "$DEMAND" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("=== A SYSTEM YOU OWN THE HEALTH OF IS %s AND NOTHING HAS BEEN DONE ABOUT IT THIS SESSION — REFUSING THIS DISPATCH ===" % d["status"])
print("")
print("  system   : %s — %s" % (d["demanded"], d["title"]))
print("  standing : %s" % d["age"])
print("  decided  : %s" % d.get("via", "?"))
print("  taken    : %s%s" % (d.get("taken", "?"), " (cached)" if d.get("from_cache") else ""))
print("")
print("  THE EVIDENCE, VERBATIM:")
for line in d.get("evidence", []) or ["(the check produced no output)"]:
    print("    %s" % line.strip())
if d.get("why"):
    print("")
    print("  why this is watched: %s" % d["why"])
others = d.get("others", [])
if others:
    print("")
    print("  Also standing, and NOT what this gate is asking about right now:")
    for o in others[:6]:
        print("    %-12s %-9s %s" % (o["id"], o["status"], o["age"]))
'
    echo ""
    echo "  On 2026-09-10 the founder found a workflow red for thirteen days, 30 GB"
    echo "  of unreclaimable worktrees and the engine's own hook text on his screen."
    echo "  The worktree state was ALREADY in that session's start-up notice and was"
    echo "  read past. Surfacing had already failed. So a known-bad state now costs"
    echo "  the one thing that changes behavior: getting on with something else."
    echo ""
    echo "  ONE of these, and this session is clear — all of it, not one per system:"
    echo ""
    echo "    1. DISPATCH SOMEBODY AT IT. A spawn whose prompt is about a standing"
    echo "       system is allowed, silently, and satisfies this gate. That is the"
    echo "       answer this is asking for."
    echo ""
    echo "    2. SAY IT CAN WAIT, ON THE RECORD. Add this line to the spawn prompt:"
    echo ""
    echo "         owned-state-ack: ${DEMANDED_ID} — <why this can wait>"
    echo ""
    echo "       It has to name ${DEMANDED_ID}, which is the OLDEST standing system —"
    echo "       naming a cheaper one is how a thirteen-day red survives thirteen"
    echo "       days. The reason needs 15 characters or more; a bare marker exempts"
    echo "       nothing. It is logged to .claude/state/owned-state-acks.log, which"
    echo "       notice-waiver-repetition.py reads, so the same excuse repeated"
    echo "       session after session gets named."
    if [ -n "$ACK_PROBLEM" ]; then
        echo ""
        echo "  THIS PROMPT CARRIES AN ACK AND IT DOES NOT COUNT: ${ACK_PROBLEM}."
        echo "  The demanded system is '${DEMANDED_ID}'."
    fi
    echo ""
    echo "  Full report, every system including the healthy ones:"
    echo "    ${ENGINE_ROOT}/scripts/owned-state.sh ${ENTITY_ROOT}"
    echo "(hook: scripts/hooks/guard-owned-state.sh)"
} >&2
exit 2
