# Type W: can a brief be stopped from carrying an unverified account of the system?

**Question asked:** the failure was already documented — as a RULE, in `CLAUDE.md`, for weeks — and
it was broken by its own author one turn after he wrote up its sibling. So the deliverable is a
MECHANISM, or an honest finding that no sound one exists. The same page records a deliberate
decision not to enforce that rule with a hook. That decision is not overturned here.

**Answer, in one line:** *you cannot stop a brief from carrying an unverified account of the system,
and you should stop trying. You can stop the account from arriving unlabeled, at the only reader who
is harmed by it.* That is buildable, it is cheap, and it is built:
`engine/scripts/brief-provenance.py`, wired into `engine/scripts/lib/spawn.py`, branch
`cc/sage-opus-x1` at `b5376005`.

Everything below is the argument for why that is the right shape and the measured cost of it,
including what it misses and what it gets wrong.

---

## 1. What the candidate idea was, and why it is not what got built

The proposal in the assignment: give the payload an evidence section whose entries are
`(command, exit code, captured output, timestamp)`, **executed at spawn time**, so the prose has
nothing left to launder. `spawn.py` already assembles the whole payload, so there is a natural seam.

**It was pushed on hard and it does not survive, for four reasons in ascending order of severity.**

**a. It makes spawn latency a function of what the lead pasted into the brief.** The CEO noticed a
130 s spawn on 2026-09-13 and asked about it in those terms. A design whose cost is
`sum(runtime of whatever commands the brief cites)` puts an unbounded number in the middle of the
thing he just paid to make fast. One `git log` is milliseconds; one `contract-integrity.test.sh`
section is 21-181 s. The rejection is about the unbounded shape, not about the idea.

**b. Most of the evidence a brief needs is not a command.** A transcript quote, a CEO instruction, a
screenshot, an observation from an earlier session. `spawn.sh` can run none of them.

**c. A re-run at spawn time answers a different question than the claim.** *"Two workspaces from
agents he stopped were still present"* is a statement about a moment that has passed — they were
marked by hand afterwards, so the command that would settle it now returns nothing. Re-running is
not verification of a historical claim; it is a measurement of a different instant that looks like
one.

**d. Decisive: the defects it would have caught are the least dangerous ones.** Per §10g of the
lifecycle failure record, the brief that spawned `zach-opus-n3` carried four unverified narratives,
two wrong facts, one distorted quotation and **two prescriptions built on an architecture its author
had read one code comment of**. An evidence section makes the cited half stronger. It does nothing
at all about the half the record calls the worst — *"a prescribed fix aims the work"* — because a
prescription is not a number and has no command behind it by construction.

**So the mechanism cannot be about supplying better evidence. It has to be about what happens to the
statements that have none.**

---

## 2. The two questions that decide the shape

### Blocking or not?

`CLAUDE.md` rejects a blocking guard over prose and gives the reason: a large false-positive class,
the fix on the day is always to waive, and habitual waiving is how a guard dies — the `g11`/`g12`/`g13`
pattern, three instances recorded on one day. **That reasoning is correct and it is load-bearing
here, but it is not a reason to build nothing, because it is a statement about WAIVERS and not about
FINDINGS.**

The asymmetry is the whole argument:

| | blocking guard over prose | this |
|---|---|---|
| cost of a false positive | the lead grants a waiver, and grants the next one faster | the agent re-derives a fact that turns out to be true |
| what a false positive leaves behind | a habit | nothing |
| how it dies | waived until nobody reads it | diluted, if it ever gets noisy |

There is no waiver to grant, so there is no waiving habit to acquire. The failure mode that killed
`g11`/`g12`/`g13` has nothing to bite on. **Its own failure mode is different and real — dilution —
and that is why the false-positive rate is measured below rather than asserted.**

### Who is the mechanism talking to?

The obvious cheap form is an ECHO to the orchestrator before dispatch: print back every
claim-shaped statement, non-blocking, and let him look. **That is attention with extra steps, and
attention is the thing that already failed.**

It is not worthless — recognition beats recall, and a sentence lifted out of the narrative that
supported it is easier to doubt than the same sentence in place. But it depends on the lead reading
it, at the end of the turn, which is exactly the moment §10e identifies as *"least capacity to
verify and highest confidence that verification is unnecessary."*

