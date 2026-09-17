# Echo cancellation on the CEO's own rig — what ERLE actually is, and what the confidence test did with it

Echo (Rust & Tauri desktop engineer). 2026-09-17, 16:20Z–18:05Z (17:20–19:05 local).
Machine: the CEO's Mac, macOS 24.6.0 (arm64). Worktree `/Users/alex/ab/richos-wt/echo-opus-selfvoice1`,
branch `cc/echo-opus-selfvoice1`, from richos main `8dca2ef7`.

Commissioned by the candidate-.4 fix brief, job 2: *"Why is ERLE 0 dB on this rig? … Measure it on
this Mac with audio on; paste the ERLE trace."*

---

## Audio discipline, declared first because it cost the CEO something

**Output volume was 60, input 44, alert 100, unmuted before anything ran, and it is 60/44/100
unmuted now.** It was never changed by me; every measurement was taken at his own setting.

**Seventeen live playbacks happened, and fifteen of them were one loop too many.** The CEO was at
his desk and asked why the same sentences were being repeated. He was right. The repetition was
measurement — the first two runs disagreed by 10 dB and repeating them is what found the real
defect — but a fixed acoustic path does not need to be measured live more than once.

| what ran | live playbacks | why |
|---|---|---|
| `aec_live --secs 40` | 2 | first look; the two disagreed by 10 dB |
| `aec_probe` | 2 | delay, echo-to-noise, coherence ceiling |
| `aec_live --secs 30` ×3 (shipped code) | 3 | the disagreement: is it the run or the rig? |
| `aec_live --secs 30` ×5 (first fix attempt) | 5 | measuring a fix that did not work |
| `aec_live --secs 30` ×5 (second attempt) | 5 | measuring a fix that also did not work |
| **`aec_capture --save`** | **1** | **one sentence; everything after this is offline** |

`examples/aec_capture.rs` exists because of that. It records the microphone and the playout
reference to a WAV pair **in exactly the coordinate system `EchoCanceller` uses**, and
`--replay` runs the whole analysis from the files with no device opened and no sound made. Every
iteration after 17:46Z was offline. The pair is committed as a test fixture, and
`tests/echo_path_replay.rs` puts the CEO's real echo path under `cargo test`.

---

## The short version

**Three findings, in the order they matter.**

1. **ERLE on this path is single-digit, and near zero on continuous speech.** Measured −0.5 to
   +0.7 dB steady-state across five live runs; 6.3 dB over the one recorded sentence. The brief's
   premise — "the canceller is not learning at all" — is close to right on the live figure and
   wrong about the cause: **the reference reaches the filter intact in every run** (2029–2280
   far-active blocks, **0** ring overruns, **0** underruns). This is the echo path, not the
   plumbing.

2. **The bigger one, and it is in the shipped candidate: the canceller declared itself CONFIDENT
   while removing nothing.** On 2 of 5 runs of the shipped build it reached confidence at 5.10 s
   and 5.12 s with a steady-state ERLE of +0.7 dB. Confidence retires the half-duplex taint rule
   **and** shortens the barge-in debounce from 5.008 s to 0.400 s. The same two runs measured **60
   and 62 near-end false positives** per ~1218 blocks and **3 occasions each, in thirty seconds,
   where Rich would have cut himself off mid-sentence** — the one regression the CEO's brief names
   in as many words: *"a regression here makes Rich interrupt himself mid-sentence, which is worse
   than the current cost."*

3. **`erle=0 dB` in the operator log was a reporting artifact on top of a real shortfall.** The
   value was packed as `(erle_db.max(0.0) as u32) << 1` — negatives clamped to zero, everything
   under 1.0 dB truncated to `0`. Ray read that as "not learning at all". It is now signed
   millidecibels.

**What is fixed, and what is a constraint.** Findings 2 and 3 are fixed in this crate and are
covered by tests. Finding 1 is a **constraint**: on Mac mini built-in speakers with an Elgato
Wave:3 across the room, this canceller — and, on the coherence evidence below, any linear
canceller — will not earn the short barge-in window. The 5.008 s debounce and the half-duplex rule
stay in force there, which is the design declining rather than the design failing.

---

## 1. The rig, as measured rather than as assumed

From the app's own boot line and from every example run:

```
in = microphone 96000 Hz / 1 ch      (Elgato Wave:3, across the desk)
out = Mac mini Speakers 48000 Hz / 2 ch
aec = PBFDAF 2048 taps (128 ms tail)
```

