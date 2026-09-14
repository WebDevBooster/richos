# The corrupted brief: what can refuse one, what cannot, and what it costs

**Asked, 2026-09-14, in the CEO's words:** *"the big problem that I discovered in the last few days is
that too often the engineer's brief contains not just unnecessary and useless fluff, but often contains
catastrophically harmful instructions such as false facts in the brief, wrong tasks, wrong scope,
prescribed design (in cases where finding new design options is the objective)."*

**Answer, in one line:** *a brief cannot be judged in scope by reading it, because everyone who reads it
was briefed by the same person — but a DISPATCH can be refused on two facts the lead does not author,
and the honest coverage that buys is two of his four kinds, not four.*

Built, registered and proven: `engine/scripts/brief-scope.py`,
`engine/scripts/hooks/guard-brief-scope.sh` (ninth PreToolUse[Agent] hook),
`engine/scripts/brief-scope.test.sh` (35 cases), `engine/scripts/brief-scope.mutation.sh` (7 mutants).

---

## 0. The problem is mis-stated in the brief I was given, in two ways, and both matter

The brief said to treat its every characterization as suspect. Two are wrong.

**a. "The reviewers were auditing against a premise the lead had already corrupted" is true, and the
conclusion drawn from it — anchor the reviewer to the spec — does not follow.** The spec MOVED. Re-derived
in `richos-hq`, not taken from the relay:

```
$ git -C /Users/alex/ab/richos-hq show 6f98eeca:docs/plans/worktree-spec-2026-09-11.md | grep -cE '^[0-9]+\. '
5
$ git -C /Users/alex/ab/richos-hq show bf25aade:docs/plans/worktree-spec-2026-09-11.md | grep -cE '^[0-9]+\. '
13
$ git -C /Users/alex/ab/richos-hq show c7bc75ab:docs/plans/worktree-spec-2026-09-11.md | grep -cE '^[0-9]+\. '
14
```

Twelve revisions, 2026-09-11 and 2026-09-12, while the rounds ran. A reviewer told to read "the spec" is
reading whichever revision the lead's brief last pointed at, which is the original failure with an extra
step. **But the growth was APPEND-ONLY** — point 2 at the five-point revision is point 2 at the
fourteen-point revision — so a point NUMBER survives it and a point's TEXT does not:

| revision | point 2 reads |
|---|---|
| `6f98eeca` | **`codex/` is never touched.** |
| `c663a823` | **A `codex/` workspace or branch is never deleted without the CEO's express word.** |

A round built against the first sentence builds a different thing from a round built against the second.
That is why the mechanism records the spec's **sha256** and refuses every dispatch when the page changes,
rather than naming the spec and trusting it.

**b. The brief's own measurement is published with a command that cannot produce it.** Type K prints

```
grep -ci "attack|adversar|hostile|...|circumvent" docs/plans/worktree-spec-2026-09-11.md
0
```

In BRE that searches for the literal string `attack|adversar|...`, so it returns 0 for every file on the
machine. **The claim is true** — I re-ran it with `-E` and with `-n`, still 0, no matching lines — **and
its evidence is worthless.** A reviewer checking the citation finds a command and an output that agree,
which is exactly the shape `brief-provenance.py` is built to trust. Worth recording beside type Y.

**Neither of these changes the diagnosis. Both change what can be built on it.**

---

## 1. Why the answer is not another reader, and the evidence is his, not mine

He ran the experiment. First he **supervised every engineer brief himself**; then **two adversarial
reviewers read every brief BEFORE every round**; his verdict is that this is the only reason the job was
ever completed. **And it still failed.** By round 7 the work had drifted; what caught it was **him**
noticing a round 10 was proposed after being told round 7 or 8 would be the last.

The failure record's own numbers say why review cannot close it: his fourteen points contain zero
adversarial words, and every reviewer brief instructed them to attack the machinery. **Two adversarial
readers cannot recover a scope when the brief that hired them has already redefined it.**

And there is a second, worse datum, which I found by checking rather than by being told. **Round 9's
prescribed design was not the lead's invention.** `docs/verification/certification-frank-round8-2026-09-13.md:185`:

