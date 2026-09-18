# The candidate-.6 "onset defect" was the harness, and here are the decibels

**Echo (Rust & Tauri desktop engineer), 2026-09-18.**
Branch `cc/echo-opus-onset1`, worktree `/Users/alex/ab/richos-wt/echo-opus-onset1`.
Main at dispatch `058614e6`; main moved to `1dd2e5a8` mid-task and is merged in.

## LIVE PLAYBACKS: 0

Nothing in this work played a sound. Machine output volume read once, read-only, and never
written: `output volume:60, input volume:44, alert volume:100, output muted:false` — the same
before and after, because it was never set. `pgrep -fl richos-tauri` returned nothing at the
start; the app was never launched. The near-end speech in the new tests is rendered by
`say -o <file>`, which writes a WAV and does not touch the output device.

---

## Verdict

**There is no defect at the onset. The missing `utterance START` in Ray's observation C is an
artifact of the only sound source an agent has on this Mac, and I changed no gate.**

Reproduced on the committed echo-path fixture, which is path (a) of the CEO's ruling of
2026-09-18 (richos-hq `wiki/ceo-decisions.md` §53, landed on main at `1dd2e5a8` as
`richos/app/crates/richos-voice/TESTING.md` and a `src/lib.rs` doc block):

- A near-end voice over Rich's audible answer **starts an utterance** at every level from
  **−36.0 dBFS** upward. It is born `tainted=true`, it is discarded, and it is never submitted —
  so the notice layer is reached and the half-duplex card can fire once, which is what it is for,
  and the `c712ccd5` invariant is untouched.
- Ray's talk-over reached the microphone at **−44.7 dBFS**, which the running app itself printed
  while discarding it. That is **8.7 dB below** the crossover with Rich audible and **5.7 dB
  below** it with **Rich entirely silent**. It would not have started an utterance in an empty
  room either.
- A voice at any near-field level sits **11 to 21 dB above** the crossover.

The brief asked for a red-then-green test. There is no red half, because there is nothing broken.
What is committed instead is a test that pins both halves of the explanation, with a positive
probe proving it can fail.

---

## 1. What the walk actually did — its own command log is the correction

`docs/verification/2026-09-17-nightly-1.2.0-20260917.6-onscreen-audit.md` §7, playback 4:

```text
21:35:01.262  say -v Samantha "Excuse me Rich, you can stop counting now."  (playback 4, ended :05)
  -> NO utterance START logged for it at all; nothing submitted; NO notice card
21:35:03.425  answer over — Rich finished the count to twenty, not cut off
```

`say` renders to the **default output device**. Two lines earlier in the same log the default
output device is `Mac mini Speakers`, and the output volume had been set to 85 for the check. So
the "interruption" came out of the same loudspeaker as Rich's answer, at the same volume, and
took the same acoustic path into the Elgato Wave:3. It is not a person at the microphone; it is a
second echo, and a gate that fires on it fires on Rich.

**The level is measured, not inferred.** Audit-5 (`…-20260917.5-onscreen-audit-2.md:449`) printed
the app's own figure for exactly this sound while discarding it: **residual −44.7 dBFS**. Rich's
echo **alone** on the same rig, over 447 far-active blocks of the committed fixture, is:

```text
  median  -48.6 dBFS
  p90     -40.2
  p99     -36.2
  peak    -34.3        spread above the median  14.3 dB
```

(`tests/self_voice_replay.rs::separating_the_ceo_from_richs_echo_by_level_needs_a_margin_this_large`,
re-run here, printed above.) **−44.7 dBFS sits inside that distribution.** Nothing downstream of
the canceller can separate the two, and nothing should try.

---

## 2. The reproduction — path (a) of §53

New in `tests/self_voice_replay.rs`, which is where the fixture harness already lived:

- `Scene::near_end_talker(at_frame, signal)` sums a signal into the **microphone track and
  nothing else**. The reference is untouched, so the canceller holds no copy of the talker and
  cannot attenuate it by even the 3–7 dB it manages on Rich. That asymmetry *is* the difference
  between a person at the desk and `say` through the app's own output device.
