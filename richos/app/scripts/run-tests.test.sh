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

# =========================================================================================
# P. THE POOL — concurrency that cannot reorder, overrun or swallow anything
# =========================================================================================
#
# The harness runs its suites concurrently now. Three things about that are load-bearing
# and none of them is visible from a green summary, so each one is a case: the OUTPUT ORDER
# a reader depends on, the BOUND that keeps fourteen suites from thrashing one Mac, and the
# FAILURE that still has to stop the run when it happens in the middle of a pool.
echo ""
echo "=== P. the pool ==="
PBOX="$TMP/pool"; mkdir -p "$PBOX"
cp "$HARNESS" "$PBOX/run-tests.sh"
P2LOG="$TMP/concurrency.log"; export P2LOG

mk_timed() {  # mk_timed <name> <seconds>
  printf '%s\n' \
    'echo start >> "$P2LOG"' \
    "sleep $2" \
    'echo end >> "$P2LOG"' \
    "echo \"=== $1 tests: all 1 passed ===\"" \
    'exit 0' > "$PBOX/$1.test.sh"
}
# Deliberately DESCENDING durations against ASCENDING names: if anything printed in
# completion order instead of discovery order, P1 would read d,c,b,a.
mk_timed a 1.2
mk_timed b 0.9
mk_timed c 0.6
mk_timed d 0.1

prun() {  # prun <jobs>
  : > "$P2LOG"
  OUT="$(env RUN_TESTS_DECLARED_GAPS= P2LOG="$P2LOG" bash "$PBOX/run-tests.sh" --jobs "$1" 2>&1)"; CODE=$?
  return 0
}

prun 4
ORDER="$(printf '%s' "$OUT" | sed -n 's/^--- //p' | tr '\n' ' ')"
if [ "$CODE" != 0 ]; then
  bad "P1 concurrent output is printed in discovery order" "exit $CODE, wanted 0"
elif [ "$ORDER" != "a.test.sh b.test.sh c.test.sh d.test.sh " ]; then
  bad "P1 concurrent output is printed in discovery order" \
      "printed '$ORDER' — four suites that finish in the opposite order must still read a,b,c,d"
elif ! printf '%s' "$OUT" | grep -Fq "all 4 suites passed — 4 checks"; then
  bad "P1 concurrent output is printed in discovery order" \
      "the summary lost a suite or a check: $(printf '%s' "$OUT" | tail -1)"
else
  ok "P1 four suites finishing in reverse still print a,b,c,d, and every check is counted"
fi

# P2 — THE BOUND. Without it, fourteen suites — three of which fan out to every core —
# start at once on a 10-core Mac. MEASURED 2026-09-19 on this machine, same tree, same
# twelve suites: pool 1 = 341 s, pool 2 = 223 s, pool 3 = 167 s, pool 4 = 183 s,
# pool 6 = 228 s, pool 10 = 236 s. MORE CONCURRENCY IS SLOWER PAST THREE, because two
# suites dominate the run and contend with each other, so a bound that is not enforced is
# not a faster run — it is a slower one.
prun 2
MAX="$(awk '/^start$/{n++; if (n>m) m=n} /^end$/{n--} END{print m+0}' "$P2LOG")"
if [ "$CODE" != 0 ]; then
  bad "P2 the pool bound is enforced" "exit $CODE, wanted 0"
elif [ "$MAX" -gt 2 ]; then
  bad "P2 the pool bound is enforced" \
      "--jobs 2 and $MAX suites ran at once. An unenforced bound is how a build thrashes."
elif [ "$MAX" -lt 2 ]; then
  bad "P2 the pool bound is enforced" \
      "--jobs 2 and never more than $MAX ran at once — the pool is not filling, so nothing is concurrent"
else
  ok "P2 --jobs 2 ran at most 2 suites at any instant, and did fill both slots"
fi

# P3 — a failure in the MIDDLE of a pool. The serial harness could not lose one; a pool can,
# by printing a summary before a straggler has been collected.
printf '%s\n' 'echo "  FAIL  c1 something is wrong"' 'echo "=== c tests: 1 FAILED, 0 passed ==="' 'exit 1' > "$PBOX/c.test.sh"
prun 4
expect "P3 a failure inside a full pool still stops the run" 1 "FAILED: c.test.sh"

