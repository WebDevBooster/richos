#!/usr/bin/env bash
# autocheck-sidecars.test.sh — a merge into main that changes an engine guard script refreshes the
# gitignored .sha256 sidecars by itself (autocheck's post-merge hook runs the engine's install.sh),
# so the integrity probe's BR4 never goes red after a land. Throwaway repositories with a copy of
# the engine and a redirected HOME; nothing touches the real main checkout or the operator's config.
# run-tests: no-host-screen: throwaway Git repositories only; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/autocheck-sidecars.test.sh richos/app/scripts/autocheck-sidecars.test.py richos/app/scripts/autocheck.test.py richos/app/scripts/autocheck richos/engine/scripts/hooks/install.sh richos/engine/scripts/hooks/contract-integrity-probe.sh richos/engine/scripts/lib/registered-hooks.sh richos/engine/hooks/hooks.json
# run-tests: covers richos/app/scripts/autocheck/autocheck.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/autocheck-sidecars.test.py"
