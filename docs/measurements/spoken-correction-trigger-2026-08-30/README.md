# The flywheel's automatic trigger, measured — 2026-08-30

**Nothing in this directory is private.** Every sentence measured here was invented for the
measurement and is written out in full in [`corpus/utterances.json`](corpus/utterances.json). No
recording of anyone was consulted, no transcript of anyone appears, and no fixture here is a real
spoken sentence. Every person, company, product and place name is fictional; the only non-fictional
terms are `Deepgram`, `whisper.cpp`, `Postgres` and `MySQL`, which already appear in the public wiki
as the doctrine's own worked examples.

---

## What was open, and what closed

The correction flywheel has been complete at both ends since 2026-08-29. Its own brief named what
was not (`../correction-flywheel-2026-08-29/README.md` §5, "What is NOT closed"):

> **The automatic trigger inside other applications.** … Inside RichOS's own composer that is a
> short wire — we own both ends … Until one of those two is wired, a correction is stated through
> `richos-service dictation-review --sent "…"`, which is a real human statement and is exactly as
> safe, but is not the mini-HUD §7 describes.

`app/crates/richos-core/src/correction.rs` said the same thing from the other side: *"nothing here
watches for 'that's wrong' and files a proposal on its own … that trigger is named as unbuilt rather
than faked."*

**The CEO corrects Rich by talking.** A correction that needs a command typed is a correction that
will not be recorded. This measures the trigger that closes that.

**It is a different trigger from the one §5 deferred, and the difference matters.** That one is a
DIFF — what was heard against what was sent, which needs the composer wire or Accessibility
read-back. This one is an UTTERANCE: the CEO says *"It's Kestrel, not Kestral"* and the pair is
stated in the words. It needs no read-back of any foreign text field, which is why it could be built
now and the other could not. The diff trigger remains open.

---

## 1. What makes an utterance a correction

Three conditions, all required. The implementation is
`app/crates/richos-core/src/spoken.rs`.

**1. A contrastive repair FRAME, matched structurally** — not sentiment, not "he sounds annoyed",
not a model's judgement. A literal `not` pivot, in either order:

```text
  "It's Deepgram, not deep graham."      asserted before the pivot     Frame::Contrast
  "Not Briella — Priya."                  asserted after the pivot      Frame::PivotFirst
```

**The span under `not` is the rejected side; the other span is the asserted side.** That one rule
covers every order the construction comes in, which is why there is no direction heuristic. `n't` is
deliberately not a frame: *"that isn't Deepgram"* states what is wrong and nothing about what is
right.

**2. Both sides term-shaped, by the gate that already shipped.** This does the overwhelming majority
of the precision work and it is not new doctrine — it is `ceo-decisions.md` §7's, ported from
`tools/richos-service/lib/dictation.js`: `looks_like_term` on the asserted side, the day/month
refusal, and the spelling-OR-sound floors 0.28 / 0.6 / 0.6. That last draws the line that matters:

> **Two different names are a decision. One name spelled twice is a correction.**
> *"Postgres, not MySQL"* is a choice. *"Kestrel, not Kestral"* is a repair.

**3. An anchor** — the rejected form is looked for in the last eight messages, because a correction
is *of* something. Carried as **evidence, not as a gate**; see §3.

---

## 2. The headline: precision, measured

```text
  149 invented utterances — 34 corrections, 115 not.
  TP 32   FP 0   FN 2   TN 115        precision 1.000     recall 0.941  (32/34)
```

**The negatives are adversarial, not representative.** 86 of the 115 carry a standalone `not` pivot
on purpose — far denser than real speech, and loaded with the shapes that break a lexical detector:
weekday swaps, two-different-names decisions, enumerator swaps, quoted speech, numbers, preferences
between ordinary nouns, and plain prose that happens to contain the word. So **1.000 is a lower
bound** on precision in use. Recall is unaffected by the imbalance.

**Scoring is strict about the thing that would actually cause harm.** A staged candidate whose PAIR
is wrong counts as a false positive, not a partial hit, even when the utterance really was a
correction — because the pair is what gets learned, and learning `Kestrel -> Kestral` backwards
would corrupt every future decode. There is no credit for being nearly right about which two words
swap.

The matrix is pinned **exactly** in `app/crates/richos-core/tests/spoken_precision.rs`, not to a
floor, because a floor lets recall be traded away silently. Move the detector and the suite fails
until somebody re-measures and re-states the number.

**The two misses are named rather than rounded away:**

| | why |
|---|---|
| `"It's Yaro, not Jarrow."` | `y` carries no consonant class, so the phonetic key collapses to one digit (`6` vs `26`) and both legs fall short. A real hole in the phonetic leg, inherited from the shipped `phoneticKey`. |
| `"no not deep graham deepgram"` | Unpunctuated: no clause boundary, so the two spans cannot be separated. whisper.cpp punctuates (`richos-voice/src/stt.rs` strips no punctuation), so this is a tail case — but it has its own test so it cannot be quietly forgotten. |

Full table, every staged pair with both similarity legs and both misses:
[`results/precision.txt`](results/precision.txt). Reproduce:

```bash
cd app && cargo test -p richos-core --test spoken_precision -- --nocapture
```

---

## 3. The anchor: measured, then demoted

The obvious precision lever is to require that the rejected form actually appears on the record — a
correction is *of* something, so if the machine never wrote "deep graham" anywhere, what is being
corrected? It sounds right. It buys nothing.

| | precision | recall |
|---|---|---|
| anchor as **evidence** (shipped) | 1.000 | **0.941** |
| anchor as a **gate** | 1.000 | 0.882 |

