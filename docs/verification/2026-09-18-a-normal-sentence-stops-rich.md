# A normal sentence stops Rich — the barge-in gate was the wrong condition, and here are the decibels

**Echo (Rust & Tauri desktop engineer), 2026-09-18.**
Branch `cc/echo-opus-bargein1`, worktree `/Users/alex/ab/richos-wt/echo-opus-bargein1`.
Main at dispatch `9da3c7d5`; main moved four times during this work (`e1af0f99`, `b5368032`,
`ee59193a`, `426a22ce`) and all four were acknowledged durably as `impact: none` — engine and
documentation only, no file of mine moved.

## LIVE PLAYBACKS: 2

Both at **output volume 60**, read and never set — `osascript -e 'output volume of (get volume
settings)'` returned `60` before the first and `60` after the last. One playback each, no loop.
`pgrep -fl richos-tauri` returned nothing before either one (the candidate-.7 instance, pid
`98757`, had been closed), no app instance was launched, and `pgrep -fl aec_capture` returned
nothing afterwards. Every other measurement in this document is offline: `say -o <file>` writes a
WAV and does not touch the output device.

The second playback exists because the first one captured no near-end voice. That is recorded, not
smoothed over — see §2.

---

## The CEO's words, which are the acceptance criterion

> *"didn't work … no matter what I said, he couldn't hear me."*
> *"it all works re audio but not while Rich is talking."*
> *"he doesn't hear me interrupting him."*

**He was heard.** The recording taken at his desk that morning has him at **−18.1 dBFS** at the
microphone against Rich's echo at **−46.7 dBFS** on the same microphone: **28.6 dB** of separation,
five separate times, **4.880 s** of speech. Every word was discarded.

---

## 1. The cause is one condition, and it is not the debounce being too long

`crates/richos-voice/src/controller.rs`, before this work:

```rust
let interrupting = match near_end {
    Some(n) if confident => is_speech && n,   // <- this
    _ => is_speech,
};
```

`EchoCanceller::confident()` requires the tracked residual **6 dB under the VAD's speech floor**
(`CONFIDENT_LEAK_RMS` = 0.0025 rms = −52.04 dBFS against `absolute_floor` = 0.005 rms =
−46.02 dBFS). The measured magnitude-squared coherence of the CEO's echo path caps **any** linear
canceller at 4.3–5.5 dB (`docs/verification/2026-09-17-aec-erle-on-the-ceo-rig.md`), so on his rig
that condition is not reachable at the volume he uses. Every frame therefore took the `_` arm: a
bare VAD verdict, judged by `BARGE_IN_DEBOUNCE_FRAMES` consecutive frames.

```text
  313 x 256 / 16000 = 5.0080 s of UNBROKEN speech
```

Nobody produces that. Measured on his own recording, his longest unbroken run of VAD-speech frames
is **66 frames = 1.056 s**, and 66 < 313. The debounce was never a discrimination between two
voices — it is a continuity race that echo happens to lose, and he loses it too.

**The two conditions answer different questions, and that is the whole finding.**

| condition | asks | needs a converged filter? |
|---|---|---|
| `confident()` | is leftover echo too quiet to reach the VAD's threshold? | **yes** — and unreachably so here |
| the near-end verdict | is there more energy here than the canceller predicts for the reference level it can see? | **no** |

The near-end verdict is `e_rms > NEAR_END_MARGIN * predicted_echo && e_rms > speech_floor`, where
`predicted_echo = leak_gain * ref_env_level`. `leak_gain` is tracked by **minimum statistics**, so
`predicted_echo` is deliberately a LOW estimate, and it starts at its pessimistic initial `1.0`.
That is not incidental: it is why the playback-onset transient measured in §3 is rejected rather
than mistaken for a person.

**The rule did not need changing. The signal did.**

---

## 2. The first playback captured nothing, and proving that took a second recording

`ceo-rig-2026-09-18-nearend`, 08:42:18Z, 25.579 s. Of **1443** far-active frames the VAD called
**16** speech, and every substantial one sat at **1.568–1.744 s** — 68 ms after playback began at
1.500 s.

Raised at once as `esc-20260918T084515Z-0864acd4` (`--state proceeding`), because the CEO's time
was the thing at stake and guessing would have cost him a second session later rather than thirty
seconds then.

**It is the filter's convergence transient on Rich's own onset, not him, and the proof is a
comparison rather than an opinion.** The same window relative to playback start, in both
recordings of the same passage at the same volume:

