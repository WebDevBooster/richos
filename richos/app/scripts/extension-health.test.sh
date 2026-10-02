#!/usr/bin/env bash
# run-tests: inputs richos/app/scripts/extension-health.test.sh richos/tools/richos-extension
# run-tests: covers richos/tools/richos-extension/manifest.json richos/tools/richos-extension/options/options.html richos/tools/richos-extension/core/offscreen.html richos/tools/richos-extension/package.json richos/tools/richos-extension/modules/call-capture/content-zoom.js richos/tools/richos-extension/tests/zoom-lifecycle.mjs richos/tools/richos-extension/modules/call-capture/platforms.js richos/tools/richos-extension/modules/call-capture/controller.js richos/tools/richos-extension/modules/call-capture/health.js richos/tools/richos-extension/modules/call-capture/session.js richos/tools/richos-extension/tests/run.js richos/tools/richos-extension/tests/controller-recovery.mjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
node "$ROOT/richos/tools/richos-extension/tests/run.js"
node "$ROOT/richos/tools/richos-extension/tests/controller-recovery.mjs"
node "$ROOT/richos/tools/richos-extension/tests/zoom-lifecycle.mjs"
