#!/usr/bin/env bash
#
# run-all-tests.sh — run EVERY test suite in this engine, and derive the count.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# "All 18 suites green" was the sentence quoted at every land, and 18 was the
# size of one glob — `scripts/hooks/*.test.sh`. There were 23 suites. The five
# outside that glob (scripts/demo.test.sh, scripts/locate-engine.test.sh,
# scripts/provision-claude-md.test.sh and the two under scripts/lib/) were not
# failing quietly; they were not being RUN.
#
# On 2026-08-29 two of those five were red on main, and had been for a day:
#
#   scripts/demo.test.sh          scripts/demo.sh — the buyer-facing 60-second
#                                 proof — exited 2 during setup, printing no
#                                 reason, on any machine that ran it.
#   scripts/locate-engine.test.sh case 6a, "install.sh mints the pointer",
#                                 FAILED.
#
# Both had the SAME cause: install.sh had started deriving its hook inventory
# from hooks/hooks.json, and two consumers did not provision it. Both were
# caught by a suite that already existed and already asserted the right thing.
# Nothing ran either suite, so the land reported 18/18 and was, on its own
# terms, telling the truth.
#
# This is the engine's own founding defect one level out. scripts/lib/
# registered-hooks.sh exists because a TYPED list of guards drifted twice in two
# days while the banner reported a full, reassuring fraction over it. A typed
# list of test suites is the same object. So this runner does not have one:
#
#   THE SUITE INVENTORY IS DISCOVERED FROM DISK, NEVER TYPED, NEVER GLOBBED
#   AT ONE DIRECTORY. A suite added anywhere under the engine is run by the
#   next invocation with no edit here, and cannot be silently excluded from
#   the fraction it is counted in.
#
# NO SILENT DEGRADATION: finding zero suites is a hard failure, not "0/0 green".
#
# Usage:
#   scripts/run-all-tests.sh            run everything, quiet on success
#   scripts/run-all-tests.sh --verbose  stream every suite's full output
#   scripts/run-all-tests.sh --list     print the discovered inventory, run none
#
# Exit codes:
#   0  every discovered suite passed
#   1  at least one suite failed (each is named, with its output)
#   2  no suites discovered, or the engine root is unreadable — refusing to
#      report a green fraction over an inventory of nothing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERBOSE=0
LIST_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=1 ;;
        --list)       LIST_ONLY=1 ;;
        *)
            echo "ERROR: run-all-tests.sh: unrecognised argument '$1'. Usage: run-all-tests.sh [--verbose] [--list]" >&2
            exit 2 ;;
    esac
    shift
done

[ -d "$ENGINE_ROOT" ] || { echo "ERROR: run-all-tests.sh: engine root unreadable: $ENGINE_ROOT" >&2; exit 2; }

# --- Discovery -------------------------------------------------------------
# Everything named *.test.sh, anywhere under the engine, sorted for a stable
# run order. LC_ALL=C so the order does not depend on the operator's locale —
# a suite list that reorders between machines makes two runs hard to diff.
SUITES=()
while IFS= read -r t; do
    [ -n "$t" ] || continue
    SUITES+=("$t")
done <<EOF
$(find "$ENGINE_ROOT" -type f -name '*.test.sh' 2>/dev/null | LC_ALL=C sort)
EOF

TOTAL="${#SUITES[@]}"
if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: run-all-tests.sh: found NO *.test.sh suites under $ENGINE_ROOT." >&2
    echo "       That is not a passing run with nothing to do — it means discovery is broken" >&2
    echo "       or this is not an engine checkout. Refusing to report a green fraction." >&2
    exit 2
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    for t in "${SUITES[@]}"; do
        printf '%s\n' "${t#"$ENGINE_ROOT"/}"
    done
    printf '%s suite(s) discovered under %s\n' "$TOTAL" "$ENGINE_ROOT" >&2
    exit 0
fi

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'

printf '%s=== engine self-test: %s suite(s) discovered under %s ===%s\n' \
    "$C_BOLD" "$TOTAL" "$ENGINE_ROOT" "$C_RESET"

PASSED=0
FAILED_NAMES=()
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/engine-tests.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT

i=0
for t in "${SUITES[@]}"; do
    i=$((i + 1))
    REL="${t#"$ENGINE_ROOT"/}"
    LOG="$LOG_DIR/$i.log"
    printf '  [%2s/%2s] %-58s ' "$i" "$TOTAL" "$REL"
    # Each suite is self-contained and sandboxes its own state; none of them
    # takes arguments. Output is captured so a green run stays readable and a
    # red one can print EVERYTHING the failing suite said — a truncated failure
    # is a failure somebody has to reproduce by hand.
    bash "$t" >"$LOG" 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        printf '%sPASS%s\n' "$C_GREEN" "$C_RESET"
        PASSED=$((PASSED + 1))
        [ "$VERBOSE" -eq 1 ] && sed 's/^/        /' "$LOG"
    else
        printf '%sFAIL%s (rc=%s)\n' "$C_RED" "$C_RESET" "$RC"
        FAILED_NAMES+=("$REL (rc=$RC)")
        sed 's/^/        /' "$LOG"
    fi
done

echo ""
if [ "${#FAILED_NAMES[@]}" -eq 0 ]; then
    printf '%s✓ %s/%s engine test suites passed.%s\n' "$C_GREEN" "$PASSED" "$TOTAL" "$C_RESET"
    exit 0
fi
printf '%s✗ %s/%s engine test suites passed — %s FAILED:%s\n' \
    "$C_RED" "$PASSED" "$TOTAL" "${#FAILED_NAMES[@]}" "$C_RESET" >&2
for n in "${FAILED_NAMES[@]}"; do
    printf '    - %s\n' "$n" >&2
done
exit 1
