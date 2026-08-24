# open-wispr Dictation HUD — reproducible patch

A minimal, calm **recording-state HUD** for our on-device dictation
(**open-wispr**, `human37/open-wispr` MIT, built from audited source at commit
`7ab4e62e` = v0.43.0). It makes silent dictation failures visible and gives the
"it hears me" signal our menu-bar icon lacks.

Built to **the design lead's endorsed spec**
(the dictation-HUD assessment, 2026-08-24). This directory holds
**only our patch + reproducible build/apply/rollback instructions** — the
open-wispr tree itself is NOT vendored here (mirrors how the earlier voice-pilot patches are
handled). CEO greenlit 2026-08-24 ("go ahead as recommended").

- **Base commit (audited):** `7ab4e62e8f182f3ecc2116e1094a1eb4416a248f`
- **Patch:** [`dictation-hud.patch`](./dictation-hud.patch)
- **Build:** [`build.sh`](./build.sh)
- **Stack:** native **Swift / SwiftPM / AppKit**, macOS 13+ (17 source files).
  The non-activating window is an `NSPanel` subclass with
  `canBecomeKey == false` — the native equivalent of murmur's
  `.nonactivatingPanel`.

---

## What it does (the design lead's spec → implementation)

| The design lead's endorsed spec | Implementation |
|---|---|
| Small **bottom-center pill** on the focused screen | `DictationHUDController.positionPanel()` — `NSScreen.main.visibleFrame`, bottom-center, above the Dock |
| **Non-activating** (`canBecomeKey == false`) — load-bearing, or paste-at-cursor breaks | `DictationHUDPanel` overrides `canBecomeKey`/`canBecomeMain` → `false`; panel is `.nonactivatingPanel` + `ignoresMouseEvents` (click-through) |
| **Recording:** mic glyph + **live audio input-level meter** + elapsed timer | `DictationHUDPillView` draws a mic glyph, a 12-segment level meter, and a `m:ss` timer |
| **Transcribing:** quiet spinner | rotating arc + muted "Transcribing…" |
| **Problem:** one plain line (e.g. "No audio — check mic") | warning dot + single line |
| **Input-level meter reads REAL mic input** (highest-value element) | `AudioRecorder.onLevel` computes RMS on the **same capture buffer that gets recorded** (collector-path parity — the meter cannot drift from what a real dictation records); `AudioLevelMeter` maps RMS→dB→0…1 with attack/decay smoothing |
| **NO** live transcript, confidence, or decorative waveform | none drawn — a segmented *level* meter only |
| Fades in on record start, auto-dismisses ~1s after paste | fade in on `.recording`; auto-dismiss `~0.85s` after returning to `.idle` (idle happens right after the paste) |

### Silent-failure detection (the design lead's core rationale)
While recording, `NoAudioDetector` watches the meter; if the loudest sample
stays below a small threshold past a ~1.4s grace window, the recording pill
swaps its timer line for **"No audio — check mic"** in-context — exactly the
function-key-mode / muted-mic / permission-lapse cases the assessment calls out,
made loud where the CEO is looking instead of silently failing.

---

## Architecture (files the patch touches)

New:
- `Sources/OpenWisprLib/DictationHUDModel.swift` — **pure, AppKit-free, unit-tested** logic: `AudioLevelMeter` (RMS→dB→smoothed meter), `NoAudioDetector`, `HUDPresenter` (phase→display reducer), `HUDFormat` (timer).
- `Sources/OpenWisprLib/DictationHUD.swift` — AppKit shell: `DictationHUDPanel` (non-activating), `DictationHUDPillView` (drawing), `DictationHUDController` (window lifecycle, positioning, fades, 30fps render tick).
- `Tests/OpenWisprTests/DictationHUDModelTests.swift` — 28 deterministic tests of the model + the non-activating invariant.
- `Tests/OpenWisprTests/DictationHUDRenderTests.swift` — 6 offscreen render tests (draw each state to an in-memory bitmap; verify state-sensitivity; **no window is shown**).

Modified (minimal):
- `AudioRecorder.swift` — adds `var onLevel: ((Float) -> Void)?`; computes RMS in the existing capture tap; emits 0 on stop.
- `StatusBarController.swift` — adds `var onStateChange: ((State) -> Void)?`, fired in the existing `state` `didSet` (the HUD mirrors the exact same single-source-of-truth lifecycle as the menu-bar icon).
- `AppDelegate.swift` — instantiates the HUD, wires `onStateChange` (via `hudPhase(for:)`) and `onLevel`, tears down on terminate.

