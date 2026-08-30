#!/usr/bin/env bash
#
# row-currency-lint.sh — run the row-currency predicate by hand.
#
# THE SAME CODE THE COMMIT GUARD RUNS. Not a second implementation, not a
# convenience approximation: scripts/lib/row-currency.{sh,py}, called the same
# way, so "it passes by hand" and "it passes at the land" can never be two
# different answers.
#
# Usage:
#   scripts/row-currency-lint.sh <repo>                 check the repo's rows
#   scripts/row-currency-lint.sh <repo> --message TEXT  also check a claim
#   scripts/row-currency-lint.sh <repo> --message-file F
#   scripts/row-currency-lint.sh <repo> --explain       show every id candidate
#                                                       the message check saw
#                                                       and why it was kept or
#                                                       rejected
#
# --explain exists because a precision argument nobody can inspect is a
# precision argument nobody should believe. It prints the extractor's own
# reasoning, token by token, for whatever message it was handed.
#
# Exit codes:
#   0  every governed row still describes the work it points at
#   1  at least one row does not (each is named, with the warrant it should
#      now carry)
#   2  broken: no declaration, a malformed one, or a checker that could not run

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/row-currency.sh"
[ -f "$LIB" ] || { echo "ERROR: row-currency-lint.sh: scripts/lib/row-currency.sh is missing at $LIB" >&2; exit 2; }
# shellcheck source=lib/row-currency.sh
. "$LIB"

REPO=""
MSG_TEXT=""
MSG_FILE=""
EXPLAIN=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --message)      MSG_TEXT="${2:-}"; shift 2 ;;
        --message-file) MSG_FILE="${2:-}"; shift 2 ;;
        --explain)      EXPLAIN=1; shift ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        -*)             echo "ERROR: row-currency-lint.sh: unrecognized argument '$1'" >&2; exit 2 ;;
        *)              [ -n "$REPO" ] && { echo "ERROR: row-currency-lint.sh: more than one repository given" >&2; exit 2; }
                        REPO="$1"; shift ;;
    esac
done
[ -n "$REPO" ] || { echo "ERROR: row-currency-lint.sh: expected a repository path" >&2; exit 2; }
[ -d "$REPO" ] || { echo "ERROR: row-currency-lint.sh: no such directory: $REPO" >&2; exit 2; }

rc_require_ceo_todos_lib || { rc_broken_banner "row-currency-lint.sh" "$RC_BROKEN_REASON" >&2; exit 2; }

# The root AS GIVEN — never normalized to the main checkout. Run by hand inside
# a worktree, the answer must be about the tree you are standing in; the guard
# is the thing that insists on a main checkout, and it does that separately.
ROOT="$(ct_repo_root "$REPO")" || { echo "ERROR: row-currency-lint.sh: $REPO is not inside a repository" >&2; exit 2; }

DECL_RC=0
rc_load_declaration "$ROOT" || DECL_RC=$?
case "$DECL_RC" in
  0) ;;
  1)
    # NEVER a quiet pass. "Nothing to check" and "no contract here" are
    # different answers and a caller must be able to tell them apart.
    {
        echo "=== ROW CURRENCY: NO CONTRACT IN THIS REPOSITORY ==="
        echo "  repository : $ROOT"
        echo "  There is no $ROW_CURRENCY_DECLARATION here, so no row is governed and"
        echo "  nothing was checked. That is not a clean record; it is no record."
        echo "  See the engine's reference/row-currency/ for the two declaration forms."
    } >&2
    exit 2 ;;
  *) rc_broken_banner "row-currency-lint.sh" "$RC_BROKEN_REASON" >&2; exit 2 ;;
esac

RES_RC=0
rc_resolve_record "$ROOT" || RES_RC=$?
case "$RES_RC" in
  0) ;;
  1)
    {
        echo "=== ROW CURRENCY: STOOD DOWN — THE RECORD IS NOT ON THIS MACHINE ==="
        echo "  repository : $ROOT"
        echo "  reason     : $RC_STANDDOWN_REASON"
    } >&2
    exit 2 ;;
  *) rc_broken_banner "row-currency-lint.sh" "$RC_BROKEN_REASON" >&2; exit 2 ;;
esac

WORK="$(mktemp -d -t row-currency-lint.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

RECORD="$RC_RECORD_REPO/$RC_RECORD_REL"
[ -f "$RECORD" ] || {
    echo "ERROR: row-currency-lint.sh: the declared record is not on disk: $RECORD" >&2
    exit 2
}

B1="$WORK/base1.md"; B2="$WORK/base2.md"
git -C "$RC_RECORD_REPO" show "HEAD:$RC_RECORD_REL" > "$B1" 2>/dev/null || B1="-"
git -C "$RC_RECORD_REPO" show "HEAD~1:$RC_RECORD_REL" > "$B2" 2>/dev/null || B2="-"

MSGF="-"
if [ -n "$MSG_FILE" ]; then
    [ -f "$MSG_FILE" ] || { echo "ERROR: row-currency-lint.sh: no such message file: $MSG_FILE" >&2; exit 2; }
    MSGF="$MSG_FILE"
elif [ -n "$MSG_TEXT" ]; then
    MSGF="$WORK/message.txt"
    printf '%s\n' "$MSG_TEXT" > "$MSGF"
fi

RC_EXPLAIN="$EXPLAIN"
export RC_EXPLAIN
JOB="$WORK/job.json"
rc_build_job "$JOB" "$RECORD" "$B1" "$B2" "$MSGF" "by hand" "commit" "-" || {
    echo "ERROR: row-currency-lint.sh: could not assemble the check" >&2; exit 2; }

RESULT="$(rc_run "$JOB")" || { echo "ERROR: row-currency-lint.sh: the predicate could not run" >&2; exit 2; }

VERDICT="$(printf '%s' "$RESULT" | head -1 | cut -f1)"
BODY="$(printf '%s\n' "$RESULT" | tail -n +2)"

if [ -n "$EXPLAIN" ]; then
    printf '%s\n' "$BODY" | awk -F'\t' '
        $1=="CLAIMED"  {printf "  CLAIM    %s — %s\n", $2, $3}
        $1=="REJECTED" {printf "  rejected %-8s %s\n", $2, $3}'
fi

case "$VERDICT" in
  CLEAN)
    printf '%s\n' "$BODY" | awk -F'\t' '$1=="NOTE" {printf "  NOTE   %s\n         %s\n", $2, $3}'
    printf '%s\n' "$BODY" | awk -F'\t' '$1=="SKIP" {printf "  SKIP   item %s — %s\n         %s\n", $2, $3, $4}'
    printf '✓ row currency: %s governed row(s) still describe the work they point at (%s not checkable).\n' \
        "$(printf '%s' "$RESULT" | head -1 | cut -f2)" \
        "$(printf '%s' "$RESULT" | head -1 | cut -f3)"
    exit 0 ;;
  BROKEN)
    rc_broken_banner "row-currency-lint.sh" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)" >&2
    exit 2 ;;
  VIOLATIONS)
    rc_refusal "row-currency-lint.sh" \
        "$(printf '%s' "$RESULT" | head -1 | cut -f2) row(s) of this record no longer describe the work" \
        "$BODY" "$RECORD" >&2
    exit 1 ;;
  *)
    echo "ERROR: row-currency-lint.sh: unexpected verdict from the predicate" >&2
    exit 2 ;;
esac
