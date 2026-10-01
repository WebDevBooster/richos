#!/usr/bin/env bash
#
# scripts/blocking-ask-exempt.sh — DECLARE that a question to the CEO has to
# block the lead's turn (AskUserQuestion) although teammates are working.
#
#     scripts/blocking-ask-exempt.sh <session-id> "<why this question has to block>"
#
# ===========================================================================
# WHY A DECLARATION
# ===========================================================================
# guard-ceo-ruled-ask.sh's deaf-lead check refuses an AskUserQuestion while a
# teammate of this session is live: on 2026-10-01 one held the lead's turn open
# for 37 minutes and every result queued behind it. The question goes as the
# turn's final message instead (scripts/lib/blocking_ask.py has every reason).
#
# A gate with no way through is a gate that gets switched off, so there is one,
# in the shape ceo-ruled-exempt.sh uses on this same tool: a reason, written
# where a reviewer sees it. Not a marker line inside the question: the only text
# an AskUserQuestion carries is what the CEO reads.
#
# A BARE MARKER EXEMPTS NOTHING: the reason is required and at least 20
# characters. SCOPE: the session it names, and nothing after it.
#
# THE LEDGER
#     <entity root>/.claude/state/blocking-ask-exempts.log
# One tab-separated line per declaration, beside ceo-ruled-exempts.log.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_REASON=20

usage() {
    cat >&2 <<'USAGE'
usage: blocking-ask-exempt.sh <session-id> "<why this question has to block>"

  <session-id>  the session the declaration applies to (the refusal prints it)
  <reason>      why this one question cannot go as your turn's final message.
                At least 20 characters, and a reviewer will read it.
USAGE
}

SESSION_ID="${1:-}"
REASON="${2:-}"
if [ -z "$SESSION_ID" ] || [ -z "$REASON" ]; then
    usage
    exit 2
fi

_RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    echo "ERROR: scripts/lib/resolve-roots.sh is missing: cannot tell which repository this declaration belongs to" >&2
    exit 2
fi
# shellcheck source=lib/resolve-roots.sh
. "$_RR_LIB"
if ! resolve_entity_root '{}'; then
    echo "ERROR: could not resolve the governed repository (${RICHOS_ROOT_REASON:-root resolution failed})." >&2
    exit 2
fi
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"

REASON_ONE_LINE="$(printf '%s' "$REASON" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')"
if [ "${#REASON_ONE_LINE}" -lt "$MIN_REASON" ]; then
    echo "REFUSED: the reason is ${#REASON_ONE_LINE} characters and at least $MIN_REASON are required." >&2
    echo "         A bare marker exempts nothing. Say why this question has to block." >&2
    exit 2
fi

LOG_DIR="$ENTITY_ROOT/.claude/state"
mkdir -p "$LOG_DIR" 2>/dev/null || { echo "ERROR: could not create $LOG_DIR" >&2; exit 2; }
LOG="$LOG_DIR/blocking-ask-exempts.log"
printf '%s\tsession=%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" "$REASON_ONE_LINE" >> "$LOG"

echo "Recorded: AskUserQuestion may block in session $SESSION_ID."
echo "  $LOG"
echo "It does not carry into the next session."
