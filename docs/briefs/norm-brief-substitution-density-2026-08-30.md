# The pipeline can now count what the audio can hold — a word-density instrument, and what it can never tell you

**Author:** Norm (Full-Stack Engineer). **Date:** 2026-08-30.
**Requested by:** Rich, on behalf of the CEO.
**Base:** richos `main` @ `1807319`. **Branch:** `norm/substitution-instrument-2026-08-30`.
**Scope:** build the instrument `open-items.md` row 3.3f names as missing — *"nothing measures word
density against a physical speech budget, and that is the named missing instrument"* — measure it on
real material, and state what it cannot see.

**This is a MEASUREMENT INSTRUMENT, not a fix. No shipping default, no tier, no `MODEL_TIERS` value
and not one decode parameter was changed.** `MAX_CONTEXT_TOKENS` is still 0; `whisperArgs()` on a
real end-to-end run through the new code is still exactly `-l en -t 4 -mc 0 -oj -np`. The findings
below about how much the shipping decode loses are findings, not a licence to retune anything.

`data-contract-bypass`: a local model measurement plus a service-side detector. No Avelor/fitapp app
was built, installed, rendered or tested; nothing touched an emulator, simulator or device.

**Privacy.** This brief and its assets are in a PUBLISHED repository, so they contain **no
transcribed speech at all** — not a quoted sentence, not a recovered clause, not a fixture line.
Every span below is a time offset, a level and a count. The committed results were passed through
`norm-substitution-density-2026-08-30-assets/tools/redact.mjs`, which deletes `recovered` / `text` / `nearbyText` recursively and reports the
byte delta so a redactor that removed nothing would be visible. `engine/scripts/lib/publication-boundary.py`
was then run by hand over every changed file against the declaration's own `PRIVATE_SOURCES` —
because Claude Code snapshots hooks at session start, so "the hook did not block it" is evidence of
nothing. It reported CLEAN against a **non-empty** corpus (14 private files, 130,466 bytes), so the
scan was live rather than vacuous. The 133-turn reference corpus is entirely invented and
regenerable by anyone with `say`.

---

## 0. Bottom line up front

### (a) The instrument exists, it is wired as pipeline stage 3.8, and it consumes stage 3.7 rather than duplicating it

`tools/richos-service/lib/substitution-guard.js` — pure, no fs, no child_process — plus stage 3.8 in
`pipeline.js`. Every span the deletion detector confirms is **excluded from this stage's speech
budget**, so one failure is never reported twice under two names. The exclusion raises density, so
it can only ever remove findings. Both stages share ONE probe function; only the paddings differ.

### (b) The budget is physical, and three independent sources agree on where its floor is

A speech burst of known duration can carry only so many words. The instrument's floor is **1.2 words
per second of detected speech**, and it sits below every legitimate delivery this project has ever
measured:

| source | what it is | range |
|---|---|---|
| 2026-08-29 Parakeet coverage brief §0c | 178 sixty-second windows, two channels, real conversational English | **1.87 – 3.68 w/s** |
| this measurement, 92-minute corpus | 516 four-second windows, shipping decode | medians **2.78** (`me`) and **2.53** (`others`); 5th percentiles **1.79** and **1.48** |
| this measurement, invented reference corpus | 133 synthesized turns whose rate is known **by construction** | **1.34 – 4.40 w/s**, median 2.88 |

The two corpora agree on the median to two decimal places (2.88 both), which is a useful check that
the unit means the same thing in both.

### (c) FALSE POSITIVES: zero, in 628 windows of clean material, on two corpora

| corpus | windows | candidates | **findings** |
|---|---|---|---|
| 92 minutes of real two-channel audio, shipping decode | 516 (199 `me` + 317 `others`) | 4 | **0** |
| invented reference corpus, 12 channels, transcripts correct by construction | 112 | 2 | **0** |

Six candidates in 4,193 seconds of clean detected speech, **all six rejected by the adjudicator** —
three as `matches-audio` (the audio really is that thin: laughter, a slow line), three as `echoed`
(the words are present, timestamped just outside the window). On the reference corpus both
rejections are provably correct: those turns were transcribed correctly and the reference says so.

