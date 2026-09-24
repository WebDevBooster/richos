#!/usr/bin/env bash
# battery-check.test.sh — CEO ruling §81: every commit touching richos/mobile/ carries
# `Battery-check: NO — <evidence>`, and the land refuses one that does not. Throwaway Git
# repositories and read-only probes of this history; nothing builds, boots or opens a window.
# run-tests: no-host-screen: throwaway Git repositories only; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/battery-check.test.sh richos/app/scripts/battery-check.test.py richos/app/scripts/battery-check.py richos/app/scripts/proof-for.sh richos/app/scripts/proof-run.py
# run-tests: covers richos/app/scripts/battery-check.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/battery-check.test.py"