> With the lead's windows recorded, the rule becomes: a ref at an agent's unlanded tip that appears at any
> point in its run is the agent's UNLESS it appeared inside a lead window ... **That is a round-9 build,
> not a CEO decision.**

The round-9 brief relays that faithfully, down to the sentence. It is an **adversarial reviewer's own
prescription**, and it produced the three measured regressions that made round 9 worse than round 8.

**This kills the whole family of "check who wrote it" answers.** Provenance was perfect. Attribution was
perfect. A citation check passes. The design was wrong anyway, and the reviewer who wrote it was me.

**And detection was never the failing step.** In the correction that reached me mid-task, the CEO had
separated two topics with a literal `" -- "` at character 142 of a 2198-character message
(sha256 `582ad14a…`). The boundary was marked, it was seen, the second topic was recognized as a second
topic — and it was consumed as evidence for the first anyway. **A mechanism that notices is solving a
problem the delimiter had already solved.** So every candidate below is judged on one question: *who is
refused, and what does not proceed.*

---

## 2. What the lead does not author

Exactly two things, and the mechanism is built out of them and nothing else.

1. **The CEO's page.** He wrote it; nobody edits it; it is recorded WITH ITS sha256 when the body of work
   starts, on the record that already exists (`integration.json`, body of work `richos-001`). One
   registration, no second inventory.
2. **A run's output.** The body of work's harness prints `PASS C<n>` / `FAIL C<n>` per point. The lead does
   not type those verdicts.

From those two comes a fact, not a judgment: **a round exists to turn a red point green.** A brief every
one of whose items names an already-green point has no spec-derived reason to exist.

**Round 9's own third line states its starting state as `14 green, 0 red`, with the only reds in the probe
RUNNER — the lead's scaffolding, which is in none of the CEO's fourteen sentences. The brief announces its
own out-of-scope-ness in a machine-readable form, and nothing read it.**

### What the brief has to carry

```
scope: richos-001
serves: point 2 - a codex/ ref deleted by an agent is restored
```

One line per work item. Nothing else in the brief is read.

### What refuses, and why each is a fact

| code | refuses when |
|---|---|
| `NO-ANCHOR` | the brief names no point of the governing spec |
| `SPEC-SATISFIED` | every point it names is recorded GREEN |
| `GREEN-ITEM` | some are — a rider on an otherwise dispatchable brief |
| `REGRESSED` | a point green in the previous verdict is red in this one |
| `NOT-CONVERGING` | three consecutive verdicts without a falling red count |
| `VERDICT-STALE` | the measurement predates the branch tip it judges |
| `SPEC-CHANGED` | the CEO's page is not the text this work was recorded against |
| `NO-SUCH-POINT` / `POINT-UNMEASURED` | the named point does not exist, or was not measured |
| `WRONG-WORK` | the brief declares a different body of work than the one recorded |

**The last two rows of the first group are the answer to "infinite loop", and they exist because of it.**
His word for what nearly happened is not "a bad round": *"even then it nearly turned into an infinite loop
were it not for my manual intervention after round 9."* A per-brief check that is right every time and
never ends the series has not solved his problem. `REGRESSED` is type L's own rule, which the record states
and nothing enforced. `NOT-CONVERGING` is **the round-count signal with semantics attached** — a count
cannot tell a hard round from a loop; a red count that stops falling can.

Window = 3, argued: two is one hard round and must not be refused; his own intervention came when round 10
was proposed after round 7 was to be the last.

**Both series clauses refuse EVERY dispatch against that body of work, including the one that would fix
it, until the CEO rules.** That is exactly what he did by hand: a hard reset deleting round 9.

---

## 3. Applied to the real round-9 brief — the required test, and the miss

`brief-scope.test.sh` §9 reads `/Users/alex/ab/richos-hq/docs/plans/round9-brief-2026-09-13.md` byte for
byte at the state it was dispatched into.

**S19 — REFUSED, `NO-ANCHOR`.** The brief names no point of the fourteen. **The sentence it dies on is
line 19:**

