#!/usr/bin/env bash
# Read-only accounting: duplicate usage, background receipts, honest timing and scope.
# run-tests: no-host-screen: synthetic JSONL and walk records only; no capture or input
# run-tests: inputs richos/app/scripts/episode-counter.test.sh richos/app/scripts/qa/episode-counter.py richos/app/scripts/qa/episode-counter.test.py
# run-tests: covers richos/app/scripts/qa/episode-counter.py richos/app/scripts/qa/episode-counter.test.py
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/qa/episode-counter.test.py"
