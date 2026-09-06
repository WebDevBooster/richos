#!/usr/bin/env bash
#
# unlanded-branches-lint.sh — run the unlanded-work sweep by hand, and SHOW ITS
#                             WORK.
#
# THE SAME CODE THE Stop HOOK RUNS. Not a second implementation and not a
# convenience approximation: scripts/lib/unlanded-branches.py, called the same
# way, so "it was quiet at the turn end" and "it is quiet by hand" can never be
# two different answers.
#
# ===========================================================================
# THIS IS THE POSITIVE PROBE
# ===========================================================================
# The hook's ordinary output is SILENCE, and this project has shipped a
# mechanism whose silence meant it was not running more than once: a scanner
# reporting CLEAN over an empty corpus, a runner reporting all-passed over a
# suite it never invoked. So the sweep is inspectable, always, and `--format
# text` prints EVERY repository it looked at with the trunk it compared
# against, including the repositories it found nothing in — which are the ones
# a silence could otherwise be hiding.
#
# IT ALSO PRINTS WHAT THE HOOK DELIBERATELY STAYS QUIET ABOUT: the branches
# that are ahead of main and are held by a LIVE teammate. Those are normal, the
# notice does not name them, and the difference between "the hook found nothing"
# and "the hook found six and judged them all live" is exactly the thing a
# person needs to be able to see by hand.
#
# Usage:
#   scripts/unlanded-branches-lint.sh                 sweep the current repo
#   scripts/unlanded-branches-lint.sh <repo>          sweep from there
#   scripts/unlanded-branches-lint.sh <repo> --json   the whole record
#   scripts/unlanded-branches-lint.sh <repo> --line   the operator's one line
#   ... --session <id>       join the worktree ledger on a session id, which is
#                            what adds the CROSS-REPOSITORY trees a seat-only
#                            sweep cannot see. Defaults to $RICHOS_SESSION_ID.
#   ... --ledger <path>      a different worktree ledger (tests point this into
#                            a sandbox).
#
# Exit codes:
#   0  nothing is stranded — every branch ahead of main is held by a live
#      teammate, or there are none
#   1  at least one branch holds work that main does not have and nothing live
#      is holding it (each is named)
#   2  broken: no repository could be resolved, or the sweep is missing. NEVER
#      the same code as 0, because "nothing is unlanded" and "nothing was read"
#      are the two answers this whole mechanism exists to keep apart.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SCRIPT_DIR/lib/unlanded-branches.py"
[ -f "$SWEEP" ] || { echo "ERROR: unlanded-branches-lint.sh: scripts/lib/unlanded-branches.py is missing at $SWEEP" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: unlanded-branches-lint.sh: python3 is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "ERROR: unlanded-branches-lint.sh: git is required" >&2; exit 2; }

REPO=""
FORMAT="text"
SESSION="${RICHOS_SESSION_ID:-}"
LEDGER=""
EXTRA="${UNLANDED_BRANCHES_EXTRA_REPOS:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --json)    FORMAT="json"; shift ;;
        --line)    FORMAT="line"; shift ;;
        --text)    FORMAT="text"; shift ;;
        --session) SESSION="${2:-}"; shift 2 ;;
        --ledger)  LEDGER="${2:-}"; shift 2 ;;
        --extra-repos) EXTRA="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "ERROR: unlanded-branches-lint.sh: unrecognized argument '$1'" >&2; exit 2 ;;
        *)         [ -n "$REPO" ] && { echo "ERROR: unlanded-branches-lint.sh: more than one repository given" >&2; exit 2; }
                   REPO="$1"; shift ;;
    esac
done
[ -n "$REPO" ] || REPO="$PWD"
[ -d "$REPO" ] || { echo "ERROR: unlanded-branches-lint.sh: no such directory: $REPO" >&2; exit 2; }

BASE=(--entity-root "$REPO" --session "$SESSION" --extra-repos "$EXTRA")
[ -n "$LEDGER" ] && BASE=("${BASE[@]}" --ledger "$LEDGER")

set +e
OUT="$(python3 "$SWEEP" "${BASE[@]}" --format "$FORMAT" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"

# --format line already answers in its exit code; the other formats are read
# back through the one field that decides it, so all three agree by
# construction rather than by two implementations agreeing.
if [ "$FORMAT" = "line" ]; then
    [ "$RC" -eq 3 ] && exit 1
    [ "$RC" -eq 0 ] && exit 0
    exit 2
fi
[ "$RC" -eq 0 ] || exit 2

TAB="$(printf '\t')"
VERDICT="$(python3 "$SWEEP" "${BASE[@]}" --format hook 2>/dev/null || true)"
STATUS="$(printf '%s\n' "$VERDICT" | grep "^STATUS${TAB}" | head -1 | cut -f2- || true)"
N="$(printf '%s\n' "$VERDICT" | grep "^N${TAB}" | head -1 | cut -f2- || true)"
case "$STATUS" in
    stand-down|"") exit 2 ;;
esac
[ "${N:-0}" = "0" ] || exit 1
exit 0
