#!/usr/bin/env bash
# A Gradle daemon kept warm for one workspace: reused by its next build, ended at land.
# Stand-in gradlew and daemon processes in a private fixture; no Gradle, no build, no device.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
source "$(dirname "${BASH_SOURCE[0]}")/verification-fixture.sh"
python3 -B "$HERE/gradle_daemons.test.py" "$@"