`examples/aec_probe`, run 2 (the click train):

```
-- 1. IS THERE AN ECHO TO CANCEL? --
  room noise floor, Rich silent : -67.9 dBFS
  microphone at the click peaks : -37.2 dBFS
  reference level sent          : -23.3 dBFS
  microphone during continuous playback: -40.2 dBFS
  echo-over-noise during that phase     : 27.7 dB
  ECHO-TO-NOISE RATIO           : 30.7 dB
  >>> There is a real echo, 30.7 dB above the noise. It is cancellable in principle.

-- 2. TRUE ROUND-TRIP DELAY (cross-correlation over 1.5 s of lag) --
  best lag        : 2 blocks = 32.0 ms
  correlation     : 0.959
```

So there is a loud, well-defined echo 32.0 ms away. Nothing here is marginal or absent.

## 2. What is linearly predictable about it — the ceiling

`examples/aec_probe`, run 1:

```
-- 2b. SAMPLE-RESOLUTION ALIGNMENT (needed for a valid coherence estimate) --
  coarse (envelope, block) : 512 samples = 32.0 ms
  fine   (waveform, sample): 510 samples = 31.88 ms
  waveform correlation at the fine lag: 0.265

-- 3. THE CEILING: HOW MUCH IS LINEARLY PREDICTABLE AT ALL? --
  coherence by band (1.0 = perfectly predictable, 0.0 = unrelated):
        0-500   Hz   coherence 0.312
      500-1000  Hz   coherence 0.651
     1000-2000  Hz   coherence 0.727
     2000-4000  Hz   coherence 0.782
     4000-8000  Hz   coherence 0.493
  >>> ceiling restricted to 300-3400 Hz (the speech band): 7.6 dB
  >>> BEST POSSIBLE ERLE FOR ANY LINEAR CANCELLER: 4.3 dB
      (188 Welch frames of 1024 samples used, 11 skipped as
       reference-silent; microphone aligned by 32.0 ms)

-- 3a. IS THE ANALYSIS WINDOW LONG ENOUGH? (ceiling vs FFT length) --
    nfft   512 (  32.0 ms window): ceiling   3.9 dB   [376 frames]
    nfft  1024 (  64.0 ms window): ceiling   4.3 dB   [188 frames]
    nfft  2048 ( 128.0 ms window): ceiling   4.7 dB   [94 frames]
    nfft  4096 ( 256.0 ms window): ceiling   4.9 dB   [47 frames]
    nfft  8192 ( 512.0 ms window): ceiling   5.1 dB   [24 frames]
    current filter tail: 128 ms (2048 taps)

-- 3b. DRIFT OR NONLINEARITY? (coherence inside 1-second windows) --
    second  0: ceiling 7.1 dB      second  3: ceiling 6.4 dB
    second  1: ceiling 7.2 dB      second  4: ceiling 6.1 dB
    second  2: ceiling 7.0 dB      second  5: ceiling 6.1 dB
  >>> PER-SECOND CEILING (mean): 6.6 dB

-- 4. WHAT THIS CANCELLER ACHIEVES ON THIS EXACT RECORDING --
  offline over the recorded pair: ERLE 1.0 dB
  canceller's own report        : ERLE 4.8 dB · delay 1 blk (16.0 ms, conf 0.12) · leak 0.00382
                                  rms (-48.4 dBFS) · far-end 550 blk · confident=false ·
                                  overrun 0 · underrun 0 · resets 0

-- 5. WHAT THIS MEANS FOR THE CANCELLER --
  search range   : 0..32 blocks = 0..512 ms (aec::MAX_DELAY_BLOCKS)
  filter tail    : 128 ms (aec::AEC_TAPS)
  >>> The delay is inside the search range and the tail covers it.
```

**The envelope of the echo is almost perfectly predictable (0.959–0.972); its waveform is not
(0.265).** The delay is well inside the filter's reach and the tail covers it, so nothing here is
a configuration mistake. The per-second ceiling (6.6 dB) exceeds the whole-recording ceiling
(4.3 dB), which by the probe's own reading means the two device clocks are sliding against each
other on top of a path that is substantially non-linear.

**One honest caveat on the "4.3 dB" figure, because it is the one most likely to be quoted.** It
is computed on a click-train recording with full-band weighting. The same canceller achieved
**6.3 dB** on a recorded *speech* sentence over the same path (§5). The ceiling is therefore
stimulus- and band-dependent and should be read as "single digits", not as a hard bound. What is
robust across every measurement here is the order of magnitude, and that is what decides the
design question.