### (d) It fires on a real substitution, and the reference proves the flag rather than suggesting it

| control | result |
|---|---|
| 92-minute corpus, 16 windows of dense speech surgically reduced to four invented words | **16 / 16 fired**, 0 unexplained extra findings |
| invented reference corpus, one turn per channel reduced to four invented words | **10 / 12 fired**, and all 10 are **right by reference** — the reference says those spans held 15–20 words |

Two extra findings appeared during the controls, one per corpus, and both were **inspected rather
than assumed**: in each case the surgery removed a whisper segment whose extent reached back into
the *previous* window, so that window genuinely lost words too (13 → 2 emitted words in one; a
17-word segment in the other). They are true of the tampered transcript, not false positives of the
instrument.

**The two misses are the instrument's shape, not a bug.** A conversational turn is ~5 s; both misses
are windows where a lost turn sat beside a good one and the good one carried the average back over
the floor. Dilution is the named blind spot, and it is now a number: 2 in 12 at turn scale.

### (e) On the artifacts, it separates cleanly from the deletion detector — and it is quiet on what ships

| artifact | deletion detector (3.7) | word density (3.8) |
|---|---|---|
| `large-v3-turbo`, `-mc 0` — **what ships** | 2 spans / 2.2 s | **0 findings** (4 candidates, 4 rejected) |
| `large-v3-turbo`, `-mc -1` — the pre-2026-08-29 decode | 45 spans / 142.3 s | 8 findings / 58.2 s |
| `large-v3-turbo-q5_0`, `-mc -1` — the 1,099-second collapse, `me` only | 37 spans / 203.4 s | 3 findings / 18.1 s |

Excluding 3.7's confirmed spans removed 5 of the 13 findings the density stage would otherwise have
reported on the `-mc -1` artifact. That is the two instruments dividing the timeline instead of
overlapping it, measured.

### (f) Cost: **1.7% of a real end-to-end pipeline run** — 10.0 s inside 588.9 s

Both numbers come from the same `runPipeline()` execution over the real 92-minute two-channel
recording, with no test double anywhere, read out of the product's own
`session.json.pipeline.substitutionGuard.elapsedMs`. The deletion detector in the same run cost
**74.6 s / 12.7%** (its own brief measured 14.0% on a different run). The instrument is cheaper than
its neighbour by a factor of seven for the same reason its neighbour is cheap: nothing re-runs the
file. The burst grid is already computed for two other consumers, window construction is arithmetic,
and only the **4** windows stage A found thin were re-decoded — as clips, through one `whisper-cli`
invocation that loads the model once.

**The cost scales with suspicion, so a BROKEN transcript costs more, and that is stated rather than
averaged away:** on the `-mc -1` artifact, where stage A found 16 and 35 candidates, stage 3.8 took
72.3 s and 90.4 s on the two channels. The probe budget (`maxProbes`, 20 per channel) is the hard
cap, it is visible in the report, and a window that does not fit inside it is reported UNPROBED and
never as a finding.

### (g) Suites green: **233** (baseline 205; 28 new tests), and every one of the 28 was driven RED by breaking the shipped source — 24 mutations, no survivors (§8).

---

## 1. What was built

| file | change |
|---|---|
| `lib/substitution-guard.js` | **new.** PURE. Window construction, the six-condition precision rule, the report, the warnings. The word-time unit, the tokenizer, the filler vocabulary and both echo measures are IMPORTED from `deletion-guard.js`, never copied. |
| `lib/pipeline.js` | stage 3.8; `makeProbe` generalized over both stages' paddings; `pipeline.substitutionGuard`; warnings merged across all three detect-only classes. |
| `test/run.js` | 28 tests, every fixture invented. |
| `README.md` | stage 3.8, at the depth of the two detectors beside it. |

