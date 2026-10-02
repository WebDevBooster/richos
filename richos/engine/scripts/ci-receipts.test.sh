#!/usr/bin/env bash
#
# ci-receipts.test.sh — `ci-receipts.py verify` must not certify a receipt whose
# own numbers refute its label, and must not excuse KNOWN-RED without a live row.
#
#   R1  a good PASS receipt is certified (the control: the checker still says yes).
#   R2  PASS with rc=1, expected_rc=0 is NOT certified.
#   R3  PASS with rc=0, expected_rc=3 (a scoped section that ran everything) is NOT certified.
#   R4  a receipt missing its sha and exit fields is NOT certified.
#   R5  KNOWN-RED with a live, unexpired declaration row is certified and reported.
#   R6  KNOWN-RED with no declaration row is NOT certified.
#   R7  KNOWN-RED whose declaration expired is NOT certified.
#   R8  KNOWN-RED with an unreadable declaration table is NOT certified.
#
# CI_RECEIPTS may name another copy of the checker (used to show the new cases
# fail on the version before the fix).
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CI_RECEIPTS:-$SCRIPT_DIR/lib/ci-receipts.py}"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-receipts-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

printf 'scripts/a.test.sh\n' > "$SANDBOX/plan"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FUTURE=2999-01-01
PAST=2000-01-01

# receipt <verdict> <rc> <expected_rc> [extra json fields]
receipt() {
    printf '{"unit":"scripts/a.test.sh","verdict":"%s","rc":%s,"expected_rc":%s,"sha":"%s","seconds":1.0,"shard":1,"shards":1}\n' \
        "$1" "$2" "$3" "$SHA"
}
kr_table() { # <path> <expiry>
    printf '# declared\nscripts/a.test.sh\t2026-09-10\t%s\tsomebody\tfailing\twhy\n' "$2" > "$1"
}
run() { # <receipt-line> -> RC, OUT   (RICHOS_CI_KNOWN_RED in the caller's env names the table)
    OUT="$(printf '%s\n' "$1" | python3 "$CHECK" verify --plan "$SANDBOX/plan" 2>&1)"
    RC=$?
}

kr_table "$SANDBOX/live.tsv" "$FUTURE"
kr_table "$SANDBOX/expired.tsv" "$PAST"
printf '# empty\n' > "$SANDBOX/empty.tsv"

RICHOS_CI_KNOWN_RED="$SANDBOX/empty.tsv" run "$(receipt PASS 0 0)"
if [ "$RC" = 0 ]; then ok "R1  a consistent PASS receipt is certified"; else bad "R1  consistent PASS refused (rc=$RC): $OUT"; fi

RICHOS_CI_KNOWN_RED="$SANDBOX/empty.tsv" run "$(receipt PASS 1 0)"
if [ "$RC" = 1 ] && grep -q 'contradict' <<<"$OUT"; then ok "R2  PASS with rc=1 expected 0 is refused"; else bad "R2  (rc=$RC): $OUT"; fi

RICHOS_CI_KNOWN_RED="$SANDBOX/empty.tsv" run "$(receipt PASS 0 3)"
if [ "$RC" = 1 ] && grep -q 'contradict' <<<"$OUT"; then ok "R3  PASS with rc=0 expected 3 is refused"; else bad "R3  (rc=$RC): $OUT"; fi

RICHOS_CI_KNOWN_RED="$SANDBOX/empty.tsv" run '{"unit":"scripts/a.test.sh","verdict":"PASS"}'
if [ "$RC" = 1 ]; then ok "R4  a receipt with no sha and no exit fields is refused"; else bad "R4  (rc=$RC): $OUT"; fi

RICHOS_CI_KNOWN_RED="$SANDBOX/live.tsv" run "$(receipt KNOWN-RED 1 0)"
if [ "$RC" = 0 ] && grep -q 'declared KNOWN-RED' <<<"$OUT"; then ok "R5  KNOWN-RED with a live declaration is certified and reported"; else bad "R5  (rc=$RC): $OUT"; fi

RICHOS_CI_KNOWN_RED="$SANDBOX/empty.tsv" run "$(receipt KNOWN-RED 1 0)"
if [ "$RC" = 1 ] && grep -q 'no declaration' <<<"$OUT"; then ok "R6  KNOWN-RED with no declaration row is refused"; else bad "R6  (rc=$RC): $OUT"; fi

RICHOS_CI_KNOWN_RED="$SANDBOX/expired.tsv" run "$(receipt KNOWN-RED 1 0)"
if [ "$RC" = 1 ] && grep -q 'expired' <<<"$OUT"; then ok "R7  KNOWN-RED past its expiry is refused"; else bad "R7  (rc=$RC): $OUT"; fi

RICHOS_CI_KNOWN_RED="$SANDBOX/does-not-exist.tsv" run "$(receipt KNOWN-RED 1 0)"
if [ "$RC" = 1 ] && grep -q 'could not be read' <<<"$OUT"; then ok "R8  KNOWN-RED with an unreadable table is refused"; else bad "R8  (rc=$RC): $OUT"; fi

# R9 (P5-77): an expiry that is not a real calendar date is not a time boundary. The
# old string comparison sorted `tomorrow` and `2999-99-99` after every date, so a red
# unit stayed excused forever.
for BADEXP in tomorrow 2999-99-99 2026-02-30 "" 20991231; do
    kr_table "$SANDBOX/bad.tsv" "$BADEXP"
    RICHOS_CI_KNOWN_RED="$SANDBOX/bad.tsv" run "$(receipt KNOWN-RED 1 0)"
    if [ "$RC" = 1 ] && grep -q 'not excused' <<<"$OUT"; then
        ok "R9  KNOWN-RED with expiry '$BADEXP' is refused (not a valid YYYY-MM-DD date)"
    else
        bad "R9  expiry '$BADEXP' excused a red unit (rc=$RC): $OUT"
    fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
