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

# an Android phone (named explicitly; the tool checks it is not an emulator). A release build is seeded
# with the made-up conversation through its debuggable twin, which REPLACES the app's saved state on the phone
python3 richos/mobile/perf/perf.py android --production --route managed --adb <adb> --serial <serial> --kind physical \
  --stamp <apk>.stamp.json --seed-twin <debug.apk> --out <file.json>

# iOS: a named simulator or physical iPhone; trace series retain every raw trace (see "iOS launch and return").
# No iOS seeding path exists yet, so the condition is named explicitly and the record is never compared
richos/mobile/native-ios/bin/rios perf --simulator <UDID> --stamp <stamp.json> --conversation as-installed --mac unreachable --out <file.json>
richos/mobile/native-ios/bin/rios perf --device <UDID> --stamp <stamp.json> --conversation as-installed --mac reachable --evidence-dir /Volumes/E1TB/reports/<run> --cold 100 --out <file.json>
richos/mobile/native-ios/bin/rios perf --device <UDID> --stamp <stamp.json> --conversation as-installed --mac reachable --evidence-dir /Volumes/E1TB/reports/<run> --cold 0 --warm 100 --out <file.json>
richos/mobile/native-ios/bin/rios perf --reparse <series-dir> --out <file.json>   # re-read retained traces, capture nothing

python3 richos/mobile/perf/perf.py check <record.json>...   # a record's structural promises
python3 richos/mobile/perf/perf.py budgets                   # the PRD §7 targets it compares to
python3 richos/mobile/perf/perf.py merge <part.json>... --out <file.json>   # one record from boots split with --only
python3 richos/mobile/perf/perf.py stamp --artifact <apk|.app> --checkout <repo> --paths <p>...
python3 richos/mobile/perf/perf.py compare <record.json> [<warm.json>]      # p95 against benchmarks taken under the same condition
python3 richos/mobile/perf/perf.py benchmark-update <record.json>...      # the only way a benchmark changes; commit after
# either of the last two, for records measured before records named their condition:
#   --condition-declaration <declaration.json>   (see "Conditions"), written by:
python3 richos/mobile/perf/perf.py declare-condition <record.json>... --fixture <name> --rows <n> --mac <state> \
  --build <type> --seeded-by <how> --evidence <retained logs> --declared-by <name> --out <private declaration.json>