# =========================================================================================
# K. SKIP-WHEN-UNCHANGED — an allowance keyed on content, never on a calendar
# =========================================================================================
#
# `make-release.test.sh` and `make-engine-asset.test.sh` are 286 s of every build (measured
# 2026-09-19, run 20260919T180454Z-ac11d13e) and neither reads anything an app-only commit
# touches. They may be skipped when nothing they read has changed since a run that proved
# them green.
#
# THIS IS THE ALLOWANCE THIS FILE'S SUBJECT IS MOST AFRAID OF — a suite that stops running
# and nobody finds out. Every case below is a way that could happen.
echo ""
echo "=== K. skip-when-unchanged ==="
KREPO="$TMP/krepo"
mkdir -p "$KREPO/scripts" "$KREPO/inputs" "$KREPO/.nohooks"
git -C "$KREPO" init -q >/dev/null 2>&1
git -C "$KREPO" config user.email nobody@example.invalid
git -C "$KREPO" config user.name "run-tests fixture"
# THIS MACHINE HAS A GLOBAL core.hooksPath, so a fixture repository inherits the operator's
# commit-identity guard and every `git commit` below is REFUSED — silently, since they were
# written with `>/dev/null 2>&1`. Measured 2026-09-19: the fixture never committed, so every
# input stayed staged-as-added, `suite_input_digest` correctly refused to skip a dirty tree,
# and K2-K5 all reported PASS while asserting nothing. A fixture must not depend on the
# machine's git configuration, so this one turns hooks off for itself and `kcommit` checks
# that the commit actually happened instead of trusting that it did.
git -C "$KREPO" config core.hooksPath "$KREPO/.nohooks"
cp "$HARNESS" "$KREPO/scripts/run-tests.sh"
printf 'one\n' > "$KREPO/inputs/a.txt"
printf '%s\n' \
  '# run-tests: inputs inputs' \
  'echo "=== heavy tests: all 7 passed ==="' \
  'exit 0' > "$KREPO/scripts/heavy.test.sh"
printf '%s\n' 'echo "=== light tests: all 1 passed ==="' 'exit 0' > "$KREPO/scripts/light.test.sh"

KFIXTURE_OK=1
kcommit() {  # commit everything, and REFUSE to continue quietly if it did not happen
  git -C "$KREPO" add -A >/dev/null 2>&1
  if ! git -C "$KREPO" commit -qm "$1" >"$TMP/kcommit.log" 2>&1; then
    KFIXTURE_OK=""
    bad "K0 the fixture repository can commit" \
        "git commit failed, so every K case below would assert nothing: $(head -3 "$TMP/kcommit.log" | tr '\n' ' ')"
    return 1
  fi
  if [ -n "$(git -C "$KREPO" status --porcelain --untracked-files=all)" ]; then
    KFIXTURE_OK=""
    bad "K0 the fixture repository is clean after committing" \
        "something is still uncommitted, so a skip could never be reached: $(git -C "$KREPO" status --porcelain | tr '\n' ' ')"
    return 1
  fi
  return 0
}
kcommit fixture && ok "K0 the fixture repository commits and is clean — the K cases can reach a skip"
KSTATE="$TMP/kstate"

krun() {  # krun <run-id>
  OUT="$(env RUN_TESTS_DECLARED_GAPS= RUN_TESTS_SKIP_UNCHANGED=1 RUN_TESTS_STATE="$KSTATE" \
             RICHOS_NIGHTLY_RUN_ID="$1" RICHOS_RUNTIME_DIR= \
             bash "$KREPO/scripts/run-tests.sh" 2>&1)"; CODE=$?
  return 0
}

krun first
if [ "$CODE" != 0 ]; then
  bad "K1a a suite with no recorded proof runs" \
      "exit $CODE, wanted 0: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
elif printf '%s' "$OUT" | grep -Fq "SKIPPED: heavy.test.sh"; then
  bad "K1a a suite with no recorded proof runs" \
      "it skipped a suite it had never seen pass — a skip must rest on a prior GREEN run"
else
  ok "K1a a suite with no recorded proof runs"
fi
krun second
if [ "$CODE" != 0 ]; then
  bad "K1b a proven suite is SKIPPED, naming its digest and its run" "exit $CODE, wanted 0"
elif ! printf '%s' "$OUT" | grep -Fq "SKIPPED: heavy.test.sh"; then
  bad "K1b a proven suite is SKIPPED, naming its digest and its run" "it ran again over identical inputs"
elif ! printf '%s' "$OUT" | grep -Fq "since run first"; then
  bad "K1b a proven suite is SKIPPED, naming its digest and its run" \
      "the skip does not name the run that proved it: $(printf '%s' "$OUT" | grep SKIPPED | head -1)"