**The load-bearing half is the annotation that reaches the AGENT**, and `CLAUDE.md` supplies the
evidence that this works, from the day the rule was written:

> The marked form works and I know it works: three times that day I wrote *"confirm this yourself, I
> derived it with a two-condition grep"*, and all three times the agent re-derived it and was right.

**Marking worked 3 times out of 3. It failed only because it was applied by hand, by the one person
who cannot see his own recollection as a recollection.** So the mark is generated rather than
remembered. The lead-facing report is kept as well, because it costs nothing and it is where the
lead learns what his own briefs look like.

---

## 3. What was built

`engine/scripts/brief-provenance.py`. Three checks, deliberately ordered by soundness, because a
page that hides a heuristic among exact checks is claiming coverage it does not have.

**1. QUOTATION — exact, and the only check that PROVES a defect.** A quotation attributed to a file
is searched for in that file, whitespace- and emphasis-normalized. Either the string is there or it
is not; there is no threshold and no judgment. Elisions (`...`, `…`) are honored as the author's own
admission that this is not the whole thing, and each surviving run is checked on its own.

**2. RESTATEMENT — structural.** *"Point 7: both endings delete"* is a paraphrase of a citable
source. **Referring** to a numbered point is silent — that is what a brief should do. **Restating
what it says** is flagged, in the record's own words: *"every paraphrase is a fresh surface for
distortion — one of them distorted. A brief that says read points 4, 5, 7 and 11 of `<path>` carries
the same authority and cannot drift from it."*

**3. PROVENANCE — heuristic, and the only one that can be noisy.** A statement is listed when it
carries a COUNT, an assertion of CERTAINTY (*"demonstrably"*), or a claim about the BEHAVIOR OF A
NAMED CODE ENTITY, and no command, captured output, commit, file:line, run id or re-derive
instruction sits in scope with it.

**Scope of evidence is the block plus an adjacent code block, never across a heading.** A brief that
pastes a grep and then says "21 other sites" has sourced the 21. One *"do not assume"* at the bottom
of a page does not exempt everything above it.

**One rule inside check 3 is worth naming, because it is the one that catches the wrong count.** *A
count is settled by something that can be counted again* — a command, a captured output, an explicit
re-derive instruction. **A single quoted instance evidences one occurrence and never a total.** That
is precisely how *"Twice in session `b7d89f44`"* survived a paragraph that quoted the guard's output
and therefore looked sourced.

**The prescription is caught through the account it rests on, not as a prescription.** There is no
prescription detector and there should not be: *"do not build a second reaper"* is formally identical
to *"do not weaken the guard"*, which good briefs carry. What is detectable is that a directive
sentence asserts the behavior of a named code entity with nothing behind it, which is what
*"so the existing reap path in `workspaces.sh` can take it"* does.

**It is append-only and it never rewrites a word the lead wrote.** On a brief that sources
everything, nothing is appended and the payload is byte-identical (case P11/P14a).

---

## 4. Acceptance: what it says about the brief that caused this

Reproduce, from the repository root of `richos`:

```
python3 engine/scripts/brief-provenance.py \
    /private/tmp/claude-501/.../scratchpad/zach3-payload.json --repo /Users/alex/ab/richos
```

Output at `b5376005`:

```
  provenance:  6 statement(s) carry no source; the brief now says so to the agent
    [restatement] Point 7: both endings delete.
                  restates docs/plans/worktree-spec-2026-09-11.md in prose rather than quoting it
                  or pointing at it; count(both) — nothing in scope sources it
    [restatement] Point 4: deletion is automatic, "with nothing left undecided".
                  restates docs/plans/worktree-spec-2026-09-11.md in prose rather than quoting it
                  or pointing at it
    [provenance ] It is not. Observed by the CEO on 2026-09-13: two workspaces from agents he
                  stopped were still p
                  count(two); behavior of workspaces.sh — nothing in scope sources it
    [provenance ] `guard-workspace-gate.sh` did not see them either — it asks about FINISHED work,
                  and these were
                  behavior of guard-workspace-gate.sh — nothing in scope sources it
    [provenance ] The signal demonstrably exists. Twice in session `b7d89f44` tonight,
                  `guard-workspace-gate.sh` b
                  count(Twice); asserted as certain; behavior of guard-workspace-gate.sh —
                  in scope: commit, file:line
    [provenance ] Make every ending point 11 names mark the agent finished, automatically, so the
                  existing reap pa
                  behavior of workspaces.sh — nothing in scope sources it
```

