#!/usr/bin/env bash
#
# unstarted-rows-lint.sh — run the unstarted-row sweep by hand, and SHOW ITS
#                          WORK.
#
# THE SAME CODE THE Stop HOOK RUNS. Not a second implementation, not a
# convenience approximation: scripts/lib/unstarted-rows.{sh,py}, called the
# same way, so "it is quiet at the turn end" and "it is quiet by hand" can
# never be two different answers.
#
# ===========================================================================
# THIS IS THE POSITIVE PROBE
# ===========================================================================
# The hook's ordinary output is SILENCE, and this project has twice shipped a
# mechanism whose silence meant it was not running: a scanner reporting CLEAN
# over an empty corpus, a runner reporting all-passed over a suite it never
# invoked. So the sweep is inspectable, always, and it prints EVERY row it
# looked at with the state it assigned — including the ones it decided to be
# quiet about, which are the ones a silence could otherwise be hiding.
#
# Usage:
#   scripts/unstarted-rows-lint.sh <repo>            the verdict and the rows
#   scripts/unstarted-rows-lint.sh <repo> --quiet    the verdict line only
#   scripts/unstarted-rows-lint.sh <repo> --receipt F  also write the receipt
#
# Exit codes:
#   0  every row is closed, claimed by a live worktree, or names its blocker
#   1  at least one unblocked row has nothing running for it (each is named)
#   2  broken: the records did not parse, or there is no contract here. NEVER
#      the same code as 0, because "nothing is unstarted" and "nothing was
#      read" are the two answers this whole mechanism exists to keep apart.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/unstarted-rows.sh"
[ -f "$LIB" ] || { echo "ERROR: unstarted-rows-lint.sh: scripts/lib/unstarted-rows.sh is missing at $LIB" >&2; exit 2; }
# shellcheck source=lib/unstarted-rows.sh
. "$LIB"

REPO=""
QUIET=0
RECEIPT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet)   QUIET=1; shift ;;
        --receipt) RECEIPT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "ERROR: unstarted-rows-lint.sh: unrecognized argument '$1'" >&2; exit 2 ;;
        *)         [ -n "$REPO" ] && { echo "ERROR: unstarted-rows-lint.sh: more than one repository given" >&2; exit 2; }
                   REPO="$1"; shift ;;
    esac
done
[ -n "$REPO" ] || { echo "ERROR: unstarted-rows-lint.sh: expected a repository path" >&2; exit 2; }
[ -d "$REPO" ] || { echo "ERROR: unstarted-rows-lint.sh: no such directory: $REPO" >&2; exit 2; }

RRC=0
ur_resolve "$REPO" || RRC=$?
case "$RRC" in
    0) ;;
    1)
        # NEVER a quiet pass. "Nothing to check" and "no contract here" are
        # different answers and a caller must be able to tell them apart.
        {
            echo "=== UNSTARTED ROWS: NO QUEUE IN THIS REPOSITORY ==="
            echo "  repository : $REPO"
            echo "  $UR_STANDDOWN_REASON"
            echo "  Nothing was swept. That is not a clean queue; it is no queue."
            echo "  See the engine's reference/unstarted-rows/ for the declaration."
        } >&2
        [ -n "$RECEIPT" ] && { UR_VERDICT="STOOD-DOWN"; ur_receipt "$RECEIPT"; }
        exit 2 ;;
    *)
        {
            echo "=== UNSTARTED ROWS: BROKEN — NOTHING WAS SWEPT ==="
            echo "  repository : $REPO"
            echo "  $UR_BROKEN_REASON"
        } >&2
        [ -n "$RECEIPT" ] && { UR_VERDICT="BROKEN"; ur_receipt "$RECEIPT"; }
        exit 2 ;;
esac

ur_collect_claims
ur_sweep
[ -n "$RECEIPT" ] && ur_receipt "$RECEIPT"

if [ "$UR_VERDICT" = "BROKEN" ]; then
    {
        echo "=== UNSTARTED ROWS: BROKEN — NOTHING WAS SWEPT ==="
        echo "  queue  : $UR_QUEUE_FILE"
        echo "  record : $UR_RECORD_FILE  (section(s) $UR_SECTIONS)"
        echo "  $UR_BROKEN_REASON"
        echo ""
        echo "  This is not an empty queue. It is an unread one, and the"
        echo "  difference is the only thing this check is for."
    } >&2
    exit 2
fi

echo "=== UNSTARTED ROWS ==="
echo "  queue      : $UR_QUEUE_FILE"
echo "  record     : $UR_RECORD_FILE  (section(s) $UR_SECTIONS)"
echo "  scan roots : $UR_SCAN_ROOTS"
echo "  swept $UR_N_ROWS row(s): $UR_N_UNSTARTED unstarted, $UR_N_CLAIMED claimed by a live worktree, $UR_N_DECLARED naming a blocker, $UR_N_CLOSED closed, $UR_N_OTHER other-token"

if [ "$QUIET" -eq 0 ]; then
    echo ""
    printf '%s\n' "$UR_ROWS" | awk -F'\t' 'NF>=4 {printf "  %-10s %-8s %-28s %s\n", $2, $3, $4, $5}'
fi

if [ "${UR_N_UNSTARTED:-0}" -gt 0 ]; then
    echo ""
    echo "  $UR_N_UNSTARTED row(s) are unblocked with nothing running for them: $UR_UNSTARTED"
    echo "  Start one, or say what it waits on — a \`Blocked by\` cell in $UR_QUEUE_LABEL,"
    echo "  or \`**Blocked:** <who>\` in a $UR_RECORD_LABEL row."
    exit 1
fi
exit 0
