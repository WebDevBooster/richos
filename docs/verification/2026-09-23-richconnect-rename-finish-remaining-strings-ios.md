# RichConnect rename, finished — every remaining self-naming string — native iOS

CEO directive, 2026-09-23, verbatim: *"From now on, the mobile app in general will be called
RichConnect."* (§79.) This pass covers what the first pass (`ec2dce55`/`5d89037d`, merged
`ef15ba64`: home-screen label + screens 9/10/12) left: every other place the phone app names
ITSELF "RichOS" in text a person reads. Wording taken verbatim from round-12.1
(`richos-hq/design/mockups/rounds/round-12.1/NOTES.md`) wherever it exists there.

Scope: `richos/mobile/native-ios/` only. Continuing `isaac-sonnet-rc2` (its run ended before it
committed or ran its proof): the edits were found already correct and complete against the brief
and round-12.1 on inspection, committed unchanged by the lead as `e96a297b`. This session's own
work was the audit (confirming the edits matched the brief and finding nothing left to rename),
running the proof to completion, and this record.

## Renamed (old → new), file:line — from `e96a297b`

- `App/Features/Attachments/AttachmentViews.swift:520` `AttachCards.attachCameraDenied`
  (attach-camera-denied): "The camera is off for RichOS" → **"The camera is off for
  RichConnect"** — matches `shared/screens.js`'s pairing-flow wording, applied to the
  in-conversation attach flow's own camera-denied card (same class as Android's
  `AttachComposer.kt:244`).
- `App/Features/Attachments/AttachmentViews.swift:532` `AttachCards.attachPhotosDenied`
  (attach-photos-denied): "RichOS can't see your photos" → **"RichConnect can't see your
  photos"** (curly apostrophe preserved).
- `App/Features/Conversation/ConversationChrome.swift:217` `AboveComposer.microphoneDenied`
  (rec-mic-denied, screen 45): "The microphone is off for RichOS" → **"The microphone is off
  for RichConnect"** — verbatim match, `shared/screens.js:139`.
- `App/Features/Pairing/Takeovers.swift:96` `TakeoverView.updateRequired` (upd-blocking,
  screen 63): "This version of RichOS can no longer send" → **"This version of RichConnect can
  no longer send"** — verbatim match, `shared/screens.js:165`.
- `App/Features/Settings/Overlays.swift:51` `DialogView.cameraDenied` (pair-camera-denied,
  screen 3): "The camera is off for RichOS" → **"The camera is off for RichConnect"** —
  verbatim match, `shared/screens.js:86`.
- `App/Features/Settings/Overlays.swift:55` `DialogView.update` (upd-dialog, screen 62): "A new
  RichOS is ready" → **"A new RichConnect is ready"** — verbatim match,
  `shared/screens.js:164`.
- `App/Features/Settings/Overlays.swift:329` `UpdateBannerView` (upd-banner, screen 61):
  "RichOS \(version) is ready" → **"RichConnect \(version) is ready"** — matches the pattern in
  `shared/screens.js:163` ("RichConnect 1.1 is ready").
- `App/Features/Settings/Overlays.swift:336` `UpdateBannerView`'s accessibility label: "Update
  RichOS in the App Store" → **"Update RichConnect in the App Store"** (VoiceOver reads the
  same name as the visible banner).
- `Release/platform.yml:50-53` the four permission purpose strings
  (`NSMicrophoneUsageDescription`, `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`,
  `NSLocalNetworkUsageDescription`) — Apple's own system permission dialogs, which show this
  text verbatim: "RichOS records/uses/sends/uses…" → **"RichConnect records/uses/sends/uses…"**
  in each. These had gone factually stale the moment the app's display name became RichConnect
  (`project.yml:60`, first pass): the system dialog's title already reads "RichConnect" (from
  `CFBundleDisplayName`), so the purpose string under it still saying "RichOS" was a real
  inconsistency, not cosmetic.
- `ShareExtension/Sources/ShareModel.swift:68,89,112` (three `.failed(...)` messages the Share
  extension shows when it cannot proceed): "RichOS could not open its shared storage… Open
  RichOS once…" / "RichOS can send photos, PDFs…" / "RichOS could not keep this on your
  iPhone…" → all **RichConnect**.
- `ShareExtension/Sources/ShareSheetView.swift:138` share-compose footer: "…The reply comes in
  RichOS." → **"…The reply comes in RichConnect."** — verbatim match, round-12.1's
  `attach/screens.js` share-compose wording.
- `ShareExtension/Sources/ShareSheetView.swift:180` `unpaired` heading: "Pair RichOS with your
  Mac first" → **"Pair RichConnect with your Mac first"** — verbatim match.
