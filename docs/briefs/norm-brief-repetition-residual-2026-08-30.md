# The guard stops deleting real speech, and the class that could only shout can now repair

**Author:** Norm (Full-Stack Engineer). **Date:** 2026-08-30.
**Requested by:** Rich, on behalf of the CEO.
**Base:** richos `main` @ `d68d73f`. **Branch:** `norm/repetition-residual-2026-08-30`.
**Scope:** `open-items.md` row 3.3's two open residuals — short repeated phrases below the veto's
3-word floor can still collapse, and the persistent-insertion class is still detect-only.

**CEO constraint this work was held to:** *deleting a genuine delivery is the expensive failure, not
missing a loop.* Both changes below are one-directional in that sense, and one of them is
one-directional **by construction rather than by measurement** — see §0(b).

**No shipping default, tier, `MODEL_TIERS` value or decode parameter moved.** `MAX_CONTEXT_TOKENS`
is still 0 and `whisperArgs()` still emits exactly `-l en -t 4 -mc 0 -oj -np`. What changed is one
threshold and one hand-off inside the post-decode guard, and one new wire in the pipeline.

`data-contract-bypass`: a local model measurement plus a service-side guard. No Avelor/fitapp app was
built, installed, rendered or tested; nothing touched an emulator, simulator or device.

**Privacy.** This repository is PUBLISHED (`.publication-boundary` at the root). The 92-minute
corpus is a private recording, so **no phrase from it appears anywhere in this brief, its assets
or the new tests** — every finding is named by its offsets, its word count and its verdict. The
tools were edited to print offsets rather than text before their output was committed. The one place
speech is quoted at all is sample C, which is macOS `say` TTS of an invented script and was already
committed in full as a fixture. `engine/scripts/lib/publication-boundary.py` was run by hand over
every changed source file — CLEAN against a **non-empty** corpus (14 private files, 130,466 words),
so the scan was live rather than vacuous.

---

## 0. Bottom line up front

### (a) The corpus is the same corpus — proven, not assumed

The four 92-minute channels were re-decoded from the two gitignored source recordings at bare whisper.cpp
defaults, with the 2026-08-29 measurement's own command. **All four came back byte-identical** to
that brief's committed transcripts (969 / 728 / 1,856 / 1,146 lines). The same four channels were
then re-decoded at the shipping `-mc 0`, and those reproduce the long-form brief's acceptance table
exactly too (435 / 566 and 439 / 530 segments; 3,762 / 6,133 and 3,706 / 6,086 words). Every number
below is therefore assigned against the same 72 hand-verified findings, not against a lookalike.

### (b) The veto's word floor is gone, and the LOOP CLASS now deletes no genuine speech on this corpus

| the 72 hand-verified findings, `-mc -1` transcripts | text-only (pre 08-29) | grid, `minW 3` (shipped 08-29) | grid, `minW 1` (this change) |
|---|---|---|---|
| **genuine deliveries deleted** | **13** | **1** | **0** |
| findings that destroyed real speech | 8 | 1 | **0** |
| loop findings | 72 | 70 | 70 |
| segments removed | 2,376 | 2,207 | 2,155 |
| runs preserved outright | 0 | 2 | 2 |
| extra fabricated segments surviving | 0 | 156 | 207 |

The middle column reproduces the 2026-08-29 brief's committed sweep row exactly (`1 / 156`, total
removed 2,207), which is what makes the right-hand column comparable rather than merely new.

**Genuine deliveries deleted: 13 → 1 → 0.** The last surviving false positive of the eight — a
one-word phrase the man said twice at 829.9 s, which whisper emitted six times — is repaired. It was
below the old 3-word floor, which is why it survived the 2026-08-29 fix.

**And this change cannot cost a false positive, by construction.** Below the old floor the guard's
behaviour was exactly `keep = 1`. With the floor removed it is `keep = max(1, min(runLen, capacity))`,
which is `>= 1` at every phrase length. It is strictly more conservative than what shipped, at every
length, on every input — a property, not a measurement, and `test/run.js` holds it as one.