```text
                               mic dBFS   ref dBFS   mic − ref
  recording 1, onset window      −42.2      −14.8      −27.4
  recording 2, onset window      −41.4      −14.8      −26.6      <- 0.8 dB apart
  recording 1, 1.0–3.0 s in      −47.2      −20.0      −27.2
  recording 2, 1.0–3.0 s in      −25.6      −20.0       −5.7      <- HIM, 21.5 dB of it
```

The onset is the same transient in both. His voice is in the second recording and starts within
1.0 s of playback, exactly as he was asked.

**The failed run is not wasted and is now load-bearing:** it is the only clean echo-only recording
at **volume 60**, the volume his failing test actually ran at. The 2026-09-17 pair was captured at
an unknown morning setting. The entire false-positive side of this decision rests on it.

The second run needed the cue protocol changed — he speaks the moment he hears Rich rather than
waiting for a relayed *"now"*. The relay was arriving late inside a 23.5 s window.

---

## 3. Where he speaks, by a stated criterion rather than by ear

Per 256-sample frame: microphone RMS minus the reference **peak-decay envelope** in dB, using the
same ×0.72-per-block decay the canceller itself uses, because echo follows the reference envelope
and not its instantaneous level. That ratio is a property of the acoustic path, so on a recording
with no near-end voice it is bounded. Over the 1441 far-active frames of recording 1:

```text
  p50 −26.9 dB   p90 −18.2 dB   p99 −8.3 dB   MAX −2.5 dB
```

205 frames of recording 2 exceed that **maximum**; bridged across gaps of up to 0.400 s so one
sentence is not split by its own inter-word pauses:

```text
   3.568 ..  5.472 s   1.904 s
   6.256 ..  7.360 s   1.104 s
  14.320 .. 15.152 s   0.832 s
  16.384 .. 16.672 s   0.288 s
  20.912 .. 21.664 s   0.752 s
  ------------------------------
  4.880 s in five intervals
```

**He was asked for ONE sentence and spoke five times.** That is what a person does when the thing
they are interrupting does not stop, and it is the same shape as the six discarded utterances in
the failing candidate's own log. No transcript of his words is kept.

**The criterion is conservative in one direction and that direction is named:** his quietest
speech — word onsets, trailing syllables, breath — falls below the baseline maximum and is
therefore NOT inside these intervals. **So the complement of this list is not a clean echo-only
set and is never used as one.** False positives are measured only on the two recordings that
contain no near-end voice at all. Full derivation in the committed sidecar
`ceo-rig-2026-09-18-nearend2-nearend.json`.

**THE RECORDING ITSELF IS NOT IN THIS REPOSITORY.** `ceo-rig-2026-09-18-nearend2-mic.wav` is his
voice, `richos` is public, so it is committed to the private `richos-hq` repository at
`fixtures/echo-path/` (793,132 bytes,
`sha256 786adf8073d0eee99b5a1d639abc5f459e2f6c1284188ab33d75ba8c1f93cfe3`). Every other file of the
family stays here, including its `-reference.wav` and both sidecars, and that none of them carries
his voice was measured rather than assumed. To reproduce anything in this document that uses his
recording, point `RICHOS_PRIVATE_FIXTURES` at that directory; without it the test that needs it
reports `ignored` with a reason naming the file and never `ok`. Why it moved and what was measured:
`2026-09-18-the-ceos-voice-moves-to-the-private-repository.md`. Everything else in this document —
every level, every interval, every score — is a number derived from the recording, and numbers are
not his words.

---

## 4. Every candidate, scored

Instrument: `crates/richos-voice/examples/bargein_score.rs`. Replays a committed
`{-mic,-reference}.wav` pair through the **shipped** `EchoCanceller`, the **shipped** `Vad` and the
**shipped** debounce arithmetic. No device, no sound.

```text
  cargo run -p richos-voice --release --example bargein_score -- --pair <fixture> [--sweep]
```

**S** = VAD speech on the residual. **B** = VAD speech AND the near-end verdict, same frame.

### 4.1 The floor echo sets — 14 clean echo-only conditions, nobody in the room

Two recordings × (as recorded + six settings of the volume knob). The knob is a scalar on the
microphone track only, derived at run time so the post-cancellation residual lands on a stated
level — which is exactly what turning the speakers up does to a recorded pair. The range
**straddles the −46.02 dBFS VAD floor** on purpose: below it Rich's residual cannot trip a speech
frame and above it it can, and a rule chosen on one side only is chosen against the easy case.

