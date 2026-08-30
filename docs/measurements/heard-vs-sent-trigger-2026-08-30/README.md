# The DIFF trigger, measured — 2026-08-30

**Nothing in this directory is private.** Every heard/sent pair measured here was invented for
the measurement and is written out in full in [`corpus/pairs.json`](corpus/pairs.json). No
dictation of anyone was consulted, no recording of anyone appears, and no line here is a real
dictated sentence. Every person, company, product and place name is fictional; the only
non-fictional terms are `Deepgram`, `whisper.cpp`, `Postgres` and `MySQL`, which already appear in
the public wiki as the doctrine's own worked examples.

---

## What was open, and what closed

RICH-TODOs row 3.4 built the whole comparison — `matchHeard`, `askCandidates`, `reviewSent` in
`tools/richos-service/lib/dictation.js` — and named exactly what it did not:

> **Still open: the automatic trigger** — inside RichOS's own composer it is a short wire, and
> today a correction is stated by command instead.

The flywheel brief said the same from the other side, and the spoken-trigger brief repeated it on
2026-08-30 when it closed the *other* half:

> The sentence above is about the DIFF trigger: what was heard against what was sent. That still
> needs the composer wire or the Accessibility read-back, and it is still open.

This is that wire, and this measures it.

**The wire is short. The two ends are not where the sentence implies.** RichOS's own voice mode is
not a source of "heard" text at all — `rich://voice-transcript` goes straight into the thread as a
turn (`app/ui/main.js`), so there is no window in which the CEO could edit it. The composer's
dictated text arrives from **open-wispr**, a separate application, and the "heard" side is the
journal our own patch makes it write (`tools/richos-hud/dictation-flywheel.patch`). So the wire is:
*at send time, ask the journal whether this text is a dictation he changed.*

---

## Why the bar is higher here than for the other two triggers

The utterance trigger fires on *"It's Kestrel, not Kestral"*. The belief trigger fires on *"the Q3
number was 1.4, not 1.2"*. Both are things he **said**, and after either of them a question is an
obvious follow-up to something he just volunteered.

This one takes no statement at all. He dictated, the recogniser mis-heard, and **he fixed it
silently and moved on.** That is what makes it the highest-quality correction signal in the
product — and it is why a false ask costs more here than in either trigger before it. After a
spoken correction, a question is a reply. After a silent edit, a question is RichOS announcing
that it watched him type. §7's usual *"a false ask is cheap"* is deliberately not the reasoning
applied below.

---

## 1. The conditions, all required

The implementation is `app/crates/richos-core/src/heard.rs`.

**1. The sent text is a dictation, corrected.** `match_heard`: an unconsumed journal entry within
ten minutes, at least **0.60** similar to what was pasted. Below that the message was typed and
the trigger is silent.

**2. Something was SUBSTITUTED.** `token_replace_hunks`, the LCS reduction `capture.js` already
uses, ported. A pure insertion or a pure deletion is never a hunk — which is how most trims and
afterthoughts stay silent with no rule of their own. **Most, not all:** a trim that runs into the
end of a sentence turns the neighbouring token into a substitution against its own punctuated form
(*"…to Marla today please."* → *"…to Marla."* is **one hunk**, not three deletions), so three of
the corpus's ten trims are actually silenced by condition 3.

**3. Neither side of the change is a grammar word.** This condition is new here, and it is the one
that earns the number — see §3. `spoken.rs` gets it for free: its spans are scanned by
`is_span_token`, which stops dead at a grammar word. A token diff has no scanner, and **a composer
message opens with a capital letter**, so un-gated `looks_like_term` believes it.

**4. The pair clears §7's gate** — `spoken::gate`, the shipped one, called rather than copied. It
is run on the **core** of the hunk, not on the expanded span, because the expansion wraps identical
context around both sides and identical context inflates every score.

