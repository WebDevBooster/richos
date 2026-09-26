#!/usr/bin/env bash
#
# test-results.test.sh — a failing test is always named, and a later run cannot erase it.
#
# THE INCIDENT THIS HOLDS TO ACCOUNT (2026-09-25). A proof run's `native-android-app` failed with
# "133 tests completed, 1 failed" and named no test; the one report that did lived in the
# checkout's Gradle build folder, and `native-android-ui`, the next suite of the same run (same
# task, same folder), replaced it with 139 passes before anyone read it. The CEO: "are you
# shitting me?? what now???"
#
# So the fixture here is that incident, small: two fake suites whose fake Gradle writes ONE
# shared results folder, the first failing and the second passing over it, run through the real
# `run-tests.sh` and the real `proof-run.py`. The first suite's failing test must still be named,
# and its result file must still exist, after the second has replaced the shared folder.
#
# CASES
#   N1-N7  lib/test_results.py reads JUnit XML, an Xcode bundle (through a stand-in
#          xcresulttool), test logs, an engine shard's log, and an unreadable result file, and
#          names each failure; and the last error of a check that died before any test ran
#   L1     two test runs on one lock and one shared folder, overlapping: each run's copy holds
#          its own result, and the second waited for the first
#   R1-R5  the incident through run-tests.sh, serial and concurrent: named in the summary and in
#          --results-out, the result file kept, the shared folder really overwritten, the kept
#          store bounded; a suite with no test named by its last error
#   P1-P2  the same through proof-run.py: named beside the check and in summary.json, the
#          result file in the run's own log directory, nothing left for the suite that passed
#   M1-M4  MUTATIONS, each of which this file must catch: the fake Gradle called directly (the
#          shape before the fix), the copy removed, the lock removed, and run-tests.sh no
#          longer giving a suite its own folder
#
# run-tests: no-host-screen: fake suites and fake Gradle runs that write files under mktemp; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/test-results.test.sh richos/app/scripts/lib/test_results.py richos/app/scripts/run-tests.sh richos/app/scripts/lib/worktree-resource.sh richos/app/scripts/proof-run.py
# run-tests: covers richos/app/scripts/lib/test_results.py
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEPER="$DIR/lib/test_results.py"
TMP="$(mktemp -d -t test-results-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
unset RICHOS_TEST_RESULTS_ROOT RICHOS_TEST_RESULTS_DIR
export RUN_TESTS_JOBS=1

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
has() { grep -Fq -- "$2" <<<"$1"; }   # a here-string, never `printf | grep -q` under pipefail
entries() { find "$1" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | LC_ALL=C sort; }
# The overlapping cases start the second run once the first has written the shared folder, so
# their order is the incident's on a loaded Mac too; the first then holds it for 3 s.
wait_for() { local n=0; while [ ! -e "$1" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done; }

NAME="dev.fake.AppTest > a draft survives a restart"

echo "=== test-results ==="

# ------------------------------------------------------------------------------------------
# N: the readers
# ------------------------------------------------------------------------------------------
mkdir -p "$TMP/n/xml"
cat > "$TMP/n/xml/TEST-dev.fake.AppTest.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="dev.fake.AppTest" tests="3" failures="1" errors="1">
  <testcase name="a draft survives a restart" classname="dev.fake.AppTest" time="0.1">
    <failure message="java.lang.AssertionError: expected:&lt;1&gt; but was:&lt;2&gt;" type="java.lang.AssertionError">java.lang.AssertionError
	at org.junit.Assert.fail(Assert.java:89)</failure>
  </testcase>
  <testcase name="passes" classname="dev.fake.AppTest" time="0.1"/>
  <testcase name="throws" classname="dev.fake.AppTest" time="0.1"><error message="IllegalStateException: no store" type="x"/></testcase>
</testsuite>
XML
out="$(python3 "$KEEPER" names "$TMP/n/xml")"
if has "$out" "  FAILED TEST  $NAME — java.lang.AssertionError: expected:<1> but was:<2>" \
   && has "$out" "  FAILED TEST  dev.fake.AppTest > throws — IllegalStateException: no store" \
   && ! has "$out" "passes"; then
  ok "N1 JUnit XML: a <failure> and an <error> are named, class > test — message; a pass is not"
else bad "N1 JUnit XML failures named" "$out"; fi

# A stand-in for `xcrun xcresulttool`, printing the shape Xcode 26.3 printed for a real bundle of
# native-ios-ui (read 2026-09-25 from a retained run: testFailures with targetName and
# testIdentifierString).
cat > "$TMP/n/xcresulttool" <<'SH'
#!/usr/bin/env bash
case "$*" in *broken.xcresult*) echo "Error: Info.plist does not exist" >&2; exit 64 ;; esac
cat <<'JSON'
{"failedTests": 1, "passedTests": 63, "result": "Failed",
 "testFailures": [{"failureText": "Test crashed with signal term.", "targetName": "RichOSNativeUITests",
                   "testIdentifierString": "ScreenshotTests/testComposerDark()", "testName": "testComposerDark()"}]}
