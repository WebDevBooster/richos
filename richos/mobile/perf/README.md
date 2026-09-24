# `mobile/perf/` — RichConnect speed and battery measurement

One command per platform that measures a given build and writes one machine-readable record:
build commit, device, route, and every number beside the method that produced it. It is step 1
of the perceived-speed PRD (private record, `richos-hq/docs/prds/2026-09-24-richconnect-perceived-speed-and-no-annoyance.md`,
§9), so that every later speed or battery claim is a measurement anyone can re-run, not an
estimate. Sage's review of that PRD (private record, `richos-hq/docs/research/2026-09-24-richconnect-perceived-speed-prd-review.md`,
§0, T5–T8) shaped it; where it departs from the PRD's letter, the reason is below.

The CEO's sentence is the acceptance criterion; this tool only supplies evidence toward it:
*"The goal for the RichConnect app is to ALWAYS feel absolutely extremely fast to the user … while
at the same time make sure that the app never creates any annoyances like that "power-intensive
app found" notification from the mobile OS or anything else the user might perceive as annoying."*

## Commands

```sh
# Android emulator: boot and install through randroid, then measure (one emulator, headless)
python3 <richos-hq>/scripts/with-android-firebase.py richos/mobile/native-android/bin/randroid emu prepare
richos/mobile/native-android/bin/randroid emu perf --out <file.json> [--expect-commit <sha>] [--theme dark] [--only cold,warm]
richos/mobile/native-android/bin/randroid emu delete

# an Android phone (named explicitly; the tool checks it is not an emulator)
python3 richos/mobile/perf/perf.py android --adb <adb> --serial <serial> --kind physical --stamp <apk>.stamp.json --out <file.json>

# iOS (WRITTEN, NOT YET RUN): a simulator by UDID (never "booted"), or an iPhone by UDID
richos/mobile/native-ios/bin/rios perf --simulator <UDID> --stamp <stamp.json> --out <file.json>
richos/mobile/native-ios/bin/rios perf --device <UDID> --stamp <stamp.json> --out <file.json>

python3 richos/mobile/perf/perf.py check <record.json>...   # a record's structural promises
python3 richos/mobile/perf/perf.py budgets                   # the PRD §7 targets it compares to
python3 richos/mobile/perf/perf.py merge <part.json>... --out <file.json>   # one record from boots split with --only
python3 richos/mobile/perf/perf.py stamp --artifact <apk|.app> --checkout <repo> --paths <p>...
```

Exit 0 a record was written; 1 a phase could not be measured (the record says which and why);
3 REFUSED before measuring anything. **Identity or refuse:** `randroid emu prepare|refresh` stamps
the APK it installs (commit, uncommitted changes under `richos/mobile/native-android`, SHA-256).
The measurement hashes the APK actually installed on the device and refuses unless it is the
stamped one; with `--expect-commit` it also refuses a build from another commit or from
uncommitted changes. An emulator is measured only through `randroid emu perf` (its recorded
serial and its device lease); `emu adb <args>` is the same passthrough for one-off QA reads.

**The emulator lease is 15 minutes** (`engine/scripts/lib/testdevices.py`: 900 s lifetime, 300 s
idle). The tool renews the idle lease as it works. **The Mac's CPU circuit breaker**
(`engine/scripts/lib/cpu_guard.py`) stops an emulator whose host process stays above 3 cores for
10 s, and back-to-back cold launches did exactly that on 2026-09-24 (qemu at 5.9–7.0 cores, three
runs stopped at the third launch, a fourth in the warm series at 5.7). So before every trial,
keystroke, delta, swipe and window, and after HOME before a timed resume, the tool waits until the
emulator's host process used under 1.5 cores for four consecutive one-second samples (two of the
breaker's 2-second samples; at most 30 s), and the record's `device.host.pacing` says how long it
waited.
A run that still loses its device writes its record with every later phase NOT RUN and why.
Split a run across boots with `--only` and join the parts with `perf.py merge`: it refuses parts
whose installed bytes differ, a part built from uncommitted changes, or a phase measured twice.

## Physical production runs

Use `--production --route managed` or `--production --route tailnet` on a paired release app.
The route label is an operator declaration; validate the actual route separately. Add
`--exercise-sends` only for a synthetic conversation where test messages are authorized.
Production typing refuses an occupied composer. No debug bridge or fixture is used.

