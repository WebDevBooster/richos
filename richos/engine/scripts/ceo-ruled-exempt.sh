#!/usr/bin/env bash
#
# scripts/ceo-ruled-exempt.sh — DECLARE that a named ruling does not cover the
# question you are about to put to the CEO.
#
#     scripts/ceo-ruled-exempt.sh <session-id> "<cite>" "<why it does not cover this>"
#
# ===========================================================================
# WHY THIS IS A DECLARATION AND NOT A FLAG
# ===========================================================================
# guard-ceo-ruled-ask.sh refuses a question whose subject the CEO's record has
# already ruled, and names the ruling. That gate is narrow — 1 false positive
# in 27 real questions — but "narrow" is not "never", and a gate with no way
# through is a gate that gets switched off.
#
# So there is a way through, and it is the shape `dialect-exempt:` uses: you
# say WHICH ruling you believe does not cover this and WHY, and it is written
# where a reviewer will see it. A BARE MARKER EXEMPTS NOTHING — the reason is
# required and length-checked, because a bare token is something a reflex types
# and a reason is something a person writes.
#
# HALF THE VALUE IS THE LOOKING. The failure this whole mechanism exists for is
# an orchestrator that writes to the record constantly and reads it almost
# never. Being made to name a section and say what it does not cover is the
# reading step, whether or not anybody ever audits the log.
#
# ===========================================================================
# SCOPE — per session, per citation, and it does not accumulate
# ===========================================================================
# An exemption clears exactly one citation for exactly one session. It is not a
# permanent waiver and it does not carry into tomorrow, because the failure
# being engineered out is a HABIT, and a habit is exactly what a permanent
# waiver would encode.
#
# ===========================================================================
# THE LEDGER
# ===========================================================================
#     <entity root>/.claude/state/ceo-ruled-exempts.log
#
# One tab-separated line per declaration, beside main-checkout-runs.log,
# resume-acks.log and ceo-todos-defers.log — the other opt-out ledgers, in the
# one place every hook that resolves this root already looks.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'USAGE'
usage: ceo-ruled-exempt.sh <session-id> "<cite>" "<why it does not cover this>"

  <session-id>  the session the exemption applies to (the refusal prints it)
  <cite>        the ruling, exactly as the refusal named it, e.g. "§14",
                "§21 › The logo", "row 3.14", "CLAUDE.md § Contrast"
  <reason>      what the ruling actually covers, and why this question is not
                that. At least 20 characters, and a reviewer will read it.

example:
  ceo-ruled-exempt.sh 374e6f14 "§14" \
    "§14 rules the dark palette and page elements; this asks how many tones the
     mark itself carries, which §14 never addresses."
USAGE
}

SESSION_ID="${1:-}"
CITE="${2:-}"
REASON="${3:-}"

if [ -z "$SESSION_ID" ] || [ -z "$CITE" ] || [ -z "$REASON" ]; then
    usage
    exit 2
fi

_RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    echo "ERROR: scripts/lib/resolve-roots.sh is missing — cannot tell which repository this exemption belongs to" >&2
    exit 2
fi
# shellcheck source=lib/resolve-roots.sh
. "$_RR_LIB"

_CR_LIB="$SCRIPT_DIR/lib/ceo-ruled.sh"
if [ ! -f "$_CR_LIB" ]; then
    echo "ERROR: scripts/lib/ceo-ruled.sh is missing — the ledger's name and the minimum reason live there" >&2
    exit 2
fi
# shellcheck source=lib/ceo-ruled.sh
. "$_CR_LIB"

if ! resolve_entity_root '{}'; then
    echo "ERROR: could not resolve the governed repository (${RICHOS_ROOT_REASON:-root resolution failed})." >&2
    echo "       Run this from inside the repository whose CEO record the gate cited." >&2
    exit 2
fi
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"

# The reason gate. A bare token is not a reason, and the refusal it clears is
# not a formality — so this rejects rather than warns.
REASON_ONE_LINE="$(printf '%s' "$REASON" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')"
if [ "${#REASON_ONE_LINE}" -lt "$CR_MIN_REASON" ]; then
    echo "REFUSED: the reason is ${#REASON_ONE_LINE} characters and at least $CR_MIN_REASON are required." >&2
    echo "         A bare marker exempts nothing. Say what '$CITE' actually covers" >&2
    echo "         and why this question is not that." >&2
    exit 2
fi

LOG_DIR="$ENTITY_ROOT/.claude/state"
mkdir -p "$LOG_DIR" 2>/dev/null || {
    echo "ERROR: could not create $LOG_DIR" >&2; exit 2; }
LOG="$LOG_DIR/$CR_EXEMPT_LOG_NAME"

printf '%s\tsession=%s\tcite=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$SESSION_ID" \
    "$CITE" \
    "$REASON_ONE_LINE" >> "$LOG"

echo "Recorded: '$CITE' declared not to cover this question, for session $SESSION_ID."
echo "  $LOG"
echo ""
echo "The gate will now let a question about that citation through in this"
echo "session only. It does not carry into the next one."
