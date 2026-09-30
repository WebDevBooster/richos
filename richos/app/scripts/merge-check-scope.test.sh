#!/usr/bin/env bash
# Phone selection, scoped retries and merge admission, all against fixtures.
# run-tests: no-host-screen: selector, shell adapters and result-bundle fixtures only
# run-tests: inputs richos/app/scripts/merge-check-scope.test.sh richos/app/scripts/merge-check-scope.test.py richos/app/scripts/lib/ios_ui_scope.py richos/app/scripts/lib/ios_ui_shards.py richos/app/scripts/lib/proof_declarations.py richos/app/scripts/proof-for.sh richos/app/scripts/proof-run.py richos/app/scripts/native-ios-ui.test.sh richos/app/scripts/native-ios-app.test.sh richos/app/scripts/native-ios-share.test.sh richos/mobile/native-ios/Release/simulator-tests.sh richos/mobile/native-ios/UITests richos/engine/scripts/lib/ci-unit-weights.tsv
# run-tests: covers richos/app/scripts/lib/ios_ui_shards.py richos/app/scripts/lib/ios_ui_scope.py richos/app/scripts/merge-check-scope.test.py richos/app/scripts/native-ios-ui.test.sh richos/app/scripts/native-ios-app.test.sh richos/app/scripts/native-ios-share.test.sh richos/mobile/native-ios/Release/simulator-tests.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$HERE/merge-check-scope.test.py"
