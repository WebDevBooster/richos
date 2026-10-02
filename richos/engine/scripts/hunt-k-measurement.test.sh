#!/usr/bin/env bash
#
# hunt-k-measurement.test.sh — runs lib/hunt-k-measurement.test.py, which proves the severity-3
# measurement fixes (hunt P5-29, P5-30, P5-31, P5-46, P5-58, P5-59) in
#   lib/qa-throwaways.py, handoff-facts.py, land-completeness-measure.py and lib/left-off.py.
# This wrapper is what names those files to the proof selector.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/lib/hunt-k-measurement.test.py"
