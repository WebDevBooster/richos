#!/usr/bin/env bash
# The RichOS native iPhone app on a simulator: the XcodeGen project generates, the Debug app builds,
# installs and launches on a simulator THIS SUITE CREATES, the development bridge returns the same
# semantic state as the headless core (byte for byte), state survives a real process restart,
# Release carries no development code, and the simulator is shut down at the end
# (build plan §3.1 loop L2; stream I1). Missing macOS/Xcode/XcodeGen/an iOS runtime/the external SSD
# is NOT RUN, exit 2; a build or check failure on a capable host is red.
# run-tests: no-host-screen: `simctl boot` starts a dedicated simulator without Simulator.app; screenshots come from `simctl io`, never the Mac's screen
# run-tests: inputs richos/app/scripts/lib/simulator_budget.py richos/engine/scripts/lib/worker_tokens.py richos/mobile/native-ios richos/app/scripts/native-ios-app.test.sh richos/engine/scripts/lib/proc_tree.py richos/engine/scripts/lib/testdevices.py richos/app/scripts/testvm/reserve.py
# run-tests: covers richos/mobile/native-ios/project.yml richos/mobile/native-ios/App/App/AppStore.swift richos/mobile/native-ios/App/App/RichOSNativeApp.swift richos/mobile/native-ios/App/App/ShareIntake.swift richos/mobile/native-ios/DevBridge/DevBridge.swift richos/mobile/native-ios/Core/Sources/RichOSCLI/Simulator.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/URLSessionTransport.swift
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
python3 "$ROOT/richos/engine/scripts/lib/cpu_guard.py" check-ios || exit 2
if [ -z "${RICHOS_WORKER_TOKENS:-}" ]; then
  exec python3 "$ROOT/richos/engine/scripts/lib/worker_tokens.py" machine -- bash "${BASH_SOURCE[0]}" "$@"
fi
NATIVE="$ROOT/richos/mobile/native-ios"
RIOS="$NATIVE/bin/rios"
VOLUME=/Volumes/E1TB

notrun() { echo "  NOT RUN  native-ios-app: $1"; exit 2; }
[ "$(uname -s)" = Darwin ] || notrun "macOS is required"
for tool in xcodebuild xcodegen swift xcrun python3; do
  command -v "$tool" >/dev/null 2>&1 || notrun "$tool is unavailable"
done
if [ ! -d "$VOLUME" ] || [ "$(stat -f %d "$VOLUME")" = "$(stat -f %d /Volumes)" ]; then notrun "/Volumes/E1TB is not mounted"; fi
xcrun simctl list runtimes 2>/dev/null | grep -q '^iOS .*com.apple.CoreSimulator.SimRuntime.iOS' || notrun "no iOS simulator runtime is installed"

# Build caches are reused per checkout (a cold app build is minutes); the prepared simulator OS is reused, exclusively leased and shut down after each run.
KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-10)"
export RICHOS_NATIVE_IOS_CACHE="$VOLUME/caches/richos-native-ios-proof/$KEY-app"
if [ "${RICHOS_SIMULATOR_CACHE_HELD:-}" != "$RICHOS_NATIVE_IOS_CACHE" ]; then
  exec python3 "$DIR/lib/simulator_budget.py" cache "$RICHOS_NATIVE_IOS_CACHE" -- bash "${BASH_SOURCE[0]}" "$@"
fi
SCRATCH="$(mktemp -d "$VOLUME/tmp/native-ios-app.XXXXXX")" || { echo '  FAIL  scratch directory'; exit 1; }
# However the run ends: the simulator is shut down, and the scratch removed.
trap '"$RIOS" sim stop >"$SCRATCH/stop.json" 2>&1 || true; rm -rf "$SCRATCH"' EXIT HUP INT TERM
# A simulator left recorded by a run that was killed before its trap is stopped first.
"$RIOS" sim stop >/dev/null 2>&1 || true
# Every simulator generation is registered by rios before it boots.
export RICHOS_TEST_DEVICE_OWNER_PID=$$

