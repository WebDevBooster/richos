#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/extension-native-browser.test.sh richos/tools/richos-extension richos/tools/richos-service
# run-tests: covers richos/tools/richos-extension/tests/native-transport-e2e.mjs richos/tools/richos-extension/tests/buffered-export.mjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
node "$ROOT/richos/tools/richos-extension/tests/native-transport-e2e.mjs"
