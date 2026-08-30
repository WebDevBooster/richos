# The correction flywheel, measured — 2026-08-29

**Nothing in this directory is private.** Every sentence measured here was invented for the
measurement: the short-call corpus comes from `corpus/calls.json` in the short-call WER harness
(whose own README states that every person, company, identifier and sentence in it was written for
that measurement), and the dictation utterances are written inline in
[`tools/dictation-bias.mjs`](tools/dictation-bias.mjs). No recording of anyone was consulted, no
transcript of anyone appears, and no fixture here is a real spoken sentence.

The decision being implemented is **"ask, never infer"** — `ceo-decisions.md` §7, decided
2026-08-26. It was unbuilt at both ends: open-wispr persisted neither text nor audio, so there was
nothing for a correction to be a correction *of*; and `entities.json` had exactly one reader, so the
vocabulary never reached the decode that would benefit.

---

## 1. The headline: name consistency, before and after

WER cannot see the thing the flywheel is for. The short-call measurement found that the shipped
`-mc 0` decode spells a *repeated* name consistently far less often than a decode with carried
context, and that gap is precisely what a correction loop should close. So the flywheel is scored on
it.

**The simulation is not a tautology.** Handing the corrector the whole reference would make it an
oracle. Instead the CEO corrects **exactly one occurrence per channel** — the first name he would see
rendered wrong, in a window of the surrounding words, the way he would fix it in a composer. Every
later occurrence, every other channel and every *different* mis-spelling of the same name is held
out and has to be earned. Each round then runs the shipped path and nothing else: `askCandidates()`
decides what is worth asking, `answerAsk()` records a confirm, `learnTerm()` writes the vocabulary,
`correctText()` applies it.

| round | corrections he made | entities learned | **names spelled consistently** | WER |
|---|---|---|---|---|
| 0 — shipped `-mc 0`, no vocabulary | — | 0 | **19 / 24** | 3.15% |
| 1 | 6 | 4 | **21 / 24** | 2.47% |
| 2 | 3 | 3 | **23 / 24** | 2.41% |
| 3 | 1 | 1 | **24 / 24** | 2.31% |
| 4 | 0 | 0 | **24 / 24** | 2.31% |

`large-v3-turbo`, 6 invented calls, 11.8 minutes, 1,852 reference words. Round 4 is a fixed point:
nothing left to correct, nothing asked, nothing learned, nothing changed. **The wheel stops turning
when there is nothing left to fix**, which is the property that makes it a flywheel rather than a
treadmill.

Two things worth reading off this table:

- **It reaches, and then beats, what carried context used to give.** The same harness measured
  `-mc -1` at 23/24 on this model. The flywheel gets there at round 2 and to 24/24 at round 3 —
  **without touching `-mc`**, and therefore without reintroducing the long-form repetition failure
  that `MAX_CONTEXT_TOKENS = 0` exists to prevent (`lib/config.js`: at `-mc -1`, 44.1% of one
  92-minute channel's timeline was inside a fabricated repetition span).
- **Round 1 made one name worse, and that is honest.** `Corvane Systems` was consistently *wrong*
  before (three occurrences, all "Corvain") and became inconsistent after (one fixed, two not),
  because the pair learned in round 1 carried more context than the name and therefore matched
  fewer places. Partial correction can cost consistency while improving WER. Round 2 closed it,
  which is the loop working as designed rather than a flaw papered over.

Reproduce:

```bash
export RICHOS_WER_TOOLS=<the short-call WER harness>/tools    # for wer.mjs
# build the corpus and the round-0 decode with the harness's own build-corpus.mjs + measure.mjs
#   measure.mjs <libDir> <corpusDir> <runsDir> --models large-v3-turbo --mc 0 --tag base
tools/rounds.sh <workDir> <richos>/tools/richos-service/lib "$RICHOS_WER_TOOLS"
```

or one round at a time with
`tools/flywheel.mjs <libDir> <corpusDir> <runsDir> <prevTag> <model> <mc> <newTag>`, followed by the
harness's own `consistency.mjs`.

Full round-by-round detail, including every ask and what it scored:
[`results/flywheel-round-1.txt`](results/flywheel-round-1.txt) … `-4.txt`.
Consistency output per round: [`results/name-consistency-round-0.txt`](results/name-consistency-round-0.txt) … `-4.txt`.

**One honesty note on the baseline.** The published short-call brief reports 17/24 for this
configuration; this rebuild of the same corpus measured 19/24 at round 0. The audio is regenerated
by `say` rather than committed, so a small difference between runs is expected. The before/after
above is measured **within one run**, which is the only comparison that means anything, and 19/24 is
the baseline it is measured against.

---

## 2. Does the vocabulary reach the decode? Two different answers

### For calls: no, and it structurally cannot

The obvious way to get a vocabulary into a decode is whisper's initial prompt. **At the shipped
`-mc 0` it is inert**, and this is proven rather than argued: three decodes of the same channel —
no prompt, with a prompt, and with a prompt plus `--carry-initial-prompt` — produced **byte-identical
output**, sha256 `409d5cc…` for all three. `-mc` caps the text context at zero tokens and the initial
prompt lives in that context.

Raising `-mc` is not available: 16 is the largest value measured loop-free on the long-form corpus,
and at `-mc 16` the prompt still needs `--carry-initial-prompt` to survive at all (`-mc 16` with a
prompt is byte-identical to `-mc 16` without one; adding the carry flag is what changes the output).
Even where the prompt does reach the decode, it did not produce the vocabulary term: at `-mc -1`
with "Pallas" in the prompt, the decode still wrote "Palis", consistently.

**So for call transcription the vocabulary reaches the decode through the corrector, or not at all.**

### For dictation: yes — and the corrector still wins

open-wispr passes no `-mc` (`Transcriber.arguments` builds `-m -f -l --no-timestamps -nt` and
nothing else), so it runs at whisper's own default and the prompt IS live. Measured on 12 invented
dictations, scored by the same case-sensitive alignment the short-call harness uses — and note that
every dictation utterance is an **independent decode with no shared context whatsoever**, which is
the cross-window consistency problem in its purest form:

| path | names right | names spelled consistently |
|---|---|---|
| no vocabulary at all (today) | 23/27 | 14/14 |
| vocabulary as an initial **prompt** | 26/27 | **13/14** |
| vocabulary as a **correction** | 25/27 | 14/14 |
| prompt **and** correction | 26/27 | **13/14** |
| **flywheel-learned vocabulary, correction** | **27/27** | **14/14** |
| flywheel vocabulary, prompt + correction | 26/27 | 13/14 |

**The prompt raises exact hits and costs consistency.** It nudged one name into a third new spelling
("Palas") while fixing another. A probabilistic nudge can invent a variant; a deterministic
replacement cannot. And the flywheel's own **two** learned pairs — taken from the first utterance in
which each name came out wrong, every later utterance held out — beat the entire hand-written
vocabulary supplied as a prompt.

**Therefore the shipped design feeds the vocabulary through `correct-text`, and leaves
`whisperPrompt` alone.** Detail: [`results/dictation-vocabulary-paths.txt`](results/dictation-vocabulary-paths.txt).

---

## 3. Precision: proving it stays silent

A correction must never be inferred. Two negative controls over the same corpus, each paired with a
positive probe over the identical text — a negative test that passes because the machinery is asleep
proves nothing.

| control | result |
|---|---|
| a change of mind (day names, numbers, ordinary verbs) across all 12 channels | **0 asks** |
| the same channels with a real name mis-hearing planted | **11 asks / 11 channels** — the gate is awake |
| 3 typed messages offered against a live dictation journal | **0 matched, 0 prompts** |
| the same journal, sent as a genuinely corrected dictation | matched, 1 prompt — the pairing works |

**The first run of this control found two real defects**, and neither would have been found by
reasoning about the code:

1. **The gate was scoring the expanded span.** Hunk expansion deliberately wraps proper-noun context
   around a change so the *learned* pair is a whole name and not a lone word — but that context is
   identical on both sides by construction, so scoring it makes every edit look like a near-miss.
   `Northgate, Tuesday` → `Northgate, Wednesday` scored 0.90 as a phrase. The gate now judges the
   unexpanded core while the vocabulary still learns the span.
2. **A weekday is capitalized by grammar.** `Tuesday` → `Wednesday` survives the core gate at 0.56
   by spelling and **0.75 by sound**, so the new phonetic leg asked about it. Days, months and their
   abbreviations are now refused outright, with the reason stated. `learn-term` remains the override,
   so a customer genuinely called August is still teachable by explicit instruction.

Beyond the corpus, the doctrine itself is asserted in `tools/richos-service/test/run.js`: no route
out of `reviewSent` carries a learn; `confirm` is the only answer that yields a pair; `decline`
learns nothing and is asked again on the very next repeat; `never` is permanent and inspectable; and
`great` → `Grant` — the single most dangerous pair in the system — is asked and never learned.

Reproduce: `tools/precision.mjs <libDir> <corpusDir> <runsDir> <tag> <model> <mc>`.
Detail: [`results/precision.txt`](results/precision.txt).

---

## 4. What it costs to keep

Measured, not estimated: an hour of dictation synthesized from the real utterance durations,
journalled as the real record shape, measured on disk.

| | |
|---|---|
| utterances in an hour of speech | 960 (mean 3.8 s each) |
| words | 9,680 |
| **Tier A — the text record (ON by default)** | **290,504 B/hour — 284 KB** |
| a heavy day, 2 hours of dictation | 567 KB |
| the full 14-day window at 2 h/day | 7.8 MB |
| the 5,000-record ceiling | 1.3 MB, ~5.2 hours of speech |
| **Tier B — the audio (OFF by default)** | 115,273,566 B/hour — **109.9 MB**, **397×** the text |
| what the 2 GB ceiling would hold | 19 hours of dictation |

**The posture, and why.** It reuses the shape and the exact numbers the techy-mode journal already
committed to (the techy-mode plan §2.4, in the private record `richos-hq`, not this repository) rather than inventing a third thing
to reason about:

- **Tier A, the text**: a rolling window, **14 days OR 5,000 records**, whichever binds first,
  evicted oldest-day-file-first by `unlink`. Bounded here where techy-mode's Tier A is not, because
  the record's only job is to be the other half of a correction and that job expires — he fixes a
  dictated name while it is still on screen. A permanent archive of everything he has ever said to
  his machine would cost more than the loop it serves.
- **Tier B, the audio**: **off by default**, which is upstream open-wispr's own default and the
  right one, because **the flywheel never reads it** — a correction is text against text. When
  switched on: 14 days or 2 GB, whichever binds first.

One writer, one sweeper: open-wispr only ever appends, and the local service's `watch` loop sweeps
hourly. That is what keeps eviction an `unlink` of a whole day file rather than a rewrite of the
CEO's speech, and a pass that removes anything says what it removed and why.

Reproduce: `tools/retention-cost.mjs <libDir> <dictationWavDir>`, where the WAV directory is the
one `tools/dictation-bias.mjs` writes.

---

## 5. What is NOT closed

**The automatic trigger inside other applications.** Everything above assumes the corrected text
reaches the service. Inside RichOS's own composer that is a short wire — we own both ends, the
journal holds what was heard and the composer holds what was sent — and it is a documented seam,
not built here (`app/` was owned by other work on the day this landed). Inside Gmail or Slack it
needs the Accessibility read-back spike §7 defers, and the open question there is read-back
*reliability* across native, Electron and web fields, not the permission. Until one of those two is
wired, a correction is stated through `richos-service dictation-review --sent "…"`, which is a real
human statement and is exactly as safe, but is not the mini-HUD §7 describes.

**Real speech.** Every number here is measured on invented sentences, which is the correct way to
measure it and is not the same as the CEO using it. One real dictation, journalled; one real
correction, asked and confirmed; the next dictation spelling it his way — that is the test this
cannot substitute for.

---

## Files

```
tools/flywheel.mjs        turn the wheel once over the short-call corpus and apply what was learned
tools/rounds.sh           drive it to a fixed point and print the round-by-round table
tools/precision.mjs       the negative controls, each with its positive probe
tools/dictation-bias.mjs  prompt vs correction vs both, on 12 invented dictations
tools/retention-cost.mjs  bytes per hour of dictation, from real durations and the real record shape

results/                  the output of each of the above, verbatim
```

These take the short-call corpus directory as an argument rather than vendoring it, and
`flywheel.mjs` and `dictation-bias.mjs` load `wer.mjs` from the short-call WER harness via
**`RICHOS_WER_TOOLS`** rather than carrying a second copy of the alignment. One alignment
implementation is why the numbers here are comparable to that brief's at all; a vendored copy would
drift and the comparison would quietly stop meaning anything. A missing harness fails by name at
startup instead of as a bare module-not-found.

That harness lives with its brief. These are its companions and may reasonably be mirrored beside
it — a call the lander is better placed to make than this branch is.

**Verified from this location**, not only from the scratch directory they were written in: the
committed copies reproduce round 1 at 21/24 and WER 3.15% → 2.47%, the precision verdict, and
284 KB/hour, against a throwaway runs directory so a stale result cannot be laundered into a pass.
