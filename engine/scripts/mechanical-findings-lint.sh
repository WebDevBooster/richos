#!/usr/bin/env bash
#
# mechanical-findings-lint.sh — run the mechanical sweep by hand, and SHOW ITS
#                               WORK. With --write, do what the Stop hook does.
#
# THE SAME CODE THE Stop HOOK RUNS. Not a second implementation, not a
# convenience approximation: scripts/lib/mechanical-findings.{sh,py}, called
# the same way, so "it wrote nothing at the turn end" and "it writes nothing by
# hand" can never be two different answers.
#
# ===========================================================================
# THIS IS THE POSITIVE PROBE
# ===========================================================================
# The hook's ordinary output is SILENCE — every finding already has its row —
# and this engine has shipped more than one mechanism whose silence meant it
# was not running. So the sweep is inspectable, always: it prints every class
# with the number of subjects it examined, every finding with its state, and
# every row it wrote or refused to write. A silence with nothing behind it is
# visible here.
#
# Usage:
#   scripts/mechanical-findings-lint.sh <repo>            sweep and report; write nothing
#   scripts/mechanical-findings-lint.sh <repo> --write    sweep and APPEND rows for new findings
#   scripts/mechanical-findings-lint.sh <repo> --quiet    the verdict line only
#   scripts/mechanical-findings-lint.sh <repo> --receipt F  also write the receipt
#
# Exit codes:
#   0  clean: no finding, and no row describes a finding that is gone
#   1  at least one finding is NEW (unwritten), GONE (row outlives it), or
#      CLOSED-BUT-PRESENT; with --write, NEW rows were appended and are named
#   2  broken: the tree or the record could not be read, or there is no
#      contract here. NEVER the same code as 0.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/mechanical-findings.sh"
[ -f "$LIB" ] || { echo "ERROR: mechanical-findings-lint.sh: scripts/lib/mechanical-findings.sh is missing at $LIB" >&2; exit 2; }
# shellcheck source=lib/mechanical-findings.sh
. "$LIB"

REPO=""
QUIET=0
WRITE=""
RECEIPT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet)   QUIET=1; shift ;;
        --write)   WRITE="write"; shift ;;
        --receipt) RECEIPT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "ERROR: mechanical-findings-lint.sh: unrecognized argument '$1'" >&2; exit 2 ;;
        *)         [ -n "$REPO" ] && { echo "ERROR: mechanical-findings-lint.sh: more than one repository given" >&2; exit 2; }
                   REPO="$1"; shift ;;
    esac
done
[ -n "$REPO" ] || { echo "ERROR: mechanical-findings-lint.sh: expected a repository path" >&2; exit 2; }
[ -d "$REPO" ] || { echo "ERROR: mechanical-findings-lint.sh: no such directory: $REPO" >&2; exit 2; }

RRC=0
mf_resolve "$REPO" || RRC=$?
case "$RRC" in
    0) ;;
    1)
        {
            echo "=== MECHANICAL FINDINGS: NO RECORD FOR THIS REPOSITORY ==="
            echo "  repository : $REPO"
            echo "  $MF_STANDDOWN_REASON"
            echo "  Nothing was swept. That is not a clean tree; it is no contract."
        } >&2
        [ -n "$RECEIPT" ] && { MF_VERDICT="STOOD-DOWN"; mf_receipt "$RECEIPT"; }
        exit 2 ;;
    *)
        {
            echo "=== MECHANICAL FINDINGS: BROKEN — NOTHING WAS SWEPT ==="
            echo "  repository : $REPO"
            echo "  $MF_BROKEN_REASON"
        } >&2
        [ -n "$RECEIPT" ] && { MF_VERDICT="BROKEN"; mf_receipt "$RECEIPT"; }
        exit 2 ;;
esac

MF_HOOK_NAME="notice-mechanical-findings.sh"
mf_sweep "$WRITE"
[ -n "$RECEIPT" ] && mf_receipt "$RECEIPT"

if [ "$MF_VERDICT" = "BROKEN" ]; then
    {
        echo "=== MECHANICAL FINDINGS: BROKEN — NOTHING WAS SWEPT ==="
        echo "  record : $MF_RECORD_FILE  (section(s) $MF_SECTIONS)"
        echo "  roots  : $(printf '%s' "$MF_ROOTS" | tr '\t' ' ')"
        echo "  $MF_BROKEN_REASON"
        echo ""
        echo "  This is not a clean tree. It is an unread one, and the"
        echo "  difference is the only thing this check is for."
    } >&2
    exit 2
fi

echo "=== MECHANICAL FINDINGS ==="
echo "  record : $MF_RECORD_FILE  (section(s) $MF_SECTIONS)"
echo "  roots  : $(printf '%s' "$MF_ROOTS" | tr '\t' ' ')"
[ -n "$MF_ABSENT" ] && echo "  absent : $(printf '%s' "$MF_ABSENT" | tr '\t' ' ')  (declared, not on this machine, not swept)"
echo "  swept $MF_N_SUBJECTS subject(s): $MF_N_FINDINGS finding(s) — $MF_N_NEW new, $MF_N_KNOWN known, $MF_N_GONE gone, $MF_N_CONTRA closed-but-present; $MF_N_WRITTEN row(s) written"

if [ "$QUIET" -eq 0 ]; then
    echo ""
    printf '%s\n' "$MF_LINES" | awk -F'\t' '
        $1=="CLASS" {printf "  %-8s %-22s %5s subject(s) examined, %s finding(s)\n", "class", $2, $3, $4}
        $1=="F"     {printf "  %-8s %-20s %-8s %s\n", $2, $4, "", $3}
        $1=="WROTE" {printf "  %-8s %-20s line %s  %s\n", "WROTE", $2, $4, $3}
        $1=="EXEMPT" {printf "  %-8s %s — declared: %s\n", "EXEMPT", $2, $3}
        $1=="SKIP"  {printf "  %-8s %s — %s\n", "SKIP", $2, $3}
        $1=="NOTE"  {printf "  %-8s %s\n", "note", $2}'
fi

if [ "$MF_N_NEW" -gt 0 ] && [ -z "$WRITE" ]; then
    echo ""
    echo "  $MF_N_NEW finding(s) have no row. Re-run with --write to append them to"
    echo "  $MF_RECORD_LABEL §$MF_SECTIONS in $MF_RECORD_REPO — the Stop hook does this on its own."
fi
if [ "$MF_N_WRITTEN" -gt 0 ]; then
    echo ""
    echo "  $MF_N_WRITTEN row(s) appended to $MF_RECORD_FILE, UNCOMMITTED: $MF_WRITTEN_IDS"
    echo "  Read each one, then land it or delete it. Nothing is running for them."
fi
if [ "$MF_N_GONE" -gt 0 ]; then
    echo ""
    echo "  $MF_N_GONE row(s) describe a finding the sweep no longer produces: $MF_GONE_IDS"
    echo "  Close each in the same land as its fix. There is deliberately no command that does it for you."
fi
if [ "$MF_N_CONTRA" -gt 0 ]; then
    echo ""
    echo "  $MF_N_CONTRA row(s) say CLOSED over a finding that is still there: $MF_CONTRA_IDS"
fi

if [ "$MF_N_NEW" -gt 0 ] || [ "$MF_N_GONE" -gt 0 ] || [ "$MF_N_CONTRA" -gt 0 ] || [ "$MF_N_WRITTEN" -gt 0 ]; then
    exit 1
fi
exit 0
