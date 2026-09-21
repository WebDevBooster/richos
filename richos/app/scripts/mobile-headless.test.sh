#!/usr/bin/env bash
# Runs real core tests and separate CLI processes. Packaging assertions exercise
# simulator.mjs without requiring Xcode; they do not claim native behavior.
# run-tests: inputs richos/app/scripts/mobile-headless.test.sh richos/mobile/package.json richos/mobile/core richos/mobile/dev richos/mobile/cli richos/mobile/ui richos/mobile/test richos/web/web-app/lib/queue.js
# run-tests: covers richos/mobile/package.json richos/mobile/core/app.js richos/mobile/dev/runtime.js richos/mobile/cli/mobile.mjs richos/mobile/cli/simulator.mjs richos/mobile/ui/entry.js richos/mobile/test/core.test.js richos/mobile/test/cli.test.js
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
for tool in node npm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "  NOT RUN  mobile-headless: $tool is unavailable"
    exit 2
  fi
done
if ! node -e 'const fs = require("node:fs"); process.exit(fs.existsSync("/Volumes/E1TB") && fs.statSync("/Volumes/E1TB").dev !== fs.statSync("/Volumes").dev ? 0 : 1)'; then
  echo '  NOT RUN  mobile-headless: external cache storage is unavailable'
  exit 2
fi
npm --prefix "$ROOT/richos/mobile" test
echo '  PASS  mobile headless core, CLI persistence/errors and resource packaging'
