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
PENDING=""
emit() { # <verdict> <case-id>
    case "$1" in
        ok)      printf '  PASS  %s\n' "$2"; PASS=$((PASS + 1)) ;;
        FAIL|ERROR) printf '  FAIL  %s\n' "$2"; FAIL=$((FAIL + 1)) ;;
        skipped*) printf '  SKIP  %s\n' "$2" ;;
    esac
}
case_id() { printf '%s' "$1" | sed -n 's/.*\(test_[A-Za-z0-9_]*\).*/\1/p' | head -1; }
while IFS= read -r raw; do
    # A subTest failure is printed INDENTED under its test ("  test_x (...)
    # (kind='dirty') ... FAIL"); the indentation is stripped so the case id is
    # the method name either way.
    line="${raw#"${raw%%[! ]*}"}"
    # WHY THIS IS NOT A ONE-LINE PATTERN. unittest -v writes a case's name and
    # its verdict as ONE line with no newline between them, so anything the
    # code under test writes to stderr lands in the middle of it -- and if that
    # notice ENDS IN A NEWLINE, the verdict is pushed onto a line of its own:
    #     test_x (__main__.C.test_x) ... bound 1 workspace(s): /tmp/...
    #     FAIL
    # The old pattern required the line to START with test_ AND to END with the
    # verdict, so both halves were dropped and the run reported "0 red" while a
    # case was failing. Measured 2026-09-10: it reported a mutant that DID turn
    # its named case red as "the red is unrelated", which is the
    # green-check-over-nothing this harness exists to prevent.
    case "$line" in
        *test_*' ... ok')                      PENDING=""; emit ok "$(case_id "$line")" ;;
        *test_*' ... FAIL'|*test_*' ... ERROR') PENDING=""; emit "${line##* }" "$(case_id "$line")" ;;
        *test_*' ... skipped'*)                PENDING=""; emit skipped "$(case_id "$line")" ;;
        *test_*' ... '*)                       PENDING="$(case_id "$line")" ;;
        ok|FAIL|ERROR|skipped*)
            [ -n "$PENDING" ] && emit "$line" "$PENDING"; PENDING="" ;;
        *test_*)                               PENDING="$(case_id "$line")" ;;
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
