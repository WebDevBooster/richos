# open-wispr dictation patches — reproducible

Our two local patches on top of **open-wispr** (`human37/open-wispr` MIT, built
from audited source at commit `7ab4e62e` = v0.43.0):

1. **HUD** — a minimal, calm recording-state HUD. It makes silent dictation
   failures visible and gives the "it hears me" signal our menu-bar icon lacks.
2. **Two-model dictation** — Accurate (`large-v3-turbo-q5_0`, default) / Fast
   (`small.en`) with a live menu toggle, plus explicit configurable model-path
   resolution. See [Two-model dictation](#two-model-dictation-accurate--fast) below.

Built to **the design lead's endorsed spec**
(the dictation-HUD assessment, 2026-08-24). This directory holds
**only our patch + reproducible build/apply/rollback instructions** — the
open-wispr tree itself is NOT vendored here (mirrors how the earlier voice-pilot patches are
handled). CEO greenlit 2026-08-24 ("go ahead as recommended").

- **Base commit (audited):** `7ab4e62e8f182f3ecc2116e1094a1eb4416a248f`
- **Patch 1 (what we build/install):** [`dictation-hud.patch`](./dictation-hud.patch)
- **Patch 2 (applied ON TOP of patch 1):** [`dictation-two-model.patch`](./dictation-two-model.patch)
- **Patch (upstream-ready, HUD-free):** [`device-change-listener.patch`](./device-change-listener.patch)
- **Build:** [`build.sh`](./build.sh) — applies both patches, in order
- **Models:** [`fetch-dictation-models.sh`](./fetch-dictation-models.sh)
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

## Two-model dictation (Accurate / Fast)

`dictation-two-model.patch`. RichOS ships **one** app carrying **two** whisper
models with a user-facing toggle. Full rationale and every measurement:
the local-dictation notes and
the two-model dictation brief, 2026-08-26.

| Mode | Model | Disk | Cold latency (2.8s / 25.1s clip) | Pooled WER |
|---|---|---|---|---|
| **Accurate** (default) | `large-v3-turbo-q5_0` | 574,041,195 B | 1.29 s / 1.88 s | 5.6 % |
| **Fast** (opt-in) | `small.en` | 487,614,201 B | 0.50 s / 1.25 s | 7.7 % |

Full `large-v3-turbo` is **dropped from the dictation path**: measured
byte-identical transcripts to `q5_0` on 34/36 runs while costing 1.05 GB more
disk, 1.13 GB more RAM and 0.20–0.27 s more latency. It remains the default for
post-call batch transcription (`tools/richos-service`), which this patch does
not touch.

### What the patch changes

New:
- `Sources/OpenWisprLib/DictationModels.swift` — **pure, AppKit-free,
  unit-tested**: `DictationMode` (accurate/fast), the model ids, and the
  model-path resolution order.

Modified (minimal):
- `Config.swift` — adds `modelDir`, `accurateModel`, `fastModel`; makes the
  long-dead `modelPath` field load-bearing; default `modelSize` becomes
  `large-v3-turbo-q5_0`; one-time migration of a pre-two-model config.
- `Transcriber.swift` — `findModel` takes an explicit `modelPath`/`modelDir`
  and consults `DictationModels.candidatePaths`.
- `StatusBarController.swift` — a top-level **Dictation** radio pair.
- `AppDelegate.swift`, `main.swift` — pass the new config through.

### Three properties worth stating

1. **Live switching, no restart.** Writing the config fires the existing
   `onConfigChange`, which rebuilds the `Transcriber`. Transcription is a fresh
   `whisper-cli` subprocess per utterance, so the very next F13 tap uses the new
   model. Nothing resident has to be swapped.
2. **The mode is derived, never stored.** There is deliberately no
   `dictationMode` field. The menu checkmark is computed from `Config.modelSize`
   — the exact value passed to `whisper-cli -m` — so the label cannot claim a
   mode the next dictation will not actually use.
3. **No hardcoded user paths.** Resolution order is `config.modelPath` (an exact
   file) → `$OPENWISPR_MODEL_DIR` (`:`-separated) → `config.modelDir` →
   `~/.config/open-wispr/models` → `~/Models/Whisper` → the whisper.cpp install
   dirs. Every home-relative default is built from
   `FileManager.default.homeDirectoryForCurrentUser`, and a unit test asserts no
   candidate path contains a literal user name.

### Models on disk

```bash
tools/open-wispr-hud/fetch-dictation-models.sh [dest-dir]
```

Downloads both `.bin` files into one shared directory (default
`~/Models/Whisper` — the same directory `tools/richos-service` and
`app/crates/richos-voice` already resolve, so one copy serves all three whisper
consumers), verifying exact byte size and GGML magic before installing. Total
**1,061,655,396 bytes (1.06 GB)** — still 563 MB less than shipping full
`large-v3-turbo` alone. A missing model is otherwise downloaded on first use by
open-wispr's own `ModelDownloader`.

### Upgrade behaviour on the CEO's live install

His `~/.config/open-wispr/config.json` predates the toggle (`modelSize:
"small.en"`, no `accurateModel`/`fastModel` keys). On first launch of a patched
build, `Config.load()` records the model pair and adopts the accurate default
once, printing a line to the service log. Reverting is one menu click (Fast).
The migration is keyed on the absence of `accurateModel`, so it can never
re-override a later choice of his.

---

## Build (reproducible, non-installing)

```bash
tools/open-wispr-hud/build.sh [workdir]
```

Clones open-wispr at `7ab4e62` (from the local Homebrew cache if present, else
GitHub), applies **both patches in order** (`dictation-hud.patch`, then
`dictation-two-model.patch`), **runs the full test suite (must be green)**,
builds `-c release`, and bundles `OpenWispr.app`. It does **not** install or
restart anything.

Verified with the HUD patch alone: fresh checkout + patch → `swift build` clean,
**158/158 tests pass**, release build + `OpenWispr.app` bundle succeed.
Verified with both patches (2026-08-26): `swift build` clean, the **168
pre-existing tests still pass**.

## Apply (scripted)

```bash
tools/open-wispr-hud/build.sh /tmp/ow            # prints $APP
tools/open-wispr-hud/install-hud.sh "$APP"
launchctl bootout   gui/$(id -u)/homebrew.mxcl.open-wispr
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/homebrew.mxcl.open-wispr.plist
pgrep -fl "open-wispr start"                     # ground truth: which binary is live
```

`install-hud.sh` installs to `~/Applications/OpenWispr.app` and repoints the
existing Homebrew LaunchAgent at it — **the Homebrew keg is never modified**, which
is what makes rollback instant and offline. It also widens the Microphone TCC grant
to accept both binaries so neither the swap nor the rollback re-prompts.

`launchctl kickstart -k` alone is **not** enough after editing the plist: launchd
keeps the loaded job definition and restarts the old path. Use bootout + bootstrap.
This was documented here but **not implemented in the scripts**, which called
`kickstart` and then exited 0 while the old binary was still running (measured
2026-08-24: PID 28010 on `~/Applications` after the plist said Homebrew). Fixed in
`b21aa2d`; `rollback-to-homebrew.sh` now also fails non-zero unless the running
executable is the intended one and the log reaches `Ready.`

**One manual step remains and cannot be scripted:** Accessibility is keyed to the
binary and its TCC row lives in the SIP-protected system database (verified
read-only even with Full Disk Access). After installing:

> **System Settings → Privacy & Security → Accessibility → remove any stale
> `OpenWispr` entry, then `+` and pick `~/Applications/OpenWispr.app` explicitly.**

**Not off-then-on.** That was the original instruction and it does **not** work:
a toggle re-affirms the cdhash the row already holds, so it re-grants the *old*
binary and the new one still reports `Accessibility: not granted` (measured
2026-08-24 — runbook §10.2). The row must be created against the new bundle.
And it dies again on that bundle's next rebuild: under ad-hoc signing the
designated requirement is `cdhash H"..."` and nothing else, so there is no
click-free, rebuild-durable option. See runbook §11 — this is why RichOS must ship
Developer ID signed. Until then the app blocks at
`Waiting for Accessibility permission...` and dictation does not work at all — the
hotkey is not registered yet. The HUD says so, bottom-centre.

## Rollback (one command, offline, tested)

```bash
tools/open-wispr-hud/rollback-to-homebrew.sh
```

Repoints the LaunchAgent at the untouched Homebrew keg and restarts. No network, no
rebuild. Tested against the live install before the swap: reached `Ready.` with
microphone and accessibility granted.

Rollback **does** restore Accessibility with zero clicks, as long as the grant was
never explicitly re-created against the HUD build: the row stays bound to the
Homebrew cdhash. Verified 2026-08-24 — the rolled-back daemon (PID 28649) logged
`Microphone: granted` / `Accessibility: granted` / `Ready.`
(An earlier caveat here claimed the opposite; it was falsified — runbook §10.3.)

Full detail: the dictation troubleshooting runbook, 2026-08-24, §9 (build)
and §10–§11 (the TCC root cause and what it forces on RichOS packaging).

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