**It removes 0 of 0 false positives and costs 2 of 32 true positives.** The CEO routinely corrects a
name he can still *see* on screen from further back than the window, or teaches one outright with no
prior mention at all — two corpus cases are deliberately unanchored for that reason. So the anchor
ships as the thing the confirmation UI quotes back to him ("you said Kestral here"), which is what
makes a one-keystroke answer answerable, and never as a reason to throw a correction away.

That comparison is itself an assertion in the test, so if a future change ever makes the anchor earn
its keep, the assertion that it does not will fail rather than this paragraph going stale.

---

## 4. Four defects the corpus found that reading the code did not

Every one was a false positive on a plausible sentence, and every one is now a named test.

1. **`It's` was offered as a name to learn.** `normalizeTerm` — the service's own, ported faithfully
   — turns an apostrophe into a **space**, so `It's` normalizes to `it s`, which matches no
   grammar word. `"It's not a bug, it's a feature"` therefore proposed `a bug -> It's`. Fixed with a
   separate `grammar_core` that *collapses* contractions instead of splitting them.
2. **A lone capital `A` was eaten by the article.** `"Ask about Series B, not Series A."` lost its
   `A`, leaving `Series -> Series B` at 0.75 similarity, which clears the floor and would have been
   asked. A lone capital is an initial, never the article `a`.
3. **`Series A` / `Series B` still scored 0.875 once that was fixed.** An **enumerator** swap is a
   distinction between two real things, not a mishearing of one, and *no threshold can separate it
   from `Kestrel`/`Kestral`* — the phrase around it is identical by construction, so both legs score
   it high. It is refused by SHAPE instead.
4. **The look-back reached across a comma into the wrong clause.** `"He told me it's Kestrel, not
   Kestral, but I have not confirmed it."` paired `confirmed` with a name two clauses away. The
   look-back now fires only when the pivot OPENS its clause, and never across a full stop.

A fifth defect, in the source this ported from, is recorded in §6.

---

## 5. What was built, and what it refuses to do

| | |
|---|---|
| `spoken.rs` | the detector. Pure. Returns candidates and, separately, every refusal with its reason — a silent filter cannot be audited. |
| `staging.rs` | the desk. Durable JSONL, `sync_all` per record, §7's three outcomes as the state machine. |
| `spine.rs` | the wire: `submit_prompt` step 1b, before the queue/deliver branch. |
| `src-tauri/main.rs` | the desk at `<app-data>/spoken-corrections.jsonl`, six commands, `rich://correction-staged`. |

**It stages. It never learns.** Precision 1.000 does not change that, because §7 is a ruling and not
a performance target:

> *"Inference cannot tell 'ship Thursday' → 'ship Friday' (a change of mind) from 'deep gram' →
> 'Deepgram' (a real correction). Asking removes the class of error entirely… **Nothing is ever
> learned silently.**"*

There is no function in either module that writes a vocabulary without a human answer, at any
threshold, at any setting. A precision measured by the author of the corpus is evidence about the
*shape* of the errors, not a licence.

**It does not detect a correction of MEANING.** *"No, the Q3 number was 1.4 million, not 1.2"* is a
correction of a belief and belongs to `correction.rs`'s loro write loop, not to a vocabulary.
**Which utterance shapes should reach the loro desk is a CEO decision that has not been made**, so
nothing here guesses it — numbers are not term-shaped and fall out at condition 2. See §7.

---

## 6. One defect in the source that was ported from

`dictation.js`'s `phoneticKey` documented `phoneticSimilarity("Thursday","Friday")` as **0.25**. The
keys it prints are right (`3623` / `163`) but `levenshtein("3623","163") = 2`, not 3, so the value is
`1 − 2/4 = 0.50`. Confirmed against the shipped JS itself, not only against the Rust port:

```bash
node -e "import('./lib/dictation.js').then(m=>console.log(m.phoneticSimilarity('Thursday','Friday')))"
0.5
```

The verdict was always right — 0.50 is under the 0.6 lone-token floor, so the pair is silent — but
the **margin** on §7's archetypal change-of-mind pair is 0.10, not the 0.35 the comment implied.
Four times thinner than the file said, on the one pair the whole decision is argued from. It matters
because §7 explicitly invites loosening the phonetic floor, and at 0.5 that floor would start asking
about weekday swaps. Corrected in place.

---

## 7. What is NOT closed

**The DIFF trigger — the one §5 of the 2026-08-29 brief deferred — is still open.** This closes the
*utterance* trigger only. A correction made by silently editing text before sending it still needs
either the composer wire or the Accessibility read-back spike, and the open question there remains
read-back *reliability* across native, Electron and web fields, not the permission.

**No UI renders any of it.** The six Tauri commands exist and are reachable, `rich://correction-staged`
fires, and `app/ui/` listens to none of it — the same gap `loro-writer.md` records for the loro
correction desk. The record is real from today; the mini-HUD §7 describes is a UI slice.

**A CEO DECISION IS NEEDED, and nothing here guesses it.** *"No, the deadline is the 14th, not the
12th"* is a correction of a BELIEF, not of a word. The machinery to record it exists —
`correction.rs`'s desk takes exactly that shape of proposal — and the trigger deliberately stays
silent on it, because deciding which spoken belief-corrections should become loro proposals is a
question about what Rich is allowed to write down about the CEO's world, and only he can answer it.
Everything that does not depend on that answer is built.

**Real speech.** Every number here is measured on invented sentences, which is the correct way to
measure it and is not the same as the CEO using it. One real utterance, one real ask, one real
confirm, and the next transcript spelling it his way — that is the test this cannot substitute for.

---

## Files

```
corpus/utterances.json   149 invented utterances, labelled, each with the record it was said against
results/precision.txt    the full table: every staged pair with both legs, and both misses
```

The measurement lives as a TEST (`app/crates/richos-core/tests/spoken_precision.rs`) rather than a
script, so the number cannot go stale without the suite going red.
