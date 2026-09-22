# What the screens need from the core (I2 → I1)

**From:** stream I2 (screens), `isaac-opus-i2`. **To:** stream I1 (core), through Rich.
**Why this file exists:** the screens render only from `AppState` and send only `Action`s (brief, item 2),
and the core at `48604d6a` can express 5 of round 12's 67 screens (`AppState.screen` has five cases:
`pair-intro`, `pair-words`, `conv-empty`, `conv-populated`, `conn-revoked`). Everything below is the state
and the actions the other screens read and send. Names are proposals; the shape is what matters. Each
row names the round-12 screens it unlocks, so the order of work can follow the screens that matter most.

Until a row exists in the core, its screens are still built and screenshotted through a Debug-only
catalog in `App/Features/Catalog/` (a named `ScreenModel` per round-12 id, `-rios-screen <id>`), and the
handoff says which screens are reached that way. When a row lands, that screen's catalog entry is
replaced by the core fixture of the same name and the Debug catalog entry is deleted.

## 1. State (all `Codable`, `Equatable`, `Sendable`; transient fields excluded from `.persist`)

| Field | Type (proposal) | Screens |
|---|---|---|
| `sheet` | `Sheet?` — `.settings`, `.forget`, `.forgetBlocked`, `.whereMessagesGo`, `.pairingLink` | `settings`, `settings-forget`, `settings-forget-blocked`, `notif-settings` |
| `scanner` | `ScannerState?` — `.looking`, `.found` | `pair-scanner`, `pair-scanner-found` |
| `pairingStep` | `.connecting` (new `Pairing` case is fine) | `pair-progress` |
| `pairingProblem` | `PairingProblem?` — `.refused`, `.blockedByUnsentWork(count)`, `.sessionNeedsNewerApp`, `.cameraDenied` | `pair-refused`, `pair-blocked`, `pair-stale`, `pair-camera-denied` |
| `consentGiven` | `Bool` (persisted; `false` for a new install) | `pair-consent` |
| `reply` | `ReplyActivity?` — `.thinking`, `.streaming(text)` | `conv-replying`, `conv-streaming` |
| `Message.audio` | `ReplyAudio?` — `.ready`, `.preparing`, `.playing(progress)` | `conv-playing-reply`, `conv-preparing-reply` |
| `Message.levels` | `[Double]` (voice only; 0…1, any count, the view resamples to 42 bars) | every voice bubble |
| `history` | `{ loadingOlder: Bool, reachedBeginning: Bool, cached: Bool }` | `conv-older-loading`, `conv-beginning`, `conn-cached`, `launch-cached` |
| `following` | `Bool`, default `true` (not persisted) | `conv-scrolled`, `voice-locked-scrolled` |
| `focusedMessageID` | `String?` (from a notification tap; cleared after the glow) | `conv-focused` |
| `composerFocused` | `Bool` (not persisted) | `comp-keyboard` |
| `voice` | `VoiceSession?` — see §3 | all of `voice-*` groups 4 and 5 |
| `keptRecordings` | `[KeptRecording]` — `{ id, durationMs, levels, reason: .interrupted/.ceiling/.unsent }` | `rec-card`, `voice-interrupted`, `voice-ceiling-reached`, `rec-unsupported` |
| `voiceAvailability` | `.available`, `.pausedByPolicy`, `.unsupportedByMac` | `upd-feature-off`, `rec-unsupported` |
| `microphone` / `camera` | `.unknown`, `.granted`, `.denied` — **mirrors the OS, not stored** (PRD §3 "store no parallel permission state") | `voice-permission`, `rec-mic-denied`, `pair-camera-denied` |
| `notifications` | `{ status: .notAsked/.on/.off/.turningOn/.denied/.unsupported/.appleUnavailable/.serviceUnavailable, offerDismissed: Bool, previews: Bool (default true) }` | `notif-offer`, `notif-settings`, `settings` |
| `update` | `UpdateNotice?` — `{ prominence: .banner/.dialog/.required, version: String, message: String }` | `upd-banner`, `upd-dialog`, `upd-blocking` |
| `macName` | `String?` | `settings` ("Paired with Alex’s Mac") |
| `toast` | `Toast?` — `.tooShort`, `.ceilingWarning` (time-bounded; the view dismisses by action) | `voice-too-short`, `voice-ceiling-warning` |