> Replace a listed probe, on the branch under test, with a file that imports the library and returns 0 —
> or flip a reviewer's `return 1` to `return 0`.

There is no point of the CEO's page that sentence could be anchored to. His fourteen sentences are about
workspaces, branches, landing and lock-out; not one is about the probe runner. **Item 1 could not have been
written with an anchor, and that is the finding, not a limitation.**

**S20 — REFUSED, `SPEC-SATISFIED`.** Give item 2 the only anchor it could have, `serves: point 2`. Refused,
because the measurement records point 2 green — and **the brief itself says so, on its own line 12:**

> **Starting state, re-measure it rather than assume it:** the fourteen read `14 green, 0 red ·
> self-check: green` with 83/83 mutants proven; the runner reads `GREEN 8, RETIRED 2, RED 2`.

The refusal hands over the question:

```
    The spec you wrote measures complete. This proposes another round on it.
    Either the work is not wanted, or the measurement is wrong. Which?
```

**Which is the right question, and the answer at the time was "the measurement is wrong"** — the round-8
certification had demonstrated point 2 violable while the harness read it green
(`lifecycle-failure-record-2026-09-13.md` §5: *"Point 2 of the CEO's page is violable today"*). Asked then,
round 9 shrinks to its one legitimate half and item 1 never gets built.

**S21 — THE MISS, AND IT IS ASSERTED IN THE SUITE SO IT CANNOT QUIETLY BECOME A CLAIM OF COVERAGE.** With
point 2 recorded RED, round 9 item 2 passes untouched — including lines 54–66:

> **Do:** record the lead's own windows. ... **Do NOT build the alternative that attributes every ref
> between two closed calls to the agent**

That is the prescribed design that made the build worse in three measured respects, and **this mechanism
would have let it through.** It refuses a dispatch on the ground that the measurement says there is nothing
to do. It has no opinion about the design inside an item, and it cannot be given one: *"do not build a
second reaper"* is formally identical to *"do not weaken the guard"*, which good briefs carry.

**So of the CEO's four kinds: wrong task — covered. Wrong scope — covered. False facts — covered
elsewhere, by `brief-provenance.py`, and partially. PRESCRIBED DESIGN — NOT COVERED, by this or by
anything.**

---

## 4. The attack I ran on my own answer

**A1. The lead attaches every item to whichever point is red.** *Real, and the main residual hole.* It is
bounded by the number of red points and shrinks as the work converges — and it is **zero exactly at the
moment the historical failure happened**, when all fourteen were green. The mechanism is strongest when
drift is likeliest. It is weakest early, when drift is cheap to correct.

**A2. The lead marks a green point red.** *Closed for the typed form, open for the written form.* The
verdict is parsed from a run's output, never typed, so he cannot edit a number. He CAN add a failing
sub-assertion to the harness. That is a strict improvement rather than a closure: to manufacture the
justification he must write a falsifiable test asserting the CEO's sentence is violated, which is a
concrete artifact a reviewer reads — instead of a paragraph.

**A3. The lead declares a new body of work.** *Real, and turned into an announcement.* `WRONG-WORK`
refuses a brief that renames the work in prose. Starting a genuinely new body of work is a loud, recorded
event — and renaming the work IS the sentence "I am now doing something other than what you asked for",
which is his decision. **The evasion is forced to become the escalation.**

**A4. The lead re-points which spec, or which part of it, applies.** *Closed.* The spec is recorded with
its sha256 at the body of work's start; any change refuses every dispatch. This is the candidate my brief
called strongest, and it only survives with the pin — §0a.

**A5. The CEO rubber-stamps the hatch.** *Open by construction and it cannot be closed.* Frequency is
bounded — once per round, only on green or stalled work — and the question is one he demonstrably wants,
since he asked it himself and it is the only thing that ever caught this. **The direction of the default
is the real gain: today a dispatch happens unless someone objects; after this it does not happen unless he
speaks.**

**A6. The lead fabricates his word.** *Open, and stated in the guard's own header rather than discovered
later.* Nothing in a hook can verify he spoke. What the hatch buys is that the way past is a fabricated
quotation of the CEO written into a log he can read.

