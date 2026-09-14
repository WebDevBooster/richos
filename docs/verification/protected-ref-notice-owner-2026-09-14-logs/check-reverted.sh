#!/usr/bin/env bash
#
# check-reverted.sh — EVERY NEW CASE IS LOAD-BEARING, PROVED BY REVERTING IT.
#
# A suite that stays green when the thing it tests is removed is a suite that
# tests nothing. This mirrors the engine into a scratch directory, reverts one
# piece of the change at a time, runs the new suite against the mirror, and
# asserts the NAMED case goes red — not merely that something went red.
#
#   R1  the reader is deleted            -> P01 (the finding is announced) RED
#   R2  the notice is put back on stderr -> P01 RED and P12's channel control
#                                           can no longer distinguish them
#   R3  the UTC age fix is reverted      -> P14 RED, forced under TZ=Europe/London
#                                           so the result does not depend on the
#                                           machine's own clock settings
#
# Usage: docs/verification/protected-ref-notice-owner-2026-09-14-logs/check-reverted.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
ENGINE_ROOT="$REPO_ROOT/engine"

SANDBOX="$(cd "$(mktemp -d -t prmrevert.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

FAILED=0
mirror() {   # -> a fresh mirror of engine/scripts at $M
    M="$SANDBOX/m$1"
    rm -rf "$M"
    mkdir -p "$M"
    cp -R "$ENGINE_ROOT/scripts" "$M/scripts"
    cp -R "$ENGINE_ROOT/hooks" "$M/hooks" 2>/dev/null || true
    rm -rf "$M/scripts/lib/__pycache__"
}

run_suite() {  # <mirror> [env...] -> output in $OUT
    OUT="$(cd "$1/scripts/hooks" && env "${@:2}" bash ./protected-ref-moves.test.sh 2>&1)"
}

verdict() {  # <label> <case prefix> <expect RED|GREEN>
    local label="$1" case_id="$2" expect="$3" line
    line="$(printf '%s\n' "$OUT" | grep -E "(PASS|FAIL)  $case_id" | head -1)"
    if [ -z "$line" ]; then
        echo "  INCONCLUSIVE  $label — $case_id did not run at all"
        echo "                $(printf '%s\n' "$OUT" | tail -3)"
        FAILED=$((FAILED + 1))
        return 0
    fi
    case "$line" in
        *FAIL*) [ "$expect" = "RED" ] && { echo "  as expected   $label -> $case_id RED"; return 0; } ;;
        *PASS*) [ "$expect" = "GREEN" ] && { echo "  as expected   $label -> $case_id GREEN"; return 0; } ;;
    esac
    echo "  NOT PROVEN    $label — expected $case_id $expect, got: $line"
    FAILED=$((FAILED + 1))
}

echo "=== the same suite, run against a reverted engine, one revert at a time ==="
echo ""

# --- R1: the reader is not there at all ------------------------------------
mirror 1
rm -f "$M/scripts/lib/protected-ref-moves.py"
run_suite "$M"
verdict "R1 the predicate deleted" "P01" "RED"

# --- R2: the notice goes back on stderr, the channel it used to use --------
mirror 2
python3 - "$M/scripts/hooks/notice-protected-ref-moves.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r'(?m)^stop_notice_abnormal_recurring "\$KEY".*$',
           'echo "=== PROTECTED REF MOVED: $LINE ===" >&2', s)
open(p, "w", encoding="utf-8").write(s)
PY
run_suite "$M"
verdict "R2 the notice back on stderr at exit 0" "P01" "RED"

# --- R3: the UTC age fix reverted ------------------------------------------
# TZ is forced rather than inherited: `time.mktime(...) - time.timezone` is only
# wrong where summer time is in force, and a control whose result depends on the
# operator's clock settings is a control that passes for the wrong reason
# somewhere else.
mirror 3
python3 - "$M/scripts/lib/protected-ref-moves.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "return calendar.timegm(time.strptime(str(ts), \"%Y-%m-%dT%H:%M:%SZ\"))"
new = "return time.mktime(time.strptime(str(ts), \"%Y-%m-%dT%H:%M:%SZ\")) - time.timezone"
assert old in s, "the UTC conversion is not where this mutation expects it"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_suite "$M" TZ=Europe/London
verdict "R3 the UTC age conversion reverted (TZ=Europe/London)" "P14" "RED"

# --- the positive control: the SHIPPED engine, same harness, all green -----
mirror 0
run_suite "$M"
echo ""
printf '%s\n' "$OUT" | tail -2 | sed 's/^/  shipped: /'
if printf '%s\n' "$OUT" | grep -q "FAIL"; then
    echo "  NOT PROVEN    the unmutated mirror is not green, so the reverts above prove nothing"
    FAILED=$((FAILED + 1))
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "every revert turned its NAMED case red, and the unmutated mirror is green."
    exit 0
fi
echo "$FAILED revert(s) did not prove what they claim."
exit 1
