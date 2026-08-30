#!/usr/bin/env bash
#
# turn-manifest.sh — NON-BLOCKING Stop hook. It prints, at the end of every
# turn, the tool calls that turn made and THE STATUS EACH ONE ACTUALLY
# RETURNED — generated from the results, never written by the assistant.
#
# WHY IT EXISTS
#   The orchestrator's recurring failure is reporting the strongest reading of
#   a narrow result: "Message queued for delivery at its next tool round"
#   reported as "I've told him"; no tool call at all reported as "dispatching
#   it rather than queuing it"; one glob matching 18 files reported as "18/18
#   suites". Every one of those was caught by the CEO reading the reply, which
#   makes him the detection mechanism for the orchestrator's own claims. That
#   is the last unmechanized failure class he has actually been hit by, and it
#   has to fire without him.
#
# WHY IT IS NOT A DETECTOR — the design is the point
#   Nothing here reads the assistant's prose, scores it, or decides whether a
#   sentence overstates. There is no threshold and no interpretation, so the
#   false-positive rate is ZERO BY CONSTRUCTION. It does not CATCH an
#   overstatement; it makes one UNSUSTAINABLE, because the true status is
#   printed directly beneath the claim. Unrepresentable rather than
#   detectable.
#
#   Judging the prose is a real job with a real owner: guard-unresolved-
#   claims.sh, which measured its own precision (17% for the prose signal —
#   report-only; 0 false positives on 262 SHA citations — blocking) before it
#   was allowed near a verdict. If a future edit to THIS file starts asking
#   whether a claim was fair, the edit belongs in that one instead.
#
# IT NEVER BLOCKS. Every path exits 0. A manifest that can refuse a turn needs
#   an opinion about which turns deserve refusing — which is the prose
#   judgment this hook exists to avoid.
#
# WHERE THE TEXT GOES — established by running it, not by assuming
#   A Stop hook reaches the OPERATOR by writing {"systemMessage": "..."} to
#   stdout and exiting 0. Verified against the shipping binary 2.1.251 both
#   statically (the command-hook runner lifts `systemMessage` out of the
#   hook's parsed stdout and the consumer yields a `hook_system_message`
#   tagged with the event; the binary's own bundled docs name the pattern
#   under "Stop hook that displays message to user") and LIVE (a headless run
#   with one such Stop hook produced
#   {"type":"system","subtype":"informational","content":"Stop says: …"} after
#   the assistant's final text). Multi-line survives; the host prefixes EVERY
#   line with "Stop says: ", which is why the rows are kept narrow.
#   engine-status.sh already reaches the operator this same way.
#
# FAIL OPEN, like every Stop hook here, for the reason in the sibling's
#   header: a Stop guard that fails CLOSED refuses to let the SESSION END and
#   re-fires until the binary's block cap gives up while the operator watches
#   a wedged session. A missing resolver, an unadopted repo, an absent
#   python3, an unreadable transcript — all end the turn.
#
#   The one thing it will not do quietly is DEGRADE. "Could not build the
#   manifest" is rendered as an explicit UNAVAILABLE notice, because silence
#   is indistinguishable from "this turn ran no tools", and those two facts
#   must never look alike.
#
# WHEN IT TAKES EFFECT
#   Hooks snapshot at session start. Installing this changes nothing in the
#   session that installs it; it begins rendering in the NEXT session.
#
# Exit code: 0, always.
#
# Self-test:  scripts/hooks/turn-manifest.sh --self-test

set -eo pipefail

HOOK_TAG="(hook: scripts/hooks/turn-manifest.sh)"

# --- self-test dispatch ---------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/turn-manifest.test.sh"
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
        echo "  hook: scripts/hooks/turn-manifest.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defence"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

# Resolve the governed repository. All three outcomes end the turn.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    root_failure_banner "scripts/hooks/turn-manifest.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${SHOW_TURN_MANIFEST:=1}"

# A stand-down is ANNOUNCED THROUGH THE SAME CHANNEL the manifest uses, never
# on stderr. MEASURED, not assumed: a Stop hook exiting 0 that wrote a unique
# marker to stderr AND a second one to plain stdout produced neither in the
# session stream. Both were filed into the transcript as a `hook_success`
# attachment — readable in transcript view, invisible in the scroll the
# operator is actually looking at. Only `systemMessage` reaches that scroll.
# So a stderr notice here would be an opt-out nobody can see: a defence that
# decays into a rumour, which is the failure the sibling guards warn about in
# words and this one would have committed in silence.
if [ "$SHOW_TURN_MANIFEST" = "0" ]; then
    printf '%s\n' "{\"suppressOutput\":true,\"systemMessage\":\"TURN MANIFEST — STOOD DOWN by SHOW_TURN_MANIFEST=0 in $CONFIG. This turn's tool statuses were not rendered. $HOOK_TAG\"}"
    exit 0
fi

# python3 is the renderer's only dependency. Absent, the turn ends — but the
# operator is told, because a manifest that is silently absent looks exactly
# like a turn that ran no tools.
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "{\"suppressOutput\":true,\"systemMessage\":\"TURN MANIFEST — UNAVAILABLE: python3 is not on PATH, so this turn's tool statuses could not be rendered. This is a GAP IN THE RECORD, not a turn that ran nothing. $HOOK_TAG\"}"
    exit 0
fi

RENDERER="$SCRIPT_DIR/turn-manifest.py"
if [ ! -f "$RENDERER" ]; then
    printf '%s\n' "{\"suppressOutput\":true,\"systemMessage\":\"TURN MANIFEST — UNAVAILABLE: the renderer is missing at $RENDERER. This is a GAP IN THE RECORD, not a turn that ran nothing. $HOOK_TAG\"}"
    exit 0
fi

# Never let a crash in the renderer wedge turn-end, and never let a partial
# write reach the host as malformed JSON: the output is buffered, and emitted
# only if python exited cleanly.
set +e
OUT="$(printf '%s' "$INPUT" | RICHOS_MANIFEST_ENTITY_ROOT="$ENTITY_ROOT" \
    python3 "$RENDERER" 2>/dev/null)"
RC=$?
set -e

if [ "$RC" = "0" ] && [ -n "$OUT" ]; then
    printf '%s\n' "$OUT"
fi
exit 0
