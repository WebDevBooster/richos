#!/usr/bin/env bash
# The controller launchd runs (cpu_guard_live.py) and the script that deploys and rolls it
# back (cpu_guard_live_deploy.py). Fixture state only: nothing here touches the real guard.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
source "$(dirname "${BASH_SOURCE[0]}")/verification-fixture.sh"
python3 -B "$HERE/cpu_guard_live.test.py" "$@"
