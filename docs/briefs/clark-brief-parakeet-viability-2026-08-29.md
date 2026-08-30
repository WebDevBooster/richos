# NVIDIA Parakeet for RichOS call transcription — a viability verdict

**Author:** Clark (Senior Researcher). **Date:** 2026-08-29.
**Requested by:** Rich, on behalf of the CEO, who asked directly: *"what about NVIDIA's Parakeet?"*
**Base:** richos `main` @ `290560a` (the commit carrying Norm's 92-minute real-audio measurement).
**Scope:** a viability verdict for **RichOS specifically** — architecture, Apple-Silicon runnability,
license, pipeline fit, language coverage.

**This is desk research. Nothing was installed, downloaded or benchmarked.** Every number below is
somebody else's measurement, attributed to its source, with its hardware named. There is **no
RichOS measurement of Parakeet anywhere in this brief**, and none should be inferred. §8 says
exactly what the missing measurement is and what it would cost.

`data-contract-bypass`: research brief only. No Avelor/fitapp app was built, installed, rendered or
tested; nothing touched an emulator, simulator or device; no model was downloaded or run.

---

## 0. Verdict

### VIABLE LATER — and "later" is one measurement away, not one quarter away.

Every gate that could have killed it is clean. The license is plain CC-BY-4.0 with no appended
term (§5). The Apple-Silicon path exists, is actively maintained, and is measured at 110–210×
realtime on an M4 Pro (§4). Word and segment timestamps, punctuation and capitalization are all
present, and our per-channel design needs no diarization (§6). English is covered by two model
versions (§7). The architectural claim the CEO is asking about is **real**: the specific failure
Norm measured — a decoder writing 709 copies of one phrase over 18 minutes of real speech — is
**structurally impossible** in a transducer, and not merely less likely (§1).

### The single fact that decides it

**Parakeet cannot commit the failure we measured, but it can commit a failure we cannot see.**

Its characteristic failure mode is not fabrication — it is **silent, high-confidence deletion**. In
the cleanest documented case, a 20-second clip with a clear 7.5-second English opening decoded to
*only* the Spanish half; the entire English opening vanished, with **no error, no low-confidence
signal, no tokens — and a reported confidence of 0.993** (FluidAudio [#850], deterministic 3/3,
Apple M3 Max, closed as a real defect). The truncated audio decoded perfectly, so the audio was
never the problem.

That matters more for RichOS than for anyone else, because of what we have built. `repetition-guard.js`
exists, fires, alarms, and writes a plain-English warning into `verification.json`. **Every class it
knows is a fabrication class.** A model that deletes rather than invents produces a transcript that
is short, fluent, internally consistent, and silently wrong — and our entire detection apparatus
returns green. Norm's 92-minute run already flagged this shape of blindness in passing: his
corrupted-timeline metric "only sees loop-shaped corruption, not content the model silently
dropped" (`norm-brief-real-audio-92min-2026-08-29.md` §4.2). Parakeet would make the invisible
class the *dominant* class.

So the honest position is not "Parakeet is better" or "Whisper is better". It is: **Parakeet trades a
loud failure we can detect for a quiet failure we currently cannot.** That trade is probably still
worth making — a model that drops 2% of a call beats one that replaces 44% of a channel with a
single phrase — but it is a trade, and it comes with a build item (a coverage/deletion detector,
§8.3) that does not exist yet and is not optional.

### Not recommended on architecture alone

Per the CEO's own standing instruction, and I agree with it: **do not replace Whisper on the strength
of §1.** The comparison that decides this is Parakeet against our own 92-minute corpus, and that
measurement does not exist. §8 specifies it. It is roughly a day of one engineer's time and it
should be run alongside a control that costs almost nothing (§8.2).

---

## 1. The hallucination claim — is the architectural difference real?

**Yes, and it is more specific than "different shape".** Three independent mechanisms, only one of
which is the one usually cited.

### 1.1 What actually happened to us

Whisper is an attention encoder-decoder. Its decoder is autoregressive **over text**: it generates
token *t* conditioned on tokens 1…*t*−1, and it decides for itself when to stop. Output length is
not bounded by input length. When the acoustic evidence is weak, the language-model prior dominates
and the decoder emits fluent, plausible, false text — the standard account, and the one Norm's
isolated-clip control proved on our own audio (`norm-brief` §4.3: identical model, identical decode
parameters, correct transcript on the 65-second clip and 47 copies of "okay" inside the 92-minute
file).

The amplifier is specific and it is ours: whisper.cpp's `-mc -1` default, which our `turbo` and
`quantized` tiers both ship (`decodeArgs: []` in `MODEL_TIERS`), **carries the previously decoded
text forward as the prompt for the next 30-second window**. A degenerate loop that starts in window
*k* is fed back into window *k*+1 as context and self-sustains. That is how a loop reaches 1,099
seconds. It is not a property of hard audio; it is a feedback path.

### 1.2 Why a transducer cannot do that

Parakeet TDT is a FastConformer encoder with a Token-and-Duration Transducer decoder
([model card][mc-v3]; architecture [Rekesh et al. 2023][fastconformer], decoder [Xu et al., ICML
2023][tdt]). Three structural facts, in order of how much they matter:

1. **The alignment is monotonic and time-bounded.** The decoder walks encoder frames forward and
   never backward. Frames are exhausted, and then it stops. There is no "generate until EOS" mode
   in which the model chooses its own output length — the audio chooses it. **A 92-minute file
   cannot yield 18 minutes of invented text, because there are no frames to hang it on.**
2. **The inner emission loop is explicitly capped.** A transducer may emit several tokens at one
   frame before advancing. Implementations bound this with `max_symbols_per_step`, whose documented
   purpose is precisely "to avoid infinite loops" ([SpeechBrain transducer decoder][sb]). TDT goes
   further: it predicts a *duration* and skips frames, so the pathological "stall on one frame"
   state is harder to enter and cheaper to leave — the mechanism behind the paper's 2.82× speedup
   ([Xu et al.][tdt]).
3. **In every Apple-Silicon runtime, decoder state resets at each chunk boundary.** parakeet-mlx
   chunks at 120 s with 15 s overlap; FluidAudio's batch path uses overlapping 15 s windows merged
   on a 2 s overlap. **No text and no label history crosses a chunk boundary in any of them.** This
   is the exact inverse of whisper.cpp's `-mc -1`. Even if a degenerate state formed, its blast
   radius would be one chunk — seconds to two minutes — not the remaining 18 minutes of the file.

The pure-CTC variants are stronger still: CTC emits a distribution per frame conditionally
independent of all other output. There is no label history at all, so there is nothing to loop on.

### 1.3 The published measurement

The cleanest architecture-level number I found is from **Calm-Whisper** (Interspeech 2025). On
UrbanSound8K — pure non-speech, where the correct output is empty and *any* text is a hallucination:

| model | hallucination rate on non-speech |
|---|---|
| Whisper large-v3 | **99.97%** |
| Conformer-CTC-large | **13.52%** |

with 55.2% of Whisper's outputs being the single word *"so"* ([Wang et al. 2025][calm]).

**Read that carefully, because it argues both ways.** A ~7× reduction is enormous and it is the
architecture doing the work. But 13.52% is **not zero**. The encoder-only model still put text over
pure noise in one clip in seven. "Structurally cannot free-run" is a much weaker and much more
accurate claim than "does not hallucinate", and anyone who tells the CEO the second thing is
overselling it. Note also that this measures *Conformer-CTC*, not Parakeet-TDT — a transducer sits
between CTC and Whisper on the label-history axis, so I would expect it between them on this metric
too. **I found no equivalent published number for Parakeet TDT on non-speech, and I am not
estimating one.**

---

## 2. Parakeet's own characteristic failure modes

Every architecture has some. Naming them is the whole point of a fair comparison. These are all
open or recently-closed defects on primary trackers, not speculation.

### 2.1 Silent deletion — the dominant class, and the dangerous one

- **[FluidAudio #850][fa850]** (closed, 2026-08-11, M3 Max, `parakeet-tdt-0.6b-v3-coreml`): a 20.3 s
  clip, 7.5 s of clear English then 12 s of Spanish, decodes to **only the Spanish**. The English
  opening is deleted entirely — no error, no tokens, **confidence 0.993**. Byte-identical output
  3/3 runs across four configurations. Truncated to 8.2 s, the same audio decodes the English
  perfectly. Chunking, seams and language hints were all ruled out by the reporter.
- **[NVIDIA-NeMo/Speech #15757][nemo15757]** (OPEN, assigned to a maintainer): `parakeet-tdt-0.6b-v3`
  transcribes a 2.2 s speech segment correctly, but **the same segment with 400 ms of trailing
  silence appended decodes to an empty string.** Cause: the silence is treated as valid audio and
  changes the per-utterance log-mel normalization. Relevant to us: our channels are 44.2% "neither
  speaker active" (`norm-brief` §6), so silence-adjacent segments are the normal case, not an edge
  case.
- **[FluidAudio #865, #838][fa865]**: pause-delimited speech spans decoding to all-blank; an isolated
  short word silently decoding to blank, with the outcome controlled by the *preceding* audio.

**This is the class RichOS is blind to.** It is the reason §0's verdict is what it is.

### 2.2 Repetition amplification — yes, it still exists

The transducer's prediction network *is* autoregressive over emitted labels, so a repeated-token run
is possible inside its bounded budget. Reported in practice: saying "no no no no no" can transcribe
as more "no"s than were spoken; **[FluidAudio #855][fa855]** (OPEN) documents seam phantoms inserted
**on repetitive speech** specifically. Given that our corpus is a retake session where a human says
the same 35-word sentence three times running (`norm-brief` §5.3), this is *directly* on our
material and must be in the measurement's scope.

### 2.3 Beam-search instability — avoidable, and the avoidance is free

- **[sherpa-onnx #3267][sherpa]**: NeMo TDT under `modified_beam_search` hallucinates or returns
  empty ~20% of the time, non-deterministically on the same file; **greedy decoding on the same
  audio is fine.**
- **[parakeet.cpp #61][pk61]** (OPEN): TDT beam search fails above ~40–90 s of audio; greedy is fine.

Both are decoder-implementation bugs, not architecture. **Operational conclusion: use greedy decode.
Greedy is also the default everywhere.** This is a settings note, not a risk.

### 2.4 Multilingual cross-talk in v3

**[FluidAudio #842][fa842]** (closed): spontaneous Spanish decoded through an English lexicon, and
the reporter attributes it to **upstream model behavior, not the CoreML port**. The window-global
language state in the multilingual v3 is also the mechanism behind #850 above. **The English-only
v2 does not have this failure mode and is also more accurate on English** (§7).

### 2.5 Noise

NVIDIA publishes its own degradation curve, and it is not flat. `parakeet-tdt-0.6b-v3`: **11.66%
average WER at 0 dB SNR**; `v2`: 6.95% at SNR 10 rising to **20.26% at SNR −5** ([model cards][mc-v3]).
Both cards state the model "is not recommended for word-for-word transcription... accuracy depends
on the context of speech". Real calls are noisier than FLEURS.

### 2.6 What long-form evidence actually exists

This is the question that matters most and the answer is thinner than I would like.

**The Open ASR Leaderboard now has a long-form track** ([Hugging Face, 2025-11-21][hfblog]; paper
[Srivastav et al.][oaslpaper]). It defines long-form as anything over 30 s and evaluates on
Earnings21 (39 h), Earnings22 (119 h) and TED-LIUM v3 — Earnings21 averages roughly 50 minutes per
file, which is the closest published regime to our 92 minutes. Results:

| model | long-form avg WER | RTFx |
|---|---|---|
| OpenAI Whisper large-v3 | **6.43%** | 68.56 |
| NVIDIA Parakeet CTC 1.1B | 6.68% | **2793.75** |
| NVIDIA Parakeet TDT 0.6B v2 | 6.91% | 955.87 |

**Whisper wins on long-form WER.** Parakeet is 0.25–0.48 points worse and 14–41× faster. The paper's
own summary: NVIDIA's CTC and TDT models "significantly improve throughput with only moderate losses
in quality". Two things I must be explicit about: **the paper contains no discussion of
hallucination, repetition looping or deletion**, so it cannot adjudicate the failure-mode question
at all — and a WER that averages over a 39-hour corpus will happily hide a catastrophic single file
inside an otherwise good average, which is exactly the shape of our defect. **This table is evidence
about accuracy, not about robustness, and it should not be read as the latter.**

The one piece of architecture-level long-form evidence, and it is from NVIDIA's own group, cuts
*against* the version we would pick: **"CTC-based models are more robust and efficient than RNNT on
long form audio"** ([Koluguri et al. 2023][longform], evaluated on Earnings21/22, CORAAL,
TED-LIUM 3). TDT is in the RNNT family. If our 92-minute measurement shows TDT misbehaving at
length, `parakeet-ctc-0.6b` / `parakeet-ctc-1.1b` are the documented next move — both are supported
by parakeet.cpp today, and both are English-only.

**Honest bottom line for §1: the architectural difference is real and it does eliminate the specific
709-repetition failure class. It does not make the model robust in general, and no published source
measures Parakeet's failure behavior at 60+ minutes on real conversational audio. That gap is why
the verdict is "later" and not "now".**

---

## 3. What we would be replacing

For calibration, from `norm-brief` §4.1, measured on the CEO's own Mac mini M4 (24 GB):

| | wall time, 92 min | realtime factor | peak RSS | worst fabricated span |
|---|---|---|---|---|
| `large-v3-turbo` | 441–525 s | 0.080–0.095 (≈11×) | **2.83 GB** | 290 s |
| `large-v3-turbo-q5_0` | 469–512 s | ≈11× | 1.76 GB | **1,099 s (44.1% of a channel)** |

Any Parakeet path is 10–20× faster than this and uses less memory. **Speed is not the reason to
consider Parakeet and should not be the reason we adopt it** — 5 minutes per call-hour is already
fine for a post-call pipeline. Correctness is the only reason.

---

## 4. Apple Silicon, local, offline — the constraint the CEO called decisive

RichOS is a local-first Tauri desktop app. Nothing may depend on a cloud API or an NVIDIA GPU.
NeMo itself (PyTorch/CUDA, Apache-2.0, and NVIDIA's own card lists only NVIDIA datacenter GPUs and
"Linux preferred") is **not a candidate for the shipping product**. But three independent
Apple-Silicon runtimes exist, and the CEO's premise that this is where it dies turns out to be
wrong — the path exists and is maintained. The question is *which* path, and each has a distinct
disqualifier.

### 4.1 parakeet.cpp — architecturally the perfect fit, and today the one that cannot do the job

[`mudler/parakeet.cpp`][pkcpp] — **MIT**, C++17 on ggml, from the LocalAI team. It is the exact
analogue of whisper.cpp: GGUF weights, `-DPARAKEET_GGML_METAL=ON`, **pre-built `macos-arm64/metal`
binaries on every release**, `--json` output with per-word timestamps and confidence, stdin input,
no Python at inference. Our `config.js` already resolves external binaries by env override → PATH →
well-known dirs, so swapping `whisper-cli` for `parakeet-cli` is a `resolveBinary` call plus a new
parse function. It claims **WER 0 vs NeMo** — byte-identical transcripts — on every published
checkpoint, and covers CTC, RNNT, TDT and hybrid in 110M/0.6B/1.1B.

**And it currently fails above about five minutes of audio.**

[Issue #55][pk55] (OPEN since 2026-07-26): a 10-minute file requests a **16.7 GB** compute buffer and
crashes; 5 minutes works. A maintainer-adjacent commenter measured the growth curve **on Apple
Silicon** — M2, `ctc-1.1b-q8_0`, Metal, resident-set growth over a load-only baseline:

| decode window | additional memory |
|---|---|
| 6 s | +0.02 GB |
| 30 s | +0.07 GB |
| **300 s** | **+2.13 GB** |

Superlinear and steepening, consistent with quadratic attention. Their two conclusions are the
important ones: **quantization does not help** (the reporter was already on the smallest model at
`q4_k` and still needed 16.7 GB — the compute graph dominates, not the weights), and **whisper.cpp's
ability to swallow a 2-hour file comes from chunking internally at 30 s**, so the difference is
*where the chunking lives*, not what the models can do.

Two further Apple-specific defects: [#59][pk59] (OPEN) — model load holds two full copies of the
weights on Metal, **2.93 GB peak for a 1.42 GB GGUF**; and [#44][pk44] (OPEN) — the
`rel_pos_local_attn` path **diverges from NeMo**. That second one is worse than it looks: local
attention is exactly the mechanism NVIDIA prescribes for long audio, so **the WER-0-vs-NeMo parity
claim does not cover the long-audio path we would need.**

Maturity, stated plainly: created 2026-05-28 — **three months old** — 775 stars, v0.5.0, MIT,
extremely active (last push 2026-08-28), but the contributor graph is `localai-bot` (14) + `mudler`
(9) and a long tail of ones. The project's own benchmark doc says: *"Treat it as beta software...
with caution warranted before embedding in customer-facing pipelines."* I would take that at face
value.

**Verdict: the right destination, not a current option.** Revisit when #55 closes, or if we decide to
chunk on our side — which we could, since we already run ffmpeg over every channel.

### 4.2 parakeet-mlx — the cheapest way to get a number, and not a shipping answer

[`senstella/parakeet-mlx`][pkmlx] — **Apache-2.0**, Python on Apple's MLX, `pip`/`uvx` installable,
975 stars. **It chunks internally: `--chunk-duration` 120 s with `--overlap-duration` 15 s by
default**, so a 92-minute file is a supported input today, unlike parakeet.cpp. Outputs txt/srt/vtt/
json with sentence-level and token-level timestamps. Default model is
`mlx-community/parakeet-tdt-0.6b-v3`.

Reported speed, third-party and unverified by me: ~1 hour of audio in ≈53 s; RTF 0.042 on an M4
(≈24× realtime). Model weights are 0.6B, ~500 MB–1.2 GB depending on precision.

Three problems for shipping:

1. **Maintenance is one person and has slowed.** 93 of 100 commits are `senstella`. Last push
   **2026-06-05** (v0.5.2) — nearly three months ago as I write. Not abandoned; not a dependency I
   would put under a product.
2. **A reported break against current MLX.** [#49][mlx49] (OPEN since 2026-02-12) reports
   `transcribe_stream()` failing on `mlx==0.30.6` because `axis` can no longer be passed as a
   keyword to `mx.concat`. I checked master directly: the calls are **still there** —
   `parakeet.py:1004`, `parakeet.py:1025`, `audio.py:146`, `conformer.py:293` — and `audio.py:146`
   is in the pre-emphasis path used by **file transcription, not only streaming**. `pyproject`
   pins `mlx>=0.22.1` with no upper bound, so a fresh install pulls **mlx 0.32.2** (2026-08-25).
   **Correction to the issue's own diagnosis, which I verified:** `mx.concat` has *not* been
   removed — it is still documented in MLX 0.32.2 as an alias for `concatenate`. The reported
   failure is the keyword-argument binding, not the function. **I did not run it, so I report this
   as a live, unresolved risk that a 10-minute install would settle, not as a confirmed break.**
3. **An open correctness defect in exactly the path we would depend on.** [PR #54][mlx54]
   (OPEN since 2026-06-07, unmerged) fixes chunk-overlap merging producing token sequences whose
   text order does not match their timestamp order, breaking
   `sentence.text == "".join(t.text for t in sentence.tokens)`. Our merge stage interleaves two
   channels **by timestamp** (`merge.js`), so timestamp integrity is load-bearing for us, not
   cosmetic. Related closed history: #43 (a 15-second timestamp jump causing sentence loss), #10
   (missing words in subtitles).

**Verdict: use it for the measurement in §8, not for the product.** It is the fastest route from
here to a number on our corpus, and that is genuinely valuable.

### 4.3 FluidAudio — the maintained one, and the one with real published Apple numbers

[`FluidInference/FluidAudio`][fa] — **Apache-2.0**, Swift, CoreML on the **Apple Neural Engine**.
2,706 stars, v0.15.6 (2026-08-19), last push 2026-08-23, an issue tracker in the high 800s with
maintainers closing defects within days. This is a properly maintained project, by a wide margin the
most maintained of the three.

Its own published benchmarks (2024 MacBook Pro, M4 Pro, 48 GB, `parakeet-tdt-0.6b-v3-coreml`):

| benchmark | result |
|---|---|
| LibriSpeech test-clean | **2.5% avg WER**, overall **155.6× realtime** |
| FLEURS English (US) | 5.4% WER, 207× realtime |
| FLEURS 24-language average | 14.7% WER, 210× realtime |
| v2 (English-only) LibriSpeech test-clean | **2.1% avg WER**, 145.8× realtime |
| README headline | 1 hour of audio in ~19 s on M4 Pro |

**Long audio is handled by design, with bounded memory:** batch mode uses "overlapping 15 s windows
merged on a 2 s overlap", and long files are explicitly *not* skipped. Memory is therefore flat in
file length — which is precisely the property parakeet.cpp lacks. There is a dedicated v3 long-form
code path (issue #869, closed).

Two real costs:

1. **Swift, and no prebuilt binary.** The CLI is invoked as `swift run fluidaudiocli transcribe
   audio.wav`; the releases carry **no binary assets**. Bundling it into a signed, notarized Tauri
   `.app` means adding a Swift toolchain to our build and shipping a second native binary — a
   packaging change, on a product whose signing story is already a v1 blocker
   (`wiki/packaging-and-signing.md`).
2. **A punctuation caveat I could not resolve.** FluidAudio's own benchmark doc describes TDT v3 as
   "multilingual, no punctuation" and says its English-only Unified model "wins on WER, throughput,
   **and punctuation**". NVIDIA's card claims automatic punctuation and capitalization for v3.
   These may simply be describing a WER harness that strips punctuation, or a genuine gap in the
   CoreML port. **I could not determine which, and it is a five-minute check for whoever runs §8.**

**Verdict: the strongest production candidate today, at the price of a Swift binary in the bundle.**

### 4.4 The Apple-Silicon summary

| | parakeet.cpp | parakeet-mlx | FluidAudio |
|---|---|---|---|
| License (code) | MIT | Apache-2.0 | Apache-2.0 |
| Runtime dependency | **none** (C++/Metal binary) | Python + MLX | Swift + CoreML |
| Prebuilt macOS arm64 binary | **yes** | n/a (pip) | **no** |
| Handles 92 min today | **NO — fails ~5 min** | yes (120 s chunks) | yes (15 s windows) |
| Memory in file length | **quadratic** | bounded | bounded |
| Maintenance | 3 months old, 1 dev + bot | 1 dev, 3 months idle | **active, many contributors** |
| Fit to our `resolveBinary` seam | **perfect** | good (CLI + JSON) | needs a bundled binary |
| Best use | future production | **the §8 measurement** | production today |

**The CEO's premise — "a model we cannot run locally on the Mac is disqualified" — does not fire.
Parakeet runs locally on Apple Silicon, offline, today, in two of three runtimes.** The constraint
that actually bites is a different one: no single runtime is simultaneously dependency-free,
mature, and proven at our file length. That is a sequencing problem, not a disqualification.

---

## 5. License — the hard v1 gate

`open-source-strategy.md` makes the license a hard v1 gate, and we were burned before by S1-mini's
appended attribution term. I checked the model card source directly rather than a summary.

**Model weights: CC-BY-4.0, and that is the whole of it.** From
`nvidia/parakeet-tdt-0.6b-v3/README.md`, verbatim and complete:

> **GOVERNING TERMS:** Use of this model is governed by the
> [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode.en) license.

The card states the model "is ready for commercial/non-commercial use", Deployment Geography
"Global", and lists Licensing again in its trustworthiness table as the same single CC-BY-4.0 line.
Use-Case Restrictions: "Abide by CC-BY-4.0". **There is no second license, no appended attribution
clause beyond CC-BY's own, no NVIDIA-specific open-model license, no acceptable-use rider, no field-
of-use limit.** `parakeet-tdt-0.6b-v2` carries the identical single term. This is materially cleaner
than the S1-mini situation.

CC-BY-4.0 does impose a real, ongoing obligation: **attribution, a link to the license, and an
indication if changes were made.** For an open-core product that ships, that is a NOTICE entry
naming NVIDIA and the model, and — if we ever ship converted weights (GGUF, CoreML, MLX) — a
statement that the weights were converted. It is not copyleft; it does not reach our source code.

**Inference stack:** parakeet.cpp MIT · parakeet-mlx Apache-2.0 · FluidAudio Apache-2.0 · NeMo
Apache-2.0. All compatible with an open-core product under any license we are likely to choose.

**Conversions inherit correctly.** `mlx-community/parakeet-tdt-0.6b-v3`,
`FluidInference/parakeet-tdt-0.6b-v3-coreml` and `mudler/parakeet-cpp-gguf` are all published under
**cc-by-4.0** — I checked each repo's license field directly.

**One trap, flagged because parakeet.cpp advertises it prominently.** parakeet.cpp also supports
`nvidia/nemotron-3.5-asr-streaming-0.6b` (40+ locales, streaming). That model is **not CC-BY-4.0** —
its HF license field is `other`, and parakeet.cpp's own table names it **OpenMDW-1.1**.
`nvidia/parakeet_realtime_eou_120m-v1` is likewise `other`. **If anyone reaches for a "newer, better"
NVIDIA model, the license gate must be re-run from scratch.** Do not let "it's the same family"
carry a license claim.

**§5 verdict: PASSES the v1 gate for `parakeet-tdt-0.6b-v2` and `-v3` and for all three inference
stacks. The only work item is a NOTICE file.**

---

## 6. Feature parity with what our pipeline actually needs

I read our pipeline rather than assuming it.

| our requirement | source | Parakeet |
|---|---|---|
| **Segment timestamps** — `parseWhisperJson` reads only `offsets.from` / `offsets.to`; `merge.js` interleaves the two channels by those offsets | `transcribe.js:24-34`, `merge.js` | **Yes.** The card advertises char, word and segment timestamps. parakeet.cpp emits per-word start/end + confidence in `--json` at 0.08 s frame resolution, matching NeMo exactly. parakeet-mlx emits sentence + token timestamps. **Our bar is the lower one** — we do not currently use word timestamps at all. |
| **Punctuation + capitalization** | consumed downstream by loro correction | **Yes** per the model card ("Automatic punctuation and capitalization"). One unresolved caveat on the FluidAudio CoreML port — §4.3. |
| **Per-channel model** — one mono 16 kHz WAV per speaker, `{me, others}` | `normalize.js`, `transcribe.js:transcribeChannel` | **Yes.** All three runtimes take one mono 16 kHz WAV and return one transcript. Parakeet's native input format is 16 kHz mono `.wav`/`.flac` — **identical to our existing `ffmpeg -ac 1 -ar 16000` normalize step. No pipeline change.** |
| **Diarization** | `diarize.js` defaults to `method: 'none'` | **Not needed, and I am saying so explicitly rather than leaving it ambiguous.** We record one speaker per track; Norm measured zero cross-talk bleed (idle channel at its own noise floor, envelope correlation −0.176), so the `{me, others}` assumption holds physically. Parakeet has no built-in diarization and **this costs us nothing.** FluidAudio bundles diarization separately if we ever want the multi-remote-speaker case that `diarize.js` documents as a seam — a bonus, not a requirement. |
| **Binary invoked as a subprocess** | `resolveBinary()` — env override → PATH → well-known dirs | **parakeet.cpp: perfect fit** (prebuilt macOS arm64 Metal binary, `--json`). parakeet-mlx: fine via CLI. FluidAudio: needs a bundled Swift build. |
| **Repetition guard compatibility** | `repetition-guard.js` operates on `{startMs, endMs, text}` | Model-agnostic by construction — it would run unchanged. **But it is the wrong instrument for Parakeet's failure mode** (§0, §8.3). |

**§6 verdict: full parity, with the integration surface smaller than expected — a new `resolveBinary`
target and a ~15-line replacement for `parseWhisperJson`. Everything downstream of `transcribe.js`
is untouched.**

---

## 7. Language coverage, and which version it constrains us to

| model | languages | English WER (Open ASR Leaderboard) | released |
|---|---|---|---|
| `parakeet-tdt-0.6b-v2` | **English only** | **6.05%** avg, RTFx 3386 | 2025-05-01 |
| `parakeet-tdt-0.6b-v3` | **25 European languages** (incl. English, German, French, Spanish, Swedish, Russian, Ukrainian) | 6.32% avg, RTFx 3332.74 | 2025-08-14 |
| `openai/whisper-large-v3-turbo` — what we run now | 99 languages | **7.83%** avg, RTFx 200.19 | — |

The v3 figures are from NVIDIA's own `.eval_results/open_asr_leaderboard.yaml` in the model repo,
the most primary source available: `mean_wer` 6.32, `rtfx` 3332.74, `earnings22_wer` 11.19,
`ami_wer` 11.39, `librispeech_clean_wer` 1.92.

Three consequences, stated plainly:

1. **On English, both Parakeet versions beat our current default on the leaderboard** — 6.05% / 6.32%
   against turbo's 7.83%. **This is short-form leaderboard WER on read and semi-prepared speech. It
   is not our audio and it is not our length**, and §2.6 shows the ordering *reverses* on the
   long-form track. Do not quote the 6.05 vs 7.83 gap as if it predicted our corpus.
2. **v3 costs coverage relative to Whisper.** 25 European languages versus 99. **No Japanese, no
   Mandarin, no Arabic, no Hindi, no Turkish, and no translation capability at all.** For a CEO
   taking calls in English and European languages this is a non-issue; the day a Japanese call
   arrives it is a hard wall, and the fallback would be keeping Whisper installed for that case.
3. **For our English corpus, v2 is the better choice on two counts** — 0.27 WER points better, and
   it structurally cannot commit the multilingual window-language failure of §2.4/#850, which is the
   single most alarming defect in this brief. **v2 is what I would measure first.** Measure v3
   second, to price the multilingual option honestly.

---

## 8. What would actually decide this

**The comparison that decides it is Parakeet against our own 92-minute corpus, and that measurement
does not exist.** Here is exactly what it takes.

### 8.1 The measurement

The corpus, harness and method already exist and were built for precisely this — Norm's
`tools/` set at `norm-brief` §8 (isolated-burst decoding, physical silence-burst structure,
`repguard.mjs` running the shipped guard, the 24-window controlled false-positive test). **None of
it is Whisper-specific except the decode command.** Swap `whisper-cli` for `uvx parakeet-mlx`, keep
everything else.

Run over the same two channels of the same 92-minute recording, at greedy decode (§2.3):

1. `parakeet-tdt-0.6b-v2` (English-only — the primary candidate)
2. `parakeet-tdt-0.6b-v3` (to price multilingual)
3. optionally `parakeet-ctc-0.6b` (§2.6's hedge, if TDT misbehaves at length)

**The five numbers that decide it:**

| # | question | how it is answered |
|---|---|---|
| 1 | **Coverage.** What fraction of real speech time produces *no* transcript? | Norm's `silencedetect` burst structure is model-free ground truth. Every burst with no overlapping segment is a candidate deletion. **This is the number that matters most and Whisper was never scored on it.** |
| 2 | **Fabrication.** Does any span of the output sit over silence or over different speech? | `repguard.mjs`, unchanged, over the Parakeet transcripts. Expect near-zero; a non-zero result is the most interesting possible outcome. |
| 3 | **Retakes.** Are the 40+ genuine repeated deliveries preserved, or collapsed/amplified? | The eight known false-positive spans from `norm-brief` §5.1 have per-burst isolated-decode ground truth already established. Direct comparison, no new adjudication needed. |
| 4 | **Length behavior.** Does quality decay across the 10-minute buckets? | Norm's `decay.mjs` bucket table, rerun. Whisper's `q5_0` hit 95–100% corrupted in the last 30 minutes; a flat Parakeet curve is the headline result. |
| 5 | **Cost on the CEO's actual machine.** Wall time and peak RSS at 92 minutes. | `/usr/bin/time -l`, same as the four Whisper runs, so it is directly comparable to 2.83 GB / 441–525 s. |

**Still no WER**, and none should be reported — there is still no human-verified reference
transcript for this audio. Coverage and fabrication are measurable without one; accuracy is not.

**Cost: roughly one engineer-day**, most of it wall-clock waiting. The harness is written, the
corpus is on disk, the adjudication ground truth for the hard spans already exists.

### 8.2 Run the free control at the same time

Whisper's `max` tier already carries `-mc 0` — **no conditioning on previously decoded text**, the
exact feedback path §1.1 identifies as the amplifier. `norm-brief` §7 lists it as explicitly
unmeasured: *"`-mc 0` was never run over a full 92-minute file and no such claim is made."*

**Run `large-v3-turbo -mc 0` over the same two channels.** It is one flag, zero new dependencies,
zero new licenses, and it isolates how much of our catastrophe is the feedback path versus the
architecture. If `-mc 0` alone collapses the 44.1% corruption to near zero, the cheapest fix in this
entire brief is a one-line change to `MODEL_TIERS` and Parakeet becomes an optimization rather than
a rescue. **If it does not, that is the strongest possible argument for the architecture swap.**
Either way we learn something we currently do not know, and the CEO gets a real answer instead of a
migration.

### 8.3 The build item that comes with adopting Parakeet

**A coverage detector.** Not optional, and it should be scoped before adoption, not after.

The good news is that the discriminator is already written and already proven on our audio. Norm's
probe 1 — `ffmpeg silencedetect` at −35 dBFS with a 0.4 s minimum gap — is model-free, physical, and
was decisive on all 72 findings. The `measureVolume` / `silencedetect` seam already exists in
`normalize.js`. The rule is direct: **a speech burst of length *n* seconds with no overlapping
transcript segment is a deletion**, and the pipeline should alarm on it exactly as loudly as
`pipeline.repetitionGuard.unrepaired` alarms today.

Note that this detector is worth building **regardless of which model we ship**, because Whisper
deletes too — Norm's §4.2 metric explicitly cannot see it, and turbo emitted 79 words per minute of
covered time on the `me` channel, "far below human speech". **We have never measured deletion on any
model.** That is a gap in the record, not a Parakeet problem.

---

## 9. What I could not verify, and therefore do not claim

- **Anything about Parakeet on our audio.** Nothing was installed, downloaded or run. Every number
  attributed to a runtime is that project's own published figure on that project's own hardware.
- **The parakeet-mlx / MLX 0.32.2 break.** I confirmed the `mx.concat` call sites still exist in
  master and that `mx.concat` still exists in MLX 0.32.2 as an alias — so the issue's stated root
  cause is partly wrong. Whether a fresh `uvx parakeet-mlx` on mlx 0.32.2 actually fails, I did not
  test. **Reported as a risk, not a fact.**
- **Whether FluidAudio's CoreML v3 emits punctuation.** Its benchmark doc and NVIDIA's model card
  appear to disagree (§4.3). Unresolved.
- **Parakeet's non-speech hallucination rate.** The 13.52% figure is *Conformer-CTC*, not
  Parakeet-TDT. I found no published equivalent for TDT and did not estimate one.
- **Any long-form result for `parakeet-tdt-0.6b-v3`.** The leaderboard long-form track carries v2 and
  CTC-1.1B; I found no v3 long-form number.
- **Whisper large-v3 / turbo `.eval_results` YAML.** Not published in those repos, so the 7.83 /
  200.19 figures are second-hand from the leaderboard rather than from OpenAI's own repo metadata.
  The 6.43% long-form figure IS primary (leaderboard paper Table 5).
- **Peak RAM for any Parakeet runtime at 92 minutes on an M4.** The only Apple-Silicon memory
  measurements I found are parakeet.cpp's (which is the broken path) and a third-party blog claiming
  22 GB of unified memory on an M4 Max. That blog's WER claims are internally inconsistent with the
  leaderboard, so I do not rely on it — but its memory observation corroborates the same quadratic
  mechanism the parakeet.cpp thread measured, from an independent direction, which is why I mention
  it at all. **The bounded-window runtimes (parakeet-mlx, FluidAudio) should not exhibit it. Should.**
- **Model version currency.** I verified against live Hugging Face and GitHub APIs on 2026-08-29:
  `nvidia/parakeet-tdt-0.6b-v3` exists (card modified 2026-08-05, 700k downloads/month) and
  `-v4` **does not exist**. parakeet.cpp v0.5.0 (2026-08-01), parakeet-mlx 0.5.2 (2026-06-05),
  FluidAudio v0.15.6 (2026-08-19), MLX 0.32.2 (2026-08-25). **Every version number in this brief was
  checked live; none is from memory.**

---

## 10. Recommendation

1. **Run §8.2 first — it is free.** `large-v3-turbo -mc 0` over the same 92 minutes. One flag. It may
   make this entire question an optimization instead of a migration.
2. **Run §8.1 in the same pass** — `parakeet-tdt-0.6b-v2` via parakeet-mlx over the same corpus,
   Norm's harness unchanged, scored on **coverage first**. One engineer-day.
3. **Do not adopt on §1 alone.** The architecture argument is real and it is not sufficient.
4. **If the numbers hold, ship on FluidAudio**, not parakeet-mlx (maintenance) and not parakeet.cpp
   (5-minute ceiling) — revisiting parakeet.cpp the moment [#55][pk55] closes, because it is the
   only path with no runtime dependency at all and it drops straight into our existing
   `resolveBinary` seam.
5. **Build the coverage detector (§8.3) either way.** We have never measured deletion on any model,
   and if we move to an architecture whose signature failure IS deletion, we would be swapping a
   defect we can see for one we cannot.

---

## Sources

**Primary — model cards and repository metadata (checked live 2026-08-29):**
- [`nvidia/parakeet-tdt-0.6b-v3`][mc-v3] model card — license, architecture, 25 languages, 24 min
  full attention / 3 h local attention, timestamps, punctuation, 2 GB RAM floor, 11.66% WER at 0 dB
  SNR, release 2025-08-14. Plus its `.eval_results/open_asr_leaderboard.yaml`: `mean_wer` 6.32,
  `rtfx` 3332.74, `earnings22_wer` 11.19, `ami_wer` 11.39.
- [`nvidia/parakeet-tdt-0.6b-v2`][mc-v2] model card — English-only, 6.05% avg WER, RTFx 3386, SNR
  curve 6.95%→20.26%, release 2025-05-01, same single CC-BY-4.0 governing term.
- Hugging Face API license fields for `mlx-community/parakeet-tdt-0.6b-v3`,
  `FluidInference/parakeet-tdt-0.6b-v3-coreml`, `mudler/parakeet-cpp-gguf` (all `cc-by-4.0`) and
  `nvidia/nemotron-3.5-asr-streaming-0.6b`, `nvidia/parakeet_realtime_eou_120m-v1` (both `other`).

**Primary — papers:**
- [Xu et al., *Efficient Sequence Transduction by Jointly Predicting Tokens and Durations*][tdt],
  ICML 2023 — the TDT decoder; frame-skipping, 2.82× faster inference.
- [Rekesh et al., *Fast Conformer with Linearly Scalable Attention*][fastconformer], 2023 — the
  encoder; limited-context attention + global token enabling long-form up to 11 h.
- [Koluguri et al., *Investigating End-to-End ASR Architectures for Long Form Audio
  Transcription*][longform], 2023 — **"CTC-based models are more robust and efficient than RNNT on
  long form audio"**; Earnings21/22, CORAAL, TED-LIUM 3.
- [Wang et al., *Calm-Whisper*][calm], Interspeech 2025 / arXiv 2505.12969 — Whisper large-v3
  99.97% vs Conformer-CTC-large **13.52%** hallucination rate on UrbanSound8K; hallucination defined
  as any non-empty output on non-speech.
- [Srivastav et al., *Open ASR Leaderboard*][oaslpaper], arXiv 2510.06961 — Table 5 long-form:
  Whisper large-v3 6.43% / RTFx 68.56, Parakeet CTC 1.1B 6.68% / 2793.75, Parakeet TDT 0.6B v2
  6.91% / 955.87. Long-form = Earnings21 (39 h), Earnings22 (119 h), TED-LIUM v3.
- [Hugging Face, *Open ASR Leaderboard: new multilingual & long-form tracks*][hfblog], 2025-11-21.
- [Canary-1B-v2 & Parakeet-TDT-0.6B-v3 technical report][techreport], arXiv 2509.14128.

**Primary — issue trackers (the failure-mode evidence):**
- [NVIDIA-NeMo/Speech #15757][nemo15757] — OPEN: v3 decodes empty when 400 ms of trailing silence is
  appended to valid speech.
- [FluidAudio #850][fa850] — mixed-language window deletes the entire English opening, confidence
  0.993, deterministic 3/3, M3 Max.
- [FluidAudio #842][fa842] — spontaneous Spanish through an English lexicon; attributed to **upstream
  model behavior**, not the port. [#855][fa855] — seam phantoms on repetitive speech. [#865][fa865],
  #838 — pause-delimited spans decoding all-blank.
- [k2-fsa/sherpa-onnx #3267][sherpa] — NeMo TDT beam search hallucinates or returns empty ~20% of the
  time; greedy is fine.
- [mudler/parakeet.cpp #55][pk55] — OPEN: `ErrorOutOfDeviceMemory` above ~5 min; the comment thread
  carries the M2/Metal memory-growth table (6 s +0.02 GB, 30 s +0.07 GB, 300 s +2.13 GB) and the
  "quantization does not help" finding. [#59][pk59] — two weight copies on Metal, 2.93 GB peak for a
  1.42 GB GGUF. [#44][pk44] — `rel_pos_local_attn` diverges from NeMo. [#61][pk61] — TDT beam search
  fails above ~40–90 s.
- [senstella/parakeet-mlx #49][mlx49] — OPEN: MLX `concat` keyword-arg break; call sites verified
  still present in master. [PR #54][mlx54] — OPEN: chunk-overlap timestamp merge produces non-
  monotonic token order.

**Runtime documentation:**
- [mudler/parakeet.cpp][pkcpp] README + benchmarks (MIT, prebuilt macOS arm64 metal, WER 0 vs NeMo,
  `--json` word timestamps, "treat it as beta software").
- [senstella/parakeet-mlx][pkmlx] README (Apache-2.0, `--chunk-duration` 120 s / `--overlap-duration`
  15 s, sentence + token timestamps).
- [FluidInference/FluidAudio][fa] README + `Documentation/Benchmarks.md`, `Documentation/CLI.md`
  (Apache-2.0, M4 Pro numbers, 15 s windows / 2 s overlap for long files).

**RichOS internal:**
- `richos-hq/docs/briefs/norm-brief-real-audio-92min-2026-08-29.md` @ `290560a` — the measurement that raised
  this question. §4.1 (wall time, 2.83 GB peak RSS), §4.2 (decay buckets), §4.3 (length is the cause,
  proven), §5 (the guard's 8 false positives), §6 (zero cross-talk bleed), §7 (`-mc 0` unmeasured).
- `wiki/call-transcription-approach.md` — the claims this brief touches.
- `wiki/open-source-strategy.md` — the license as a hard v1 gate (§5 answers it).
- `tools/richos-service/lib/config.js` (`MODEL_TIERS`, `resolveBinary`), `transcribe.js`
  (`parseWhisperJson` — segment offsets only), `merge.js` (timestamp interleave), `diarize.js`
  (`method: 'none'` default), `normalize.js` (`-ac 1 -ar 16000`, the `silencedetect` seam).

[mc-v3]: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
[mc-v2]: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
[tdt]: https://arxiv.org/abs/2304.06795
[fastconformer]: https://arxiv.org/abs/2305.05084
[longform]: https://arxiv.org/abs/2309.09950
[calm]: https://arxiv.org/abs/2505.12969
[oaslpaper]: https://arxiv.org/html/2510.06961v1
[hfblog]: https://huggingface.co/blog/open-asr-leaderboard
[techreport]: https://arxiv.org/abs/2509.14128
[nemo15757]: https://github.com/NVIDIA-NeMo/Speech/issues/15757
[fa850]: https://github.com/FluidInference/FluidAudio/issues/850
[fa842]: https://github.com/FluidInference/FluidAudio/issues/842
[fa855]: https://github.com/FluidInference/FluidAudio/issues/855
[fa865]: https://github.com/FluidInference/FluidAudio/issues/865
[sherpa]: https://github.com/k2-fsa/sherpa-onnx/issues/3267
[pk55]: https://github.com/mudler/parakeet.cpp/issues/55
[pk59]: https://github.com/mudler/parakeet.cpp/issues/59
[pk44]: https://github.com/mudler/parakeet.cpp/issues/44
[pk61]: https://github.com/mudler/parakeet.cpp/issues/61
[mlx49]: https://github.com/senstella/parakeet-mlx/issues/49
[mlx54]: https://github.com/senstella/parakeet-mlx/pull/54
[pkcpp]: https://github.com/mudler/parakeet.cpp
[pkmlx]: https://github.com/senstella/parakeet-mlx
[fa]: https://github.com/FluidInference/FluidAudio
[sb]: https://speechbrain.readthedocs.io/en/latest/API/speechbrain.decoders.transducer.html
