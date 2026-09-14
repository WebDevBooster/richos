# Prescribed design: what cannot be refused, what can, and the one fact that separates them

**Author:** Sage (software architect). **Date:** 2026-09-14.
**Question put to me:** of the CEO's four named kinds of corrupted brief — false facts, wrong tasks,
wrong scope, prescribed design — the fourth is covered by nothing. Close it, or establish that it
cannot be closed and say precisely why.

**Answer, in one line:** *a prescribed design cannot be refused on its CONTENT — a check that could
tell a good design from a bad one at dispatch would make the round unnecessary — but the CEO scoped
the harm himself to "cases where finding new design options is the objective", and WHETHER THAT CASE
OBTAINS is arithmetic over a ledger the lead does not author. So the fourth kind is partly closable,
and the part that closes is a refusal, not a report.*

**Built:** §6 of `engine/scripts/brief-scope.py` (the `design:` disposition and the retry rule),
§4b (the counter-stamp), wired at `engine/scripts/lib/spawn.py:618-624`. Sixteen new suite cases,
four new mutants. **51 passed, 0 failed; 11 properties proven load-bearing.**

---

## 0. The premises I was given, checked before designing anything

The brief asked me to re-derive rather than trust. Three mattered.

**a. "Round 9's prescribed design came from the reviewer" — TRUE, and re-derived on both sides.**

```
$ sed -n '185p' /Users/alex/ab/richos/docs/verification/certification-frank-round8-2026-09-13.md
... A ref that appears inside one of the LEAD's own call windows is his, by the platform's word,
... a ref at an agent's unlanded tip that appears at any point in its run is the agent's UNLESS it
appeared inside a lead window ... That is a round-9 build, not a CEO decision.
```

**b. "The lead PARAPHRASES, which is what happened in round 9" — FALSE, and the correction changes
which candidate survives.** Measured with `difflib.SequenceMatcher` over both passages,
punctuation-normalized:

| measurement | value |
|---|---|
| distinct words shared / distinct words in the brief passage | **59 / 90** |
| longest exact shared span | **196 characters** |
| characters in shared spans of 40+ chars, of the brief passage | **351 / 778** |

Round 9 was **near-verbatim, not a paraphrase**. The failure record says so too (§10o:
"Near-verbatim, including the 'Do NOT build the alternative' instruction"). This matters because the
brief offers the paraphrase as the reason quote-detection would not work. That is not the reason it
does not work — §2b gives the real one, and it is stronger.

**c. Both statements the spawn-time provenance annotator flagged as unsourced are in fact sourced,
one level away.** "The CEO's four named kinds" resolves to
`richos/docs/verification/brief-scope-2026-09-14.md:6`, quoting him directly:

```
$ grep -n 'prescribed design' /Users/alex/ab/richos/docs/verification/brief-scope-2026-09-14.md
6: prescribed design (in cases where finding new design options is the objective)."
```

`g11`/`g12`/`g13` resolves to `richos-hq/docs/verification/lifecycle-failure-record-2026-09-10.md:224`
("three guards killed in one day"). Neither premise is wrong. **The clause inside the CEO's own
sentence — `(in cases where finding new design options is the objective)` — turns out to be the whole
design, and it was sitting inside a statement the annotator had marked as unsourced.**

**d. S21 exists and asserts the miss, as stated.** `bash engine/scripts/brief-scope.test.sh` before any
change of mine: `=== brief-scope tests: 35 passed, 0 failed ===`, including
`ok S21 THE MISS, ASSERTED: with point 2 red, round 9 item 2 passes untouched`.

---

## 1. Why content-based detection is impossible, and this is not a strong word

Three independent arguments, each sufficient.

**1. The reductio.** A mechanism that could distinguish a good design from a bad one at dispatch time
would make the round unnecessary — you would simply ask it for the design. Whether the mechanism works
is the question the round exists to answer. So no dispatch-time check can evaluate a prescription's
correctness, and every proposal that appears to must be doing something else.

