# Type Y, answered: a check CAN compare a claim's predicate against its command — for the commands somebody has written a capability down for, and for nothing else

**Author:** Sage (software architect). **Date:** 2026-09-14.
**Question put to me:** can a check compare a claim's PREDICATE against what its cited command is
capable of establishing? Non-blocking; must not become wallpaper; output must reach the reader of the
artifact; "no sound check exists" is an acceptable answer if argued from the corpus.

**Built.** `engine/scripts/brief-provenance.py` gains a fourth check. It catches **all four** instances
in the brief. Its cost is measured below as counts over stated denominators, including a **62% false
positive rate on the records corpus** — which is survivable in this shape and would be fatal in any
other.

---

## 0. The two premises I was given, checked before I designed anything

The brief marked both as the lead's assertions rather than measurements. Both needed correcting.

| asserted in the brief | measured | how |
|---|---|---|
| "every one of these would pass a provenance check" | **TRUE.** 0 findings across all four | the four instances, each with its real command, put through `brief-provenance.py` at `0cd22739`: `provenance: nothing asserted without a source` |
| "re-running the command confirms the sentence in three of the four" | **FALSE under both readings.** Re-running confirms the OUTPUT in **4** of 4; it confirms the SENTENCE in **0** of 4 | `git branch --no-merged main --list 'codex/*'` still returns one branch; `merge-base --is-ancestor 55728e67 f201e904` still exits 0; the other two reproductions are recorded in §10e of the failure record. Every one of the four sentences is false in its predicate, so none is confirmed |

The correction matters to the design rather than being pedantry. "Three of four" implies one instance
where re-derivation helps. **There is none.** Re-derivation is not a partial defense against this
failure; it is *zero* defense, and it actively strengthens the false sentence by confirming the number
under it. That is why the annotation this check emits carries a different instruction from every other
row the file produces.

---

## 1. §10i's tell is right about three instances and blind to the fourth — so the check is three rules

The record proposes one tell: *"If the sentence has an actor in it, the command must have found the
actor."* The brief asked me to push on it before building. It does not survive its own corpus.

| # | cited command | the claim | the gap | does "find the actor" describe it? |
|---|---|---|---|---|
| 1 | `escalations.py outstanding` | "79 outstanding, explicitly **waiting on him**" | the count was the lead's; "waiting on him" names whose move it is | **partly** — the actor is there, but the defect is an *expectation*, not an act |
| 2 | a count of rows ever addressed to the CEO | "**10 outstanding** for the CEO" | `outstanding` is a filter the selector never applied | **NO. There is no actor anywhere in it** |
| 3 | `git branch --no-merged` | "all but one are **fully merged into main**" | reachability reported as an act | yes |
| 4 | `merge-base --is-ancestor` → 0 | "it **arrived as a passenger inside** that merge" | true of every later merge; identifies none | **partly** — the gap is *identification*, not agency |

**Instance 2 is a SCOPE mismatch — `outstanding` versus `ever addressed to` — and an actor detector is
structurally blind to it.** Instance 4's gap is that a predicate true of a whole class was asserted of
one member. Calling all four "the command must have found the actor" would produce a check that catches
two of them and believes it has a theory.

So the check is three rules, and being three is the finding:

- **A1 — AUTHORITY and EXPECTATION are universally unestablishable.** No shell command reports whether
  something was allowed, or whose action is awaited. This rule needs no table and does not even need a
  command; any cited evidence plus such a predicate is a mismatch. Catches 1.
- **A2 — ACT, AGENT, TIME and IDENTITY are table-driven.** Whether a command can carry them depends on
  the command: `git reflog` records operations, `git branch --no-merged` does not. Catches 3 and 4.
- **B — a count's NAME must be derivable from its SELECTOR.** Purely lexical: if the sentence calls a
  count `outstanding` and the command that produced it contains no word to that effect, the count may
  carry a filter that was never applied. Catches 2, and only this rule does.

---

## 2. What makes it decidable: it never judges the sentence

**A general predicate checker is not decidable and I did not build one.** What is decidable is a much
smaller question: *what is this command capable of establishing?* — and that question has an answer
somebody can write down, once, per command.

So the finding is a **capability disclosure**, not a verdict:

> `git branch --no-merged main --list 'codex/*'` establishes which branch tips are reachable from a ref
> at this instant. It cannot establish that any operation was performed — and the sentence asserts an
> act.

**That first sentence has no truth value to get wrong.** It is a fact about git. The check therefore
cannot produce a false *accusation*; it can only produce an *unnecessary row*, and unnecessary rows are
what §3 measures. The comparison is left to the reader, which is also the only place it belongs.

**The table is an allowlist, and that is the whole noise control.** Eight command forms have a
capability written down. An unrecognized command yields **nothing** — no guess, no default. Adding a
command to the table is a deliberate act of writing down what it measures.