elif ! printf '%s' "$OUT" | grep -Eq 'sha256 [0-9a-f]{64}'; then
  bad "K1b a proven suite is SKIPPED, naming its digest and its run" \
      "the skip does not name the digest it compared"
elif ! printf '%s' "$OUT" | grep -Fq "1 of 2 suites passed"; then
  bad "K1b a proven suite is SKIPPED, naming its digest and its run" \
      "the summary claims a suite that did not run: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
else
  ok "K1b a proven suite is SKIPPED, naming the digest and the run that proved it"
fi

printf 'two\n' > "$KREPO/inputs/a.txt"
kcommit change
krun third
if printf '%s' "$OUT" | grep -Fq "SKIPPED: heavy.test.sh"; then
  bad "K2 a committed change to a declared input makes the suite run again" \
      "the input changed and the suite was skipped anyway"
else
  ok "K2 a committed change to a declared input makes the suite run again"
fi

krun fourth   # re-prove at the new content
printf 'three, and never committed\n' > "$KREPO/inputs/a.txt"
krun fifth
if printf '%s' "$OUT" | grep -Fq "SKIPPED: heavy.test.sh"; then
  bad "K3 an uncommitted edit to a declared input makes the suite run again" \
      "the working tree differs from the index and the suite was skipped over it. A digest \
taken from HEAD alone cannot see an edit nobody committed, which is most edits."
else
  ok "K3 an uncommitted edit to a declared input makes the suite run again"
fi
git -C "$KREPO" checkout -- inputs/a.txt >/dev/null 2>&1

if printf '%s' "$OUT" | grep -Fq "SKIPPED: light.test.sh"; then
  bad "K4 a suite that declares no inputs is never skipped" \
      "light.test.sh declares nothing and was skipped anyway — a silent skip is this file's subject"
else
  ok "K4 a suite that declares no inputs is never skipped, however often it passes"
fi

printf '%s\n' \
  '# run-tests: inputs inputs' \
  'echo "  FAIL  h1 the heavy suite found something"' \
  'echo "=== heavy tests: 1 FAILED, 0 passed ==="' \
  'exit 1' > "$KREPO/scripts/heavy.test.sh"
kcommit red
rm -f "$KSTATE/heavy.test.sh.proof"
krun sixth
krun seventh
if [ "$CODE" != 1 ]; then
  bad "K5 a suite that failed leaves no proof" "exit $CODE, wanted 1 — a red suite must stay red"
elif printf '%s' "$OUT" | grep -Fq "SKIPPED: heavy.test.sh"; then
  bad "K5 a suite that failed leaves no proof" \
      "a suite that FAILED was skipped on the next run. A proof is written only over a GREEN \
run, or a red suite goes green by being run twice."
else
  ok "K5 a suite that failed leaves no proof, so the next run still runs it and still fails"
fi

# =========================================================================================
# S. `--no-host-screen` — the promise that nothing reaches the operator's screen
# =========================================================================================
#
# The CEO, 2026-09-19: *"So, every engineer will keep opening the app making me unable to do
# anything here or WHAT???"*. `gui-boot.test.sh` boots the real app on the real screen for
# ~162 s of every build. The mode that stops it has to be ENFORCED rather than documented,
# and the enforcement has three separate ways to fail silently.
echo ""
echo "=== S. --no-host-screen ==="
SBOX="$TMP/screen"; mkdir -p "$SBOX"
cp "$HARNESS" "$SBOX/run-tests.sh"
printf '%s\n' 'echo "=== quiet tests: all 2 passed ==="' 'exit 0' > "$SBOX/quiet.test.sh"
# Classified by the ONE library in this repository that boots the shipped binary — a
# structural fact about what a suite calls, not a guess about what it might do.
printf '%s\n' \
  '. "$DIR/lib/gui-launch.sh"' \
  'echo "=== window tests: all 5 passed ==="' \
  'exit 0' > "$SBOX/window.test.sh"

srun() {  # srun <extra args> [gui host]
  OUT="$(env RUN_TESTS_DECLARED_GAPS= RICHOS_GUI_HOST="${2:-}" \
             bash "$SBOX/run-tests.sh" $1 2>&1)"; CODE=$?
  return 0
}

srun "--no-host-screen"
if [ "$CODE" != 0 ]; then
  bad "S1 --no-host-screen holds back the suite that boots the app" "exit $CODE, wanted 0"
