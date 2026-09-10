# Every hardware choice in RichOS, and whether the app makes it or inherits it

**2026-09-10. The whole class, not the instance.**

The CEO asked: *"WHEN WILL THE CUSTOMER'S HARDWARE CHOICES STOP — PERMANENTLY STOP — BEING
HARDCODED INTO THE APP??? WHEN WILL THE APP START BEING INTELLIGENT AND PICK THINGS BASED ON THE
ACTUAL HARDWARE WHERE IT IS INSTALLED???"*

The instance he found — which whisper model runs — was fixed and landed the same day at `c1df6f24`
(`app/crates/richos-voice/src/hardware.rs`, `tools/richos-service/lib/hardware.js`,
`tools/richos-service/lib/model-costs.json`). **The word that governs this document is
PERMANENTLY**, so it is not about that instance. It is the enumeration of the class, and
[the check that refuses the next member](#part-2--the-check) is Part 2 below.

Every number below carries the command that produced it or the word `unverified:`. There is no
third setting.

---

## The method, and where it can be wrong

Two sweeps. **The first asks the opposite question from the obvious one** — not "where is a
hardware value hardcoded" (a grep for that finds only what you already suspected) but "where does
this codebase ask the machine anything at all". Everything a program decides about a machine it
never queried is decided by a constant, whether or not a constant is visible:

```sh
grep -rn 'sysctl\|vm_stat\|host_statistics\|os\.cpus\|os\.totalmem\|os\.freemem\|statfsSync\|\
available_parallelism\|num_cpus\|default_input_device\|default_output_device\|default_input_config\|\
default_output_config\|parse_backends\|parseBackends\|installed_voices\|system_profiler\|hw\.memsize\|\
process\.arch\|os\.platform' \
  app/crates/*/src tools/richos-service/lib tools/richos-service/bin app/ui app/src-tauri/src \
  --include=*.rs --include=*.js | grep -v node_modules | grep -v '/target/'
```

**32 hits, 31 real, in 8 files** (`richos-user-update/src/lib.rs:753` is a false positive — the
string `sysctl-read` inside a `sandbox-exec` profile). The result that matters is what is *absent*:

| tree | sites that ask the machine anything |
|---|---|
| `app/crates/richos-voice/src/` | 25 |
| `tools/richos-service/lib/` | 6 |
| **`app/crates/richos-core/src/`** | **0** |
| **`app/src-tauri/src/`** | **0** |
| **`app/ui/`** | **0** |

Every one of the 31 is in the voice/transcription stack, and 16 of those are `hardware.rs` — the
module written this morning. **The Tauri shell, which owns the window, the updater and the entire
desktop surface, has never asked the host a single question.** That is not an accusation of
sloppiness; most of what those trees do genuinely has no hardware axis. But it is why the
enumeration below reaches outside the audio stack, and it is the honest answer to "how do you know
you found them all": I do not, and the second sweep is what bounds the gap.

The second sweep is the inverse — every fixed value on a path that scales with work or with the
host: whisper/ffmpeg argv, thread and worker counts, buffer/chunk/batch/ring sizes, timeouts,
memory and disk budgets, window geometry, sample rates, device selection, GPU/Metal availability.

**Where this can still be wrong.** A hardware-dependent choice that is neither a named constant nor
a call into a system API — a magic number inline, or a decision expressed as control flow — is
outside both sweeps. That gap is precisely what Part 2 exists to close going forward, and it is why
Part 2 matters more than this list.

## Verdicts used

| verdict | means |
|---|---|
| **RESOLVED** | asked at run time, from the machine, already |
| **DEFECT** | fixed or absent, and demonstrably wrong on some machine the product will meet |
| **FIXED-CORRECT** | fixed, and that is right — the reason is stated, not assumed |
| **INHERITED-EXAMINED** | a third-party default, kept, because it was *measured* to be best |
| **LATENT** | correct on every live path today, held there by convention rather than by construction |

---

## Summary

| # | Site | Choice | Verdict |
|---|---|---|---|
| [D1](#d1) | `stt.rs:245`, `config.js:601` | whisper decode threads, `-t 4` | **DEFECT** — right with Metal, costs 19.2 % without |
| [D2](#d2) | `tauri.conf.json:14-15` | initial window 1400 × 880 | **DEFECT** — 320 pt wider than one of the CEO's own displays |
| [D3](#d3) | `journal.rs:96` | raw-audio budget, 2 GiB | **DEFECT** — never asks how much disk exists |
| [D4](#d4) | `aec.rs:172` | AEC delay search, 512 ms | **DEFECT** — sized for a wired desktop, fails silently past it |
| [D5](#d5) | `transcribe.js:165,239` | `DEFAULT_MODEL` fallback | **LATENT** — a live bypass of the resolver, held off by convention |
| [I1](#i1) | *(nowhere)* | whisper `--processors`, default 1 | **INHERITED-EXAMINED** — measured best, 25–35 % ahead |
| [I2](#i2) | *(nowhere)* | ffmpeg `-threads`, default auto | **INHERITED-EXAMINED** — the vendor default is itself hardware-derived |
| [I3](#i3) | `capture.rs:199`, `playout.rs:129` | cpal buffer size, device default | **INHERITED-EXAMINED** — and the actual value is recorded, not assumed |
| [F1](#f1) | `vad.rs:22` | `SAMPLE_RATE = 16_000` | **FIXED-CORRECT** — a format contract, not a hardware choice |
| [F2](#f2) | `stt.rs:74` | `FALLBACK_MODEL_ID` | **FIXED-CORRECT** — reached only under an explicit path override |
| [F3](#f3) | `main.js:4639-4640` | layout breakpoints 1180 / 820 | **FIXED-CORRECT** — keyed to the window, which is measured |
| [F4](#f4) | `spine.rs:155,158` | context window / watermark | **FIXED-CORRECT** — a model property, and already measured at run time |
| [R1–R8](#resolved) | 8 sites | model, devices, voice, disk, prefix | **RESOLVED** — already asks |

**Five defects. One is measured and costs 19.2 %. One is visible on the CEO's own desk today.**

---

## The defects

<a id="d1"></a>
### D1 — whisper decode threads: `-t 4`, in both decoders

**Where.** `app/crates/richos-voice/src/stt.rs:244-245` and
`tools/richos-service/lib/config.js:596,601`.

**What it is.** Both paths pin the decode thread count to 4. Both give the same reason:

> the decode is Metal-bound; 8 threads measured byte-identical at the same wall clock
> — `stt.rs:243`

That sentence contains two claims and only the first was measured. *"Threads past 4 buy nothing"*
is true **when the decode is Metal-bound**. *"The decode is Metal-bound"* is a property of the
machine it was measured on — an M4 with a working Metal backend — asserted as a property of the
decode.

**Two things make it sharper than an ordinary unexamined constant.**

First, `whisper-cli --help` reports its own default for `-t` as `[4]`. **The pinned value is the
vendor default, digit for digit**, sitting under a comment that says the pin exists *"so the value
is ours, not the vendor's idea of this machine"* (`config.js:562`). Passing a default explicitly is
worth doing — it cannot be flipped by a formula bump, which is exactly why `-fa` is passed — but it
does not turn the number into a decision, and the comment reads as though it does.

Second, **the signal that would decide it correctly is already read on every single run and thrown
away.** `app/crates/richos-voice/src/toolchain.rs:262 pub fn parse_backends(stderr: &str)` and
`tools/richos-service/lib/toolchain.js:206` both parse whisper-cli's own `load_backend:` startup
lines, which name each ggml compute backend the binary actually `dlopen`'d:

```
load_backend: loaded BLAS backend from /opt/homebrew/Cellar/ggml/0.17.0/libexec/libggml-blas.so
load_backend: loaded MTL  backend from /opt/homebrew/Cellar/ggml/0.17.0/libexec/libggml-metal.so
```

`MTL` present or absent is the whole question. The app already detects the GPU, records it in the
toolchain lock, and then picks threads as if it had not.

**What it should depend on.** Whether Metal is carrying the decode — and, when it is not, a
*measured* thread count for this machine, not a formula over its core count.

**What it costs.** Measured, five reps per cell, minimum reported, argv copied verbatim from
`decode_args(None)`, one 3.095 s utterance through `ggml-small.en.bin`. Full derivation:
`docs/measurements/hardware-choice-audit-2026-09-10/measurements/thread-sweep-derivation.md`.

| threads | Metal on | Metal off (`-ng`) |
|---|---|---|
| 1 | 0.538 s | 7.586 s |
| **4 (shipped)** | **0.503 s** | **2.842 s** |
| 8 | 0.510 s | **2.295 s** |
| 10 | 0.508 s | 4.762 s |

- **On a large machine — one with Metal, which is the CEO's:** nothing. `0.538 − 0.503 = 0.035 s`,
  a `0.035 / 0.503 = 6.96 %` span across *every* thread count from 1 to 10. The pin is correct here
  and this measurement confirms it. **His own Mac16,10 reports Metal 3 and 10 GPU cores, so D1
  costs him zero today.**
- **On a machine without a usable Metal backend:** `2.842 − 2.295 = 0.547 s`, i.e.
  `0.547 / 2.842 = 19.24 %` of every dictation, forever, paid for a GPU that is not there. The full
  span is `7.586 / 2.295 = 3.305x`.

**And the obvious fix is wrong, from the same capture.** `-t 10` — this machine's logical core
count, exactly what `std::thread::available_parallelism()` and `os.cpus().length` return here — is
`4.762 / 2.842 = 1.675x`, **67.5 % slower** than the shipped 4, with samples spread over 42.3 s
against 0.133 s at `-t 8`. The best value measured was 8: neither the P-core count (4) nor the
logical count (10).

So a resolver that read the core count and believed it would make this machine two-thirds slower
while looking precisely like what the CEO asked for. **The optimum is a measured property of the
machine, not a formula over its spec sheet** — which is the same conclusion `hardware.rs` reached
about model choice, and it points at the same mechanism already built and shipping: the speed cache
at `~/.config/richos/whisper-speed.json`, keyed by `cache_key(bin_sha, machine)`, which already
calibrates once per machine per binary and already keeps the minimum.

**Not fixed here, and that is a deliberate call.** The fix is a second axis on `hardware.rs`'s
calibration probe, and `hardware.rs` landed nine hours ago in the commit this task is the follow-up
to. Extending a calibrator on the same day it lands, on the strength of a proxy measurement (`-ng`
on a Metal machine) rather than a real Metal-less host, would be building on my own fresh work
without a second machine to check it against. What this document delivers instead is the
measurement that makes the fix specifiable and the check that stops a sixth one being added
quietly. **Naming it honestly: D1 is diagnosed and priced, not repaired.**

<a id="d2"></a>
### D2 — the window opens at a size chosen for a screen, without asking about the screen

**Where.** `app/src-tauri/tauri.conf.json:14-15`:

```json
"width": 1400,
"height": 880,
"minWidth": 1024,
"minHeight": 700,
"center": true
```

**What it is.** A fixed initial window size. `app/src-tauri/src/` contains **zero** calls that ask
the machine anything (see the method sweep above), and nothing reads monitor geometry before the
window is created.

**What it should depend on.** The work area of the display the window will open on — which Tauri
exposes directly (`Window::primary_monitor()` / `available_monitors()` → `MonitorHandle::size()`
and `scale_factor()`).

**What it costs — measured on the CEO's own machine, `system_profiler SPDisplaysDataType`:**

```
BenQ GC2870      1920 x 1080   Main Display    UI Looks like 1920 x 1080   (1x, not Retina)
HP E243          1080 x 1920   Rotation: 270   UI Looks like 1080 x 1920   (portrait)
VA2246 SERIES    1920 x 1080                   UI Looks like 1920 x 1080
```

His HP E243 is mounted in portrait and is **1080 points wide**. The hardcoded initial width is
1400:

```
  1400 − 1080 = 320 points off-screen
  1400 / 1080 = 1.296  ->  29.6 % wider than that display
```

`minWidth: 1024` lets it be *dragged* smaller; it does not affect the size it *opens* at. So on
one of the three screens on his desk today, RichOS opens with 320 points of itself past the edge.

- **On a large machine** (his 1920-wide main display, or any 24"+ external): nothing. 1400 × 880
  fits with room, and this is why the value has survived — it is correct on the display the
  developer had.
- **On a small machine:** `unverified:` I could not confirm the default scaled resolution of a
  13-inch MacBook Air from Apple's specifications (the web search tool was unavailable during this
  audit, and I will not put a remembered number in a document that is about not doing that). What
  *would* settle it is one line on any such machine —
  `system_profiler SPDisplaysDataType | grep 'UI Looks like'` — and if that reports a width below
  1400, the app opens off-screen on the most popular Mac Apple sells. **The structural finding does
  not depend on that number**: the app chooses a window size without asking how big the screen is,
  and there is already one screen on the CEO's own desk where the answer is wrong.

<a id="d3"></a>
### D3 — a 2 GiB disk budget on a machine whose disk was never measured

**Where.** `app/crates/richos-core/src/journal.rs:94-96`:

```rust
pub const RAW_RETENTION_DAYS: u64 = 14;
/// 2 GiB.
pub const RAW_MAX_TOTAL_BYTES: u64 = 2 * 1024 * 1024 * 1024;
```

**What it is.** The raw-payload retention window: 14 days or 2 GiB, whichever binds first. The
2 GiB is a fixed fraction of a disk nobody looked at. `richos-core` has zero sites that ask the
machine anything.

**Why it is a defect and not merely a default.** The same repository already does this correctly,
120 lines of unrelated code away: `tools/richos-service/lib/model-fetch.js:84` calls
`fs.statfsSync(dir)` and refuses a model download that would not fit
(`model-integrity.js:217 diskPreflight`). **One half of the product asks how much disk there is and
the other half does not**, and the half that does not is the one that writes continuously.

**What it should depend on.** Free space on the volume holding the journal, as a share rather than
an absolute — the same `statfs` call the fetch path already makes.

**What it costs.**
- **On a small machine** — a 256 GB MacBook Air with 20 GB free, having just downloaded
  `ggml-large-v3-turbo-q5_0.bin` (574,041,195 B, from `model-pins.json:131`) — 2 GiB of raw audio
  is 10 % of everything the user has left, taken silently and held for 14 days.
- **On a large machine** — a 4 TB Mac Studio — the cap throws away evidence the CEO could have
  kept, for no reason at all, and §7.2 of the design says the retention window is *his* question.

**Honest mitigation, stated:** this one is already a *value* rather than a `const` edit —
`RawRetention` is configurable and `journal.rs:100-115` explains at length that this was the point.
So it is a bad default rather than an unreachable one. It is still a hardware choice made without
looking at the hardware, and a non-technical CEO will never open that config.

<a id="d4"></a>
### D4 — the echo canceller searches half a second, because a desk was measured

**Where.** `app/crates/richos-voice/src/aec.rs:170-172`:

```rust
/// Longest bulk delay the estimator will look for.
/// 32 blocks x 256 / 16 000 = 0.512 s. A speaker-to-mic acoustic round trip on a desktop is
/// tens of milliseconds; half a second is generous headroom for a slow USB device.
pub const MAX_DELAY_BLOCKS: usize = 32;
```

Re-derived rather than trusted: `32 × 256 ÷ 16 000 = 0.512 s`. Correct.

**What it is.** The delay estimator correlates capture against reference over lags `0..32` blocks
(`aec.rs:754`). The comment's reasoning is about the **acoustic** round trip, which is indeed tens
of milliseconds. But the delay this filter has to find is not acoustic; it is
**output-device buffering + acoustic + input-device buffering**, because the reference is tapped in
the output callback (`playout.rs`), upstream of everything the device does with those samples.

**What it should depend on.** The output path actually in use. `playout.rs:158-160` already stores
`callback_frames` — *"The callback size IS the barge-in stop latency. Record what the device
actually used rather than what we hoped it would use"* — which is exactly the right instinct,
applied one constant to the left of where it is also needed.

**What it costs.** `unverified:` I did not measure a Bluetooth output path, and I am not going to
assert a headset's latency from memory in this document. The arithmetic that makes it worth
measuring: a wired path fits inside 512 ms with two orders of magnitude to spare, and an A2DP path
adds output buffering measured in hundreds of milliseconds on top of a *second* Bluetooth hop when
the microphone is on the same headset. What would settle it is
`cargo run -p richos-voice --example aec_probe` — which already exists, already prints
`coarse (envelope, block)` and `fine (waveform, sample)` lag in milliseconds, and needs only to be
run once with AirPods as the default output device.

**The part that is certain without any measurement, and is the real finding:** when the true delay
exceeds the search range, `aec.rs:754`'s loop simply returns the best correlation *within* range.
There is no saturation signal — no report, no widening, no degraded-mode notice. The filter aligns
to the wrong lag, cancellation collapses, and the observable symptom is Rich hearing himself
through the microphone and barging in on his own speech. **A fixed search range that fails silently
at its edge is worse than a shorter one that says so**, and the fix that does not require knowing
any headset's latency is to report when the winning lag lands at the boundary.

<a id="d5"></a>
### D5 — the hardware resolver has a bypass, held shut by convention

**Where.** `tools/richos-service/lib/transcribe.js:165` and `:239`:

```js
const modelId = opts.model || DEFAULT_MODEL;
```

**What it is.** `DEFAULT_MODEL` is `MODEL_TIERS[DEFAULT_TIER].model` — a constant, identical on
every machine. `resolveTierForHost` (the hardware resolver, `config.js:371`) is *not* consulted
here. A caller that omits `model` gets the hardcoded tier on any machine, including one the
resolver would have demoted.

**Live today?** No. Both callers pass it: `pipeline.js:110` resolves the tier and `pipeline.js:323`
forwards `{ model, extraArgs: decodeArgs }`. Verified by enumerating callers —
`grep -rn 'transcribeClips\|transcribeChannel' tools/richos-service/{lib,bin}` returns two call
sites and both pass `model`.

**Why it is still on the list.** The property "the resolver is never bypassed" currently holds
because two call sites happen to be written correctly, not because anything makes it hold. A third
caller written next month gets the constant, on every machine, silently — and the failure looks
exactly like working. `hardware.js` has been alive for nine hours and this door is already in the
wall behind it.

**Cost:** on a small machine, the whole of `c1df6f24`, undone by an omitted argument.

---

## The library defaults — examined, not inherited

The CEO's standing rule: *"NEVER use the default settings of ANY third-party tool/software for
ANYTHING. UNLESS the default settings have proven to be the best possible settings."* The brief was
right that this is the likeliest hiding place. These three are defaults, they are kept, and each
one now carries the reason it survived.

<a id="i1"></a>
### I1 — whisper `--processors`, default 1: **measured, and it wins**

`-p N` splits the input audio into N chunks decoded concurrently. **Of every flag this binary
accepts it is the one whose right value most obviously scales with the machine**, and nothing in
this repository has ever passed it — `grep -rn -- '--processors'` returns nothing, and the only
`"-p"` in the tree is `richos-user-update/src/lib.rs:756`, an unrelated `-p <profile>`. It has been
running at whisper-cli's own `[1]` on every machine forever: the exact shape of the `-mc -1` that
cost two weeks.

Measured on 61.906 s of audio through `ggml-large-v3-turbo-q5_0` (`DEFAULT_TIER`), three reps,
minimum, peak RSS from `/usr/bin/time -l`. Derivation:
`docs/measurements/hardware-choice-audit-2026-09-10/measurements/processors-sweep-derivation.md`.

| `-p` | wall clock | peak RSS |
|---|---|---|
| **1 (ships)** | **3.488 s** | **872,873,984 B** |
| 2 | 4.372 s | 1,029,455,872 B |
| 4 | 4.726 s | 1,334,525,952 B |

```
  4.372 / 3.488 = 1.2534           -p 2 is 25.3 % SLOWER
  4.726 / 3.488 = 1.3549           -p 4 is 35.5 % SLOWER
  1,334,525,952 / 872,873,984 = 1.5289   and holds 52.9 % more resident
```

Slower *and* hungrier, monotonically, for one reason: the decode is carried by **one** Metal
device, so N decoders contend for it instead of adding throughput while each carries its own working
state. Parallelism across a resource you have exactly one of is not parallelism.

**Verdict: `-p 1` stays, and it must NOT become hardware-resolved.** Raising it on a machine with
more cores would make that machine slower and hungrier — the exact failure the naive reading of
"pick things based on the actual hardware" produces. This is the entry the brief asked for: a
finding decided to be correctly fixed, stated with its reason rather than omitted.

Limit, stated: measured with Metal carrying the decode. The no-Metal case is served better by `-t`
(D1), which costs no per-processor memory, so `-p 1` holds there too — but for a different reason,
and only the Metal half is measured.

<a id="i2"></a>
### I2 — ffmpeg `-threads`, default auto: **the vendor default is the hardware-resolving one**

`tools/richos-service/lib/normalize.js:215,235,273,297` invoke ffmpeg without `-threads`. ffmpeg's
default is `auto`, which derives its thread count from the host at run time. **Here the vendor
default is the only option in the list that asks the machine**, and pinning it would replace a
hardware-resolved value with a constant — the defect this whole document is about, introduced in
the name of avoiding it.

Additionally these calls are `-c copy` concat, mono downmix, resample and `volumedetect`: I/O-bound
format work, not decode. Kept, deliberately, and now on the record as a decision.

<a id="i3"></a>
### I3 — cpal buffer size, `BufferSize::Default`: **the device's own answer, and it is recorded**

`capture.rs:199` and `playout.rs:129` both take `supported.config()`, which carries
`BufferSize::Default` — the device's preferred callback size. Forcing a fixed frame count on
CoreAudio is how you get glitching on the machines that do not like your number, and the *right*
buffer size is definitionally a property of the device.

What makes this examined rather than inherited is one line: `playout.rs:158-160` stores what the
device actually chose —

> The callback size IS the barge-in stop latency. Record what the device actually used rather than
> what we hoped it would use.

The value is the device's, and the app knows which value it got. Kept.

---

## Fixed, and correctly so

<a id="f1"></a>
**F1 — `vad.rs:22 SAMPLE_RATE = 16_000`.** Not a hardware choice at all: whisper.cpp accepts
16 kHz mono and nothing else, so this is a **format contract**. The hardware-dependent part of the
same path *is* resolved — `capture.rs:197,205` reads the device's real rate and runs a streaming
`RateConverter` into 16 kHz. Fixed on the right side of the seam.

<a id="f2"></a>
**F2 — `stt.rs:74 FALLBACK_MODEL_ID = "small.en"`.** Formerly the constant every machine got; now
reached only when `RICHOS_VOICE_WHISPER_MODEL`/`RICHOS_WHISPER_MODEL` pin the *weights by path*, in
which case a ladder walk would time the same file on every rung and report a resolution that
resolved nothing (`stt.rs:291-296`). The ordinary unmeasurable case goes to the registry's
`safeRung` and the CEO is told. Correct, and already documented as such.

<a id="f3"></a>
**F3 — `main.js:4639-4640 BREAK_WIDE = 1180`, `BREAK_NARROW = 820`; `RAIL_*`, `INSPECTOR_*`.**
Layout breakpoints in CSS pixels. A breakpoint is a design decision about layout *at a width*, and
the width is measured at run time from the window. Keyed to the right variable; nothing to resolve.
(The window's *initial* size is D2, which is a different question.)

<a id="f4"></a>
**F4 — `spine.rs:155 DEFAULT_CONTEXT_WINDOW_TOKENS = 200_000`, `:158 DEFAULT_WATERMARK_RATIO = 0.70`,
`:183 CONTEXT_CRITICAL_RATIO = 0.95`.** A context window is a property of the **model**, not of the
machine — a 24 GB Mac and a 128 GB Mac talk to the same remote model and get the same window. And
the constant is already only a fallback: `spine.rs:111` records that the measured value from the
live lease supersedes it, with the provenance tracked. Out of scope, correctly.

<a id="resolved"></a>
## Already resolved at run time — the eight that ask

Recorded because the enumeration is not honest without them, and because they are the shapes the
fixes above should copy.

| | Site | Asks |
|---|---|---|
| R1 | `hardware.rs::resolve_live` (`stt.rs:280+`) | live whisper model, from measured decode time on this host (`c1df6f24`) |
| R2 | `config.js:371 resolveTierForHost` | batch whisper tier, same registry, same speed cache |
| R3 | `capture.rs:193-199` | input device, its rate, channel count and sample format |
| R4 | `playout.rs:121-131` | output device, its rate, channels and format |
| R5 | `tts.rs:192 pick_voice` | probes `say -v '?'` and takes the best *installed* voice — Rich gets better with no code change the day a Premium voice is installed |
| R6 | `model-fetch.js:84` + `model-integrity.js:217` | free space via `statfsSync` before a ~574 MB download; refuses rather than fills the disk |
| R7 | `loro.rs:1349` | Homebrew prefix, arm64 then x86_64, by existence rather than by assumption |
| R8 | `toolchain.rs:262`, `toolchain.js:206` | which ggml compute backends the binary actually loaded — **read, recorded, and consumed by no decision (see D1)** |

---

## Part 2 — the check

Fixing this list changes nothing about next month. The check that refuses the next member of the
class — a hardware-dependent choice must either be resolved at run time or carry a declaration, at
the site, saying why a fixed value is correct — lands in the commit after this one, together with
the corpus it was measured against and its false-positive rate. This section is updated to name it
in that same commit, rather than pointing now at a file that does not yet exist.