## 3. ERLE, live, five runs of the shipped build

`examples/aec_live`, output volume 60, nobody in the room. Every figure is the example's own.

| run | length | steady-state ERLE | residual | leak estimate | ERL | confident | self-interrupts |
|---|---|---|---|---|---|---|---|
| A | 40 s | **−0.1 dB** | −36.6 dBFS | −38.7 dBFS | — | never | 0 |
| B | 40 s | **−0.5 dB** | −46.1 dBFS | −49.8 dBFS | 28.0 dB | never | 0 |
| C | 30 s | **−0.2 dB** | −38.9 dBFS | −42.6 dBFS | 23.7 dB | never | 0 |
| D | 30 s | **+0.7 dB** | −39.4 dBFS | −48.4 dBFS | 23.5 dB | **5.12 s** | **3** |
| E | 30 s | **+0.7 dB** | −39.5 dBFS | −46.1 dBFS | 23.6 dB | **5.10 s** | **3** |

Run B's plumbing section, which is the answer to "is the reference actually reaching the filter":

```
-- 6. THE PLUMBING: DID THE REFERENCE ACTUALLY REACH THE FILTER? --
  blocks where the aligned reference was ACTIVE : 2280
  reference ring overruns (samples)             : 0
  reference ring underruns (blocks)             : 0
  divergence resets                             : 1
  delay estimate confidence (0..1)              : 0.16
  >>> The reference arrived, intact and aligned, for every block above. Any
      shortfall in ERLE is a property of the echo PATH, not of the plumbing.
```

That section did not exist before this work; it was added precisely because "ERLE 0 dB" has two
explanations with opposite consequences and the report could not choose between them.

Run D's section 3 — the finding that matters:

```
-- 3. CONFIDENCE, AND FALSE POSITIVES (nobody in the room but Rich) --
  time to CONFIDENT: 5.12 s of open microphone
  near-end false positives after confidence: 60 of 1217 blocks
  >>> times Rich would have INTERRUPTED HIMSELF under the 0.400 s window: 3
```

## 4. Why a canceller removing nothing said it was confident

`confidence_condition` compared **`residual_typ_rms`**, a smoothed average, against
`CONFIDENT_LEAK_RMS` (0.0025 rms = −52.04 dBFS). Two properties of that average, both correct for
what the estimate is *for*, are fatal when it is asked to decide confidence on a path with no
cancellation:

- **it excludes blocks where the near-end detector suspects the CEO is talking.** Uncancelled echo
  *is* speech, so it trips that detector — and those are exactly the loud blocks the threshold is
  about. What survives into the average is the quiet ones.
- **it is frozen while Rich is silent**, and the hold was counted in wall-clock blocks, so a value
  that dipped under the threshold as a sentence trailed off kept satisfying the condition through
  the whole gap before the next one.

**Two attempted fixes failed, and that is how the mechanism was identified.** Each was measured on
five live 30 s runs before the next was written:

| variant | runs CONFIDENT | when |
|---|---|---|
| shipped (smoothed estimate, hold in wall clock) | **2 of 5** | ~5.1 s |
| + estimate updated only while the reference is active | **4 of 5** | ~5.1 s |
| + the hold counted only while the reference is active | **4 of 5** | 5.4–19.7 s |
| **the block's own residual, held over far-active blocks** | **0 of 5** (offline) | — |

Tightening *where* and *when* the estimate was sampled made it **worse**, which is what ruled out
sampling and ruled in the estimator itself.

**The fix is to measure the claim instead of estimating it.** `confident()` means: leftover echo is
incapable of reaching the threshold that decides a barge-in. That sentence is about what the
residual does block by block, so the condition is now `CONFIDENCE_HOLD_BLOCKS` consecutive
far-active blocks whose **own** residual is under `CONFIDENT_LEAK_RMS`. No smoothing, no
exclusions, nothing to skew.

**And it latches**, which is not laziness: the CEO's voice is in the residual, so without a latch
`confident()` goes false the instant he speaks — and `confident()` is what licenses the 0.400 s
window he is speaking to use. That was measured as a red test
(`a_four_hundred_millisecond_interruption_cuts_rich_off_and_becomes_a_turn`: *"0.400 s of the CEO
talking over Rich did not interrupt him"*). The latch asserts a property of the **echo path**,
which does not change because somebody started talking; `reset_filter` clears it when the path
really does change, and a ring overrun withdraws it immediately.

**Headphones are unaffected**, which is the case this must not break: the microphone never hears
Rich, every block's residual is the room noise floor (−67.9 dBFS here, 15.9 dB under the
threshold), and confidence still arrives after 2.000 s of far-active blocks.