`comp-too-long` and `comp-disabled` need nothing new: the view derives them from `draft.count` against a core
constant (`Limits.messageCharacters = 4000`, please expose it) and from `connectionNotice == .incompatible`.

## 2. Actions

`openScanner`, `closeScanner`, `scanned(text)`, `openSheet(Sheet)`, `closeSheet`, `submitPairingLink(text)`,
`confirmWords`, `rejectWords`, `acceptConsent`, `forgetPairing`, `sendDraft`, `retryNow`,
`discardMessage(id)`, `loadOlder`, `setFollowing(Bool)`, `setComposerFocus(Bool)`, `playVoice(id)`,
`stopPlayback`, `hearReply(id)`, `sendKept(id)`, `discardKept(id)`, `dismissNotificationOffer`,
`turnOnNotifications`, `setPreviews(Bool)`, `dismissUpdate`, `clearFocus`, `dismissToast`, and the voice
gesture in §3. Effects the views need the core to own: `openAppStore`, `openSupport`, `openSystemSettings`.

## 3. The voice gesture (build plan §3.2: one state machine in the core, fed dx/dy/time)

```
VoiceSession { phase: .pressed | .held | .locked | .ending(.sent | .canceled | .tooShort | .ceiling),
               startedAtMs: Int64, frozenElapsedMs: Int64?, dx: Double, dy: Double,
               cancelProgress: Double, lockProgress: Double, width: Double }
Actions: voicePress(width:), voiceBegin, voiceMove(dx:dy:), voiceRelease, voiceLockedCancel,
         voiceLockedSend, voiceInterrupted, voiceSettled   // `voiceSettled` after the end animation
```

Thresholds exactly as round-12 `NOTES.md` "Motion": press delay 200 ms; lock at 60 pt up, refused once
`cancelProgress > 0.3`; cancel distance `min(0.35 × width, 140)`; mid-slide cancel at 1.0; a release after
0.55 cancels; a release under 500 ms is too short; an interruption locks under 0.3 and cancels above,
never sends; warning at 29:00, stop at 30:00 into `keptRecordings`. `voiceMove` arrives at touch rate (60–120 Hz):
please keep it free of `.persist` (today `Reducer.reduce` persists on every change, which would write
`state.json` per touch event). The halo's breathing level is display-only and stays in the view (a
deterministic pretend voice in Debug fixtures, the recorder's meter live), so it never enters the state.

## 4. Fixtures (one per round-12 id, `Fixture.all`)

Every in-app id in `round-12/shared/screens.js` except the four that are not app screens on iPhone:
`pair-pwa-storage` and `notif-pwa-install` (web app only) and `notif-lock-preview`, `notif-lock-generic`
(Apple's lock screen; the card's content is the notification service extension, stream I3). That is 63.
Conversations: round 12's `CONVO` (`Conversation.round12` today, seven messages, same times) and
`OLDER.concat(CONVO)` for the screens whose `setup` calls `full(a)` (`conv-populated`, `conv-older-loading`,
`conv-scrolled`, `conn-cached`, `launch-cached`, `voice-locked-scrolled`); `OLDER` is three messages from
"yesterday". `Conversation.round12`'s voice message has no waveform yet (round 12 draws `waveFor(42, 3)`).

## 5. Project (project.yml)

A unit-test target is needed for the adopted T3 transcript tests (ledger §2.8 M2 says ADOPT AS-IS *with
their tests*; they drive a `UICollectionView` in a `UIWindow` and `@testable import` the app, so they
cannot live in the UI-test bundle):

```yaml
  RichOSNativeTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: UnitTests
        optional: true
    dependencies:
      - target: RichOSNative
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.richos.native.ios.tests
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/RichOSNative.app/RichOSNative"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

and `- RichOSNativeTests` in the scheme's `test.targets`. `UnitTests/**` would then be I2's alongside `UITests/**`.

## 6. The composition seam

`RichOSNativeApp.swift`: replace `PlaceholderRootView(store: store)` with
`RootView(state: store.state, send: store.send)`. `RootView` takes no `AppStore`, so I2 never depends on I1's
store type.
