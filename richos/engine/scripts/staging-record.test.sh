#!/usr/bin/env bash
#
# staging-record.test.sh — the recorder must never invent a deploy verdict.
#
#   W1  --outcome success writes a record saying success (the control).
#   W2  --outcome failure writes a record saying failure.
#   W3  NO --outcome exits 2, names --outcome, and writes NO record. (Hunt P5-12:
#       the variable defaulted to "success", so forgetting the flag recorded a
#       successful deploy nobody verified.)
#   W4  an empty --outcome is refused the same way.
#
# RECORDER names another copy of the script (used to show W3 fails before the fix).
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER="${RECORDER:-$SCRIPT_DIR/staging-record.sh}"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/staging-record-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

SHA=0123456789abcdef0123456789abcdef01234567
REC="$SANDBOX/record"

OUT="$(bash "$RECORDER" --root "$SANDBOX" --record "$REC" --sha "$SHA" --outcome success 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '^outcome=success$' "$REC"; then ok "W1  --outcome success is recorded"; else bad "W1  (rc=$RC): $OUT"; fi

rm -f "$REC"
OUT="$(bash "$RECORDER" --root "$SANDBOX" --record "$REC" --sha "$SHA" --outcome failure 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '^outcome=failure$' "$REC"; then ok "W2  --outcome failure is recorded"; else bad "W2  (rc=$RC): $OUT"; fi

rm -f "$REC"
OUT="$(bash "$RECORDER" --root "$SANDBOX" --record "$REC" --sha "$SHA" 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q -- '--outcome' <<<"$OUT" && [ ! -e "$REC" ]; then ok "W3  no --outcome is refused and writes nothing"; else bad "W3  (rc=$RC, record exists: $([ -e "$REC" ] && echo yes || echo no)): $OUT"; fi

OUT="$(bash "$RECORDER" --root "$SANDBOX" --record "$REC" --sha "$SHA" --outcome '' 2>&1)"; RC=$?
if [ "$RC" = 2 ] && [ ! -e "$REC" ]; then ok "W4  an empty --outcome is refused and writes nothing"; else bad "W4  (rc=$RC): $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