elif ! printf '%s' "$OUT" | grep -Fq "NOT RUN (no screen): window.test.sh"; then
  bad "S1 --no-host-screen holds back the suite that boots the app" \
      "window.test.sh was not held back: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
elif printf '%s' "$OUT" | grep -Fq "all 2 suites passed"; then
  bad "S1 --no-host-screen holds back the suite that boots the app" \
      "the summary claimed both suites passed while one of them never ran"
else
  ok "S1 --no-host-screen holds back the suite that boots the app, and the run is still green"
fi

srun "" ""
if [ "$CODE" != 0 ] || ! printf '%s' "$OUT" | grep -Fq "all 2 suites passed"; then
  bad "S2 without the flag nothing changes" \
      "both suites must run as before; exit $CODE, $(printf '%s' "$OUT" | tail -1)"
else
  ok "S2 without the flag nothing changes — both suites run, as they always did"
fi

# S3 — A NAMED GUEST IS NOT A SUGGESTION. The dangerous version of this feature falls back
# to the host's screen when the VM is missing, which is the exact interruption the mode
# exists to prevent; the second most dangerous records NOT RUN and lets a caller who asked
# for a proof believe they asked for nothing.
srun "--no-host-screen" "richos-test-1"
if [ "$CODE" != 2 ]; then
  bad "S3 a named guest with no runner is REFUSED" \
      "exit $CODE, wanted 2. It must neither fall back to this screen nor pretend the suite \
was skipped on purpose."
elif ! printf '%s' "$OUT" | grep -Fq "richos-test-1"; then
  bad "S3 a named guest with no runner is REFUSED" "the refusal does not name the guest that was asked for"
else
  ok "S3 RICHOS_GUI_HOST with no runner REFUSES — never the host's screen, never a silent NOT RUN"
fi

# S4 — the proof file `nightly-local.py publish` will demand of a screenless candidate.
PROOF="$TMP/gui.proof"
srun "--proof-out $PROOF"
if [ ! -f "$PROOF" ]; then
  bad "S4 a host-screen suite that RAN writes a proof" "no file at $PROOF"
elif ! grep -q '^commit=' "$PROOF"; then
  bad "S4 a host-screen suite that RAN writes a proof" \
      "the proof names no commit, so nothing can tell which tree it was taken against"
elif ! grep -q '^result=pass$' "$PROOF"; then
  bad "S4 a host-screen suite that RAN writes a proof" \
      "the proof does not record the verdict: $(tr '\n' ' ' < "$PROOF" | cut -c1-160)"
else
  ok "S4 a host-screen suite that ran writes a proof naming its commit and its verdict"
fi

# S5 — a silent no-op here would be a green run of nothing, which is this file's subject.
OUT="$(bash "$SBOX/run-tests.sh" --only nosuchsuite.test.sh 2>&1)"; CODE=$?
expect "S5 --only with a name that matches nothing is refused" 2 "names no suite under"

# S6 — THE REAL INVENTORY, not a fixture. A fixture proving the classifier works says
# nothing about whether THIS directory is classified correctly, and the cost of being wrong
# is a window on the operator's Mac. The same reason make-engine-asset.test.sh's L9-L18 run
# against the real tree after L1-L8 have run against a synthetic one.
SCAN_MISSING=""
for real in "$DIR"/*.test.sh; do
  grep -vE '^[[:space:]]*#' "$real" \
    | grep -qE '(^|[[:space:]]|\()(open|osascript)[[:space:]]|/Contents/MacOS/|\$GUI_BINARY|target/(debug|release)/richos-tauri' \
    || continue
  grep -q 'lib/gui-launch\.sh' "$real" && continue
  grep -q '^# run-tests: host-screen' "$real" && continue
  if ! grep -qE '^# run-tests: no-host-screen:[[:space:]]*[^[:space:]]' "$real"; then
    SCAN_MISSING="$SCAN_MISSING $(basename "$real")"
  fi
done
if [ -n "$SCAN_MISSING" ]; then
  bad "S6 every real suite that could open a window is classified or declares itself inert" \
      "undeclared:$SCAN_MISSING — each must either source lib/gui-launch.sh (and so be held \
back by --no-host-screen) or carry '# run-tests: no-host-screen: <why its matches open \
nothing>'. A bare marker declares nothing, and neither does silence."
else
  ok "S6 every suite in the real inventory that could open a window is classified or declared inert"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== run-tests.test.sh: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== run-tests tests: all $PASS passed ==="
