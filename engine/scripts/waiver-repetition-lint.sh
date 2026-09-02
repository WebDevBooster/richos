#!/usr/bin/env bash
#
# waiver-repetition-lint.sh — read the escape-hatch ledgers by hand, and SHOW
#                             THE WORK.
#
# THE SAME CODE THE Stop HOOK RUNS. Not a second implementation and not a
# convenience approximation: scripts/hooks/notice-waiver-repetition.py, called
# the same way, so "it is quiet at the turn end" and "it is quiet by hand" can
# never be two different answers.
#
# ===========================================================================
# THIS IS THE POSITIVE PROBE
# ===========================================================================
# The hook's ordinary output is SILENCE, and this engine has shipped a
# mechanism whose silence meant it was not running more than once — a scanner
# reporting CLEAN over an empty corpus, a runner reporting all-passed over a
# suite it never invoked, a probe layer green over a guard that refused to
# start. So this prints EVERY hatch it derived from the guards, including the
# ones it decided to say nothing about, plus the ledgers on disk that no guard
# claims. A silence with nothing behind it is visible here.
#
# ===========================================================================
# WHY THE REPORT IS THE MECHANISM
# ===========================================================================
# The full argument is in the analyzer's header. Short version: on 2026-09-02
# one repository held 228 resume-acks and 23 CEO-TODO defers, all written by
# the lead, and the 228 were caused by a guard whose liveness check could never
# succeed for a background agent. The proof was sitting in a plain text file
# the whole time. Nothing read it. This reads it.
#
# Usage:
#   scripts/waiver-repetition-lint.sh <repo>              the full report
#   scripts/waiver-repetition-lint.sh <repo> --quiet      the one-line verdict
#   scripts/waiver-repetition-lint.sh <repo> --json       machine-readable
#   scripts/waiver-repetition-lint.sh <repo> --today D    evaluate as of D
#   scripts/waiver-repetition-lint.sh <repo> --jaccard N  reason-grouping knob
#
# Exit codes:
#   0  no escape hatch is being used repeatedly for the same reason
#   1  at least one is (each is named, with the guard and the count)
#   2  broken: the hatches could not be enumerated, or there is no state to
#      read. NEVER the same code as 0, because "no repeated waiver" and
#      "nothing was read" are the two answers this mechanism exists to keep
#      apart.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/hooks/notice-waiver-repetition.py"
[ -f "$ANALYZER" ] || { echo "ERROR: waiver-repetition-lint.sh: scripts/hooks/notice-waiver-repetition.py is missing at $ANALYZER" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: waiver-repetition-lint.sh: python3 is required and is not on PATH — refusing rather than reporting a clean sweep nothing performed" >&2; exit 2; }

REPO=""
MODE="text"
TODAY=""
JACCARD=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet)   MODE="quiet"; shift ;;
        --json)    MODE="json"; shift ;;
        --today)   TODAY="${2:-}"; shift 2 ;;
        --jaccard) JACCARD="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "ERROR: waiver-repetition-lint.sh: unrecognized argument '$1'" >&2; exit 2 ;;
        *)         [ -n "$REPO" ] && { echo "ERROR: waiver-repetition-lint.sh: more than one repository given" >&2; exit 2; }
                   REPO="$1"; shift ;;
    esac
done
[ -n "$REPO" ] || { echo "ERROR: waiver-repetition-lint.sh: expected a repository path (the ENTITY whose .claude/state holds the ledgers)" >&2; exit 2; }
[ -d "$REPO" ] || { echo "ERROR: waiver-repetition-lint.sh: no such directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"

# The ENGINE root is this script's own repository — the guards whose append
# sites are read are the ones shipped beside this file. The ENTITY root is the
# argument, because a by-reference engine governs a repository it does not live
# in, and conflating the two is the mistake the root-resolution contract exists
# to stop.
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

ARGS=(--engine-root "$ENGINE_ROOT" --entity-root "$REPO")
[ -n "$TODAY" ] && ARGS+=(--today "$TODAY")
[ -n "$JACCARD" ] && ARGS+=(--jaccard "$JACCARD")

case "$MODE" in
    json)  ARGS+=(--json) ;;
    quiet) ARGS+=(--one-liner) ;;
esac

set +e
OUT="$(python3 "$ANALYZER" "${ARGS[@]}" 2>&1)"
RC=$?
set -e

printf '%s\n' "$OUT"

if [ "$MODE" = "quiet" ] && [ "$RC" -eq 0 ]; then
    echo "waiver repetition: CLEAR — no escape hatch is being used repeatedly for the same reason."
fi

exit "$RC"
