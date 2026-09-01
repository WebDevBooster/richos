# RichOS macOS companion — CEO real-capture test protocol (P2)

The one verification step that **cannot be done anywhere but a real Mac with a human at the
keyboard**: proving the Core Audio process tap actually records live system audio into the frozen
contract, and that every failure mode behaves per the never-silent guarantee.

The reason this is yours and not ours is narrow and worth stating, because it is the only reason:
**the "System Audio Recording" permission is a GUI grant, and macOS provides no API to request it
non-interactively and no API to query whether it is held.** Everything either side of that gate is
already proven on this Mac and is reproduced below with its real output, so you are not re-testing
our work — you are closing the one hole.

Expect **~25 minutes**. Nothing here goes to a network. No account, no cloud.

> **Where the recording goes.** By default the companion writes to
> `~/RichOS/corpus/ceo/unfiled/evidence/meetings` — your corpus, deliberately **outside** this
> repository, which ships publicly. Sections 1–4 below use a scratch zone instead, so nothing from
> this test lands in your real corpus. Both are outside the repo; the companion now **refuses** an
> in-repo zone rather than recording into one.

---

## 0. One-time setup

**0.1 — Toolchain.** Xcode command line tools give you Swift. Check:

```
swift --version
```

PASS: any `Apple Swift version 5.9` or newer.
FAIL: `xcode-select: note: no developer tools were found` → run `xcode-select --install`, then retry.

**0.2 — Build (Release).** From this directory:

```
cd tools/richos-service/companion-macos
swift build -c release
```

PASS: the last line is `Build complete!` and `.build/release/richos-companion` exists.
FAIL: any `error:` line — stop and send it; that is a code defect, not an environment one.

For brevity below:

```
rc=.build/release/richos-companion
```

**0.3 — Unit tests.** These need no permission and no audio hardware:

```
swift test
```

PASS: `Executed 36 tests, with 0 failures`.
*(VERIFIED 2026-08-29, macOS 15.6, Swift 6.1.2 — 36/36.)*

**0.4 — Environment report.**

```
$rc doctor
```

VERIFIED output on this Mac, 2026-08-29 — yours should differ only in paths and macOS version:

```
RichOS macOS capture companion 0.1.0-p2
macOS: 15.6.0
Core Audio process tap (>= 14.4): AVAILABLE
Product repo: /Users/…/richos
Drop zone: /Users/…/RichOS/corpus/ceo/unfiled/evidence/meetings
  source: corpus default
  (set RICHOS_DROP_ZONE, or LORO_CORPUS, to put sessions somewhere else)
  NOTE: does not exist yet — `capture` creates it on first run.
pipeline dep ffmpeg: /opt/homebrew/bin/ffmpeg
pipeline dep whisper-cli: /opt/homebrew/bin/whisper-cli
```

PASS: `AVAILABLE`, and both pipeline deps resolve to a path.
FAIL: `UNAVAILABLE — needs macOS 14.4+` → this protocol cannot run on that machine; stop and say so.
PARTIAL: `pipeline dep … : not found` → capture and the contract still work; only the transcript
steps (1.3, 3.5) are skipped. `brew install ffmpeg whisper-cpp` if you want them.

**0.5 — A scratch drop zone,** so this test cannot touch your real corpus. Use one terminal window
for the whole protocol and set it once:

```
export RICHOS_DROP_ZONE="$HOME/richos-companion-test"
```

Re-run `$rc doctor` and confirm `source: RICHOS_DROP_ZONE` and the new path. If it still says
`corpus default`, the variable did not reach the process — you are in a different window.

---

## 1. Headless contract proof — no permission needed

This proves the contract writer, the frozen L/R channel mapping, and the handoff to the
transcription pipeline **on your machine**, before any permission is involved. If this fails, stop:
the problem is not TCC.

**1.1 — Make two one-sided samples.** Any two mono 16-bit WAVs work; these are easy:

```
say -v Samantha -o /tmp/mic.aiff  "left channel me this is the microphone side of the recording"
say -v Daniel   -o /tmp/sys.aiff  "right channel them this is the system audio side of the recording"
ffmpeg -y -loglevel error -i /tmp/mic.aiff -ac 1 -ar 48000 -c:a pcm_s16le /tmp/mic.wav
ffmpeg -y -loglevel error -i /tmp/sys.aiff -ac 1 -ar 48000 -c:a pcm_s16le /tmp/system.wav
```

**1.2 — Push them through the real contract writer:**

```
$rc ingest --mic /tmp/mic.wav --system /tmp/system.wav
```

PASS looks exactly like this (the session id is a timestamp, so yours differs):

```
session (open) written: /Users/…/richos-companion-test/2026-08-29T16-40-18Z--system--call
session (closed) written: /Users/…/richos-companion-test/2026-08-29T16-40-18Z--system--call
run the P1 pipeline over it:  node ../bin/richos-service.js run "…"
```

The directory contains three files: `session.json`, `audio-part-00.wav`, `health.ndjson`.

FAIL: a `privacy invariant: refusing to write call recordings inside the RichOS product repo` line
and exit 1 → your `RICHOS_DROP_ZONE` points inside the checkout. Set it to something under `$HOME`.

Open `session.json` and confirm these five (VERIFIED values, 2026-08-29):

| Field | Expected |
|---|---|
| `schemaVersion` | `2` |
| `status` | `"closed"` |
| `capture.source` | `"desktop-companion-macos"` |
| `capture.method` | `"coreaudio-tap+mic"` |
| `capture.channels` | `left: "microphone (me)"`, `right: "system/tap (everyone else)"` |

and in `health.ndjson`, every row `"level":"green"`, `"tapRunning":true`, `"micRunning":true`,
`"bytesDelta"` non-zero, `"problems":[]`.

**1.3 — Transcribe it** (skip if 0.4 said a dep was missing):

```
node ../bin/richos-service.js run "$RICHOS_DROP_ZONE/<sessionId>"
```

PASS: the last line is `READY … -> …/transcript.md`, and that file reads — VERIFIED verbatim on this
Mac, 2026-08-29:

```
**[00:00] Me:** Left channel me this is the microphone side of the recording.

**[00:00] Them:** Right channel them this is the system audio side of the recording.
```

**`Me:` carries the mic line and `Them:` carries the system line. That is the whole contract**: left
is you, right is everyone else, no diarization model involved. If those two are swapped, stop and
report it — every downstream feature reads that mapping.

FAIL: `pipeline.status` stays `"pending"` and no `transcript.md` → paste the command's stderr.

---

## 2. The permission grant — and proving it was actually granted

This is the section the Windows half does not need and the reason this document exists.

### 2.1 What you are granting, and what it is called on your Mac

macOS 14.4+ has a **narrow** permission for capturing system audio without capturing the screen. On
macOS 15.6 the pane is **System Settings → Privacy & Security → System Audio Recording Only**
(*"Allow the applications below to access and record your system audio."*). It is a different pane
from **Screen & System Audio Recording**, which is the broad screen-recording permission. The
companion uses the narrow one and asks for nothing else besides **Microphone**.

*(The two pane names above were read out of this machine's own System Settings string table on
2026-08-29, not from memory.)*

### 2.2 Establish the "before" state — do this BEFORE you run capture

The whole point of this section is to be able to tell **granted** from **merely prompted**. That
needs a before and an after. macOS exposes no API for it, but the permission store is a SQLite file
you can read:

```
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, client_type, auth_value from access where service like '%AudioCapture%' or service like '%Microphone%';"
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, client_type, auth_value from access where service like '%AudioCapture%' or service like '%ScreenCapture%';"
```

VERIFIED on this Mac, 2026-08-29 — the "before" state, and it is the finding this whole item exists
for:

```
kTCCServiceMicrophone|com.apple.Terminal|0|2
kTCCServiceMicrophone|com.google.Chrome|0|2
…
```

and **not one `kTCCServiceAudioCapture` row in either database.** No application on this machine has
ever been granted — or even asked for — system-audio recording. That is exactly the gap.

Reading the columns:

- `auth_value` — **`2` = allowed**, `0` = denied. (Consistent with observed behavior here: every
  app that records audio on this Mac has `2`.)
- `client_type` — `0` = the client is a **bundle identifier**, `1` = an **absolute path**. Which one
  appears after you grant is load-bearing; see 2.5.
- **A missing row is not "denied". It means never asked** — and that is the state that makes
  "prompted" and "granted" indistinguishable without this query.

If either command errors instead of printing rows, your terminal lacks Full Disk Access. Either
grant it (System Settings → Privacy & Security → Full Disk Access → your terminal app) or fall back
to the GUI check in 2.4 alone, and say in your report that you did.

### 2.3 Trigger the prompt

```
$rc capture
```

Expected first two stderr lines:

```
•  session (open) written: /Users/…/richos-companion-test/<sessionId>
•  capturing system audio + mic. Press Ctrl-C to stop.
```

Two dialogs should appear — **Microphone** and **System Audio Recording**. Allow both. Then press
**Ctrl-C** immediately; this run exists only to raise the prompts.

> **UNKNOWN — this is the specific thing nobody has ever seen.** Whether both prompts actually
> appear, in what order, and **under whose name**, has never been observed. This binary is
> **ad-hoc/linker-signed with no Info.plist and no bundle identifier** (verified:
> `codesign -dv` reports `Signature=adhoc`, `Identifier=richos-companion`, `TeamIdentifier=not set`).
> A binary in that shape is normally attributed to the process macOS holds *responsible* — your
> terminal application — so the dialog is likely to say **"Terminal" wants to record system audio**
> rather than "richos-companion". **Likely is not verified.** Record what the dialog actually says
> verbatim; that single sentence is the answer to a question the project has been guessing at.
>
> It is also possible that **no dialog appears at all** and the call simply fails. Section 2.6
> covers that, and it is a legitimate outcome to report, not a mistake on your part.

### 2.4 Confirm in the GUI

**System Settings → Privacy & Security → System Audio Recording Only.**

PASS: an entry is listed **with its toggle ON**.
FAIL — and this is the distinction that matters: an entry listed with the toggle **OFF** means you
were prompted and it was *not* granted (or was granted and later revoked). An **empty pane** —
*"Applications that have requested access to record your app audio will appear here"* — means the
prompt never reached TCC at all, which is a different failure with a different cause. Say which one
you see.

macOS may also show *"'X' may not be able to record the audio from running applications until it is
quit."* If it does: **quit the application it names** (your terminal, if that is what it says) and
reopen it before section 3. A grant that needs a relaunch and does not get one looks exactly like a
grant that did not take.

### 2.5 Confirm in the store — the check that cannot be fooled

Re-run **both** queries from 2.2.

PASS: a `kTCCServiceAudioCapture` row now exists with `auth_value` **`2`**.
FAIL: `auth_value` `0` → denied. Toggle it on in the pane from 2.4 and re-check.
FAIL: still no row at all → the prompt never reached TCC. Go to 2.6.

**Then read the `client` and `client_type` of that row and write both down.** This decides something
open item 1.1 (Apple signing) has been arguing about with no data:

- `client_type 0` with a bundle id like `com.apple.Terminal` → the grant belongs to your **terminal
  app**. Rebuilding the companion does not disturb it, and any binary you run from that terminal
  inherits it.
- `client_type 1` with the **path** to `richos-companion` → the grant is pinned to this ad-hoc
  binary, whose code-directory hash **changes on every `swift build`**. Then every rebuild costs you
  the grant, which is precisely the dogfooding cost that makes Developer ID signing a v1 blocker.

