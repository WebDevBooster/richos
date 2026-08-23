# RichOS capture — test protocol

Two parts:

- **Part A — automated**, runs anywhere in about a minute and needs no call and no human.
- **Part B — a real call**, which is the only way to exercise tab audio, because Chrome
  requires a human invocation before it releases a tab's audio to an extension.

Nothing in this protocol is OS-specific. It was developed and run on macOS; Part C is the same
protocol re-run on Windows or Linux to confirm the extension behaves identically.

---

## Part A — automated (no call needed)

```
cd tools/richos-extension
node tests/run.js            # expect: 30 passed, 0 failed
node tests/live-capture.mjs  # expect: 27 checks passed, 0 failed
```

The live harness needs a Chrome for Testing / Chromium build (branded Chrome refuses
`--load-extension`); it finds any Playwright/Puppeteer build in the usual caches, or set
`CHROME_PATH`. `ffprobe`/`ffmpeg` are optional but recommended — they are what verifies the
exported audio really contains sound.

Deliberate-failure variant (proves the alarm fires, not just that the happy path works):

```
RICHOS_FAKE_AUDIO_FILE=1 RICHOS_SILENCE_TEST=1 node tests/live-capture.mjs
# expect: 29 passed, including
#   "a silent capture device raises a RED digital-silence alarm during the call"
#   "the alarm was recorded in the durable alert log"
```

**What Part A already proves** (verified on macOS, Chrome for Testing 149, headless):

- the extension loads with no manifest error and the service worker boots clean;
- it logs no errors and throws no uncaught exceptions for a whole session;
- a real Meet URL is recognised by the real platform-detection code;
- `session.json` is on disk *before* any audio is;
- audio chunks are written continuously and are durable in IndexedDB;
- per-second health records carry real, non-zero levels from a live audio device;
- a service-worker restart re-attaches to the running recorder and audio keeps flowing;
- closing the call tab finalises the session, exports it, and self-verifies it;
- files land at `richos-capture/<session>/{session.json,audio-part-00.webm,health.ndjson}`
  and the directory recorded inside `session.json` matches the folder on disk;
- the exported file decodes as 2-channel Opus and measures −20 dB, i.e. it contains sound.

**What Part A cannot prove:** tab audio (needs the human invocation), real speech quality,
real device switching, and real browser/OS-level kills. That is Part B.

---

## Part B — a real call (the one that matters)

### B0. Install

1. `chrome://extensions/` → Developer mode → **Load unpacked** → `tools/richos-extension`
2. Pin the RichOS icon.
3. Popup → **Settings** → **Grant** microphone access (once).
4. Leave everything else at defaults.

Expected: badge is grey/empty. No notifications of any kind. Nothing visible in any web page.

### B1. Arm a real call

1. Open a Google Meet (or Zoom web / Teams web) call.
2. Watch the badge. Expect it to go **red `ARM`** within ~10 s with one desktop alert saying
   the call is not being recorded (this is Chrome's tab-audio grant, not a defect).
3. Press **Alt+Shift+L** (or click the RichOS icon) **while the call tab is focused**.
4. Expect: badge goes **green `REC`** within a couple of seconds.
5. Open the popup. Expect: platform name, elapsed time climbing, MB and chunk count climbing,
   all health pills green, and the save location.

**Critical check — you must still hear the meeting.** `chrome.tabCapture` mutes the captured
tab by default; the recorder routes it back to your speakers. If the other party goes silent
the moment you arm, stop and report it — that is a blocker.

Also confirm the other participants see and hear nothing unusual: no banner, no notification,
no bot joining. Ask one of them directly if you can.

### B2. Talk, and confirm both channels

Speak for ~15 s. Have the other side speak for ~15 s. In the popup, both level pills should be
green and the MB counter should keep climbing (roughly 0.7 MB per minute).

### B3. End the call

Close the tab (or leave the meeting and close it). Expect:

- badge returns to grey;
- popup shows the last call with "saved OK";
- `Downloads/richos-capture/<timestamp>--<platform>--<code>/` contains `session.json`,
  `audio-part-00.webm`, `health.ndjson`;
- open the `.webm` in VLC (or `ffplay`): **left channel = you, right channel = them**;
- `session.json` shows `"status": "closed"` and `"verification": {"ok": true, ...}`.

If `ffmpeg` is installed, the one-line proof it is not silent:

```
ffmpeg -i audio-part-00.webm -af volumedetect -f null -   # mean_volume should be > -60 dB
```

---

## Part B2 — failure drills (do these deliberately, in a test call with a colleague or a
second device)