JSON
SH
chmod +x "$TMP/n/xcresulttool"
mkdir -p "$TMP/n/run/result-0.xcresult" "$TMP/n/run/broken.xcresult"
out="$(RICHOS_XCRESULTTOOL="$TMP/n/xcresulttool" python3 "$KEEPER" names "$TMP/n/run/result-0.xcresult")"
if has "$out" "  FAILED TEST  RichOSNativeUITests.ScreenshotTests > testComposerDark() — Test crashed with signal term."; then
  ok "N2 an Xcode result bundle: its failures are named, target.suite > test() — message"
else bad "N2 xcresult failures named" "$out"; fi

cat > "$TMP/n/test.log" <<'LOG'
Test Case '-[RichOSCoreTests.PairingTests testWordsMatch]' failed (0.004 seconds).
✘ Test draftSurvivesRestart() failed after 0.002 seconds with 1 issue.
dev.fake.CoreTest > the outbox drains FAILED
Test Case '-[RichOSCoreTests.PairingTests testPasses]' passed (0.001 seconds).
FAIL: test_sigkill_owner_cleans_up (__main__.Reliability.test_sigkill_owner_cleans_up)
ERROR: test_boots (runner.Tests)
test phone::rows::keeps_order ... FAILED
test phone::rows::passes ... ok
not ok 3 - the share inbox delivers
ok 4 - the share inbox passes
LOG
out="$(python3 "$KEEPER" names --log "$TMP/n/test.log")"
if has "$out" "RichOSCoreTests.PairingTests > testWordsMatch" && has "$out" "draftSurvivesRestart()" \
   && has "$out" "dev.fake.CoreTest > the outbox drains" && ! has "$out" "testPasses" \
   && has "$out" "  FAILED TEST  __main__.Reliability > test_sigkill_owner_cleans_up" \
   && has "$out" "  FAILED TEST  runner.Tests > test_boots" \
   && has "$out" "  FAILED TEST  phone::rows::keeps_order" && has "$out" "  FAILED TEST  the share inbox delivers" \
   && ! has "$out" "passes"; then
  ok "N3 a test log (XCTest, swift-testing, Gradle, unittest, cargo, node TAP): each failed test named, a pass not"
else bad "N3 log failures named" "$out"; fi

out="$(python3 "$KEEPER" names --log "$TMP/n/test.log" "$TMP/n/xml")"
if has "$out" "$NAME" && ! has "$out" "testWordsMatch"; then
  ok "N4 the result files are the ground truth: the log is read only when they name nothing"
else bad "N4 result files outrank the log" "$out"; fi

printf '<testsuite><testcase name="x"' > "$TMP/n/run/TEST-cut.xml"
out="$(RICHOS_XCRESULTTOOL="$TMP/n/xcresulttool" python3 "$KEEPER" names --log "$TMP/n/test.log" \
       "$TMP/n/run/TEST-cut.xml" "$TMP/n/run/broken.xcresult")"
if has "$out" "unreadable result file $TMP/n/run/TEST-cut.xml" && has "$out" "unreadable result bundle $TMP/n/run/broken.xcresult" \
   && has "$out" "testWordsMatch"; then
  ok "N5 a result file that cannot be read is reported by path, and the log still names the tests"
else bad "N5 unreadable result files reported, log still read" "$out"; fi

