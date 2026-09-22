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
| `testflight.ts`, `testflight.test.ts` | Upload, status and publish against App Store Connect (adopted from T3 Code, MIT) |
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

## Waiting on the CEO (build plan §6)

1. **Xcode 26** (App Store Connect has refused uploads built with anything older since 2026-04-28).
   Installed beside Xcode 16.4 and chosen per command with `DEVELOPER_DIR`, so the preserved app keeps
   its toolchain.
2. **The production bundle identifier**, permanent once uploaded. One change: `RICHOS_BUNDLE_ID` in
   `platform.yml` and `PRODUCT_BUNDLE_IDENTIFIER` in `../project.yml` (the suite checks they agree).
   The Mac and the Connect Worker must list it as an APNs topic too.
3. **The App Store Connect app record**, the current license agreement, and a team **App Manager**
   API key (not Admin).
4. Confirming **export compliance** in App Store Connect: the binary says
   `ITSAppUsesNonExemptEncryption = NO` because the only cryptography is Apple's own (URLSession
   HTTPS; CryptoKit and Security for P-256 signing and AES-GCM preview decryption).

## Upload, once those exist

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
     DEVELOPMENT_TEAM=<team> CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Distribution"
   ```

3. `node Release/testflight.ts upload --archive <path>/RichOSNative.xcarchive --export-options Release/ExportOptions.plist`
4. `node Release/testflight.ts status --version 0.1.0 --build <n>` until processing is `VALID`.
5. `node Release/testflight.ts publish --version 0.1.0 --build <n> --notes-file <notes>` puts it
   in the internal group. A rerun writes nothing twice.

None of steps 2–5 has run: the App Store Connect record, the key and Xcode 26 do not exist yet. The
tool's behavior is proven against a fake App Store Connect (`testflight.test.ts`, 36 tests).