```

Exit 0 a record was written; 1 a phase could not be measured (the record says which and why);
3 REFUSED before measuring anything; 4 the record was written and is SLOWER than the established
benchmark (below). **Identity or refuse:** `randroid emu prepare|refresh` stamps
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
ASCII Send probes are prepared one character per Android `input text` invocation so a whole
burst does not share one key-event timestamp. Probe entry is outside the Send timing interval.
The composer must still match the intended string exactly before Send; a mismatch stops the
series with the draft retained. This automation path does not certify normal IME typing.

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

## Start times never get slower: the benchmark

The apps must stay fast: the cold launch and warm resume times already achieved are kept, and
faster is welcome. The benchmark file holds, per class (a device and a condition, below), the best
p95 measured so far for `coldLaunch` and `warmResume`, the record, build commit and date it came from,
and every repeated series of that class with its noise. The numbers were written by
`benchmark-update` from the records themselves, never typed. A class taken out of use moves to
`retired` with the reason and is never compared against.

**The file is private.** It holds numbers measured on the CEO's own phones, so it lives in the private
record repository, never in this one. `perf.py` finds it through `$RICHOS_MOBILE_PERF_BENCHMARKS`, else
the default `~/ab/richos-hq/docs/mobile-perf/benchmarks.json` on the Mac that runs the phones, and
`--benchmark FILE` overrides both. In a public clone the file is absent: every comparison is reported
NOT COMPARED with the reason "no private benchmark file", and `perf.py compare` exits 5. It never
passes silently. The tests here use only fixture benchmarks with made-up numbers.

### Conditions: only like-for-like records are compared

A launch time depends on what the app reads at launch as well as on its code. On 2026-10-02 phone
records that had been compared as a slowdown turned out to have been measured with different
conversations on the phone and a live Mac. Rebuilt and measured under one fixed condition, the
"slower" build equalled the "fast" one. A benchmark is
only worth keeping if two builds are measured the same way, so:

- **Every record names its condition** (`condition` in the record, `condition.py`): the conversation
  the app held (fixture name, row count and the SHA-256 of exactly what was seeded), whether the Mac
  was reachable, and the build type. `KEYS` in `condition.py` are the fields that must be equal.
- **`perf.py android` seeds a fixed, made-up conversation by default** (`--conversation fixture`):
  - Debug build with its development bridge: `devbridge-hello/1`, 40 rows by default, the scripted
    Mac unreachable (`--mac reachable` sets it accepting).
  - Any other build: `synthetic-conversation/1`, 100 rows by default, written into the app's own
    saved-state files (`files/core/session.json` and `history.json`) and read back by SHA-256.
    Its pairing names a host under `.invalid`, which never resolves, so the Mac is unreachable by
    construction. A debuggable build is written with `run-as`. A release build is seeded through its
    debuggable twin (`--seed-twin <debug.apk>`, same commit, same signing key). The tool
    uninstalls the app, installs the twin, writes the files, then installs the stamped release APK
    over it with the data kept. **That replaces the app's saved state on the phone.** A release build
    without `--seed-twin` is refused before anything on the device changes.

  The default sizes are the ones the established benchmarks were taken with. `--rows N` is a
  different condition. After the cold series the tool checks the seeded conversation's marker row is
  on screen. If it is not, the condition is marked unverified and the record is never compared.
- **`--conversation as-installed`** measures whatever the app holds. The record says so, and is never
  compared with anything. **`perf.py ios` has no seeding path yet:** a Release build takes no fixture
  argument and its saved state cannot be written from the Mac by this tool. So it refuses the default
  and needs `--conversation as-installed --mac reachable|unreachable`. Until an iOS seeding path exists,
  no iOS record is compared.
- **`perf.py compare` compares a record only with a class whose device matches and whose condition is
  equal on every key.** A device match under another condition, a record that names no condition, an
  as-installed record or an unverified one is NOT COMPARED with the reason "different conditions".
  It never passes and never fails across conditions (exit 5). Records of one build (an iOS cold
  series and its warm series), or parts joined by `merge`, must share one condition.
- **Records measured before records named their condition** get one only from a *condition
  declaration*: a private JSON file (`richos-mobile-perf-condition-declaration/1`) that states the
  condition, the evidence, who declared it and when. It names the exact record files it applies to by
  SHA-256. `--condition-declaration FILE` on `compare` and `benchmark-update` applies it. It never
  replaces a record's own condition, and it is refused when the record itself says otherwise (build
  type, Mac state, seeded rows). The benchmark entry names the declaration it relied on.

**The noise allowance** comes from the repeated series, not from a guess. For each series,
`benchmark.py` resamples its own samples 2,000 times (seeded), takes the p95 of each resample and
uses the spread of those p95s as the series' standard error (SE). Two runs of one build differ by
more than 1.96 x √2 x SE only about one time in forty in the slower direction. The class's allowance
is the median of its series' bounds, so one series with a long tail cannot widen it. The spread
*between* series of different builds is deliberately not used: it is the kind of change (a slowdown
across builds) this check exists to catch, so it cannot also be the allowance.

**Where it runs.** Every record `perf.py android`, `perf.py ios` (including `--reparse`) and
`perf.py merge` write is compared before it is written. That covers `rios perf`, `randroid emu perf`
and the physical Android command, which all run `perf.py`. The record gets a `benchmark` section
with every metric (FASTER, WITHIN NOISE, SLOWER or NOT COMPARED, with the reason). A slower build's
`acceptance` reads `REFUSED: slower than the established benchmark`, the command exits 4, and
`perf.py check` refuses a slower record that claims anything else. `perf.py compare` judges a retained
record, or an iOS cold series with its warm series from the same build: exit 0 nothing slower, 4 slower,
5 nothing could be compared. A metric is compared only if it has a p95 (20 trials or more) and the class
has a number for it; anything else is listed as NOT COMPARED with the reason, never as a pass.

**What still needs a phone.** The comparison only judges a record that exists, and a phone record
exists only when someone runs the series. On the Android phone that is
`perf.py android --production ... --kind physical --seed-twin <debug.apk> --only cold,warm --cold 100 --warm 100`.
No iPhone benchmark can exist until an iOS seeding path does (see "Conditions"). No commit
runs a phone. The fixture suite (`mobile-perf.test.sh`) runs on any change to this tool.

**Raising a number.** A faster series is reported as FASTER and changes nothing by itself.
`perf.py benchmark-update <record.json>...` raises a benchmark when the series is faster, adds every
series to the noise list and recomputes the allowance; the person then commits the private benchmark file in richos-hq.
A slower series replaces a benchmark only with `--allow-slower "<reason>"`, and the reason is written
beside the number. The
file holds no serial, UDID, sample or trace.

## §7 budgets this cannot measure yet, and what would settle each

| Budget | Why not now | What settles it |
|---|---|---|
| Send to durable queued state ≤ 150 ms | Nothing marks the moment the outbox item is durable. | A `Trace` section around the outbox commit in the send path, read from the same atrace capture as the tap. |
| Received text to visible ≤ 100 ms | No mark when stream bytes reach the app (the bridge's broadcast has none). | A `Trace` section where `ConnectionOwner` hands a chunk to the store; then the first frame after it, as the tap does. |
| Energy, OS attribution, OEM warnings | An emulator has no battery or power model. | This command on a phone with `--kind physical` (PRD §8 names the OEM phone family that is mandatory), plus Settings > Battery and the OEM manager over the 30-minute and overnight windows. |
| Managed Connect and Tailscale routes | The debug build's scripted Mac has no network. | A paired lab Mac (native-android README), counting the phone's requests at the Mac and the Connect Worker while backgrounded (Sage T7). |
| Release-configuration timing | A debuggable, unminified build is slower than release. | A profileable release-configuration build signed for local install, reaching the conversation through a real pairing. |
| Production persistence cost | In a development world the core persists through the bridge's document, not `AppPorts`' `JsonFile`. `RichCore.commit` changes show here; `JsonFile` changes need a paired production core. | The same typing phase against a paired production core. |
| iOS launch acceptance | The tool now measures the presented, input-ready endpoint (below), but no physical series has run. | The two 100-trial commands below on the phone, with a stamped Release build. |
| Return to a waiting reply on screen | `warmResume` ends when retained content accepts input; it does not wait for the reply already waiting on the Mac. Re-walk 4 (2026-10-01) saw 1.12-2.11 s on six returns and 17.11 s on one. | A `returnToReply` class: lab Mac with the reply held, send, Home, the reply finishes on the Mac, return; from `AppResume` to the presented frame of the first `transcript-drawn` after `text-received`, with a trial longer than the slowest return (30 s); a trial without the reply is kept as at least 30 s, never dropped. |

## iOS launch and return (PRD §7)

**What is measured.** Cold launch runs from the target process's `Initializing - Process Creation`
(Instruments App Launch) to the correct saved viewport presented with the composer accepting
input. Warm return runs from UIKit's own `AppResume` begin (`IsForeground 1`, emitted in the
retained process when the foreground transition reaches it) to the same kind of end. Both starts
are the earliest point visible in the app's process. Time the OS spends before that (the tap, a
process spawn request, thawing) is not included.

**The end mark, and why it is presentation and not a draw.** The app emits three static signposts
(`native-ios/App/Platform/PerformanceMarks.swift`, `ReadinessMarks`). `viewport-ready` fires once
the transcript applied its saved position after its first load: the bottom, or the remembered
reading anchor. `composer-ready` fires when the editable message field enters the hierarchy, and a
disabled composer has no field. `input-ready` fires from a single non-repeating run-loop observer
ordered after Core Animation's commit, so it marks the main thread going idle right after the turn
that committed that content. The tool then joins everything on one trace clock and one process ID:

1. The carrying commit is the first main-thread `com.apple.coreanimation` `Commit` to end at or
   after the latest ready-content mark. It must end no later than `input-ready`.
2. The presented frame is the first Frame Lifetimes frame whose server render began at or after
   that commit's end. A render that began earlier cannot contain the commit.
3. The presentation time is that frame's `display-surface-swap` timestamp. It must agree with the
   frame lifetime's end to 0.1 ms, and it cannot come before the render began.
4. The end is the later of presentation and `input-ready`.

Frame seeds are not used, because iOS 26.3.1 exports every seed as `4294967295`. On the first
physical capture, the old `useful-content` draw came one commit before the transcript's final
scroll position, which is why a draw is not the endpoint. The tool does not inspect pixels.
Whether the saved position is the right one is the positioning code's job and its tests' job.

**Keeping the tool honest.** A trial is rejected, and the series stops, when any of these happens:
- the capture fails;
- the process creation is missing or appears twice;
- marks come from another process;
- `input-ready` is missing (for example, a disabled composer) or appears twice;
- the order is wrong;
- no frame rendered after the commit;
- two frames began rendering at the same instant;
- Frame Lifetimes and the display swap disagree, or a swap precedes its own render;
- a warm trial's process changed. That was a relaunch, so it is a cold start.

Each table is exported alone, because a combined export carries the schema on its first table only,
and parsing by column name is refused without one. Xcode 26.3's trace loader crashes on roughly one
load in seven before reading any table (SIGSEGV or a Swift trap in `InstrumentsPlugIn`
`FileStatus`). An export is a pure re-read of a trace it does not modify, so a signal death is read
again, at most five times. Every attempt is recorded in `<trial>.exports.json`, and any other
export failure stops at once. Every trace is retained. The record lists trials above p95 as
`outliers` with their trace paths. `--reparse <series-dir>` re-exports and re-joins a retained
series without capturing anything.

**Simulator.** `--xctrace` on `--simulator` runs the same capture path as a dry run. Its lifecycle
table has no process creation and its frame records are not a display pipeline, so it proves the
capture, marks and join, never a phone number. Pass fixture arguments with `--app-arg=-rios-fixture
--app-arg=conv-populated`, using the `=` form so the value is not read as an option.

### A 100-trial series on the connected iPhone, per class

This needs a Release build signed for the phone, installed and stamped, and paired with an isolated
test conversation that already has history. The composer must be enabled. The phone stays unlocked
and awake on USB for the whole series. Each trial records for `--trace-seconds` (10 s), then exports
four tables. Each export took 1.7–2.4 s on this Mac, measured offline, plus an occasional re-read.
So a 100-trial class needs roughly 35 minutes, and the phone's own launch and transfer time is not
yet measured. Run from the repository root:

```sh
UDID=<the iPhone's UDID from xcrun devicectl list devices>
RUN=/Volumes/E1TB/reports/<date>-ios-launch-timing
RICHOS_IOS_DEVICE=$UDID RICHOS_APPLE_TEAM=<team> richos/mobile/native-ios/bin/rios device build   # prints {log, app}
APP=<the printed app: …/physical/derived/Build/Products/Release-iphoneos/RichOSNative.app>
mkdir -p "$RUN"
python3 richos/mobile/perf/perf.py stamp --artifact "$APP" --checkout "$PWD" --paths richos/mobile/native-ios > "$RUN/stamp.json"
xcrun devicectl device install app --device "$UDID" "$APP"
SHA=$(git rev-parse HEAD)