> **The gate judges the core; the vocabulary learns the span.** `Rich Hand` → `Rich Hanna` is
> learned whole and judged on `Hand`/`Hanna` (0.600, not the expanded span's 0.889). Learning the
> lone delta would corrupt the ordinary word *"hand"* in every future decode.

---

## 2. The headline: precision, measured

```text
  156 invented heard/sent pairs — 39 corrections, 117 not.
  TP 35   FP 1   FN 3   TN 117        precision 0.972     recall 0.921
```

**The negatives are adversarial, not representative.** Twelve are freshly typed messages offered
against a live journal; twelve more are typed messages that *resemble* a dictation in the window;
fifteen are typo fixes on words that are capitalized and term-shaped; twenty are changes of mind;
and the rest are rewordings, trims, afterthoughts, casing fixes and wholesale rewrites. So
**0.972 is a lower bound** on precision in use. Recall is unaffected by the imbalance.

A candidate whose **pair** is wrong scores as a false positive, not as a partial hit — the pair is
what reaches `learn-term`, and a wrong pair poisons the vocabulary he then dictates against.

Full run: [`results/precision.txt`](results/precision.txt). Reproduce:

```sh
cargo test -p richos-core --test heard_precision -- --nocapture
```

---

## 3. The condition that earns it

The same corpus with condition 3 removed:

```text
  TP 35   FP 18   FN 3                 precision 0.660     recall 0.921
```

**Seventeen false positives, and recall does not move at all.** Fourteen are typo fixes, each of
them capitalized, term-shaped, and comfortably through §7's gate:

| what he fixed | spelling | sound | verdict without condition 3 |
|---|---|---|---|
| `Your` → `You're` | 0.67 | 1.00 | `Add "You're" to your vocabulary?` |
| `Its` → `It's` | 0.75 | 1.00 | asked |
| `Their` → `They're` | 0.57 | 1.00 | asked, on the sound leg |
| `There` → `Their` | 0.60 | 1.00 | asked |
| `Who's` → `Whose` | 0.60 | 1.00 | asked |
| `Then` → `When` | 0.75 | 0.50 | asked, on the spelling leg |
| `To` → `Two` | 0.67 | 1.00 | asked |
| `Wont` → `Won't` | 0.80 | 1.00 | asked |

The other three are trims whose leading filler collided with the sentence (`Actually, book` →
`Book`). **This comparison is an assertion in the test, not a sentence here**, so a future change
that makes the condition free fails the suite rather than leaving this table quietly wrong.

---

## 4. The one false positive, named

`c08` — *"Marcus Web owns that account now."* corrected to *"Marcus Webb owns that account now."*

The name **opens the sentence**. `capture.js`'s expansion refuses to absorb a sentence-initial
token, and rightly: a capital there is grammar, not evidence of a name. But that means the pair
collapses to the naked delta `Web` → `Webb`, and **as a vocabulary entry that rewrites the ordinary
word "web" in every future dictation** — precisely the harm the expansion exists to prevent,
defeated by position. The prompt he would see is `Add "Webb" to your vocabulary?`, which does not
reveal what the mangled side is.

**The defect is in the SHARED rule, so `capture.js`'s call-transcript path has it too.** It is
reported rather than patched around, because the two repairs available inside `heard.rs` are both
worse than the disease:

- refuse every hunk whose expansion was blocked at a sentence boundary — which also loses
  `Marla | Kestral` → `Kestrel`, a perfectly safe pair: **−1 recall for −1 false positive**;
- invent a token-length threshold to fit one row.

The behaviour is pinned in the shared fixture (`spoken_gate_agreement.rs`), so if either
implementation changes it, the number above stops being true and the suite says so.

---

## 5. The pairing condition earns nothing measurable here, and is kept anyway

Offering all 156 sends against **every other row's dictation** — 24,058 wrong answers available,
all inside the window:

```text
  pairing ON  (0.60 floor):   52 of 156 sends claimed a foreign dictation,  15 questions
  pairing OFF (0.00 floor):  156 of 156 sends claimed a foreign dictation,  15 questions
```

The floor cuts wrong pairings by two thirds — and cuts the **questions** not at all, because all
fifteen are *correct* vocabulary pairs found against a genuinely similar earlier dictation
(`Kestral` → `Kestrel`, `Dana Okonko` → `Dana Okonkwo`), which is the behaviour we want. So the
condition's keep rests on the first number and on doctrine — this trigger is about a dictation he
corrected, and a diff against an unrelated sentence is not one — **not** on the second. Saying so
here is what stops the second being claimed for it.

---

## 6. Two things the shipped JavaScript gets wrong for this trigger

**It diffed the wrong side of the journal — now fixed in BOTH implementations.** A journal record
carries `text` (what the recogniser produced) *and* `emitted` (what was actually pasted, after the
shared vocabulary corrected it on the way out — `dictation-flywheel.patch`: *"Keeping BOTH is the
whole point"*). `reviewSent` used `text`. But `emitted` is what he SAW and therefore what he
edited. Measured over the corpus's `emitted-*` rows:

```text
  diffing `emitted` (shipped here): 1 ask
  diffing `text`    (the JS path):  5 asks
```

The four extra are pairs **the vocabulary already holds**, asked at a moment when he changed
nothing at all.

Because that would have left the CLI and the app answering the same question differently — the
exact drift `spoken_gate_agreement.rs` exists to prevent — `lib/dictation.js` now reads every
record through a shared `heardSide()` and `richos-service dictation-review` reports the pasted
side rather than the raw one. A record with no `emitted` (an older one, or one written before
patch 3) falls back to `text`, which is exactly what shipped before; the fallback has its own
positive probe in `test/run.js` so it cannot become a second silence.

**It has no structural refusal**, because it never needed one — §3. That one is NOT ported back:
`askCandidates` is also reached by the call-transcript path, whose spans do not open a composer
message, and tightening a shared gate to fix a problem only one caller has is how a rule stops
being one rule. `heard.rs` applies it, and says so.

---

## 7. What is NOT closed

**It ships OFF BY DEFAULT.** `RICHOS_HEARD_TRIGGER=on`. This is the only one of the three triggers
that did not measure 1.000, its one false positive would corrupt an ordinary English word, and it
fires on an edit he never volunteered. Until §4's defect is repaired in the shared expansion rule
where it lives, the CEO turns this on deliberately or not at all.

**The heard side does not exist on his machine yet.** `~/.config/open-wispr/` currently holds
`config.json`, `hud-backups`, `models` and `recordings` — and no `dictation-journal`. The journal
is written by **patch 3** (`tools/richos-hud/dictation-flywheel.patch`), which is built and
documented but is not what is installed. Until that build is installed, this trigger reads an
empty directory and stays silent, correctly and by construction. **Nothing in this work changes
that, and no number here should be read as evidence that the loop is turning on his machine.**

**Corrections made in other applications.** Gmail, Slack, anywhere that is not RichOS's composer
still needs the Accessibility read-back §7 defers. Nothing here approximates one.

**Two recall holes, measured rather than assumed away, and both are ROWS in the corpus:**

- `buried-01..03` — a real name fix made inside a wholesale rewrite. The rewrite drops the pair
  below the pairing floor and the correction is lost. This is all three of the misses.
- `c35` — *"whisper cpp"* → *"whisper.cpp"* is a correction he really made and is **still** not a
  vocabulary entry: both sides normalize to one key, and `correct.js:131-132` skips any mangling
  whose normalized form equals the canonical's. Labelled by the OUTCOME, which is what the labels
  mean.

**Real dictation.** Every number here is measured on invented pairs, which is the correct way to
measure it and is not the same as the CEO using it. One real dictation, journalled; one real
silent edit, asked and confirmed; the next dictation spelling it his way — that is the test this
cannot substitute for.

---

## Files

```
corpus/pairs.json                             156 labelled heard/sent pairs, every one invented
results/precision.txt                         the full run, including every ask and every miss
app/crates/richos-core/src/heard.rs           the trigger
app/crates/richos-core/tests/heard_precision.rs      this measurement, pinned as a test
app/crates/richos-core/tests/heard_trigger_tests.rs  the completion criterion, end to end
app/crates/richos-core/tests/spoken_gate_agreement.rs the JS/Rust anti-drift pair
app/ui/tests/shots-5c/                        what the CEO actually sees
```
