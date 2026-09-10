# turbo vs q5_0 — the numbers, 2026-09-10

**Which model ships: `large-v3-turbo` (1,624,555,275 B) or `large-v3-turbo-q5_0` (574,041,195 B).**
Open item 1.3.

**This document measures. It does not recommend, and it changes no default.** The shipping default
is still `large-v3-turbo` (`config.js` `DEFAULT_MODEL`), untouched by this work.

- The rig, the tools and how to re-run any row: [`README.md`](README.md)
- The generated tables: [`measurements/model-comparison.txt`](measurements/model-comparison.txt)
- The settings this is measured under: [`../whisper-settings-2026-09-10/whisper-settings-decisions.md`](../whisper-settings-2026-09-10/whisper-settings-decisions.md)

**Everything below is on whisper.cpp 1.9.1 / ggml 0.17.0 / Apple M4, under the settings as they now
ship** — `-l en -t 4 -mc 0 -oj -np -fa -ojf -of <base>`, recorded from the process that ran, not
read out of source. Both model files match their `model-pins.json` pins.

---

## 1. The whole thing in one table

Short call = 6 invented two-speaker calls, 12 channels, 1,905 scoring tokens, true WER because the
script IS the reference. **Post-guard is what the user receives** — the shipping repetition guard
runs after the decoder in `pipeline.js`, so a fabrication it removes costs the user nothing and one
it keeps costs the user everything.

| | | `large-v3-turbo` | `large-v3-turbo-q5_0` |
|---|---|---|---|
| **short call, render A** | WER pre-guard | 4.09% (S41 D9 I28) | **2.89%** (S40 D9 I6) |
| | WER post-guard | 3.78% (S41 D9 I22) | **2.78%** (S40 D9 I4) |
| | proper nouns exact / 66 | **47** (71.21%) | 44 (66.67%) |
| | fabrication findings | 3 silence, 0 loops | 1 silence, 0 loops |
| | **one full sentence emitted twice** | **yes** | no |
| **short call, render B** | WER pre-guard | 3.20% (S40 D8 I13) | 3.04% (S44 D6 I8) |
| | WER post-guard | 2.99% (S40 D8 I9) | **2.94%** (S44 D6 I6) |
| | proper nouns exact / 66 | **48** (72.73%) | 42 (63.64%) |
| | fabrication findings | 2 silence, 0 loops | 1 silence, 0 loops |
| **92 min real, channel `me`** | segments / words | 435 / 3,762 | 439 / 3,706 |
| | post-guard words | 3,762 | 3,700 |
| | loop findings / span | 0 / 0.0 s | 0 / 0.0 s |
| | silence fabrications | 2 (0 removed) | 4 (3 removed) |
| | decode wall | **221.5 s** | 237.2 s |
| **92 min real, channel `others`** | segments / words | 566 / 6,133 | 530 / 6,086 |
| | post-guard words | 6,133 | 6,084 |
| | loop findings / span | 0 / 0.0 s | 0 / 0.0 s |
| | silence fabrications | 0 (0 removed) | 3 (2 removed) |
| | decode wall | **244.6 s** | 261.5 s |
| **resources** | peak RSS, short call | 2,014,101,504 B (1.88 GB) | **884,981,760 B (0.82 GB)** |
| | peak RSS, 92 min | 2,817,949,696 B (2.62 GB) | **1,859,256,320 B (1.73 GB)** |
| | on disk | 1,624,555,275 B | **574,041,195 B** |
| | integrity hash per cold start | 2.94 / 2.95 / 2.95 s | **1.05 / 1.06 / 1.06 s** |

**Read as differences:** q5_0 uses **56.1% less peak RAM at call length** and **34.0% less at 92
minutes**, occupies **1,050,514,080 B less disk**, and hashes **1.9 s faster** on every cold start.
It is **7.0% slower** on the long recording (498.7 s against 466.1 s for both channels) and 2.6% /
5.3% slower on the two short-call repetitions. On WER it is ahead on both renders, by 1.21 points on one and 0.16 on the
other. On proper nouns it is behind on both renders, by 3 and by 6.

