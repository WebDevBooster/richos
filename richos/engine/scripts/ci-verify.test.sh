#!/usr/bin/env bash
#
# ci-verify.test.sh — the two halves CI runs must add up to the whole.
#
# WHY THIS SUITE EXISTS. CI stopped running `ci-verify.sh` as one command on
# 2026-09-10: the non-suite steps run as `--no-suites` in one job, and step 3
# runs as `ci-shard.sh --shard i/N` across twelve. That split is only safe while
# the two halves are EXACTLY the whole, and "exactly" is not a property anybody
# can keep by reading the file. A step added to ci-verify.sh and not reached by
# either half is a verification silently dropped, and the log of both halves
# would still be green.
#
# So every case here runs the real script against a SYNTHETIC engine whose
# steps are stubs that record being called. The verdict is which stubs ran.
#
#   V1   `--list-steps` is the same set as the `step` calls in the file. The
#        inventory cannot drift from the steps it claims to list.
#   V2   `--no-suites` runs every step EXCEPT the suites.
#   V3   no arguments runs every step INCLUDING the suites — the one-line full
#        pass a person can still run by hand.
#   V4   V2 and V3 differ by exactly one step, and it is the suites step. This
#        is the coverage identity the sharded workflow rests on.
#   V5   `--no-suites` prints a banner saying it is one half of a verification,
#        so its green line can never be quoted as a pass.
#   V6   The step counter adds up: no banner numbers a step above the total it
#        announces. A log that reads "[7/6]" is where a reader stops trusting it.
#   V7   An unrecognized argument exits 2 rather than being ignored — an ignored
#        flag is a run that did something other than what was asked.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CIV="$SCRIPT_DIR/ci-verify.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-verify-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$CIV" ] || { echo "FATAL: missing $CIV" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== ci-verify tests ==="

# --- V1: the declared inventory equals the steps the file takes ------------
DECLARED="$(bash "$CIV" --list-steps | LC_ALL=C sort | tr '\n' ' ')"
# The `step` calls, in file order: `step 1 "..."` or `step "$(step_no 4)" "..."`.
TAKEN_N="$(grep -cE '^[[:space:]]*step ("\$\(step_no [0-9]+\)"|[0-9]+) ' "$CIV" || true)"
DECLARED_N="$(bash "$CIV" --list-steps | grep -c . || true)"
if [ "${TAKEN_N:-0}" -eq "${DECLARED_N:-0}" ] && [ "${DECLARED_N:-0}" -gt 0 ]; then
    ok "V1   --list-steps declares $DECLARED_N step(s) and the file takes $TAKEN_N: $DECLARED"
else
    bad "V1   --list-steps declares $DECLARED_N but the file takes $TAKEN_N step(s) — a step exists that the inventory does not name, or the reverse"
fi

# ---------------------------------------------------------------------------
# a synthetic engine whose every step is a stub that records being called
# ---------------------------------------------------------------------------
E="$SANDBOX/engine"
LOG="$SANDBOX/called.log"
mkdir -p "$E/scripts/hooks" "$E/reference"
printf '1.0.0-test\n' > "$E/VERSION"
cp "$CIV" "$E/scripts/ci-verify.sh"; chmod +x "$E/scripts/ci-verify.sh"

stub() { # <path> <name-to-record> [extra stdout]
    { printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s\\n" "%s" >> "$STEP_LOG"\n' "$2"
      [ -n "${3:-}" ] && printf '%s\n' "$3"
      printf 'exit 0\n'
    } > "$1"
    chmod +x "$1"
}
stub "$E/scripts/run-all-tests.sh" suites
stub "$E/scripts/hooks/install.sh" install
stub "$E/scripts/hooks/contract-integrity-probe.sh" probe
# The demo's beat COUNT is asserted by ci-verify.sh, so the stub has to say it.
stub "$E/scripts/demo.sh" demo 'printf "7/7 beats passed\n"'
stub "$E/scripts/publication-completeness.sh" publication

run_civ() { # <args...> -> rc, log in $LOG, output in $SANDBOX/out
    : > "$LOG"
    ( cd "$E" && STEP_LOG="$LOG" bash scripts/ci-verify.sh "$@" ) > "$SANDBOX/out" 2>&1
    printf '%s' "$?"
}
called() { LC_ALL=C sort "$LOG" | tr '\n' ' '; }

# --- V2 / V3 / V4 ----------------------------------------------------------
RC="$(run_civ --no-suites)"
HALF="$(called)"
HALF_RC="$RC"
RC="$(run_civ)"
WHOLE="$(called)"
WHOLE_RC="$RC"

if [ "$HALF_RC" = "0" ] && [ -n "$HALF" ] && ! printf '%s' "$HALF" | grep -q 'suites'; then
    ok "V2   --no-suites ran: $HALF(and not the suites)"
else
    bad "V2   rc=$HALF_RC ran: $HALF"; sed 's/^/          /' "$SANDBOX/out" | tail -15
fi
if [ "$WHOLE_RC" = "0" ] && printf '%s' "$WHOLE" | grep -q 'suites'; then
    ok "V3   no arguments ran every step: $WHOLE"
else
    bad "V3   rc=$WHOLE_RC ran: $WHOLE"; sed 's/^/          /' "$SANDBOX/out" | tail -15
fi
DIFF="$(python3 - "$HALF" "$WHOLE" <<'PY'
import sys
half = set(sys.argv[1].split())
whole = set(sys.argv[2].split())
print(" ".join(sorted(whole - half)) + "|" + " ".join(sorted(half - whole)))
PY
)"
ONLY_IN_WHOLE="${DIFF%%|*}"
ONLY_IN_HALF="${DIFF##*|}"
if [ "$ONLY_IN_WHOLE" = "suites" ] && [ -z "$ONLY_IN_HALF" ]; then
    ok "V4   the two halves differ by exactly the suites step — the coverage identity the sharded workflow rests on"
else
    bad "V4   only-in-whole='$ONLY_IN_WHOLE' only-in-half='$ONLY_IN_HALF'; the split is not exactly the whole minus the suites"
fi

# --- V5: the banner --------------------------------------------------------
run_civ --no-suites >/dev/null
if grep -q 'ONE HALF OF A VERIFICATION' "$SANDBOX/out" \
   && grep -q 'STEP 3 DID NOT RUN HERE' "$SANDBOX/out"; then
    ok "V5   --no-suites announces that it is one half, at the start and at the end"
else
    bad "V5   the half-verification banner is missing"; sed 's/^/          /' "$SANDBOX/out" | head -10
fi

# --- V6: the counter adds up ----------------------------------------------
BAD_NUM="$(grep -oE '=== \[[0-9]+/[0-9]+\]' "$SANDBOX/out" \
           | tr -d '=[] ' \
           | python3 -c '
import sys
bad = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    a, b = line.split("/")
    if int(a) > int(b):
        bad.append(line)
print(" ".join(bad))
')"
if [ -z "$BAD_NUM" ]; then
    ok "V6   every step banner numbers within its announced total"
else
    bad "V6   these banners number above their total: $BAD_NUM"
fi

# --- V7: an unrecognized argument -----------------------------------------
RC="$(run_civ --this-is-not-a-flag)"
if [ "$RC" = "2" ] && grep -q 'unrecognized argument' "$SANDBOX/out"; then
    ok "V7   an unrecognized argument exits 2 instead of being ignored"
else
    bad "V7   rc=$RC for an unrecognized argument"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ci-verify tests: all $PASS passed ==="
    exit 0
fi
echo "=== ci-verify tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
