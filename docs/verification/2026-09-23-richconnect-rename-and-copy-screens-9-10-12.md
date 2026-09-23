# RichConnect rename + screens 9/10/12 copy — native Android

CEO directive, 2026-09-23 (verbatim in the brief): app name is **RichConnect**; store listing
"RichConnect: RichOS Mobile Remote" collapses (30-char cap) to store name "RichConnect" with
Apple subtitle / Google short description "RichOS Mobile Remote". Copy changes on mobile
screens 9 (`pair-stale`), 10 (`pair-consent`) and 12 (`conv-empty`), quoted verbatim from
`richos-hq/design/mockups/rounds/round-12/app.html`.

Scope: `richos/mobile/native-android/` only. The PWA (`avelor/src`) is out of scope by CEO
ruling (preserved as-is). Not this repo — the mockup source itself is round-12, frozen; not
edited here.

## Changes

- `app/src/main/AndroidManifest.xml`: `android:label="RichOS"` → `"RichConnect"` (home-screen
  label). Verified via `aapt2 dump badging` on the built debug APK: `application-label:'RichConnect'`
  in every locale. The share target's `android:label="Rich"` ("Share to Rich") is untouched —
  it names the share action, not the app.
- `ui/overlays/Takeovers.kt` `NeedsNewerApp` (screen 9, `pairing-stale` testTag / catalog id
  `pair-stale`): eyebrow "A newer RichOS is needed" → "Newer app version needed" (renders
  uppercase via the eyebrow style); lede's second sentence "Update RichOS and everything picks
  up where it left off." → "Update this RichConnect app and everything picks up where it left
  off." (first sentence "Your data has been kept." unchanged, per the brief).
- `ui/overlays/Takeovers.kt` `Consent` (screen 10, `pairing-consent` / `pair-consent`): spark row
  bold "Rich on your Mac sends it to its AI provider to write the reply." → "Rich (powered by
  your AI provider) writes the reply there."; its detail "The provider set up on your Mac. You
  can change it there." → "So, all the AI work happens on your Mac." Cloud row bold "Our
  connection service carries it to your Mac and keeps nothing." → "Our connection service just
  moves the messages between your Mac and your phone." Its detail line ("Encrypted on the way,
  stored nowhere.") is not in the CEO's list and is unchanged.
- `ui/conversation/Thread.kt` `EmptyConversation` (screen 12, `conv-empty`): added, verbatim,
  under the existing "Your conversation will appear here.": "Press and hold the gold microphone
  to record a voice message. Release to send. Or slide left to cancel. Or slide up to lock.
  Because then you don't need to hold and can scroll." (apostrophe rendered as the codebase's own
  curly `’`, matching every other contraction in this source tree — e.g. `Cards.kt:90`,
  `AttachComposer.kt:224` — not a wording change).
- `ui/attach/AttachOverlays.kt:490`: the Android share-sheet drawing's app-icon stamp, `"RichOS"`
  → `"RichConnect"` — this draws the OS share sheet entry for THIS app, i.e. its launcher label,
  which is now RichConnect. Explicitly named in the brief.

## Layout fix the new paragraph required (found, not in the brief)

Adding the fourth line to `EmptyConversation` clipped on the smallest phone at the largest text
setting: `ScreensTest` failed `conv-empty--*-small-font200` in both themes with
`clipped text "Press and hold the gold microphone to re" (text 624×684 px in 624×296)` — the
brief's own "unverified" flagged this as the risk, and it was real.

Fix: `EmptyConversation`'s Column now scrolls (`verticalScroll(rememberScrollState())`), and its
placement in `RichApp.kt` `Conversation()` now reserves the composer zone's own measured height
at the bottom (`.padding(bottom = zoneDp + 20.dp)`, the same reservation `Thread()` already uses
for the populated conversation) so the scrollable region ends above the composer rather than
sliding text behind it. Re-ran `native-android-ui.test.sh conv-empty pair-stale pair-consent`:
PASS. Confirmed by eye at `light-small-font200` (screenshot below): the last line ends cleanly at
the composer's top edge, no overlap, scrollable to read the rest — the same behavior the
populated conversation already has when scrolled. The words were not touched to make this fit.

## Contrast (computed, not eyeballed)

The new paragraph reuses the exact style/color pairing already covered by
`ContrastPairings.of()` — "ink-soft on ground" (`t.read.copy(color = c.inkSoft)` over `c.ground`),
the same pairing the existing "Your conversation will appear here." line already uses, and
`ContrastTest` fails the build if it ever drops below 4.5:1 (Floor.TEXT) in either theme.
Computed directly from `RichColors.Dark`/`RichColors.Light` (WCAG relative-luminance formula,
inkSoft = ink at 72% alpha over ground):

