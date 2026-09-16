#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$here/nightly-local.test.py"
echo '  PASS  manual-only releases, local credentials, worktree isolation and failure gates'
