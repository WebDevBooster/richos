# RichOS — the capture extension

One Chrome extension, several modules. The first module is **call capture**: it records both
sides of your calls to local disk and checks, second by second, that the audio is really being
written — so a capture failure is something you learn about *during* the call, not afterwards.

Everything stays on your machine. No account, no cloud, no third-party service, nothing to
subscribe to. The same unpacked folder runs on Chrome for **macOS, Windows and Linux** — there
is no OS-specific code anywhere in it.

---

## The guarantee

> **Both capture channels are health-monitored second by second for the whole call; any stall
> alarms you within seconds and fails over automatically; and because the raw audio is written
> to local disk continuously, no failure discovered at any point can lose the call's content.**

The invariant underneath it: **never lose the audio.** Audio is ground truth. If the raw audio
exists, no transcription problem is ever fatal — the worst case is running the transcriber
again on a file you already have. That is why RichOS captures audio first and treats platform
captions as a strictly secondary layer, not a foundation.

**Three independent capture channels, so a detected call is never fully uncaptured:**

1. **Microphone (you)** and **2. platform captions** start *automatically, with zero clicks* the
   moment a call tab is detected. Captions are secondary (enrichment + failsafe), but they cover
   the seconds before audio is armed and the worst case where audio never arms at all.
3. **Tab audio (everyone else)** is the recoverable ground truth. Chrome will not release it
   without one invocation per tab, so it still takes a single click (or `Alt+Shift+L`) — and that
   click merely *upgrades* an already-running mic + captions session to full capture.

If a channel fails, the others carry on and you are told within seconds. Captions breaking loses
only enrichment — the opposite of a caption-only tool, for which captions breaking loses the whole
meeting.

Three design choices carry that guarantee:

1. **Chunked, awaited writes.** The recorder hands over a chunk every 3 seconds (configurable)
   and each one is committed to IndexedDB *before* it is acknowledged. A tab crash, a
   service-worker eviction, an extension reload or a browser kill costs at most one chunk.
2. **The session record is written at call START, not at the end.** A call that captured
   nothing therefore leaves an `open` session on disk with no audio — a loud anomaly any
   process can see — instead of an absence nobody notices until they go looking for a
   transcript.
3. **The watchdog is not the recorder.** The service worker evaluates the recorder's own
   reported numbers every second, and both are recovered from disk on restart.

---

## Honest limits — what this CAN and CANNOT survive

A pure MV3 extension can protect a lot, but not everything. This table is deliberately blunt.

| Failure | Handled? | What actually happens | Worst-case loss |
|---|---|---|---|
| Meeting tab reloads or navigates away | **Yes** | Session finalises and exports; a new tab arms again | 0 (up to one chunk) |
| Meeting tab crashes | **Yes** | Tab-audio track ends → mic-only failover + red alarm; audio already on disk | ≤ one chunk on that channel |
| Service worker evicted (routine in MV3) | **Yes** | The next heartbeat wakes it; it re-attaches to the running recorder | 0 |
| Extension reloaded / updated mid-call | **Yes** | Chunks survive in IndexedDB; recovered and exported on next boot, loudly | ≤ one chunk |
| Microphone device switches (Bluetooth handoff) | **Yes** | Device re-acquired, new part started, alarm if it fails | ≤ a few seconds of your side |
| Tab audio stream ends | **Yes** | Re-attach attempted; otherwise microphone-only failover + red alarm | Other party's audio until recovered |
| Audio stops flowing while everything "looks fine" | **Yes** | Chunk-arrival, byte-growth, audio-graph-state and per-channel level signals all alarm | 0 (alarmed in ≤15 s) |
| Caption feature breaks (Meet DOM/protocol change) | **Yes (soft)** | Captions degrade; the audio path is untouched and no hard alarm fires | Enrichment only — never the call |
| Call captured captions but never any audio | **Flagged** | A specific anomaly at finalise and at sync (captions prove a call happened) | You are told; the captions are still saved |
| Digital silence (wrong input, muted at OS level) | **Yes** | Red alarm in ≤20 s | You are told *during* the call |
| Disk full / storage write fails | **Yes** | Chunk write error alarms immediately | Alarmed at once |
| Browser is quit or killed mid-call | **Partly** | Everything already committed is recovered and exported on next launch, with an alarm | ≤ one chunk, plus the rest of the call is not captured until you re-arm |
| **Whole-browser crash, OS kill, power loss** | **NO** | Recovery happens on next launch, but nothing captures the remainder of the call, and an OS-level kill between two commits can cost that chunk | The remainder of the call |
| **Calls in a desktop app** (Zoom/Teams native, FaceTime, phone) | **NO** | A browser extension cannot hear them at all | Everything — join calls in the browser, or wait for the native companion |
| **Chrome itself being terminated by the OS** | **NO** | No process outside the browser is watching | Detected only at next launch |