**Three suppressions are soundness, not tuning, and each was found by the corpus rather than imagined:**

- A **cited commit SHA is evidence of an act.** Somebody made it; the history records who and when.
  Without this the check fired on `deleted at \`3ddc05a3\` on 2026-08-28` — the best-sourced shape there
  is. (It also improves instance 4: with the SHAs credited, the diagnosis narrows from "act" to
  "identity", which is the correct one.)
- A **command that performs the act establishes it.** `git merge` followed by "it was merged" is a
  report.
- A **command that reads history carries who and when.** `git reflog`, `git blame`, `git log --author`.
  Without this the check would have flagged every row of the one document in the corpus that got this
  right, which is precisely how a report becomes wallpaper.

---

## 3. The cost, as counts over stated denominators

Run identically over two corpora. "Rows added" is the check-4 count; the comparison column is what
checks 1-3 already emit on the same documents.

| corpus | documents | check-4 rows | per document | checks 1-3 rows | check 4 as a share of the report |
|---|---|---|---|---|---|
| this session's spawn payloads (`scratchpad/*.json` with a `prompt` key) | **23** | **1** | 0.04 | 140 | **0.7%** |
| landed records (`richos docs/verification/*.md`) | **63** | **37** | 0.59 | 1743 | **2.1%** |

**False positives, classified by hand against a stated rubric** — a row is a TRUE POSITIVE when the
sentence reports that something happened, was authorized, or is awaited by a person, and the cited
source is a state measurement:

| corpus | rows | true positive | arguable | **false positive** | FP rate |
|---|---|---|---|---|---|
| spawn payloads | 1 | 0 | 0 | **1** | 1 of 1 |
| landed records | 37 | 8 | 6 | **23** | **23 of 37 = 62%** |

**The 62% is reported, not buried, because it is the number that decides the shape.** A 62% false
positive rate in a blocking guard is the g11/g12/g13 death spiral on day one. In a non-blocking
disclosure it costs a reader one re-read of a sentence that turns out to be fine — 0.59 of those per
record — and there is no waiver to grant, so there is no habit to form. **That asymmetry is the entire
argument for shipping it, and it is the same argument `brief-provenance.py`'s own record makes.**

**The dominant false-positive class is mention-versus-use and specification-versus-report.** Most of
this corpus is specifications, test matrices and hypotheticals, where "deleted" and "landed" name a
required behavior rather than an event. One pass of three narrowings together — a `HYPOTHETICAL` filter
(modals and conditionals), honoring the author's own `unverified:` marker, and the hyphen guard — took
the records corpus from 46 rows to 37; I did not separate their individual contributions. The residue is
not decidable by a program and I stopped rather than tune further. **Test case Y11
asserts a known false positive out loud**, the way P4 asserts a known miss, so precision cannot be
quietly overclaimed later.

### The positive probe, and it was not constructed

Run against `docs/verification/codex-branch-merge-provenance-2026-09-14.md` — a 511-line landed record
written before this check existed — it emits four rows. **Two of them are the exact sentences
`reed-opus-cx2` later proved false**, at the cost of an escalation
(`esc-20260914T070409Z-5622da32`) and a published correction:

    [capability] which means `codex/workspace-retirement-safety` carried it in.
    [capability] `durable-orchestration`, which arrived as a passenger.

A third is the branch count that the same correction revised. **That is the evidence that the rows are
worth their cost: on the one document in the corpus known to contain this failure, the check lands on
it.**

---

## 4. The finding the brief did not ask for, and it is the most important one

**Not one of the four instances happened in a spawn brief.**

| # | where the sentence actually was | can a brief check see it? |
|---|---|---|
| 1 | `project_restart_2026-09-13_late.md`, a memory file | no |
| 2 | a correction inside a landed `docs/verification/` record | no |
| 3 | **a question typed to the CEO in chat** | **no, and nothing ever will** |
| 4 | a landed `docs/verification/` record | no |

The brief's constraint — *"the output goes into the artifact the reader receives"* — is satisfied for
briefs by extending `brief-provenance.py`, because `engine/scripts/lib/spawn.py:616` already appends its
annotation to every spawn payload. **No hook was touched and none needed to be.** But the measurement in
§3 says the plain truth about that surface: **1 row across 23 briefs, and that row is a false positive.**
On briefs this check is very nearly inert, because type Y did not happen there.

**Where it fires is records, and records are where it should be delivered.** The recommendation, stated
as a recommendation because the surface belongs to somebody else:

1. **Wire it as a non-blocking `PostToolUse[Write|Edit]` notice on `docs/verification/**.md` and
   `**/*restart*.md`.** `engine/scripts/hooks/*` is `zach-opus-n9`'s this session, so I have not touched
   it. The invocation is `python3 engine/scripts/brief-provenance.py <file>` — it already accepts any
   markdown file and needs no new entry point.