### (c) THE FLOOR WAS NOT THE WHOLE RESIDUAL: class 3 was undoing class 1's veto, and nothing was measuring it

Scoring the guard end to end rather than at the class-1 seam — how many copies of a phrase actually
reach `transcript.md` inside the ground-truth span — found the veto's protection being taken back one
stage later. **K identical consecutive segments are, to a word-exact boundary rule, a stutter chain.**
So wherever class 1 had just decided the audio holds K separate deliveries, `guardOverlapStutter`
collapsed them again.

It bites at **K >= 4**: three copies make only two links and `minChainLinks` is 3. The one genuine
retake in the shipping world is a 3x retake, one delivery under the threshold — which is exactly why
this was invisible to every measurement taken so far, including the acceptance transcripts.

The fix is a hand-off, and the precedence is not a preference: **class 1 consulted the audio; class 3
is text-only.** Where the burst grid says K separate speech events happened, a text rule does not
overrule it. A boundary is not a link when both its segments sit inside a span class 1 protected —
preserved outright *or* clamped to more than one delivery. One-directional as always: it can only
remove links, so no stutter the class used to catch can escape it.

| genuine deliveries deleted END TO END, all four classes | text-only | `minW 3` + hand-off | `minW 1`, NO hand-off | **shipped after this work** |
|---|---|---|---|---|
| deliveries lost | 10 | 5 | 9 | **4** |
| findings affected | 6 | 5 | 6 | 4 |

Read the third column against the fourth: with the floor gone but class 3 left alone, **9** deliveries
still die — the floor fix on its own would have bought almost nothing end to end. The hand-off is
worth 5 of them.

**And all four survivors are class 4, not the loop class** — the silence-fabrication class removing a
one- or two-word phrase whose single real delivery sat under the burst floor. That is the residual
class 4's own header already names ("SPEECH BELOW THE BURST FLOOR ... the one place class 4 can
destroy a real word"), now observed on a second corpus with a count. It is identical before and
after this change and is left alone deliberately — §8.

**The loop class, end to end, now deletes zero genuine deliveries.**

### (d) A correction to the record: the shipped guard was better than the record says

`open-items.md` row 3.3, the wiki, and this guard's own header all state **13 → 3** genuine
deliveries deleted and **6 of 8** false positives repaired. That headline is not supported by any
committed evidence. The 2026-08-29 brief's own two measurement files —
`measurements/guard-veto-evaluation.txt` (*"12 of 13 recovered ... 1 genuine deliveries deleted"*,
with a per-finding table showing seven of the eight rows going to zero) and
`measurements/guard-veto-parameter-sweep.txt` (*"3 0.6 | 1 genuine deliveries still deleted"*) —
both say **1**, and this independent reproduction says **1**. The true shipped state was **13 → 1
and 7 of 8**. The correction makes the residual smaller than advertised, not larger.

### (e) Neither sibling instrument can hold the short-phrase residual, and the reason is geometric

The task asked whether `deletion-guard.js` or `substitution-guard.js` could supply the signal the
veto lacked below three words. Measured on the exact span the old floor destroyed: **0 candidates
from either**, and the first reason needs no thresholds at all — the two bursts carrying the two
real deliveries are **0.61 s and 0.85 s**, both below the deletion detector's `minGapSec` of 1.0 s.
They are not rejected; they are never candidates. Two further reasons stand behind that one
(§3.2). The loop class had to hold this itself.

### (f) The persistent-insertion class now REPAIRS, on physical evidence, and the artifact's own counter-example survives

The class was detect-only for one measured reason: inside the fabricated span, one marker is a real
spoken numeral, so a blanket strip deletes a word the speaker said. That is still true — the
unadjudicated strip destroys it, 1 real word of 57 markers.

