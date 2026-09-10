#!/usr/bin/env bash
#
# daily-workspace-cleanup.test.sh — runs the daily lane's unittest suite and
# prints its cases in the `  PASS  <id>` / `  FAIL  <id>` shape every other
# suite in this engine uses, so the mutation harness
# (daily-workspace-cleanup.mutation.sh) can name the case that must go red
# when a refusal is removed. A unittest suite prints "test_x ... FAIL", which
# the harness cannot match; this wrapper is the translation and nothing else.
#
# Exit 0 = every case passed AND every mutant was caught; exit 1 otherwise.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(python3 "$here/daily-workspace-cleanup.test.py" -v 2>&1)"; RC=$?
FAIL=0
PASS=0
while IFS= read -r raw; do
    # A subTest failure is printed INDENTED under its test ("  test_x (...)
    # (kind='dirty') ... FAIL"); the indentation is stripped so the case id is
    # the method name either way.
    line="${raw#"${raw%%[! ]*}"}"
    case "$line" in
        test_*' ... ok')     printf '  PASS  %s\n' "${line%% *}"; PASS=$((PASS + 1)) ;;
        test_*' ... FAIL'|test_*' ... ERROR') printf '  FAIL  %s\n' "${line%% *}"; FAIL=$((FAIL + 1)) ;;
        test_*' ... skipped'*) printf '  SKIP  %s\n' "${line%% *}" ;;
    esac
done <<EOF
$OUT
EOF
if [ "$RC" -ne 0 ] || [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$OUT" | grep -A 30 -E '^(FAIL|ERROR):' | head -80
    echo "=== daily-workspace-cleanup tests: FAILED (rc=$RC, $FAIL red) ==="
    exit 1
fi
echo "=== daily-workspace-cleanup tests: all $PASS passed ==="
if [ -f "$here/daily-workspace-cleanup.mutation.sh" ]; then
    bash "$here/daily-workspace-cleanup.mutation.sh" || exit 1
fi
exit 0
