#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$here/nightly.test.py"
echo '  PASS  nightly versions, real Git reservations, channel races and publication failures'
