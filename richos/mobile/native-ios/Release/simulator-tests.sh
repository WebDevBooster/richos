#!/usr/bin/env bash
# Stream I3's tests on a simulator (target RichOSPlatformTests): the Share to Rich sheet's model
# and rendering, the platform effect handler, the notification platform.
#
#   Release/simulator-tests.sh <output directory on /Volumes/E1TB>
#
# Creates ONE simulator of its own, boots it with `simctl boot` (no Simulator.app, nothing on the
# Mac's screen), grants the microphone to the host app as I2's UI tests do, runs the tests, and shuts
# the simulator down and deletes it however the run ends. It never uses `booted`. The share sheet's
# rendered states are written to <output>/snapshots/*.png. Prints the xcresult counts and exits 0
# only when every test passed and at least one ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: simulator-tests.sh <output directory>}"
case "$OUT" in /Volumes/E1TB/*) ;; *) echo "simulator-tests: the output directory must be on /Volumes/E1TB" >&2; exit 2 ;; esac
mkdir -p "$OUT/logs"
rm -rf "$OUT/snapshots" "$OUT/result.xcresult"

PROJECT="$("$HERE/Release/generate.sh" "$OUT/project")" || { echo "FAIL generate"; exit 1; }
RUNTIME="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["name"].startswith("iOS")]; print(r[-1]["identifier"] if r else "")')"
[ -n "$RUNTIME" ] || { echo "NOT RUN no iOS simulator runtime"; exit 2; }
UDID="$(xcrun simctl create "RichOS native-ios platform-tests $(basename "$OUT")" "iPhone 16 Pro" "$RUNTIME")" || { echo "FAIL simctl create"; exit 1; }
cleanup() {
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
# A run killed before its trap leaves this simulator behind; registering it with this shell's pid lets
# the engine remove it once this shell is gone (richos/engine/scripts/lib/testdevices.py, §54).
python3 "$HERE/../../engine/scripts/lib/testdevices.py" register --kind ios-simulator --id "$UDID" \
  --owner-pid $$ --script simulator-tests.sh >/dev/null || { echo "FAIL device ownership registration" >&2; exit 1; }

xcrun simctl boot "$UDID" && xcrun simctl bootstatus "$UDID" -b >/dev/null || { echo "FAIL simctl boot $UDID"; exit 1; }
xcrun simctl privacy "$UDID" grant microphone dev.richos.native.ios >/dev/null 2>&1 || true

TEST_RUNNER_RICHOS_SNAPSHOT_DIR="$OUT/snapshots" xcodebuild test -project "$PROJECT" -scheme RichOSPlatformTests \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$OUT/DerivedData" \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" -resultBundlePath "$OUT/result.xcresult" \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- >"$OUT/logs/test.log" 2>&1
CODE=$?

SUMMARY="$(xcrun xcresulttool get test-results summary --path "$OUT/result.xcresult" 2>/dev/null)"
COUNTS="$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("0 0 0"); sys.exit()
print(d.get("totalTestCount",0), d.get("passedTests",0), d.get("failedTests",0))')"
read -r TOTAL PASSED FAILED <<<"$COUNTS"
SHOTS="$(find "$OUT/snapshots" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
echo "simulator tests: $PASSED passed, $FAILED failed of $TOTAL; $SHOTS share-sheet snapshots in $OUT/snapshots; device $UDID (deleted on exit)"
if [ "$CODE" -ne 0 ] || [ "${TOTAL:-0}" -eq 0 ] || [ "${FAILED:-1}" -ne 0 ]; then
  grep -E 'error:|failed|XCTAssert' "$OUT/logs/test.log" | head -20
  echo "FAIL full log $OUT/logs/test.log"
  exit 1
fi