- `ShareExtension/Sources/ShareSheetView.swift:188` `unpaired` body: "…Open RichOS on this
  iPhone and scan the code on your Mac." → **"…Open RichConnect on this iPhone…"**.
- `ShareExtension/Sources/ShareSheetView.swift:277-281` `ShareConfirmation.line` (all four
  outcome branches — sent, saved-offline, saved-other, refused): "Rich will reply in RichOS." /
  "…next time RichOS is open…" / "…next time you open RichOS." / "…kept in RichOS." → all
  **RichConnect**.

16 call sites across 7 files, all self-naming (the phone app naming itself), none of them the
Mac product or "RichOS Connect."

## Verified unchanged, and why (checked by re-grepping the whole target after the edits)

**Mac-referencing (the brief's own examples) — left as RichOS:**
- `App/Features/Attachments/AttachmentViews.swift:545` `MacUnsupportedCard`: "Update RichOS on
  your Mac, then send them from here."
- `App/Features/Conversation/ConversationChrome.swift:84` `.macUnreachable`: "…Keep it awake
  with RichOS running."
- `App/Features/Conversation/ConversationChrome.swift:85` `.incompatible`: "This Mac needs a
  newer RichOS app."
- `App/Features/Conversation/ConversationChrome.swift:88` `.attachmentsUnsupported`: "This Mac
  needs a newer RichOS for photos and files."

**"RichOS Connect" (the CEO's own open question per round-12.1 NOTES.md: "left as it was,
because it is ambiguous") — every occurrence, untouched:**
- `App/Features/Pairing/Takeovers.swift:58` "…and choose RichOS Connect."
- `App/Features/Conversation/ConversationChrome.swift:83` "RichOS Connect is temporarily
  unavailable."

**Identifiers, data locations and comments (renaming breaks builds/installs/tests or changes
nothing a person sees) — sampled, not exhaustive, via `git grep -n RichOS` over the whole
target post-edit:** the `RichOSCore`/`RichOSFixtures`/`RichOSCLI`/`RichOSNative`/`RichOSShare`/
`RichOSNotificationService`/`RichOSPlatformTests` module, target and scheme names in
`project.yml`/`Release/platform.yml`/`Core/Package.swift`; the `RichOS-Device` HTTP auth scheme
and `X-RichOS-Challenge` header (`Protocol/Signing.swift`, `Protocol/APIClient.swift`,
`Protocol/PairingAPI.swift`) and every test asserting them; `RichOSAppGroup`/
`RichOSKeychainGroup` entitlement/Info.plist keys; storage paths
(`Application Support/RichOS/…`, `RichOS/Attachments`, `RichOS/Recordings`,
`Library/Application Support/RichOS/SharedInbox`); the `dev.richos.native.qr-scanner` dispatch
queue label; doc comments throughout `TranscriptView.swift`, `TranscriptViewportGeometry.swift`,
`NotificationTarget.swift`, `Scanner.swift`, `ShareInbox.swift`, `Palette.swift`, `Mark.swift`
describing the project's own adoption-ledger decisions ("RichOS's addition", "RichOS changes",
"why it fits RichOS"); `NotificationService/Tests/main.swift:50`'s `content.title = "RichOS"`,
an unasserted test-fixture placeholder value (the test only checks `.body`, never `.title`);
`ShareViewController.swift:10`'s doc comment describing pre-`transport` behavior (the code it
describes was renamed; the comment is prose about the project, not app copy — left per the
brief's own "code comments" exclusion, though it is now slightly stale prose worth a follow-up
note, not a rename).

No ambiguous ("phone app or Mac?") strings were found this pass — every remaining "RichOS" in
the target is either clearly Mac-referencing, clearly "RichOS Connect," or clearly an
identifier/comment.

## Contrast

