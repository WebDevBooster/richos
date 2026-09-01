#!/usr/bin/env bash
#
# guard-ceo-ruled-ask.sh — BLOCKING PreToolUse guard on the AskUserQuestion tool.
#
# REFUSES TO PUT A QUESTION TO THE CEO WHOSE SUBJECT THE RECORD HAS ALREADY
# RULED — AND NAMES THE RULING.
#
# The predicate, the corpus measurement, the fail-open argument and the escape
# hatch all live in scripts/lib/ceo-ruled.sh and NOWHERE ELSE. Read that first;
# this file is the wiring and the refusal.
#
# ===========================================================================
# THE FAILURE
# ===========================================================================
# 2026-09-01. Three times in one evening the orchestrator asked the CEO
# something the record already answered, and each answer had been written down
# by the orchestrator itself hours or days earlier: what a customer installs
# (his standing instruction, open-items.md row 3.14, "automatically download
# and install whatever the user needs"); whether the logo carries one tone or
# two (approved, §21); and the splash screens, where a palette approval had
# been laundered into "seven approved splash screens" and repeated back to him
# as fact.
#
# His words on the first: "HOW MANY TIMES DO I HAVE TO DISCUSS AND ANSWER THE
# SAME IDENTICAL SHIT???"
#
# THE MECHANISM: the orchestrator WRITES to the record constantly and READS it
# almost never. Nothing stood between "this looks like a decision" and "ask
# him". This hook is that step, and it is the only one.
#
# ===========================================================================
# THIS IS THE SIBLING OF guard-ceo-ask-first.sh, ASKING THE OPPOSITE QUESTION
# ===========================================================================
# That guard refuses to DISPATCH work while a prepared decision has never been
# put to him. This one refuses to PUT a question to him he has already
# answered. Same record, same tokenizer (ceo-ruled.py loads ceo-asks.py's), one
# declaration of where his record lives (ca_resolve). Two failures, one surface.
#
# ===========================================================================
# WHY PreToolUse ON AskUserQuestion, AND WHAT THAT DOES NOT COVER
# ===========================================================================
# PreToolUse is the only event that fires BEFORE the CEO sees anything, which
# is the only place a question can be stopped rather than regretted.
#
# BUT — AND THIS IS THE HONEST HALF — TWO OF THE THREE FAILURES ABOVE WERE
# PROSE, NOT AskUserQuestion CALLS. Verified against the session transcripts on
# this machine: the Option D question and the logo question were sentences in a
# reply. There is no PreToolUse event for a sentence, and no hook can block
# one. scripts/hooks/notice-ceo-ruled-prose.sh reports those at the END of the
# turn, which is after he has read them, and that is stated rather than papered
# over: this gate hardens the structured ask, and the notice is the only reach
# the prose ask has at all.
#
# ===========================================================================
# THE ATTRIBUTION GATE
# ===========================================================================
# A call carrying an `agent_id` came from a WORKER. A teammate asking its own
# clarifying question is not the orchestrator re-litigating a ruling, and
# refusing it would spend this gate's whole false-positive budget on the case
# it was not built for. Worker calls pass, silently — the same line
# notice-ceo-asks.sh draws on the same tool.
#
# ===========================================================================
# FAIL OPEN, ALWAYS
# ===========================================================================
# A gate that can wedge the orchestrator's ability to ask the CEO ANYTHING is
# worse than the failure it prevents. Every plumbing failure lets the ask
# through and says so on both channels available. The only refusal is the one
# where the predicate ran, read a real record, and can name and quote a ruling.
#
# NOTE ON THE LOUD CHANNEL. The `systemMessage` field is proven for Stop hooks
# and only for Stop hooks (scripts/lib/stop-hook-notice.sh carries the
# measurement); whether it reaches the operator from PreToolUse is UNVERIFIED.
# So a broken state is announced on stderr AND as a systemMessage here, and
# notice-ceo-ruled-prose.sh repeats it at the end of every turn through the
# channel that IS measured.
#
# NOTE: hooks are snapshotted at session start. This one is INERT until the
# next session — it assumes nothing about being live in the session that adds it.

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
        echo "  hook: scripts/hooks/guard-ceo-ruled-ask.sh"
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
    announce_broken "CEO-RULED GATE IS OFF: it cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is checking whether this question has already been answered on the record."
    exit 0
fi
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"

_CR_LIB="$SCRIPT_DIR/../lib/ceo-ruled.sh"
if [ ! -f "$_CR_LIB" ]; then
    announce_broken "CEO-RULED GATE IS OFF: scripts/lib/ceo-ruled.sh is missing at $_CR_LIB, so its entire predicate is absent. Questions to the CEO are UNCHECKED against his record — a clean run and an absent gate must never look the same."
    exit 0
fi
# shellcheck source=../lib/ceo-ruled.sh
. "$_CR_LIB"

if ! cr_require; then
    announce_broken "CEO-RULED GATE IS OFF: $CR_BROKEN. Questions to the CEO are UNCHECKED against his record."
    exit 0
fi

RRC=0
cr_resolve "$ENTITY_ROOT" || RRC=$?
case "$RRC" in
    0) ;;
    1) exit 0 ;;    # NOT-DECLARED: no CEO record here, stand down silently
    *)
        announce_broken "CEO-RULED GATE IS OFF: this repository declares a CEO record and it cannot be read — ${CR_REASON}. Questions are UNCHECKED, and a declared-but-unreadable record is not an empty one."
        exit 0 ;;
esac