- `Scene::rich_answers_for(secs)` builds an 18 s audible answer as a chain of `say` invocations
  with the synthesis gaps between them — the shape of the walk's *"one… two… three…"*, whose
  deltas chunk into roughly one sentence per number (`chunk.rs:126-129`). The fixture holds one
  sentence, so it is re-entered at rotating offsets rather than replayed from the same sample,
  which would make the echo periodic.
- `say_offline(voice, text)` renders **Ray's own sentence in Ray's own voice** to a 16 kHz mono
  WAV. `-o` means no sound. Same device `voiced_acceptance.rs` already uses, for the same reason:
  a model of a voice can be fitted to its own detector, so the speech here is real speech.
- The talker is superimposed **11.0 s into the answer**, where Ray's was.
- Every replay asserts `!brain.aec_confident()` — the canceller is unconfident on this path, as
  the brief requires, and that is checked rather than assumed.

Driven through `CaptureBrain` — the exact struct the audio callback runs.

---

## 3. The numbers

`the_level_at_which_a_talker_over_rich_starts_an_utterance`. Left half: the talker over Rich's
audible answer. Right half: **the control** — the identical talker at the identical position in
an identical-length scene in which Rich never plays, so the only variable between the halves is
whether Rich is audible.

```text
[sweep] talker: Ray's own sentence, 2.841 s, superimposed 11.0 s into the answer
[sweep]         OVER RICH'S AUDIBLE ANSWER          | CONTROL: THE SAME TALKER, RICH SILENT
[sweep]  level  start  taint  adm  disc  barge  run | start  adm  disc  run
[sweep]  -46.0      0      0    0     0      0    0 |     0    0     0    0
[sweep]  -45.0      0      0    0     0      0    0 |     0    0     0    0
[sweep]  -44.0      0      0    0     0      0    0 |     0    0     0    0
[sweep]  -43.0      0      0    0     0      0    0 |     0    0     0    0
[sweep]  -42.0      0      0    0     0      0    0 |     0    0     0    0
[sweep]  -41.0      0      0    0     0      0    0 |     0    0     0    0
[sweep]  -40.0      0      0    0     0      0    0 |     0    0     0    0
[sweep]  -39.0      0      0    0     0      0    0 |     1    0     1    6
[sweep]  -38.0      0      0    0     0      0    0 |     1    0     1    6
[sweep]  -37.0      0      0    0     0      0    0 |     1    0     1    6
[sweep]  -36.0      1      1    0     1      0    6 |     1    1     0    6
[sweep]  -35.0      1      1    0     1      0    6 |     1    1     0    6
[sweep]  -30.0      1      1    0     1      0    6 |     1    1     0    6
[sweep]  -20.0      1      1    0     1      0    6 |     1    1     0    6
[sweep]  -12.0      1      1    0     1      0    6 |     1    1     0    6
```

(Full sweep is 1 dB from −52 to −28 dBFS plus four coarse steps above; the rows above are the
interesting band. `run` is the peak consecutive-speech run the endpointer reached inside the
talker, out of the 7 frames an onset needs.)

| | |
|---|---|
| first `utterance START` **over Rich's answer** | **−36.0 dBFS** |
| first `utterance START` **with Rich silent** | **−39.0 dBFS** |
| what the audible answer costs at the onset | **3.0 dB** |
| Ray's harness talk-over, as the app measured it | **−44.7 dBFS** → 8.7 dB below the first, 5.7 dB below the second |
| `a_voice()`, this file's CEO stand-in since the window work | **−24.8 dBFS** → 11.2 dB clear |
| `say` rendered, unattenuated | **−15.8 dBFS** → 20.2 dB clear |
| the crate's own "a normal speaking level", `barge_in_composition.rs:20`: 0.25-amplitude tone, 0.25 ÷ √2 = 0.17678 rms | **−15.05 dBFS** → 20.9 dB clear |