Against §10g's own enumeration of that brief:

| §10g kind | count | caught? |
|---|---|---|
| Verified quotation | 6 | correctly SILENT — including the point 11 blockquote, which is genuinely verbatim |
| Unverified narrative asserted as observed fact | 4 | **yes**, in 2 rows (they occupy two sentences) |
| Factually wrong — "twice", and "demonstrably exists" | 2 | **yes**, both in 1 row, flagged on the count AND on the certainty word |
| Distorted quotation — point 4 used as a general claim | 1 | **yes**, as a restatement |
| Prescription built on an unverified model | 2 | **one of two.** "so the existing reap path in `workspaces.sh` can take it" is caught. **"do not build a second reaper" is MISSED** |

**The miss is stated out loud in the test suite, as case P4, so it can never quietly become a claim
of coverage.** A prescription that names no code entity cannot be told from a legitimate constraint
by any textual means I can defend. The partial answer is that such a prescription almost always
rests on an account in the same or an adjacent sentence, and the account is what gets caught.

**What the agent actually receives** (tail of the dispatched payload, `spawn.sh --dry-run`, all nine
PreToolUse[Agent] guards still passing):

> ## Provenance of this brief — generated, not written by the lead
>
> The statements below were written by your orchestrator without a command, a commit, a captured
> output or a file:line beside them. They are its ACCOUNT of the system, and an account is a
> recollection until you check it. Nothing here says any of them is wrong.
>
> **Re-derive any of them you are about to build on, and say what you found.** If one of them is the
> reason for an approach this brief prescribes, treat the approach as a hypothesis and not as a
> constraint: a prescription resting on an unchecked account has already chosen your design for you.
> If the code contradicts it, that is a finding — report it and stop rather than forcing the brief's
> shape onto what is actually there.

---

## 5. The false-positive rate, measured, with every finding shown

**The corpus is the nine payloads dispatched in session `b7d89f44` on 2026-09-13/14** — eight
briefs plus `zach3`. Reproduced with `dump.py` over the scratchpad payloads at `b5376005`:

| brief | findings |
|---|---|
| `zach-opus-n3` (the defective one) | **6** |
| `sage-opus-v1` | 4 |
| `sage-opus-x1` | 4 |
| `tom-opus-h1` | 2 |
| `tom-opus-h3` | 2 |
| `zach-opus-n1` | 2 |
| `sage-opus-w1` | 0 |
| `tom-opus-h2` | 0 |
| `zach-opus-n2` | 0 |
| **total** | **20 over 9 briefs** |

The defective brief carries the most findings in the corpus, and three briefs are silent. Neither
was designed for; both are what the measurement returned.

**Adjudication of all 14 findings on the eight briefs that were FINE.** The rule being applied is
`CLAUDE.md`'s own: a count or a statement about the system carries the command that produced it, or
it carries the word `unverified`.

