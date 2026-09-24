# RichConnect Android: first speed and battery baseline (emulator pilot), 2026-09-24

`record.json` is the baseline: one record, schema `richos-mobile-perf/1`, made by
`richos/mobile/perf/perf.py merge` from the four runs in `parts/`. Every number in it keeps its raw
samples and the method that produced it. `perf.py check` reads all five as sound.

**Verdict: NOT VERIFIED.** This is a pilot on an emulator, of a debuggable build, with 20 launch
trials. PRD §8 accepts only physical-device, release-configuration evidence with 100 trials per
launch class. These numbers show where time and work go on this build; they certify nothing.

## What was measured

- **Build:** the debug APK `1602b71dcf27…` (SHA-256 of the installed bytes, checked against the
  stamp `randroid emu prepare` wrote), built from committed sources at every part (`dirty: false`).
  It contains commit `d794518f`'s `ReportDrawnWhen` launch marker. The parts were stamped at tool
  commits `3065ac96`, `5782c54b` and `e85e17ab` (same APK bytes; `build.commits`).
- **Device:** Android 14 (API 34) `google_apis` arm64 emulator, Pixel 7 profile (1080 × 2400, 420
  dpi, 60 Hz), headless (`-no-window`, software GPU), on this Mac. Host CPU is sampled per phase
  in each part.
- **Route:** the debug build's scripted Mac (no network). The launch series ran with it
  unreachable (Sage T6); three spot-check launches ran with it accepting. 40 synthetic messages of
  history were seeded before each part.
- **Theme:** the emulator's own setting (light); the app follows the phone.

## The numbers

| Metric | Result | PRD §7 proposed budget |
|---|---|---|
| Cold launch to useful content ("Fully drawn") | n 20: min 923, p50 1,018, **p95 2,105**, max 2,594 ms | p95 ≤ 1,000 ms |
| Cold launch to first frame (kept, not the endpoint) | n 20: p50 586, p95 1,111 ms | — |
| Cold launch, scripted Mac accepting (spot check) | 871, 955, 965 ms | — (network must not delay it) |
| Warm resume, same process | n 20, **all 20 recreated the activity (`WARM`)**: min 169, p50 207, **p95 302**, max 339 ms | p95 ≤ 200 ms |
| Tap on Send to the frame that consumed it | n 10: min 44.8, p50 59.3, max 68.5 ms (10 samples place no p95) | p95 ≤ 100 ms |
| … to the send animation settling | n 10: p50 457.5, max 679.1 ms | — |
| Idle frames, 10 s untouched | conversation 0, Settings 0, pairing 0 | 0 |
| Scrolling (6 swipes) | 107 frames, 13.1% on time, 7 of 100 ms or more | ≥ 99% on time (the software GPU makes this number meaningless; see below) |
| Typing, per keystroke (18) | **1.0 fsync**, 597 write syscalls, 1.20 MB written, 20 KB reaching storage, 18.2 frames | (step 3 before/after) |
| Streamed reply, per delta (8, plus opening and final rows) | **2.5 fsyncs**, 390 write syscalls, 594 KB written, 44 KB to storage, 5.6 frames | (step 3 before/after) |
| Background, 60 s after a 5 s settle | 10 context switches (ART's Profile Saver 8, two Kotlin coroutine workers 1 each; one worker thread ended), 1 CPU tick; batterystats: 7 ms user and 4 ms system CPU, **0 network bytes, 0 wakeup alarms, 0 jobs, 0 wake locks, 0 syncs**; no pending alarms, scheduled jobs, held wake locks or open sockets | zero app-originated periodic work |

## Observations (what the data shows, not causes)

1. **The conversation appears about 0.43 s after the first frame on every cold launch** (p50
   first frame 586 ms, p50 useful content 1,018 ms). The first frame is the bare ground; the
   saved conversation and composer follow. Candidates to measure next: the saved-state read (in
   this debug build, the development world's document) and the first composition of 40 rows. This
   is PRD §9 step 3/4 territory.
2. **Every warm resume in the measured series recreated MainActivity in a retained process**
   (20 of 20 `WARM`, same pid). Earlier boots of the same APK bytes resumed `HOT`: 2 of 2 in the
   dry run, and the first 8 of 20 in an attempt whose other 12 the tool of that time rejected
   without logging their state. The system event log recorded no
   `wm_destroy_activity` for it in the first recreated trial. Cause unknown; J2 requires the
   reading position and draft to survive a recreation, so an Android engineer should look.
3. **Typing writes the whole session with a forced sync on every keystroke** in this build: one
   fsync and about 1.2 MB through write() per character with 40 messages of history, as Sage's
   review read from the source. A streamed reply costs 2.5 fsyncs per delta. These are the
   "before" numbers for step 3. They were taken through the development world's persistence
   (`RichCore.commit` into the bridge's document), not the production `JsonFile` port.
4. **Backgrounded, the app did no network, alarm, job, sync or wake-lock work in 60 s.** The 10
   context switches were the runtime's own housekeeping threads, not an app timer; the strict
   `zeroWork` rule still reads false, correctly. The 5 s after HOME (the cancellation) cost 113
   switches, most on the main and render threads.
5. **Idle screens render nothing:** 0 frames in 10 s on the conversation, Settings and pairing.

## What this cannot say

- **Frame smoothness:** the emulator renders on the host CPU (SwiftShader), so 13% on-time is the
  emulator, not the app. Only a physical phone answers the smoothness budget.
- **Energy and OS battery warnings:** an emulator has no battery model. The background numbers
  show work, not energy.
- **Real routes:** managed Connect and Tailscale need a paired Mac (Sage T7: count the phone's
  requests at the Mac and the Worker).
- **Release timing, send-to-queued, received-to-visible, iOS:** see `richos/mobile/perf/README.md`,
  "budgets this cannot measure yet".

## How the run went, and why it is four parts

The emulator lease is 15 minutes, and the Mac's CPU circuit breaker stops an emulator whose host
process stays above 3 cores for 10 s. Back-to-back launches, resumes, keystrokes and the
streaming mark's animation each tripped it (eight emulators stopped between 03:04 and 03:41 UTC at
3.98 to 9.01 cores, one during `emu prepare` itself; the engine's `cpu-guard/events.jsonl`). The tool now waits for four quiet seconds before each step, writes its
record even when the device goes, and splits across boots with `--only`; `perf.py merge` joins
parts only when the installed bytes are identical and no part was built from uncommitted changes.

| Part | Phases | Tool commit | Pacing wait |
|---|---|---|---|
| 1 | cold (20), cold-live (3), idle conversation, idle Settings | `3065ac96` | 47 s |
| 2 | warm (20), scroll, tap (10) | `5782c54b` | 256 s |
| 3 | typing | `5782c54b` | 142 s |
| 4 | streaming, background, idle pairing | `e85e17ab` | 33 s |

## Reproduce

```sh
python3 <richos-hq>/scripts/with-android-firebase.py richos/mobile/native-android/bin/randroid emu prepare
richos/mobile/native-android/bin/randroid emu perf --expect-commit <HEAD> --only seed,cold,cold-live,idle-conversation,idle-settings --out part1.json
#   … one boot per part, with the phases above …
richos/mobile/native-android/bin/randroid emu delete
python3 richos/mobile/perf/perf.py merge part1.json part2.json part3.json part4.json --out record.json
```
