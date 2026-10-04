#!/usr/bin/env bash
# review-walk-gate.test.sh — no RichConnect build goes to a store review before the automated reviewer
# walk passed on that exact build (richos/mobile/perf/reviewwalk.py, read by `testflight.ts upload`;
# CEO 2026-10-04, §107). A scratch records directory: nothing builds, uploads or reaches a device.
# run-tests: no-host-screen: scratch JSON only; no phone, emulator, simulator or window
# run-tests: inputs richos/mobile/perf/reviewwalk.py richos/app/scripts/review-walk-gate.test.sh richos/app/scripts/review-walk-gate.test.py
# run-tests: covers richos/mobile/perf/reviewwalk.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/review-walk-gate.test.py"