Either answer is useful. We currently do not know which one it is.

### 2.6 If no prompt appeared and no row was created

Run capture again and watch stderr. There are exactly two shapes, and which one you see tells us
where the code is wrong:

**Shape A — it refuses to start.** The alarm text is fixed and will read:

```
‼️  RichOS companion ALARM: capture failed to start: AudioDeviceStart failed (OSStatus <n>). If this is the first run, grant "System Audio Recording" and Microphone in System Settings > Privacy & Security, then retry. The open session at … is the on-disk record that this call was NOT captured.
```

Send the **`<n>`**. *(UNKNOWN: nobody has seen this number. It is the OSStatus Core Audio returns
when starting a tap-bearing aggregate device without the grant, and it is the single most useful
byte in this whole document if the grant path is broken.)*

**Shape B — it starts and records silence on the right.** Capture runs, but the tap delivers no
frames. After 15 seconds you get:

```
‼️  RichOS companion ALARM: no audio has been written for 15s — the capture has stalled (tap stopped, device changed, or System Audio Recording permission was revoked). Session: …
```

(and a Notification Center banner). `health.ndjson` will show `"level":"red"` with the problem
string `system-audio tap stalled — silence-filling RIGHT (possible permission revocation)`.

Either way the session directory **exists on disk with `status:"open"`** — the never-silent
guarantee: a call that was not captured leaves a loud anomaly, never an absence. Confirm that it
does; that part is verifiable regardless of which shape you hit.

---

## 3. Live capture of a real call — the core test

Only attempt this once section 2 ends with `auth_value 2`.

1. Start a real **Zoom or Teams desktop** call — a test call with someone, or Zoom's test meeting at
   <https://zoom.us/test>, which plays audio you can talk over.
2. **Wear headphones for this run.** It proves the tap reads the render stream *before* the output
   device, so capture does not depend on sound coming out of the speakers. It also keeps the far
   side out of your microphone, which would make the L/R check meaningless.
3. Run:

   ```
   $rc capture
   ```

   PASS: `capturing system audio + mic. Press Ctrl-C to stop.`
   FAIL: `stand down: …` → a browser capture already owns this call. Re-run with `--force` if you
   want both, or close the extension's capture. (VERIFIED: with nothing else capturing, the
   coordination authority answers `"decision": "own", "reason": "no conflicting live capture"`.)

4. Talk for **60–90 seconds**, and make sure the other side talks too. Deliberately **take turns**
   rather than talking over each other — you need to be able to tell the channels apart by ear.
5. Press **Ctrl-C**. PASS:

   ```
   •  session (closed) written: … — the P1 watcher will now transcribe it.
   ```

**3.5 — Verify the capture.** In the session directory:

- `session.json` → `"status":"closed"`, `audio.bytesTotal` well above zero,
  `health.recordsWritten` ≈ the number of seconds you recorded, `health.worstLevel` `"green"`.
- `health.ndjson` → rows with `tapRunning:true`, `micRunning:true`, `bytesDelta` non-zero every
  second, and **`sysRms` above zero while the other person was speaking**. That number is the proof
  the tap actually received audio, as opposed to running happily and recording silence.
- **Open `audio-part-00.wav` in QuickTime, Audacity or Music, and listen with the balance hard left,
  then hard right.** **LEFT = your voice. RIGHT = the other participant.** This is the single most
  important check in this document, and it is the one no automated test can make.
- If the deps are installed, a `transcript.md` should appear on its own within a minute or so (the
  P1 watcher picks up closed sessions), or run
  `node ../bin/richos-service.js run "<dir>"`. Both sides should be attributed `Me:` / `Them:`.

FAIL, and what each means:

| What you see | What it means |
|---|---|
| RIGHT channel silent, LEFT fine | The tap ran but captured nothing — permission, or the tap is attached to the wrong device |
| LEFT silent, RIGHT fine | Microphone not granted or not running; `health.ndjson` will say `micRunning:false` |
| Both present but one lags the other progressively | Sample-rate drift between the mic and the tap. **UNKNOWN — never observed over a real call.** Note roughly how far apart they are by the end |
| Audio stops partway through, `bytesDelta` goes to 0 | The 15 s watchdog should have alarmed. Say whether it did |

> **UNKNOWN, stated rather than papered over:** no output of this section has ever been seen. The
> expectations above are read from the source and from the headless path, which exercises the same
> `SessionWriter`, `ChannelMixer` and `WavWriter`. What has never run is `CoreAudioCapture` — the
> tap, the aggregate device and the resampled microphone. Any deviation you find here is real signal,
> not you doing it wrong.

---

## 4. Failure modes — the never-silent guarantee

Each of these deliberately breaks something. Do them after section 3 succeeds; ~3 minutes each.

**4a — Microphone denied.** System Settings → Privacy & Security → **Microphone** → turn the
companion's entry (or your terminal's) **off**. Run `$rc capture`, play any audio for ~20 s, Ctrl-C.

PASS: the system side is still recorded on RIGHT; `health.ndjson` rows carry `"micRunning":false`,
`"level":"red"`, and a problem string about the microphone; LEFT is silent. **The far side of the
call is not lost.** Turn the permission back on afterwards.

**4b — No audio at all.** Run `$rc capture` with no call, nothing playing, and say nothing, for
~30 s. Ctrl-C.

PASS: after 15 s of no byte growth, the stderr **ALARM** about "no audio has been written for 15s"
plus a Notification Center banner; and the near-empty session is on disk with `session.json`
present. When the pipeline runs over it, it is flagged as an anomaly rather than silently dropped.

**4c — Crash mid-call.** Run `$rc capture`, record ~20 s of real audio, then **kill it hard** from a
second terminal — `pkill -9 richos-companion` — rather than Ctrl-C.

PASS: `session.json` is still `"status":"open"` (never finalized — a loud anomaly), **but
`audio-part-00.wav` is a valid, playable WAV** containing everything up to the last one-second flush.
Play it. Losing at most ~1 s is the guarantee; losing the file is a defect.

---

## 5. What to report back

For each of **1, 2, 3, 4a, 4b, 4c**: **pass / fail, plus one line.**

Four things are worth more than the pass/fail:

1. **The exact wording of the System Audio Recording dialog** (2.3) — and which application it named.
2. **The `client` and `client_type` of the `kTCCServiceAudioCapture` row** (2.5) — this settles
   whether a rebuild costs the grant.
3. **The `<n>` from `AudioDeviceStart failed (OSStatus <n>)`**, if you hit shape A (2.6).
4. **One screenshot**: `audio-part-00.wav` open in an audio editor, showing your voice on the LEFT
   track and the other participant on the RIGHT.

If anything deviates from "PASS", paste the stderr and the offending `session.json`. That is exactly
the signal that pinpoints a real-hardware defect no unit test can reach.

---

## 6. What this protocol does NOT cover

Named here so nobody reads a completed run as more than it is:

- **Process-scoped capture.** The Windows half can scope the tap to one application's PID; this one
  always captures **all** system output. That is deliberate (architecture §10-Q2, "all-output
  first") and means anything else making noise — a notification, music — lands on the RIGHT channel
  alongside the call. `CATapDescription` supports an exclusion list; nothing uses it yet.
- **Extension ↔ companion failover.** Section 3 exercises the `claim` handshake in the trivial case
  only (nothing else capturing). Promotion of a dead browser session to the companion is P4.
- **Long calls.** The longest thing the contract writer has ever handled is measured in seconds.
  Nothing here says what an hour looks like — clock drift, file size, or memory.
- **A signed build.** Everything above runs an ad-hoc binary. What changes under a Developer ID
  signature is the subject of open item 1.1, and section 2.5 is the measurement that informs it.