Physical cold and warm timings use the system launch trace, the useful-content draw marker and
that frame's `DisplayPresentTime`. A monotonic-clock counter joins the OEM trace clock to the
frame clock without assuming they share an origin. Window-visibility frames are valid launch
frames even though steady-state deadline statistics exclude them. The frame buffer is reset
before each launch. Missing or ambiguous evidence rejects a trial; it is never replaced with
blank-shell timing. Raw traces and frame records, including failed launches, are saved beside
`--out` in `<file.json>.evidence`. Keep these outputs on the external SSD and private.

Physical background observation reads existing per-UID battery accounting without resetting
history, simulating unplugging or changing battery settings. Charging can pause accounting.
Unavailable counters stay unknown and cannot establish zero work or a battery-acceptance pass.
The emulator methods in the table below retain their separate instrumentation.

## What each number is

| Record key | Method | PRD §7 row |
|---|---|---|
| `coldLaunch` | `am force-stop`, `am start -W` (launch state must read `COLD`). **Useful content** is the platform's "Fully drawn" time, reported by `ReportDrawnWhen { state != null }` in `MainActivity`: the first frame drawn after the saved state is read. On Android that frame is the transcript at its newest row with the composer (the list is `reverseLayout`, launch rows are pre-seen so they draw at full opacity; the dump after the series checks both are on screen). `firstFrameMs` (TotalTime) is kept beside it, never used as the endpoint (Sage T5). Primary series with the scripted Mac **unreachable** (Sage T6); `coldLaunchLive` is a 3-launch spot check with it accepting. | Cold launch ≤ 1,000 ms p95 |
| `warmResume` | HOME, `--away` s, the launcher settles, launcher intent with `am start -W`: TotalTime of a start in the same process (PRD J2: process retained). Android's `HOT` (activity kept) and `WARM` (activity recreated) both count; each sample keeps its state, `hotStats` and `recreatedStats` split them, and the first recreation's reason is read from the event log (`wm_destroy_activity`). A new pid is a cold start and is rejected. | Warm resume ≤ 200 ms p95 |
| `tapToFeedback` | `input tap` on "Send message". Start: the app's own `deliverInputEvent … eventTimeNano` trace slice (atrace `input`). End: `FrameCompleted` of the frame whose `InputEventId` is that event (`gfxinfo framestats`). Both CLOCK_MONOTONIC, one clock. `settledMs`: to the last frame of the burst the tap started. Each trial checks the sent text is on screen. | Tap feedback ≤ 100 ms p95 |
| `activeFrames` | `input swipe` on the transcript; framestats per swipe (it keeps only 120 frames): frames with `FrameCompleted ≤ FrameDeadline`, frames ≥ 100 ms. | ≥ 99% on time, no stall ≥ 100 ms |
| `idleFrames` | `gfxinfo reset`, `--idle-seconds` untouched, "Total frames rendered" for MainActivity's window, on the conversation, the Settings sheet and (first run) the pairing screen. | Settled idle: 0 |
| `backgroundQuiet` | HOME; wakeups of every app thread during the settle window (cancellation) and after it (context switches, `/proc/<pid>/task/*/status`), CPU ticks, `batterystats` reset at the window's start and read at its end (checkin: wakeup alarms, wake locks, jobs, syncs, network bytes), then pending alarms, jobs, held wake locks and open sockets. `zeroWork` is true only when all are zero. | Background quiet: 0 |
| `typingCost` | One character per `input text` into the focused composer: `/proc/<pid>/io` write syscalls and bytes, ftrace `ext4/f2fs_sync_file_enter` for the app's thread group, frames; per keystroke. Needs root (an emulator's `google_apis` image grants it; the run puts adbd back). Sage asked for this: the step-3 persistence fix needs a before and after. | (step 3 evidence) |
| `streamCost` | A streamed reply fed as `receive` delta frames through the debug bridge; the same counts per delta. The bridge saves its own document per command, which is included; compare runs on the same path only. | (step 3 evidence) |

Every metric keeps its raw samples. `stats` gives p50 always, p95 from 20 samples and p99 from
100 (fewer cannot place them), with the reason when absent. A budget comparison is never a
verdict: `acceptance` is **NOT VERIFIED** unless the device is physical, the build is a release
configuration and there are at least the PRD §8 protocol's 100 launch trials, and even then it
reads "EVIDENCE ONLY (a reviewer decides)". On an emulator the Mac's CPU is sampled per phase,
because the emulator's timings depend on it.

## §7 budgets this cannot measure yet, and what would settle each