**2. The form is shared with good briefs.** `brief-scope-2026-09-14.md` §3 puts it exactly right and I
re-derived it against this very brief: *"do not build a second reaper" is formally identical to "do not
weaken the guard"*. My own brief contains **"Do not answer with another reviewer"** and **"Do not
recommend Flutter"** lives in my standing identity. Both are prohibitions naming an implementation;
both are correct and load-bearing. A detector keyed on the shape would fire on all of them.

**3. The instance defeats every provenance answer, and did.** Round 9's attribution was correct, the
citation resolved, the source was a committed file with a SHA, the reviewer had flagged his own text as
a build decision, and the lead's commit message declared the construction principle
(`93dd7e0e`: *"both quoted from the reviewers who found them"*). `brief-provenance.py` passes it — not
by failing, but **because every provenance fact is TRUE**. Provenance establishes where a sentence came
from. It is silent on whether that origin is one anybody audits.

**So the honest finding is: the harm of a prescribed design is not a property of its text.** It is a
property of the relationship between the prescription and the future, and nothing at dispatch time
knows the future.

---

## 2. Both candidates in the brief, refuted — and the brief said to say so

### 2a. "Separate the finding from the remedy" — refuted

The proposal: a brief may carry the defect, its reproduction, the observable and the invariants, but not
the mechanism. It requires deciding, in prose, whether a sentence "names an implementation" or "states
an observable". That is content-based detection, so §1 applies directly.

It is also **worse than not having it**, for a reason specific to this codebase. The one measurement
anyone has taken of a prose-reading check here is mine, last night:
`claim-capability-2026-09-14.md` reports a **62% false-positive rate** on the records corpus and says it
is *"survivable in this shape and would be fatal in any other"* — the shape being non-blocking. A
blocking version at that rate is the `g11`/`g12`/`g13` death on day one. A non-blocking version is
failure type AB, a detector with no authority, which the brief's own constraint 1 rules out.

And the separation it asks for is not available even in principle. **The observable and the mechanism
are frequently the same sentence.** Round 9 item 2's observable —
`the lead's bookmark at an agent's unlanded tip is still recognised as the lead's` — presupposes the
lead-window design. Stripping the mechanism would have left an observable that only that mechanism can
state.

### 2b. "Non-collusive assignment" — refuted, and for a better reason than the brief gives

The brief doubts it can be detected when the lead paraphrases. §0b shows the lead did **not** paraphrase:
a 196-character exact span. **So quote-detection would have fired on round 9.** The candidate's stated
blocker is not real, and it still fails, three ways:

1. **It creates a gradient toward paraphrase, and paraphrase is a recorded failure type.** Any mechanism
   that penalizes quoting a reviewer rewards restating him. Type W names the restatement as its own
   defect: *"every paraphrase is a fresh surface for distortion — one of them distorted"*, and says a
   brief that points at a path *"carries the same authority and cannot drift from it."* A check that
   punishes the faithful relay and passes the lossy one has inverted the sign.
2. **Nothing was reviewed, so rotating reviewers changes nothing.** §10o is explicit: *"No artifact
   records a reviewer reviewing the round-9 brief before dispatch."* A rule about who may review a brief
   that nobody reviewed is a rule with no instance.
3. **It is another reader**, which constraint 2 forbids and the CEO's own experiment already falsified:
   two adversarial reviewers on every brief before every round, and it still drifted by round 7.

---

## 3. What IS available, and why it is a fact

Return to the CEO's sentence, and read the clause that had been treated as an aside:

> *"prescribed design **(in cases where finding new design options is the objective)**"*

**He scoped the harm himself.** A prescription is not harmful because it is a prescription; it is harmful
when the round's job was to FIND the mechanism. When the design is settled and the round is to implement
it, prescribing is the entire point of the brief.

So the question a machine must answer is not *is this design right* — impossible — but **is this a round
where finding a design is the objective**. And that has an answer in the existing ledger:

> **A point RED in the previous recorded verdict and RED STILL.** The measurement has not moved.
> Whatever approach the work has been taking is not closing it.

That is arithmetic over `<verdict>.history.jsonl`, appended from a harness run, parsed from `PASS C<n>` /
`FAIL C<n>` lines. **The lead does not author it** — which is the same standard the existing clauses are
built to, and the only standard that survived the CEO's reviewer experiment.

