# RichOS capture — architecture (Stage 0, extension-only)

This implements **Stage 0** of the loro call-capture architecture in
the caption-capture analysis brief, 2026-08-23, retargeted on two
points and with one thing deliberately removed. Read that brief for the reasoning; read this
file for what was actually built and why it differs.

## What changed from the brief

| Brief (Stage 0) | Built here | Why |
|---|---|---|
| macOS-first, with a local native helper | **Cross-platform Chrome extension only** | The CEO's calls run on Windows; development and testing happen on a Mac. A Chrome MV3 extension is the same code on every OS, so "which machine" stops being an engineering question. There is no OS-conditional code in the extension. |
| Native-messaging helper as the outside-the-browser watchdog, from day one | **Deferred** (specified below, not built) | It is the single largest piece of work in the brief and it is per-OS. Everything else in the guarantee — chunked durable writes, second-by-second health, in-call alarms, recovery, verification — is achievable inside the browser, and is now proven to work in a browser. Shipping that first gets the guarantee into use in days rather than weeks, and real usage tells us whether the remaining ceiling actually bites. |
| Session directory written into the loro repo | **Written to Chrome's downloads folder, moved by a sync helper** | Extensions may only write inside the downloads folder. The alternative is the native host (below). One command bridges the gap. |
| Health pill injected into the meeting page | **Toolbar badge + popup only** | Nothing may be visible to the other party or appear in a screenshare. The badge is also strictly more reliable than an in-page element: it lives in the browser chrome, so it survives anything that happens to the page. |
| Live in-tab chime | **Off by default** | An open microphone would put the chime into the call. |
| Caption adapters (Stage 1+) | **Built as a secondary failsafe + enrichment layer (Meet first)** | Audio-first is still the whole point; captions never become the guarantee. But collecting them is pure upside (§Captions below): a zero-gesture third channel, per-remote-speaker names, and an accuracy cross-check — losing them costs only enrichment, because the audio is recoverable. |
| One click before anything is captured | **Hybrid auto-start: mic + captions run with zero gesture** | The click is genuinely unavoidable for *tab* audio (a Chrome security boundary), but it should not gate the other two channels. Now only tab audio waits for the click; mic + captions start on sight (§Hybrid auto-start). |

## Why one unified extension

The CEO installs **RichOS**, not a collection of tools. Call capture is module 1; the existing
GPT Exporter (`engine/tools/gpt-exporter/`) becomes module 2 — both are loro capture channels.
The split is enforced structurally:

```
core/        settings · IndexedDB · offscreen host · output writer · alerts/badge · registry
modules/
  call-capture/     everything about calls
  chatgpt-export/   seam stub only
```

A module is a plain object with `id`, `defaults`, `settingsSchema`, `init`, `onMessage`,
`getStatus`. Registering it gives it namespaced settings, a settings UI rendered from its own
schema, the drop-zone writer, the badge and the alerting stack — no duplication. The offscreen
document is core-owned because Chrome permits exactly one per extension.

## Runtime shape

```
┌──────────────────────────── Chrome ─────────────────────────────┐
│  meet.google.com tab                                            │
│    · READ-ONLY caption content script (captions/content-meet.js)│
│      observes the caption overlay, renders NOTHING in the page  │
│      (the only visible page injection remains the opt-in banner)│
│    · other call tabs: not touched at all                        │
│              │ cc:caption (deduped revisions)                    │
│  offscreen document  (core/offscreen.html)                      │
│    · tab audio  ──┐  (added on the ARM click)                   │
│    · microphone ──┴─► ChannelMerger(2) ─► MediaStreamDestination │
│    · tab audio also ─► ctx.destination  (you keep hearing it)   │
│    · AudioWorklet level meters on each source                   │
│    · MediaRecorder(timeslice) ─► IndexedDB, one awaited write    │
│      per chunk                                                  │
│                    │ heartbeat 1 Hz + chunk acks                │
│  service worker ───┴─ watchdog · recovery · alarms · export      │
│    · mic + captions auto-start with ZERO gesture on detection   │
│    · session record written at call START                       │
│    · captions persisted to IndexedDB (same count → captions.ndjson)│
│    · chrome.downloads ─► Downloads/richos-capture/<session>/     │
└─────────────────────────────────────────────────────────────────┘
                                │  sync/richos-sync.mjs (reconcile.js)
                                ▼
   loro  wiki/raw/meetings/<session>/  ─► whisper + captions ─► transcript.md
     (captions.ndjson → per-speaker names merged in + accuracy cross-check score)
```

### Load-bearing details

- **`tabCapture` mutes the tab.** The tab source is reconnected to `ctx.destination`, or the
  CEO stops hearing the meeting the instant capture arms. The microphone is *never* connected
  there (that would echo into the call).
- **Two channels, not a mix.** Left = microphone, right = tab. Free "me vs them" separation for
  transcription with no diarisation model.
