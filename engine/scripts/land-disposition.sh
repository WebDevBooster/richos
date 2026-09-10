#!/usr/bin/env bash
#
# land-disposition.sh — IS EVERY PIECE OF FINISHED WORK EITHER LANDED, OR HELD
#                       FOR A REASON SOMEBODY WROTE DOWN?
#
# The mechanism, the measured threshold, the substrate argument and what this
# cannot see are all in scripts/lib/land-disposition.py. Read that first — it is
# the analysis half. This file is the wiring and the two modes.
#
# ===========================================================================
# WHAT IT ANSWERS
# ===========================================================================
# For every branch that is ahead of main and that no live worktree holds:
#
#     LANDED       an ancestor of main. Nothing owed; it never appears here.
#     HELD         a demand exists and somebody acknowledged it with the REASON
#                  the work is not landed. Printed WITH the reason and with who
#                  wrote it, because a held item nobody can see is a hold again.
#     DEMANDED     a demand is standing and unanswered. It gets louder on its
#                  own at 1h, 24h and 72h through the escalation ledger.
#     UNDISPOSED   finished, not landed, nothing written. THE DEFECT.
#     YOUNG        under the threshold. The legitimate case; nothing is owed.
#     CEO-OWNED    a codex/ branch. Named, never demanded on — ceo-decisions 31.
#
# and, printed even when empty, COULD NOT DECIDE and NOT EXAMINED. R5: absence
# must never read as success, and a checker that could not look has found
# nothing and proved nothing.
#
# ===========================================================================
# TWO MODES, AND THE DEFAULT IS THE HARMLESS ONE
# ===========================================================================
#   land-disposition.sh                 REPORT. Writes nothing at all. This is
#                                       the one to run while reading.
#   land-disposition.sh --demand        Raise a demand for undisposed work and
#                                       close any demand whose work has landed.
#                                       The only mode that writes, and the whole
#                                       write surface is one append per row to
#                                       ~/.claude/state/escalations.jsonl.
#   land-disposition.sh --json          the machine form
#   land-disposition.sh --quiet         print nothing; the exit code is the
#                                       answer (for a hook)
#   land-disposition.sh --threshold N   hours, overriding the configured value
#
# ===========================================================================
# EXIT CODES — THE VERDICT IS IN THE CODE, NOT ONLY IN THE PROSE
# ===========================================================================
#   0   nothing is owed a disposition
#   3   at least one piece of finished work is neither landed nor held for a
#       written reason
#   4   nothing could be examined — no repository resolved, or the analysis
#       could not be loaded. DELIBERATELY NOT 0, for the reason the whole file
#       exists: an unexamined main and a clean one must never share a code.
#
# UNDECIDED never changes the exit code. This refuses only on a fact it
# established; what it could not decide is printed, loudly, and settled by a
# person.
#
# ===========================================================================
# IT NEVER SWEEPS AND NEVER DELETES
# ===========================================================================
# An unmerged branch is untouched by construction — there is no mutating git
# verb anywhere in this tool, and land-disposition.test.sh asserts that
# mechanically rather than trusting anyone to remember. Two things already
# remove worktrees and branches and they disagree about what they may touch;
# a third would make the disagreement worse rather than settle it.
#
# Self-test:  scripts/land-disposition.sh --self-test

set -eo pipefail

if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/hooks/land-disposition.test.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/lib/land-disposition.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "land-disposition: python3 is not on PATH — NOTHING WAS EXAMINED." >&2
    exit 4
fi
if [ ! -f "$ANALYZER" ]; then
    echo "land-disposition: the analyzer is missing at $ANALYZER — NOTHING WAS EXAMINED." >&2
    exit 4
fi

ENTITY_ROOT=""
SESSION=""
EXTRA=""
THRESHOLD=""
DEMAND=0
FORMAT="text"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --root|--entity-root) ENTITY_ROOT="${2:-}"; shift 2 ;;
        --session)   SESSION="${2:-}"; shift 2 ;;
        --extra-repos) EXTRA="${2:-}"; shift 2 ;;
        --threshold) THRESHOLD="${2:-}"; shift 2 ;;
        --demand)    DEMAND=1; shift ;;
        --json)      FORMAT="json"; shift ;;
        --quiet)     QUIET=1; shift ;;
        -h|--help)
            sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "land-disposition: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# WHICH ROOT, WHEN NOBODY SAID
# ---------------------------------------------------------------------------
# The repository this was run from, resolved to its MAIN checkout by the
# analyzer — never the worktree a person happens to be standing in. Run by hand
# from an agent worktree, that is the difference between reading the agent's
# copy of main and reading the real one.
if [ -z "$ENTITY_ROOT" ]; then
    ENTITY_ROOT="$(pwd)"
fi

CONFIG=""
for candidate in "$ENTITY_ROOT/orchestration.config" \
                 "$SCRIPT_DIR/../orchestration.config"; do
    if [ -f "$candidate" ]; then CONFIG="$candidate"; break; fi
done
if [ -n "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi
: "${CHECK_LAND_DISPOSITION:=1}"
: "${LAND_DISPOSITION_DEMAND_HOURS:=3}"

if [ "$CHECK_LAND_DISPOSITION" = "0" ]; then
    # Never a silent permission. An opt-out nobody can see is a defense that
    # decays into a rumor — and this one's whole subject is silence.
    echo "land-disposition: STOOD DOWN by CHECK_LAND_DISPOSITION=0 in ${CONFIG:-<no config>}." >&2
    echo "  Finished work that is neither landed nor held is NOT being demanded." >&2
    exit 4
fi

[ -n "$THRESHOLD" ] || THRESHOLD="$LAND_DISPOSITION_DEMAND_HOURS"

ARGS=(--entity-root "$ENTITY_ROOT" --threshold-hours "$THRESHOLD"
      --format "$FORMAT")
[ -n "$SESSION" ] && ARGS+=(--session "$SESSION")
[ -n "$EXTRA" ] && ARGS+=(--extra-repos "$EXTRA")
[ "$DEMAND" = "1" ] && ARGS+=(--demand)

# ONE SWEEP. The analyzer's exit code means the same thing in every format, so
# there is nothing to parse and no way for the printed report to disagree with
# the code beside it. A second sweep for the verdict would be exactly that bug.
set +e
OUT="$(python3 "$ANALYZER" "${ARGS[@]}" 2>&1)"
RC=$?
set -e

case "$RC" in
    0|3|4) : ;;
    *)
        echo "land-disposition: the analyzer exited $RC, which is not one of its" >&2
        echo "  verdicts (0 nothing owed, 3 owed, 4 unexamined). NOTHING WAS EXAMINED." >&2
        printf '%s\n' "$OUT" >&2
        exit 4 ;;
esac

if [ "$QUIET" = "0" ]; then
    printf '%s\n' "$OUT"
fi
exit "$RC"