- Dark (`0xFFDFE4EE` @ 72% over `0xFF0C1322`): **7.91:1**
- Light (`0xFF0C1322` @ 72% over `0xFFEAE6DD`): **6.69:1**

Both clear the 4.5:1 floor by a wide margin. Text size is `TypeSize.Read` = 16 sp, the codebase's
declared readable floor.

## Proof

`cd richos/app && python3 scripts/proof-run.py --working` (the selection `proof-for.sh --working`
names for the 4 changed paths: `native-android-app.test.sh`, `native-android-ui.test.sh`,
`proof-for.test.sh`; `AndroidManifest.xml` itself is prose/config, not proven by a suite).
First run caught the clipping regression above (`native-android-ui` FAILED,
`native-android-app` PASSED, `proof-for` canceled after the first failure per the runner's
design). After the layout fix, a second full run: all 3 PASSED in 157 s
(`proof-for` 152s, `native-android-ui` 54s, `native-android-app` 44s).

## Screenshots (this directory)

`native-android-ui.test.sh pair-stale pair-consent conv-empty` (Robolectric, headless, no
emulator — the app's own screenshot mechanism, dark/light × small (360dp)/large (412dp), plus the
small-phone 200%-font variant that caught the clipping):

- `pair-stale--{dark,light}-{small,large}.png` — screen 9
- `pair-consent--{dark,light}-{small,large}.png` — screen 10
- `conv-empty--{dark,light}-{small,large}.png` and `conv-empty--{dark,light}-small-font200.png`
  — screen 12, including the font-200 variant that exercises the fix
- `andy-pre-handoff-live.png` — the app installed and launched on a real (headless) emulator,
  `dev.richos.native.android/dev.richos.android.app.MainActivity`, `LaunchState: COLD`, no
  `logcat -b crash` entries. Shows the pairing-intro screen (screen 1, unpaired — there is no
  Mac to pair with in this environment); screens 9/10/12 are conditional states not reachable
  without a live pairing session or the dev bridge, which is why the Robolectric renders above
  are the proof for those three screens specifically. This screenshot instead proves the built
  RichConnect-labeled APK installs and launches without crashing.

## Emulator

Started one headless emulator (`codex-android-34`, `-no-window`, none was running beforehand) to
install and launch the built APK for the live sanity check above. Shut down after
(`adb emu kill`), confirmed gone via `ps -p <pid>` and `adb devices` (empty). Nothing else was
running or touched on this Mac's display, sleep, lock or input.

## Out of scope, found, not changed — for the CEO/lead to decide

Several other "RichOS" strings in `ui/attach/AttachOverlays.kt` are the same class of self-naming
as the one the brief named (line 490) but were not themselves named:

- line 288: `"...The reply comes in RichOS."` (share flow: where the reply appears)
- line 372: `"Rich will reply in RichOS."` (same flow, the "Sent" confirmation)
- line 386: `"Pair RichOS with your Mac first"` (share flow, unpaired state heading)
- line 393: `"Open RichOS to pair"` (button in the same state)

And in other files, self-referencing (not Mac-referencing) uses of "RichOS" that read the same
way: `SystemDrawings.kt:104` `"Allow RichOS to record audio?"` (mic permission rationale);
`ui/composer/Cards.kt:98` `"The microphone is off for RichOS"`; `ui/attach/AttachComposer.kt:244`
`"The camera is off for RichOS"` and `:249` `"RichOS can't see your photos"`;
`ui/overlays/Sheets.kt:322` `"The camera is off for RichOS"` and `:332`/`:369` (`UpdateDialog`,
"A new RichOS is ready" / "RichOS $version is ready" — this one may in fact mean the phone app's
own update, same as screen 63 `UpdateRequired`'s "This version of RichOS can no longer send",
also not touched); `platform/ShareToRich.kt:30` `"Not sent to Rich. Open RichOS to see why."`.

None of these were in the brief's explicit scope (`Takeovers.kt` 241-262, `EmptyConversation`,
the manifest label, and `AttachOverlays.kt:490`), and the brief's own instruction for an
ambiguous mention is to leave it and list it — these are not ambiguous (they clearly self-refer
to the phone app, not the Mac) but they are also not scoped, so left untouched rather than
silently widening the rename. Listed here rather than guessed at.

"RichOS Connect" (the pairing feature's own name, e.g. `Takeovers.kt:155`, `Header.kt:69`,
`Scanner.kt:228`) is a distinct, already-established product name for the Mac-side pairing
feature, not this app's own name, and was left unchanged.