| Budget | Why not now | What settles it |
|---|---|---|
| Send to durable queued state ≤ 150 ms | Nothing marks the moment the outbox item is durable. | A `Trace` section around the outbox commit in the send path, read from the same atrace capture as the tap. |
| Received text to visible ≤ 100 ms | No mark when stream bytes reach the app (the bridge's broadcast has none). | A `Trace` section where `ConnectionOwner` hands a chunk to the store; then the first frame after it, as the tap does. |
| Energy, OS attribution, OEM warnings | An emulator has no battery or power model. | This command on a phone with `--kind physical` (PRD §8 names the OEM phone family that is mandatory), plus Settings > Battery and the OEM manager over the 30-minute and overnight windows. |
| Managed Connect and Tailscale routes | The debug build's scripted Mac has no network. | A paired lab Mac (native-android README), counting the phone's requests at the Mac and the Connect Worker while backgrounded (Sage T7). |
| Release-configuration timing | A debuggable, unminified build is slower than release. | A profileable release-configuration build signed for local install, reaching the conversation through a real pairing. |
| Production persistence cost | In a development world the core persists through the bridge's document, not `AppPorts`' `JsonFile`. `RichCore.commit` changes show here; `JsonFile` changes need a paired production core. | The same typing phase against a paired production core. |
| Every iOS number | Not run tonight; the iPhone app does not yet emit the launch marker. | The two signposts below, then `rios perf` on the simulator and the iPhone. |

## iOS: the marker the app must emit (Sage T5)

The iPhone app draws `Color.clear` until the saved state has loaded
(`native-ios/App/App/RichOSNativeApp.swift`, the `else` branch of `if let store`), so a first-frame
launch metric would pass a blank screen. `ios.py` reads two signposts that do not exist yet:

```swift
import os
private let perfLog = OSLog(subsystem: "dev.richos.connect", category: .pointsOfInterest)
os_signpost(.event, log: perfLog, name: "useful-content")     // once, first composer appearance after `store` is set
os_signpost(.event, log: perfLog, name: "foreground-useful")  // each return to .active, after the retained screen draws
```

`useful-content` goes in the conversation (or pairing) screen's first appearance of the composer
inside the `RootView(...)` branch, never at `store = loaded` in the `.task`. Both are release-safe
and add no polling or network. Everything `ios.py` parses is tested against documented output
shapes, not captured output; the record says `"ranOnHardware": false` until the first run.

## Tests

`richos/app/scripts/mobile-perf.test.sh`: the parsers against output captured from the API 34
emulator (`fixtures/android/`), the whole Android run against a scripted adb (including every
refusal), and the iOS parsers. No emulator, simulator, build or window.

## Production journeys and markers (24 September follow-up)

`--production` never invokes the development bridge or seeds fixture state. Pair the installed,
profileable Release build with an isolated test conversation first, then name its route and actual
network condition. The operator must set and record that condition; the tool does not disable Wi-Fi
or alter Tailscale. Use short runs on a daily phone and the PRD's separately scheduled overnight test.

```sh
python3 richos/mobile/perf/perf.py android --production --route managed --network-condition mac-unreachable \
  --adb /opt/homebrew/bin/adb --serial SERIAL --kind physical --stamp BUILD.stamp.json \
  --expect-commit COMMIT --only cold,warm,scroll --cold 100 --warm 100 --out PRIVATE_RECORD.json
```

`--exercise-sends` explicitly enables synthetic send and typing probes through the actual composer
for a prepared test conversation. An occupied composer is refused. Without that flag production
runs do not enter or send text. Real streamed replies are recorded with platform tracing; no fixture
injection pretends to test production networking. Route labels are operator declarations, not
independent proof that traffic took that route.

Both release apps now emit static performance events without content, identifiers or uploads:

| Event | Boundary |
|---|---|
| Android `richconnect:send-tapped` | Send reaches the application dispatcher, including queue wait. |
| `send-requested` | Android begins the journal transaction; iOS receives a send action. |
| `durable-queued` | Durable user-work save succeeds, before delivery. Failed saves emit no success event. |
| `text-received` | Android receives a parsed delta frame; iOS receives a reply-delta action. |
| `transcript-drawn` | Android's transcript root draws changed message state; iOS's useful root draws a changed transcript revision. |
| `foreground-useful` | The loaded root draws after returning to the foreground. |
| iOS `useful-content` | The loaded root first draws, rather than its blank loading branch. Android retains `reportFullyDrawn`. |

Android trace event names have the `richconnect:` prefix. iOS uses the `dev.richos.connect`
points-of-interest log. Capture these with Perfetto or Instruments and join draw markers to actual
frame presentation. A draw marker does not by itself establish that a particular offscreen message
was visible, that collection-view layout had settled or that every control was usable. Review the
visible viewport and a frame trace. This follow-up supplies production measurement hooks and
controls, not physical-device timing or energy certification. Earlier tables describe the original
pilot; statements there that markers were absent are superseded by this section.
