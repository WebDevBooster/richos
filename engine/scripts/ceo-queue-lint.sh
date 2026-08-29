#!/usr/bin/env bash
#
# ceo-queue-lint.sh — run the CEO-queue predicate against a real record.
#
# The predicate, its rationale and everything it cannot catch live in
# scripts/lib/ceo-queue.sh. This is the command-line face of it: the answer to
# "what does the guard actually check?" that a person can run, by hand, in one
# line, and get the same verdict the guard gets — because it is the same code.
#
#   scripts/ceo-queue-lint.sh                     # the repository you are in
#   scripts/ceo-queue-lint.sh /path/to/repo       # a specific repository
#   scripts/ceo-queue-lint.sh /path/to/record.md  # a specific record file
#
# EXIT CODES — and the third one is the whole reason this script has its own
# code space rather than a boolean:
#
#   0  clean: every item in every CEO section is prepared
#   1  violations: each is named, with the item id and what to do
#   2  cannot run: no declaration, a broken declaration, or a broken checker
#   3  THE DECLARED RECORD IS NOT ON DISK
#
# Exit 3 exists because "the record is absent" and "the record is fine" must
# never be the same signal. A checker that quietly no-ops when its subject is
# missing is precisely the defect this whole mechanism was built to remove: it
# reports green over an inventory of nothing. CI runs this predicate against
# FIXTURES (see scripts/hooks/ceo-queue.test.sh) because the real record lives
# in a separate private repository that a CI runner cannot see; a suite that
# silently passed on the runner because the record was absent would be the same
# failure one level out.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/ceo-queue.sh"

QUIET=0
TARGET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet|-q) QUIET=1 ;;
        -h|--help)
            sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            echo "ERROR: ceo-queue-lint.sh: unrecognised argument '$1'" >&2
            exit 2 ;;
        *)
            [ -z "$TARGET" ] || { echo "ERROR: ceo-queue-lint.sh: one target only" >&2; exit 2; }
            TARGET="$1" ;;
    esac
    shift
done
[ -n "$TARGET" ] || TARGET="$PWD"

if [ ! -f "$LIB" ]; then
    echo "ERROR: ceo-queue-lint.sh: scripts/lib/ceo-queue.sh is missing at $LIB — the entire predicate lives there and this script will not guess." >&2
    exit 2
fi
# shellcheck source=lib/ceo-queue.sh
. "$LIB"

REPO="$(cq_repo_root "$TARGET" 2>/dev/null || true)"
if [ -z "$REPO" ]; then
    echo "ERROR: ceo-queue-lint.sh: '$TARGET' is not inside a git repository." >&2
    exit 2
fi

DECL_RC=0
cq_load_declaration "$REPO" || DECL_RC=$?
case "$DECL_RC" in
    0) ;;
    1)
        echo "ERROR: ceo-queue-lint.sh: $REPO carries no $CEO_QUEUE_DECLARATION, so it declares no CEO queue." >&2
        echo "       Nothing was checked. This is a usage error, not a pass." >&2
        exit 2 ;;
    *)
        cq_broken_banner "ceo-queue-lint.sh" "$CQ_BROKEN_REASON" >&2
        exit 2 ;;
esac

RECORD="$REPO/$CQ_QUEUE_RECORD"
# When the caller named a file directly, honour it — but only if the
# declaration's record is what they named, so this can never be used to lint
# some other file and call the result a verdict on the queue.
if [ -f "$TARGET" ] && [ "$(cq_physical "$TARGET")" != "$(cq_physical "$RECORD")" ]; then
    echo "ERROR: ceo-queue-lint.sh: '$TARGET' is not the declared record for $REPO." >&2
    echo "       $CEO_QUEUE_DECLARATION declares QUEUE_RECORD=$CQ_QUEUE_RECORD" >&2
    exit 2
fi

if [ ! -f "$RECORD" ]; then
    {
        echo "=== CEO QUEUE: THE DECLARED RECORD IS NOT ON DISK ==="
        echo "  repository : $REPO"
        echo "  declared   : $CQ_QUEUE_RECORD"
        echo "  looked at  : $RECORD"
        echo ""
        echo "  This is exit 3, deliberately distinct from both 'clean' and"
        echo "  'violations'. A checker that no-ops when its subject is absent"
        echo "  reports green over nothing, which is the failure this mechanism"
        echo "  exists to remove."
    } >&2
    exit 3
fi

cq_resolve_roots "$REPO"

RESULT="$(cq_lint_file "$CQ_QUEUE_RECORD" "$RECORD" "$REPO")" || {
    echo "ERROR: ceo-queue-lint.sh: the checker could not run — treating as BROKEN, not as clean." >&2
    exit 2
}

VERDICT="$(printf '%s' "$RESULT" | head -1 | cut -f1)"
BODY="$(printf '%s\n' "$RESULT" | tail -n +2)"

case "$VERDICT" in
    CLEAN)
        if [ "$QUIET" -eq 0 ]; then
            CHECKED="$(printf '%s' "$RESULT" | head -1 | cut -f2)"
            SKIPPED="$(printf '%s' "$RESULT" | head -1 | cut -f3)"
            printf '✓ CEO queue clean: %s item(s) in section(s) %s are prepared — artifact on disk, time, done, unblocks.\n' \
                "$CHECKED" "$CQ_CEO_SECTIONS"
            printf '  entry point: %s — present, singular, named at the head of %s, byte-current with %s.\n' \
                "${CQ_QUEUE_VIEW:-<none declared>}" "$CQ_ROOT_README" "$CQ_QUEUE_RECORD"
            printf '  front door : sha256:%s\n' "$(cq_verdict_fp "$RESULT" | cut -c1-16)"
            if [ "${SKIPPED:-0}" != "0" ]; then
                printf '  %s artifact(s) NOT checked (declared root not on this machine):\n' "$SKIPPED"
                printf '%s\n' "$BODY" | while IFS="$(printf '\t')" read -r kind sec iid path why; do
                    [ "$kind" = "SKIP" ] || continue
                    printf '    section %s, item %s — %s: %s\n' "$sec" "$iid" "$path" "$why"
                done
            fi
            # Every LIMIT of this run, printed on a clean verdict. A green tick
            # that does not say what it left unchecked is how "clean" starts
            # meaning something it never checked.
            printf '%s\n' "$BODY" | awk -F'\t' '$1=="NOTE" {printf "  NOT CHECKED — %s\n    %s\n", $2, $3}'
        fi
        exit 0 ;;
    VIOLATIONS)
        cq_refusal "ceo-queue-lint.sh" \
            "$(printf '%s' "$RESULT" | head -1 | cut -f2) thing(s) about this queue are not ready" \
            "$BODY" "$REPO/$CQ_QUEUE_RECORD" >&2
        exit 1 ;;
    BROKEN)
        cq_broken_banner "ceo-queue-lint.sh" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)" >&2
        exit 2 ;;
    *)
        echo "ERROR: ceo-queue-lint.sh: unexpected verdict from the predicate — refusing rather than reporting clean." >&2
        exit 2 ;;
esac