The evidence that separates them is the audio. Cut each suspect segment's own span out and decode it
ALONE: a fabricated ordinal is a product of accumulated decode context and does not survive
isolation, while a numeral the speaker uttered comes back. On the captured artifact, ground truth
known by construction:

| | markers | stripped | REAL WORDS DESTROYED | fabricated markers left in |
|---|---|---|---|---|
| unadjudicated strip (`stripInsertions`) | 57 | 57 | **1** | 0 |
| head-anchored probe rule | 57 | 57 | **1** | 0 |
| **whole-clip probe rule (shipped)** | 57 | **56** | **0** | **0** |

The false-positive control is the speaker's *genuine* spoken action list: probed the same way, the
isolated decodes return "1." and "Three," and the rule refuses to strip both. Three real numerals in
the corpus, three protected; 56 fabrications, 56 removed.

### (g) What did NOT change, named

- **No decode parameter, tier or default.** `-mc 0` is untouched; so is every `MODEL_TIERS` value.
- **`burstFitSlack` stays 0.6.** The sweep says 0.6 is the only slack that deletes nothing at any
  word floor; 0.8 costs a delivery back.
- **Non-ordinal insertions stay out of scope.** A fabricated bullet or word carries no ordering
  signal, so nothing reaches the probe that could repair it.
- **`stripInsertions` still exists and still defaults to false.** It is the arm that eats the word.
- **Retake de-duplication.** Out of scope by CEO ruling 2026-08-29; repeated deliveries in a webinar
  recording are correct output and nothing here treats them otherwise.

---

## 1. The short-phrase floor

### 1.1 What the floor was, and the one thing its argument missed

The floor read `minWordsForBurstVeto: 3`, and the reason given was sound as far as it went: a 1-2
word phrase fits inside any speech burst, so the *duration* half of the burst ceiling — "is this
burst long enough to hold the phrase?" — carries no signal there.

What that missed is that the ceiling has a second half, and it does not depend on phrase length at
all. A burst is a separate speech EVENT. Saying anything K times requires K of them inside the run's
own span, however short the thing being said is. Below three words the ceiling stops being *does it
fit* and becomes *how many times did this channel start speaking in here* — looser, and still a
ceiling.

The header's stated consequence of removing the floor was that the ceiling "would veto everything"
below three words. Measured on the 31 findings of the 72 that sit below it: **zero** runs are
preserved outright that were not already, because those runs sit over spans holding 0-2 bursts, not
6-47. The prediction does not happen at `burstFitSlack: 0.6`.

### 1.2 The sweep, in the previous brief's own metric

`minWordsForBurstVeto` × `burstFitSlack` over the 72 hand-verified findings — genuine deliveries
still deleted (of the 13 the text-only guard destroyed) / extra fabricated segments surviving (of
2,376 text-only removals). Same arithmetic and same join key as
`norm-longform-fix-2026-08-29-assets/tools/veto-sweep.mjs`, so the rows overlap with its committed
table and can be compared line for line (`measurements/veto-eval-2026-08-30.txt`, "FULL SWEEP";
`measurements/veto-sweep-2026-08-30.txt` is the same grid scored a second, independent way, and the
two agree on which cells delete speech):

| | slack 0.6 | slack 0.8 | slack 1.0 |
|---|---|---|---|
| **minWords 1** | **0 / 207** | 1 / 174 | 3 / 145 |
| minWords 2 | 1 / 161 | 2 / 131 | 4 / 107 |
| minWords 3 | 1 / 156 | 2 / 126 | 4 / 103 |
| minWords 4 | 2 / 154 | 3 / 124 | 5 / 102 |
| minWords 5 | 2 / 154 | 3 / 124 | 5 / 102 |

The three `minWords 3-5` rows are identical to the previous brief's, cell for cell. The two new rows
are the ones the old floor hid.

