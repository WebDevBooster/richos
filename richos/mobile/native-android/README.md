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
bin/randroid emu perf [--out file.json] [--only …]   # launch, resume, tap, frames, background, typing
                                                  #   and stream cost of the installed build, one
                                                  #   record (richos/mobile/perf/README.md)
bin/randroid emu adb <args>                       # one adb command, this emulator's serial only
bin/randroid emu stop | delete                    # quit it (by the PID recorded at boot) / delete its AVD

bin/randroid build debug | release               # release is signed when the upload key is present
bin/randroid bundle                               # the signed .aab for Google Play (see Release)
bin/randroid verify-bundle <file.aab>             # upload signature, permanent ID, no bridge
bin/randroid check-release                        # the bridge is absent from the release APK and bundle
bin/randroid doctor
```

The headless session persists between calls in one file, so separate processes see one app, as
separate launches of the app would.

**Devices are addressed only by the serial `emu prepare` recorded.** Never a bare `adb`: a
physical phone may be attached. `emu stop` signals only the PID captured when the emulator was
spawned. At most one emulator per checkout, `-no-window`, stopped as soon as a run ends.

## Pairing the emulator with an isolated test Mac

The app is unchanged: it pairs over real HTTPS on the default trust store. Two helpers in `bin/`:

```sh
RICHOS_MOBILE_CACHE=<scratch>/lab RICHOS_MOBILE_MAC_ORIGIN=https://localhost:8443 \
  node richos/mobile/cli/mobile.mjs lab mac          # the production Rust listener, own identity
bin/emu-pair-front.mjs serve --upstream <lab port> --dir <scratch>/front   # TLS front, throwaway CA
bin/emu-pair-front.mjs trust --serial emulator-NNNN --ca <scratch>/front/ca.pem --reverse 8443:<front port>
bin/emu-pair-front.mjs qr --text-file <link file> --out qr.png            # the link as a QR picture
bin/emu-ui.py --serial emulator-NNNN tap "Use a pairing link instead"     # drive by the words on screen
```

`trust` touches only an emulator (a google_apis image, `adb root`) and lasts until it reboots. A
QR picture goes through the scanner's own reader with the debug bridge's `scan-image` (base64 of
the picture as its argument; the scanner must be open). Stop the lab and the front with SIGTERM.

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
real process restart. `bin/randroid check-release` proves none of this is in a release APK or
bundle.

## Release: the signed bundle for Google Play

**First, the Android app's own suites.** They are not part of the desktop app's nightly build
(CEO, 2026-09-26: the phone apps are independent apps), so a release is where they all run
together. From the repository root:

```sh
richos/app/scripts/run-tests.sh --for android
```

That is every suite `richos/app/scripts/phone-app-suites.tsv` names for Android, including the
ones both phone apps share. Each of them also runs at a land whenever its own inputs change.
Nothing yet refuses a bundle made without this run; it is a step, not a gate.

One command, run from the repository root, makes the bundle Google Play takes. The two private
wrappers (richos-hq, never this repository) supply the Firebase client values and the upload key
through the process environment; nothing secret is on a command line, in Gradle's configuration
or in Git:

```sh
python3 /Users/alex/ab/richos-hq/scripts/with-android-firebase.py \
  python3 /Users/alex/ab/richos-hq/scripts/with-android-signing.py \
  richos/mobile/native-android/bin/randroid bundle
```

It writes `RichConnect-<versionCode>.aab` and a receipt `RichConnect-<versionCode>.json` (commit,
version, signer) under `$RANDROID_CACHE/release/`, after verifying that exact file. It refuses
rather than produce a bundle that would upload and be wrong: without the upload key (unsigned),
without the Firebase values (no notifications), from uncommitted source under this folder (no
commit identifies it; `--allow-dirty` makes a test bundle and the receipt says so), or with a stale
launcher icon.

**What verification means** (`bundle` runs it; `bin/randroid verify-bundle <file.aab>` runs it on
any file): every entry is signed, by exactly one signer, and that signer's SHA-256 is
`release/upload-certificate.sha256` (the upload certificate's public fingerprint); the package is
`dev.richos.connect`; the bundle holds only the `base` module; and the development bridge is
absent, read from the complete dex dump of the bundle's `base` module (the same scan as the APK,
which must also find the app's own `MainActivity`); and the merged manifest passes the release
security policy, `richos/mobile/security/release_policy.py` (not debuggable or test-only, backup
and cleartext off, only the expected components exported, no deep link; security review
2026-09-23, finding R-1). `check-release` applies the same policy to the release APK and bundle.

**Signing.** The release build is signed with the Google Play **upload key**; Play App Signing
holds the key that signs what users install. `app/build.gradle.kts` signs only when the four
`richos.upload.*` Gradle properties arrive from the environment; without them the release build
is unsigned exactly as before, and `check-release` says the signature was not checked. The key
was made once by `richos-hq/scripts/make-android-upload-key.py`, which refuses to replace it; the
setup note is `richos-hq/docs/operations/2026-09-23-richconnect-android-upload-key.md`.

**Version numbers.** `versionName` (what a person reads in Play and in Settings) is set by hand in
`app/build.gradle.kts` for a release; debug builds add `-dev`. `versionCode` (what Play compares) is
**1 for every development build** and, for a bundle, **the number of whole minutes from
2026-01-01T00:00Z (UTC) to the moment `bundle` ran**. So every bundle made later has a higher code,
whatever commit or branch it came from, which is the only rule Play enforces (a new upload's code
must exceed every earlier one). It stays below Play's limit of 2,100,000,000 for about 4,000
years. Two bundles in the same minute share a code; Play refuses the second, which is the right
outcome. The receipt names the commit each code was built from.

**The icon.** `node release/make-app-icon.cjs` writes the adaptive launcher icon (background, foreground
and the Android 13 themed-icon monochrome layer) and `release/play-store-icon-512.png`, the Play
listing icon, from `richos/app/icon-source/richos-icon-1024.png`, the source the iPhone, the PWA
and the desktop app use. `--check` fails on any drift; the suite runs it. Its header says how each
layer is composed and why.

## Versions

minSdk 29, targetSdk 36 (build plan §3.3), compileSdk 37 (the current Compose and lifecycle
libraries refuse to compile against less). Permanent application ID `dev.richos.connect`;
Kotlin package root `dev.richos.android` (`native` is a Java keyword). Gradle 9.7.1 (wrapper,
checksum pinned), AGP 9.4.1, Kotlin 2.4.20, Compose BOM 2026.09.00, Robolectric 4.17.

## Registered proof

`richos/app/scripts/native-android-core.test.sh` (core, CLI, headless processes) and
`richos/app/scripts/native-android-app.test.sh` (Robolectric app tests, `check-release`, the icon's
`--check`, a signed `bundle` made with a throwaway key that `verify-bundle` must then refuse
against the committed upload certificate, and with
`RANDROID_SUITE_EMULATOR=1` the emulator parity, on-screen and restart checks). Both print
`NOT RUN` and exit 2 on a host without the toolchain.