**Barge-in did not fire, and must not have.** 2.841 s of talking is under the unconfident-canceller
debounce: `313 × 256 ÷ 16000 = 5.008 s`, re-derived here rather than quoted. That is a different
gate answering a different question, exactly as `endpoint.rs`'s module table says, and it is not
what observation C was about. The onset is `7 × 256 ÷ 16000 = 0.112 s`, and the run reached 6
before firing on the 7th frame.

---

## 4. Which way this replay errs — measured, not asserted

`mic_gain_for_the_walks_volume()` scales the whole microphone track to put the post-cancellation
residual where the live app measured its own, which scales the CEO's **room noise** along with
the echo. His room sits at **−67.9 dBFS** live
(`2026-09-17-aec-erle-on-the-ceo-rig.md:86`); the scaled fixture's quietest second is
**−49.1 dBFS**. A louder room means a higher adapted floor, and therefore a **higher** onset bar
than the running app has:

```text
[measured] VAD speech threshold after settling: -38.06 dBFS on the replay's room (-49.1 dBFS),
           -46.02 dBFS on the CEO's (-67.9 dBFS) — the replay's onset bar is 7.96 dB higher
           than the live one
```

At his real room level the `noise_floor × 3.0` term falls far under the absolute floor, so the
live threshold is **pinned at 0.005 rms = −46.02 dBFS** (`vad.rs:86-91`). That is asserted in
`the_replays_room_is_louder_than_the_ceos_so_its_onset_bar_is_the_pessimistic_one`, so a
re-recorded fixture that inverted the relationship would fail loudly rather than quietly
invalidating this document.

**Every level in §3 is therefore conservative**, and the conclusion — a near-field voice clears
the onset comfortably — is safe in the right direction.

---

## 5. Both walk observations, explained, with no change to any gate

This is an **extrapolation and is flagged as one**: it takes the 3.0 dB the audible answer costs
in the fixture and applies it to the live pinned threshold. It is not a live measurement.

```text
  live threshold, Rich silent      -46.02 dBFS   (the absolute floor, pinned)
  Ray's sound at the microphone    -44.70 dBFS   -> 1.32 dB ABOVE it  -> HEARD
  live threshold, Rich audible     ~-43.0  dBFS   (-46.02 + the measured 3.0 dB)
  Ray's sound at the microphone    -44.70 dBFS   -> 1.7 dB BELOW it   -> NOT HEARD
```

- **Observation A**, `21:31:06.940 utterance START tainted=false` → `21:31:09.607 utterance END
  ADMITTED — 3.008 s`: Ray's spoken *prompt*, through the same speakers at the same volume, with
  Rich **silent**. Heard, recognized in full, submitted. Consistent with the first two rows.
- **Observation C**, `21:35:01.262` → *"NO utterance START logged for it at all"*: the same kind
  of sound, through the same speakers at the same volume, with Rich **audible**. Not heard.
  Consistent with the last two rows.

One knife-edge of under two decibels, with the harness sitting on it, explains both. It is not an
onset defect; it is a test signal that was never more than about 1 dB clear of the level at which
this app is willing to call anything speech at all.

---

## 6. What I did NOT change, and why

- **The VAD's absolute floor, ratio and adaptation.** Nothing at −44.7 dBFS can be admitted
  without admitting Rich's own echo, whose median is −48.6 dBFS and whose peak is −34.3 dBFS.
  Lowering the floor to hear the harness is the candidate-.5 defect being rebuilt on purpose.
- **`SPEECH_ONSET_FRAMES` (7 frames, 0.112 s).** It is reached in 7 frames by every near-field
  level tested. It was never the gate.
- **`bargein.rs` and the 5.008 s → 0.400 s rule.** Not in question, per the correction, and not
  touched.
- **The whole-answer audible window (`c712ccd5`).** Untouched, and the new test asserts its
  invariant from the other side: a near-end utterance over the answer is born tainted and is
  never submitted.
