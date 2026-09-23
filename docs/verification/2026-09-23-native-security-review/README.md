# Native RichConnect apps: security review, 2026-09-23

**Reviewer:** Tom (QA, automation and security), `tom-opus-sec1`. **Read at:** richos `4edbfce1` (main), both
`richos/mobile/native-android/` and `richos/mobile/native-ios/`. **Method:** source read with file:line, the
merged Android manifests of a release and a debug APK built from this SHA, `randroid check-release`, and
four proof tests run red against this SHA (`red-run-4edbfce1.txt`). Nothing ran on a device, an emulator or
a simulator; nothing was paired, registered or sent. Read-mostly: no product file was edited.

Severity: **High** can be exploited by another app on the phone today with real impact; **Medium** is a
real defect with a bounded impact or a release-check gap; **Low** is defense in depth or a narrow window;
**Info** is design or operations, recorded for the owner.

## What to fix, in order

| ID | Sev | Platform | Finding | Owner |
|---|---|---|---|---|
| A-1 | **High** | Android | Any installed app can make RichConnect send text and files to Rich **as the user, with no press** | Andy |
| A-3 | Medium | Android | Share and pick intake reads whole streams into memory before any limit, stages any count, and leaves refused copies on disk | Andy |
| A-5 | Medium | Android | An FCM token rotation can be dropped, and nothing re-registers at launch, so push stops silently | Andy |
| R-1 | Medium | Android | `check-release` proves the bridge is absent and nothing else a store build must not carry | Tom (rules, done) + Andy (one call) |
| R-2 | Medium | iPhone | The archive that is uploaded is never scanned; the release check scans a separate simulator build | Isaac |
| A-2 | Low | Android | The stager opens any URI with the app's own rights (`file://` into private storage proven) | Andy |
| A-4 | Low | Android | The preview key is never discarded or rotated; the service ignores `host` and the local previews choice | Andy |
| A-6 | Low | Android | No `dataExtractionRules`: Android 12+ device-to-device transfer copies the conversation cache despite `allowBackup=false` | Andy |
| A-7 | Low | Android | The six-word "They match" press has no overlay (tapjacking) protection on Android 10 and 11 | Andy |
| I-1 | Low | iPhone | "Forget" never erases the preview key; the unregistration it relies on is best effort | Isaac |
| I-2 | Low | iPhone | Conversation state and attachments are in iCloud and Finder backups; after a restore a new identity key is minted silently | Isaac |
| I-3 | Low | iPhone | The Share extension treats an unknown file size as zero and copies the file | Isaac |
| I-4 | Low | iPhone | The identity key lands in the Keychain group both extensions can read | Isaac |
| X-1 | Low | both | No screen-capture or app-switcher cover on either app | product decision (Urban) |
| A-9 | Info | Android | A second, weaker `forget` path survives in the core (not reachable from the screens) | Andy |
| X-2 | Info | protocol | The six words verify a claimed CA hash, not the channel or the origin the phone used | Sage review, Echo |
| X-3 | Info | both | Event-stream line buffers are unbounded | Andy, Isaac |
| X-4 | Info | operations | Restrict the Firebase Android API key in Google Cloud to the package and Play signing certificate | Zach |

Every item below carries the fix and the test, ready to brief. The two Android proof tests are in
`proof-tests/` as `.kt.txt` (not compiled here; drop the `.txt` at the destination path each names); they are red at `4edbfce1` for the reasons recorded.

---

## A-1 (High). The Android share target sends without the person

**Evidence.**
- `ShareActivity` is exported with `SEND` and `SEND_MULTIPLE` filters, including `text/*`
  (`native-android/app/src/main/AndroidManifest.xml:34-59`). Export is required for a share target, and an
  exported activity can be started by ANY app with an explicit intent, which skips the system chooser.
- `ShareActivity.onCreate` reads the intent, stages its streams and calls `ShareToRich.share` at once, then
  `finish()`es (`platform/ShareToRich.kt:84-97`). There is no window (`Theme.NoDisplay`), no confirmation,
  no caller check.
