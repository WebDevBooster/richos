#!/usr/bin/env bash
# cpu_policy.py managed verification pressure and recovery decisions.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$here/verification-pressure.test.py"