**Nothing in this table is a tie, and nothing in it is a landslide.** §5 is where the conditions
that would settle it are stated concretely.

## 2. The `-fa` row on q5_0 — the specific question, and what re-running it found

The settings table §6 says: *"The one row that could plausibly differ between a full and a
quantized model is `-fa`, since flash attention interacts with numeric precision; if the CEO moves
the default to q5_0, re-run the `nofa` row and nothing else."*

Re-run, same method, and **on turbo too in the same sitting** — a delta measured against a baseline
from a different corpus render is not a delta.

| render A | `-fa` (ships) | `-nfa` | `-nfa` costs |
|---|---|---|---|
| `large-v3-turbo` | 4.09% (S41 D9 I28) | **3.20%** (S42 D7 I12) | **−0.89 points — it HELPS** |
| `large-v3-turbo-q5_0` | **2.89%** (S40 D9 I6) | 2.99% (S39 D10 I8) | +0.10 points |
| wall, turbo (r1 / r2) | 78 s / 75 s | 90 s / 90 s | +15.4% / +20.0% |
| wall, q5_0 (r1 / r2) | 80 s / 79 s | 90 s / 91 s | +12.5% / +15.2% |
| peak RSS | unchanged either way | unchanged either way | 0 |

**The answer to the question asked: on q5_0 the effect very nearly vanishes.** 2.89% against 2.99%
is **two errors in 1,905 tokens** (55 total against 57). It does not reverse and it does not hold at
anything like the recorded magnitude — it disappears into the noise floor of the corpus.

**And the row does not reproduce on turbo either, which is the finding I did not go looking for.**
The settings table records `-nfa` costing turbo **1.57 points** (4.46% against 2.89%). On today's
corpus render the same two configurations on the same model, same binary, same day, score 3.20%
against 4.09% — `-nfa` is **better by 0.89 points**. The sign is opposite.

**Why, and it is not a contradiction of that measurement.** Both are correct on their own audio.
`say` re-renders the corpus differently each time — render A and render B here differ by 68 bytes
across 12 files and by a full WER point on turbo — and the settings rig's own README already rules
that absolute WER is comparable only within one sitting on one audio build. What today adds is that
**the DIFFERENCE between two configurations is not stable across renders either**, at least when
one arm of it is dominated by a single fabrication event on a single call (§3). That was not known
when the `-fa` row was written, and it is the part of that row that does not survive.

**What DOES survive, on both models and both repetitions: `-nfa` is slower.** 12.5–20.0% here,
18% there. The speed half of the `-fa` row reproduces cleanly; the accuracy half does not.

**Per the brief, this is recorded here and `wd1`'s table is not edited.** The row as written is
`-fa`'s: *"worth 1.57 WER points."* On the evidence of today the defensible version of that row is
narrower — flash attention is the vendor default, it is faster on both models, it is worth pinning
explicitly so a formula bump cannot flip it silently, and its accuracy effect is within corpus-
render noise on both models. The pin is still right. The number attached to it is not reproducible.

## 3. The one finding that is not a rounding difference

Full text, guard verdict and hashes: [`measurements/fabrication-case.txt`](measurements/fabrication-case.txt).

On render A, call-03, channel `me` — 114.17 s of audio, shipping settings, `-mc 0` — **turbo emits
one sentence of the script twice**:

> Then we keep the old spreadsheet until your board trusts the new one. That is normal.
> Then we keep the old spreadsheet until your board trusts the new one. That is normal.

q5_0 on the identical audio with the identical argv emits it once. Both repetitions of the sweep
produce byte-identical output, so this is deterministic, not sampling.

**The shipping guard does not remove it.** It removes the other thing turbo invented on that call —
a "Thank you." emitted from 114.00 s to 143.98 s on a file 114.17 s long, i.e. almost entirely past
the end of the audio — and leaves the duplicated sentence in place. Seventeen words spoken once are
delivered twice.

Three things make this worth the CEO's attention rather than a footnote:

1. **It is the class `-mc 0` exists to prevent**, occurring at `-mc 0`, at CALL length, on the model
   that ships today. The settings table's fabrication rows are all long-form because at call length
   it had not been seen; this rig looked, and there it is.
2. **It survives the guard**, so it is not damage repaired downstream — it reaches the transcript.
3. **It recurs in milder form on independent audio.** On render B turbo does not reproduce the full
   duplication, but at the same point it emits `That is normal. It is normal.` — an echo the guard
   also keeps. q5_0 renders the passage once on both renders.

**What this is not.** It is not a rate, and it is not a claim that turbo duplicates spans in
general. It is one call, twice, on one model. It is also the single largest contributor to turbo's
render-A insertion count (I28 against q5_0's I6), which is why §1's short-call WER gap should be
read together with this section rather than on its own.

## 4. The long recording, where the two previously disagreed most violently

The 2026-08-29 record has q5_0 destroying **44.1%** of channel `me`'s timeline against turbo's
**8.6%**. That was at `-mc -1`. **Under the settings as they now ship, that disagreement is gone:**

| | loop findings | fabricated span | share of timeline |
|---|---|---|---|
| turbo, `me` | 0 | 0.0 s | 0.0% |
| q5_0, `me` | 0 | 0.0 s | 0.0% |
| turbo, `others` | 0 | 0.0 s | 0.0% |
| q5_0, `others` | 0 | 0.0 s | 0.0% |

Both models, both channels, 184.6 minutes of real audio in total: **zero loop findings and zero
fabricated timeline.** The catastrophic divergence between these two models was a property of
`-mc -1`, and `-mc 0` closes it for both. Turbo's `me` row reproduces the settings rig's committed
figures exactly — 435 segments, 3,762 words — on the same WAV bytes, which is this rig's validation
that it is the same instrument.

**The residue, stated rather than buried.** q5_0 produces slightly more of the *silence* fabrication
class (4 against 2 on `me`, 3 against 0 on `others`) and the guard removes most of them (3 of 4, 2 of
3). Turbo produces fewer and the guard removes none of them. After the guard, turbo has **62 more
words on `me` and 49 more on `others`** than q5_0.

**Those 111 words are undecidable and will stay undecidable.** No verified reference exists for this
recording, and per the CEO's ruling of 2026-09-10 none is coming. There is no measurement, on this
material or any material that will ever exist, that says whether they are speech q5_0 lost or
fabrication the guard missed in turbo. Anyone who tells you which is guessing.

**What the channels physically are**, measured with the pipeline's own burst probe, because the
silence profile is what the VAD question in the settings table §3 turns on:

| channel | duration | speech bursts | speech | share of timeline |
|---|---|---|---|---|
| `me` | 5,536.8 s | 681 | 1,259.3 s | **22.7%** |
| `others` | 5,536.3 s | 861 | 2,286.5 s | **41.3%** |

Neither channel is a continuously-talking one: the busier of the two is silent for 58.7% of its
timeline. That is a correction to a *characterization* in the settings table §3, not to its
decision — that decision rests on a measured 91% wall-clock cost for tuned VAD on this audio, which
this work did not re-run and does not dispute.

## 5. What would make this close

The conditions under which the cheaper model is the wrong choice, stated concretely enough to check.

**q5_0 is the wrong choice if proper nouns are the thing that matters.** This is the one axis where
turbo wins on **both** renders and by a margin larger than the WER gap: 47 against 44, and 48
against 42. Per-term, q5_0 is the one that drops `Everlock` (3 of 4 against 4 of 4 on both renders),
`Nadia Kwok` and `Northgate`. The settings table §5 already prices name spelling as the standing
cost of the `-mc 0` invariant — 46 of 66 there — and choosing q5_0 spends a further 3 to 6 of the
remaining ones. If the loro correction layer is going to canonicalize entity names anyway (the open
half of item 3.3d), this is cheap; if it is not, this is the axis that a CEO reading his own
transcript would notice first, because a wrong company name is visible in a way that a wrong "the"
is not.

**q5_0 is the wrong choice if the 7% long-form wall-clock cost lands somewhere that matters.** It is
7.0% on 184.6 minutes of audio — 32.6 seconds on a job that already takes 8 minutes. That is
invisible for batch transcription of a recorded meeting. It is not obviously invisible if a long
recording is ever transcribed while the user waits, and it compounds against the `-mc 0` decision,
which already chose the faster of its options partly on wall clock.

**turbo is the wrong choice if peak memory is a constraint on any host that has to run this.** 1.88
GB against 0.82 GB at call length is the largest single difference in this entire document, and it
is stable, reproducible, and independent of corpus render or flags. On an 8 GB machine running the
desktop app, a webview, and a Node service, 1 GB is not a rounding error. **This is the axis where
the measurement is decisive rather than close** — everything else here is within a point or two of
its alternative; this is a factor of 2.3.

**turbo is the wrong choice if a duplicated sentence in a transcript is worse than a mis-heard
word.** §3 is the whole argument. WER treats 17 duplicated words as 17 errors, the same as 17
mis-heard ones. A reader does not: a sentence appearing twice reads as a defect in the product,
while a mis-transcribed word reads as transcription being hard. That is a judgment about what a
transcript is FOR, and it is not a number I can produce.

**It is genuinely close on WER, and I would not decide on that axis at all.** 1.21 points on render
A and 0.16 on render B is the same comparison giving two answers a factor of 7.5 apart, on audio
that differs by 68 bytes. Post-guard the render-B gap is **0.05 points** — 2.99% against 2.94%,
which is one error in 1,905 tokens. Any decision that rests on the short-call WER column is resting
on the render.

**And one condition that would flip everything but which nobody can check.** If real two-party call
audio behaves like the 92-minute webinar, both models are clean at `-mc 0` and the choice is
resources against names. If it does not — if real calls, with cross-talk and two live microphones,
provoke the duplication class in one model and not the other — that would dominate every number
here. There is no recording of a real two-party call, and there will not be one.

## 6. What these numbers cannot support

Named, so nobody builds on them.

| Claim | Why it cannot be made |
|---|---|
| Either model's WER on REAL audio | No verified reference exists for any real recording here, and the CEO has ruled that no further recording will be made. Every WER in this document is on synthesized speech from a script. |
| Anything about cross-talk | The invented corpus fills the non-speaking channel with `anullsrc` — exact digital silence — and the real recording is a two-mic webinar with one speaker per file. Cross-talk is not in the material, is not measurable on the material, and no claim about it appears here. |
| Anything about accents, noise, or non-English | One synthetic voice per channel; `-l en` throughout. |
| Which model is right for the DICTATION path | That path runs `small.en`, not either of these (settings table §7). Nothing here touches it. |
| A fabrication RATE for turbo | §3 is one call observed twice. Six calls is not a sample from which a rate can be estimated, and saying "one in six" would be inventing precision. |
| That the 111-word long-form difference is speech, or that it is fabrication | Undecidable on this material, permanently. §4. |
| That q5_0 is safer at 92 minutes | It is not. It produces MORE silence fabrications than turbo on both channels (4 vs 2, 3 vs 0). The guard removes most of them; that is a statement about the guard, not about the model. |
| That `-fa` is worth 1.57 WER points | Measured today at −0.89 on turbo and +0.10 on q5_0. §2. The pin stays right; the number does not reproduce. |

## 7. Open, and NOT decided here

- **Item 1.3, the model default itself.** Not mine. The shipping default is unchanged by this work.
- **Long-form `-fa`.** Every `-fa` figure in §2 is at call length, the length the settings row was
  measured at. Flash attention was not re-measured at 92 minutes on either model, and given that
  §3's duplication is flash-attention-dependent at call length, that is a real gap rather than a
  tidy one. It is named rather than filled because the brief scoped the `-fa` re-run to the row as
  written, and filling it is four more 4-minute decodes on a question nobody has asked yet.
- **Whether the settings table's `-fa` row should be re-worded.** §2 says what today's evidence
  supports; per the brief I have not edited that table, and reconciliation is the lead's at land
  time.
