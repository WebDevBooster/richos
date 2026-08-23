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
again on a file you already have. That is why v0 captures audio first and treats platform
captions as a later convenience layer, not a foundation.

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
that tab. This is a browser security boundary, and RichOS does not try to work around it. The
exact refusal, measured on this machine, is:

```
Extension has not been invoked for the current page (see activeTab permission).
```

So the automatic flow is:

- RichOS recognises a call tab (Meet, Zoom web, Teams web, Whereby, Slack/Discord/Webex when
  audible) and immediately tries to arm.
- If Chrome refuses, **the badge turns red (`ARM`) and you get one alert**: click the RichOS
  icon on the call tab, or press **Alt+Shift+L**. That is the invocation, and capture starts.
- If a call tab is open and *nothing* is capturing, RichOS keeps telling you. Forgetting is
  the failure mode this design refuses to allow.

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
| red `!` / `ARM` | something is wrong, or a call is open and not being captured |

Click the icon for detail: elapsed time, MB and chunks written, per-channel health
(microphone / tab audio / levels / audio graph), where the session is being saved, and the
result of the last call.

### Notifications

| Category | Default | Notes |
|---|---|---|
| Ambient status (badge + popup) | **Always on** | Toolbar only. Never participant-facing. |
| Routine "capture started/stopped" desktop notifications | **OFF** | Toggle in Settings. |
| Participant disclosure banner in the meeting page | **OFF** | Toggle in Settings; requires page access. For all-party-consent jurisdictions. |
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
marked `open`, one with no audio, or one whose own verification failed is reported, left in
place, and the script exits non-zero. That is the "a call happened and we may not have it"
tripwire.

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

Captions (live speaker names from the platform's own caption feature) are deliberately **not**
in v0. The interface they will implement is fixed in `modules/call-capture/captions/adapter.js`,
and `session.json` already carries a `captions` block so ingest never has to change shape.

---

## Testing

```
node tests/run.js            # pure logic: 30 tests, no browser, fake clock
node tests/live-capture.mjs  # real Chrome, real audio, real files on disk
```

The live harness launches a throwaway Chrome profile with the extension loaded, serves a
tone-playing page as `https://meet.google.com/...` so real platform detection runs, records,
restarts the service worker mid-session, closes the call tab, and then verifies the exported
files — including decoding the audio and measuring that it contains actual sound. It also
collects everything the extension logs or throws.

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
    captions/adapter.js  the deliberate, unimplemented caption seam
  chatgpt-export/        module 2 seam — the GPT Exporter port lands here later
options/ popup/ icons/   shared UI shell
sync/richos-sync.mjs     drop zone → loro, with anomaly reporting
tests/                   pure harness + live browser harness
```