# one trial of each class first: proves the device, the tool and this phone's lists before a long series
richos/mobile/native-ios/bin/rios perf --device "$UDID" --stamp "$RUN/stamp.json" --expect-commit "$SHA" --conversation as-installed --mac reachable \
  --evidence-dir "$RUN/traces" --cold 1 --out "$RUN/pilot-cold.json"
richos/mobile/native-ios/bin/rios perf --device "$UDID" --stamp "$RUN/stamp.json" --expect-commit "$SHA" --conversation as-installed --mac reachable \
  --evidence-dir "$RUN/traces" --cold 0 --warm 1 --out "$RUN/pilot-warm.json"

# the series: cold launches, then warm returns
richos/mobile/native-ios/bin/rios perf --device "$UDID" --stamp "$RUN/stamp.json" --expect-commit "$SHA" --conversation as-installed --mac reachable \
  --evidence-dir "$RUN/traces" --cold 100 --out "$RUN/cold-100.json"
richos/mobile/native-ios/bin/rios perf --device "$UDID" --stamp "$RUN/stamp.json" --expect-commit "$SHA" --conversation as-installed --mac reachable \
  --evidence-dir "$RUN/traces" --cold 0 --warm 100 --away 2 --out "$RUN/warm-100.json"
```

**Output.** Each command writes one record and prints `record: <file>`. It exits 0 when every trial
was measured, 1 when the series stopped (`phases.cold` or `phases.warm` names the trial and the
reason) and 3 when it refused before measuring. The distribution is at `metrics.coldLaunch.stats`
or `metrics.warmResume.stats`: `n`, `min`, `p50`, `p95` (from 20 samples), `p99` (from 100) and
`max`, in milliseconds. `samplesMs` holds every sample. `budget` sets p95 beside the PRD target
(1,000 ms cold, 200 ms warm), never as a verdict. `phaseStatsMs` splits each sample into
`usefulDraw` (cold) or `foregroundDraw` (warm), `commitEnd`, `inputReady` and `presented`.
`outliers`, `rejected` and `evidence` name the retained traces. `acceptance` stays **NOT VERIFIED**
until both classes have at least 100 trials on a physical device with a Release build. Run as the two
commands above, each record lists the class it lacks ("no warm return distribution" in
`cold-100.json`, "no cold launch distribution" in `warm-100.json`). That is expected: the pair,
from one stamped build, is the protocol's evidence. The build
configuration is read from the stamped bundle's bytes, using `rios sim check-release`'s own
development markers. Even then the record says "EVIDENCE ONLY (a reviewer decides)". Keep `$RUN` on
the external SSD and private. Summaries go to `richos-hq`'s `docs/verification/`, never to this
repository.

What this path has not yet proven on a phone (the pilots settle each one, and the first failure
stops with the reason):
- the `devicectl device info processes` JSON field names (`result.runningProcesses`,
  `processIdentifier`, `executable`);
- whether `--notify-tracing-started` reaches the Mac during a device recording;
- whether UIKit emits `AppResume` on iOS 26.3.1 as it does on the iOS 26.3 Simulator.

Profiler overhead is included in every number.

## Tests

`richos/app/scripts/mobile-perf.test.sh`: the parsers against output captured from the API 34
emulator (`fixtures/android/`), the whole Android run against a scripted adb (including every
refusal), and on iOS the parsers, the presentation join and every rejection, the export re-read, the
warm-trial orchestration and `--reparse`, against synthetic exports shaped like Xcode 26.3's (the
physical traces they were checked against stay private in `richos-hq`). The benchmark cases (G1-G9)
use fixture records: slower is refused, equal or faster passes, a missing metric is not compared, and
the committed emulator numbers recompute exactly from the committed baseline. The condition cases
(C1-C7): the same condition and slower is refused; a different condition, none, as-installed or an
unverified seed is not compared, slower or faster; the seeded files are the 2026-10-02 fixture byte
for byte; twin and run-as seeding against a scripted adb (a release build without a twin is refused
untouched); declarations; benchmark files without conditions; iOS refusing the default. No emulator,
simulator, build or window.

## Production journeys and markers (24 September follow-up)

`--production` never invokes the development bridge. By default it seeds the made-up conversation
into the app's files (see "Conditions"; a release build through `--seed-twin`). To measure a paired
app with its real conversation instead, add `--conversation as-installed`, name the route and the
actual network condition. Such a record is never compared with a benchmark. The operator must set
and record that condition; the tool does not disable Wi-Fi or alter Tailscale. Use short runs on a
daily phone and the PRD's separately scheduled overnight test.

```sh
python3 richos/mobile/perf/perf.py android --production --route managed \
  --adb /opt/homebrew/bin/adb --serial SERIAL --kind physical --stamp BUILD.stamp.json --seed-twin DEBUG_TWIN.apk \
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
| iOS `viewport-ready` | The transcript applied its first load's saved position (bottom or remembered anchor). |
| iOS `composer-ready` | The editable message field entered the hierarchy (a disabled composer has none). |
| iOS `input-ready` | The main run loop committed the turn that made the viewport and composer ready (and, on return, the first draw after activation) and is about to wait for events. |

Android trace event names have the `richconnect:` prefix. iOS uses the `dev.richos.connect`
points-of-interest log. Capture these with Perfetto or Instruments and join draw markers to actual
frame presentation. A draw marker does not by itself establish that a particular offscreen message
was visible, that collection-view layout had settled or that every control was usable. Review the
visible viewport and a frame trace. This follow-up supplies production measurement hooks and
controls, not physical-device timing or energy certification. Earlier tables describe the original
pilot; statements there that markers were absent are superseded by this section.
