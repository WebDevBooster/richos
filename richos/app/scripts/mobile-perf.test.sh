#!/usr/bin/env bash
# mobile-perf.test.sh — RichConnect's speed and battery measurement tool (richos/mobile/perf, PRD
# 2026-09-24 §9 step 1): its parsers against output captured from the Android emulator, the whole
# Android run against a scripted adb (refusing a stale build or a misnamed device), and the iOS
# parsers against documented output shapes. Nothing builds, boots or opens a window.
# run-tests: no-host-screen: parsers and a scripted adb only; no emulator, simulator or window
# run-tests: inputs richos/mobile/perf richos/mobile/native-android/bin/randroid richos/mobile/native-ios/bin/rios richos/app/scripts/mobile-perf.test.sh richos/app/scripts/mobile-perf.test.py
# run-tests: covers richos/mobile/perf/perf.py richos/mobile/perf/perfcore.py richos/mobile/perf/android.py richos/mobile/perf/ios.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/mobile-perf.test.py"
