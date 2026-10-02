#!/usr/bin/env bash
# mobile-device.test.sh — a physical phone is touched only through `randroid device` / `rios device`,
# only the release build goes on it, and nothing uninstalls the app or clears its data (CEO
# 2026-10-02 and 2026-10-01). The real randroid against a scripted adb and aapt2 (install refuses a
# debuggable APK and accepts the release one; every walk step, the recording and perf refuse a phone
# holding a debuggable build; an emulator is refused), one user per phone (two callers on one
# phone: refused naming the holder, or waiting; a killed holder's lock reclaimed; a session's nested
# commands; the iPhone's two spellings one lock), and the commit check (richos/mobile/physical.py
# scan, run by autocheck.py at every commit and land) catching planted installs, uninstalls, data
# clears, Gradle device tasks, device xcodebuilds and Debug iPhone builds. About fifteen seconds.
# run-tests: no-host-screen: a scripted adb and aapt2 only; no phone, emulator, simulator or window
# run-tests: inputs richos/mobile/physical.py richos/mobile/native-android/bin/randroid richos/mobile/native-ios/bin/rios richos/mobile/perf/perf.py richos/mobile/perf/android.py richos/mobile/perf/ios.py richos/app/scripts/qa/phone-android.py richos/app/scripts/qa/hidden-send-try.py richos/app/scripts/autocheck/autocheck.py richos/app/scripts/mobile-device.test.sh richos/app/scripts/mobile-device.test.py
# run-tests: covers richos/mobile/physical.py richos/app/scripts/mobile-device.test.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/mobile-device.test.py"
