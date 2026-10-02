#!/usr/bin/env bash
# phone-speed-watch.test.sh — the phone speed check that runs by itself after every land touching
# richos/mobile/ (richos/mobile/perf/watch.py, started by autocheck's post-merge and post-commit hooks
# on main) and the guard that keeps every automatic run from uninstalling the app or clearing its
# data (phone_guard.py). Fake phones and a fake land in throwaway Git repositories: nothing builds,
# boots, opens a window or reaches a phone.
# run-tests: no-host-screen: throwaway Git repositories and stand-in tools only; no phone, emulator, simulator or window
# run-tests: inputs richos/mobile/perf/watch.py richos/mobile/perf/phone_guard.py richos/app/scripts/autocheck/autocheck.py richos/app/scripts/autocheck/shim.sh richos/app/scripts/autocheck/install.sh richos/app/scripts/phone-speed-watch.test.sh richos/app/scripts/phone-speed-watch.test.py
# run-tests: covers richos/mobile/perf/watch.py richos/mobile/perf/phone_guard.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/phone-speed-watch.test.py"
