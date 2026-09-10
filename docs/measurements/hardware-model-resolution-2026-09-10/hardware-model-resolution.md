# Asking the machine — how RichOS picks a whisper model, 2026-09-10

The CEO, on seeing `DEFAULT_MODEL_ID: &str = "small.en"`:

> *"Why is the RichOS app being built for the shittiest possible hardware? Or better: WHY IS THE
> SHITTIEST POSSIBLE HARDWARE HARDCODED INTO THE APP???"*

He is right that the choice was made once, by hand, and baked in. This directory is the
measurement that replaces the constant with a rule, and it changes the answer in a direction
nobody predicted — including whoever wrote the brief for this work, and including me.

**It does not touch the CEO decision page §10, and it does not touch
[`../whisper-model-choice-2026-09-10/`](../whisper-model-choice-2026-09-10/).** Those record what
the two call-path models COST and that stands; every figure of theirs quoted below is quoted, not
re-derived. What changes here is that the choice stops being made once, by hand, for a machine
nobody has.

---

## 0. The four findings, before the reasoning

1. **Memory was never the constraint, and the assumed direction is backwards.** At utterance
   length `large-v3-turbo-q5_0` peaks at **858,570,752 B** against `small.en`'s **867,516,416 B**.
   The quantized turbo is **8,945,664 B CHEAPER** than the model that was kept for weak hosts.
   Every model in the ladder — the largest, full turbo, at 1,989,836,800 B — fits several times
   over in the memory a working 24 GB Mac has spare (5,873,516,544 B, measured under a heavy
   load). **Physical RAM does not discriminate between these models on any Mac Apple ships.**
2. **The constraint on the live path is decode TIME**, and it spans 10x across the ladder
   (0.202 s to 2.108 s) where memory spans 8x but never binds. Time is also the axis that varies
   across machines, which is exactly what "ask the machine" needs to be asking about.
3. **On the CEO's own M4, the better live model is over the record's own ceiling.**
   `stt.rs` states the failure point in its module docs — *"a second of dead air after every
   sentence is the difference between talking to Rich and operating him."* `q5_0` costs a median
   **1.549 s** per utterance here. It is not marginal and it is not a tuning question.
4. **The two obvious runtime signals are both disqualified by measurement, not by opinion.**
   macOS memory pressure reads **WARN on the CEO's machine continuously** under normal work, and
   available memory **swings 315,375,616 B across six samples in six seconds.** A resolver keyed
   to either would demote him at random and would write a different model id into two transcripts
   taken an hour apart.

So the resolver reads decode SPEED, measured on the machine it is running on, and uses memory
only as a guard that almost never fires. The rest of this document is how each of those numbers
was obtained and what rule they support.

---

## 1. The rig

Same instrument as the sibling directory — `/usr/bin/time -l`, bytes on macOS — pointed at the
scope neither of the existing rigs covers. `../whisper-model-choice-2026-09-10/` measures two
models at call length and at 92 minutes. The live path decodes a **3.095 s utterance** and is
judged on the silence after the CEO stops talking, so neither of its scopes is this one, and it
never measured `small.en` at all — which is the model the live path actually ships.

**The probe utterance** is the same sentence `stt.rs`'s module docs were written from, so the
numbers here are directly comparable to the ones already in the source:

```sh
say -o utt.wav --data-format=LEI16@16000 "Rich, what is the status of the voice pipeline today?"
```

| | |
|---|---|
| duration | 3.095 s (49,525 frames @ 16 kHz mono) — **the same 3.095 s `stt.rs` records**, rendered independently |
| bytes | 103,146 |
| sha256 | `547d525a0125cc679c47c44b1a467dbd0bb7445409e5e047c725192723510622` |

The WAV is **not committed**: `say` output drifts between renders (established by the settings
rig), so a committed file would imply a stability it does not have. The sentence and the exact
command are here instead, and the sha256 identifies the render these numbers came from. Every
model transcribed it **exactly, on every one of the 15 runs** — accuracy is not what separates
these rows and the transcript column is in the raw output to prove it rather than to be read.

**The argv is `stt.rs::decode_args(None)` copied verbatim** — `-l en -t 4 -fa -np -nt -mc 0` —
plus the `-m`/`-f` its caller adds. Not one flag is this rig's invention, and no flag here is
whisper.cpp's own default taken on trust: each was settled in
[`../whisper-settings-2026-09-10/`](../whisper-settings-2026-09-10/) §7 and is pinned explicitly
in `decode_args` precisely so a Homebrew bump cannot flip it. **This work adds no flag and
changes no flag.** It changes which `-m` argument gets chosen, and nothing else.

