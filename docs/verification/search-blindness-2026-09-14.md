# A durable solution to false premises in briefs already exists, it is not a check, and it caught all of these before you saw them — what I added closes one more category and the remainder is stated

**Author:** Sage (software architect). **Date:** 2026-09-14.
**The question, verbatim:** *"Is there a way to develop an actually working, durable solution for
that? Or does such solution already exist?"* — about a lead repeatedly handing engineers false
premises, every one caught by the engineer and none by the lead. **He suspects it has been there a
long time and he got lucky in noticing it.**

**The short answer, in one sentence.** A durable solution exists and has been running: the brief marks
what the lead has not verified, and the ENGINEER re-derives it — which is what caught every instance
of the night in question, and which the record shows has caught at least thirteen false brief premises
across this project; no mechanism can be built that makes the lead accurate; and for the specific
category behind his question I built a fifth automatic check, shipped with this record, which catches
the instances and leaves a remainder I name rather than hide.

**On the luck.** He did not get lucky. Every one of the three was caught, escalated and corrected on
the day, by the mechanism designed for it. What he noticed was not a leak — it was the catches.

---

## 1. The premises I was given, checked before I designed anything

The brief marked all of these as the lead's account rather than measurement, which is the discipline
working. Three of them needed correcting, and one of the corrections changed the design.

| asserted in the brief | measured | how |
|---|---|---|
| "the category NEITHER of them covers" | **FALSE as stated.** Reconstructed with their commands, the existing checks put a row on two of the three | instance 2 gets a **capability** row; instance 3 gets a **provenance** row — `brief-provenance.py` at `4472d954`+`2d072389`, reconstructions in the scratchpad |
| "three instances in one night, each becoming a briefed premise" | **Two of three corroborated in the brief corpus; the third is not there.** Instance 1 is `tom7-brief.md` line 11, instance 3 is `zach13-brief.md` lines 13/24/27/40. `ALREADY ACKED` appears in `sage5-brief.md` in its CORRECT form — quoted as the guard's own output with "reproduce it" beside it | `grep -ln` over the 30 `*brief*.md` files in the session scratchpad |
| "the pairing rule — two commands, one empty, one not — is checkable without judging prose" | **True, and useless.** Checkable, and it catches **none of the three**. §4 | re-derived against the real code |
| "9 for 9, every one caught by the engineer" | **Not re-derived as 9 of 9, and corroborated in kind and then some.** 13 escalation records whose title names a false premise or a wrong claim, 5 of them dated 2026-09-14 | `ls docs/verification/escalations/ \| grep -icE "premise\|is-false\|are-false\|is-not-broken\|wrong"` → `13`. A title grep, so a LOWER BOUND — which is itself an instance of the failure this document is about, and it is marked rather than rounded up |

---

## 2. What actually happened to each of the three, in the briefs as they SHIPPED

This is the measurement that reframes the whole question, and it is not the story any of us was
telling. **None of the three briefs cited the search.** The search happened in the lead's head and only
the conclusion reached the page.

| # | the brief | did it cite the search? | what the lead did | what caught it |
|---|---|---|---|---|
| 1 | `tom7-brief.md` line 11 — *"`git init` appears nowhere in that suite"* | **no command anywhere near it** | marked it: *"His explanation, to be verified rather than assumed"* | the engineer. `esc-20260914T103619Z-9c47c035`: *"The suite DOES build repositories; the brief's premise was a two-word search result."* Corrected in place at `engine/scripts/hooks/contract-integrity.test.sh:356` and `engine/scripts/lib/hook-dependencies.sh:79` (line numbers at `1fbbd3ad`) |
| 2 | not present in the 30-brief corpus | — | — | unknown; it may never have been briefed |
| 3 | `zach13-brief.md` — *"byte-identical across 53 rooted hooks"* | no | marked it: *"The 53 is his; re-derive it."* | the engineer. `esc-20260914T105902Z-e10ccf88`: *"Re-derived all three facts the brief flagged as unverified. Three of its numbers were wrong."* 60 carriers, not 53 |

**Both times the lead marked it. Both times the engineer re-derived it. Both times the engineer was
right and escalated durably.** That is a solution, it is durable, it survives the mailbox, it survives
the branch never being merged, and it was already running before the question was asked.

### What the existing checks say about those two briefs

Run at `1fbbd3ad` before my change:

- `tom7-brief.md` → **4 rows, and NOT ONE of them on the false sentence.** They are on `100`, `25` and
  three `157`s.