Every changed string reuses an existing style/color pairing already in the app (`CardText`'s
title style over the card surface, `TakeoverView`'s `displayBlocking` over `palette.ink`,
`DialogView`'s title style, `UpdateBannerView`'s `body.weight(600)` over `palette.ink`, the
Share extension's `Typography.read`/title styles) — no new pairing was introduced by a rename.
Measured directly from the rendered proof-run frames below: dark `pm-dark-pair-camera-denied`
title "The camera is off for RichConnect" and dark `pm-dark-upd-blocking` headline both render
full `ink` on the surface/ground pairings this codebase's existing `ContrastTest`-equivalent
(`native-ios-app.test.sh`'s Palette contrast checks) already covers and gates at 4.5:1; both
passed as part of that suite (see Proof, below).

## Layout

`RichConnect` is longer than `RichOS` (1-6 characters depending on the sentence). The rendered
frames below show no clipping at either device (iPhone SE 3rd gen / iPhone 16 Pro Max) or at the
`ax5` (accessibility, largest Dynamic Type) variant captured for `upd-dialog` and `upd-blocking`
— `Overlays.swift:48`'s dialog title wraps to two lines where needed ("The camera is off for /
RichConnect") using the existing `fixedSize(horizontal: false, vertical: true)` wrapping already
in place; nothing was truncated or re-sized to make the new word fit.

## Proof

`cd richos/app && python3 scripts/proof-run.py --working`, run in the foreground from this
worktree, waited on to completion (1086 s wall): **all 4 checks PASSED** —
`native-ios-app` 240 s, `proof-for` 352 s, `native-ios-share` 1071 s, `native-ios-ui` 1077 s.
Logs: `/Volumes/E1TB/state/richos/proof-runs/0eaabc2de49c/20260923T191819Z-5_v5i7k3`. No test
asserted any of the 16 old strings (checked by grep of `UITests/`, `ShareExtension/Tests/`,
`NotificationService/Tests/`, `Core/Tests/` before and after), so nothing needed updating beyond
the source.

## Screenshots (this directory)

`native-ios-ui.test.sh`'s own simulator run inside the proof above (part of `native-ios-ui`,
PASSED) photographs every round-12 fixture screen on both iPhone SE (3rd gen) and iPhone 16 Pro
Max, dark and light, plus an accessibility (`ax5`, largest Dynamic Type) pass for a subset. Full
export: `/Volumes/E1TB/caches/richos-native-ios-ui/98f8324161/screenshots/20260923-201855/`.
Copied here, the frames for every fixture-reachable screen whose text changed this pass:

- `{pm,se}-{dark,light}-pair-camera-denied.png` — screen 3, `Overlays.swift` dialog. Verified by
  eye: "The camera is off for RichConnect", unclipped, both themes.
- `{pm,se}-{dark,light}-rec-mic-denied.png` — screen 45, `ConversationChrome.swift` card.
- `{pm,se}-{dark,light}-upd-banner.png` — screen 61: "RichConnect 1.1 is ready", both themes.
  Verified by eye: full contrast, no overlap with the conversation behind it.
- `{pm,se}-{dark,light}-upd-dialog.png` and `{pm,se}-ax5-upd-dialog.png` — screen 62: "A new
  RichConnect is ready", including the largest-Dynamic-Type variant.
- `{pm,se}-{dark,light}-upd-blocking.png` and `{pm,se}-ax5-upd-blocking.png` — screen 63:
  "This version of RichConnect can no longer send", verified by eye: two-line wrap, no
  clipping, full contrast in both themes, App Store button and Support link intact.

**Not screenshotted by the existing fixture harness — gap noted, not filled here:** the two
attach-flow cards (`attach-camera-denied`, `attach-photos-denied` — no `RichOSFixtures` entry
exists for them, unlike Android's `AttachCatalog.kt` `ScreenSpec`s for the same states) and the
Share extension's screens (`share-compose`, `share-unpaired`, `share-sent` and friends — the
Share extension is a separate app target with no equivalent to `ScreenshotTests.swift`'s
`-rios-fixture` launch mechanism). Both are pre-existing test-infrastructure gaps, not
introduced by this rename, and adding fixture/screenshot coverage for them is out of this
brief's scope (a rename, not new test infrastructure). Correctness for those files is instead
evidenced by: the source diff above (mechanical string substitution only, no logic changed),
`native-ios-share.test.sh` PASSING (which builds, unit-tests and UI-tests the Share extension
target that `ShareModel.swift`/`ShareSheetView.swift` live in), and the same styling/contrast
reasoning as the screenshotted cards (identical `CardText`/`Typography` usage). Flagging this
gap for a decision rather than silently building new fixture infrastructure to fill it.

## Simulators

No simulator was booted, created or removed directly by this session outside the proof-run's
own lifecycle: `proof-run.py` → `native-ios-ui.test.sh`/`native-ios-share.test.sh` create their
own headless simulators (never `Simulator.app`), admitted by the shared simulator budget, and
each script's own trap shuts down and deletes every simulator it created by UDID regardless of
how the run ends — confirmed after the run: `xcrun simctl list devices booted` shows none
booted; the `RichOS mobile loop *` devices listed by `simctl list devices` are pre-existing,
already-`Shutdown` residue from earlier unrelated runs (not created or touched by this session).
Nothing was opened on this Mac's own display, and nothing touched its sleep, lock or input
state.