2. **Accept that instance 3 is unreachable.** A sentence typed to the CEO passes through no file and no
   tool. Nothing textual will ever catch it. What transfers to that surface is the *habit* the rows
   teach, and a habit is not a check — so the honest statement is that **one of the four instances is
   outside the reach of any mechanism, and the record should say so rather than imply coverage.**

---

## 5. What it says about each of the four, verbatim

Run on a corpus file carrying all four with their real commands:

    provenance:  4 cite a source that does not establish what they say; the brief now says so to the agent

    [capability] 79 teammate escalations outstanding, oldest 8 days, explicitly waiting on him.
      the captured output in scope is a measurement. It cannot establish whose action is awaited
      — and the sentence asserts that a named person's action is awaited.

    [capability] There are 10 outstanding for the CEO.
      `grep -c '"for": "ceo"' ~/.claude/state/escalations.jsonl` establishes a count of the items
      the selector you gave it matched. It cannot establish the current status of the things it
      counted — and the sentence asserts a status the selector did not filter on. The count is
      called "outstanding", and nothing in the command or its output filters on that.

    [capability] All but one of the codex branches are fully merged into main.
      `git -C /Users/alex/ab/richos branch --no-merged main --list 'codex/*'` establishes which
      branch tips are reachable from a ref at this instant. It cannot establish that any operation
      was performed — and the sentence asserts an act.

    [capability] Its own back-merge commit `55728e67` is an ancestor of `f201e904`, which means
    `codex/workspace-retirement-safety` carried it in.
      `git merge-base --is-ancestor 55728e67 f201e904 ; echo $?` establishes whether one commit is
      reachable from another at this instant - which is equally true of EVERY later merge, so it
      singles out none of them. It cannot establish which of several equally-consistent candidates
      it was — and the sentence asserts one candidate out of several.

**Four of four, each with the right diagnosis rather than a generic one** — expectation, scope, act,
identity. The brief required at least the two `git`-based ones.

---

## 6. The instruction the rows carry, and why it is not check 3's

This is the part that would be easiest to get wrong and hardest to notice. Checks 1-3 tell the agent:
*re-derive it.* **Applied to a type-Y row that instruction is actively harmful**, because re-deriving
confirms the number and hands the false predicate more credibility than it had. So the capability rows
travel under their own heading and their own words:

> These are not unsourced. The command was run, the output is real, and re-running it will agree with
> the number — that is why they are listed apart. **What is in question is the WORD, not the
> measurement.** [...] If you need the claim — that somebody did something, that it was authorized,
> that a particular one of them is the one — then this source does not carry it, and neither does
> re-running it: you need different evidence, or the honest answer that the record cannot settle it.

Test case Y12 pins this, because a future refactor merging the two sections would silently reintroduce
the failure.

---

## 7. Defects I introduced and then found, recorded because they are the interesting part

Each was found by running the check on the real corpus, and each is now a comment at the code that
fixes it.

| defect | what it did | why it happened |
|---|---|---|
| `\bmerge\b` matched inside `git merge-base` | the corpus's own read-only ancestry probe was read as a merge operation, which silently exonerated instance 4 | a hyphen is a word boundary |
| the rule-B alias test read the prose block | the sentence's own word `outstanding` satisfied the test asking whether the COMMAND says `outstanding` — **the claim exonerating itself** | the evidence scope was reused without narrowing it |
| `\bmerged\b` matched inside `--no-merged` in a cited command | the predicate matched inside the citation, at an offset outside the quotation, defeating the quotation test | backticked spans were not blanked |
| `mask_quotes` pairs quote marks with a 12-character floor | a short earlier quotation (`"32.6 GB"`) is skipped, the pairing walks off by one, and a sentence **correcting** the phrase "waiting on him" was flagged for containing it | pairing is fragile; counting marks is not |
| the summary line said `N statement(s) carry no source` for sourced findings | **this file committing the exact failure its fourth check exists to catch** | one counter, two opposite classes |

The last one is the one to keep. It took one run to produce and would have shipped.

---

## 8. Verification

| check | result |
|---|---|
| `engine/scripts/brief-provenance.test.sh` | **32 passed, 0 failed** (was 20; +12 Y cases) |
| the same suite with `check_capability` neutered | **26 passed, 6 failed** — Y1, Y2, Y3, Y4, Y11, Y12 all bite; the six negatives (Y5-Y10) correctly still pass |
| `engine/scripts/spawn.test.sh` | **32 passed, 0 failed, 0 skipped** — the annotation path is unbroken |
| `engine/scripts/lib/spawn.py` loads and `PROV.annotate` / `PROV.report` resolve | yes |
| the four instances | 4 of 4 flagged, §5 |
| false-positive rate | counted, §3 |

Not run: `contract-integrity.test.sh`. Nothing here touches a hook, `hooks.json`,
`orchestration.config` or an installed surface — the probe has no section covering this file. Rich runs
the full pass at land.