- `zach13-brief.md` → **4 rows, every one of them on the count `53`.** The check agreed with the
  engineer independently of the lead's mark.

So checks 1-4 were already half-covering this, on the instance that carried a number. The uncovered
half is instance 1, and §3 is why.

---

## 3. Why instance 1 slipped the one check that should have had it — and the defect underneath

`tom7-brief.md` line 11 cites nothing. Check 3 flags a claim with no source. It said nothing. The
reason is worth the whole investigation:

```
evidence in scope: ['command']
```

The block was read as SOURCED. The only backticked span in it is `` `git init` `` — the string the
claim was wrong about — and `is_command()` accepted it, because it has two tokens and starts with a
program name. **The string the claim was wrong about was counted as the evidence for it.** The false
premise armored itself with its own subject.

Fixed in this pass. **A span that was NAMED is not a span that was RUN**: an invocation carries a flag,
a path, a pipe, a redirect, an extension, or a third token; a bare `verb noun` pair is how prose names
a command it is talking about. Measured before adopting, because widening what counts as unsourced is
the direction that turns a report into wallpaper: **+3 rows over 30 briefs, +3 over 31 spawn payloads,
+25 over 65 records.**

---

## 4. The candidate in the brief, pushed on hard, and rejected on measurement

The shape proposed: *a claim resting on a search that found nothing or few must cite a second command
of the same shape that DOES find something.* This is the 2026-05-08 rule transplanted literally —
pair every negative probe with a positive control.

**It catches none of the three.** Re-derived against the real code:

| # | why the control fails |
|---|---|
| 1 | **The search was not empty.** `grep "git init"` on that file returns **one** hit — the comment making the claim. A control that demands "show a search of this shape that finds something" is satisfied by the search itself and adds no row, while the claim stays false |
| 2 | The control would prove the path readable and the tool working. **Both were.** The pattern was still a rendering of a `%d` template: `guard-ci-red-lands.sh` prints `ALREADY ACKED %d TIME(S)`, and a literal containing `26` cannot appear in the source that renders it however often it prints |
| 3 | There is no search. It is a count of a typed list, reported as a count of files |

**A control proves the PLUMBING. All three failed at the SELECTOR.** That is the finding, and it is why
the 2026-05-08 rule does not transplant as written.

What DOES recover instances 1 and 2 is a strictly WEAKER selector, and I checked both:
`grep -rn 'init -q'` finds `contract-integrity.test.sh:1621`; `grep -rn "ALREADY ACKED"` finds
`guard-ci-red-lands.sh:794` and `guard-ci-turn-gate.py:787`. But "weaker" is a direction a person
chooses, not a property two strings have, and it is not free — broadening instance 1 all the way to
`init` returns **51** lines, most of them the word *definition*. **So the mechanism names the discipline
and does not pretend to verify it.**

### And "did the search return nothing" cannot be detected, and does not need to be

A brief quotes a command and rarely its output, so emptiness is usually invisible. It is also not the
signal: **instance 1's search returned a hit and was just as wrong.** The negative claim lives in the
brief's own prose, which is always there. Emptiness was never what mattered.

---

## 5. Where the line is — the question that decides whether the check lives

*"The working tree is clean"* also rests on a search that found nothing, and it is fine. What separates
it from *"`git init` appears nowhere"*? Not emptiness. This:

- **A CENSUS enumerates its domain.** `git status`, `ls`, `git branch` — nothing the author wrote stands
  between the domain and the answer, so empty output IS the absence.
- **A SELECTOR SEARCH puts an author-written pattern in front of the domain.** `grep PATTERN`,
  `find -name PATTERN`. Empty output is then ambiguous between the thing being absent and the pattern
  not matching its spelling, and no exit code and no re-run can tell the two apart.

That alone still fires on every correct grep claim, so a second condition does the discriminating work:
**the sentence must not name the pattern that was searched.** A sentence about the string is grep's own
question and grep answers it exactly; what went wrong in all three was a silent translation from a
STRING to a CONCEPT — repositories, logging, carrying the bootstrap. That translation is the defect,
and it is visible without judging whether anything is true.

**The rule this restates is already in `CLAUDE.md`, written for colors:**

> A value has more than one spelling. `#8F7030`, `#8f7030` and `rgb(143,112,48)` are one colour.
> Grep for the thing, not for one of its forms.

Written 2026-09-01 about a hex code, never pointed at a claim about code. That is the fourth rule in
this session found to apply one domain over from where it was filed.

---

