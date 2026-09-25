#!/usr/bin/env bash
# The physical-iPhone check launcher (`rios device build|verify`): its selection, the bounded time
# allowance of a walker's script, the reuse of an earlier build and the APNs signing match. Host-only
# node tests, a second or two: no device, no build, no simulator, no window.
#
# The XCUITest checks it launches (UITests/PhysicalDeviceTests.swift) are NOT claimed here: they run
# only on a physical iPhone, and on a simulator they skip. Their proof is a physical run, recorded
# privately in richos-hq (e.g. docs/verification/2026-09-24-native-acceptance-r1-iphone/).
# run-tests: no-host-screen: node unit tests only; nothing is drawn, captured or pressed
# run-tests: inputs richos/app/scripts/native-ios-physical-tool.test.sh richos/mobile/native-ios/Tools/physical-device.mjs richos/mobile/native-ios/Tools/physical-device.test.mjs
# run-tests: covers richos/mobile/native-ios/Tools/physical-device.mjs richos/mobile/native-ios/Tools/physical-device.test.mjs
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "  NOT RUN  native-ios-physical-tool: node is unavailable"
  exit 2
fi
if node --test "$ROOT/richos/mobile/native-ios/Tools/physical-device.test.mjs"; then
  echo "=== native-ios-physical-tool: passed ==="
else
  echo "=== native-ios-physical-tool: FAILED ==="
  exit 1
fi