- `Action.Share` with text and no files enqueues an ordinary text message on the selected conversation
  (`core/.../RichCore.kt:74-92`), byte-identical to one the person typed (`Wire.text`). Rich cannot tell it
  apart.
- The designed flow is a compose sheet with a Send press: `ShareCompose` (`ui/attach/AttachOverlays.kt:236`),
  cataloged as `share-compose` *"a translucent share-target activity with our sheet, over the app shared
  from"* (`ui/catalog/AttachCatalog.kt:152`). `ShareActivity` does not use it. The iPhone extension does
  (the person presses Send, `ShareExtension/Sources/ShareModel.swift:101-135`).
- **Proven:** `proof-tests/ShareConsentTest.kt.txt` starts `ShareActivity` with an explicit intent carrying
  only `EXTRA_TEXT` and finds the message queued: `expected:<0> but was:<1>`.

**Impact.** Any app the person has installed, while it is in the foreground (a game, a keyboard's
companion app, a compromised SDK inside a trusted app), can put words into Rich's conversation that
Rich reads as the person's own instruction, and can attach files it chooses. Rich acts on the Mac with
tools. The only trace on the phone is a toast that says "Sent to Rich." This is prompt injection with the
user's identity and no user action.

**Fix.** Show the existing `ShareCompose` sheet in `ShareActivity` (translucent theme, not `NoDisplay`),
stage for preview only, and dispatch `Action.Share` only from the sheet's Send press. Drop `text/*` from
the filters unless plain-text sharing is a v1 decision (the iPhone leaves it out on purpose,
`ShareExtension/Info.plist:3-8`). Set `filterTouchesWhenObscured` on the Send control (see A-7).
Reference: the T3 iOS read row E3, *"The share extension never sends the draft"*
(`richos-hq/docs/research/2026-09-22-t3-swiftui-ios-app-read.md:139`): COPY THE DESIGN, because on RichOS
a shared line reaches an agent with tools on the Mac, so the person's press is the consent.

**Test.** `proof-tests/ShareConsentTest.kt.txt` into `app/src/testDebug/.../debug/`: red now, green with the
fix. Add a second case: pressing Send on the sheet does queue exactly one message (the positive probe).

## A-3 (Medium). Android intake is unbounded

**Evidence.** `Stager.stage` reads the whole stream with `readBytes()` before any size is known
(`platform/Attachments.kt:64`); images are decoded first (`:61-62`). `ShareActivity` stages every URI in
`EXTRA_STREAM` (`ShareToRich.kt:92`) and the core's limits (`RichCore.kt:331-339`: 10 files, 25 MiB per file,
the Mac's `MAX_FILE_BYTES` at `app/src-tauri/src/phone/attachments.rs:64`) run only afterward. When the core
refuses, the staged copies in `files/staged/` are never deleted (`ShareToRich.kt:92-94`; the picker path has
the same shape at `Attachments.kt:125-131`).

**Impact.** One share of a large or endless stream crashes RichConnect (out of memory). A share of many
items stages all of them. Every refused share leaves its copies behind, so repeated shares grow app
storage without bound. With A-1 unfixed, another app can do this silently.

**Fix.** Read through a counting stream that stops at `maxFileBytes + 1` and refuses; stop staging at
`maxFilesPerMessage`; delete staged files for any share that is refused or abandoned (and on the sheet's
Cancel once A-1 lands).

**Test.** A Robolectric test registering a `ContentProvider` that serves 26 MiB (and one that never ends):
`stage` refuses without allocating the whole stream; a SEND_MULTIPLE with 11 URIs stages at most 10; after
a refused share `files/staged/` is empty.

## A-5 (Medium). Android can lose an FCM token rotation