## 6. What I built, and what it says about each of the three

`engine/scripts/brief-provenance.py` check 5, **SELECTOR BLINDNESS**. Two entry branches, because the
instance as retold and the instance as shipped are not the same thing:

- **(a) a search is cited** and the sentence is about something wider than the string it names.
- **(b) no search is cited at all** and a QUOTED LITERAL is asserted absent. Nobody learns a string is
  absent by any means other than looking for it, so the search exists whether or not it is shown.
  Branch (b) is the flagship instance; without it a check named after this failure is silent on it.

Run against all three, reconstructed with the commands the account gives them:

| # | what check 5 says |
|---|---|
| 1 | **CAUGHT, on exactly the harmful sentence.** `[selector] The suite builds no repositories.` — *"`grep -n "git init" …contract-integrity.test.sh` can only answer about the string “git init” in the files it was pointed at… Broaden the pattern until it returns hits and read them; re-running this one will agree with it."* The sentence in the same brief that DOES name the string is silent, correctly: it is true, and it is grep's own question |
| 1' | **CAUGHT AS IT ACTUALLY SHIPPED**, with no command cited, by branch (b): `[selector] His explanation, to be verified rather than assumed: `git init` appears nowhere in that suite…` — *"this says the string “git init” is absent, and NO SEARCH IS SHOWN."* Verified against `tom7-brief.md` line 11 itself, and against a variant with the incidental number stripped out, so the catch does not rest on the word "0" being in the sentence |
| 2 | **CAUGHT**, twice over: check 4 on the act predicate and check 5 on the selector. `[selector] Nothing in the engine emits that line.` |
| 3 | **MISSED, and it always will be.** It is a COUNT, not a search: a list's length reported as a file count, with no selector anywhere. **Check 3 already covers it** — `count(53) — nothing in scope sources it` — and covered it on the real brief, four times. Nothing in check 5 should try to reach it |

---

## 7. The cost, as counts over stated denominators

Measured with `searchblind/measure.py` in the session scratchpad, on the surface this is delivered on
and on the one it is not.

| corpus | documents | check-5 rows | documents with a row | rows from checks 1-4 |
|---|---|---|---|---|
| real briefs (`*brief*.md`) | 30 | **4** | 4 | 127 |
| spawn payloads (`*payload*.json`) | 31 | **6** | 4 | 215 |
| landed records (`docs/verification/*.md`) | 65 | 31 | 23 | 1862 |

**Hand-classified on the 30-brief corpus, which is the surface it ships on: 4 rows, 3 real, 1 false
positive.** The false positive is this task's own brief, flagged for QUOTING the failure it commissions
— the known mention-versus-use class the file already asserts out loud as Y11, now S13.

The records number is why check 5 is **deliberately not** wired into the record-write delivery hook.
That hook runs check 4 only, by its own measured decision, for exactly this reason: 31 rows against
1862 would be a signal buried rather than delivered. Check 5 reaches the agent through the spawn path,
which already calls `annotate()`, with no new wiring.

**Three tightenings, each forced by a measurement rather than by taste**, recorded because the
temptation to skip them is what kills checks like this:

1. `(is|are|was|were) not <word>` produced **four of the first six rows** on the records corpus, all on
   sentences saying a thing is not some OTHER thing. An identity negation claims nothing absent. Dropped.
2. `no longer` is a temporal, not a quantifier. Two more rows. Excluded.
3. Branch (b) with a general negation put **20 rows on 30 briefs, 16 documents of 30** — over half of
   every brief. Nearly all of it was one shape: a quoted span that is the ACTOR, not the needle. Branch
   (b) now requires a PRESENCE predicate, and the count went 20 → 4.

And one tightening forced by a **test**, which is the part I like least and should say loudest: case
S9b failed because my negative-existence regex carried an enumerated list of nouns, and "no harness
covers that branch" was outside it. **An enumerated list is one spelling of the thing.** The check
written to catch this failure committed it in its own source, and a test caught it, which is the whole
argument of §9 in miniature.

---

## 8. The test that fails without it and passes with it

`engine/scripts/brief-provenance.test.sh`, **47 cases, 15 new**. Removing `check_selector(blocks)`
from `review()` in a copy of the file and running the suite against it:

