#!/usr/bin/env bash
#
# ceo-queue-render.sh — write the CEO's queue page from the record.
#
# ===========================================================================
# WHY THE RENDERER IS AN ENGINE COMMAND AND NOT A SCRIPT IN THE REPOSITORY
# ===========================================================================
# The first version lived in the repository that owns the record, as a node
# script with its own parse of the same file. Three things were wrong with
# that, and only the third is obvious in hindsight:
#
#   1. TWO PARSERS OF ONE FILE. It had its own regexes for the item heading and
#      the four fields, and its own hard-coded knowledge of where the sibling
#      repository lives. Two parsers agree until they don't, and the day they
#      disagree the CEO reads a page the gate says is fine. This engine has now
#      found that exact defect in itself three times — a typed guard list, a
#      typed suite list, a typed count.
#
#   2. THE GATE WOULD HAVE TO TRUST IT. "Is the view current?" is answered by
#      rendering and comparing bytes. If the renderer is supplied by the
#      repository being checked, the repository can make its own gate pass.
#
#   3. CUSTOMERS COULD NOT REACH IT. The engine shipped the lint, the guard and
#      the test suite, and the view generator sat in one operator's private
#      repository. Every adopter would have received the enforcement and not the
#      page — the exact failure that started this, shipped to everyone.
#
# So: ONE parse (scripts/lib/ceo-queue.py), and the view is one of its two
# outputs. There is no second implementation to keep in step.
#
# DERIVED, NEVER MAINTAINED. Edit the record; re-run this. Never edit the view
# by hand — it is overwritten without warning, and the commit guard refuses a
# view that is not byte-identical to what the record renders to.
#
# Usage:
#   scripts/ceo-queue-render.sh                 # the repository you are in
#   scripts/ceo-queue-render.sh /path/to/repo
#   scripts/ceo-queue-render.sh --check [repo]  # write nothing; is it current?
#   scripts/ceo-queue-render.sh --stdout [repo] # print it, write nothing
#
# Exit codes:
#   0  written (or, with --check, already current)
#   1  --check only: the view on disk is STALE or missing
#   2  cannot run: no declaration, a broken one, or a broken renderer
#   3  the declared record is not on disk

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/ceo-queue.sh"

MODE="write"
TARGET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)  MODE="check" ;;
        --stdout) MODE="stdout" ;;
        -h|--help)
            sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            echo "ERROR: ceo-queue-render.sh: unrecognised argument '$1'" >&2
            exit 2 ;;
        *)
            [ -z "$TARGET" ] || { echo "ERROR: ceo-queue-render.sh: one target only" >&2; exit 2; }
            TARGET="$1" ;;
    esac
    shift
done
[ -n "$TARGET" ] || TARGET="$PWD"

if [ ! -f "$LIB" ]; then
    echo "ERROR: ceo-queue-render.sh: scripts/lib/ceo-queue.sh is missing at $LIB — the parse and the template both live there and this script will not guess." >&2
    exit 2
fi
# shellcheck source=lib/ceo-queue.sh
. "$LIB"

REPO="$(cq_repo_root "$TARGET" 2>/dev/null || true)"
if [ -z "$REPO" ]; then
    echo "ERROR: ceo-queue-render.sh: '$TARGET' is not inside a git repository." >&2
    exit 2
fi

DECL_RC=0
cq_load_declaration "$REPO" || DECL_RC=$?
case "$DECL_RC" in
    0) ;;
    1)
        echo "ERROR: ceo-queue-render.sh: $REPO carries no $CEO_QUEUE_DECLARATION, so it declares no CEO queue." >&2
        echo "       There is nothing to render. Start one with: scripts/ceo-queue-init.sh $REPO" >&2
        exit 2 ;;
    *)
        cq_broken_banner "ceo-queue-render.sh" "$CQ_BROKEN_REASON" >&2
        exit 2 ;;
esac

if [ -z "$CQ_QUEUE_VIEW" ] && [ "$MODE" != "stdout" ]; then
    echo "ERROR: ceo-queue-render.sh: $CEO_QUEUE_DECLARATION declares no QUEUE_VIEW, so there is no page to write." >&2
    echo "       Add QUEUE_VIEW=\"CEO-QUEUE.md\" (a bare top-level file name)." >&2
    exit 2
fi

RECORD="$REPO/$CQ_QUEUE_RECORD"
if [ ! -f "$RECORD" ]; then
    echo "ERROR: ceo-queue-render.sh: the declared record is not on disk: $RECORD" >&2
    exit 3
fi

cq_resolve_roots "$REPO"

OUT_TMP="$(mktemp -t ceo-queue-view.XXXXXX)" || exit 2
trap 'rm -f "$OUT_TMP"' EXIT

RC=0
cq_render "$CQ_QUEUE_RECORD" "$RECORD" "$REPO" > "$OUT_TMP" || RC=$?
if [ "$RC" -ne 0 ]; then
    # stdout carries a BROKEN line in this case, never a partial document.
    echo "ERROR: ceo-queue-render.sh: the record is not renderable — refusing to write a partial page." >&2
    sed 's/^/       /' "$OUT_TMP" >&2
    exit 2
fi

case "$MODE" in
    stdout)
        cat "$OUT_TMP"
        exit 0 ;;
esac

VIEW="$REPO/$CQ_QUEUE_VIEW"
if [ -f "$VIEW" ] && cmp -s "$OUT_TMP" "$VIEW"; then
    printf '✓ %s is current with %s\n' "$CQ_QUEUE_VIEW" "$CQ_QUEUE_RECORD"
    exit 0
fi

if [ "$MODE" = "check" ]; then
    if [ ! -f "$VIEW" ]; then
        echo "✗ $CQ_QUEUE_VIEW does not exist. The queue has no entry point." >&2
    else
        echo "✗ $CQ_QUEUE_VIEW is STALE against $CQ_QUEUE_RECORD:" >&2
        diff -u "$VIEW" "$OUT_TMP" 2>/dev/null | sed 's/^/    /' >&2
    fi
    echo "  Fix: scripts/ceo-queue-render.sh $REPO" >&2
    exit 1
fi

cp "$OUT_TMP" "$VIEW" || { echo "ERROR: ceo-queue-render.sh: could not write $VIEW" >&2; exit 2; }
printf '✓ wrote %s from %s\n' "$CQ_QUEUE_VIEW" "$CQ_QUEUE_RECORD"

# The reachability half is not this script's to fix, but it IS this script's to
# say out loud — a renderer that writes a page nobody can find has done the same
# half-job that started all of this.
README="$REPO/$CQ_ROOT_README"
if [ ! -f "$README" ]; then
    echo "  ⚠ $CQ_ROOT_README does not exist, so nothing at the front door names this page." >&2
elif ! head -40 "$README" | grep -qF "$CQ_QUEUE_VIEW"; then
    echo "  ⚠ $CQ_ROOT_README does not name $CQ_QUEUE_VIEW in its first 40 lines." >&2
    echo "    A page a newcomer has to search for is a search, not an entry point. Add, at the very top:" >&2
    echo "" >&2
    echo "      > ## → **[$CQ_QUEUE_VIEW]($CQ_QUEUE_VIEW)** — what is waiting on you right now" >&2
    echo "" >&2
fi
exit 0