### The refusal

On an item anchored to a point on retry, the brief must declare who chooses the mechanism:

```
serves: point 2 - a codex/ ref deleted by an agent is restored
design: open                       the engineer chooses
design: spec point <N>             the mechanism is in the CEO's own page
design: ceo-word: <what he said, and when>
```

An undeclared retry item is **refused** (`DESIGN-UNDECLARED`, exit 2, the spawn does not happen). A
disposition that is not one of the three literal forms is refused (`DESIGN-NOT-A-DISPOSITION`) — the
token is matched literally, because a disposition needing interpretation is prose, and reading prose is
the thing this file refuses to do.

### The counter-stamp, and why it is not a report

Type AE's damage is an **authority transfer**, not a false statement: *"the brief arrives at the engineer
stamped `quoted from the reviewer who found it`, and that stamp is an argument for compliance. An
engineer who would have pushed back on the lead's design does not push back on the certifier's."*

So the counter is a stamp with better provenance, and `design: open` triggers it: `spawn.py` appends a
section to the dispatched payload saying the point has not moved, that **no sentence in the brief is
binding on the engineer's design**, and naming round 9 as the instance. The lead did not write it and
cannot remove it.

**This is the part most likely to be mistaken for failure type AB, so here is the distinction stated
plainly.** AB is *a detector that never misses and never intervenes* — it is addressed to an observer who
may act on it, and the cost is sunk by the time it speaks. The counter-stamp is not addressed to an
observer: **it modifies the instruction the agent receives, at the moment of dispatch, on the only copy
there is.** The precedent is already running and I found it rather than inventing it —
`brief-provenance.annotate()` at `spawn.py:618` rewrites every payload, and its output is the
"Provenance of this brief" section at the foot of my own brief, which is why §0b and §0c above exist at
all. **I re-derived two premises because a machine-written paragraph told me to, and the lead could not
have suppressed it.**

**Its residue, stated rather than discovered later: the counter-stamp's effect runs through what the
engineer then decides.** It gives him standing to refuse a prescription. It cannot make him use it.

---

## 4. What I built, with the commands

```
$ bash engine/scripts/brief-scope.test.sh
    === brief-scope tests: 51 passed, 0 failed ===
    === mutation: all 11 properties proven load-bearing ===

$ bash engine/scripts/brief-provenance.test.sh
    47 passed, 0 failed

$ bash engine/scripts/hooks/contract-integrity.test.sh --only base,manifest
    passed: 21   failed: 0
```

**The acceptance case is the real round-9 brief, byte for byte**, not one written to be caught:

| case | asserts |
|---|---|
| **S31** | the round-9 brief, anchored to point 2, point 2 red in two consecutive verdicts → **REFUSED `DESIGN-UNDECLARED`** |
| S31b | the refusal names the reviewer-authored prescription that produced it |
| S22 / S22b | a retry item with no `design:` line is refused, quoting the CEO's scoping clause |
| S22c | the refusal claims only red-then-red, never "a round was spent" — §5 |
| S23 / S24 / S27 | each of the three dispositions is accepted |
| S25 / S26 | a disposition naming a nonexistent point, or carrying a prescription, is refused |
| **S28** | **BOUNDARY:** a first-time-red point needs no disposition |
| **S29** | **BOUNDARY:** a green point is refused as `SPEC-SATISFIED`, not for its design |
| S30 / S30b / S30c | the counter-stamp is appended, the brief is intact above it, and a brief with nothing on retry is **byte-identical** after annotate |
| **S32** | **THE RESIDUE, ASSERTED:** `design: open` plus a prescription in the body still passes |

**The four new mutants**, each a property that cannot be removed without a real case going red:

| mutant | case that must go red |
|---|---|
| `design-undeclared-accepted` | **S31** — without it, round 9's brief is dispatched carrying the reviewer's design |
| `design-disposition-unchecked` | S25 |
| `retry-never-detected` | S22 — without the red-then-red rule, §6 never fires |
| `retry-over-triggers` | **S28** — the boundary is load-bearing in the other direction |

`retry-over-triggers` is the one I care most about: it proves the clause cannot be widened into the
false-positive class that kills guards without a case catching it.