- **The tap-to-stop-in-silence question** raised beside the notices work
  (`2026-09-17-notice-budget-provenance-and-the-not-measured-diagnostic.md`): a `forced` tap sets
  `barged = true`, and on the **same frame** the final `else if !speaking && !recording` branch
  of `controller.rs::push_residual` clears it again, because `recording` is still false (the onset
  needs 7 frames). Confirmed from source, still true, and **unchanged by this work** — I made no
  behavioral change at all. It remains a product question, not a measurement one.

---

## 7. What the next walk must do to test barge-in honestly

**Per §53, `say` through this Mac's speakers is no longer an acceptable way to test an
interruption, a barge-in, a talk-over, or "the CEO speaks while Rich speaks."** The three paths
§53 allows, with what each is actually good for here:

1. **(a) The committed fixture, with a near-end voice superimposed on the microphone track at a
   stated near-field level.** This is what this document is. It needs no device, no sound and no
   person, it runs in `cargo test`, and it can sweep a level range no live walk could. It is the
   right default and it should be the first thing any future onset or window claim is checked
   against. What it cannot do: prove the *devices* behave, or catch anything above the
   microphone-frame boundary.
2. **(b) A human at the desk.** The only path that tests barge-in end to end as the CEO will
   experience it — his voice, his gain, his distance, his room, the real capture callback. The
   walk should record whether `utterance START` appeared, whether `BargeIn` did, and the wall
   clock of each. This is the one that has never been run.
3. **(c) A second, separate sound source near the microphone** — a phone or a second laptop
   playing a voice recording, positioned at speaking distance from the Wave:3, with the Mac's own
   output at the walk's volume. This is the honest substitute for (b) when no person is
   available, and it is the one a QA agent can actually execute. **The level must be stated and
   measured, not assumed**: the whole of this document exists because an unmeasured level was
   read as a code defect.

**THE ONE THING A WALK STILL CANNOT READ OFF THE LOG, AND I DID NOT BUILD IT.** A sound that
produces **no** `utterance START` prints nothing at all — which is precisely why observation C
cost a walk and two engineer tasks to explain. The deciding pair is now readable in code
(`CaptureBrain::last_rms()` against `CaptureBrain::speech_threshold()`, plus
`onset_run_frames()`), but **it is not printed**: `CapMsg::Started` is the only thing that crosses
the channel to the supervisor thread, the VAD lives on the audio thread, and putting the numbers
in the log means widening `CapMsg` and touching every match site. That is new shipped behavior and
I was told to stop, so it is recorded here rather than done. **The shape it should take, for
whoever picks it up:** a once-per-transition line on the order of *"heard something at −44.7 dBFS,
threshold −43.0 dBFS, onset run 3 of 7 — not speech"*, rate-limited exactly as `NoAudio` is (one
transition, one message, never one per 16.000 ms frame). Without it, path (b) or (c) below can
report *whether* an interruption was heard but never *by what margin*, and the next marginal case
will be as unanswerable as this one was.

**And the acceptance criterion for any of the three:** an interruption that reaches the
microphone at a near-field level must produce an `utterance START` line. Whether it also produces
a `BargeIn` depends on the 5.008 s debounce and on the canceller's confidence, which on this
hardware means a 2–3 second interjection correctly will not cut Rich off. A walk that expects
Rich to stop after two seconds on the CEO's speakers is expecting the design to do something it
declines to do by measurement, not something it fails at.

---

## 8. Still open, and named rather than papered over

- **No recording of a human voice exists in this tree, and I cannot make one.** §53's path (a)
  asks for a near-end voice *recording*; what is committed is real speech rendered offline by
  `say -o` plus the crate's existing synthetic `a_voice()` stand-in, superimposed on the
  microphone track and never played. That satisfies the substance of (a) — nothing goes through
  the speakers — but a few seconds of the CEO's own voice, captured at his Wave:3 and committed
  beside the echo-path fixture, would make every level in §3 his instead of a synthesizer's.
  **That capture needs a person and is therefore not mine to do.**