`1 / 0.6` ships: the most protective corner, and the only cell in the grid that deletes no genuine
speech at all.

### 1.3 What it costs, priced in the world we actually ship

The right-hand column above is measured in the **pre-fix** world (`-mc -1`, 2,376 collapsed
segments), which has not shipped since 2026-08-29. Re-run against the same four channels decoded at
the shipping `-mc 0`:

| the same four channels, `-mc 0` | `minW 3` (shipped 08-29) | `minW 1` (this change) |
|---|---|---|
| loop findings | 0 | 0 |
| segments removed | 0 | 0 |
| runs preserved outright | 2 | 2 |
| extra fabricated segments surviving | 4 | 4 |
| genuine deliveries deleted | 0 | 0 |

**The change costs nothing in the world we actually run.** Those `-mc 0` transcripts also reproduce
the 2026-08-29 acceptance table exactly — 435 / 566 and 439 / 530 segments, 3,762 / 6,133 and
3,706 / 6,086 words — so this is the same comparison that brief made, one configuration further on.
The 51 extra segments in §1.2 are a cost priced entirely in a decode configuration that has not
shipped for a day, and even there they are duplicated backchannels left in, not speech taken out.

### 1.4 The safety argument is a property, not a number

The cost column above is a measurement and could have come out differently on another corpus. The
SAFETY of the change could not. Below the old floor the guard's behaviour was literally
`keep = 1`; with the floor gone it is `keep = max(1, min(runLen, capacity))`, and
`max(1, x) >= 1` for every `x`. There is no input, at any phrase length, for which the new
configuration removes a segment the old one kept. `test/run.js` holds that as a property over four
fixtures × four burst grids rather than as a sentence, and dropping the `max(1, …)` floor turns
seven checks red.

---

## 2. The hand-off class 3 was missing

### 2.1 How it was found, and why nothing had found it before

Every measurement of this guard until now scored the LOOP CLASS: hand `guardChannel` a channel, read
its `loops` and `preserved`. That is the right instrument for choosing the veto's parameters and it
is what the 2026-08-29 numbers are. It is blind to what the next two classes then do to the same
segments.

Scoring end to end instead — for each of the 72 ground-truth spans, how many copies of the phrase
survive `guardChannelAll` — the two numbers disagreed: 0 deliveries deleted at the class-1 seam, 8
deleted by the time the transcript existed. `norm-repetition-residual-2026-08-30-assets/tools/attribute.mjs` walks a span through the four
classes one at a time and names the one that took it.

### 2.2 What class 3 was doing

`guardOverlapStutter` links two consecutive segments when the tail of one is word-for-word the head
of the next, and calls three consecutive links a stutter chain. **K identical consecutive segments
satisfy that perfectly** — they are what the class was built to remove, when a decoder emits them.
When a human delivers them, they are speech, and the class has no way to tell: it never looks at the
audio.

So class 1 would preserve five real deliveries on the burst grid's evidence, and class 3 would
collapse them to one. Measured on this corpus end to end: 9 deliveries lost with the hand-off absent, 4 with it —
**5 genuine deliveries recovered at the class-1 seam and destroyed again downstream**, across the
findings where a run of four or more identical segments survived class 1.

It bites at K >= 4 and not at K = 3, because three copies make two links and `minChainLinks` is 3.
The shipping world's only surviving loop finding is a 3x retake — one delivery under the threshold.
**That is why an acceptance transcript could show all three deliveries present and the defect still
be there.**

### 2.3 The fix, and why the precedence is not a preference

`guardChannelAll` now hands class 3 the spans class 1 protected — `preserved` runs and `loops` rows
with `kept > 1` — and a boundary inside such a span is not a link. Class 1 consulted the AUDIO;
class 3 is text-only. Where the physical grid says K separate speech events happened, a text rule
does not get to overrule it.

