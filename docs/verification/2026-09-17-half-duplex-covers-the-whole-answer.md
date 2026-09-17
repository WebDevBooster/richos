# Half-duplex covers the whole of Rich's answer — the candidate-.5 blocker, fixed

**Date:** 2026-09-17
**Engineer:** Echo
**Branch:** `cc/echo-opus-selfvoice2`
**Base:** richos `main` at `e19d55c5` (Ray's candidate-.5 audit), then `eef1580b` (slice 3a)
merged in at `ff5c42c8` while this work was in flight — acknowledged via `inflight-ack.sh`,
impact `none`: slice 3a changed `richos-core`, `src-tauri`, `ui/` and docs, and `git diff
HEAD...main` showed zero files under `richos-voice`. The replay suite was re-run after the merge
(14 passed, 0 failed) and `ledger.rs`, which §7 cites by line, is untouched by it.
**Footprint:** `richos/app/crates/richos-voice/**` and this file. Nothing in `richos-core`,
`src-tauri` or `ui/` was touched — see §7 for the one boundary this work stops at.

**Live playbacks made by this work: ZERO.** Nothing on this Mac made a sound. The one test that
opens the real output device queues SILENCE and is used only to read the device's own latency
back; everything else runs on the committed WAV pair. The output volume was not touched, so
there was nothing to restore. The candidate-.5 app (pid `26884`) was left running and untouched,
as were `~/RichOS`, `~/.richos-signing` and the installed app.

---

## 1. What was wrong

From Ray's walk on the CEO's own rig — Mac mini Speakers out, Elgato Wave:3 in, output volume 85
(`docs/verification/2026-09-17-nightly-1.2.0-20260917.5-onscreen-audit-2.md` §2, Observation C):

```text
20:06:35.672  PromptReceived  source=jam  "Please count slowly out loud from 1 to 20."
20:06:35.679  TurnStarted
20:06:39.432  AssistantDelta  seq 2   "One"
20:06:40.179  AssistantDelta  seq 3   "... two... three... four... five"
20:06:40.680  TurnCompleted   end_turn        <- the MODEL turn ends; the SPEAKING does not
20:06:43.693  PromptReceived  source=jam  "1, 2, 3, 4, 5."     <- RICH, sent as the CEO
20:06:43.703  TurnStarted
20:06:50.525  AssistantDelta  seq 5   "Six... se"
20:06:51.621  TurnCompleted   end_turn
```

Rich's own counting, heard back through the Wave:3, recognized, submitted as the CEO's message,
and answered. A model turn spent, and words he never said sitting in a user bubble in his thread.

**Three independent holes, each sufficient on its own.** All three were read out of the source at
`aadb5b74`, and all three are closed.

| # | the hole | where it was |
|---|---|---|
| 1 | `speaking` was `playout.is_playing()`, i.e. `queued_samples() > 0` — false before an answer's first sample, false in every gap between spoken sentences, false while the device still holds the last one | `controller.rs` supervisor step 2 |
| 2 | taint was decided ONCE, on the `Started` frame; an utterance born untainted stayed untainted however much of Rich landed in it afterwards | `controller.rs:389` |
| 3 | the recording reaches **0.416 s further back** than that frame, and whisper transcribes the whole buffer | `endpoint.rs` pre-roll |

**Hole 1, in detail, because it is the one the walk's own answer created.** Sentences are
synthesized one at a time on the speaker thread, `MacSay` spawning `say` per sentence.
`chunk.rs:126-129` consumes a RUN of `.`/`!`/`?` as one terminator, so *"One... two... three..."*
chunks into roughly twenty one-word sentences and therefore twenty separate spawns. Whenever
synthesis of sentence N+1 outlasts playback of sentence N, the queue empties and the flag went
false mid-answer. `SILENCE_HANGOVER_FRAMES` is 50 frames — 50 × 256 ÷ 16000 = **0.800 s** — so an
utterance born in such a gap survives the following gaps easily and is admitted whole.

**Hole 3's arithmetic, re-derived rather than quoted.** `PRE_ROLL_FRAMES` = 19 and
`SPEECH_ONSET_FRAMES` = 7, so the WAV begins 19 + 7 = 26 frames before `Started` fires:
26 × 256 ÷ 16000 = **0.416 s**.

**What the record could NOT settle, and no longer has to.** Ray states it plainly: `app.log`
carried no timestamps, no playout boundaries and no per-utterance taint flag, so *"began in a gap
between spoken sentences"* and *"began after playout had been marked ended"* are indistinguishable
from the evidence. The fix makes the question stop deciding anything — every candidate birthplace
is now inside the window — and §5 makes the next walk able to answer it from the log anyway.

---

## 2. The invariant now in force

> Nothing captured during the whole of Rich's answer — every chunk, every gap between spoken
> sentences, and the device-latency tail after the last sample is queued — is submitted as the
> CEO's prompt while the canceller cannot vouch.

Barge-in is untouched: a barge-in still clears the taint outright, and a confident canceller still
admits the utterance. Both are pinned by tests (§4).

### The audible window

`AudibleWindow` (`controller.rs`) is **queued OR owed OR within the measured hold**.

- **owed** is `Shared::pending_speech`, the count of sentences between the speaker channel and the
  playout queue. It is incremented at the SEND, not at the synthesis, so the window opens before
  any sound exists — which also means the supervisor's 25 ms `TICK` cannot be beaten by it. A
  `PendingSpeech` `Drop` guard does the decrement, covering all four exits from the speaker
  loop's body plus unwind; an `else` branch would not, and a stuck counter would be a microphone
  that never listens again.
- **hold** is `audible_hold_secs(out_tail, in_latency)`.

### The hold, measured on the CEO's rig

Every term is a reading off a running device. Nothing is a constant someone chose.

```text
  output device tail    Playout::audible_tail_secs()    10.7 ms   MEASURED
+ input device latency  Capture::input_latency_secs()   (per device, read live)
+ one VAD frame         256 / 16000                     16.000 ms
--------------------------------------------------------------------
  floored at one TICK                                   25 ms
```

The output figure comes from cpal's `OutputStreamTimestamp`: `playback − callback` is when the
samples written now reach the DAC. On the macOS host that is the device's buffer over its rate
(`cpal-0.17.3/src/host/coreaudio/macos/device.rs:898-908`). Read off this machine, with no sound
made:

```text
[measured] device=10.7 ms callback=10.7 ms -> audible tail 10.7 ms on Mac mini Speakers
```

Re-derived: **512 frames ÷ 48 000 Hz = 10.667 ms**, which is exactly what both terms are.

The input term is the mirror: `callback − capture` from `InputCallbackInfo`, i.e. how far in the
past the audio being judged actually happened — the capture callback reads `speaking` at
PROCESSING time, so a frame delivered just after Rich's last speaker sample still contains him.

**The floor is not padding.** The hold is evaluated once per 25 ms tick; a hold shorter than the
interval at which it is sampled cannot be enforced, and claiming otherwise would be a timing
assertion the code cannot keep. On the CEO's rig the measured sum is 10.7 + ~10.7 + 16.0 ≈ 37.4 ms,
which is over the floor, so the floor does not bind here — it binds on a device that reports
nothing yet.

### The taint rule

```rust
let echo_is_in_the_recording = speaking || self.quiet_frames < ECHO_LOOKBACK_FRAMES;
self.tainted = echo_is_in_the_recording && !self.barged && !confident;
```

plus, on every frame the utterance is alive:

```rust
} else if recording && !self.tainted && speaking && !self.barged && !confident {
    self.tainted = true;
}
```

`ECHO_LOOKBACK_FRAMES` = `PRE_ROLL_FRAMES + SPEECH_ONSET_FRAMES` = 26 = **0.416 s**, derived from
the two constants rather than typed.

**The cost to the CEO, stated because it is real:** he has to leave about 0.42 s of air after Rich
stops before a reply is admitted. `the_look_back_is_the_0_416_s_the_recorder_actually_reaches_back_through`
pins that number so it cannot drift upward the next time somebody widens the window "to be safe".

---

## 3. A finding the brief's premise did not have

**The committed echo-path fixture, replayed at the level it was recorded at, CANNOT birth this
defect.**

Its microphone track sits at −40 to −51 dBFS and the canceller takes another 6.3 dB off it over
the far-active blocks (`tests/echo_path_replay.rs`). The VAD's speech test is
`rms > max(noise_floor × 3.0, absolute_floor)` with `absolute_floor` = 0.005 = **−46.02 dBFS**
(`vad.rs:86-91`, `vad.rs:139`). The residual lands UNDER that floor, so Rich's own voice produces
**zero** speech frames. Driven unscaled, the scenes simply end when the question does and nothing
happens at all — the first version of the replay passed for exactly that wrong reason, and the
probe that caught it counted 0 of 596 frames above the threshold.

The live walk plainly did hear him: the app printed two tainted discards during it, at residual
**−45.8 dBFS** and **−44.7 dBFS**, which is ABOVE the floor. The walk ran at output volume 85; the
fixture was recorded at some other setting, and the two are not the same level.

So the mic track is scaled to put its post-cancellation residual where the running app measured
its own, and the factor is DERIVED at run time from that measurement rather than typed:

```text
[measured] fixture mic -46.9 dBFS overall -> x2.18 -> -40.1 dBFS, so the residual lands at
           -45.25 dBFS, where the app measured its own during the walk
```

**×2.18 is 6.8 dB — a volume knob, not a different recording**, and the test bounds it on both
sides so a re-recorded fixture announces itself instead of quietly changing what is being proved.

**For whoever records the next fixture:** a pair captured for ERLE work is not automatically a
pair that can reproduce a VAD-threshold defect. Capture at the volume the walk uses, and say what
the volume was.

---

## 4. The proof

`richos/app/crates/richos-voice/tests/self_voice_replay.rs`. It runs the CEO's own echo path
through the EXACT `CaptureBrain` the audio callback runs, and through a term-for-term
reconstruction of the rule that shipped in candidate .5, so the difference is attributable rather
than merely observable — the precedent `echo_path_replay.rs` set.

### Before and after, on the same audio

| | shipped rule (candidate .5) | the rule now |
|---|---|---|
| a question, then Rich answers into it | **ADMITTED — 2.224 s, 0.820 s of it Rich** | DISCARDED, tainted |
| an utterance born while `say` is still spawning | **ADMITTED**, and the WAV contains Rich | DISCARDED, tainted |
| the CEO speaks after the answer ends | admitted | **admitted** |
| the CEO taps stop mid-answer | admitted | **admitted** |

Each half of the fix closes the first scene on its own:
`re_evaluating_taint_closes_this_scene_even_on_the_old_speaking_signal` feeds the NEW brain the
SHIPPED flag and it still refuses. They are not one change wearing two names.

### The tail

```text
running 14 tests
test synthesis_alone_holds_the_window_open ... ok
test the_hold_is_the_sum_of_the_measured_terms_floored_at_one_tick ... ok
test the_look_back_is_the_0_416_s_the_recorder_actually_reaches_back_through ... ok
test the_window_closes_once_the_measured_hold_has_elapsed ... ok
[measured] fixture mic -46.9 dBFS overall -> x2.18 -> -40.1 dBFS, so the residual lands at -45.25 dBFS, where the app measured its own during the walk
test the_scaling_is_derived_from_the_apps_own_measurement ... ok
test a_barge_in_mid_answer_still_delivers_the_words_the_ceo_is_saying ... ok
test the_ceo_speaking_after_the_answer_ends_is_still_heard ... ok
test the_window_is_open_for_every_frame_of_the_answer_including_the_gaps ... ok
[measured] Rich's echo alone, 447 far-active blocks: median -48.6 dBFS, p90 -40.2, p99 -36.2, peak -34.3 — spread above the median 14.3 dB
[measured] so a level test would have to sit at least 14.3 dB above the median before it stopped firing on Rich alone, i.e. the CEO would have to reach -34.3 dBFS at the microphone while the echo sits at -48.6 dBFS
test separating_the_ceo_from_richs_echo_by_level_needs_a_margin_this_large ... ok
test an_utterance_born_while_say_is_spawning_is_admitted_by_the_old_flag_and_refused_by_the_window ... ok
[measured] 2.224 s submitted as the CEO's message, 0.820 s of it Rich
test the_shipped_rule_submits_richs_own_answer_as_the_ceos_message ... ok
test richs_own_answer_is_never_submitted_as_the_ceos_message ... ok
test re_evaluating_taint_closes_this_scene_even_on_the_old_speaking_signal ... ok
test the_shipped_rule_never_fired_a_barge_in_in_this_scene ... ok

test result: ok. 14 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 4.75s
```

Whole crate: **286 passed, 0 failed, 4 ignored** (the four live-audio opt-ins).

---

## 5. What Ray asked for, so the next walk does not have to infer

Three things did not exist and now do, all in the same file that already printed the ERLE gap.

1. **A wall clock on every line**, in the ledger's own `HH:MM:SS.mmmZ` UTC format, so a log line
   can be lined up against a `PromptReceived` instead of guessed at.
2. **Playout boundaries, per chunk AND per answer.** `playout chunk START` / `playout chunk END`
   are the queue itself; `ANSWER AUDIBLE` / `answer over` are the extended window. **The
   difference between the two IS the diagnosis Ray could not make** — a chunk END with the answer
   window still open is exactly a synthesis gap, named as such in the log.
3. **The per-utterance taint flag, printed whether true or false**, at the start and again at the
   end, with what the window said at that instant. Only discards printed before, so an invariant
   could be seen violated and never seen held.

```text
[richos-voice] 20:06:41.108Z ANSWER AUDIBLE — half-duplex window OPEN (hold after the last sample 37 ms = out 10.7 + in 10.7 + slicer 16.0)
[richos-voice] 20:06:41.133Z playout chunk START — 0.331 s queued, 19 sentence(s) still in synthesis
[richos-voice] 20:06:41.470Z playout chunk END — queue empty, 19 sentence(s) still in synthesis
[richos-voice] 20:06:41.688Z utterance START tainted=true (Rich audible=true)
[richos-voice] 20:06:42.504Z utterance END DISCARDED tainted=true (Rich audible=true)
```

(Shape, not a capture: no live run was made. The format is what the code emits.)

---

## 6. The notice — decided, with the number

`VoiceNotice::CouldNotListenWhileSpeaking` fires on strictly more discards now, so the question
was put directly: does it still say anything true, or is every discard on the unconfident path
indistinguishable from echo, leaving the sentence empty?

**It stays, unchanged, latched once per voice session.** Two different things produce a tainted
discard — Rich's echo, and the CEO genuinely talking over Rich without meeting the 5.008 s
debounce — and the line already refuses to choose between them: every clause about him is
conditional. That is the measurement, not a hedge.

The candidate narrower trigger — *fire only on a voiced residual standing above the echo the
canceller expects* — does not survive the numbers.

- **Voicing cannot separate them.** Rich's echo IS voiced speech, so `voiced.rs`'s pitch and
  harmonicity evidence answers yes to both. Only level is left.
- **Level cannot either, on this path.** Measured over the CEO's own recording with no near-end
  talker present at all, so every decibel of it is Rich — 447 far-active blocks:

  ```text
  median residual          -48.6 dBFS
  p90                      -40.2 dBFS
  p99                      -36.2 dBFS
  peak                     -34.3 dBFS
  spread above the median   14.3 dB
  ```

  A level test would have to sit at **−34.3 dBFS** to stop firing on Rich alone. The VAD's own
  absolute speech floor is **−46.02 dBFS**. So the discriminator would sit **11.7 dB above the
  level at which the app is willing to call anything speech at all**: silent for a CEO speaking
  normally, announcing itself only when he raised his voice. Wrong way round.

The measurement is a test, not a paragraph, so it is re-derived on every run and a fixture that
changed the answer fails loudly.

---

## 7. Can a thread that already received such a prompt be told apart afterwards?

**Today: no, beyond `source=jam`, and the boundary is not mine to cross.**

`Event::PromptReceived` (`app/crates/richos-core/src/ledger.rs:332-353`) carries `turn_id`,
`thread_id`, `text`, `source`, `at`, `entity_id`, `binding_revision` and `intake_id`. `source`
distinguishes a spoken turn (`jam`) from a typed one (`text`) and from an internal one, and
nothing else on the record says anything about where a spoken turn's audio came from. Every voice
prompt looks identical, so an echo-born one and a genuine one are indistinguishable on replay —
including in the CEO's own thread, after the fact.

Making them separable is a one-field change and it lands in `richos-core`, not here: an optional
provenance stamp on `PromptReceived` written by the same code that already knows the answer
(`CapMsg::Started { tainted }` and the window's state at the utterance's start), `#[serde(default)]`
so every existing record reads as "not recorded". That would let a thread be audited afterwards,
and would let the UI mark such a bubble rather than leaving the CEO to recognize his own words'
absence.

**I stopped at that boundary** — `richos-core` is outside this task's footprint and
`echo-opus-frontdesk1` is working in it. Nothing in this branch touches it.

For the walk that produced the blocker: the words Rich never said are in the QA scratch thread
only (`…/scratchpad/richos-qa-cand5/home/…/conversation-ledger.jsonl`), nothing of the CEO's, so
there is nothing to clean up.

---

## 8. Commits, oldest first

| SHA | what |
|---|---|
| `b77810a5` | measure how long Rich is still audible after the playout queue empties |
| `9255d9d3` | ask the microphone's device how old the audio it just handed over is |
| `fdf00379` | half-duplex covers the WHOLE of Rich's answer, not the queue's depth |
| `01d5ff93` | replay the defect: the shipped rule submits Rich, the new one refuses |
| `155fb96f` | the half-duplex notice keeps its trigger — measured, not assumed |

Not merged, not pushed, not deployed. `nightly-local.py` was not run.