- **Chunks are awaited.** `persistChunk` commits to IndexedDB before acknowledging, so the
  crash window is one `chunkMs` (default 3 s), not "whatever was buffered".
- **Parts.** Every recovery starts a new `audio-part-NN.webm`. Each part is a self-contained
  WebM, so a corrupted part cannot poison the ones after it. Chunks *within* a part must be
  exported together — the first chunk carries the header. (Violating this produced an
  unplayable fragment during development; orphan recovery now refuses to export a session the
  recorder still has open.)
- **Levels come from an AudioWorklet, not a polled analyser.** The recorder lives in a hidden
  document and Chrome throttles timers there; a polled analyser measured exactly 0.000 for an
  entire session while the recording was at −20 dB. The worklet sees every 128-sample block.
- **The numbers shown are the numbers written.** Byte and chunk counts in the popup, the health
  evaluator and `session.json` all come from the recorder that performed the writes — never a
  second counter that can drift from reality.
- **Pure health logic.** `health.js`, `platforms.js` and `session.js` contain no `chrome.*` and
  are unit-tested with a fake clock, because everything the CEO gets alarmed about is decided
  there.

### Health signals and their budgets

| Signal | Source | Amber | Red | Recovery |
|---|---|---|---|---|
| Recorder heartbeat | offscreen → SW, 1 Hz | 7 s | 15 s | rebuild the offscreen document |
| Chunk arrival | MediaRecorder | 7 s | 15 s | restart the recorder (new part) |
| Byte growth | committed chunk sizes | — | 15 s | restart the recorder |
| Recorder state | `MediaRecorder.state` | — | not recording | restart |
| Audio graph | `AudioContext.state` | — | not running | resume, then restart |
| Track liveness | `MediaStreamTrack.readyState` | muted | ended | re-attach tab / re-acquire mic |
| Digital silence per channel | worklet peak | — | 20 s | re-attach tab / re-acquire mic |
| Speech present | worklet peak vs floor | 120 s | never red | none (nobody talking is legitimate) |
| Not armed at all | tab scan | — | 10 s | loud alarm; only a human click can fix it |

Attempts are capped (5 per signal, 5 s apart) so a genuinely dead channel stays loud instead of
thrashing, and every attempt is recorded in `session.json`.

## Hybrid auto-start — mic + captions with zero gesture