**And the measurement says something sharper than "it costs nothing."** The 2026-08-29 brief
hand-verified this class as clean on this corpus — 3 findings, 3 true positives, 0 genuine words
lost — measured on the TEXT-ONLY guard, before the veto existed. Add the veto and the same four
channels give the class **14 findings and 162 removals**, because every run the veto protects is a
fresh chain for it to eat. With the hand-off: **3 findings, 7 removals, 2 trims — the same three
spans, by offset** (`measurements/stutter-class-unchanged.txt`). The hand-off does not merely avoid
a cost; it puts the class back exactly where its own verification left it.

One-directional like everything else here: `protectedSpans` can only remove links, never create
them. Asserted three ways — the protected
run survives, an unrelated protected span leaves the captured stutter's removals unchanged, and a
run of four with no burst grid still collapses to one.

The clamped case is in the hand-off as well as the preserved one, and that is not decoration: the
finding that lost four deliveries was a CLAMP (7 emitted, 5 kept), which is reported under `loops`
rather than `preserved`. A hand-off covering only `preserved` leaves class 3 free to take them, and
the suite has a check that goes red if it does.

---

## 3. Why the loop class had to hold the short-phrase residual itself

### 3.1 The measurement

`norm-repetition-residual-2026-08-30-assets/tools/siblings.mjs` takes the shipped guard **with** the old 3-word floor — the configuration that
deletes one of the two real deliveries at 829.9 s — and hands its output to stage 3.7's and stage
3.8's stage-A candidate generation, on the channel and the grid the pipeline would use.

```
deletion detector : 37 candidate(s) on this channel, 0 at 829.9-833.9s
word-density      : 25 candidate(s) on this channel, 0 at 829.9-833.9s
```

### 3.2 Three reasons, and the first one needs no thresholds

1. **The bursts are too short to be candidates at all.** The two bursts carrying the two real
   deliveries measure 0.61 s and 0.85 s; `deletion-guard.js#DEFAULT_DELETION_OPTS.minGapSec` is
   1.0 s. Stage A never generates them. A short retake is short *because it is short* — the very
   property that makes the loop class's text-only path dangerous is the one that puts it beneath
   both instruments' floors.
2. **The probe floor.** Even reaching stage B, `minProbeWords: 3` rejects a recovered one-word
   delivery as not-speech.
3. **The echo condition.** `maxEchoWords: 2` / `maxEchoRatio: 0.7` reject a probe whose words are
   already nearby in the transcript — and a deleted RE-delivery is, by construction, exactly that:
   the surviving copy is sitting a second away.

### 3.3 And the collapse hides itself from a coverage check by design

`guardChannel` extends the kept segment's end to the run's end, so the span still reads as spoken
time. Measured: all three bursts in that span score `coveredByASegmentExtent=true` after the
collapse. That is the right behaviour for timing honesty and it is also why no coverage-based
instrument can find the loss.

---

## 4. The persistent-insertion class

### 4.1 The artifact, and why detection was where it stopped

`large-v3-turbo` on 11 minutes of noisy audio prefixed a fabricated, stalling ordinal onto 59 of 88
segments. The detector's four channel-level conditions bound the fabrication to 57 of those 59, and
the two it excludes are the speaker's real action-list items — that part was already right.

The blocker was inside the fabricated span: at 205.3 s the speaker answers a question with "Zero.",
which whisper renders as a leading " 0. ". A blanket strip deletes it. That is measured on the
artifact, not argued: `stripInsertions: true` removes 57 markers and one of them is a real word.

### 4.2 The remedy, and why it is the same remedy the pipeline already buys twice

Stages 3.7 and 3.8 both answer "is this suspicious span real?" by cutting it out and decoding it
alone. The insertion class can ask the same question of a single segment, and the answer is
decisive for the same reason: **a fabricated ordinal is a product of accumulated decode context**,
and an isolated clip has none. The 2026-08-29 long-form work proved this on this very failure mode,
where a 65-second clip cut from a catastrophically looped span decoded correctly at identical
parameters.