| finding | verdict |
|---|---|
| `sage-v1`: "Cost: 130 s and two sequential guard refusals, against 1.3 s through `spawn.sh`" | **TRUE** — measured numbers restated from the record with no command. Textbook "the record is the laundering path". |
| `sage-v1`: "`CLAUDE.md` records three instances of that pattern in one day" | **TRUE** — a count read off another document. |
| `sage-v1`: "`engine-status.sh` line 229 ... still instructs the superseded four-step path" | **weak true** — a behavioral claim; the file:line is a pointer, so the agent can follow it. Low value. |
| `sage-v1`: "type N is the one row marked FIXED, and the thing that fixed it is `spawn.sh`" | **weak true** — an account of a table two blocks away. Low value. |
| `sage-x1`: four restatements of `CLAUDE.md`'s history ("five briefs in one day", "three instances") | **TRUE x4** — counts restated from a document without quoting it. This is my own brief, and it earns every row. |
| `tom-h1`: "all 7 discarding mutation harnesses" | **TRUE** — a census with no command, in a file whose census has been wrong before (`CLAUDE.md`: "18 mutation harnesses ... it is 2"). |
| `tom-h1`: "appears ~28 times in that file overall" | **TRUE** — same, and it carries a tilde, which is an unmarked admission. |
| `tom-h3`: "the other 14 sites — the 3 graded medium and the 11 negative-control cases" | **weak true** — counts from "a prior pass"; the brief says re-derive about a DIFFERENT census two blocks earlier. |
| `tom-h3`: "Do not touch the 7 already converted" | **weak true** — same shape, lower stakes. |
| `zach-n1`: "`spawn.sh` landed last night and does the whole thing in one command, evaluating every PreToolUse[Agent] guard from every surface..." | **TRUE, and a good one** — this is a type-W architectural account written from memory. It happens to be right. |
| `zach-n1`: "the instruction every session boots with still names the old four-step path" | **FALSE POSITIVE** — the brief sources this with an explicit `grep` in the NEXT section, under a heading. Block scoping did not reach it. |

**Strict false-positive rate: 1 of 20 findings (5%), on 1 of 8 clean briefs.** The one FP is a
scoping artifact and it is reported rather than patched: widening evidence scope past a heading would
let a single command at the top of a brief source every claim under it, which is the hole the scoping
rule exists to close. That trade is stated so a future reader can re-decide it rather than discover it.

**A second FP was found by this measurement and FIXED** rather than reported: `sage-opus-w1`'s
*"which had been main three hours earlier"* — a duration read as a count. It is now case P15, with
P15b proving "three commits" is still caught. That brief is now silent. **Finding it by running the
check against real briefs, rather than against cases written from the same imagination that wrote the
check, is the reason the corpus measurement exists at all.**

**Of the 14 findings on clean briefs, 5 are what a reviewer would call low-value** — correct by the
rule, but the kind of row that gets skimmed. **Dilution, not waiving, is this mechanism's death, so
that ratio is the number to watch.** At 0-4 rows per brief it is readable today.

---

## 6. Cost

| | |
|---|---|
| the check, in process, on the 5130-char `zach-opus-n3` brief | **2.7 ms** (mean of 20 calls) |
| the whole `spawn.sh --dry-run` it sits inside, same brief | **1.82 s** (`/usr/bin/time -p`) |
| share of a spawn | **0.15%** |
| commands executed at spawn time | **none** |
| `spawn.test.sh` with the wiring in | **32 passed, 0 failed** |
| `brief-provenance.test.sh` | **20 passed, 0 failed** |

---

## 7. What this does not do

Stated here, not discovered later.

1. **It cannot tell a true account from a false one.** Nothing textual can. It reports whether a
   statement is SOURCED, which is a different property, and the only one a text-level mechanism owns.
2. **It does not catch a bare prescription** — "do not build a second reaper". Case P4 asserts this.
3. **It does not catch a qualitative laundered claim with no number, no certainty word and no named
   entity.** "The situation has not improved" passes silently.
4. **Nothing stops the lead writing a claim and not citing it.** The mechanism is not total and does
   not need to be: it changes what the AGENT does with the uncited half, which is where the harm was.
5. **It is not a guard and must not become one.** Making it blocking would hand it the `g11` death
   `CLAUDE.md` already diagnosed, and would trade a cheap finding for an expensive waiver.
6. **It says nothing about the CEO-facing handoff (type U).** The same library would serve it — the
   handoff is a brief whose reader is the next session — but that is a separate decision and a
   separate surface, and it is not made here.

---

## 8. Recommendation

**Land it, and do not add a rule anywhere.** The rule already exists, it is correct, and a second
written copy of it is the thing §10g says does not work. What changes is that the rule's output is
now produced by the machine that assembles the payload, at 2.7 ms, and is delivered to the reader who
is harmed by its absence.

**Do not make it blocking.** Not now and not after it proves itself; its viability rests entirely on
a finding being cheap.

**Watch the dilution number, not the false-positive number.** If briefs start carrying ten rows each,
the annotation is wallpaper and the mechanism is dead without anyone deciding to kill it. The corpus
measurement in §5 is the baseline to re-run against.
