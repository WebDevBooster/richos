#!/usr/bin/env bash
# app-evidence.test.py also runs the real ../app-engine-hook.py (DesktopHookHandOff): the desktop
# hook hands capture the app's data directory, which the output witness never records.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/app-evidence.test.py"
python3 "$HERE/../../mega-lander/tests/path-spaces.test.py"