The HUD is purely additive: the menu-bar icon, hotkey/toggle behavior, paste
path, and transcription are unchanged.

---

## Build (reproducible, non-installing)

```bash
tools/open-wispr-hud/build.sh [workdir]
```

Clones open-wispr at `7ab4e62` (from the local Homebrew cache if present, else
GitHub), applies the patch, **runs the full test suite (must be green)**, builds
`-c release`, and bundles `OpenWispr.app`. It does **not** install or restart
anything.

Verified: fresh checkout + patch → `swift build` clean, **158/158 tests pass**,
release build + `OpenWispr.app` bundle succeed.

## Apply (manual — triggers the live gates, do when the CEO is present)

Installing means replacing the running app and restarting the dictation service,
which re-raises the mic/accessibility permission prompts and is the moment to
verify F13 + paste-at-cursor. **Do not run this unattended on the CEO's active
machine.** When ready:

```bash
# 1. Build (see above); note the printed OpenWispr.app path as $APP
brew services stop open-wispr

# 2. Swap the app bundle + CLI binary in place
DEST=/opt/homebrew/opt/open-wispr
cp -R "$APP" "$DEST/OpenWispr.app.hud" && rm -rf "$DEST/OpenWispr.app" && mv "$DEST/OpenWispr.app.hud" "$DEST/OpenWispr.app"
cp "$APP/Contents/MacOS/open-wispr" /opt/homebrew/bin/open-wispr

# 3. Restart; macOS may ask to re-grant Accessibility after a binary change
brew services start open-wispr
```

Then live-verify: tap **F13**, watch the pill fade in bottom-center, speak (the
meter should move), confirm the transcribed text pastes at the cursor in a
normal app (email/docs/chat composer), and that the pill auto-dismisses.

## Rollback (clean)

```bash
brew reinstall open-wispr    # restores pristine v0.43.0, removes the HUD
brew services restart open-wispr
```

`brew reinstall` re-fetches/rebuilds the audited v0.43.0 and overwrites our
swapped files. Because a plain `brew upgrade`/`reinstall` will also silently
undo the HUD, treat re-applying the patch as part of any open-wispr upgrade.

---

## Verification status

**Verified (deterministic, headless — no window shown on the CEO's screen):**
- Fresh `7ab4e62` + patch applies cleanly, builds (debug **and** `-c release`), bundles `OpenWispr.app`.
- Full suite **158/158 green** (124 pre-existing + 34 new).
- State logic + the RMS→meter mapping unit-tested (silence→0, loud→full, monotonic dB window, attack faster than decay, deterministic).
- No-audio silent-failure detection unit-tested (grace window, threshold, reset).
- Phase→display reducer + `StatusBarController.State`→`HUDPhase` mapping tested for every state.
- **Non-activating invariant** asserted by test (`canBecomeKey`/`canBecomeMain` are `false`).
- Offscreen render sanity: every state draws non-empty, meter is level-sensitive, states differ. Built binary `--help`/`status` run clean.

**Pending (the real gates — deferred by design):**
- **The design lead's live visual audit** on the real surface (an explicit signoff requirement).
- **CEO real-use:** F13 fade-in, meter moving on real speech, **paste-at-cursor still lands** in email/docs/chat (the load-bearing non-activating proof in practice), multi-display placement + Dock-hidden behavior, permission re-grant flow.

## Deviations from the spec (flagged, not silent)

1. **Pill size 244×44** — the design lead said "roughly `340×76`, or smaller." Chosen smaller to honor the calm/unobtrusive bar. Trivially tunable (`DictationHUDController.pillSize`).
2. **No-audio warning is shown inline in the Recording pill** (swapping the timer line) rather than as a separate Problem pill, so silent failure is caught *in-context while recording* — realizing the assessment's "make silent failure loud" intent. Reuses the Problem message string.
3. **`waitingForPermission` surfaces as a Problem line** ("Waiting for mic / accessibility permission"). It's a permission failure, so it maps into the existing Problem state — not a 4th state.
4. **Screen selection uses `NSScreen.main`** as the "screen with keyboard focus" approximation (our app is an accessory and never key). Multi-display correctness is on the live-verification list (design-lead follow-up #3).
