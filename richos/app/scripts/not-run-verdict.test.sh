#!/usr/bin/env bash
# not-run-verdict.test.sh — a suite that prints NOT RUN over a subcheck exits 2 ("this host cannot
# answer", run-tests.sh), never 0 (hunt part 2, finding 18). A throwaway Git repository and a read
# of the suites' own text; nothing builds, boots or opens a window.
# run-tests: no-host-screen: a throwaway Git repository and source reads only; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/not-run-verdict.test.sh richos/app/scripts/not-run-verdict.test.py richos/app/scripts/battery-check.test.py richos/app/scripts/battery-check.py
# run-tests: covers -
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/not-run-verdict.test.py"
