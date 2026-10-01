#!/usr/bin/env bash
# workspace-scope.test.sh — in a teammate workspace a runner with no selection runs only what the
# branch touches, on one device, and says so; `--full`, the merge gate, proof-run.py and the
# nightlies are never narrowed (CEO, 2026-10-01). Fixture git repositories only; nothing builds,
# boots a simulator or opens a window.
# run-tests: no-host-screen: fixture repositories and shell blocks only; nothing is launched
# run-tests: inputs richos/app/scripts/workspace-scope.test.sh richos/app/scripts/workspace-scope.test.py richos/app/scripts/lib/ios_ui_scope.py richos/app/scripts/lib/android_ui_scope.py richos/app/scripts/lib/ios_ui_shards.py richos/app/scripts/native-ios-ui.test.sh richos/app/scripts/native-android-ui.test.sh richos/engine/scripts/lib/workspace_scope.py richos/mobile/native-ios/UITests richos/mobile/native-ios/UnitTests richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/composer/DraftEditor.kt
# run-tests: covers richos/app/scripts/lib/android_ui_scope.py richos/app/scripts/lib/ios_ui_scope.py richos/app/scripts/native-ios-ui.test.sh richos/app/scripts/native-android-ui.test.sh richos/app/scripts/workspace-scope.test.py
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$HERE/workspace-scope.test.py"
