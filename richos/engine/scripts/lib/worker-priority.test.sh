#!/usr/bin/env bash
# Per-permit engine_pass.py priority and worker_tokens.py nested progress.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/verification-fixture.sh"
python3 "$HERE/worker-priority.test.py" "$@"
