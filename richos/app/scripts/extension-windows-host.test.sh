#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/extension-windows-host.test.sh richos/tools/richos-service/host/install-host-windows.mjs richos/tools/richos-service/lib richos/engine/voice richos/engine/loro richos/tools/richos-service/test/install-host-windows.mjs
# run-tests: covers richos/tools/richos-service/host/install-host-windows.mjs richos/tools/richos-service/test/install-host-windows.mjs
set -euo pipefail
[[ -d /Volumes/E1TB ]] || { echo 'External SSD unavailable' >&2; exit 1; }
export RICHOS_TEST_SCRATCH_ROOT=/Volumes/E1TB/tmp/codex
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
node richos/tools/richos-service/test/install-host-windows.mjs
