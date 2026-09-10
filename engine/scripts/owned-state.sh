#!/usr/bin/env bash
#
# owned-state.sh — WHAT DO I OWN THE HEALTH OF, AND WHICH OF IT IS BAD RIGHT
#                  NOW? Ask it by hand, any time, from anywhere.
#
# THE SAME CODE THE GATE RUNS. Not a second implementation and not a
# convenience approximation: scripts/lib/owned-systems.py, called the same way,
# so "the gate let me through" and "it is clean by hand" can never be two
# different answers.
#
# ===========================================================================
# THIS IS THE POSITIVE PROBE
# ===========================================================================
# The gate's ordinary output is SILENCE, and this project has shipped a
# mechanism whose silence meant it was not running more than once: a scanner
# reporting CLEAN over an empty corpus, a runner reporting all-passed over a
# suite it never invoked, a probe layer green over a guard that refused to
# start. So this prints EVERY system in the declaration, including the healthy
# ones and including the rows that are out of jurisdiction here — which are
# exactly the ones a silence could otherwise be hiding.
#
# It also prints, for every system, WHICH COMMAND ANSWERED and WHEN THE ANSWER
# WAS TAKEN. A cached verdict says so. An answer whose age is invisible is the
# failure this engine is named after avoiding.
#
# Usage:
#   scripts/owned-state.sh                     the full report, this repository
#   scripts/owned-state.sh <repo>              from there
#   scripts/owned-state.sh <repo> --json       the whole record
#   scripts/owned-state.sh <repo> --refresh    ignore the cached verdict
#   scripts/owned-state.sh <repo> --line       the operator's one line
#
# Exit codes:
#   0  every system in jurisdiction is healthy
#   1  at least one is not — each named, with the evidence that decided it
#   2  BROKEN: the declaration could not be read. Never the same code as 0,
#      because "nothing is wrong" and "nothing was read" are the two answers
#      this whole mechanism exists to keep apart.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPT_DIR/lib/owned-systems.py"

if [ ! -f "$LIB" ]; then
    echo "ERROR: owned-state.sh: scripts/lib/owned-systems.py is missing at $LIB" >&2
    exit 2
fi
command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: owned-state.sh: python3 is not on PATH, so no check can be run" >&2
    exit 2
}

ENTITY=""
MODE="report"
PASS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --json)    PASS+=(--json); shift ;;
        --refresh) PASS+=(--refresh); shift ;;
        --ttl)     PASS+=(--ttl "${2:-900}"); shift 2 ;;
        --line)    MODE="line"; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        printf 'owned-state.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
        *)         ENTITY="$1"; shift ;;
    esac
done

if [ -z "$ENTITY" ]; then
    ENTITY="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
fi
ENTITY="$(cd "$ENTITY" 2>/dev/null && pwd || printf '%s' "$ENTITY")"
[ -d "$ENTITY" ] || { printf 'owned-state.sh: %s is not a directory\n' "$ENTITY" >&2; exit 2; }

# An engine loaded BY REFERENCE lives outside the repository it serves, and the
# report has to name BOTH roots or a reader cannot tell which pair produced the
# verdict. resolve-main-checkout.sh does the same job one level down.
if [ "$MODE" = "line" ]; then
    RC=0
    OUT="$(python3 "$LIB" report --entity "$ENTITY" --engine "$ENGINE_ROOT" --json "${PASS[@]}" 2>/dev/null)" || RC=$?
    if [ "$RC" -ge 2 ]; then
        echo "OWNED SYSTEMS: BROKEN — the declaration could not be read, so nothing is being watched."
        exit 2
    fi
    printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("OWNED SYSTEMS: BROKEN — the verdict could not be parsed.")
    sys.exit(2)
standing = [s for s in d["systems"] if s["status"] in ("UNHEALTHY", "UNKNOWN")]
if not standing:
    live = [s for s in d["systems"] if s["status"] != "OUT-OF-JURISDICTION"]
    print("OWNED SYSTEMS: all %d in jurisdiction healthy (taken %s)." % (len(live), d["generated_at"]))
    sys.exit(0)
print("OWNED SYSTEMS: %d standing — %s (taken %s). Detail: scripts/owned-state.sh" % (
    len(standing), "; ".join("%s %s" % (s["id"], s["status"]) for s in standing), d["generated_at"]))
sys.exit(1)
'
    exit $?
fi

RC=0
python3 "$LIB" report --entity "$ENTITY" --engine "$ENGINE_ROOT" "${PASS[@]}" || RC=$?
exit "$RC"