**Wired, and proven wired.** A real `runPipeline()` over the real recording — ffmpeg normalize +
channelsplit, whisper decode, repetition guard, 3.7, 3.8, merge, verify, emit — finished `ready`,
wrote `pipeline.substitutionGuard` with 515 analyzed windows across both channels — one fewer than
the 516 in §0(c), because in the wired path stage 3.7's two confirmed spans leave this stage's
budget and one window drops below the speech mass it needs — merged its
warnings into `verification.json` beside the other two detect-only classes, and left no probe clips
behind.

### 1.1 The discriminator

> A **confirmed finding** is a window holding ≥ 4 s of physically detected speech inside ≤ 30 s of
> wall clock, carrying **at least one** emitted word but far fewer than its budget, where decoding
> **that window in isolation** returns substantially more words than the transcript claims, and
> those words are **not already in the transcript beside it**.

The second half is the whole instrument. A density deficit alone is evidence of nothing: people
pause, trail off and deliver a line slowly for emphasis. The isolated re-decode is what separates
"this span is sparse" from "the audio holds more words than the transcript does" — and a slow,
emphatic delivery is rejected **by name**, `matches-audio`, with the reason spelled out in the
report.

### 1.2 The six conditions

| # | condition | default | why it exists, in one measured fact |
|---|---|---|---|
| 1 | SPEECH MASS | ≥ 4 s of speech in ≤ 30 s wall | 8 s dilutes a whole lost turn (2/12 recall); 3 s is where candidate noise starts (15 candidates on 92 clean minutes against 4) |
| 2 | EMITTED | ≥ 1 word | a wordless window is a DELETION and belongs to 3.7; reporting it here reports one failure twice |
| 3 | DEFICIT | below 1.2 w/s **and** 0.45× the channel's own median | the floor is below all 133 reference turns and both channel 5th percentiles; the relative half is inert at conversational pace and exists for the slow channel |
| 4 | LEVEL | within 24 dB of channel peak | the burst grid is model-free and cannot tell a voice from a chair; a window of breath has a fake denominator |
| 5 | RECOVERY | ≥ 1.75× and ≥ +5 words, surviving repadding | the condition that makes it an instrument rather than a word counter |
| 6 | ECHO | ≤ 4 consecutive **and** < 70% in order, locally | text present at the wrong second is a timing defect; a collapsed retake is text stage 3.5 removed on purpose. Neither is missing speech |

### 1.3 What it refuses to claim, stated in the module header before the code

**It cannot tell you the words present are WRONG. Nothing without a reference transcript can.** It
measures one thing: the transcript holds fewer words than the audio physically carries, by a margin
the audio itself confirms. That is consistent with substitution, with partial deletion inside a
covered burst, and with a paraphrasing collapse — all three the same defect to the reader, all three
with the same remedy. So the verdict noun is `under-transcribed`, and the word "substitution"
appears in no verdict anywhere in the module.

---

## 2. Method, and the provenance of every artifact

Audio: the two gitignored mp3s at `docs/reference/local/`, normalized by the production step
(`ffmpeg -ac 1 -ar 16000`). **No audio, normalized channel or clip is committed anywhere.** Five
independent checks say this is the same corpus the 2026-08-29 briefs measured, and that this harness
reproduces their instruments rather than approximating them:

| check | published 2026-08-29 | this run |
|---|---|---|
| `me.wav` sha256 | `ce12551a…` | **identical** |
| `others.wav` sha256 | `ff0c70cf…` | **identical** |
| burst grid, product's own `detectSpeechBursts()` | 681 / 1,259.3 s and 861 / 2,286.5 s | **identical** |
| emitted word tokens, `-mc -1` | `me` 5,770, `others` 7,125 | **identical** |
| deletion detector, `-mc 0` `me` | 2 spans / 2.2 s | **identical** |
| deletion detector, `-mc -1` `me`, scored pre-guard | 16 spans / 37.1 s | **identical** |

