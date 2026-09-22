# RichOS for Android (native)

The native Android app: Kotlin, Jetpack Compose, one activity. Build plan:
`richos-hq/docs/plans/2026-09-22-native-apps-build-plan.md` §3.3. The preserved apps
(`richos/mobile/ios/`, `richos/mobile/ui/`, `richos/web/web-app/`) are untouched; they are the
working reference for the phone protocol.

## The rule that shapes it: the fast loop

Application logic lives in `:core`, plain Kotlin on the JVM with no Android dependency, so it is
proven on the Mac in seconds with no emulator. The UI calls the same actions the command line
calls. There is no second implementation of any behavior for tests.

| Module | What it is |
|---|---|
| `core/` | `AppState`, `Action`, the five ports (`OutboxStorage`, `SessionStore`, `Transport`, `Clock`, `IdSource`), `RichCore` (the one place state changes), and `core/dev/`: the fixtures and the deterministic runtime the CLI and the debug bridge share. |
| `cli/` | `randroid-headless`, the headless command line over the real core. |
| `app/` | The Compose app. `app/` package: entry, `AppStore` (the one owner of the core, `StateFlow<AppState>`), production ports. `app/src/debug/`: the development bridge, absent from release builds. Screens: `ui/` and `design/` packages (stream A2). |

## One command: `bin/randroid`

Everything prints JSON and exits nonzero on failure. The grammar and the result envelope are the
preserved phone CLI's (`richos/mobile/cli/mobile.mjs`).

```sh
bin/randroid headless state                       # L1′: the real core, one JVM start, no Gradle
bin/randroid headless fixture offline             #   offline | online | queued | interrupted | revoked
bin/randroid headless action '{"type":"compose","text":"Hello"}'
bin/randroid headless scenario draft-survives-restart
bin/randroid headless transport accept            #   accept | unreachable | lose-ack | revoked
bin/randroid headless advance 1000
bin/randroid headless reset | restart

bin/randroid test core [--tests '<pattern>']      # L1: the core and CLI JVM tests
bin/randroid test app                             # the app entry and bridge, Robolectric (no emulator)

bin/randroid emu prepare                          # L2: boot this checkout's own emulator
                                                  #     (-no-window), build, install, launch
bin/randroid emu refresh                          # incremental build + reinstall + relaunch
bin/randroid emu state | action '<json>' | fixture <n> | scenario <n> | transport <m> | advance <ms> | reset
bin/randroid emu restart                          # a real process restart, then the state
bin/randroid emu parity [scenario]                # same scenario headless and on the device
bin/randroid emu verify                           # the screen shows what the core says
bin/randroid emu screenshot [file.png]
bin/randroid emu stop | delete                    # quit it (by the PID recorded at boot) / delete its AVD

bin/randroid build debug | release
bin/randroid check-release                        # the bridge is absent from the release APK
bin/randroid doctor
```

The headless session persists between calls in one file, so separate processes see one app, as
separate launches of the app would.

**Devices are addressed only by the serial `emu prepare` recorded.** Never a bare `adb`: a
physical phone may be attached. `emu stop` signals only the PID captured when the emulator was
spawned. At most one emulator per checkout, `-no-window`, stopped as soon as a run ends.

## Where things go

Nothing is built into the source tree. `bin/randroid` puts build output, the Gradle project
cache, the headless session and the emulator's AVD under `$RANDROID_CACHE` (default
`/Volumes/E1TB/caches/richos-native-android/<checkout hash>/`) and refuses to run if that volume
is absent. Gradle's own cache is `$GRADLE_USER_HOME` (default
`/Volumes/E1TB/caches/richos-native-android/gradle`). Java: `$JAVA_HOME`, else Android Studio's
bundled runtime. Android SDK: `$ANDROID_HOME`, else `/opt/homebrew/share/android-commandlinetools`
(needs `platforms;android-37.0`, `build-tools;36.0.0`, and for the emulator
`system-images;android-34;google_apis;arm64-v8a`).

## The debug bridge

Debug builds only (`app/src/debug/`). `bin/randroid emu <command>` sends an explicit broadcast
through `adb -s <serial> shell am broadcast`; the receiver requires `android.permission.DUMP`,
which the adb shell holds and no ordinary app can obtain. It runs the command against the same
`DevRuntime` the headless CLI runs and answers in the broadcast's result data, so one adb call is
one round trip. The development world is saved in the app's private files, so it survives a
real process restart. `bin/randroid check-release` proves none of this is in a release APK.

## Versions

minSdk 29, targetSdk 36 (build plan §3.3), compileSdk 37 (the current Compose and lifecycle
libraries refuse to compile against less). Development application ID `dev.richos.native.android`;
Kotlin package root `dev.richos.android` (`native` is a Java keyword). Gradle 9.7.1 (wrapper,
checksum pinned), AGP 9.4.1, Kotlin 2.4.20, Compose BOM 2026.09.00, Robolectric 4.17.

## Registered proof

`richos/app/scripts/native-android-core.test.sh` (core, CLI, headless processes) and
`richos/app/scripts/native-android-app.test.sh` (Robolectric app tests, `check-release`, and with
`RANDROID_SUITE_EMULATOR=1` the emulator parity, on-screen and restart checks). Both print
`NOT RUN` and exit 2 on a host without the toolchain.
