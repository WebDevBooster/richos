#!/usr/bin/env bash
#
# stop.sh — STOPPING THE TEAMMATES THE CEO NAMED IS ONE COMMAND.
#
#   stop.sh <name> [<name> ...] --ceo-word '<his sentence, verbatim>' [--dry-run]
#
# It takes NAMES. It has no "everything" mode and it never will:
#
#     "WHEN THE FUCK DID I SAY THAT 'EVERYTHING RUNNING' NEEDS TO STOP???"
#                                        — the CEO, 2026-09-20 05:15Z
#
# For each name it reads the workspace registry and the one liveness resolver,
# measures what would be destroyed (commits past the ref its work integrates on,
# uncommitted paths), writes the `stop-work-ack.sh` line the TaskStop guard asks
# for, VERIFIES that line is findable by the guard's own reader, and prints the
# exact TaskStop call to make plus the registry commands to run afterwards.
#
# A name that is not provably running is reported and SKIPPED, never guessed at
# and never widened into a neighbor.
#
# WHY IT EXISTS — 2026-09-20, ceo-decisions §67. He objected to three agents'
# spend; the TaskStop on each was refused for want of an ack that takes seconds
# to write; Rich sent "commit and hold" messages instead, which stop nothing,
# and the CEO killed all three from his own screen. "In the 'same minute'? or in
# the same second?" This command is the answer to the second question, and the
# paragraph above is the answer to what happened forty minutes later when a
# fourth agent was stopped on an inference.
#
# IT DOES NOT CALL TaskStop. No script can: the tool belongs to the assistant's
# harness. It leaves that one call with nothing left to decide.
#
# The mechanism, the exit codes, and the measurement behind the two ack
# spellings are in scripts/lib/stop.py. This file finds python3, resolves the
# two roots, and gets out of the way.
#
# Exit: 0 every name decided (acked, or skipped as not running)
#       1 something could not be decided — the ack is still written, stop anyway
#       2 usage: no names, or no --ceo-word

set -uo pipefail

TAG="(<engine>/scripts/stop.sh)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { printf '%s\n' "$*" >&2; }

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 2 ;;
    esac
done

command -v python3 >/dev/null 2>&1 || {
    err "REFUSED: python3 is required. $TAG"; exit 2; }
command -v git >/dev/null 2>&1 || {
    err "REFUSED: git is required to read what would be destroyed. $TAG"; exit 2; }

LIB="$SCRIPT_DIR/lib/stop.py"
[ -f "$LIB" ] || { err "REFUSED: $LIB is missing; this file decides nothing itself. $TAG"; exit 2; }

# --- ROOT RESOLUTION -------------------------------------------------------
# The ack is written into the GOVERNED REPOSITORY's .claude/state, because that
# is where guard-stop-live-work.sh reads it from. Under a by-reference engine
# this script's own location is the ENGINE, which is usually not that
# repository — so it is resolved, never assumed. --entity overrides.
ENTITY="${RICHOS_STOP_ENTITY:-}"
ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --entity) ENTITY="${2:-}"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

if [ -z "$ENTITY" ]; then
    _RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
    if [ -f "$_RR_LIB" ]; then
        # shellcheck source=lib/resolve-roots.sh
        . "$_RR_LIB"
        if resolve_entity_root ""; then
            ENTITY="$RICHOS_ENTITY_ROOT_RESOLVED"
        fi
    fi
fi
if [ -z "$ENTITY" ]; then
    ENTITY="${CLAUDE_PROJECT_DIR:-$PWD}"
    err "NOTE: the governed repository could not be resolved; falling back to $ENTITY. If the"
    err "      ack lands somewhere the guard does not read, pass --entity <the main checkout>. $TAG"
fi

ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The session transcript, when the host names it, lets a teammate with no
# recorded agent id still be joined to one. Optional by construction: its
# absence costs an INDETERMINATE, never a refusal.
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-}"

exec python3 "$LIB" \
    --entity "$ENTITY" \
    --engine "$ENGINE_ROOT" \
    --session "${CLAUDE_SESSION_ID:-}" \
    --transcript "$TRANSCRIPT" \
    ${ARGS[@]+"${ARGS[@]}"}