Four whisper runs, all with `-ojf` (output verbosity, not a decode parameter): `large-v3-turbo` at
`-mc 0` on both channels (the shipping configuration, verbatim from `whisperArgs()`), the same at
`-mc -1` on both channels, and `large-v3-turbo-q5_0` at `-mc -1` on `me`.

Everything is scored by importing the product's own functions — `parseWhisperJson`,
`guardTranscription`, `detectSpeechBursts`, `cutSpan`, `measureSpanVolume`, `transcribeClips`,
`guardDeletions`, `guardSubstitution`. Nothing in the harness reimplements a rule that ships. The
segments judged are POST-repetition-guard, because that is the timeline the pipeline judges and the
one that reaches `transcript.md`.

### 2.1 The reference corpus, and why it is the only place a flag can be scored

The invented short-call corpus from the 2026-08-29 WER work — 6 two-speaker calls, 47–174 s, 1,852
words, every sentence, person and company invented — regenerates byte for byte from
`corpus/calls.json` with `say`. `norm-substitution-density-2026-08-30-assets/tools/build-corpus-timed.mjs` is that builder with **one addition**:
`reference-timeline.json`, the start, end and word count of every synthesized turn. That file is
what makes this corpus a reference for a DENSITY instrument and not only for WER — the true
words-per-second of every span is known because nobody spoke and nobody transcribed.

---

## 3. The two things the data forced, neither of which was in the design

**The window was 8 seconds and it was wrong.** Eight seconds is a comfortable span for a rate, and
it is longer than a conversational turn. Scored against the reference corpus with one turn per
channel replaced by four words, an 8 s window caught **2 of 12** — the lost turn was averaged with
the good turn beside it. At 4 s it catches **10 of 12**, and the clean-corpus candidate count on
92 real minutes moves only from 2 to 4. At 3 s it jumps to 15, which is where sub-turn noise
begins — so 4 is one step inside the last clean value. The window also decides how much of a channel is examined at all: at 8 s the instrument
analyzed 74% and 94% of the two channels' detected speech; at 4 s it analyzes **91% and 99%**.

**The echo floor could not be inherited.** `deletion-guard.js` rejects a candidate when more than
**2** consecutive recovered words already appear nearby, and that is right for its probe, which is a
clause of 3–10 words. This probe is a whole window of 20–35 words, where an ordinary English 3-gram
collides with any neighbouring sentence — measured, at the 8 s window: a floor of 2 rejected two
genuine synthetic substitutions on a 3-word coincidence, 12/16 against 14/16 for every floor from 3
to 6. The shipped floor is 4.

---

## 4. The sweeps, all against both corpora at once

| `windowSpeechSec` | 8 | 6 | 5 | **4** | 3 |
|---|---|---|---|---|---|
| reference-corpus recall | 2/12 | 3/12 | 5/12 | **10/12** | 9/12 |
| candidates on 92 clean minutes | 2 | 3 | 4 | **4** | 15 |
| % of detected speech analyzed (`me` / `others`) | 74 / 94 | 83 / 97 | 87 / 98 | **91 / 99** | 94 / 99 |

| `minDeficitWords` | **0** | 1 | 2 | 4 |
|---|---|---|---|---|
| reference-corpus recall | **10/12** | 7/12 | 4/12 | 0/12 (measured at the shipped 4 s window) |
| candidates on 92 clean minutes | **4** | 3 | 2 | 1 |

| `maxWindowSec` | 12 | 16 | 20 | **30** | 45 |
|---|---|---|---|---|---|
| candidates on 92 clean minutes | 7 | 6 | 5 | **4** | 5 |
| speech analyzed, seconds | 2,861 | 3,141 | 3,274 | **3,402** | 3,501 |

| `maxEchoWords`, at the 8 s window | 2 | **3–6** | 8 |
|---|---|---|---|
| surgical-control recall | 12/16 | **14/16** | 15/16, by readmitting a span whose recovered sentence genuinely recurs seven words long beside it |

At the shipped 4 s window the contiguous echo arm is less load-bearing than it was — 15/16 at a
floor of 2 and 16/16 at every floor from 3 to 12, with the clean corpora unaffected across that
whole range because the **in-order ratio arm** catches those cases instead. That is why both arms
exist, and it is measured rather than argued. 4 is inside the plateau on both configurations.