The last three rows are the honest ceiling of an extension-only design. Closing them needs a
small companion process that lives *outside* the browser — specified, not built, in
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## Install

1. Open `chrome://extensions/`
2. Turn on **Developer mode** (top right)
3. **Load unpacked** → select this `tools/richos-extension` folder
4. Pin the RichOS icon to the toolbar (extensions puzzle icon → pin)
5. Open **Settings** from the RichOS popup and click **Grant** next to *Microphone access*
   once. Chrome asks once, for the extension — not per call.

That is the whole setup. Identical on macOS, Windows and Linux.

---

## Using it

### Arming — one thing you should know

Chrome will not hand a tab's audio to any extension until the extension has been *invoked* for
that tab. This is a browser security boundary, and RichOS does not try to work around it — but
it no longer means "nothing is recorded until you click". The exact refusal, measured on this
machine, is:

```
Extension has not been invoked for the current page (see activeTab permission).
```

So the hybrid automatic flow is:

- RichOS recognises a call tab (Meet, Zoom web, Teams web, Whereby, Slack/Discord/Webex when
  audible) and **immediately starts recording your microphone and collecting captions — no
  click.** Your microphone needs a one-time permission grant (below); after that, mic + captions
  start on every call with zero gesture.
- It also tries to arm tab audio. Chrome refuses without an invocation, so **the badge turns red
  (`ARM`) and you get one alert within ~10 s**: click the RichOS icon on the call tab, or press
  **Alt+Shift+L**. That click *upgrades* the running mic + captions session to full tab-audio
  ground truth — it does not start capture from scratch, because capture is already running.
- If the microphone permission is missing, RichOS degrades to **captions only** and stays loud
  about the missing audio — it is never silent, and the badge tells the two cases apart (CEO
  decision 2026-08-23): **amber `ARM`** while captions are actually landing ("degraded, but
  working — get ground truth"), **red `ARM`** if not one caption has landed either (or the
  caption adapter itself breaks) — the true "nothing is being captured" failure.

The grant lasts for the life of that tab, so it is one keystroke per call, not per minute — and
you can do it the moment the tab opens, before anyone joins.

### The status UI (always on, toolbar only)

Nothing is ever injected into the meeting page, so nothing RichOS shows can be seen by the
other party or appear in a screenshare.

| Badge | Meaning |
|---|---|
| grey / empty | idle |
| green `REC` | capturing, all channels healthy |
| amber `...` | degraded (warming up, quiet, or microphone-only failover) |
| amber `ARM` | **captions-only, and captions ARE flowing** — no audio yet, but the call is not going uncaptured; click to add audio (ground truth) |
| red `!` / `ARM` | true failure — something is wrong, mic + captions ARE running and one click will add tab-audio ground truth, OR captions-only with nothing captured at all (no caption has landed, or the caption adapter broke) |

`ARM` no longer means "nothing is recorded" — in the hybrid flow your microphone and the captions
are already being captured; the click adds the other side's tab audio. In captions-only mode, the
badge colour itself tells you whether captions are actually landing (amber) or whether nothing is
being captured at all (red). Click the icon for the exact state (including live caption count and
speaker labels).

