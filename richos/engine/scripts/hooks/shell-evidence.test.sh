#!/usr/bin/env bash
# The errexit notice is said once per context: shell-evidence.py passes it through scripts/lib/notice_once.py.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/shell-evidence.test.py"
