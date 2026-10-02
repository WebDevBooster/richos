#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/extension-alerts.test.sh richos/tools/richos-extension/core/alerts.js richos/tools/richos-extension/core/constants.js richos/tools/richos-extension/core/settings.js richos/tools/richos-extension/core/offscreen-host.js richos/tools/richos-extension/tests/alerts.mjs
# run-tests: covers richos/tools/richos-extension/core/alerts.js richos/tools/richos-extension/tests/alerts.mjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
node "$ROOT/richos/tools/richos-extension/tests/alerts.mjs"