**A7. The harness is green and the spec is violated.** *Real friction, and I claim it is the right
friction.* Round 8 is the worked example. The mechanism turns a measurement/reality disagreement into a
refusal and a question. It is not a false positive — it is the system saying two of its own sources
disagree — but it is paid every time the harness is weaker than a reviewer.

**A8. Nothing here would have caught the failure that produced my own brief.** *Correct, and I will not
stretch it.* Type AC — two subordinate clauses of a first-hand CEO account dropped in the relay — is a
fidelity failure about a message, not a scope failure about a spec. No clause above touches it, and
`brief-provenance.py` catches it only if the dropped clause happened to be a sourced number. **The
structural answer exists and is not mine to install unilaterally: the CEO's message is an artifact, so it
gets committed and the brief CITES IT AT A PATH AND A SHA instead of summarizing it** — which is exactly
what round 8's own brief does with the spec (*"read the CEO's fourteen sentences there, by that path"*).
That is checkable, it is already the house pattern, and nobody applied it to his messages.

---

## 5. The cost, which is what he actually asked for and has not been given

**Per spawn, on a body of work with no recorded spec — every body of work today:** one `read_json` of a
file the spawn path already opens, then silent exit 0. Unmeasurable. **Nothing else in this engine changes.**

**Per spawn, on a spec-governed body of work:** one sha256 of the spec, one `read_json`, one `git rev-parse`,
a regex pass over the brief. Milliseconds. **Deliberately NOT running the harness at spawn** — that is
20+ minutes, and spawn latency is something the CEO already noticed and paid to reduce at 130 s.

**Per round:** one harness run, recorded. **This is not a new cost** — round 9's own brief already ordered
the starting state re-measured. The mechanism re-uses a measurement the process already takes, and gives it
somewhere to be read.

**Per round, on green or stalled work:** **one question to the CEO.** That is the real price, and it is the
entire price. It is the only recurring cost and it buys the only signal that has ever worked.

**Authoring:** one line per work item. Seconds.

**Set-up, once per body of work:** `record-spec` — one command.

**What it is compared against:** two adversarial reviewers on every brief before every round. That is two
Opus agents per round, each reading a brief and the spec. **This does not replace them** — §4 of the
failure record lists what their passes caught and says they must not be cut. **It closes the one class they
structurally cannot, and it costs one question instead of two agents.**

---

## 6. What stays human, named precisely rather than implied

1. **Whether an item's APPROACH is right.** Round 9 item 2 is the worked example. Nothing mechanical reads
   a design, and §3/S21 asserts this rather than mentioning it.
2. **Whether a red point is really red, and a green one really green.** The mechanism inherits the harness's
   quality exactly.
3. **Whether the work is still wanted when the spec measures complete.** **His, and the one thing the
   mechanism guarantees reaches him instead of depending on him noticing a round number.**
4. **Whether a relayed account of his own words is faithful.** Uncovered by anything, including this. §4/A8.

---

## 7. Reproduction

```
bash engine/scripts/brief-scope.test.sh
    === brief-scope tests: 35 passed, 0 failed ===
    === mutation: all 7 properties proven load-bearing ===

bash engine/scripts/hooks/contract-integrity.test.sh --only base,manifest
    passed: 21   failed: 0   exit 3 (scoped-and-green)
```

`base,manifest` are the sections that pin hook registration and the PreToolUse[Agent] chain, which is what
this change touches. The full pass is the lead's at land time.

**Mutant M1 is the mechanism's claim as a falsifiable property:** remove the green-point refusal and case
S20 — the real round-9 brief — goes red. Proven load-bearing, with the other six.

**One finding from building it, recorded because it happened to a file whose header cites the type.** The
guard shipped unable to find its own library: `$ENGINE/scripts/brief-scope.py` resolved one directory too
deep from `scripts/hooks/`, the `[ -f ]` test took a quiet exit 0, and **every library-level case still
passed.** Only the two cases that drive the HOOK caught it. That is type Z — the check passes because the
thing it checks never ran — and the fix is both halves: the path, and the silence. A guard that cannot run
now says so on stderr and still exits 0. Case S18b pins it.
