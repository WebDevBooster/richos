#!/usr/bin/env bash
#
# scratch-sweep.test.sh — the sweep wrapper must be able to say the cleaner
# CRASHED. It runs the real wrapper against a stand-in scratch-reaper.sh.
#
#   K1  a reaper that exits 0 with nothing to do -> exit 0, ok:true (the control).
#   K2  a reaper that exits 1 before writing any log -> NOT ok (hunt P5-26: this
#       used to fall through as ok:true, swept=0, exit 0).
#   K3  a reaper that exits 4 (a deletion failed) but left no parsable log -> NOT ok.
#   K4  a reaper killed with 125 -> NOT ok.
#   K5  a reaper that exits 3 (undecidable) stays ok:true with exit 3: a live
#       owner protecting something is the mechanism working.
#   K6  a reaper that exits 2 (refused) stays ok:false with exit 2.
#
# SWEEP names another copy of the wrapper (used to show K2-K4 fail before the fix).
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="${SWEEP:-$SCRIPT_DIR/scratch-sweep.sh}"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scratch-sweep-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

mkdir -p "$SANDBOX/engine/scripts" "$SANDBOX/tmp"
cp "$SWEEP" "$SANDBOX/engine/scripts/scratch-sweep.sh"

# run_with <reaper-exit-code> <reaper stdout line> -> RC, OUT
run_with() {
    printf '#!/usr/bin/env bash\n[ -n "$1" ] && :\nprintf "%%s\\n" %q\nexit %s\n' "$2" "$1" > "$SANDBOX/engine/scripts/scratch-reaper.sh"
    chmod +x "$SANDBOX/engine/scripts/scratch-reaper.sh"
    : > "$SANDBOX/reaper.log"
    OUT="$(TMPDIR="$SANDBOX/tmp" SCRATCH_REAPER_LOG="$SANDBOX/reaper.log" \
           bash "$SANDBOX/engine/scripts/scratch-sweep.sh" --apply 2>/dev/null)"
    RC=$?
}

run_with 0 "applied: deleted=0 freed=0 B log=x"
if [ "$RC" = 0 ] && grep -q '"ok":true' <<<"$OUT"; then ok "K1  a reaper that exits 0 is ok"; else bad "K1  (rc=$RC): $OUT"; fi

run_with 1 "fixture crash"
if [ "$RC" = 1 ] && grep -q '"ok":false' <<<"$OUT" && grep -q 'exited 1' <<<"$OUT"; then ok "K2  a reaper that exits 1 is reported as a failure"; else bad "K2  (rc=$RC): $OUT"; fi

run_with 4 "a deletion failed"
if [ "$RC" = 1 ] && grep -q '"ok":false' <<<"$OUT"; then ok "K3  a reaper that exits 4 with no log is reported as a failure"; else bad "K3  (rc=$RC): $OUT"; fi

run_with 125 "killed"
if [ "$RC" = 1 ] && grep -q '"ok":false' <<<"$OUT"; then ok "K4  a reaper that exits 125 is reported as a failure"; else bad "K4  (rc=$RC): $OUT"; fi

run_with 3 "verdict: deleted=0 freed=0 B failures=0 undecidable=2"
if [ "$RC" = 3 ] && grep -q '"ok":true' <<<"$OUT"; then ok "K5  undecidable (exit 3) stays ok:true with exit 3"; else bad "K5  (rc=$RC): $OUT"; fi

run_with 2 "refused"
if [ "$RC" = 2 ] && grep -q '"ok":false' <<<"$OUT"; then ok "K6  a refusal (exit 2) stays ok:false with exit 2"; else bad "K6  (rc=$RC): $OUT"; fi

# P5-34: a misspelled preview flag must refuse, never sweep.
run_flag() {
    printf '#!/usr/bin/env bash\ntouch "%s/reaper-ran"\nexit 0\n' "$SANDBOX" > "$SANDBOX/engine/scripts/scratch-reaper.sh"
    chmod +x "$SANDBOX/engine/scripts/scratch-reaper.sh"; rm -f "$SANDBOX/reaper-ran"
    OUT="$(TMPDIR="$SANDBOX/tmp" SCRATCH_REAPER_LOG="$SANDBOX/reaper.log" \
           bash "$SANDBOX/engine/scripts/scratch-sweep.sh" "$@" 2>/dev/null)"
    RC=$?
}
run_flag --dryrun
if [ "$RC" = 2 ] && [ ! -e "$SANDBOX/reaper-ran" ]; then ok "K7  --dryrun refuses and runs no deletion"; else bad "K7  (rc=$RC) reaper ran: $OUT"; fi
run_flag --some-future-option
if [ "$RC" = 0 ] && [ -e "$SANDBOX/reaper-ran" ]; then ok "K8  CONTROL: an unrelated unknown flag is still ignored"; else bad "K8  (rc=$RC): $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
