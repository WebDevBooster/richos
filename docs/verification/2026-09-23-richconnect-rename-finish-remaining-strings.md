# RichConnect rename, finished — every remaining self-naming string — native Android

CEO directive, 2026-09-23, verbatim: *"From now on, the mobile app in general will be called
RichConnect."* (§79.) This pass covers what the first pass (`cc6c873d`, home-screen label +
screens 9/10/12) left: every other place the phone app names ITSELF "RichOS" in text a person
reads. Verbatim wording taken from round-12.1 (`richos-hq/design/mockups/rounds/round-12.1/`
`shared/screens.js`, `attach/attach.js`, `NOTES.md`) wherever it exists there.

Scope: `richos/mobile/native-android/` only.

## Renamed (old → new), file:line

- `ui/overlays/SystemDrawings.kt:104` — mic-permission drawing (the moment before Android's own
  system dialog): "Allow RichOS to record audio?" → **"Allow RichConnect to record audio?"**
  This drawing represents Android's real permission dialog, whose title now genuinely reads
  "RichConnect" post-rename (the dialog's app name comes from the manifest's
  `android:label`, already RichConnect since the first pass) — so this was not just cosmetic,
  it had gone factually stale.
- `ui/overlays/Sheets.kt:322` `CameraOffDialog` (pair-camera-denied, screen 3): "The camera is
  off for RichOS" → **"The camera is off for RichConnect"** — verbatim match,
  `shared/screens.js:86`.
- `ui/overlays/Sheets.kt:332` `UpdateDialog` (upd-dialog, screen 62): "A new RichOS is ready" →
  **"A new RichConnect is ready"** — verbatim match, `shared/screens.js:164`.
- `ui/overlays/Sheets.kt:369` `UpdateBanner` (upd-banner, screen 61): "RichOS $version is ready"
  → **"RichConnect $version is ready"** — matches the pattern in `shared/screens.js:163`
  ("RichConnect 1.1 is ready").
- `ui/overlays/Takeovers.kt:312` `UpdateRequired` (upd-blocking, screen 63): "This version of
  RichOS can no longer send" → **"This version of RichConnect can no longer send"** — verbatim
  match, `shared/screens.js:165`.
- `ui/composer/Cards.kt:98` (`ComposerCard.MicrophoneOff`, rec-mic-denied, screen 45): "The
  microphone is off for RichOS" → **"The microphone is off for RichConnect"** — verbatim match,
  `shared/screens.js:139`.
- `ui/attach/AttachComposer.kt:244` `DeniedCard(CAMERA)` (att-denied-camera): "The camera is off
  for RichOS" → **"The camera is off for RichConnect"** (same pairing-flow wording, applied to
  the in-conversation attach flow's own camera-denied card).
- `ui/attach/AttachComposer.kt:249` `DeniedCard(PHOTOS)` (att-denied-photos): "RichOS can't see
  your photos" → **"RichConnect can't see your photos"** (curly apostrophe preserved, matching
  every other contraction in this source tree).
- `ui/attach/AttachOverlays.kt:288` `ShareCompose` (share-compose / share-compose-many /
  share-compose-file): "…The reply comes in RichOS." → **"…The reply comes in RichConnect."** —
  verbatim match, `attach/attach.js:610`.
- `ui/attach/AttachOverlays.kt:372` `ShareDone` (share-sent): "Rich will reply in RichOS." →
  **"Rich will reply in RichConnect."** — verbatim match, `attach/attach.js:612`.
- `ui/attach/AttachOverlays.kt:386` `ShareUnpaired` (share-unpaired): "Pair RichOS with your Mac
  first" → **"Pair RichConnect with your Mac first"** — verbatim match, `attach/attach.js:634`.
- `ui/attach/AttachOverlays.kt:393` `ShareUnpaired` button: "Open RichOS to pair" →
  **"Open RichConnect to pair"** — verbatim match, `attach/attach.js:635`.