# --- Parse the call --------------------------------------------------------
META="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("tool_name") not in (None, "", "AskUserQuestion"):
        raise ValueError("not an AskUserQuestion call")
    print("OK\t%s\t%s" % (str(d.get("session_id", "") or ""),
                          str(d.get("agent_id", "") or "")))
except Exception:
    print("PARSEFAIL\t\t")
' 2>/dev/null || printf 'PARSEFAIL\t\t')"

STATUS="$(printf '%s' "$META" | cut -f1)"
SESSION_ID="$(printf '%s' "$META" | cut -f2)"
AGENT_ID="$(printf '%s' "$META" | cut -f3)"

# An unparseable payload is NOT blocked, and the choice is deliberate rather
# than left as an inconsistency to be discovered. guard-worktree-isolation.sh
# fails CLOSED on an unparseable spawn because an unparseable spawn could BE
# the violation it exists to catch. Here the subject of the check is the
# question TEXT: with no text there is nothing to compare against the record,
# and refusing on that would block a question nobody could then permit.
if [ "$STATUS" = "PARSEFAIL" ]; then
    announce_broken "CEO-RULED GATE: could not parse this AskUserQuestion call, so it was not checked against the CEO's record. This ONE question is ungated."
    exit 0
fi

# A worker's own clarifying question is not the orchestrator re-asking a ruling.
[ -z "$AGENT_ID" ] || exit 0

QLIST="$(cr_questions_of "$INPUT")"
[ -n "$QLIST" ] || exit 0

cr_exempts "$ENTITY_ROOT" "$SESSION_ID"

QFILE="$(mktemp -t ceo-ruled-q.XXXXXX)" || exit 0
OUTFILE="$(mktemp -t ceo-ruled-out.XXXXXX)" || { rm -f "$QFILE"; exit 0; }
REPORT="$(mktemp -t ceo-ruled-report.XXXXXX)" || { rm -f "$QFILE" "$OUTFILE"; exit 0; }
trap 'rm -f "$QFILE" "$OUTFILE" "$REPORT"' EXIT

BLOCKED=0
BROKEN_NOTE=""

while IFS=$'\t' read -r QIDX QTEXT; do
    [ -n "${QTEXT:-}" ] || continue
    printf '%s' "$QTEXT" | tr '\001' '\n' > "$QFILE"
    if ! cr_check "$QFILE" > "$OUTFILE" 2>/dev/null; then
        BROKEN_NOTE="${CR_BROKEN:-the predicate could not run}"
        continue
    fi
    if grep -q '^PROBLEM	' "$OUTFILE"; then
        BROKEN_NOTE="a declared record could not be parsed: $(grep -m1 '^PROBLEM	' "$OUTFILE" | cut -f2-)"
    fi
    case "$(grep -m1 '^VERDICT	' "$OUTFILE" | cut -f2)" in
        RULED)
            BLOCKED=1
            {
                printf '  QUESTION %s\n' "$((QIDX + 1))"
                # NAMED AND QUOTED, NEVER COUNTED. "already decided" sends the
                # reader hunting through 1,400 lines; a section number, a title
                # and the CEO's own sentence is something he can answer FROM.
                while IFS=$'\t' read -r K F1 F2 F3 F4 F5 F6 F7 F8; do
                    case "$K" in
                        RULED)
                            printf '    %s  %s\n' "$F2" "$F3"
                            printf '      in %s, line %s   (matched: %s "%s")\n' \
                                "$F1" "$F8" "$F4" "$F5"
                            ;;
                        QUOTE)
                            printf '      > %s\n' "$F2"
                            ;;
                    esac
                done < "$OUTFILE"
                printf '\n'
            } >> "$REPORT"
            ;;
    esac
done <<QLIST_EOF
$QLIST
QLIST_EOF

if [ -n "$BROKEN_NOTE" ] && [ "$BLOCKED" -eq 0 ]; then
    announce_broken "CEO-RULED GATE IS DEGRADED: $BROKEN_NOTE. This question was not fully checked against the CEO's record."
fi

[ "$BLOCKED" -eq 1 ] || exit 0

# --- REFUSE ----------------------------------------------------------------
{
    echo "=== THE RECORD HAS ALREADY RULED ON THIS — REFUSING TO ASK HIM AGAIN ==="
    echo ""
    echo "  On 2026-09-01 three questions went to the CEO that the record"
    echo "  already answered, each one written down by this session's own"
    echo "  orchestrator hours or days earlier. His words: \"HOW MANY TIMES DO"
    echo "  I HAVE TO DISCUSS AND ANSWER THE SAME IDENTICAL SHIT???\""
    echo ""
    echo "  WHAT THE RECORD SAYS:"
    echo ""
    cat "$REPORT"
    echo "  ANSWER HIM FROM THIS, do not ask. Open the file at the line above"
    echo "  and read the ruling in full before deciding it does not apply."
    echo ""
    echo "  IF A RULING GENUINELY DOES NOT COVER THIS QUESTION, say which one"
    echo "  and why — on the record, where a reviewer sees it:"
    echo ""
    printf '    %s/scripts/ceo-ruled-exempt.sh %s "<cite>" "<why it does not cover this>"\n' \
        "$ENGINE_ROOT" "${SESSION_ID:-<session-id>}"
    echo ""
    echo "  A BARE MARKER EXEMPTS NOTHING — the reason is required and is"
    echo "  length-checked. Half the point is that you looked at the ruling."
    echo "  It is logged to .claude/state/$CR_EXEMPT_LOG_NAME, per session,"
    echo "  per citation, and it does not carry into the next session."
    echo "(hook: scripts/hooks/guard-ceo-ruled-ask.sh)"
} >&2
exit 2
