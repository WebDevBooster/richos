#!/usr/bin/env bash
# native-work.py admission order (worker first, compiler lane second). Stand-in budgets
# only: no build runs, no device is leased, nothing waits.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 -B "$HERE/native-work.test.py" "$@"