Chrome will not release a tab's audio to an extension until the extension is *invoked* for that
tab; that is a real security boundary and we do not work around it. But it should only gate the
**tab-audio** channel — not the microphone (which needs a one-time extension-level permission, not
a per-tab invocation) and not captions (read from the page's own DOM). So the arming model is now
three-tiered, driven by `armMode: 'auto'` + `autoStartMicCaptions`:

- On detecting a call tab, the controller mints a tab-audio stream id. If Chrome grants it (the CEO
  had already invoked the extension for that tab), the session starts in **`full`** mode.
- If Chrome refuses (`needsInvocation`) on an `auto` trigger, the controller starts the session
  anyway in **`mic+captions`** mode (`recorder` started with `expectTab:false`, which is an
  *intentional* no-tab start, not a failover) and raises the red `ARM` prompt for the one click.
- If even the microphone is unavailable (permission not yet granted), it degrades to
  **`captions-only`** (no recorder at all) and stays loud — never silent.
- The ARM click routes to `armTab(tabId, 'popup'|'shortcut')`, which now takes an **upgrade** path:
  it mints the (now-granted) stream id and *adds* tab audio to the live session via the recorder's
  existing `reattach-tab` (or, for `captions-only`, starts the recorder fresh) — capture is never
  restarted from zero, so the seconds before the click are already captured.

All arm entry points are serialised through a single promise chain (`armChain`), because captions
can arrive faster than a session can be created and each one may trigger an auto-start; without
serialisation two concurrent starts would double-build the recorder. The mode, `awaitingTabAudio`
and `audioActive` flags are persisted with the active session so a service-worker restart restores
the exact state.

Health treats `awaitingTabAudio` as **amber** (partial capture) and never as red or a recovery
action — the controller owns the red `ARM` prompt for the missing ground-truth channel. A
`captions-only` session has no recorder, so `tick()` skips audio evaluation entirely and just keeps
the red `ARM` prompt alive while captions keep landing.

## Captions — the secondary failsafe + enrichment layer

Captions are collected as a **secondary** channel. The guarantee is unchanged (audio is ground
truth); captions are pure upside precisely because of the inversion versus a caption-harvester —
for a harvester, captions breaking is total loss; for us it loses only enrichment. They buy three
things: a zero-gesture belt-and-suspenders third channel, per-remote-speaker **names** (which the
2-channel audio cannot give — audio gives "you vs. them", captions add *which* of them), and an
accuracy cross-check.

- **Read-only, clean-room DOM observation.** `captions/meet.js` observes the caption overlay Meet
  renders and reads text + speaker off the DOM. The Tactiq dissection showed they instead hook the
  internal WebRTC `captions` data channel in the page's MAIN world; we copied none of that and do
  the opposite (the one thing their write-up says they *avoid*), which is provably our own design
  and, for a secondary layer, the right trade: no MAIN-world injection, no page-global patching.
  It is honestly more fragile to Meet restyles — which is exactly why captions are secondary and
  **fail soft**: a broken adapter reports a degraded-captions state and loses enrichment, never the
  call, and never raises a hard audio alarm.
- **Both renderers.** Meet ships caption markup in more than one shape (classic obfuscated classes
  and a newer server-driven layout). `extractCaptionRows` tries region/row/speaker/text selectors
  in order and falls back to a structural heuristic, so a class-name change degrades to
  lower-fidelity capture rather than to zero. Both shapes are covered by deterministic tests
  (`tests/run.js`), and the exact production class names are a tuning step to confirm on a real Meet
  call (see the caveat in the build report), not a correctness prerequisite.
- **One collector path for the count.** `caption-dedup.js` (`CaptionAggregator`) turns the stream
  of in-place caption mutations into append-only revision events; the content script sends only
  those to the SW, which persists each to the `captions` IndexedDB store and increments the count
  **only on a successful write**. `captions.ndjson` is written from those exact rows at finalise,
  and `session.json`'s `captions.count` is set from the same read — so the number shown in the
  popup, the number in `session.json`, and the line count on disk are one number (the LinkedIn
  rule). The live harness asserts this parity on disk.
- **Manifest content script — why it is allowed.** Reading captions needs a content script on
  `meet.google.com`, declared in `content_scripts` with a matching `host_permissions` entry and
  `web_accessible_resources` (the ISOLATED-world bootstrap dynamically imports the ES-module
  adapter). This does **not** violate the toolbar-only rule: the rule forbids injecting *visible
  UI* into the page, and this script renders nothing — it only reads. Status UI stays toolbar-only
  (badge + popup); the sole permitted visible page injection remains the opt-in disclosure banner.

### Captions-as-failsafe reconciliation

A call that produced **captions but no audio** (tab audio never armed, or capture failed for the
whole call) is neither silent success nor silent loss — captions prove a call happened, so the
missing audio is a first-class anomaly. `verifySession` flags it specifically at finalise;
`sync/reconcile.js` (shared by the CLI and the tests) flags it at sync and refuses to treat the
session as complete; and orphan recovery on the next boot writes a flagged `captions-only`
recovered session and alerts the CEO. Nothing about captions is ever silently accepted or dropped.

### The enrichment seam (downstream, not built here)

Captions land with enough structure (`speaker`, `text`, `t`, `firstT`, `revision`, `id`, `adapter`)
for the loro ingest to (a) merge the platform's speaker names into the Whisper transcript and (b)
compute a per-call caption-vs-transcript agreement score. Those computations are post-call at
ingest and are deliberately **not** in the extension — the extension's job is only to land the data
that makes them possible.

## The deferred increment — a native companion (cross-platform, NOT built)

The extension cannot survive Chrome itself dying, and cannot hear desktop-app calls. Both need
a small process outside the browser. When it is built it should be **one codebase with per-OS
builds** (Windows service/tray binary, macOS launch agent, Linux systemd user unit) — not a
Windows-only tool — and it should keep the extension exactly as it is, connected over Chrome's
native-messaging stdio channel (no listening port, starts and dies with the browser).

Scope, in priority order:

1. **Outside-the-browser watchdog.** It holds its own timer; "the browser stopped talking to
   me" becomes an alarm the browser cannot suppress, and a browser crash mid-call is detected in
   seconds instead of at next launch.
2. **Direct writes to the loro repo**, removing the Downloads hop and the sync command.
3. **Post-call transcription on the spot** (whisper.cpp / faster-whisper per channel), plus the
   verification artifact the brief specifies.
4. **System-audio capture** for desktop-app calls (WASAPI loopback on Windows, ScreenCaptureKit
   on macOS, PipeWire on Linux) — the one hole a browser genuinely cannot close.

Until then, item 4 is stated plainly in the README's can/cannot table rather than hidden.

## Open questions for the CEO

1. **Where do your calls actually happen** — browser or desktop app? If most are desktop Zoom,
   the native companion jumps the queue and item 4 becomes the priority rather than the last
   step.
2. **Is one keystroke per call acceptable?** Chrome will not release tab audio without it. The
   extension makes forgetting impossible, but it cannot remove the keystroke.
3. **Desktop notifications during screenshares.** Failure alerts default to a desktop
   notification, which *is* visible if you are sharing your whole screen. Keep as is, or make
   the red badge the only failure surface while sharing?
4. **Retention.** Audio is ~43 MB per call-hour. Purge after the transcript exists (default 30
   days, enforced by the sync helper), or keep everything?
5. **Second concurrent call.** Today a second call tab raises an alarm and is not captured.
   Should it record both?