Each drill has an expected *observable* result. If any drill produces silence from the
extension, that is a bug and the guarantee is not met.

| # | Drill | How | Expected |
|---|---|---|---|
| 1 | **Tab audio dies** | Drag the call tab out into its own window, or reload the call tab mid-call | Badge → red within ~7–15 s, alert "recording your microphone only" (or re-attach succeeds and it returns to green). Audio file keeps growing either way. |
| 2 | **Microphone dies** | Unplug/disconnect the mic (or switch Bluetooth headset off) mid-call | Badge → red within ~20 s, alert about the microphone; the other side keeps recording. Reconnect → recovery. |
| 3 | **Digital silence** | Mute the microphone at the OS level (not in the meeting app) | Red "digital silence on your microphone" within ~20 s. |
| 4 | **Service worker eviction** | `chrome://serviceworker-internals` → find RichOS → **Stop**. Or just wait; MV3 evicts routinely | Recording continues; badge stays green; chunk count keeps climbing. This is the routine case and must be invisible. |
| 5 | **Extension reload mid-call** | `chrome://extensions` → reload RichOS while recording | On reload: red alert "a recording was interrupted"; the audio recorded up to that moment appears in the drop zone. Re-arm to continue the call. |
| 6 | **Tab crash** | Open `chrome://crash` in the call tab? No — instead close the call tab abruptly | Session finalises and exports; last-call result visible in the popup. |
| 7 | **Browser killed** | Quit Chrome (or kill it from Task Manager / Activity Monitor) mid-call | On next launch: red alert about an interrupted recording, and the captured audio appears in the drop zone. Everything after the kill is gone — this is the documented ceiling. |
| 8 | **Never armed** | Join a call and deliberately do nothing | Red `ARM` badge + alert within ~10 s, repeating. You must not be able to sit through a whole call unaware. |
| 9 | **Drop-zone write blocked** | Point the drop folder at something invalid in Settings | Alert "cannot write to the drop zone"; capture continues in the browser. |
| 10 | **Disclosure banner** | Settings → turn on the participant disclosure, grant page access, join a call | A small banner appears in the meeting page (this is the ONLY thing ever injected). Turn it back off and confirm it is gone. |

After the drills, run the sync helper and confirm it refuses to quietly move the damaged
sessions:

```
node sync/richos-sync.mjs --to <somewhere> --dry-run
# expect: ANOMALIES listed for the interrupted sessions, exit code 2
```

---

## Part C — cross-platform confirmation (Windows / Linux)

The extension is the same folder; there is no per-OS build. Re-running this short list on a
second OS is enough to confirm parity:

1. `chrome://extensions` → Load unpacked → same folder. **Expect: no manifest errors.**
2. Grant microphone access from Settings.
3. Join a real call, arm with **Alt+Shift+L**, confirm green badge and that you still hear the
   meeting. (On Windows, check the shortcut is not taken by another app: `chrome://extensions/shortcuts`.)
4. End the call and confirm the session folder appears under your Downloads folder, with a
   directory name containing no `:` characters (Windows would reject them).
5. Play the `.webm` and confirm left = you, right = them.
6. Run drill #3 (mute the mic at the OS level) and confirm the red alarm.
7. Run drill #4 (stop the service worker) and confirm recording continues.
8. `node tests/run.js` — the pure harness runs anywhere node does.

Report per step: pass/fail, the badge behaviour you saw, and the contents of the session
folder.

---

## Reporting template

```
Environment: <OS + version> / Chrome <version> / extension <manifest version>
Part A:  tests/run.js <n> passed · live-capture <n> passed · silence test <n> passed
Part B:  platform used, arming behaviour, badge states seen, could I still hear the meeting?
Drills:  1..10 → pass/fail + what you observed
Files:   session dir listing, session.json status + verification, volumedetect result
Anything the other party noticed: <should be "nothing">
```