PASS=0; FAILED=0
ok()  { PASS=$((PASS + 1)); echo "  ok  $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

echo "=== native-ios-app ==="

# A1 — generate, build, create and boot a simulator, install, launch straight into a fixture.
if "$RIOS" sim prepare conv-empty >"$SCRATCH/prepare.json" 2>"$SCRATCH/err"; then
  if [ "$(json 'd["result"]["state"]["screen"]' < "$SCRATCH/prepare.json")" = conv-empty ]; then
    ok "A1 the Debug app builds, installs on a prepared simulator and answers in fixture conv-empty ($(json 'd["result"]["timingsMs"]' < "$SCRATCH/prepare.json"))"
  else bad "A1 prepare" "state: $(head -c 300 "$SCRATCH/prepare.json")"; fi
else
  bad "A1 prepare" "$(tail -c 600 "$SCRATCH/err")"
  echo "=== native-ios-app tests: $FAILED FAILED, $PASS passed (later cases need a running app) ==="
  exit 1
fi
UDID="$(json 'd["result"]["device"]' < "$SCRATCH/prepare.json")"

# A2: the shared prepared device is recorded by exact UDID and owned by this run.
if python3 - "$ROOT" "$UDID" "$$" <<'PY_CHECK'
import sys
sys.path.insert(0, sys.argv[1] + '/richos/engine/scripts/lib')
import testdevices as d
r = d._read_json(d._record_path('ios-simulator', sys.argv[2])) or {}
assert r.get('prepared') and r['owner']['pid'] == int(sys.argv[3])
PY_CHECK
then ok "A2 the app uses this run's exclusive prepared simulator ($UDID)"
else bad "A2 prepared simulator ownership"; fi

# A3 — headless and native agree byte for byte on every scenario; state survives a real relaunch.
if "$RIOS" sim verify >"$SCRATCH/verify.json" 2>"$SCRATCH/err"; then
  if [ "$(json 'd["result"]["processRestartPreservedState"] and all(s["identical"] for s in d["result"]["scenarios"])' < "$SCRATCH/verify.json")" = True ]; then
    ok "A3 simulator and headless results are identical; state survives a real process restart"
  else bad "A3 verify" "$(head -c 400 "$SCRATCH/verify.json")"; fi
else bad "A3 verify" "$(tail -c 800 "$SCRATCH/err")"; fi

# A4 — a fixture and an action through the bridge land on the screen the core derives.
if "$RIOS" sim fixture pair-words >/dev/null 2>"$SCRATCH/err" \
   && "$RIOS" sim action '{"type":"set-appearance","appearance":"light"}' >"$SCRATCH/action.json" 2>>"$SCRATCH/err" \
   && [ "$(json 'd["result"]["state"]["screen"] + "|" + d["result"]["state"]["appearance"]' < "$SCRATCH/action.json")" = "pair-words|light" ]; then
  ok "A4 fixture and action commands reach the running app"
else bad "A4 fixture and action through the bridge" "$(tail -c 400 "$SCRATCH/err")"; fi

# A5 — a screenshot of the simulator's own framebuffer (never the Mac's screen), at iPhone 16 Pro size.
if "$RIOS" sim screenshot "$SCRATCH/shot.png" >/dev/null 2>"$SCRATCH/err"; then
  W="$(sips -g pixelWidth "$SCRATCH/shot.png" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
  H="$(sips -g pixelHeight "$SCRATCH/shot.png" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
  if [ "$W" = 1206 ] && [ "$H" = 2622 ]; then ok "A5 screenshot captured from the simulator at 1206 x 2622 (402 x 874 pt at 3x)"
  else bad "A5 screenshot size" "got ${W:-?} x ${H:-?}"; fi
else bad "A5 screenshot" "$(tail -c 400 "$SCRATCH/err")"; fi

# A6 — the two names the CLI and the app must share are spelled the same in both.
A6_BAD=""
for name in rios-commands rios-fixture rios-appearance; do
  grep -q "\"$name\"" "$NATIVE/DevBridge/DevBridge.swift" && grep -q "\"$name\"" "$NATIVE/Core/Sources/RichOSCLI/Simulator.swift" \
    || A6_BAD="$A6_BAD $name"
done
if [ -z "$A6_BAD" ]; then ok "A6 the bridge's directory and launch-argument names agree between app and CLI"
else bad "A6 bridge names agree between DevBridge.swift and Simulator.swift" "differ:$A6_BAD"; fi

# A7 — Release carries none of the development markers the Debug binary carries.
if "$RIOS" sim check-release >"$SCRATCH/release.json" 2>"$SCRATCH/err"; then
  ok "A7 Release excludes the bridge and fixtures: $(json '", ".join(d["result"]["markersAbsentFromRelease"])' < "$SCRATCH/release.json")"
else bad "A7 check-release" "$(tail -c 600 "$SCRATCH/err")"; fi

# A8 — visible-control UI tests and app unit tests, once the screens stream has written them, on
# the MIDDLE screen size (iPhone 16 Pro). ONLY BEFORE NIGHTLIES (CEO, 2026-09-23, "Only before
# nightlies", esc-20260923T113632Z-746305fb): native-ios-ui.test.sh runs the same 42 tests on the
# smallest and largest sizes on every land, and this third size costs about ten minutes, so it
# runs when the nightly build's script-suites gate sets RICHOS_NATIVE_IOS_APP_A8=1
# (nightly-local.py, `gates`), where a failure stops that nightly. Anywhere else it says NOT RUN
# and why; set the variable to run it by hand.
if [ "${RICHOS_NATIVE_IOS_APP_A8:-}" != 1 ]; then
  echo "  NOT RUN  A8 UI tests on the middle iPhone size: they run before each nightly (CEO 2026-09-23, \"Only before nightlies\"); RICHOS_NATIVE_IOS_APP_A8=1 runs them here"
elif find "$NATIVE/UITests" "$NATIVE/UnitTests" -name '*.swift' 2>/dev/null | grep -q .; then
  touch "$SCRATCH/a8.start"; A8_SINCE=$(( $(date +%s) - 1 ))
  if "$RIOS" sim ui-test >"$SCRATCH/ui.json" 2>"$SCRATCH/err"; then
    ok "A8 UI tests: $(json 'd["result"]["tests"]' < "$SCRATCH/ui.json")"
  else
    bad "A8 UI tests" "$(tail -c 600 "$SCRATCH/err")"
    # Every failing test by name, and this run's result bundle and log moved to the run's
    # results (lib/test_results.py). The bundle is this run's alone (`ui-<time>.xcresult`); the
    # log is logs/ui-test.log, which the next A8 run of this cache replaces.
    KEEP=(--collect "ui-test.log=$RICHOS_NATIVE_IOS_CACHE/logs/ui-test.log")
    for b in "$RICHOS_NATIVE_IOS_CACHE"/results/ui-*.xcresult; do
      [ -d "$b" ] && [ "$b" -nt "$SCRATCH/a8.start" ] && KEEP+=(--move "$(basename "$b")=$b")
    done
    python3 "$DIR/lib/test_results.py" report --label "native-ios-app A8" --since "$A8_SINCE" \
      ${RICHOS_TEST_RESULTS_DIR:+--into "$RICHOS_TEST_RESULTS_DIR"} "${KEEP[@]}"
  fi
else
  echo "  NOT RUN  A8 UI tests: UITests/ and UnitTests/ have no test files yet (stream I2 writes them)"
fi

# Z: shutdown releases the lease and retains the OS for the next proof.
if "$RIOS" sim stop >"$SCRATCH/stop.json" 2>"$SCRATCH/err" &&
   xcrun simctl list devices | grep -F "$UDID" | grep -q Shutdown; then
  ok "Z the simulator $UDID was shut down and retained for reuse"
else bad "Z the prepared simulator was shut down"; fi

if [ "$FAILED" -eq 0 ]; then
  echo "=== native-ios-app tests: all $PASS passed ==="
  exit 0
fi
echo "=== native-ios-app tests: $FAILED FAILED, $PASS passed ==="
exit 1