Click the icon for detail: elapsed time, MB and chunks written, per-channel health
(microphone / tab audio / levels / audio graph), where the session is being saved, and the
result of the last call.

### Notifications

| Category | Default | Notes |
|---|---|---|
| Ambient status (badge + popup) | **Always on** | Toolbar only. Never participant-facing. |
| Routine "capture started/stopped" desktop notifications | **OFF** | Toggle in Settings. |
| Participant disclosure banner in the meeting page | **OFF** | Toggle in Settings; requires page access. For all-party-consent jurisdictions. The ONLY thing RichOS ever renders into a meeting page. |
| Caption content script on `meet.google.com` | **On** (read-only) | Reads the captions Meet renders and forwards them to the extension. Renders **nothing** in the page. |
| **Failure alerts** | **ON** | CEO-only, independent of the routine setting. Red badge always; desktop notification on by default; chime off by default (an open microphone would pick it up). |

### Settings

**General:** drop-zone folder · hide Chrome's download bubble · routine start/stop
notifications · failure alerts · failure chime · audio retention (advisory, used by the sync
helper).

**Call capture:** enabled · arming mode (automatic / manual) · also arm unrecognised audible
tabs · record microphone on its own channel · microphone DSP · chunk size · bitrate · maximum
session length · participant disclosure banner + text · keep raw chunks after export.

---

## What lands on disk

Chrome extensions may only write inside your downloads folder, so each call becomes a folder
under `Downloads/richos-capture/`:

```
Downloads/richos-capture/2026-08-23T14-05-02Z--meet--abc-defg-hij/
  session.json          written at call START (status "open"), rewritten at close
  audio-part-00.webm    2-channel Opus: LEFT = your microphone, RIGHT = everyone else
  health.ndjson         one JSON record per second: levels, chunk counts, track states
  captions.ndjson       secondary channel: one JSON record per caption revision
                        ({speaker, text, t, firstT, revision, id, adapter}) — present only
                        when the platform produced captions
```

Two channels rather than a mix means free "me vs them" speaker separation for transcription,
with no diarisation model involved.

`session.json` carries the schema version, extension version, platform, timings, capture
settings, per-part byte/chunk accounting, the health tally (green/amber/red seconds), every
alert raised, every recovery attempted, and a self-verification verdict. Anything not
trustworthy is stated in the file rather than smoothed over.

Size: roughly **43 MB per hour** at the default 96 kbps.

### Getting it into loro

```
node sync/richos-sync.mjs --to ~/richos/wiki/raw/meetings
node sync/richos-sync.mjs --to ~/richos/wiki/raw/meetings --dry-run --purge-after 30
```

The helper moves finished sessions and **refuses to quietly move anomalies** — a session still
marked `open`, one with no audio, one whose own verification failed, or one that captured
**captions but no audio** is reported, left in place, and the script exits non-zero. That last
case is the caption-failsafe reconciliation: captions prove a call happened, so missing audio is
a flagged failure, never silent success and never silent loss. (Shared logic:
`sync/reconcile.js`, unit-tested and exercised against the real CLI by `tests/sync-reconcile.mjs`.)

---

## Transcription (v0 seam)

A pure MV3 extension cannot run Whisper — there is no native binary, no filesystem, and no way
to spawn a process. Pretending otherwise would be the dishonest part of this design, so the
seam is explicit:

**v0:** the extension produces `audio-part-NN.webm` + `session.json` in the drop zone; the sync
helper moves them into loro's `raw/meetings/`; the loro ingest step runs local whisper.cpp /
faster-whisper over the two channels and writes `transcript.md` next to the audio. Post-call
transcription is also the *right* default: transcription is a pure function of the audio, the
audio is already safe, and running ASR live would heat the machine during the call for no
reliability gain.

