#!/usr/bin/env bash
#
# ceo-asks-status.sh — what the CEO-ask gate can see, and what it would do.
#
# The predicate, its rationale and everything it cannot catch live in
# scripts/lib/ceo-asks.sh. This is its command-line face: the answer to "why did
# it block me / why is it not blocking anything?" that a person can run in one
# line and get the SAME verdict the hooks get, because it is the same code.
#
#   scripts/ceo-asks-status.sh                 # the repository you are in
#   scripts/ceo-asks-status.sh /path/to/repo   # a specific governed repository
#   scripts/ceo-asks-status.sh --session <id>  # as of one session's ledger
#
# Without --session it reports what is PREPARED, with nothing discharged — the
# state of a session that has just opened.
#
# EXIT CODES, and the third exists so "nothing to ask" and "cannot tell" are
# never the same signal:
#
#   0  nothing prepared, or every prepared item has been put to him
#   1  OPEN — a prepared item has not been put to him in this session
#   2  BROKEN or NOT-DECLARED: no verdict was reached

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/ceo-asks.sh"

TARGET=""
SESSION=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session) SESSION="${2:-}"; shift ;;
        --session=*) SESSION="${1#--session=}" ;;
        -h|--help)
            sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            echo "ERROR: ceo-asks-status.sh: unrecognized argument '$1'" >&2
            exit 2 ;;
        *)
            [ -z "$TARGET" ] || { echo "ERROR: ceo-asks-status.sh: one target only" >&2; exit 2; }
            TARGET="$1" ;;
    esac
    shift
done
[ -n "$TARGET" ] || TARGET="$PWD"

[ -f "$LIB" ] || {
    echo "ERROR: ceo-asks-status.sh: scripts/lib/ceo-asks.sh is missing at $LIB — the entire predicate lives there and this script will not guess." >&2
    exit 2
}
# shellcheck source=lib/ceo-asks.sh
. "$LIB"

ca_require || { echo "ERROR: ceo-asks-status.sh: $CA_BROKEN" >&2; exit 2; }

ROOT="$(cd "$TARGET" 2>/dev/null && pwd -P)" || {
    echo "ERROR: ceo-asks-status.sh: '$TARGET' is not a directory." >&2
    exit 2
}

RRC=0
ca_resolve "$ROOT" || RRC=$?
case "$RRC" in
    0) ;;
    1)
        echo "=== CEO-ASK GATE: NOT DECLARED HERE ==="
        echo "  repository : $ROOT"
        echo "  $CA_REASON"
        echo ""
        echo "  This is a STAND-DOWN, not a pass. To put a list under the gate,"
        echo "  add to $ROOT/orchestration.config:"
        echo "      $CA_REPOS_KEY=\"../the-repo-that-carries-.ceo-todos\""
        exit 2 ;;
    *)
        echo "=== CEO-ASK GATE: DECLARED AND UNREADABLE — THE GATE IS OFF ==="
        echo "  repository : $ROOT"
        echo "  $CA_REASON"
        echo ""
        echo "  Teammate dispatches are UNGATED while this is true. A"
        echo "  declared-but-unreadable list is not an empty one."
        exit 2 ;;
esac

. "$SCRIPT_DIR/lib/owned-work-policy.sh"
OWNED_POLICY=0
if owned_work_policy "$ROOT"; then OWNED_POLICY=1; fi
ARC=0
if [ "$OWNED_POLICY" -eq 1 ]; then
    ca_assess "$ROOT" "" || ARC=$?
else
    ca_assess "$ROOT" "$SESSION" || ARC=$?
fi
if [ "$ARC" -ge 2 ]; then
    echo "=== CEO-ASK GATE: BROKEN ==="
    echo "  ${CA_BROKEN:-the predicate could not run}"
    exit 2
fi

if [ "$OWNED_POLICY" -eq 1 ]; then
    if [ "${CA_PREPARED:-0}" -gt 0 ]; then
        echo "CEO DECISIONS PENDING / OPEN: independent authorized work may proceed."
        echo "Only dependent deliverables wait. An ask receipt is not a CEO answer."
        printf '%s\n' "$CA_ASK_LINES"
        exit 1
    fi
    echo "No prepared CEO decisions are pending. This status grants no new authority."
    exit 0
fi

echo "=== CEO-ASK GATE ==="
echo "  repository : $ROOT"
printf '  lists     :'
printf '%s\n' "$CA_REPOS" | sed '/^$/d' | sed 's/^/ /' | tr -d '\n'
echo ""
echo "  session    : ${SESSION:-<none given — reporting as a session that has just opened>}"
echo "  prepared   : ${CA_PREPARED:-0}"
echo "  asked      : ${CA_ASKED:-0}"
echo "  unasked    : ${CA_UNASKED:-0}"
echo "  verdict    : ${CA_VERDICT:-?}"
if [ "${CA_UNASKED:-0}" -gt 0 ]; then
    echo ""
    echo "  OPEN/exit 1 is a policy state, not a failed command."
    echo "  If the CEO directed independent work to continue, add this truthful per-spawn line:"
    echo "    ceo-todos-deferred: <reason from the CEO's instruction>"
    echo "  This leaves the question pending and records no answer. It grants no other guard exemption."
    echo ""
    echo "  NOT PUT TO HIM${SESSION:+ IN SESSION $SESSION} — ask ONE of these with AskUserQuestion:"
    echo ""
    printf '%s\n' "$CA_ASK_LINES" | awk -F'\t' 'NF>1 {printf "    %s  %s\n         %s\n\n", $2, $3, $4}'
fi
[ "$ARC" -eq 1 ] && exit 1
exit 0
