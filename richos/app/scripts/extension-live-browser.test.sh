#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/extension-live-browser.test.sh richos/tools/richos-extension
# run-tests: covers richos/tools/richos-extension/tests/live-capture.mjs richos/tools/richos-extension/tests/buffered-export.mjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
node "$ROOT/richos/tools/richos-extension/tests/live-capture.mjs"