So `guardInsertions` gained a `probe` option with the callback shape 3.7 and 3.8 already use, and
`pipeline.js`'s probe factory moved above stage 3.5 so all three stages share one cut, one pair of
paddings and one clip decoder.

### 4.3 THE PRECISION RULE, four conditions

1. **PROBE PRESENT.** No probe, no repair, ever. Without one the module is byte-for-byte the
   detect-only class it was, and the report says which of "left it alone" and "never looked" applies.
2. **SUSPECT ONLY.** The four detection conditions fired, and the marker is past the first
   well-formedness violation. The genuine leading enumeration is never probed and never touched —
   asserted: exactly 57 spans reach the probe, not 59.
3. **NOT IN EITHER DECODE.** Neither the tight (0.3 s pad) nor the wide (0.75 s pad) isolated decode
   contains the numeral *anywhere*, in digit or word form.
4. **THE DECODE SAID SOMETHING.** Both clips returned lexical text. An empty or failed decode is
   absence of evidence, not evidence of fabrication — keep, and report it as unadjudicated.

It is one-directional like every other probe in this file: a recovered numeral can only ever
**refuse** a strip. There is no arm of the rule where a probe result causes a removal that text
alone would not already have caused, and `test/run.js` asserts that against three different probe
behaviours.

### 4.4 Condition 3 is where the whole thing was nearly lost, so read this one

The obvious rule is "does the isolated decode *open* with the numeral?" — the marker is
segment-initial, after all. **That rule destroys the word.** Decoded alone, the real marker's span
returns the numeral seven words in, because the fabricated decode had put the segment boundary 1.7 s
early and the clip therefore opens with the tail of the previous turn. A head-anchored rule strips
56 of 57 correctly and the 57th is the one that matters.

The whole-clip rule pays for that with a named false negative: a marker whose segment body happens
to quote its own numeral is kept, and the fabrication survives. **Zero of 57 on this artifact**, and
it is the direction this file always errs in.

### 4.5 The false-positive control: real spoken numerals

The corpus's genuine enumeration is the two action-list markers the detector already protects. Cut
and decoded the same way, they return `"close. 1. Exponential backoff with jitter, shipped in
2.7.4..."` and `"...dashboard first. Three, we added a synthetic canary job..."` — digit form in one,
word form in the other, which is exactly why condition 3 reads both. The rule refuses to strip
either. Three real numerals exist in this corpus; the mechanism protects all three.

### 4.6 What it costs, and when

Nothing, until the class fires. Detection is pure arithmetic over text, and the four conditions are a
channel-level verdict that has been met by exactly one artifact ever. When it does fire the price is
`2 × markers` isolated decodes through one `whisper-cli` invocation, capped at
`insertionProbeBudget: 80` per channel. Measured on the artifact, machine otherwise idle: **114
isolated decodes in 134-136 s through one `whisper-cli` invocation** for a 685-second channel — the
same order as the deletion detector's 12.7% of pipeline time, and it scales with the number of
fabricated markers rather than with call length. Markers past the budget are kept and named as
unadjudicated, never as clean.

---

## 5. What is in the record after this

`record.pipeline.repetitionGuard` gains `insertionProbeAvailable` (a property of the WIRING, true on
every run whether or not the class fires), `insertionsRepaired` and `insertionsKeptSpoken`. And
`unrepaired` changes meaning in the honest direction: it used to count the whole finding, and now
counts only what is **still in the transcript** — a numeral the audio backs, or a marker nothing
looked at. `guardWarnings` follows the same rule the other repaired classes follow: no warning for
what was removed, a warning for everything that was not, and a separate line saying a kept numeral
is the guard refusing to delete real speech rather than a defect.

---

## 6. Verification

