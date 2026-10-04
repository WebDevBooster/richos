# Releasing the RichOS native iPhone app

Stream I3's folder: everything between a working app and a build on TestFlight. Every command runs on
this Mac from the command line; nothing here needs Simulator.app or opens a window.

## What is here

| File | What it does |
|---|---|
| `platform.yml` | The two extensions, purpose strings, export compliance, entitlements and icon, merged into `../project.yml` by one `include:` line |
| `generate.sh` | The merged Xcode project into the cache, until that line lands |
| `check-release.sh` | Builds Debug and Release and checks the Release product (R1–R9 in its header) |
| `platform-tests.sh` | The notification and share platform tests, on this Mac, no simulator |
| `simulator-tests.sh` | The share sheet, platform effects and notification platform on one simulator it creates and deletes; writes share-sheet snapshots |
| `make-app-icon.cjs` | The icon at every size from `richos/app/icon-source/richos-icon-1024.png`; `--check` finds drift |
| `testflight.ts`, `testflight.test.ts` | Upload, status and publish against App Store Connect (adopted from T3 Code, MIT); the store listing's check, apply and the App Review submit (RichOS) |
| `ExportOptions.plist` | The export options the upload uses |
| `App-Info.plist`, `RichOSNative.entitlements` | The app's keys and entitlements a build setting cannot express |
| `third-party/T3-Code-LICENSE.txt` | T3 Code's MIT notice for the adopted files |

## Proven here, on this Mac

```sh
richos/mobile/native-ios/Release/platform-tests.sh /Volumes/E1TB/caches/<you>/platform-tests
richos/mobile/native-ios/Release/check-release.sh  /Volumes/E1TB/caches/<you>/release
richos/mobile/native-ios/Release/simulator-tests.sh /Volumes/E1TB/caches/<you>/simulator
node --test richos/mobile/native-ios/Release/testflight.test.ts
node richos/mobile/native-ios/Release/make-app-icon.cjs --check
```

The suite `richos/app/scripts/native-ios-share.test.sh` runs all five.

## Account and distribution setup

1. **Xcode 26** (App Store Connect has refused uploads built with anything older since 2026-04-28).
   Installed beside Xcode 16.4 and chosen per command with `DEVELOPER_DIR`, so the preserved app keeps
   its toolchain.
2. **Register the permanent bundle identifier `dev.richos.connect`** with Push Notifications and
   App Groups. Register its `.notification-service` and `.share` extension identifiers and
   `group.dev.richos.connect`; assign that App Group to the app and Share extension. The source,
   CLI and push registration use this ID. Enable the same topic in the private Connect profile
   after verifying the APNs keys cover it.
3. **The App Store Connect app record**, the current license agreement, and a team **App Manager**
   API key (not Admin).
4. Confirming **export compliance** in App Store Connect: the binary says
   `ITSAppUsesNonExemptEncryption = NO` because the only cryptography is Apple's own (URLSession
   HTTPS; CryptoKit and Security for P-256 signing and AES-GCM preview decryption).

## Upload, once those exist

**First, the iPhone app's own suites, including the middle iPhone size.** They are not part of the
desktop app's nightly build (CEO, 2026-09-26: the phone apps are independent apps), so a release is
where they all run together, and where `native-ios-app.test.sh` case A8 runs: the UI and unit tests
on the middle screen size, which the CEO ruled off every land on 2026-09-23 and which took 1238 s on
its own on 2026-09-25. From the repository root:

```sh
RICHOS_NATIVE_IOS_APP_A8=1 richos/app/scripts/run-tests.sh --for ios
```

That is every suite `richos/app/scripts/phone-app-suites.tsv` names for iOS, including the ones both
phone apps share. Each of them also runs at a land whenever its own inputs change (A8 excepted).
Nothing yet refuses an upload made without this run; it is a step, not a gate.