| recording | residual target | run S | run B | 25-window S | 25-window B |
|---|---|---|---|---|---|
| 2026-09-17 | as recorded | 0 | 0 | 0 | 0 |
| 2026-09-17 | −52.00 | 0 | 0 | 0 | 0 |
| 2026-09-17 | −49.50 | 1 | 0 | 1 | 0 |
| 2026-09-17 | −47.00 | 1 | 0 | 1 | 0 |
| 2026-09-17 | −45.25 | 2 | 0 | 2 | 0 |
| 2026-09-17 | −43.00 | 5 | 0 | 5 | 0 |
| 2026-09-17 | −41.00 | 5 | 0 | 5 | 0 |
| 2026-09-18-nearend | as recorded | 11 | 1 | 14 | 1 |
| 2026-09-18-nearend | −52.00 | 11 | 0 | 12 | 0 |
| 2026-09-18-nearend | −49.50 | 11 | 1 | 14 | 1 |
| 2026-09-18-nearend | −47.00 | 12 | 1 | 17 | 1 |
| 2026-09-18-nearend | −45.25 | 12 | **6** | 19 | **6** |
| 2026-09-18-nearend | −43.00 | 22 | 2 | 22 | 4 |
| 2026-09-18-nearend | −41.00 | **23** | 1 | **23** | 1 |
| **WORST ANYWHERE** | | **23** | **6** | **23** | **6** |

−45.25 dBFS is Ray's walk at output volume 85 (the running app printed −45.8 and −44.7 dBFS; this
is the mean). −41.00 is 4 dB above anything ever measured on this rig, because a rule that only
survives the loudest level ever recorded has no headroom.

### 4.2 The ceiling the CEO sets — his own voice

| | run S | run B | 25-window S | 25-window B |
|---|---|---|---|---|
| `ceo-rig-2026-09-18-nearend2`, his 4.880 s | 66 | **66** | 25 | **25** (saturated) |

### 4.3 The verdict

```text
  15 of 25 on signal B   echo worst 6 of 25   margin 15/6 = 2.50x   the CEO: 25 of 25
  15 of 25 on signal S   echo worst 23 of 25  FIRES ON RICH         one frame short of saturation
```

Threshold sweep on **B** over a 180-condition grid (six volumes × six near-end levels × four
positions in the answer × two fixtures, with the near-end voice superimposed per §53 path (a)):

