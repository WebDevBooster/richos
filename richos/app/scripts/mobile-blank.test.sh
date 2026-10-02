#!/usr/bin/env bash
# mobile-blank.test.sh — the no-blank-screen checks (CEO, 2026-10-02): the frame analyzer
# (richos/mobile/perf/blank.py) on synthetic frames and the series verdict. No phone recording ever
# enters the repository; nothing boots, builds, records or decodes.
# run-tests: no-host-screen: synthetic frames only; no device, simulator or window
# run-tests: inputs richos/mobile/perf/blank.py richos/mobile/perf/framedump.swift richos/mobile/perf/perfcore.py richos/app/scripts/mobile-blank.test.sh richos/app/scripts/mobile-blank.test.py
# run-tests: covers richos/mobile/perf/blank.py richos/mobile/perf/framedump.swift
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/mobile-blank.test.py"
