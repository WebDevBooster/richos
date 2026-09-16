#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/app-evidence.test.py"
python3 "$HERE/../../mega-lander/tests/path-spaces.test.py"
