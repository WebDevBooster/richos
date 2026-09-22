#!/usr/bin/env bash
# Native Android app, stream A2: every round-12 screen, by name, headless.
#
#   native-android-ui.test.sh                 the design-system and screen tests, then EVERY screen
#                                             rendered headless (Robolectric, native graphics, no
#                                             emulator) in dark and light, on a 360 dp and a 412 dp
#                                             phone, at 2x text on the small phone, plus the motion
#                                             filmstrips; each frame checked (names, 48 dp targets,
#                                             no clipped or broken text, composer on screen, the
#                                             timer clear of Cancel) and written as a PNG
#   native-android-ui.test.sh <id|gN> …       only those screens (ids from round 12, or gN for a
#                                             whole group); prints where the PNGs went
#   native-android-ui.test.sh --list          every screen id, its group and title (no JVM)
#   native-android-ui.test.sh --fast          only the pure JVM tests (contrast, follow rule,
#                                             voice frames, catalog, taps), no rendering
#
# RICHOS_SHOTS overrides where the PNGs go. A host without the external SSD, a Java 21+ runtime or
# the Android SDK prints NOT RUN and exits 2 (bin/randroid decides Java and Gradle); a failed check
# on a capable host exits 1.
# run-tests: no-host-screen: Robolectric renders on the JVM; nothing opens a window
# run-tests: inputs richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design richos/mobile/native-android/app/src/main/res/font richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/design richos/mobile/native-android/core/src/main richos/mobile/native-android/app/build.gradle.kts richos/mobile/native-android/gradle richos/mobile/native-android/bin/randroid richos/app/scripts/native-android-ui.test.sh
# run-tests: covers richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/Components.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/Contrast.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/Press.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/RichColors.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/RichIcons.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/RichMotion.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/RichTheme.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/design/RichType.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/catalog/ScreenCatalog.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/composer/Cards.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/composer/Composer.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/composer/Orb.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/conversation/Bubbles.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/conversation/Follow.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/conversation/Header.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/conversation/Thread.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/model/ScreenModel.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/overlays/Scanner.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/overlays/Sheets.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/overlays/SystemDrawings.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/overlays/Takeovers.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/RichApp.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/UiEvent.kt richos/mobile/native-android/app/src/main/kotlin/dev/richos/android/ui/voice/VoiceFrame.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/design/ContrastTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui/catalog/CatalogTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui/conversation/FollowTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui/InteractionTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui/ScreenChecks.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui/ScreensTest.kt richos/mobile/native-android/app/src/test/kotlin/dev/richos/android/ui/voice/VoiceFrameTest.kt richos/app/scripts/native-android-ui.test.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
NA="$ROOT/richos/mobile/native-android"
RANDROID="$NA/bin/randroid"
CATALOG="$NA/app/src/main/kotlin/dev/richos/android/ui/catalog/ScreenCatalog.kt"

if [ "${1:-}" = "--list" ]; then
  # ScreenSpec("id", group, "inv", "title" … — read from the source, so the list needs no JVM.
  grep -o 'ScreenSpec("[a-z0-9-]*", [0-9]*, "[^"]*", "[^"]*"' "$CATALOG" \
    | sed -E 's/ScreenSpec\("([^"]*)", ([0-9]*), "[^"]*", "([^"]*)"/g\2  \1  \3/'
  exit 0
fi

VOLUME=/Volumes/E1TB
if [ ! -d "$VOLUME" ] || [ "$(stat -f %d "$VOLUME")" = "$(stat -f %d /Volumes)" ]; then
  echo "  NOT RUN  native-android-ui: mount $VOLUME for build output and screenshots"
  exit 2
fi
SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
if [ ! -d "$SDK/platforms" ]; then
  echo "  NOT RUN  native-android-ui: no Android SDK under $SDK"
  exit 2
fi

PURE=(--tests 'dev.richos.android.design.*' --tests 'dev.richos.android.ui.catalog.*'
      --tests 'dev.richos.android.ui.conversation.*' --tests 'dev.richos.android.ui.voice.*'
      --tests 'dev.richos.android.ui.InteractionTest')

if [ "${1:-}" = "--fast" ]; then
  "$RANDROID" test app -q "${PURE[@]}"
  code=$?
  [ "$code" -eq 2 ] && { echo "  NOT RUN  native-android-ui: bin/randroid reported a missing host tool"; exit 2; }
  [ "$code" -eq 0 ] || { echo "  FAIL  native-android-ui: JVM tests exited $code"; exit 1; }
  echo '  PASS  native-android-ui: contrast (both themes), follow rule, voice frames, catalog, taps'
  exit 0
fi

# Where the frames go: one stable place per checkout, on the external SSD, printed at the end.
HASH="$(printf '%s' "$NA" | shasum | cut -c1-10)"
export RICHOS_SHOTS="${RICHOS_SHOTS:-$VOLUME/caches/richos-native-android/ui-shots/$HASH}"
rm -rf "$RICHOS_SHOTS" && mkdir -p "$RICHOS_SHOTS"
export RICHOS_SCREENS=""
if [ "$#" -gt 0 ]; then
  RICHOS_SCREENS="$(IFS=,; echo "$*")"
  for want in "$@"; do
    case "$want" in
      g[0-9]*) ;;
      *) grep -q "ScreenSpec(\"$want\"" "$CATALOG" || { echo "  FAIL  native-android-ui: no screen named '$want' (see --list)"; exit 1; } ;;
    esac
  done
fi

started=$(date +%s)
if [ "$#" -gt 0 ]; then
  "$RANDROID" test app -q --rerun --tests 'dev.richos.android.ui.ScreensTest'
else
  "$RANDROID" test app -q --rerun "${PURE[@]}" --tests 'dev.richos.android.ui.ScreensTest'
fi
code=$?
[ "$code" -eq 2 ] && { echo "  NOT RUN  native-android-ui: bin/randroid reported a missing host tool"; exit 2; }
frames=$(find "$RICHOS_SHOTS" -name '*.png' | wc -l | tr -d ' ')
echo "  $frames frames in $RICHOS_SHOTS ($(( $(date +%s) - started )) s)"
if [ "$code" -ne 0 ]; then
  echo "  FAIL  native-android-ui: a screen check or test failed (exit $code); the Gradle report names the screen and the problem"
  exit 1
fi
if [ "$#" -gt 0 ]; then
  echo "  PASS  native-android-ui: $* rendered and checked"
else
  echo '  PASS  native-android-ui: every round-12 screen rendered and checked, both themes, two phones, 2x text'
fi