### False-positive cost, measured against the real corpus

Constraint 3 asks for this measured on real briefs. **My mechanism reads no prose, so its content
false-positive rate is zero by construction**; the real cost is the declaration it forces. Measured:

```
$ for f in richos-hq/docs/plans/round*-brief-*.md; do grep -cE '^\s*(\*\*)?serves:' "$f"; done
    round6 0   round7 0   round8 0   round9 0   round10 0        (5 briefs)
```

All five real briefs carry zero anchors, so every one of them is already refused at `NO-ANCHOR` and
**§6 is never reached**. It adds no refusal to any brief that exists.

```
$ python3 -c "...integration.json..."
    bodies of work: 3   (femcboost-001, richos-001, richos-hq-001)
    spec recorded: False, False, False
```

**Zero bodies of work have a recorded spec, so the whole file — mine included — is silent on the live
system today.** The cost when a spec is recorded is one line per retry item.

---

## 5. A defect the build exposed in my own design, recorded because it is the house failure

My first draft of the refusal said *"This body of work already had a round spent on point 2"* and the
counter-stamp said *"has been through at least one round already."* **Neither is what I measure.** I
measure red-then-red, which is also true of a point **nobody has worked** — red in two verdicts merely
because no round reached it.

That is a verified number wearing a false name — failure type Y, the type I wrote the capability check
for last night — and I put it in a paragraph whose entire purpose is to be more trustworthy than the
lead's prose. Every sentence the module emits is now worded to claim only what was measured, and **S22c
asserts it** so it cannot drift back.

**The over-trigger itself is kept, deliberately.** The precise notion would be *"a point a previous
dispatch was anchored to, still red"*, and nothing records which points a dispatch claimed. Adding a
second ledger to find out is failure type X — one registration, many inventories — for a gain of one
line. And the over-trigger is benign in the way that matters: for a point nobody has worked,
**`design: open` is the true disposition**, so the line the lead is forced to write is the line he
should have written.

---

## 6. What this does NOT close, stated so it is never read as coverage

1. **A lead who writes `design: open` and prescribes anyway is not refused.** S32 asserts this. Nothing
   reads the prose; what the prescription loses is unchallenged authority, not its place in the brief.
2. **A FIRST-time-red point takes no disposition and no counter-stamp.** S28 asserts it. If round 9's
   point 2 had been red for the first time, §6 would let it through exactly as S21 records. This is a
   deliberate boundary — a brief opening work on a fresh point *should* carry a starting approach — and
   it is the largest hole.
3. **`design: ceo-word:` cannot verify he spoke.** Same residue the existing `scope-ceo-word:` hatch
   carries and for the same reason; the evasion is forced to become a fabricated quotation in a log.
4. **Whether a design is right remains human.** §1. Nothing here evaluates a mechanism, and the module
   header now says so in the same place it used to claim it "has no opinion about the design inside."

### The one thing I would build next, and why I did not build it now

`DESIGN-UNEXERCISED`: an item dispatched `design: open` obliges the round to record which mechanisms were
considered and which was chosen — an artifact the **engineer** authors — and the next dispatch against
that body of work is refused until it exists. It would have bitten round 9 exactly: the brief forbade the
alternative, so the contract would have been unsatisfiable and the engineer would have had to say so
before round 10 could be dispatched. **`round10-brief-2026-09-13.md` exists on disk**, so there is a real
instance to test it against.

I did not build it because it needs a record that does not exist, and inventing one without knowing where
it belongs is how type X happens. It is the right next round, and it is one round late by construction —
which is the honest shape of this whole answer.

---

## 7. The constraint on this document itself

The brief's opening constraint was that a design whose only auditor is its proposer has the shape of the
thing it is meant to stop. **This one's auditor is the mutation harness, not me**: eleven properties, each
proven by watching a named case go red, and the two that carry §6's claim are pinned to the real round-9
brief and to the boundary case in the opposite direction. **`design-undeclared-accepted` → S31 is the
whole claim as a falsifiable property:** remove my refusal and the round the CEO had to stop by hand is
dispatched, carrying an adversarial reviewer's own prescription, exactly as it was.