**Evidence.** `RichMessagingService.onNewToken` re-registers only if `store.states.value` already says
notifications are on (`platform/Notifications.kt:211-219`). When FCM starts the process to deliver a new
token, the core opens asynchronously (`app/RichApplication.kt:74-85`), so `states.value` can still be null;
`AppStore.dispatch` also returns silently when there is no core (`app/AppStore.kt:74-75`). Nothing
re-requests the token at launch: `requestNotifications` runs only on Turn on and on a previews change
(`RichCore.kt:530-546`). The iPhone re-registers on every launch (`App/Platform/NotificationPlatform.swift:26-34`).
Inferred from the code; not reproduced on a device.

**Impact.** The Mac keeps the old token, FCM answers unregistered, the Worker clears the binding, and
replies stop arriving until the person turns notifications off and on.

**Fix.** When the production core opens with notifications on, call `platform.requestNotifications(previews)`
(FCM returns its cached token) and let `pushToken` register only when the token differs from the last one
registered (keep a hash of it in the session). In `onNewToken`, wait for the store's first state instead of
reading `.value`.

**Test.** A core test with a recording `Platform`: opening a session whose notifications are on calls
`requestNotifications` once; a `PushToken` equal to the last registered one sends nothing; a different one
registers.

## R-1 (Medium, test code: fixed here). The Android release check covers only the bridge

**Evidence.** `randroid check-release` scans class names in two packages and three manifest strings
(`native-android/bin/randroid:322-357`). A release manifest with `android:debuggable=true`, backup on,
cleartext on, a network security config trusting user certificates, a new exported component or a deep
link passes it unchanged (`:333`, `:352`). `debuggable` alone would let anyone with USB access read
`files/core/session.json` through `run-as`.

**What is committed.** `richos/mobile/security/release_policy.py` and the suite
`richos/app/scripts/native-release-policy.test.sh` (auto-discovered by `run-tests.sh`, under a second):
- Android rules on a merged manifest: package, not debuggable, not test-only, backup off, no cleartext and no
  network security config, exported components exactly the launcher, the share target and library
  receivers behind `c2dm.SEND`, `DUMP` or `BIND_JOB_SERVICE`, no VIEW or BROWSABLE filter, no bridge marker.
- Repository rules: no tracked credential file (google-services.json, keystores, `.p8`, profiles), no
  Google API key literal anywhere, no private key in the native trees, no custom TLS trust or ATS exception,
  no URL scheme or deep link, no log call in production code, iOS entitlements limited to push, the App
  Group and the Keychain group.
- **Failing then passing:** `self-test` mutates the recorded release manifest and a scratch tree once per
  rule; each mutation must fail exactly its rule (15 mutations), the debug manifest of the same build must
  fail (A2, A6, A8), and only then do the real inputs pass. Before this suite, no check in the tree
  looked for any of them (`grep -rlE 'AIza|google-services|X509TrustManager|NSAllowsArbitraryLoads'
  richos/app/scripts richos/engine/scripts` is empty, and `check-release` reads three strings).

**Ready to brief (Andy, after the release-signing change lands).** In `check_release`, after the bridge
scan: `aapt2 dump xmltree --file AndroidManifest.xml "$release" | python3 "$ROOT/richos/mobile/security/release_policy.py" android-manifest -`,
and the same on the bundle `randroid bundle` produces (the file Play receives). Test: the existing
`native-android-app.test.sh` then fails on a debuggable release.

## R-2 (Medium). The iPhone upload is not the build that was checked

**Evidence.** `Release/check-release.sh:29-37` builds its own Debug and Release for the simulator SDK and
scans those (R8 at `:148-163`). `testflight.ts upload` validates only the archive's bundle ID, platform and
export options (`Release/testflight.ts:526-543`) before `-exportArchive` (`:559-590`). An archive built
from a Debug configuration, or with a debug entitlement, would be uploaded.

**Fix.** Before export, run the R8 marker scan over every Mach-O in the archive (`RichOSNative`, any
`*.debug.dylib`, both `.appex`), read the signed entitlements (`codesign -d --entitlements :-`) and refuse
`get-task-allow`, and require `aps-environment=production`.

