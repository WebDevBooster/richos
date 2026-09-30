#!/usr/bin/env bash
#
# ci-receipts.test.sh — `ci-receipts.py verify` must not certify a receipt whose
# own numbers refute its label.
#
#   R1  a good PASS receipt is certified (the control: the checker still says yes).
#   R2  PASS with rc=1, expected_rc=0 is NOT certified.
#   R3  PASS with rc=0, expected_rc=3 (a scoped section that ran everything) is NOT certified.
#   R4  a receipt missing its sha and exit fields is NOT certified.
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
