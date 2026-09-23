#!/usr/bin/env bash
# Release security policy for both native RichConnect apps (richos/mobile/security/release_policy.py;
# security review 2026-09-23, docs/verification/2026-09-23-native-security-review/). No build, no
# simulator, no emulator, no network; under a second.
#   1. self-test: every rule FAILS on its negative control (debuggable, test-only, backup on,
#      cleartext, an exported provider or unprotected receiver, a deep link, a credential file,
#      a Firebase key literal, custom TLS trust, a log call, a debug entitlement). A rule that
#      cannot fail proves nothing when it passes.
#   2. the merged release manifest recorded from 4edbfce1 passes every Android rule; the debug
#      manifest of the same build fails (the positive probe: the development bridge is seen).
#   3. this checkout's tracked files and native sources pass every repository rule.
# The same Android rules on a freshly built APK or bundle belong in `randroid check-release`
# (ready-to-brief item in the review); this suite keeps the rules themselves honest.
# run-tests: no-host-screen: Python over text files only
# run-tests: inputs richos/app/scripts/native-release-policy.test.sh richos/mobile/security richos/mobile/native-android/app/src richos/mobile/native-android/core/src/main richos/mobile/native-ios/App richos/mobile/native-ios/Core/Sources richos/mobile/native-ios/ShareExtension richos/mobile/native-ios/NotificationService richos/mobile/native-ios/Release richos/mobile/native-ios/project.yml
# run-tests: covers richos/mobile/security/release_policy.py
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
POLICY="$ROOT/richos/mobile/security/release_policy.py"
if ! command -v python3 >/dev/null 2>&1; then
  echo "  NOT RUN  native-release-policy: python3 is unavailable"
  exit 2
fi
if ! command -v git >/dev/null 2>&1; then
  echo "  NOT RUN  native-release-policy: git is unavailable"
  exit 2
fi

fails=0
python3 "$POLICY" self-test || { echo "  FAIL  native-release-policy: a rule does not fire on its negative control"; fails=$((fails + 1)); }
python3 "$POLICY" android-manifest "$ROOT/richos/mobile/security/fixtures/release-manifest-4edbfce1.txt" \
  || { echo "  FAIL  native-release-policy: the recorded release manifest breaks a rule"; fails=$((fails + 1)); }
python3 "$POLICY" repo "$ROOT" || { echo "  FAIL  native-release-policy: this checkout breaks a repository rule"; fails=$((fails + 1)); }

if [ "$fails" -eq 0 ]; then
  echo "  PASS  native-release-policy: every rule fires on its control; recorded release manifest and this checkout pass"
  exit 0
fi
exit 1