## 5. The recorded fixture, and the A/B that settles it

One live capture at 17:46Z — one sentence, 9.54 s, at volume 60 — then offline forever:

```
$ ./target/release/examples/aec_capture --replay \
      crates/richos-voice/tests/fixtures/echo-path/ceo-rig-2026-09-17
=== replay: crates/richos-voice/tests/fixtures/echo-path/ceo-rig-2026-09-17 (9.54 s, no audio) ===

-- the path --
  blocks                        : 596 (447 with the reference active)
  room noise, reference silent  : -57.6 dBFS
  microphone, reference active  : -45.7 dBFS
  residual,   reference active  : -52.0 dBFS
  ERLE over those blocks        : 6.3 dB
  canceller's own ERLE          : 8.8 dB
  delay                         : 2 blk (32.0 ms, conf 0.76)
  reference overruns / underruns: 0 / 0

-- what the confidence test sees --
  threshold CONFIDENT_LEAK_RMS  : -52.0 dBFS
  reference-active blocks under it: 347 of 447 (77.6 %)
  longest consecutive run under it: 86 blocks (1.376 s)
  >>> never CONFIDENT — the 5.008 s debounce stays in force
  >>> the SHIPPED smoothed-estimate rule: CONFIDENT at block 338 (5.41 s)

-- could leftover echo cut Rich off by itself? --
  VAD absolute speech floor     : -46.0 dBFS
  longest run of reference-active blocks with the residual AT OR ABOVE it: 10 (0.160 s)
  longest run at or above CONFIDENT_LEAK_RMS                             : 50 (0.800 s)
  a 0.400 s barge-in needs 25 consecutive frames
  >>> No. Leftover echo never holds the threshold for a whole barge-in window.
```

**Both rules, one recording, no sound: the shipped rule declares confidence at 5.41 s, the measured
rule never does.** The residual sits at −52.0 dBFS — *exactly* at the threshold — and only 77.6 %
of far-active blocks are under it, with the longest qualifying stretch 86 blocks (1.376 s) against
the 125 (2.000 s) the hold demands. That is a canceller which is genuinely marginal on this path,
and "not confident" is the correct answer for it.

`tests/echo_path_replay.rs` pins both directions and runs on any machine:

```
running 2 tests
test the_canceller_does_not_claim_confidence_on_the_ceos_real_echo_path ... ok
test the_fixture_still_contains_the_defect_the_shipped_rule_had ... ok
```

The second is the positive control, and it is the one that matters over time: a fixture that
quietly stopped reproducing the defect would make the first pass forever for the wrong reason.

## 6. What this does NOT establish

- **It is one room, one pair of devices, one day, one volume.** Everything above is evidence about
  the CEO's Mac. It is not evidence about echo cancellation, and a green fixture is not a claim
  about anyone else's desk.
- **Headphones were not measured.** The reasoning above says confidence still arrives there and the
  arithmetic is simple, but no headphone run was taken on this machine today. What would settle it
  is one `aec_capture --save` with headphones plugged in, which is ten seconds of sound.
- **A real human talking over Rich was not measured.** `aec_live`'s phase 3 injects a known talker
  into the captured frames, which tests the detector against a real residual and is not a person.
  One sentence from the CEO over Rich's voice would settle it.
- **Whether a better canceller exists for this path is open, and the evidence says the answer is
  not a linear one.** `aec.rs`'s own header already names the route that is not taken — a
  magnitude-domain echo-presence detector, exploiting the 0.959 envelope correlation rather than
  the 0.265 waveform correlation — and names why it is not in the crate: an unexplained 64 %
  false-positive mode on a synthetic path. Nothing here changes that assessment.
- **The 96 kHz microphone was noticed and not chased.** Both legs decimate to 16 kHz through a box
  pre-filter (`wav::RateConverter`, `taps = round(in/out)`: 6 taps for the mic, 3 for the
  reference), which passes some out-of-band content to alias differently in each leg. That is a
  plausible contributor to the 0.265 waveform correlation and it is **unverified** — it was not
  measured and nothing here rests on it. What would settle it is replaying the fixture through a
  proper anti-alias decimation and re-measuring coherence, which needs no new recording.