- **No measurement of the CEO's own voice level at his Wave:3 exists anywhere in the record.** I
  looked. The near-field anchors in §3 are the crate's own convention (−15.05 dBFS), its existing
  stand-in (−24.8 dBFS) and an unattenuated synthesizer (−15.8 dBFS). The crossover is −36.0
  dBFS, so the conclusion holds across a 21 dB span and does not depend on which anchor is
  right — but the number itself is still missing, and it would come free with the capture above.
- **Reference-signal-gated echo suppression is still the open gap**, unchanged. Coherence caps
  any linear canceller at 4.3 dB full band on this path, `confident()` returns false there, and
  no primitive for the real fix exists in this crate. Everything above assumes it stays that way.
- **The 3.0 dB the audible answer costs at the onset is real.** It is small, it is nowhere near a
  person's voice, and it is the thing that decided Ray's two observations. If a future walk finds
  a *genuine* near-field interruption going unheard, freezing the VAD's floor adaptation while
  the audible window is open is the obvious first move and would cost that 3 dB back. I did not
  do it, because nothing measured here justifies touching a shipped gate.

---

## 9. Commands and output

```text
$ pgrep -fl richos-tauri                      (no match — the app was never launched)
$ osascript -e 'get volume settings'
  output volume:60, input volume:44, alert volume:100, output muted:false      (read only, twice,
                                                                               unchanged)

$ cargo test -p richos-voice --release
  unittests src/lib.rs            240 passed; 0 failed; 4 ignored
  tests/barge_in_composition.rs    17 passed; 0 failed
  tests/echo_path_replay.rs         2 passed; 0 failed
  tests/model_provisioning.rs      23 passed; 0 failed
  tests/self_voice_replay.rs       18 passed; 0 failed        (14 before this work)
  tests/voiced_acceptance.rs        4 passed; 0 failed
  Doc-tests richos_voice            0 passed; 0 failed

  The 4 ignored are the device-opening tests, which report `ignored` without
  RICHOS_VOICE_LIVE_AUDIO=1 — see build.rs. They were not opted into.

# THE POSITIVE PROBE — a negative result whose test cannot fail proves nothing.
$ sed -i '' 's/absolute_floor: 0.005,/absolute_floor: 0.1,/' src/vad.rs
$ cargo test -p richos-voice --release --test self_voice_replay -- a_near_end_voice_over
  FAILED: "a voice at -24.8 dBFS over Rich's answer started NO utterance — this is the defect
           the .6 walk was read as showing, and it is now real: Outcome { ... starts: 0 ... }"
           left: 0   right: 1
$ (reverted)
$ sed -i '' 's/SPEECH_ONSET_FRAMES: u32 = 7;/SPEECH_ONSET_FRAMES: u32 = 120;/' src/endpoint.rs
$ cargo test -p richos-voice --release --test self_voice_replay -- a_near_end_voice_over
  FAILED: the same assertion, the same message
$ (reverted)

$ git diff --stat 1dd2e5a8 HEAD -- .
  richos/app/crates/richos-voice/src/controller.rs        |  34 ++
  richos/app/crates/richos-voice/src/endpoint.rs          |   8 +
  richos/app/crates/richos-voice/src/vad.rs               |  34 +-   (2 deletions: push_frame
                                                                     now calls the accessor)
  richos/app/crates/richos-voice/tests/self_voice_replay.rs | 381 ++
  4 files changed, 455 insertions(+), 2 deletions(-)
  Plus this file. No threshold, constant, gate or decision moved.
```

**Not run, deliberately:** `nightly-local.py`, any deploy, any push, any merge to main. Nothing
under `~/RichOS`, `~/.richos-signing` or the installed app was read or written. `richos-core` and
`ui/` were not touched — `echo-opus-land1` is working there.
