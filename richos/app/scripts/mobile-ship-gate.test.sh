#!/usr/bin/env bash
# mobile-ship-gate.test.sh — no RichConnect build reaches users without the §104 speed PASS for its
# exact app code (richos/mobile/perf/shipgate.py, called by `randroid bundle` and by
# `testflight.ts upload|publish`; CEO 2026-10-03, §106). A throwaway Git repository and a scratch
# verdict directory: nothing builds, uploads or reaches a phone.
# run-tests: no-host-screen: throwaway Git repositories and scratch JSON only; no phone, emulator, simulator or window
# run-tests: inputs richos/mobile/perf/shipgate.py richos/mobile/perf/watch.py richos/mobile/perf/perfcore.py richos/mobile/perf/reviewwalk.py richos/mobile/native-android/bin/randroid richos/mobile/native-android/bin/review-walk.mjs richos/mobile/native-android/bin/review-reset.mjs richos/mobile/native-android/bin/review-reset.test.mjs richos/mobile/native-android/bin/apk-install.sh richos/app/scripts/mobile-ship-gate.test.sh richos/app/scripts/mobile-ship-gate.test.py richos/app/scripts/lib/ship_gate_fixture.py
# run-tests: covers richos/mobile/perf/shipgate.py richos/app/scripts/lib/ship_gate_fixture.py richos/mobile/native-android/bin/randroid richos/mobile/native-android/bin/review-walk.mjs richos/mobile/native-android/bin/review-reset.mjs richos/mobile/native-android/bin/review-reset.test.mjs
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/mobile-ship-gate.test.py"
# The Google review walk's last step (reset the host, even after its sign-in expired), on a stubbed page.
node --test "$here/../../mobile/native-android/bin/review-reset.test.mjs"