# An engine shard's log, in ci-shard.sh's own shape (colored, as a proof run's log is): each failed
# unit named with its reason, a passed unit and the canary's detail lines not.
E=$'\033'
cat > "$TMP/n/shard.log" <<LOG
=== ci-shard: 3 unit(s), shard 3/5 at 0000000 ===
  [  1/  3] scripts/hooks/contract-integrity.test.sh:MC     ${E}[32mPASS${E}[0m 94.8s
  [  2/  3] scripts/hooks/contract-integrity.test.sh:SCR    ${E}[31mFAIL${E}[0m 901.6s — touched the operator's record
        TOUCHED THE OPERATOR'S RECORD — the class that wrote a false termination:
          workspace registry entry APPEARED: events.jsonl 1cb77d2cf8199354 event=end key=x
  [  3/  3] scripts/lib/git-jurisdiction.test.sh            FAIL 3.1s (rc=1, expected 0)

${E}[31m✗ ci-shard shard 3/5: 1/3 unit(s) passed, 2 FAILED.${E}[0m
LOG
out="$(python3 "$KEEPER" names --log "$TMP/n/shard.log")"
if has "$out" "  FAILED TEST  scripts/hooks/contract-integrity.test.sh:SCR — touched the operator's record" \
   && has "$out" "  FAILED TEST  scripts/lib/git-jurisdiction.test.sh — (rc=1, expected 0)" \
   && ! has "$out" ":MC" && ! has "$out" "APPEARED" && [ "$(grep -c 'FAILED TEST' <<<"$out")" -eq 2 ]; then
  ok "N7 an engine shard's log (ci-shard.sh): each failed unit named with its reason, a pass and the canary's detail not"
else bad "N7 ci-shard failures named" "$out"; fi

printf '%s\n' 'Traceback (most recent call last):' '  File "testdevices.py", line 1241, in acquire_ios' \
  'TimeoutError: prepared simulator is leased by another run' 'native-ios-ui: failure evidence retained' > "$TMP/n/died.log"
out="$(python3 "$KEEPER" last-error "$TMP/n/died.log")"
if [ "$out" = "TimeoutError: prepared simulator is leased by another run" ] \
   && [ -z "$(python3 "$KEEPER" last-error "$TMP/n/xml/TEST-dev.fake.AppTest.xml.none" 2>/dev/null)" ]; then
  ok "N6 a check that died before any test ran: its last error line is read back, exactly"
else bad "N6 last-error" "$out"; fi

# ------------------------------------------------------------------------------------------
# The fixture: a fake Gradle that owns ONE results folder, as bin/randroid's test tasks do,
# and a fake randroid that runs it the way randroid now does (through test_results.py run).
# ------------------------------------------------------------------------------------------
make_box() {  # make_box <dir> [keeper]  — a scratch copy of the harness, its libraries, two suites
  local box="$1" keeper="${2:-$KEEPER}"
  mkdir -p "$box/scripts/lib"
  cp "$DIR/run-tests.sh" "$box/scripts/run-tests.sh"
  cp "$DIR/lib/worktree-resource.sh" "$box/scripts/lib/worktree-resource.sh"
  cp "$keeper" "$box/scripts/lib/test_results.py"
  cat > "$box/scripts/fake-gradle.sh" <<'SH'
# fake-gradle.sh <shared> <pass|fail> <seconds to hold the folder> — clears its one results
# folder and writes this run's JUnit XML there, as Gradle's test task does under $OUT.
shared="$1"; verdict="$2"
rm -rf "$shared/xml"; mkdir -p "$shared/xml"
if [ "$verdict" = fail ]; then
  printf '%s\n' '<testsuite name="dev.fake.AppTest" tests="2" failures="1">' \
    '<testcase name="a draft survives a restart" classname="dev.fake.AppTest"><failure message="expected 1 but was 2">AssertionError</failure></testcase>' \
    '<testcase name="passes" classname="dev.fake.AppTest"/></testsuite>' > "$shared/xml/TEST-dev.fake.AppTest.xml"
else
  printf '%s\n' '<testsuite name="dev.fake.UiTest" tests="139" failures="0">' \
    '<testcase name="every screen" classname="dev.fake.UiTest"/></testsuite>' > "$shared/xml/TEST-dev.fake.UiTest.xml"
fi
sleep "${3:-0}"
echo "$([ "$verdict" = fail ] && echo '2 tests completed, 1 failed' || echo 'BUILD SUCCESSFUL')"
[ "$verdict" = pass ]
SH
  cat > "$box/scripts/fake-randroid.sh" <<'SH'
# fake-randroid.sh <shared> <pass|fail> <seconds> — `randroid test`: before the fix it ran Gradle
# directly (FAKE_DIRECT=1); now through test_results.py run, as bin/randroid does.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${FAKE_DIRECT:-}" = 1 ]; then exec bash "$here/fake-gradle.sh" "$@"; fi
exec python3 "$here/lib/test_results.py" run --lock "$1/test-results.lock" --label "fake randroid test" \
  ${RICHOS_TEST_RESULTS_DIR:+--into "$RICHOS_TEST_RESULTS_DIR"} --collect "app-xml=$1/xml" -- \
  bash "$here/fake-gradle.sh" "$@"
SH
  fake_suite "$box" a fail "${FAKE_HOLD:-0}"
  fake_suite "$box" b pass 0
}

fake_suite() {  # fake_suite <box> <name> <pass|fail> <seconds>
  cat > "$1/scripts/$2.test.sh" <<SH
#!/usr/bin/env bash
# A fake suite that drives the one Gradle project (bin/randroid), like native-android-app/-ui.
# run-tests: no-host-screen: fixture files only
here="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# R2 starts b only once a's run has written the shared folder, so the order is the incident's
# on a loaded Mac too, not whichever process happened to start first.
if [ "$2" = b ] && [ -n "\${FAKE_WAIT_FOR:-}" ]; then
  n=0; while [ ! -e "\$FAKE_WAIT_FOR" ] && [ "\$n" -lt 300 ]; do sleep 0.1; n=\$((n + 1)); done
fi
bash "\$here/fake-randroid.sh" "\$FAKE_SHARED" $3 $4 || { echo "  FAIL  $2: Robolectric tests exited 1"; exit 1; }
echo "=== $2: all 1 passed ==="
SH
}

# run_box <box> [run-tests args] — the incident: a fails into the shared folder, b passes over it
run_box() {
  local box="$1"; shift
  rm -rf "$box/shared" "$box/kept"
  mkdir -p "$box/shared"
  FAKE_SHARED="$box/shared" RUN_TESTS_RESULTS_STATE="$box/kept" \
    bash "$box/scripts/run-tests.sh" --results-out "$box/results.json" "$@" > "$box/out" 2>&1
  echo $? > "$box/rc"
}
kept_xml() { grep -rl '<failure' "$1/kept" 2>/dev/null | head -1; }

# ------------------------------------------------------------------------------------------
# L1: two test runs, one lock, one folder, overlapping in time
# ------------------------------------------------------------------------------------------
make_box "$TMP/l"
mkdir -p "$TMP/l/shared"
( RICHOS_TEST_RESULTS_DIR="$TMP/l/first" bash "$TMP/l/scripts/fake-randroid.sh" "$TMP/l/shared" fail 3 \
    > "$TMP/l/first.out" 2>&1 ) &
first=$!
wait_for "$TMP/l/shared/xml/TEST-dev.fake.AppTest.xml"
RICHOS_TEST_RESULTS_DIR="$TMP/l/second" bash "$TMP/l/scripts/fake-randroid.sh" "$TMP/l/shared" pass 0 > "$TMP/l/second.out" 2>&1
wait "$first"
if grep -q '<failure' "$TMP/l/first/app-xml/TEST-dev.fake.AppTest.xml" 2>/dev/null \
   && [ -f "$TMP/l/second/app-xml/TEST-dev.fake.UiTest.xml" ] && [ ! -e "$TMP/l/second/app-xml/TEST-dev.fake.AppTest.xml" ] \
   && grep -q 'waiting for another test run' "$TMP/l/second.out" \
   && grep -qF "  FAILED TEST  $NAME" "$TMP/l/first.out"; then
  ok "L1 an overlapping second run waited on the lock; each copy holds only its own run's result"
else bad "L1 one lock, one folder, two overlapping runs" "$(cat "$TMP/l/first.out" "$TMP/l/second.out" | tail -8)"; fi

# ------------------------------------------------------------------------------------------
# R: the incident through run-tests.sh
# ------------------------------------------------------------------------------------------
check_incident() {  # check_incident <box> <case> <what>
  local box="$1" out summary
  out="$(cat "$box/out")"
  summary="$(tail -4 <<<"$out")"
  if [ "$(cat "$box/rc")" = 1 ] && has "$summary" "a.test.sh:   FAILED TEST  " ; then
    bad "$2 $3" "the summary carries the marker, not the name: $summary"; return
  fi
  if [ "$(cat "$box/rc")" = 1 ] && has "$summary" "a.test.sh: $NAME" \
     && has "$summary" "suite(s) FAILED: a.test.sh"; then
    ok "$2 $3: the summary names it beside the suite"
  else bad "$2 $3: named in the summary" "exit $(cat "$box/rc"); $summary"; fi
  if [ -n "$(kept_xml "$box")" ] && grep -q '<testcase name="every screen"' "$box/shared/xml/TEST-dev.fake.UiTest.xml" 2>/dev/null \
     && [ ! -e "$box/shared/xml/TEST-dev.fake.AppTest.xml" ]; then
    ok "$2 ...and a's result file is kept though b really replaced the shared folder"
  else bad "$2 a's result file kept after b replaced the shared folder" "kept: $(entries "$box/kept")"; fi
  if python3 - "$box/results.json" "$NAME" <<'PY'
import json, sys
suites = {s["name"]: s for s in json.load(open(sys.argv[1]))["suites"]}
assert any(sys.argv[2] in f for f in suites["a.test.sh"]["failing_tests"]), suites
assert "failing_tests" not in suites["b.test.sh"], suites
PY
  then ok "$2 ...and --results-out lists it under a, and nothing under b"
  else bad "$2 --results-out failing_tests" "$(cat "$box/results.json" 2>&1 | head -20)"; fi
}

make_box "$TMP/r"
run_box "$TMP/r"
check_incident "$TMP/r" R1 "serial: a fails into the shared folder, b passes over it"

FAKE_HOLD=3 make_box "$TMP/rc"
FAKE_WAIT_FOR="$TMP/rc/shared/xml/TEST-dev.fake.AppTest.xml" run_box "$TMP/rc" --jobs 2
check_incident "$TMP/rc" R2 "concurrent: b starts while a still holds the folder"

kept_list="$(entries "$TMP/r/kept")"
if [ -n "$kept_list" ] && [ "$(wc -l <<<"$kept_list" | tr -d ' ')" = 1 ] && [[ "$kept_list" == *Z-a-* ]]; then
  ok "R3 only the failed suite's folder is kept; the passing suite leaves nothing"
else bad "R3 only the failed suite's folder is kept" "$(entries "$TMP/r/kept")"; fi

make_box "$TMP/rk"
for n in $(seq 1 12); do mkdir -p "$TMP/rk/old/20260101T0000$(printf '%02d' "$n")Z-a-1"; done
rm -rf "$TMP/rk/shared"; mkdir -p "$TMP/rk/shared"
FAKE_SHARED="$TMP/rk/shared" RUN_TESTS_RESULTS_STATE="$TMP/rk/old" bash "$TMP/rk/scripts/run-tests.sh" --only a.test.sh >/dev/null 2>&1
left="$(entries "$TMP/rk/old" | wc -l | tr -d ' ')"
if [ "$left" = 10 ] && grep -rq '<failure' "$TMP/rk/old" 2>/dev/null && [ ! -e "$TMP/rk/old/20260101T000001Z-a-1" ]; then
  ok "R4 the store of kept results is bounded: the newest 10 folders, the oldest deleted (§54)"
else bad "R4 the kept store is bounded at 10" "$left left: $(entries "$TMP/rk/old" | head -3)"; fi

# R5 — a suite that dies before any test runs (the shape native-ios-ui had in this branch's own
# proof run: no simulator lease) is still named by what went wrong, not "named nothing".
make_box "$TMP/rd"
rm -f "$TMP/rd/scripts/a.test.sh" "$TMP/rd/scripts/b.test.sh"
cat > "$TMP/rd/scripts/c.test.sh" <<'SH'
#!/usr/bin/env bash
# run-tests: no-host-screen: fixture output only
echo 'Traceback (most recent call last):'
echo 'TimeoutError: prepared simulator is leased by another run'
exit 1
SH
out="$(RUN_TESTS_RESULTS_STATE="$TMP/rd/kept" bash "$TMP/rd/scripts/run-tests.sh" 2>&1)"
if has "$(tail -3 <<<"$out")" "c.test.sh: (no test ran to fail) TimeoutError: prepared simulator is leased by another run"; then
  ok "R5 a suite that died before any test ran is named by its last error beside it in the summary"
else bad "R5 a suite with no test is named by its last error" "$(tail -4 <<<"$out")"; fi

# ------------------------------------------------------------------------------------------
# P1: the incident through proof-run.py, as Rich runs it (--keep-going; both suites in the
# gradle lane, one after the other). The host sample is stubbed so a busy Mac cannot turn this
# into a queueing test (proof-run.test.py P8 does the same).
# ------------------------------------------------------------------------------------------
make_box "$TMP/p"
mkdir -p "$TMP/p/shared"
echo "cd $TMP/p && scripts/run-tests.sh --only a.test.sh --only b.test.sh" > "$TMP/p/commands"
BOOT="import runpy,sys; sys.path.insert(0, sys.argv[1]); import reserve
reserve.host_sample = lambda: {'cpu_user_percent': 5.0, 'cpu_system_percent': 2.0, 'cpu_idle_percent': 93.0, 'swapout_mb_per_s': 0.0, 'memory_pressure': 'normal', 'memory_free_percent': 80, 'swap_used_mb': 0.0}
sys.argv = [sys.argv[2]] + sys.argv[3:]
runpy.run_path(sys.argv[0], run_name='__main__')"
# RICHOS_RUNTIME_DIR is named so the runner does not verify the nightly's runtime for two fake
# suites, and RICHOS_MACHINE_WORKERS so they do not queue behind the Mac's real workers
# (proof-run.test.py does the same); proof-run.py refuses to run on a Mac without the external
# SSD, and says so.
FAKE_SHARED="$TMP/p/shared" RICHOS_PROOF_RUN_DIR="$TMP/p/state" RICHOS_RUNTIME_DIR="$TMP/p/no-runtime" \
  RICHOS_MACHINE_WORKERS="$TMP/p/machine" \
  python3 -c "$BOOT" "$DIR/testvm" "$DIR/proof-run.py" --keep-going --commands "$TMP/p/commands" \
  --log-dir "$TMP/p/log" > "$TMP/p/out" 2>&1
prc=$?
if [ "$(uname -s)" = Darwin ] && ! python3 -c 'import os,sys; sys.exit(0 if os.path.ismount("/Volumes/E1TB") else 1)'; then
  echo "  NOT RUN  P1 proof-run.py needs /Volumes/E1TB on a Mac; R1-R4 hold run-tests.sh to the same fixture"
elif [ "$prc" = 1 ] && python3 - "$TMP/p/log/summary.json" "$NAME" <<'PY'
import json, os, sys
checks = {c["check"]: c for c in json.load(open(sys.argv[1]))["checks"]}
a, b = checks["a"], checks["b"]
assert a["result"] == "failed" and any(sys.argv[2] in f for f in a["failing_tests"]), a
assert a["results"] and a["results"].startswith(os.path.dirname(sys.argv[1])), a
found = [os.path.join(t, f) for t, _d, fs in os.walk(a["results"]) for f in fs if f.endswith(".xml")]
assert any("<failure" in open(f).read() for f in found), found
assert b["result"] == "passed" and b["results"] is None and not b["failing_tests"], b
PY
then
  if grep -qF "failed: $NAME" "$TMP/p/out"; then
    ok "P1 proof-run: a is failed BY NAME beside the check and in summary.json, its result file in the run's own log directory, b left nothing"
  else bad "P1 proof-run prints the name beside the check" "$(tail -12 "$TMP/p/out")"; fi
else bad "P1 proof-run names the failing test and keeps its result file" "exit $prc; $(tail -15 "$TMP/p/out")"; fi

# P2 — R5's suite through proof-run: the check is named by its last error, in summary.json too.
echo "cd $TMP/rd && scripts/run-tests.sh --only c.test.sh" > "$TMP/rd/commands"
RICHOS_PROOF_RUN_DIR="$TMP/rd/state" RICHOS_RUNTIME_DIR="$TMP/rd/no-runtime" RICHOS_MACHINE_WORKERS="$TMP/rd/machine" \
  RUN_TESTS_RESULTS_STATE="$TMP/rd/kept" \
  python3 -c "$BOOT" "$DIR/testvm" "$DIR/proof-run.py" --keep-going --commands "$TMP/rd/commands" \
  --log-dir "$TMP/rd/log" > "$TMP/rd/out" 2>&1
if [ -f "$TMP/rd/log/summary.json" ] && python3 - "$TMP/rd/log/summary.json" <<'PY'
import json, sys
c = {c["check"]: c for c in json.load(open(sys.argv[1]))["checks"]}["c"]
assert c["result"] == "failed", c
assert c["failing_tests"] == ["(no test ran to fail) TimeoutError: prepared simulator is leased by another run"], c
PY
then ok "P2 proof-run: a check that died before any test ran is named by its last error, in summary.json too"
else bad "P2 proof-run names a no-test failure by its last error" "$(tail -8 "$TMP/rd/out")"; fi

# ------------------------------------------------------------------------------------------
# M: mutations. Each is a way to lose the name; each must turn a case above red.
# ------------------------------------------------------------------------------------------
# M1 — the shape before the fix: the fake Gradle run directly, no copy, no name. The incident
# must reproduce, or R1 proves nothing.
make_box "$TMP/m1"
FAKE_DIRECT=1 run_box "$TMP/m1"
if ! grep -qF "$NAME" "$TMP/m1/out" && [ -z "$(kept_xml "$TMP/m1")" ] && [ "$(cat "$TMP/m1/rc")" = 1 ]; then
  ok "M1 before the fix the fixture reproduces the incident: a failed, and no name and no result file survive b"
else bad "M1 the fixture reproduces the incident on the old shape" "$(tail -5 "$TMP/m1/out")"; fi

mutant() {  # mutant <file> <python expression over s> -> a mutated copy of the keeper
  python3 - "$KEEPER" "$1" "$2" <<'PY'
import sys
s = open(sys.argv[1]).read()
t = eval(sys.argv[3], {"s": s})
assert t != s, "the mutation did not apply"
open(sys.argv[2], "w").write(t)
PY
}

# M2 — the copy removed: the name is still printed, but the result file is lost with b's run.
if mutant "$TMP/m2.py" 's.replace("where = keep(into, name, src, move)", "where = src")'; then
  make_box "$TMP/m2" "$TMP/m2.py"
  run_box "$TMP/m2"
  if [ -z "$(kept_xml "$TMP/m2")" ]; then ok "M2 with the copy removed, R1's kept-file check goes red (no result file survives)"
  else bad "M2 the copy mutant is caught" "a result file was kept without the copy"; fi
else bad "M2 mutation applied" "test_results.py no longer has the line M2 mutates"; fi

# M3 — the lock removed: the overlapping second run replaces the first's folder before its copy.
if mutant "$TMP/m3.py" 's.replace("fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)", "pass")'; then
  make_box "$TMP/m3" "$TMP/m3.py"
  mkdir -p "$TMP/m3/shared"
  ( RICHOS_TEST_RESULTS_DIR="$TMP/m3/first" bash "$TMP/m3/scripts/fake-randroid.sh" "$TMP/m3/shared" fail 3 >/dev/null 2>&1 ) &
  first=$!
  wait_for "$TMP/m3/shared/xml/TEST-dev.fake.AppTest.xml"
  RICHOS_TEST_RESULTS_DIR="$TMP/m3/second" bash "$TMP/m3/scripts/fake-randroid.sh" "$TMP/m3/shared" pass 0 >/dev/null 2>&1
  wait "$first"
  if ! grep -q '<failure' "$TMP/m3/first/app-xml/"*.xml 2>/dev/null; then
    ok "M3 with the lock removed, L1 goes red: the second run erased the first's failing result before its copy"
  else bad "M3 the lock mutant is caught" "the first run's failure survived without the lock"; fi
else bad "M3 mutation applied" "test_results.py no longer has the line M3 mutates"; fi

# M4 — run-tests.sh no longer gives each suite its own folder: the name still reaches the
# summary through the log, but no result file is kept.
make_box "$TMP/m4"
python3 - "$TMP/m4/scripts/run-tests.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
t = s.replace('( RICHOS_TEST_RESULTS_DIR="$results" ', '( ')
assert t != s
open(p, "w").write(t)
PY
run_box "$TMP/m4"
if [ -z "$(kept_xml "$TMP/m4")" ] && grep -qF "a.test.sh: $NAME" "$TMP/m4/out"; then
  ok "M4 without a folder per suite, R1's kept-file check goes red (the log still names the test)"
else bad "M4 the per-suite folder mutant is caught" "$(tail -4 "$TMP/m4/out")"; fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== test-results tests: all $PASS passed ==="
  exit 0
fi
echo "=== test-results tests: $FAIL FAILED, $PASS passed ==="
exit 1
