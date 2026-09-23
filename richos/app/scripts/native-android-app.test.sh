#!/usr/bin/env bash
# Native Android app, stream A1 app shell: the app's entry, store wiring and debug-only bridge,
# tested headless on the JVM with Robolectric (no emulator), then the release APK checked for
# the bridge's absence (build plan §3.1). A host without Java, the external SSD, Android SDK
# platform 37.0 (compile) or build-tools 36.0.0 prints NOT RUN and exits 2; a build or test
# failure on a capable host exits 1.
#
# THE EMULATOR LAYER IS OPT-IN: RANDROID_SUITE_EMULATOR=1 also boots this checkout's own
# emulator (-no-window, by the serial bin/randroid records), checks that the on-device bridge
# returns the same states as headless and that the screen shows the core's draft, then shuts
# the emulator down and deletes its AVD. Off by default because every land and nightly runs
# every suite and a cold emulator boot is the most expensive step in this file.
# run-tests: no-host-screen: Robolectric runs on the JVM; the opt-in emulator is started with -no-window
# run-tests: inputs richos/mobile/native-android/app richos/mobile/native-android/core richos/mobile/native-android/bin richos/mobile/native-android/gradle richos/mobile/native-android/gradlew richos/mobile/native-android/settings.gradle.kts richos/mobile/native-android/build.gradle.kts richos/mobile/native-android/gradle.properties richos/app/scripts/native-android-app.test.sh
# run-tests: covers richos/mobile/native-android/app/src/debug/kotlin/dev/richos/android/app/debug/DevBridge.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/app/AppPorts.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/app/AppStore.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/app/MainActivity.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/app/RichApplication.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/platform/Attachments.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/platform/HttpsMac.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/platform/KeystoreKeys.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/platform/MicRecorder.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/platform/Notifications.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/platform/ShareToRich.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/platform/Wav.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/app/AppTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/platform/AttachmentsTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/platform/IdentityTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/platform/NotificationsTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/platform/WavTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/platform/WireTest.kt richos/mobile/native-android/app/src/testDebug/kotlin/dev/richos/android/app/debug/DevBridgeTest.kt richos/mobile/native-android/app/src/testDebug/kotlin/dev/richos/android/app/debug/ScreenFollowsCoreTest.kt richos/mobile/native-android/app/src/testDebug/kotlin/dev/richos/android/app/debug/ShareTest.kt richos/mobile/native-android/bin/randroid richos/mobile/native-android/gradlew richos/mobile/native-android/gradle/libs.versions.toml
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
NA="$ROOT/richos/mobile/native-android"
RANDROID="$NA/bin/randroid"

VOLUME=/Volumes/E1TB
if [ ! -d "$VOLUME" ] || [ "$(stat -f %d "$VOLUME")" = "$(stat -f %d /Volumes)" ]; then
  echo "  NOT RUN  native-android-app: mount $VOLUME for build output and scratch"
  exit 2
fi
# Java: bin/randroid picks a 21+ runtime (RANDROID_JAVA_HOME, JAVA_HOME, Android Studio's) and
# exits 2 with NOT RUN when there is none; that exit is passed through below.
SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
if [ ! -f "$SDK/platforms/android-37.0/android.jar" ] || [ ! -x "$SDK/build-tools/36.0.0/aapt2" ]; then
  echo "  NOT RUN  native-android-app: Android SDK platform 37.0 and build-tools 36.0.0 are not installed under $SDK"
  exit 2
fi

fails=0
bad() { echo "  FAIL  native-android-app: $1"; fails=$((fails + 1)); }

# Only this stream's tests; the screens' screenshot sweep is native-android-ui.test.sh (A2).
"$RANDROID" test app -q --tests 'dev.richos.android.app.*' --tests 'dev.richos.android.platform.*'
code=$?
if [ "$code" -eq 2 ]; then echo "  NOT RUN  native-android-app: bin/randroid reported a missing host tool"; exit 2; fi
[ "$code" -eq 0 ] || bad "Robolectric tests (:app:testDebugUnitTest) exited $code"

"$RANDROID" check-release >/dev/null || bad "check-release: the development bridge reached the release APK, or it did not build"

if [ "${RANDROID_SUITE_EMULATOR:-0}" = "1" ]; then
  SCRATCH_PARENT="$VOLUME/tmp/codex"
  mkdir -p "$SCRATCH_PARENT"
  SCRATCH="$(mktemp -d "$SCRATCH_PARENT/native-android-app.XXXXXX")" || { echo "  FAIL  native-android-app: no scratch"; exit 1; }
  export RANDROID_SESSION="$SCRATCH/headless.json"
  # The emulator this suite boots is deleted however the suite ends.
  trap '"$RANDROID" emu delete >/dev/null 2>&1; rm -rf "$SCRATCH"' EXIT HUP INT TERM
  # The emulator is started with nohup, so a run killed before its trap leaves it running. Its cache
  # (the one bin/randroid derives) is registered to this shell, and the engine ends the emulator it
  # recorded once this shell is gone (richos/engine/scripts/lib/testdevices.py, §54).
  RCACHE="${RANDROID_CACHE:-$VOLUME/caches/richos-native-android/$(printf '%s' "$NA" | shasum | cut -c1-10)}"
  python3 "$ROOT/richos/engine/scripts/lib/testdevices.py" register --kind android-cache \
    --id "$RCACHE" --owner-pid $$ --script native-android-app.test.sh >/dev/null 2>&1 || true
  "$RANDROID" emu prepare >/dev/null || bad "emu prepare (boot, build, install, launch) failed"
  if [ "$fails" -eq 0 ]; then
    "$RANDROID" emu parity draft-survives-restart >/dev/null || bad "the emulator's states differ from headless for draft-survives-restart"
    "$RANDROID" emu action '{"type":"compose","text":"On the screen"}' >/dev/null || bad "emu action failed"
    "$RANDROID" emu verify >/dev/null || bad "the screen does not show the core's draft"
    "$RANDROID" emu restart >/dev/null || bad "emu restart failed"
    "$RANDROID" emu verify >/dev/null || bad "the draft did not survive a real process restart on the device"
  fi
else
  echo "  NOTE  native-android-app: emulator layer not run (set RANDROID_SUITE_EMULATOR=1)"
fi

if [ "$fails" -gt 0 ]; then exit 1; fi
echo '  PASS  native-android-app: Robolectric entry + bridge tests, release APK free of the bridge'
