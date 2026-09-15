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
#   H8  a DECLARED gap whose suite failed a case is a FAILURE   <- the concealment case
#   H9  ...and a declared gap that failed nothing is still green — H8 has not eaten H2
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

# H8 — THE CASE THIS FILE DID NOT HAVE, AND THE NINE DAYS IT COST.
#
# H1-H7 all ask whether the DECLARATION is honest. None of them asks whether the SUITE still
# works. `gui-boot.test.sh` was dead on every host from 2026-09-08 to 2026-09-10 — its boot
# fixture built a `.app` with no `Info.plist` and the app exited on its first line — and the
# declaration in `packaging-ci.yml`, which is TRUE (no public runner can hold the loro
# compiler), read exactly the same on the runner as it had every day before. A suite that
# cannot answer HERE and a suite that cannot answer ANYWHERE were indistinguishable.
#
# The fake suite below is that shape exactly: it prints a failed case in the standard form
# every suite in this directory uses, and then exits 2. Declared, it must still be a FAILURE.
rm -f "$BOX"/*.test.sh 2>/dev/null
printf '%s\n' 'echo "=== aaa tests: all 3 passed ==="' 'exit 0' > "$BOX/aaa.test.sh"
printf '%s\n' \
  'printf "  PASS  C1 the fixture is intact\n"' \
  'printf "  FAIL  C2 the fixture is intact\n         it is not\n"' \
  'echo "deadgap.test.sh: and now this host cannot answer either." >&2' \
  'exit 2' > "$BOX/deadgap.test.sh"
run "deadgap.test.sh: no widget on this host"
if [ "$CODE" != 1 ]; then
  bad "H8 a declared gap whose suite failed a case is a failure" \
      "exit $CODE, wanted 1. A gap is a claim about the HOST; this suite found something wrong. \
Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"
elif ! printf '%s' "$OUT" | grep -Fq "FAILED: deadgap.test.sh"; then
  bad "H8 a declared gap whose suite failed a case is a failure" \
      "exit 1 as wanted, but the summary does not name it as failed"
elif ! printf '%s' "$OUT" | grep -Fq "C2 the fixture is intact"; then
  bad "H8 a declared gap whose suite failed a case is a failure" \
      "the failed case is not quoted, so a reader has to reproduce the run to see what broke"
else
  ok "H8 a declared gap whose suite failed a case is a FAILURE, and the case is quoted"
fi

# H9 — and the allowance still works. H8 keys on a `FAIL` line rather than on the exit code,
# so the case that proves it did not swallow H2 has to be run right next to it: same
# declaration, same exit 2, no failed case, green.
printf '%s\n' \
  'printf "  PASS  C1 the fixture is intact\n"' \
  'echo "deadgap.test.sh: this host cannot answer." >&2' \
  'exit 2' > "$BOX/deadgap.test.sh"
run "deadgap.test.sh: no widget on this host"
expect "H9 a declared gap that failed nothing is still green" 0 "1 of 2 suites passed"

# The scratch inventory is put back the way H1-H6 left it, so H7 reads a directory it
# recognizes and anything added after this does too.
rm -f "$BOX/deadgap.test.sh"
printf '%s\n' 'echo "=== bbb tests: all 2 passed ==="' 'exit 0' > "$BOX/bbb.test.sh"

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
