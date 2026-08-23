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
| Caption adapters (Stage 1+) | **Interface fixed, unimplemented** | Audio-first is the whole point. Captions add live speaker names; they add nothing to the guarantee. |

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
│  call tab (Meet / Zoom web / Teams web / anything with audio)   │
│    · not touched at all — no content script, nothing injected   │
│      (the only exception: the opt-in disclosure banner)         │
│                                                                 │
│  offscreen document  (core/offscreen.html)                      │
│    · tab audio  ──┐                                             │
│    · microphone ──┴─► ChannelMerger(2) ─► MediaStreamDestination │
│    · tab audio also ─► ctx.destination  (you keep hearing it)   │
│    · AudioWorklet level meters on each source                   │
│    · MediaRecorder(timeslice) ─► IndexedDB, one awaited write    │
│      per chunk                                                  │
│                    │ heartbeat 1 Hz + chunk acks                │
│  service worker ───┴─ watchdog · recovery · alarms · export      │
│    · session record written at call START                       │
│    · chrome.downloads ─► Downloads/richos-capture/<session>/     │
└─────────────────────────────────────────────────────────────────┘
                                │  sync/richos-sync.mjs
                                ▼
             loro  wiki/raw/meetings/<session>/  ─► whisper ─► transcript.md
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