- **`node test/run.js`: 251 passed, 0 failed** (233 before this work; 18 new).
- **`node test/e2e.mjs`: ALL E2E CHECKS PASSED**, 1 named skip (a real loro vocabulary on this
  machine, depended on by no assertion).
- **Every check was run RED at least once by breaking the shipped source.** Seventeen mutations, in §7.
- The corpus reproduction, the 72-finding acceptance measurement at both decode configurations, the
  sweep, the end-to-end count, the per-class attribution of what is still lost, the stutter-class
  before/after, the sibling-instrument check, the three insertion strip rules, the insertion
  false-positive control and the probe's cost are each in `measurements/`, printed by the tool in
  `tools/` named in the assets README.

### 6.1 The new fixture

`TURBO_NUMERAL_INSERTION_ISOLATED_DECODES` — the 57 suspect markers' real isolated re-decodes, both
paddings, cut by the product's `cutSpan` and decoded by the product's `transcribeClips` in one
`large-v3-turbo` invocation. It makes §0(f) a thing `node test/run.js` re-runs rather than a number
in a document. Sample C only; no private speech.

---

## 7. The mutations

Every one applied to the shipped source, suite re-run, source restored (`/tmp/mutate2.py`
reproduced in `norm-repetition-residual-2026-08-30-assets/tools/mutations.py`).

| # | mutation applied to the shipped source | suite | result | first check to go red |
|---|---|---|---|---|
| 1 | class-1: the 3-word veto floor put back (minWordsForBurstVeto 1 -> 3) | `test/run.js` | 1 check(s) RED | a SHORT repeated phrase is clamped to what the audio holds — the 2026-08-30 residual, closed |
| 2 | class-1: the keep floor lowered below one delivery (max(1, ...) -> max(0, ...)) | `test/run.js` | 7 check(s) RED | the guard collapses the real large-v3 4x repetition loop to a single line |
| 3 | class-2: an EMPTY isolated decode counted as proof of fabrication | `test/run.js` | 3 check(s) RED | a marker is only ever stripped on POSITIVE, agreeing evidence from both paddings |
| 4 | class-2: the numeral matched in DIGIT form only | `test/run.js` | 5 check(s) RED | numeralInText reads a numeral in EITHER form, anywhere, and says "empty" rather than "absent" |
| 5 | class-2: the numeral test anchored to the HEAD of the clip | `test/run.js` | 3 check(s) RED | numeralInText reads a numeral in EITHER form, anywhere, and says "empty" rather than "absent" |
| 6 | class-2: 'spoken' requires BOTH paddings to recover the numeral, not either | `test/run.js` | 1 check(s) RED | a marker is only ever stripped on POSITIVE, agreeing evidence from both paddings |
| 7 | class-2: a thrown probe no longer falls back to detect-only | `test/run.js` | the suite CRASHED (the guard is load-bearing) | — |
| 8 | class-2: the per-channel probe budget removed | `test/run.js` | 1 check(s) RED | the probe BUDGET caps the decodes and the markers past it stay in the text, named |
| 9 | class-2: the channel name no longer reaches the probe | `test/run.js` | 1 check(s) RED | the insertion probe is routed PER CHANNEL — it is told which wav to cut |
| 10 | class-2: the KEPT-because-spoken warning dropped from verification.json | `test/run.js` | 1 check(s) RED | a repaired insertion says what it removed AND what it left, and the two never merge |
| 11 | class-2: unadjudicated markers no longer warned about | `test/run.js` | 1 check(s) RED | an insertion NOTHING adjudicated warns that it was not adjudicated — never that it was clean |
| 12 | class-3: the hand-off removed — the stutter class may collapse what class 1 preserved | `test/run.js` | 2 check(s) RED | class 3 does NOT collapse the deliveries class 1 preserved on the audio |
| 13 | class-3: the hand-off widened to any segment touching a protected span | `test/run.js` | 1 check(s) RED | the hand-off is scoped to the protected span — a real stutter outside one is still caught |
| 14 | class-1 -> class-3 hand-off: only PRESERVED runs handed over, not clamped ones | `test/run.js` | 1 check(s) RED | a CLAMPED run is handed over too, not only a fully preserved one |
| 15 | pipeline: stage 3.5 no longer passes a probe to the guard at all | `test/e2e.mjs` | 1 check(s) RED | the insertion class was wired with a way to REPAIR, not only to detect |
| 16 | pipeline: the wiring flag hard-coded instead of read back from the guard | `test/e2e.mjs` | GREEN — mutant SURVIVED | — |
| 17 | guard: the report claims a probe reached it when none did | `test/run.js` | 1 check(s) RED | the report says whether a probe REACHED the guard — "detect-only" and "clean" never merge |

