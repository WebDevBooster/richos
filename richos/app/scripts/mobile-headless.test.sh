#!/usr/bin/env bash
# Runs real core tests and separate CLI processes. Packaging assertions exercise
# simulator.mjs without requiring Xcode; they do not claim native behavior.
# run-tests: inputs richos/app/scripts/mobile-headless.test.sh richos/mobile/package.json richos/mobile/core richos/mobile/dev richos/mobile/cli richos/mobile/ui richos/mobile/platform richos/mobile/test richos/web/web-app/lib richos/web/web-app/test/stub-mac.js richos/tools/phone-probe/lib
# run-tests: covers richos/mobile/cli/device.mjs richos/mobile/cli/device-runner.mjs richos/mobile/dev/client-runtime.js richos/mobile/dev/lab.mjs richos/mobile/test/device-runner.test.js richos/mobile/test/lab.test.js richos/mobile/core/client.js richos/mobile/platform/native.js richos/mobile/test/client.test.js richos/mobile/package.json richos/mobile/core/app.js richos/mobile/dev/runtime.js richos/mobile/cli/mobile.mjs richos/mobile/cli/simulator.mjs richos/mobile/ui/entry.js richos/mobile/test/core.test.js richos/mobile/test/cli.test.js richos/mobile/test/run-suite.cjs richos/mobile/test/storage.cjs
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
for tool in node npm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "  NOT RUN  mobile-headless: $tool is unavailable"
    exit 2
  fi
done
node "$ROOT/richos/mobile/test/run-suite.cjs" headless
echo '  PASS  mobile headless core, CLI persistence/errors and resource packaging'
