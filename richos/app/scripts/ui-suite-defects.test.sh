#!/usr/bin/env bash
# run-tests: inputs richos/app/ui/tests richos/app/scripts/ui-suite-defects.test.sh
# run-tests: covers richos/app/ui/tests/lib/tracked-tree-keeps-candidates.test.js richos/app/ui/tests/lib/splash-relief-race.test.js
# Guards for defects in the UI suites themselves (hunt part 2, findings 27, 28, 29, 43). No
# browser: each test is decided in the suite source or on the files it writes.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="$DIR/../ui/tests"
node "$TESTS/lib/tracked-tree-keeps-candidates.test.js"
node "$TESTS/lib/splash-relief-race.test.js"
