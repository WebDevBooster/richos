#!/usr/bin/env bash
# mobile-blank.test.sh — the no-blank-screen checks (CEO, 2026-10-02): the frame analyzer
# (richos/mobile/perf/blank.py) on synthetic frames, the series verdict, and the cold-start glue for
# both phones (blankstart.py, perf.py android's cold-blank phase) against a scripted phone. No phone
# recording ever enters the repository; nothing boots, builds, records or decodes.
# run-tests: no-host-screen: synthetic frames and a scripted phone only; no device, simulator or window
# run-tests: inputs richos/mobile/perf/blank.py richos/mobile/perf/blankstart.py richos/mobile/perf/framedump.swift richos/mobile/perf/perf.py richos/mobile/perf/perfcore.py richos/app/scripts/mobile-blank.test.sh richos/app/scripts/mobile-blank.test.py
# run-tests: covers richos/mobile/perf/blank.py richos/mobile/perf/blankstart.py richos/mobile/perf/framedump.swift
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/mobile-blank.test.py"