**Two mutants are EQUIVALENT and are reported rather than hidden.**

1. Replacing `keep = max(1, min(runLen, capacity))` with `keep = max(1, capacity)` leaves the suite
   green, because any `keep >= runLen` takes the preserve branch and produces identical output. It is
   unobservable from outside the function. The `max(1, …)` floor itself is not equivalent — dropping
   it turns seven checks red (#2).
2. Hard-coding `insertionProbeAvailable = true` in the pipeline instead of reading it back from the
   guard's report is green **on a run where the wiring is intact**, because `true` is then the
   correct value. The mutant that matters is #15 — cutting the wire itself — and that one is red,
   as is #17, the guard claiming a probe it never received.

---

## 8. Not measured, and therefore not claimed

- **One artifact.** The insertion class's repair is measured on the only capture of that failure
  this project has. Its ground truth is exact (TTS of a written script), and n is 1.
- **Sample C is TTS.** No real recorded call has been through this harness, unchanged from every
  predecessor brief.
- **The probe's behaviour on a REAL fabricated ordinal in real audio is unmeasured**, because no
  real recording has produced one.
- **`insertionProbeBudget: 80` is not swept.** It is above the only observed marker count (57) and
  below anything that would cost minutes; nothing in the corpus constrains it.
- **The short-phrase clamp is measured on 31 findings from one recording.** Its safety is a
  property and does not depend on that number; its cost does.
- **The class-3 hand-off is measured on the two findings in this corpus where a run of four or more
  identical segments survived class 1.** The defect's mechanism is exact (`minChainLinks: 3` vs K
  identical segments) and does not depend on that number; the size of what it was costing does.
- **Class 4's four remaining end-to-end deletions are NOT fixed here**, deliberately. They are the
  residual its own header names — genuine quiet speech under the burst floor — and the fix it names
  is a per-span level probe, which that class avoids on purpose because it puts an ffmpeg call on
  every candidate. Naming it with a count on a second corpus is what this work adds; the decision to
  pay for it is not this task's.
- **Run-to-run determinism of the isolated decodes IS measured**, and is the one caveat that went
  away: the cost run re-cut and re-decoded all 114 clips from scratch and every row came back
  byte-identical to the committed fixture (57/57). What is still unmeasured is determinism on other
  hardware.

## Sources

- `richos-hq/docs/briefs/norm-brief-real-audio-92min-2026-08-29.md` and its assets — the 72
  hand-verified findings, their per-finding ground truth, and the four raw transcripts this work
  reproduced byte-identically.
- `richos-hq/docs/briefs/norm-brief-longform-fix-2026-08-29.md` and its assets — the physical veto,
  its parameter sweep, and the `veto-eval.mjs` arithmetic reused here.
- `richos-hq/docs/briefs/norm-brief-q5-call-transcription-2026-08-26.md` §6.3 and §12 — the captured
  insertion artifact, sample C's construction, and the reference script that makes its ground truth
  exact.
- `tools/richos-service/lib/repetition-guard.js`, `lib/deletion-guard.js`, `lib/substitution-guard.js`,
  `lib/pipeline.js` — the three instruments and the seam they share.
