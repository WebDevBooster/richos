# The CEO-RULED gate — the corpus, the rate, and what it does not catch

`guard-ceo-ruled-ask.sh` refuses a question to the CEO whose subject his record
has already ruled. `notice-ceo-ruled-prose.sh` reports the same thing for a
question asked in prose. Both take their whole verdict from
`scripts/lib/ceo-ruled.py`.

**This page exists because a blocking gate with a false-positive class gets
waived, and habitual waiving is how a defense decays into a formality.** So the
rate is measured against the real record and the real questions on this machine,
stated here, and the anchors that could not meet it were deleted rather than
tuned.

---

## The failure being engineered out

2026-09-01. Three times in one evening the orchestrator put a question to the
CEO that the record already answered, and each answer had been written down by
the orchestrator itself hours or days earlier.

| # | The question | Where the answer already was |
|---|---|---|
| 1 | What a customer installs — three options offered | `open-items.md` row 3.14, his own standing instruction: *"automatically download and install whatever the user needs"* |
| 2 | Is the mark one tone or two | `ceo-decisions.md` §21 › The logo — APPROVED |
| 3 | The splash screens, restated as "seven approved" | `ceo-decisions.md` §21 › The splash screens — TWO |

His reply to the first said, in the sharpest terms he had used all week, that
he had already discussed and answered the identical question more than once.
The wording is in the private record; what this corpus measures is the count and
the class, not the phrasing.

**The mechanism, in one line: the orchestrator writes to the record constantly
and reads it almost never.** Nothing stood between "this looks like a decision"
and "ask him".

---

## Corpus 1 — every AskUserQuestion ever asked on this machine

Extracted from every session transcript under `~/.claude/projects`: **18 calls,
27 questions**, spanning 2026-07-27 to 2026-09-01. Every one is a real question
that was really put to the CEO. Each was flattened exactly as the hook flattens
it — header, question, and every option label and description — and run against
the live `ceo-decisions.md` (1,431 lines), `open-items.md` (284 lines) and
`femcboost/CLAUDE.md` (230 lines), which parse to **82 rulings**.

**Result: 2 of 27 fire. 7.4%.**

| Question (header) | Asked | Cited | Verdict |
|---|---|---|---|
| ACP adapter | 2026-08-31 | §16 Delete the ACP adapter | **Correct.** §16 is the ruling that came out of this very question. Asking it again today is exactly the defect. |
| Partitions | 2026-09-01 | `CLAUDE.md § American English` | **False positive.** The question was about where corpus partitions live; an option description happened to list his standing rules by name, American English among them. |

**So the false-positive rate is 1 in 27 — 3.7%** — and the one false positive
costs a single declaration, on a question that did name a ruled rule out loud.

### The three failures, and the positive control

Run against the same live record, as the AskUserQuestion calls they should have
been (wording taken from the transcripts, not invented):

| Case | Result | Cited |
|---|---|---|
| 1. What the customer installs | **REFUSED** | `row 3.14`, quoting *"Go ahead with 8.8 MB"* **and** the standing instruction *"automatically download and install whatever the user needs"* |
| 2. One tone or two | **REFUSED** | `§21 › The logo`, matched `title+token "logo / swoosh"`, quoting *"OK, go!"* |
| 3. Which splash screens ship | **REFUSED** | `§21 › The splash screens`, quoting *"I have never approved more than 2 splash screens"* |
| POSITIVE CONTROL: which monospace family should ship | **PASSES** | — nobody ever ruled it |

The positive control is not decorative. The register mentions a *monospaced*
face exactly once, as a finding about vendored fonts, and rules nothing about
it. `ceo-ruled.test.sh` case 3d proves that control is not passing over a dead
gate: it adds a real monospace ruling to the fixture and the same question is
then refused.

---

## Corpus 2 — every assistant turn, for the prose notice

The prose notice cannot block anything; the Stop event fires after the CEO has
read the message. Its only job is to put the ruling in front of the
orchestrator before the CEO answers, so it has to be quiet enough to be read.

**2,821 assistant text turns** across every femcboost session on this machine;
**193 of them carry an ask.** Three windows were measured before one was chosen:

| Window | Fires | Rate of asking turns | Catches the three prose failures |
|---|---|---|---|
| question SENTENCES only | 4 | 2.1% | **none** |
| the asking PARAGRAPH ← shipped | 9 | 4.7% | **1 of 3** (the Option D turn) |
| the WHOLE message | 51 | 26.4% | 2 of 3 |

