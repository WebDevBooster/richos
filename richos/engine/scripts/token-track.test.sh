#!/usr/bin/env bash
# Covers token-track.py, token-track-launchd.sh and token-track.test.py: tokens per quota point from a fixture transcript and fixture readings.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$here/token-track.test.py"
bash -n "$here/token-track-launchd.sh"
# The plist install writes starts a reading at every clock minute 0-59 and has no StartInterval
# (which drifts past skipped minutes); rendered with `plist`, which loads nothing.
bash "$here/token-track-launchd.sh" plist | python3 -B -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
assert "StartInterval" not in d, "StartInterval drifts: a firing during a run is missed"
cal = d.get("StartCalendarInterval")
assert isinstance(cal, list) and all(set(e) == {"Minute"} for e in cal), cal
assert sorted(e["Minute"] for e in cal) == list(range(60)), cal
'
echo "token-track: launchd plist fires every clock minute"