| threshold on B | false positives | detections (of 150 above the echo's own level) |
|---|---|---|
| 7 | 0 | 126 |
| 9 | 0 | 124 |
| 11 | 0 | 121 |
| 13 | 0 | 119 |
| **15** | **0** | **117** |
| 19 | 0 | 117 |
| 25 | 0 | 116 |

Every threshold from 7 up scores zero false positives, and detections are flat from 13 to 25. **So
the margin above the measured floor of 6 was bought for nothing, and 15 of 25 was already the
constant in the crate.** The shipped rule needed no new number.

For comparison on signal **S**: 15 of 25 scores **96** false positives, 19 of 25 scores 72, 23 of
25 scores 24. Only 25 of 25 reaches zero, and a rule demanding 25 unbroken frames is the old
defect with a smaller number.

---

## 5. What shipped

`src/bargein.rs` — `set_aec_confident` → `set_near_end_gated`. `BargeInMode::Windowed` is in force
whenever a canceller exists; `BargeInMode::Consecutive` now covers exactly one case, **no canceller
at all**, and is unchanged there.

`src/controller.rs` — `self.monitor.set_near_end_gated(near_end.is_some())`, and:

```rust
let interrupting = match near_end {
    Some(n) => is_speech && n,   // a canceller is present
    None => is_speech,           // no canceller: nothing can tell the two voices apart
};
```

**Frame math, re-derived here rather than quoted:**

```text
   15 x 256 / 16000 = 0.2400 s of evidence
   25 x 256 / 16000 = 0.4000 s of window
  313 x 256 / 16000 = 5.0080 s   (no-canceller only, now)
  5.008 / 0.400     = 12.52x shorter
    7 x 256 / 16000 = 0.1120 s   (SPEECH_ONSET_FRAMES — what an utterance needs to be born)
```

### The lines that were quoting the old number

* **Boot line.** Was `barge-in=313 frames (5.008 s) until the canceller proves itself, then 25
  frames (0.400 s)`. *"Until"* named a wait that never ends on his hardware, so the 5.008 s figure
  was the permanent behavior dressed as a start-up condition. Now, with a canceller:
  `barge-in=15 of 25 frames (0.240 s of near-end speech inside 0.400 s), gated on the canceller's
  per-frame near-end verdict from the first frame`. With none: `barge-in=313 consecutive frames
  (5.008 s) — NO canceller, so a bare VAD verdict is all there is`. One flag, two lines, and the
  test drives both so the wording cannot be hard-coded.
* **Discard line.** Told him barge-in needed 5.008 s of talking over Rich. Now names the rule that
  would actually have rescued the audio: 15 of 25 frames. The confidence figures before the
  semicolon **stay**, because the TAINT rule still rests on `confident()` and a discard is the
  taint rule's decision — what changed is only what would have prevented it.
* **The CEO-facing notice is unchanged and needed no change.** *"While I was speaking, I couldn't
  tell your voice from my own — so if you said something just then, it didn't reach me and I
  haven't sent anything. I'm listening now."* No duration claim in it, still true on a tainted
  discard, and it simply fires less often now because a barge-in produces no discard.

---

## 6. The tests, both directions, each carrying the other's positive control

`crates/richos-voice/tests/barge_in_on_the_ceos_rig.rs`.

* **`richs_own_echo_never_interrupts_him_at_any_volume`** — all 14 echo-only conditions assert
  **0 barge-ins** and **0 admitted utterances** (the `c712ccd5` invariant: Rich's own voice must
  never become the CEO's message). *Positive control:* the same recording at the same volume with a
  −22.0 dBFS near-field voice summed into the microphone track DOES fire — `barge_ins: 1`. Without
  it the fourteen zeroes would prove nothing.
* **`the_ceos_own_voice_over_rich_interrupts_him_and_his_words_are_kept`** — his real recording
  through the full shipped pipeline. Barge-in at **3.744 s**, **0.176 s** after his marked speech
  opens, inside his first interval, `admitted: 1`. *Negative control, named in the doc:* the same
  passage at the same volume on the same rig 14 minutes earlier with nobody speaking fires nothing.
  One recording differs from the other by one thing — him — and so does the verdict.
* **`every_duration_in_this_file_is_the_frame_math`**.

### Two stale assertions corrected, both of which encoded the defect

* `self_voice_replay.rs::a_near_end_voice_over_richs_answer_starts_a_tainted_utterance_and_is_never_submitted`
  required `barge_ins == 0` and `admitted == 0` for a near-field voice over Rich. That was a
  faithful description of the behavior the CEO met. It now requires the barge-in AND the admission.
  **The assertions that actually hold the invariant are untouched and still pass:** Rich's own
  answer alone admits nothing, and audio at the ECHO's own level (−44.7 dBFS, Ray's
  `say`-through-the-speakers level) starts nothing and admits nothing.
* `controller.rs::the_diagnostics_line_carries_the_exact_frame_math` required the old wording. It
  now asserts the new line, asserts the ABSENCE of *"until the canceller proves itself"* and of
  `5.008`, and adds the no-canceller positive control.

The sweep in `self_voice_replay.rs::the_level_at_which_a_talker_over_rich_starts_an_utterance`
shows the change directly, before → after, in its `barge` column:

```text
  talker level        barge BEFORE   barge AFTER
  −52.0 … −36.0            0              0     <- at or near the echo's own level: correctly silent
  −35.0 … −12.0            0              1     <- a person; now stops Rich
```

Nothing fires at or below −36.0 dBFS, which is the region where a talker is indistinguishable from
the echo by level. That boundary is the design working, not a gap.

---

## 7. Three things I was wrong about, found by my own assertions failing

Recorded rather than quietly accommodated, because each one changes what a later reader should
believe.

1. **`confident()` is NOT unreachable on this hardware — it is unreachable at the volumes actually
   used.** The 2026-09-18 pair scaled DOWN to a −52.00 dBFS residual *does* become confident,
   because `CONFIDENT_LEAK_RMS` is −52.04 dBFS and the target sits a hair's breadth from it. So
   "unreachable on this hardware" is a property of the hardware **and the volume knob**. It changes
   nothing about safety — confidence only makes the TAINT rule more permissive and barge-in no
   longer consults it — so the test reports it at every volume and asserts the two things that
   matter regardless.
2. **A barge-in latency measured from the marked interval start can legitimately be SHORTER than
   the rule's own 0.240 s of evidence.** Measured: 0.176 s = 11 frames. Not a short circuit — the
   interval marker only claims frames above the echo-only baseline maximum, so it starts late and
   he was already speaking before it. A floor measured from a deliberately-late reference point is
   not a floor; the assertion pins the ceiling instead.
3. **Only ONE of his five sentences is admitted in replay**, with three tainted discards after the
   barge-in. That is a limit of replaying a recording, not of the fix: live, the first barge-in
   stops playout, `speaking` falls, the monitor disarms, and the rest arrive as ordinary utterances.
   A recording plays to the end and cannot stop. Asserting `== 1` would pin the artifact.

### A 7.5 dB disagreement between two instruments, reconciled — and nothing was stale

`self_voice_replay.rs::separating_the_ceo_from_richs_echo_by_level_needs_a_margin_this_large`
reports the 2026-09-17 echo at median **−48.6 dBFS** over 447 blocks, and
`docs/verification/2026-09-18-the-onset-defect-was-the-harness.md` quotes it. `bargein_score`
reported **−56.3 dBFS** over the same 447 blocks with the same canceller. Both were re-run here and
both reproduce. **Neither is wrong:** the test reads the fixture through
`mic_gain_for_the_walks_volume()`, which scales it up to model output volume 85, and `bargein_score`
replays it as recorded. No figure needed changing — but a reader comparing the two without knowing
that would conclude one instrument is broken, so `bargein_score` now prints both far-end selectors
side by side with the reason.

### A finding not asked for, recorded rather than hidden

**A near-end talker present from the first second of playback breaks the bulk-delay estimate.**
Recording 2 settled on 1 block (16.0 ms) at correlation confidence **0.02**; recording 1 — same
rig, same volume, same passage, 14 minutes earlier — settled on 2 blocks (32.0 ms) at confidence
**0.74**. The whole answer is then canceled against the wrong alignment: ERLE **5.4 dB** against
**8.8 dB**. The envelope cross-correlation the estimator runs on has no way to exclude near-end
energy. **Not fixed here and not in scope here.** It makes cancellation worse exactly when someone
is interrupting, which is the moment barge-in has to work — and barge-in survives it, because the
conjunction does not depend on a converged filter. That is the same property §1 rests on, now
tested by accident as well as on purpose.

### What none of this proves

One room, one pair of devices, one day, one output volume, one person. It proves what this path
does with this person's voice in it. It proves nothing about any other path, any other voice, or
echo cancellation in general — and the record already establishes why that matters here: every
synthetic rig in this crate models a path a linear filter CAN follow, and the CEO's is not one.

Barge-in itself has existed since 2026-08-29 (`bargein.rs`). What was missing was never the
monitor; it was the condition on the signal feeding it.

---

## 8. Commands and their output

```text
$ cargo test -p richos-voice --release
running 244 tests
test result: ok. 240 passed; 0 failed; 4 ignored; 0 measured; 0 filtered out; finished in 1.66s
     Running tests/barge_in_composition.rs
running 17 tests
test result: ok. 17 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.13s
     Running tests/barge_in_on_the_ceos_rig.rs
running 3 tests
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.65s
     Running tests/echo_path_replay.rs
running 2 tests
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.05s
     Running tests/model_provisioning.rs
running 23 tests
test result: ok. 23 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.03s
     Running tests/self_voice_replay.rs
running 18 tests
test result: ok. 18 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 5.77s
     Running tests/voiced_acceptance.rs
running 4 tests
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 20.00s
```

The 4 ignored are the device-opening tests, which report `ignored` unless
`RICHOS_VOICE_LIVE_AUDIO=1` is set — `build.rs` states that mechanism.

```text
$ cd src-tauri && cargo check
warning: `richos-tauri` (bin "richos-tauri") generated 4 warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 32.32s
```

The 4 warnings are pre-existing dead-code notices in `nav.rs` and nearby files; none is from this
change.

---

## 9. The on-screen proof, which is not mine to run

The CEO says one ordinary sentence over Rich on the next candidate, cued the same way, and Rich
stops. Everything above is evidence that it will; none of it is that.

One thing to carry into that walk: **the cue.** The first of my two playbacks failed because *"now"*
was relayed too late inside a 23.5 s window. The second worked because he was told to speak the
moment he hears Rich's voice, with no relay to wait for. Whoever runs the on-screen test should use
the second form.