- `platform/ShareToRich.kt:30` `ShareOutcome.REFUSED` (the Toast a person sees when a share
  fails, per the enum's own doc comment "in the words the person sees"): "Not sent to Rich. Open
  RichOS to see why." → **"Not sent to Rich. Open RichConnect to see why."** Not in round-12.1
  (no failed-share screen there); this is the exact site the brief named
  (`platform/ShareToRich.kt:30`), self-referencing the same way as every other renamed string
  ("open the app" = open this phone app).

13 strings across 7 files, all self-naming (the phone app naming itself), none of them the Mac
product or "RichOS Connect."

## Left unchanged, and why

**Mac-referencing (explicit "do not change" class — the brief's own examples, plus the same
pattern found elsewhere):**
- `ui/overlays/Takeovers.kt:131` "Keep the Mac awake with RichOS running, then scan again."
- `ui/conversation/Header.kt:70` "…Keep it awake with RichOS running."
- `ui/conversation/Header.kt:71` "This Mac needs a newer RichOS app."
- `ui/conversation/Header.kt:74` "This Mac needs a newer RichOS for photos and files."
- `ui/attach/AttachComposer.kt:259` `MacOffCard` "…Update RichOS on your Mac, then send them
  from here."
- `core/RichCore.kt:333` "This Mac cannot take photos or files yet. Update RichOS on your Mac."
- `core/src/test/.../MacTransportTest.kt:194` asserts the RichCore.kt:333 string above —
  unchanged because the string it asserts is unchanged.

**"RichOS Connect" (the CEO's own open question, per round-12.1's NOTES.md: "left as it was,
because it is ambiguous") — every occurrence, untouched:**
`ui/overlays/Scanner.kt:228`, `ui/overlays/Takeovers.kt:155`, `ui/conversation/Header.kt:69`,
`core/Connection.kt:64` (comment), `core/src/test/.../ConnectionTest.kt:33` (test name),
`core/protocol/PairLink.kt:10` (comment).

**Identifiers and protocol wire values (renaming breaks the wire contract or the resource, and
changes nothing a person reads):** `Theme.RichOS` (`themes.xml`, `AndroidManifest.xml`); the
`RichOS-Device` HTTP Authorization scheme and `X-RichOS-Challenge` header
(`core/protocol/Signing.kt`, `core/dev/DevMac.kt`, and the tests asserting them —
`ProtocolTest.kt`, `WireTest.kt`, `MacTransportTest.kt:34`); `settings.gradle.kts`
(`rootProject.name`).

**Code comments naming the project/architecture (never user copy):** doc comments in
`Follow.kt`, `Press.kt`, `Components.kt`, `RichColors.kt`, `RichIcons.kt`, `RichTheme.kt`, and
comments in `InteractionTest.kt` / `FollowTest.kt` referring to "RichOS's rule" / "RichOS's
additions" as the project's own name for its design decisions.

**Internal QA/dev-catalog descriptions, never shown to a real user — the screen catalog's own
comment says so ("Not app UI"):**
- `ui/catalog/AttachCatalog.kt:151` — the `system("Android's share sheet with RichOS
  (ACTION_SEND target); drawn for review")` note attached to the `share-sheet` `ScreenSpec`: an
  internal description string for the screenshot-catalog tooling, never rendered as on-screen
  text or read by TalkBack in the shipped app.
- `ui/attach/AttachOverlays.kt:430` `SystemPickerDrawing`'s `"Android share sheet with RichOS
  (drawing)"` — a `contentDescription`/testTag label on a Robolectric-only drawing of Android's
  OS share sheet (line 415's comment: "the system share sheet with RichOS in it. Not app UI.").
  The drawing's actual VISIBLE text stamp inside it already reads "RichConnect" (line 488,
  renamed in the first pass); this is only the accessibility label describing the drawing to the
  test harness. Listed here per the brief's own instruction for anything not unambiguously
  in scope, rather than silently widened.
- `core/dev/DevRuntime.kt:398` — a dev-bridge scripted scenario's canned server message,
  `"Update to keep using RichOS."`, fed into `UpdateNotice` to test that the app renders
  whatever content string the Mac sends. A test fixture payload (the brief's own exclusion),
  not app-authored copy — the real app never originates this string.
- `cli/src/main/kotlin/dev/richos/android/cli/Main.kt:22` — `USAGE = "Headless RichOS Android
  core…"`, the developer CLI's own `--help` text (`randroid headless`), never seen inside the
  shipped RichConnect app.

No ambiguous ("phone app or Mac?") strings were found this pass — every remaining "RichOS" is
either clearly Mac-referencing, clearly "RichOS Connect," clearly an identifier, or clearly
internal tooling.

## Contrast

Every changed string reuses an existing style/color pairing already covered by this codebase's
`ContrastTest` (`t.answer`/`t.bodyStrong`/`t.readStrong`/`t.sheetTitle`/`t.read` over
`ink`/`inkSoft` on `ground`/`surface`) — no new pairing was introduced. `ContrastTest` (part of
the `native-android-app` suite, run below) fails the build below 4.5:1 in either theme; it
passed.

## Layout

No new lines were added (unlike the previous pass's screen-12 paragraph); every change is a
word substitution inside an existing string with the same style. `RichConnect` is one character
longer than `RichOS` in some strings and up to 5 longer in others (e.g. "A new RichOS is ready"
→ "A new RichConnect is ready"); the small-phone, largest-text (`font200`) renders were checked
for every touched screen and none clipped — the dialog title wraps to two lines where needed
("A new RichCon-\nnect is ready" at `light-small` even at 1x, hyphenated by the existing
`Hyphens.Auto`/`lineBreak` styling already in place for these titles) with no clipping at 200%.

## Proof

`cd richos/app && python3 scripts/proof-run.py --working` — proof-for's selection for the 7
changed paths: `native-android-app.test.sh`, `native-android-ui.test.sh`, `proof-for.test.sh`.
Run in the foreground, all 3 passed in 288 s wall (native-android-app 71 s, native-android-ui
62 s, proof-for 162 s). No test asserted any of the 13 old strings (checked by grep before
editing), so nothing needed updating beyond the source.

## Screenshots (this directory, `2026-09-23-richconnect-rename-finish-remaining-strings/`)

`native-android-ui.test.sh pair-camera-denied voice-permission rec-mic-denied upd-banner
upd-dialog upd-blocking att-denied-camera att-denied-photos share-unpaired share-sent
share-compose share-compose-many share-compose-file` (Robolectric, headless, no emulator) — dark
and light, small (360dp) and large (412dp), plus the small-phone 200%-font variant for every
screen whose text changed. All 78 frames rendered and passed `ScreenChecks` (no clipped text, 48
dp touch targets, composer on screen) on the first run — no layout fix was needed this time.

- `pair-camera-denied--{dark,light}-{small,large}.png` (+ `-small-font200`) — screen 3
- `voice-permission--{dark,light}-{small,large}.png` (+ `-small-font200`) — screen 29
- `rec-mic-denied--{dark,light}-{small,large}.png` (+ `-small-font200`) — screen 45
- `upd-banner--{dark,light}-{small,large}.png` (+ `-small-font200`) — screen 61
- `upd-dialog--{dark,light}-{small,large}.png` (+ `-small-font200`) — screen 62
- `upd-blocking--{dark,light}-{small,large}.png` (+ `-small-font200`) — screen 63
- `att-denied-camera--{dark,light}-{small,large}.png` (+ `-small-font200`)
- `att-denied-photos--{dark,light}-{small,large}.png` (+ `-small-font200`)
- `share-unpaired--{dark,light}-{small,large}.png` (+ `-small-font200`)
- `share-sent--{dark,light}-{small,large}.png` (+ `-small-font200`)
- `share-compose--{dark,light}-{small,large}.png`, `share-compose-many--…`,
  `share-compose-file--…` (+ `-small-font200` each)
- `andy-pre-handoff-live.png` — the built APK installed and launched live on a headless
  emulator (`dev.richos.native.android/dev.richos.android.app.MainActivity`), `emu verify`
  confirms "Message Rich" on screen, `logcat -b crash` empty. Shows the empty-conversation
  screen (already paired in this dev checkout's fixture state) — none of the 13 renamed
  screens are reachable without a specific permission-denied/update/share state, which is why
  the Robolectric renders above are the proof for those states; this shot is the general
  install-and-launch sanity check the pre-handoff rule requires.

## Emulator

`bin/randroid emu prepare` created and booted one headless AVD (`randroid-d94716a5d3`,
`-no-window`; none was running beforehand — `adb devices` was empty), built, installed and
launched the app (`bootMs` 47195, `buildMs` 43932, `installLaunchMs` 4819). After the live
sanity check: `bin/randroid emu stop` (by its own recorded serial/PID) then `emu delete`
(removed the AVD). Confirmed gone: `adb devices` empty, no `qemu`/`emulator` process in `ps -ef`.
Nothing else touched this Mac's display, sleep, lock or input.