### Stack identity

Unchanged from the sibling rigs, re-read rather than transcribed:

```
whisper-cli   /opt/homebrew/bin/whisper-cli -> Cellar/whisper-cpp/1.9.1/bin/whisper-cli
sha256        7dc20e3106d70746d61c419646d9bf87f726a5df7da562e26e8529067119f7b8
host          Apple M4, 10 cores (4 performance + 6 efficiency), 25,769,803,776 B, Darwin 24.6.0
```

`hw.memsize` = 25,769,803,776 B is 24 GiB exactly (24 x 1024^3). This is the CEO's own machine.

---

## 2. Utterance length — the table the live decision rests on

`measurements/utterance-sweep.txt`, produced by `tools/utterance-sweep.sh`. Three runs per model;
run 1 carries a cold page cache and is kept rather than discarded, because it is what the first
utterance of the day actually costs.

| model | peak maxRSS B (max of 3) | wall s (3 runs) | on disk B |
|---|---|---|---|
| `tiny.en` | 248,545,280 | 0.212 / 0.211 / 0.202 | 77,704,715 |
| `base.en` | 367,149,056 | 0.278 / 0.253 / 0.248 | 147,964,211 |
| `small.en` | **867,516,416** | 0.539 / 0.578 / 0.593 | 487,614,201 |
| `large-v3-turbo-q5_0` | **858,570,752** | 1.452 / 1.323 / 1.286 | 574,041,195 |
| `large-v3-turbo` | 1,989,836,800 | 2.108 / 1.522 / 1.522 | 1,624,555,275 |

**Read the two bold rows again.** `q5_0` — the more accurate model, the one the call path ships,
the one a "low-RAM host" was supposedly being protected from — peaks **8,945,664 B lower** than
`small.en`. The tier table in `tools/richos-service/lib/config.js` calls `small.en` the
*"FALLBACK for weak / non-Apple-Silicon / low-RAM hosts."* On the low-RAM axis that sentence is
measurably false: it is the more expensive of the two. It is a fallback for a **slow** host, and
that is a different claim needing a different measurement, which is section 3.

The inversion is not a fluke of one sitting. The sweep was run twice, ~40 minutes apart, and the
first run — from the scratch copy of this same script, same argv, same WAV sha256 — gave
`q5_0` 856,899,584 B against `small.en` 865,189,888 B: the same ordering, and a gap of the same
size (8,290,304 B against 8,945,664 B).

**Why it happens** is not mysterious once measured: `small.en` is a full-precision fp16 model and
`large-v3-turbo-q5_0` is 5-bit quantized. On disk the turbo is larger (574 MB vs 488 MB) and that
is the figure everyone has in their head; resident, the quantized weights plus their smaller
per-layer activations land slightly under. **Disk size is not memory size, and the constant was
defended with the disk figure.**

---

## 3. The live path — where the ceiling comes from, and that it is not mine

The budget is **not invented by this rig.** It is stated twice in `stt.rs`'s own module docs,
which is the only place in either repository that says what a conversation may cost:

- the promise — *"the finished transcript landing in the thread within ~0.5 s of him stopping"*;
- the failure point — *"a second of dead air after every sentence is the difference between
  talking to Rich and operating him."*

So: **target 0.5 s, hard ceiling 1.000 s, both quoted from the record.** The resolver admits the
most accurate model that comes in under the ceiling.

`measurements/warm-reps.txt`, eight warm reps of the two models the decision turns on. Three runs
is not enough here: a conversation is dozens of utterances and the CEO judges the pause after
every one, so run 1's cold cache is the wrong number to decide on.

```
small.en               0.882 0.760 0.796 0.846 0.804 0.812 0.758 0.792   median 0.800
large-v3-turbo-q5_0    1.546 1.636 1.631 1.502 1.552 1.505 1.609 1.519   median 1.549
```