The whole-message window fires on one turn in four. A notice at that rate is a
notice nobody reads, which is the same corpse in a louder coat. The sentence
window is quiet and catches nothing, because the Option D ask put its question
in a heading and the already-ruled sentence in the next line.

---

## The anchors that were built, measured and DELETED

The first implementation had three ways to match. Against corpus 1:

| Anchor | Fired | Examples of what fired |
|---|---|---|
| TOKEN — a single word rare across rulings and repeated inside one | — | "days", "char", "walk", "much", "move", "hole", "assets", "skill" |
| PHRASE — a 2-3 word phrase shared with a ruling's BODY | — | "anything else", "per session", "all companies" |
| **together: 18 of 27 questions — 67%** | | |

A ruling's body cites half the register; sharing words with it is not evidence
of anything. Both were deleted. What survives is the record's own statement of
what each ruling is ABOUT — its **title** — carried whole by the question.

Three further refinements. The first two were forced by a measured false positive; the third was not designed at all, it was found:

1. **Specificity is measured over TITLES, not bodies.** "splash screens"
   appears in the body of three rulings and is the title of exactly one. Body
   frequency answers "does the record talk about this"; only title frequency
   answers "is this what a ruling is ABOUT".
2. **A title fires alone only if it is multi-word AND carries a distinctive
   word.** Otherwise it needs a corroborating signal — a word or phrase rare
   across the register and *repeated* inside that one ruling.
   - Without the multi-word rule, the one-word CLAUDE.md titles "Surfaces" and
     "Pipeline" refused three unrelated questions about design-round surfaces
     and a prospects pipeline.
   - Without the distinctiveness rule, "start screen" refused two questions
     about when to schedule a migration, because one option said "It starts
     fresh" and another said "against your screen".

3. **The corroborating signal must be INDEPENDENT of the title.** Found by
   re-measuring against the live register *after another branch landed a ruling
   in it*: a section titled "The door" repeated the word "door", "door"
   corroborated "door", and a question from 2026-07-27 about extending the
   in-app recording door to the men's intros came back refused. One coincidence
   wearing two hats. The subject's own words are excluded now, the rate went
   back to 2 in 27, and `ceo-ruled.test.sh` case 3e reproduces the exact shape.

   **Worth saying plainly: the suite was green throughout that defect.** It was
   found by running the predicate against the real record one more time after
   the record had moved, which is the only kind of check that finds this class
   — and it is the reason section 8 of the suite runs against the live record
   rather than against the fixture alone.

Distinctive means: appearing in at most `RARE_FRACTION` (10%) of the rulings.
Over the live register that is 8 of 82, which puts "swoosh" (1), "certificate"
(2), "american" (3), "extra" (3), "splash" (6) and "payload" (8) on the
identity side, and "start" (10), "logo" (10), "whole" (12), "system" (16),
"type" (25) and "nothing" (29) on the vocabulary side. That split is the gate.

---

## What this does NOT catch — say it here, not in a postmortem

1. **A question phrased in entirely different words from the ruling's title.**
   Failure 2 is only caught because the question named the swoosh; had it said
   only "your mark", nothing would have fired. This is the price of never
   crying wolf and it is paid deliberately.
2. **A question asked in prose, at the time it is asked.** No PreToolUse event
   exists for a sentence in a reply. The prose notice arrives at the end of the
   turn, after he has read it, and catches 1 of the 3.
3. **An assertion.** Failure 3 was not a question — it was "the seven approved
   splash screens" stated as fact. Nothing that looks for an ask can see an
   assertion.
4. **Whether a ruling actually ANSWERS a question.** The gate says only that
   the question is about the same subject a ruling is about. The declaration in
   `scripts/ceo-ruled-exempt.sh` exists because that distinction is a human's.

---

## Reproducing the measurement

The corpus is the machine's own transcripts and the live wiki, so it is not
vendored here — a vendored copy would go stale and start reporting a rate that
is no longer true. `scripts/hooks/ceo-ruled.test.sh` section 8 runs the four
headline cases against the LIVE record whenever `richos-hq` is on the machine,
and says plainly when it is not rather than passing. Sections 1–7 run against a
fixture whose statistics are shaped to match, so the suite is deterministic
anywhere.

To re-measure corpus 1 by hand: flatten every `AskUserQuestion` `tool_use` in
`~/.claude/projects/**/*.jsonl` and feed each through `ceo-ruled.py` in `check`
mode with the three live record files as `sources`.
