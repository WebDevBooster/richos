#!/usr/bin/env bash
# The build caches on the external drive clean themselves up: lib/build_caches.py and the
# reaper arm that plans it (scratch-reaper.py scan_build_caches). The cases are in
# build-caches.test.py.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 -B "$HERE/build-caches.test.py" "$@"