**And a second, earlier sample from the same script under a lighter load** (run from the scratch
copy before this directory existed; same argv, same WAV sha256, machine not simultaneously
running this rig's other sweeps):

```
small.en               0.670 0.521 0.512 0.535 0.524 0.521 0.519 0.521   median 0.521
large-v3-turbo-q5_0    1.367 1.315 1.302 1.304 1.377 1.316 1.344 1.368   median 1.331
```

Two things follow, and the second is the one that makes the design work.

1. **`q5_0` is over the ceiling on the CEO's own M4, under both loads** — 1.549 s and 1.331 s
   against 1.000 s, i.e. **55% and 33% over.** `small.en` is under it under both — 0.800 s and
   0.521 s. The verdict survives a load swing that moved every number by ~50%, so it is not a
   marginal call that a faster disk or a quieter afternoon would flip. This also **independently
   reproduces the claim already in `stt.rs`** (0.47–0.74 s for `small.en`, turbo-class costing
   "+0.63–0.79 s absolute"): measured here as +0.749 s and +0.810 s. The source comment was
   right and is now checked rather than trusted.
2. **The same machine decodes ~50% slower when it is busy.** Any calibration that samples once
   while something else is running would under-rate the machine permanently. So the resolver
   takes the **minimum** across reps, which is the estimator least contaminated by interference —
   `small.en` 0.758 / 0.512, `q5_0` 1.502 / 1.302 — and even the minimum puts `q5_0` over.

### What this means, stated plainly

**On every Mac measured today the live ladder can only step DOWN from `small.en`, never up.** The
CEO's M4 is the fastest machine in play; a machine slower than it cannot make `q5_0` cheaper. So
the honest live rule is not "give the good machine the better model" — it is **"stop giving a slow
machine a model it cannot decode in time."** An M1 Air decoding `small.en` at 2x this M4's cost
would sit at ~1.6 s per utterance and the conversation would be unusable, and today it gets
`small.en` anyway because the constant does not know what machine it is on.

The upward door is left open and it opens by itself: `q5_0` sits at the top of the live ladder and
the resolver will select it, with no code change and no env var, on the first machine that decodes
it under 1.000 s. That machine does not exist here yet, and this record says so rather than
pretending the ladder has a rung it cannot reach.

---

## 4. The batch path — a different job, a different budget

Live dictation and a 92-minute call transcription are not the same problem and are not treated as
one. A batch decode has **no per-utterance budget at all** — nobody is waiting through a pause —
so the ceiling from section 3 is meaningless here and is not applied.

The ceiling for batch is **the CEO decision page §10 ruling itself**: `large-v3-turbo-q5_0`. This
rig does not reopen it and its evidence is not memory-only — §10 put `q5_0` ahead of full turbo on
post-guard WER on both corpus renders (2.78%/2.94% against 3.78%/2.99%), ahead on fabrication (full
turbo duplicated a 17-word sentence deterministically at call length and the shipping guard keeps
it), and ahead on the 1,050,514,080 B a new user downloads before the product works. **A capable
machine is therefore NOT promoted above `q5_0`**, because the measurement says that would be a
downgrade on three axes to buy 3–6 proper nouns of 66. Promotion here would be re-deciding §10 by
the back door, from a rig that measured none of the things §10 decided on.

What is missing today is the other direction. `config.js` carries a `low-resource` tier, it names
`small.en`, and **nothing in the product ever selects it** — a human has to pass `--tier
low-resource`. So a slow machine gets the same decode a fast one does. The batch rule is
therefore a **demotion-only** rule, and its threshold is the one non-arbitrary line available:

> **A transcription that takes longer than the recording it is transcribing is a different
> product.** Below real time, demote.

`1.0x real time` is not a round number somebody liked; it is the boundary at which a batch
transcription stops being a batch job and becomes a backlog. Quoting §10's long-form figures for
what the shipping model actually costs on this machine: 92.3 minutes of two-channel audio decoded
in 237 s and 262 s (`q5_0`), i.e. **0.043 and 0.047 s of compute per second of audio — 21x to 23x
faster than real time.** This M4 has 21x of headroom against the line, which is the correct shape
for a guard: it says nothing on any healthy machine and catches the machine that cannot cope.

Memory on this path uses §10's own figures rather than re-measuring them: `q5_0` peaks at
884,981,760 B at call length and 1,859,256,320 B on 92 minutes, against full turbo's
2,014,101,504 B and 2,817,949,696 B.

---

## 5. What the resolver reads, and the two candidates it rejects

`measurements/machine-state.txt`, from `tools/machine-state.py`.

### Rejected: memory pressure (`kern.memorystatus_vm_pressure_level`)

Six samples, one second apart, on the CEO's machine during ordinary work:

```
sample 1..6   pressure=2  pressure=2  pressure=2  pressure=2  pressure=2  pressure=2
```

**2 is WARN.** Not a spike — the steady state. A resolver that demoted on elevated pressure would
demote him permanently, on a 24 GB machine with 5.8 GB spare, and would have looked completely
principled in review. This is the single most useful thing this directory measured, and it is
invisible without running it.

### Rejected: available memory

The same six samples:

```
5,881,397,248  5,566,021,632  5,803,556,864  5,733,023,744  5,763,481,600  5,758,533,632
```

**315,375,616 B of churn in six seconds**, on an idle-ish desktop. That is a third of the entire
gap between the smallest and largest live model. Keying resolution to it means the model depends
on the second voice mode happened to start — and the model id is written into every transcript's
provenance line, so two transcripts from one machine on one afternoon would no longer be
comparable. Determinism is a product property here, not an engineering preference.

It is kept as a **guard**, never as a discriminator: a model whose measured peak RSS exceeds what
the machine has available right now is refused. Both sides of that comparison are measured bytes,
there is no chosen constant in it, and on this machine it never fires (largest model
1,989,836,800 B against 5,873,516,544 B available).

### Kept: measured decode time, and `hw.memsize` for the record

The machine's own commitment, for the record and for the reason the RAM ladder was abandoned:

```
non-reclaimable set      19,388,923,904   (wired + active + compressor)   75.2% of total
available now             5,873,516,544                                   22.8% of total
total (hw.memsize)       25,769,803,776
```

Note `occupied by compressor` = 11,463,786,496 B. On a machine with 24 GB of RAM, 11.5 GB of it
is holding compressed pages. This is what a real working Mac looks like, and it is why a threshold
of the form "reserve N GB for the system" derived on ONE machine does not transfer to another: the
working set scales with the machine. A rule needing such a constant was drafted and thrown away.

---

## 6. The rule, in full

Ordered ladders, most accurate first. A model is admitted iff it clears **both** gates; the
resolver takes the first one that does.

```
live  (stt.rs)       ladder: large-v3-turbo-q5_0 -> small.en -> base.en -> tiny.en
                     gate 1: measured decode of a 3.095 s probe on THIS machine <= 1.000 s
                     gate 2: measured peak RSS <= memory available on THIS machine
                     -> on the CEO's M4: small.en (q5_0 rejected at 1.549 s / 1.331 s)

batch (config.js)    ladder: large-v3-turbo-q5_0 -> small.en
                     ceiling: the CEO decision page §10 ruling; never promoted above it
                     gate 1: projected decode <= 1.0x the recording's own duration
                     gate 2: measured peak RSS <= memory available on THIS machine
                     -> on the CEO's M4: large-v3-turbo-q5_0, with 21x of headroom
```

Every constant in that block is either measured in this directory, quoted from §10, or quoted
from `stt.rs`'s own stated failure point. There is no number in it that somebody liked.

**The env override stays and stops being the only control.** `RICHOS_VOICE_WHISPER_MODEL_ID` and
`RICHOS_WHISPER_MODEL` continue to win outright, for engineers and for reproducing a measurement.
What changes is that a non-technical CEO who will never set one now gets a machine-appropriate
answer instead of a hand-picked constant.

**And the resolution is said out loud.** Whichever way it goes, the model id, the reason and the
measurement that decided it are named in the provenance line that already accompanies every
transcript, and a demotion below the ladder's top rung reaches the user in plain language on a
surface they see. A capable machine being quietly handed the weaker model is the defect this work
exists to remove; doing it silently in the other direction would be the same defect.

---

## 7. Reproducing

```sh
say -o /tmp/utt.wav --data-format=LEI16@16000 "Rich, what is the status of the voice pipeline today?"
bash tools/utterance-sweep.sh /tmp/utt.wav /tmp/hw-out    # table in section 2
bash tools/warm-reps.sh /tmp/utt.wav                      # section 3
python3 tools/machine-state.py                            # section 5
```

`say -o` writes a file and plays nothing. The sweeps were additionally run with system output
muted at the device level.

## 8. Open, and honestly open

- **No machine other than this M4 has been measured.** Every cross-machine claim above is a claim
  about what the RULE will do, never a measured result — which is exactly why the rule measures
  the machine it is on instead of shipping a table of machines. The first non-M4 host to run it
  should have its calibration recorded here.
- **`small.en-q5_1` is not in either ladder.** It is the one entry in `model-pins.json` with a
  single witness and no copy on any machine here, and its own `witness` field says so. It is the
  obvious extra rung below `small.en` and it stays out until somebody can verify the bytes.
- **§10's conclusion is untouched and this rig gives no reason to revisit it.** The one figure
  here that bears on it — `q5_0` costing less resident memory than `small.en` — strengthens it.
