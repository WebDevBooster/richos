#!/usr/bin/env bash
#
# run-tests.test.sh — the harness's own allowance, held to account.
#
# =========================================================================================
# WHY A SUITE FOR THE THING THAT RUNS THE SUITES
# =========================================================================================
#
# `run-tests.sh` now tolerates one outcome it used to call a failure: a suite that exits 2,
# meaning "this host cannot answer". That allowance is the only way seven suites that pass
# perfectly on a public runner can run in CI at all, because the eighth needs a compiler that
# lives in a private repository and no runner can ever have it.
#
# IT IS ALSO THE MOST DANGEROUS LINE IN THIS DIRECTORY. An allowance is how a suite stops
# running and nobody finds out, and this repository has shipped that defect five times under
# a reassuring fraction — "13/13 guards", "18/18 suites", a `run.js` reporting "all 4 suites
# passed" while running none of `steering.js`'s 24 checks. The allowance is therefore
# conditional in four ways, and every one of those conditions is a claim that has to keep
# being true. A claim nothing executes is a comment.
#
# So: fake suites in a scratch directory with known exit codes, and a copy of the real
# `run-tests.sh` pointed at them. Nothing here touches the repository's own suites.
#
# CASES
#
#   H1  an UNDECLARED gap is refused                    <- the anti-silence case
#   H2  a gap DECLARED with a reason is green, and the summary names it
#   H3  a declaration with NO reason is refused         <- a bare marker declares nothing
#   H4  a STALE declaration — the suite answered — is refused
#   H5  a real FAILURE outranks a declared gap
#   H6  no gaps at all leaves the original summary untouched
#   H7  an empty inventory is still exit 2, never "all 0 suites passed"
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$DIR/run-tests.sh"

TMP="$(mktemp -d -t run-tests-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "run-tests.test.sh: run-tests.sh refuses off macOS, so its allowances cannot be" >&2
  echo "                   exercised here. (uname -s reports $(uname -s).)" >&2
  exit 3
fi

# A scratch inventory. `run-tests.sh` discovers suites next to ITSELF, so the copy goes in
# with them and the real directory is never read.
BOX="$TMP/box"; mkdir -p "$BOX"
cp "$HARNESS" "$BOX/run-tests.sh"
printf '%s\n' 'echo "=== aaa tests: all 3 passed ==="' 'exit 0' > "$BOX/aaa.test.sh"
printf '%s\n' 'echo "=== bbb tests: all 2 passed ==="' 'exit 0' > "$BOX/bbb.test.sh"
printf '%s\n' 'echo "gap.test.sh: cannot answer on this host." >&2' 'exit 2' > "$BOX/gap.test.sh"
printf '%s\n' 'echo "=== broken tests: 1 FAILED, 0 passed ==="' 'exit 1' > "$BOX/broken.hold"

# run <declaration> -> sets CODE and OUT
run() {
  OUT="$(env "RUN_TESTS_DECLARED_GAPS=${1:-}" bash "$BOX/run-tests.sh" 2>&1)"; CODE=$?
  return 0
}
# expect <name> <wanted-code> [substring]
expect() {
  local name="$1" want="$2" needle="${3:-}"
  if [ "$CODE" != "$want" ]; then
    bad "$name" "exit $CODE, wanted $want. Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
  elif [ -n "$needle" ] && ! printf '%s' "$OUT" | grep -Fq -- "$needle"; then
    bad "$name" "exit $want as wanted, but the output never said '$needle'"
  else
    ok "$name"
  fi
}

echo ""
echo "=== H. the harness's host-gap allowance ==="

# H1 — the case the whole design exists for. Nothing declared; a suite says it cannot
# answer; the run must refuse rather than quietly drop it.
run ""
expect "H1 an undeclared gap is refused" 2 "nobody declared them: gap.test.sh"

# H2 — declared, with a reason. Green, and the summary must not read "all N suites passed".
run "gap.test.sh: no widget on this host"
if [ "$CODE" != 0 ]; then
  bad "H2 a declared gap with a reason is green" "exit $CODE, wanted 0"
elif printf '%s' "$OUT" | grep -Fq "all 3 suites passed"; then
  bad "H2 a declared gap with a reason is green" \
      "the summary claimed all three suites passed while one of them did not run"
elif ! printf '%s' "$OUT" | grep -Fq "2 of 3 suites passed"; then
  bad "H2 a declared gap with a reason is green" \
      "the summary does not say how many ran: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -Fq "no widget on this host"; then
  bad "H2 a declared gap with a reason is green" "the reason is not printed with the result"
else
  ok "H2 a declared gap with a reason is green, and the summary names it and its reason"
fi

# H3 — a bare name. The same rule gui-boot.test.sh's own A4 case applies to the gaps IT
# accounts for: a marker with no reason declares nothing.
run "gap.test.sh"
expect "H3 a declaration with no reason is refused" 2 "A bare name declares nothing"

# H4 — the allowance outliving its reason. Without this, a declaration written for one cause
# sits there ready to swallow a different one years later.
mv "$BOX/gap.test.sh" "$BOX/gap.hold"
run "aaa.test.sh: a reason that is no longer true"
expect "H4 a declaration whose suite answered is refused" 2 "The allowance has outlived its reason"
mv "$BOX/gap.hold" "$BOX/gap.test.sh"

# H5 — a suite that RAN and lost must never be reported under a gap headline.
mv "$BOX/broken.hold" "$BOX/broken.test.sh"
run "gap.test.sh: no widget on this host"
expect "H5 a real failure outranks a declared gap" 1 "FAILED: broken.test.sh"
mv "$BOX/broken.test.sh" "$BOX/broken.hold"

# H6 — the ordinary path is untouched. This is the case that catches a refactor of the
# summary breaking the thing everyone actually reads.
rm -f "$BOX/gap.test.sh"
run ""
expect "H6 with no gap and no failure the original summary is unchanged" 0 "all 2 suites passed — 5 checks"

# H7 — the pre-existing refusal that must survive all of the above.
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
cp "$HARNESS" "$EMPTY/run-tests.sh"
OUT="$(bash "$EMPTY/run-tests.sh" 2>&1)"; CODE=$?
expect "H7 an empty inventory is refused, never 'all 0 suites passed'" 2 "refusing to report green over an empty inventory"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== run-tests.test.sh: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== run-tests tests: all $PASS passed ==="