**Test.** A `testflight.test.ts` case with a fixture archive whose binary carries `rios-fixture`: upload
refuses before any Xcode call.

## A-2 (Low; proven). The Android stager opens any URI with the app's rights

**Evidence.** `Stager.stage` passes whatever URI it is given to `ContentResolver.openInputStream`
(`platform/Attachments.kt:53-67`), which also opens `file://` paths with RichConnect's own permissions.
**Proven:** `proof-tests/PlatformSecurityTest.kt.txt` staged `files/core/session.json` (21 bytes).

**Why Low today.** The core refuses types the Mac does not take (`RichCore.kt:338`), the type of a `file://`
URI comes from its extension, no private file has an accepted extension today, and the Mac sniffs content
(`phone/attachments.rs:119`). Any future private file named `.jpg`, `.pdf` or `.txt` would be sendable by
another app (with A-1) to the person's own Mac.

**Fix.** Accept only `content://` URIs whose authority is not one of this package's own; refuse everything
else before opening. **Test:** `proof-tests/PlatformSecurityTest.kt.txt` first case, red now.

## A-4 (Low; proven). The Android preview key outlives its purpose

**Evidence.** `PreviewKeys.key()` returns the stored key forever (`platform/Notifications.kt:52`): it is not
discarded when previews are turned off (`:145-161`) or when notifications are unregistered (`:163-165`), and
it is not rotated when the phone pairs with another Mac (the iPhone rotates per origin,
`App/Platform/Shared/NotificationPreview.swift:140-148`). `onMessageReceived` decrypts whatever arrives
without checking `host` against the registered `pushHostId` or the person's previews choice (`:221-226`); the
iPhone extension honors the local choice (`NotificationService/Sources/NotificationService.swift:26-28`). A
key file that no longer opens (after a device transfer, see A-6) makes `key()` throw, so previews stay off
with no message (`:59-67`, `:159`). **Proven:** both key cases in `proof-tests/PlatformSecurityTest.kt.txt`.

**Fix.** Delete the key file on previews off and on unregister; replace an unreadable file with a fresh key;
show the generic line when `host` differs from `pushHostId` or previews are off. **Test:** the two key cases
in `proof-tests/PlatformSecurityTest.kt.txt`, plus a service case with a foreign `host`.

## A-6 (Low). Android device-to-device transfer is still on

