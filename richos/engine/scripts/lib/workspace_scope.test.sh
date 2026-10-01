#!/usr/bin/env bash
# workspace_scope.test.sh — a test runner started in a teammate workspace narrows to what the branch
# touches, and ci-shard.sh's no-selector default there (workspace_scope.test.py). Fixture
# repositories only.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/verification-fixture.sh"
python3 -B "$HERE/workspace_scope.test.py"
