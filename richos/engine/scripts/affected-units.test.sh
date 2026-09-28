#!/usr/bin/env bash
# lib/affected_units.py semantic selection and global validation boundary.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$here/affected-units.test.py"
