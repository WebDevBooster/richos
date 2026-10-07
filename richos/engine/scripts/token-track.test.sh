#!/usr/bin/env bash
# Covers token-track.py, token-track-launchd.sh and token-track.test.py: tokens per quota point from a fixture transcript and fixture readings.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$here/token-track.test.py"
bash -n "$here/token-track-launchd.sh"