```
  FAIL  S1   a negative claim TRANSLATED from a searched string is caught
  FAIL  S4   a rendered value searched for in its own source is caught
  FAIL  S7   the instance AS SHIPPED — an absent literal with NO search shown is caught
  FAIL  S13  KNOWN FALSE POSITIVE: a brief ABOUT this failure is flagged for quoting it
  FAIL  S9a  a pattern behind -e and a value-taking flag is still found
  FAIL  S9b  a find -name pattern is a selector too
  FAIL  S10  selector rows carry their OWN instruction — broaden, not re-run
  40 passed, 7 failed
```

**Seven, and I had written six before running it** — S13 goes red too, because a case that asserts a
known false positive is a case that fails when the check stops firing at all. The distinction matters:
a check that never fires is indistinguishable from a broken one, which is why the file's own P8 exists.

`S2` and `S3` are the suppressors the check lives or dies by, and without them it flags every correct
grep claim in the corpus.

**Four cases assert KNOWN MISSES out loud**, because a file that quietly passes claims a coverage it
does not have:

- **S6** — the pattern exemption is scoped to the BLOCK, so a translated claim sharing a paragraph with
  its string is exempted with it. The scope is not a preference: `sentences()` splits per LINE, and
  wrapped prose otherwise hands the second half of a well-formed claim to the test with its string left
  on the line above.
- **S7b** — a relayed conclusion with neither a search nor a literal has no surface to recognize.
- **S11/S12** — the two measured false-positive shapes, pinned so they cannot come back.
- **S13** — a brief discussing this failure is flagged for quoting it.

Green on every suite that shares this module: brief-provenance **47/47**, notice-claim-capability
**14/14 with 8 mutants killed**, spawn **32/32**, handoff-facts **22/22**.

---

## 9. The rival answer, weighed seriously — and it wins

The brief put it plainly: *it may be that the durable solution is not making the lead accurate but
making re-derivation unskippable.* **The measurement says so, and it is the answer to give him.**

Every instance was caught by an engineer. Both instances traceable to a brief were caught by an
engineer who re-derived a fact the brief had MARKED, and both escalated durably — to a ledger outside
every repository, which arrives whether or not the branch is ever merged. The record holds at least
thirteen of these. That is not a lucky streak; it is a pipeline with a measurable yield.

**So the honest ranking of what protects this project from a wrong brief:**

1. **The engineer re-deriving.** Catches everything the other layers catch and the things none of them
   can see. Costs one re-derivation per marked claim. Already running.
2. **The mark itself** — `unverified:`, *"the 53 is his; re-derive it"*. Cheap, and its own author
   cannot apply it reliably, which is the reason for layer 3.
3. **The generated annotation** (checks 1-5). Applies the mark for him, to statements he did not think
   to mark, and reaches the agent whether or not he reads a word of it.

**Layer 3 is the only one that can be built, and it is the least of the three.** Anything that made the
lead accurate would have to know what is true, and nothing textual does. What layer 3 buys is that the
lead's recollections arrive LOOKING LIKE recollections, so layer 1 knows where to spend its attention.

**Nothing here should be made blocking.** A blocking guard over prose has a large false-positive class,
the fix on the day is always to waive, and habitual waiving is how a guard dies — `g11`/`g12`/`g13`,
three instances in a single day. A false positive from a non-blocking row costs one re-read and leaves
no habit behind. That asymmetry is the whole reason this shape is viable where the other was rejected.

---

## 10. What stays human, stated so no one reads coverage into this page

- **MISREADING.** A command that ran, an output that was pasted, and a reading that was wrong — indented
  log lines taken for top-level failures. The command is real, the output is real, the citation is
  perfect, and every check above is satisfied. **A second reader is the only defense, and there is no
  version of this that a checker reaches.**
- **A negative claim naming neither a search nor a literal.** "The suite builds no repositories" with
  nothing beside it. Formally identical to a legitimate constraint. S7b.
- **A sentence typed straight to the CEO in chat**, which passes through no artifact any hook watches.
- **Mention versus use.** A document about this failure is flagged for describing it. Not decidable by
  a regular expression, asserted rather than hidden.

---

## 11. What I did not do, and why

I did not extend `notice-claim-capability.sh` to carry check 5 to record writes. Its rows would be 31
against that corpus's 1862; its name, its heading and its trailing instruction are all check 4's, and
its test suite pins that wording. Mixing a differently-shaped check under a heading that misdescribes
it is the failure this whole family of checks exists to catch. The volume is measured and sits in §7 if
someone later decides that surface is worth its own delivery, with its own name.

I did not touch `engine/scripts/lib/containers.*`, `orchestration.config`, `.git/hooks/`, or
`docs/plans/worktree-spec-2026-09-11.md`.
