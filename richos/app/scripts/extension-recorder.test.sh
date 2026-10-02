#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/extension-recorder.test.sh richos/tools/richos-extension/modules/call-capture/recorder.js richos/tools/richos-extension/modules/call-capture/constants.js richos/tools/richos-extension/core/constants.js richos/tools/richos-extension/tests/recorder-lifecycle.mjs
# run-tests: covers richos/tools/richos-extension/modules/call-capture/recorder.js richos/tools/richos-extension/tests/recorder-lifecycle.mjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
node "$ROOT/richos/tools/richos-extension/tests/recorder-lifecycle.mjs"