**Evidence.** `android:allowBackup="false"` (`AndroidManifest.xml:18`) and no `android:dataExtractionRules`
(the merged manifest, `richos/mobile/security/fixtures/release-manifest-4edbfce1.txt:32-39`). For apps
targeting Android 12 or higher, `allowBackup=false` stops cloud backup but not device-to-device transfer
([Android Developers, Auto Backup](https://developer.android.com/identity/data/autobackup)). The transfer
would copy `files/core/session.json` (up to 100 cached rows per conversation, the pairing and device id,
`core/.../State.kt:67-105`) to the new phone, where the Keystore key does not exist.

**Fix.** Add `dataExtractionRules` excluding every domain under both `<cloud-backup>` and
`<device-transfer>`. **Test:** a `release_policy.py` rule once the attribute exists (A4 extended to require
it), and a resource test that the rules file excludes `root`, `file`, `database` and `sharedpref`.

## A-7 (Low). No overlay protection on the six words

The "They match" press confirms a pairing. Android 12+ blocks touches through untrusted overlays; RichConnect
supports Android 10 and 11 (`minSdk = 29`, `app/build.gradle.kts:23`). **Fix:** `filterTouchesWhenObscured`
(Compose: a `pointerInteropFilter` that drops `FLAG_WINDOW_IS_OBSCURED` events) on the six-word answers and
on the share Send. **Test:** a Robolectric touch with `FLAG_WINDOW_IS_OBSCURED` dispatches nothing.

## I-1 (Low). The iPhone keeps the preview key after "Forget"

`PreviewKeyStore.erase()` (`App/Platform/Shared/NotificationPreview.swift:158-162`) is called only by tests
(`PlatformTests/PlatformEffectsTests.swift:113-114`). "Forget" sends the unregistration best effort and only
when a client exists (`Core/Sources/RichOSCore/Connection/NetworkEffects.swift:136-141`;
`Settings/SettingsReducer.swift:32-42`). If the Mac does not hear it, sealed previews keep opening on a
phone whose app shows no pairing. **Fix:** erase the preview key in the `.forgetIdentity` handling on the
app side. **Test:** a `PlatformEffectsTests` case: after `confirmForget`, `PreviewKeyStore.load().key == nil`.

## I-2 (Low). iPhone state is in backups

`AppStore.defaultStorage()` keeps state in Application Support, *"which is backed up"*
(`App/App/AppStore.swift:67-71`); attachments too (`App/App/ShareIntake.swift:15-18`). Recordings are excluded
(`App/Platform/VoicePlatform.swift:84-88`), Android excludes everything (A-6). After a restore the identity key
is absent (`…ThisDeviceOnly`, `Core/Sources/RichOSCore/Protocol/Identity.swift:104-110`) and `signer(for:)`
mints a new key for the old pairing without saying so (`:46-51`). **Fix (owner's call):** mark the
`RichOS/` directory `isExcludedFromBackup`, and treat a missing key for a paired origin as "pair again".
**Test:** a platform test that the storage directory carries the exclusion; a core test that a paired state
with no key shows `revoked`, not a silent new key.

## I-3 (Low). iPhone Share extension: unknown size counts as zero

`SharePayloadLoader.swift:84-85` reads `fileSize ?? 0`, so a provider that reports no size is copied whatever
its size; `ShareInbox.write` then reads it whole before its own check (`ShareInbox.swift:194-196`). Share
extensions have a small memory limit, so a very large item ends the extension. **Fix:** read the size of the
copy with `attributesOfItem` and refuse above `maxFileBytes` before normalizing. **Test:** a
`ShareExtension/Tests` case with a provider whose file reports no size and exceeds the limit.

## I-4 (Low). The identity key is readable by both extensions

`KeychainIdentityStore()` is created with no access group (`App/App/RichOSNativeApp.swift:33`), so on a
device the key is added to the first `keychain-access-groups` entry, the shared group
(`Release/RichOSNative.entitlements:14-17`), which the notification extension also holds
(`NotificationService/NotificationService.entitlements:6-9`). The notification extension parses remote
payloads and needs only the preview key. **Fix:** store the identity key under the app's own
`application-identifier` group (or give only the Share extension the shared group when it starts signing).
**Test:** a platform test that the stored item's `kSecAttrAccessGroup` is not the shared group.

## X-1 (Low). Screens can be captured and appear in the app switcher

Neither app sets `FLAG_SECURE` (`app/MainActivity.kt:36-67`) or covers its window on resign-active. A
conversation shows in Recents thumbnails and screenshots. This is a product decision: a privacy-screen
option, as messaging apps offer, costs the ability to screenshot. Routed to Urban, not decided here.

## A-9 (Info). A weaker `forget` still exists

`Action.Forget` (`RichCore.kt:488-494`) keeps the conversation cache and does not unregister; the screens use
`ConfirmForget` (`:555-563`, `ui/UiEvent.kt:128-129`), which does both. The old path is reachable from the
CLI and the debug bridge only. **Fix:** route `Forget` through the same code as `ConfirmForget` or remove it.

## X-2 (Info, for Sage). What the six words prove

The phone derives the words from `ca_fingerprint_sha256` as the Mac's answer states it
(`core/.../protocol/Fingerprint.kt:24-28`; `Core/Sources/RichOSCore/Pairing/PairingReducer.swift:31-45`). The
phone never meets that authority in TLS (both routes present public chains, contract §1.1), so the words
prove "the server I reached claims my Mac's CA hash". A relay that has the pairing code (seen on the Mac's
screen) and gets the person to use its link passes the check. Deriving the words from the CA hash AND the
origin the phone actually connected to would bind them to the channel; that is a Mac, protocol and
conformance change, so it is recorded for Sage's review, not briefed.

## X-3 (Info). Event-stream lines are unbounded

`URLSessionTransport.open` appends bytes until a newline (`Core/Sources/RichOSCore/Protocol/URLSessionTransport.swift:57-63`);
the Android parser has no line bound either (`core/.../protocol/Sse.kt`). Only the paired Mac or the path to
it can send an endless line. **Fix:** cap a line at the Mac's largest frame and reconnect past it.

## X-4 (Info, operations). Restrict the Firebase API key

The Android API key is public by design (it is in the APK). Google recommends restricting it to the Android
app (package `dev.richos.connect` and the Play app signing certificate's SHA-1) and to the Firebase APIs the
app calls. Needs the Play signing certificate first.

---

## Checked and clean (with the evidence)

- **Keys at rest.** Android: non-exportable P-256 in the Keystore, StrongBox first, TEE otherwise, one per
  origin (`platform/KeystoreKeys.kt:74-100`); removed on uninstall. iPhone: Secure Enclave key, stored only as
  its enclave handle, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not in backups
  (`Identity.swift:64-71`, `:104-110`). No user-presence requirement on either, correctly: the phone signs
  in the background. The Android preview key is wrapped by a Keystore AES-GCM key (`Notifications.kt:51-106`);
  the iPhone's is a `…ThisDeviceOnly` Keychain item (`NotificationPreview.swift:122-135`).
- **Nothing secret in logs or crash reports.** No log call in any production source of either app (rule
  L1, zero matches). No crash-reporting or analytics SDK: the only Android runtime library beyond AndroidX and
  Compose is `firebase-messaging` (`gradle/libs.versions.toml`); Firebase is initialized only when the person
  turns notifications on (`Notifications.kt:120-126`).
- **Nothing secret in Git.** No `google-services.json`, keystore, `.p8` or profile is tracked, and none was
  ever committed on any branch (`git log --all -- '*google-services*' '*GoogleService-Info*' '*.jks'
  '*.keystore' '*.p8'` is empty); no `AIza…` key and neither Firebase identifier appears in any branch
  (`git log --all -S'173300173658'` is empty). The Firebase values reach builds only through
  `richos-hq/scripts/with-android-firebase.py`, as environment variables, never arguments. The in-progress
  release-signing change (`cc/andy-opus-rel2`, uncommitted, read only) takes all four upload-key values from
  Gradle properties set by a wrapper, with no path or password in the tree. Rule G1 and G2 now keep it so.
- **Transport and trust.** HTTPS only, host names only so SNI carries the name, no redirects
  (`platform/HttpsMac.kt:30-40`; `URLSessionTransport.swift:14-19`, `:74-78`, ephemeral with no cache or
  cookies). No custom trust manager, network security config, ATS exception or pinning in either app (rule T1).
- **Pairing.** The link parser is strict and refuses anything but one HTTPS origin with one `pair` code
  (`protocol/PairLink.kt:23-43`); scanners hand text to it and never follow a URL. Words are computed on the
  phone. Nothing is sent before the words are confirmed (`MacTransport.kt:107-113`). "They do not match"
  discards the pairing and the key on the same press (`RichCore.kt:449-470`; `PairingReducer.swift:60-68`).
- **Replay and dedup.** Client ids are random (`app/AppPorts.kt:54`, `ShareToRich.kt:43`); the outbox keeps
  the exact request bytes (`State.kt:141-142`), so a replay or a retry hits the Mac's receipt on
  `(device_id, client_id)` plus the body hash. Both apps pass the conformance corpus (`retry.json`).
- **When a Mac removes the phone.** The Mac clears the push registration and revokes the device id
  (contract §2.6); the phone sees 403 or an unreachable Mac and offers pairing again (`RichCore.kt:168-171`,
  `:283-284`). Nothing on the phone keeps working against that Mac.
- **Push content.** The FCM data message and the APNs payload carry only hashed references and the sealed
  preview; decryption is AES-256-GCM bound to the thread and event (`core/.../protocol/NotificationPreview.kt:28-50`;
  `NotificationPreview.swift:40-63`). Nothing readable reaches Google or Apple.
- **Notification taps.** Android opens the launcher intent through an immutable PendingIntent with no
  extras (`Notifications.kt:252-253`), so a tap can open nothing else. The iPhone accepts only three
  exact-hex keys and a matching host and conversation (`NotificationTarget.swift:21-41`,
  `NotificationTapRouter.swift:10-14`).
- **Exported Android components** in the merged release manifest: `MainActivity` (launcher), `ShareActivity`
  (see A-1), `FirebaseInstanceIdReceiver` behind `c2dm.permission.SEND`, `ProfileInstallReceiver` behind
  `DUMP`. Every provider and service is unexported. No deep link, no URL scheme on either platform (rule T2).
- **Development code out of Release.** Android: `check-release` green at this SHA (0 bridge classes in 3,669;
  77 in the debug APK as the positive probe). iPhone: `DevBridge` is `#if DEBUG` and excluded by file name
  (`project.yml:67-70`); fixtures and commands are `#if DEBUG` (`Core/Sources/RichOSFixtures/*.swift:1-4`);
  R8 scans the app and both extensions against the debug positive probe (see R-2 for the gap).
- **Purpose strings** (iPhone): microphone, camera, photo library and local network, each saying what, when
  and where it goes (`Release/platform.yml:50-53`), checked word for word by R2. Android asks for the
  microphone and notifications at the moment of use.
- **iPhone Share extension**: offered only for the Mac's types and at most 10 items
  (`ShareExtension/Info.plist:16`), limits enforced again before writing (`ShareInbox.swift:179-201`), the
  inbox resolves symlinks and refuses paths outside it (`ShareInbox.swift:303-306`, `:315-323`), and the person
  presses Send.

## Premises in the brief, re-derived

- The setup record is at `richos-hq/docs/plans/2026-09-23-mobile-setup-decisions-and-review-access.md`, not
  `docs/operations/` (commit `d64526d9`). Read in full, with the FCM receipt.
- The report path: this repository has no `richos/docs/`; it follows the existing `docs/verification/` at
  the repository root.
- iPhone identifiers are still `dev.richos.native.ios` (`project.yml:58`, `Release/platform.yml:30`), as the
  brief says; the Android ID is `dev.richos.connect` (`app/build.gradle.kts:20`, and the merged manifest).
- The "new Android release-signing setup" is not on main; it is uncommitted in `cc/andy-opus-rel2` and was
  read, not reviewed as landed.
- Mac limits: 25 MiB per file, 10 files, 100 MiB per message (`app/src-tauri/src/phone/attachments.rs:64-67`).

## Surfaces

| Surface | Checked | How |
|---|---|---|
| Android app, share target, FCM service | yes | source, merged release and debug manifests, 4 Robolectric proof tests |
| iPhone app, Share and notification extensions | yes | source, entitlements, plists, release tooling (no simulator run) |
| Release artifacts | Android yes, iPhone source only | `check-release` at `4edbfce1`; iPhone archive path read |
| First run / returning user | yes, by code | pairing, forget and re-pair paths (A-4, A-9, I-1, I-2) |
| Denied permissions | yes, by code | notifications denied path (`Notifications.kt:150-153`), microphone mirror |
| Offline / reconnect | yes, by code | share while offline queues (A-1 test uses the offline fixture), token rotation (A-5) |
| Light and dark themes | not applicable | no user interface was changed or judged |
| Physical devices, push delivery | not applicable | no device assigned; nothing paired or registered |

Contrast: not applicable; nothing a person reads was produced.
