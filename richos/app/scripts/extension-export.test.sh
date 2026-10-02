#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/extension-export.test.sh richos/tools/richos-extension
# run-tests: covers richos/tools/richos-extension/core/output.js richos/tools/richos-extension/core/zip.js richos/tools/richos-extension/core/native-host-client.js richos/tools/richos-extension/popup/popup.js richos/tools/richos-extension/popup/popup.html richos/tools/richos-extension/core/constants.js richos/tools/richos-extension/manifest.json richos/tools/richos-extension/tests/export-archive.mjs richos/tools/richos-extension/tests/popup-export.mjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
node "$ROOT/richos/tools/richos-extension/tests/export-archive.mjs"
node "$ROOT/richos/tools/richos-extension/tests/popup-export.mjs"