---

## 5. False-positive behaviour, stated as a measurement

| test | result |
|---|---|
| 92 minutes, both channels, shipping decode | 516 windows, 4 candidates, **0 findings** |
| the 4 candidates, individually | 3 `matches-audio` (one is the corpus's loudest burst, which is laughter, returning 1 informative word), 1 `echoed` (16 consecutive words already in the transcript beside it) |
| invented reference corpus, 12 channels | 112 windows, 2 candidates, **0 findings** — both `echoed` at 8 and 11 consecutive words, and the reference confirms both turns were transcribed correctly |
| candidate rate on clean material | 6 in 628 windows — **0.96%** |
| finding rate on clean material | **0 in 628 windows** |
| positive control fires in the same runs | 16/16 and 10/12 |

An instrument that flagged everything would not be an instrument; an instrument that never fires is
not one either. Both halves are in the table.

---

## 6. What it can and cannot see

**Can:** a ≥ 4 s stretch of loud, physically detected speech carrying at least one word but far
fewer than the audio holds, where the same model recovers substantially more, stable, locally-novel
words from that stretch alone — on either channel, anywhere in a 92-minute file.

**Cannot** — enumerated in the module header rather than discovered later:

- **Whether the words present are WRONG.** Equal-length substitution — a sentence replaced by a
  different sentence of the same length — is invisible to this instrument and to every other
  instrument in this pipeline. Only a reference transcript, or a second model, can see it.
- **Substitution that ADDS words.** A density *surplus* is the repetition guard's ceiling; where the
  fabricated text does not repeat, nothing sees it.
- **Anything shorter than the window.** Measured at turn scale: 2 of 12.
- **Speech below the burst floor**, and **stretches too sparse in wall time to form a window** —
  `analyzedSpeechSec` against `burstSeconds` says how much was examined, every run.
- **A span the model also refuses in isolation.** No single-model method can see it.
- **THE DIFFERENCE BETWEEN "LOST HERE" AND "PRESENT AT THE WRONG SECOND", AT LONG RANGE — and this
  one is not a caveat, it is a result.** See §7.

## 7. The result that argues against the instrument, and the control that rescues it

On the `-mc -1` artifact the instrument produced 8 findings. Every one is loud (−5.5 to −10.4 dBFS
against a −0.9 dBFS peak), every one re-decodes to 12–27 informative words against 2–7 in the
transcript, and a second inspection pass proved the repetition guard took nothing at those spans —
**the model itself never emitted those words at those seconds**, on the raw pre-guard decode.

And every one of the 8 recovered sentences occurs verbatim **elsewhere** in the same 92-minute
transcript, at contiguous runs of 5 to 35 words.

The obvious conclusion is that all 8 are long-range timing defects, and that the ECHO condition
should be widened from "nearby" to "the whole transcript". **The control says otherwise, and this is
the single most useful measurement in this brief.** Run the same whole-transcript test against the
16 surgical findings — spans where words were provably removed, by me, from a transcript I still
have — and **6 of the 8 on the `others` channel match 11 to 20 consecutive words elsewhere too.** A
whole-transcript echo condition would therefore delete more than a third of the detections it is
known to be right about.

The reason is the material: this is a webinar in which the speaker genuinely re-delivers whole
sentences, which is why the CEO ruled retake de-duplication out of scope in the first place. On
material like this, text matching elsewhere is **not** evidence that the words at this second are
present.

So the honest statement about those 8 is: the audio there holds words the transcript does not, at
that second; whether they are lost or merely misplaced **cannot be decided without a reference**,
and the whole-transcript test cannot decide it either — demonstrated, not assumed. The instrument
says the first thing and refuses the second, which is exactly what its verdict noun claims. On the
`q5_0` artifact 1 of 3 findings is unambiguous by the same test: its recovered words appear **nowhere
in the 92-minute transcript**.

## 8. Every check run RED by breaking the shipped source

A green suite proves nothing on its own. Each of 24 mutations removes or inverts ONE load-bearing
behaviour of `substitution-guard.js`; the whole suite runs against each; **all 28 new tests went red
at least once, and every one of the 24 mutations was caught by at least one test.** `norm-substitution-density-2026-08-30-assets/tools/mutate.py` re-runs the battery and fails
if any test survives every mutation. The list, by what each breaks:

| mutation | what it breaks |
|---|---|
| M1 / M19 | the window target (40 s; never stopping at the target) |
| M2 | the wall cap — a denominator made of silence |
| M3 | condition 2 — a wordless window becomes this stage's too |
| M4 / M5 | condition 3 — `min` inverted to `max`; the floor raised above every real delivery |
| M6 / M7 / M8 / M9 | conditions 4, 5 (recovery), 5 (stability), 6, each deleted |
| M10 | probe words counted raw instead of distinct-informative — laughter recovers |
| M11 | `excludeSpans` ignored — a confirmed deletion inflates this stage |
| M12 / M23 | the channel-level answer: hard-wired false; its warning removed |
| M13 / M16 | the offset tiling removed; overlapping candidates no longer collapsed |
| M14 / M18 / M22 | the three ways "never looked" could come to read as "clean" |
| M15 | the warning drops its refusal to claim the words present are wrong |
| M17 / M24 | `analyzedSpeechSec` overstates the instrument's own coverage; `wordlessWindows` hidden |
| M20 | the final verdict inverted |
| M21 | the echo floor returned to the deletion detector's clause-sized 2 |

## 9. Two findings about neighbouring work, neither of them mine to decide

1. **The deletion detector's published `-mc -1` figure was measured PRE-GUARD, and the pipeline sees
   more.** Scored on raw segments it is 16 spans / 37.1 s on `me`, reproduced here exactly. Scored on
   the POST-repetition-guard segments the pipeline actually hands it, the same artifact gives **28
   spans / 80.6 s**, because the guard's own removals open new wordless bursts. **On the shipping
   decode it makes no difference** (2.2 s either way, verified), so nothing that ships is affected —
   but the two numbers describe different things and only one of them is what the product reports.
2. **On the `q5_0` catastrophe, a quarter of the analyzed windows carry no word at all** after the
   guard collapses the fabricated loop. That is stage 3.7's class, correctly excluded from this
   stage — which means this stage's own findings *understate* the damage by construction. The new
   `windowsBelowFloor` / `wordlessWindows` counts exist so that cannot be misread.

## 10. Open questions for the CEO, none of them decided here

1. **Default on or off.** It ships **on** (`RICHOS_SUBSTITUTION_GUARD=off` disables it), because a
   detector that is off protects nothing. The price is in §0(f).
2. **The probe budget.** `maxProbes` is 20 per channel. On a healthy 92-minute recording only 4
   candidates exist in total, so the cap never binds; on the `-mc -1` artifact it left 15 windows on
   `others` UNPROBED — reported honestly as "not claimed and not cleared", never as clean.
3. **Turn-scale sensitivity.** 2 of 12 lost turns are invisible because a turn is shorter than the
   smallest window over which a rate means anything. Closing that needs a different instrument, not
   a smaller number.
4. **Timestamp accuracy as its own alarm** — raised by the deletion detector's brief and reinforced
   here: 22 of this instrument's 30 rejections across every artifact were `echoed`, i.e. words
   present at the wrong second. Still nobody measures that as a defect class.

## 11. Reproducing it

`norm-substitution-density-2026-08-30-assets/` — `tools/` regenerates every number from the
gitignored audio (repoint `SP`); `results/` holds every scored report **with all speech redacted**,
the sweeps, the controls, the reference-corpus tables and the mutation battery's output. The
reference corpus rebuilds anywhere with `say` from `corpus/calls.json`.

Not committed (regenerable, or private by construction): the four whisper JSONs, the normalized
channels, every probe clip, and the probe caches.