Why not write straight into the repo? Because that needs a native-messaging host — see
[ARCHITECTURE.md](ARCHITECTURE.md). It is a genuine future increment, not a workaround, and the
Downloads path costs one command in the meantime.

### Captions as the enrichment seam

Captions are collected as a **secondary** channel (`captions.ndjson`) alongside the audio. At
loro-ingest they enable two things the audio alone cannot: (a) merging the platform's
**per-remote-speaker names** into the Whisper transcript (audio gives "you vs. them"; captions add
*which* of them), and (b) a **caption-vs-transcript agreement score** that turns accuracy into a
measured number. The extension does not compute the score — it just lands the caption data with
enough structure (`speaker`, `text`, `t`, `revision`, `id`) to make it possible post-call. Meet is
the first adapter (`modules/call-capture/captions/meet.js`) behind a generic, cross-platform seam
(`captions/adapter.js`); other platforms are future adapters. There is no OS-conditional code
anywhere in the framework.

---

## Testing

```
node tests/run.js             # pure logic: 47 tests, no browser, fake clock
node tests/sync-reconcile.mjs # the real sync CLI vs synthetic sessions on disk
node tests/live-capture.mjs   # real Chrome, real audio, real captions, real files on disk
```

The live harness launches a throwaway Chrome profile with the extension loaded, serves a page as
`https://meet.google.com/...` that plays a real tone **and emits Meet-shaped captions** so both
the real platform detection and the real caption content script run. It verifies that mic +
captions auto-start with no gesture, that captions land with speaker labels + timestamps through
the same collector path that persists them, that breaking the caption feature never touches the
audio, restarts the service worker mid-session, closes the call tab, and then verifies the
exported files — including decoding the audio and measuring that it contains actual sound. It also
collects everything the extension logs or throws. (Last run on this Mac: 37/37 checks passed.)

Branded Google Chrome refuses `--load-extension`, so the harness uses a Chrome for Testing /
Chromium build if one is cached locally (`CHROME_PATH` overrides). Loading the extension by
hand in your normal Chrome is unaffected.

For validating on a real call — including how to deliberately break each channel and watch the
alarm fire — see [TEST-PROTOCOL.md](TEST-PROTOCOL.md).

---

## Layout

```
manifest.json            MV3 shell (name: RichOS)
background.js            service worker: registers modules, routes messages
core/                    shared by every module
  constants.js           product identity, storage keys, badge colours, core settings
  settings.js            namespaced settings + defaults
  idb.js                 IndexedDB helpers
  offscreen-host.js      the single offscreen document's lifecycle
  offscreen.html/.js     offscreen router (blob URLs, alarm chime, module handlers)
  output.js              the ONE place bytes leave the browser
  alerts.js              badge, routine notifications, failure alerts, alert log
  registry.js            module registration + message routing
modules/
  call-capture/          module 1 — this README
    controller.js        arming, watchdog, recovery, export, verification (service worker)
    recorder.js          audio graph, MediaRecorder, chunk persistence (offscreen)
    level-meter-worklet.js  audio-thread level metering
    health.js            pure health evaluation (unit-tested)
    platforms.js         pure platform detection (unit-tested)
    session.js           pure session record + naming (unit-tested)
    constants.js         defaults, thresholds, settings schema
    captions/            the secondary caption channel (failsafe + enrichment)
      adapter.js         generic cross-platform seam (types + registry)
      caption-dedup.js   pure revision aggregation; the caption COUNT lives here (unit-tested)
      meet.js            Google Meet DOM adapter, read-only (both renderers)
      content-meet.js    tiny read-only content script injected on meet.google.com
  chatgpt-export/        module 2 seam — the GPT Exporter port lands here later
options/ popup/ icons/   shared UI shell
sync/
  richos-sync.mjs        drop zone → loro, with anomaly reporting
  reconcile.js           pure "does this hold the call?" logic (shared by CLI + tests)
tests/                   pure harness + sync-reconcile harness + live browser harness
```