**The speed test IS a gate** (CEO 2026-10-03, §106: nothing reaches users without passing the speed
tests). Every archive carries the commit it was built from: the app target's last build step, on an
archive only, writes `RichOSSourceCommit` (the checkout's HEAD) and `RichOSSourceDirty` (whether it had
uncommitted app code) into the archived app's Info.plist (`platform.yml`, `shipgate.py stamp`).
`testflight.ts upload` reads that commit from the archive and refuses unless the phone speed watch has a
§104 PASS, cold and warm, for its exact app code on the iPhone test phone
(`richos/mobile/perf/shipgate.py`); an archive with no stamp, or built with uncommitted app code, is
refused. It runs before credentials, App Store Connect or Xcode, and records the commit it uploaded
(`/Volumes/E1TB/state/richos/ship-gate/testflight-uploads.json`). `testflight.ts publish` refuses a build
with no such record and gates the recorded commit again, so a limit tightened since the upload still
stops it. The checkout running `upload` must have the archive's commit. No flag skips the gate.

1. Put the API key in a private file outside every checkout (the tool refuses one inside a git
   working tree, or with any mode but 600):

   ```dotenv
   # ~/.config/richos/testflight.env, mode 600
   RICHOS_IOS_ASC_KEY_ID=KEY_ID
   RICHOS_IOS_ASC_ISSUER_ID=ISSUER_UUID
   RICHOS_IOS_ASC_PRIVATE_KEY_BASE64=BASE64_OF_THE_DOWNLOADED_P8_FILE
   RICHOS_IOS_ASC_APP_ID=APP_ID
   RICHOS_IOS_ASC_BUNDLE_ID=THE_PRODUCTION_BUNDLE_ID
   RICHOS_IOS_ASC_INTERNAL_GROUP_ID=INTERNAL_GROUP_UUID
   # RICHOS_IOS_ASC_PUBLIC_GROUP_ID=  only for external testing, which needs Beta App Review
   ```

2. Archive with Xcode 26 and the Apple team (signing is the team's, not this folder's), bump
   `CURRENT_PROJECT_VERSION` first:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode-26.app/Contents/Developer xcodebuild archive \
     -project <generated project> -scheme RichOSNative -configuration Release \
     -destination 'generic/platform=iOS' -archivePath <path>/RichOSNative.xcarchive \
     DEVELOPMENT_TEAM=<team> CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development"
   ```

   The identity is `Apple Development` on purpose: with automatic signing Xcode refuses `Apple
   Distribution` ("conflicts with automatically signed targets"). The upload step's export re-signs
   for App Store Connect (`ExportOptions.plist`, method `app-store-connect`).

   Before the upload, prove the archive is iPhone only (Apple refused the first upload with errors
   90023 and 90474 when every target also declared iPad):

   ```sh
   python3 Release/check_device_family.py <path>/RichOSNative.xcarchive
   ```

3. `node Release/testflight.ts upload --archive <path>/RichOSNative.xcarchive --export-options Release/ExportOptions.plist`
4. `node Release/testflight.ts status --version 1.0.0 --build <n>` until processing is `VALID`.
5. `node Release/testflight.ts publish --version 1.0.0 --build <n> --notes-file <notes>` puts it
   in the internal group. A rerun writes nothing twice.

**The App Store listing is the record, and only a proven version goes to App Review** (CEO
2026-10-04). The listing record is the private record repository's
`docs/operations/*-listing-state.json`: name, subtitle, description, keywords, promotional text,
privacy and support URLs, the version, and `screenshotsDir` (the screenshots folder, relative to that
repository, shown in file-name order).

- `node Release/testflight.ts check-listing --record <record>` reads the live listing and exits 1
  naming every field, and every screenshot position, that differs from the record.
- `node Release/testflight.ts apply-listing --record <record>` sets the differing text fields from the
  record, replaces the screenshots only when they differ, then runs the same check. It never submits.
- `node Release/testflight.ts submit --record <record>` is the only way this Mac sends a version to App
  Review. It refuses, with no option to skip, unless check-listing passes, the build selected on the
  version was uploaded by this tool (so its archive's stamped commit is recorded), that commit has the
  speed pass (`shipgate.py`, §106) and the review walk passed on it (`reviewwalk.py`, §107).

A simulator release check does not prove signing or TestFlight upload. Verify the account record,
API key and current distribution toolchain before running steps 2–5. The tool is tested against a
fake App Store Connect (`testflight.test.ts`).
