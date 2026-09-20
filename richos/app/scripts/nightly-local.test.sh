#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/nightly-local.test.sh richos/app/scripts/nightly-local.test.py richos/app/scripts/nightly-local.py richos/app/scripts/nightly.py richos/app/scripts/make-release.sh richos/app/scripts/package-app.sh richos/app/scripts/run-tests.sh richos/app/scripts/gui-proof-in-vm.sh
# run-tests: covers richos/app/scripts/nightly-local.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$here/nightly-local.test.py"
echo '  PASS  manual-only releases, local credentials, worktree isolation and failure gates'
