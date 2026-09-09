# Adversarial review of the two land-cost architectures

**Status: REVIEW ONLY. Nothing here authorizes implementation.**
Author: Frank (expert advisor / devil's advocate). Written from the richos worktree
`frank-opus-lc1` at `d3195bb5` (the merge of `sage-fable-lc1` and `sage-fable-lc2`).

Under review:

- `docs/plans/land-cost-architecture-2026-09-09.md` — **Sage #2**
- `docs/plans/land-cost-architecture-2026-09-09-second-review.md` — **Sage #1**

Every number below either names the script in
`docs/measurements/frank-review-2026-09-09/tools/` that produced it, with its captured output
in `docs/measurements/frank-review-2026-09-09/results/`, or carries the word *unverified*.
I re-derived rather than quoted. The transcript corpus is live, so a re-run moves call counts
by one or two.

---

## 0. Verdict

**The end state both documents describe is correct and is the wheel. The order they put it in
is wrong, and it is wrong for one reason: both measured aggregate hours and neither measured
who spent them.**

I reproduced Sage #2's headline number exactly — 84.8 hours — and then asked the question
neither document asks. **70.5 of those 84.8 hours (83%) belong to one engineer, Zach, whose
task in that window WAS the test and worktree-lifecycle infrastructure.** Sage's own agents
spent 0.6 h. Ray, Ace, Mark, Norm, Art, Urban: zero.

That single fact breaks three load-bearing claims and inverts the recommended order:

1. Sage #2's "on the agent's clock, the tax goes to zero, not to a smaller number" (§5.2) is
   false for 83% of the number it is derived from. An engineer changing a guard must run that
   guard's tests. CI does not remove that; CI makes it *slower* for him, because a 10-minute
   sharded round trip replaces a local check.
2. The CEO's 2026-09-08 order is not the tidy answer's poor relation. It is the only step in
   either plan that addresses the population that spent the hours, and both plans ranked it
   last after evaluating it against a consumer their own design deletes.
3. **"Landing a change costs about an hour" is false, on a wider and fairer window than either
   Sage used.** So is the brief that carried it. That is the sixth wrong explanation of the
   day, and it is in the brief that commissioned these two documents.

Sage #1 is the more accurate document. Sage #2 is the better-instrumented one. Neither is
safe to execute in its stated order.

---

## 1. The 84.8 versus 46.9 hours — the brief's premise is wrong too

**Neither number is wrong. They measure different things over different corpora, and the brief's
assertion that "at least one of those is wrong" is itself the error.**

- Sage #2: 8-day window, 261 subagent transcripts, **execution plus polling**. I reproduce
  **84.8 h** to the decimal (`tools/decomp.py` → `results/suite-wait-decomposition.txt`).
- Sage #1: all 1,713 transcripts on the machine, all time, **execution only** — it explicitly
  excludes the `until … sleep` loops ("377 calls ≥ 10 min, of which 97 name a suite; most of
  the rest are `until … sleep` loops"). **46.9 h.**

I tested Sage #2's regex for the false-positive class it invites (`suites?\b` matches any
command containing the word "suite"). It is clean:

```
TOTAL matched by the committed regex: 84.8 h
  EXEC   20.1 h     (the command actually runs a suite)
  POLL   62.1 h     (until/sleep, pgrep, docker logs, lsof -p)
  READ    0.2 h     (cat/grep/sed that merely mentions a suite file)
  OTHER   2.4 h
```

`results/suite-wait-decomposition.txt`, and the 35 largest calls are printed there for
inspection — they are real suite runs and real polling loops on real suite runs.

**So the honest statement is: in the last eight days, agents were blocked on suites for
84.8 hours, of which 20.1 was foreground execution and 62.1 was polling a background run.**
Sage #2's number survives scrutiny. Sage #1's does not contradict it.

**Where Sage #1 fails a rule it sets for itself:** its §8 lists the transcript reader as
`python3 <transcript reader over ~/.claude/projects/…>`. **The script is not committed** — it
lived in a session scratchpad that no longer exists. Its headline 46.9 h cannot be re-derived
by anybody, in a document whose opening line promises every number names the command that
produced it. Sage #2 committed its tools. On reproducibility that is not a tie.

---

## 2. Where the hours actually are — the thing they both missed

`tools/attrib.py` → `results/suite-wait-attribution.txt`, same corpus, same regex, one extra
column: whose worktree the commands ran in.

```
zach   70.5 h  (83%)      echo  6.8 h  (8%)      tom  2.0 h      reed 1.0 h
sage    0.6 h              urban 0.4 h            ray  0.0 h      art/ace/mark/norm  absent
```

Top agents: `zach-opus-rs1` 5.36 h, `zach-opus-ob1` 5.21 h, `zach-opus-c1` 3.87 h,
`zach-opus-si1` 3.75 h, `zach-opus-sg1` 3.34 h — 25 agents carry 68% of the total and 23 of
those 25 are Zach.

**Read what those agents were doing.** The largest single calls in
`results/suite-wait-decomposition.txt` are `reap-stale-worktrees.mutation.sh`,
`guard-worktree-removal.test.sh`, `engine-status.test.sh`, `contract-integrity.test.sh`, and
`docker logs richos-linux-*` — Linux parity runs in containers. This is the worktree-lifecycle
and guard-hardening program. **For that program, running the suite is the deliverable, not a
tax on it.**

Consequences both documents get wrong:

1. **Sage #2's §5 "best obtainable" argument fails.** Its claim that the agent-side tax goes
   to zero assumes the agent's remaining work is independent of the suite. For 83% of the
   measured hours it is the same work.
2. **The benefit of Step 1 / Step 3 (CI sharding) accrues to a population that currently
   spends almost nothing.** Feature engineers do not appear in the attribution at all. That is
   not an argument against CI — CI is right — it is an argument against CI being *first*.
3. **The binding constraint is not total wall clock. It is the per-check ceiling.** The Bash
   tool caps a call at 600 s. `results/suite-wait-decomposition.txt` shows **239 polling calls
   hitting that cap**; the cap is why the polling loops exist at all. Any check an engineer
   must run that exceeds ~10 minutes converts into a poll loop plus a model turn per
   re-issue, regardless of whether the full pass lives in CI. Neither plan states this as the
   constraint; Sage #1 explicitly dismisses splitting below the section level as "past the
   point where anyone is waiting." It is exactly the point where somebody is waiting.

---

## 3. "An hour per land" does not survive measurement, on either window

Sage #2 measured merge → push and got 0.8 min median. That window is open to the obvious
objection that the verification happens *before* the merge, so I measured a strictly wider
one: **previous push → this push, every Bash call in between, for every episode containing at
least one merge** (`tools/landwindow.py` → `results/land-episode-verification.txt`).

```
land episodes (previous push -> this push, containing >=1 merge): 229
verification minutes inside the episode: median 0.0  p75 0.0  p90 1.1  max 25.8  mean 0.8
episodes with >=30 min verification: 0
episodes with  0 min verification: 137
total verification inside land episodes over 8 days: 3.0 h
```

**229 lands in eight days; three hours of verification across all of them; not one land paid
30 minutes.** The heaviest episode in the corpus paid 25.8 minutes and had a span of 753
minutes, which is Rich doing other things, not verifying.

So:

- Sage #2 is right that the hour is not in the land, and my wider window supports it more
  strongly than its own window did. Credit where it is due.
- **Step 2 of Sage #2 and Step 4 of Sage #1 — "the land becomes seconds", a new
  `affected-suites` script, a tree-closure guard, doctrine retirement — target a cost measured
  at three hours per eight days.** Both plans put it second. That is a day of build against
  0.4 hours a day of measured loss, most of which is already zero.
- The brief that commissioned both documents asserted the hour as established fact and both
  Sages had to spend their opening sections dismantling it. Neither escalated that the
  premise was false; both quietly re-ranked around it. That is the polite failure, and it is
  the one the record keeps recording.

---

## 4. The recommended order is not self-serving. It is worse than that — it is untested

I looked hard for motivated reasoning and did not find it. What I found is that **both plans
evaluated the CEO's order against the wrong consumer and neither noticed.**

Sage #2 §4 Step 4: *"After Steps 1–3 nobody needs a local full pass, so a faster local full
pass has no consumer. It would carry the documented load-flake risk and a floor of 5–12
minutes on the operator's own machine."*

Every clause is about **the local full pass**. Nobody asked for a faster local full pass.
The consumer that matters is the engineer who changed one guard and must run **one section**
of `contract-integrity`. For him, mutant concurrency is the difference between a section that
fits under the tool ceiling and a section that does not.

**The evidence Sage #2 used to claim scoped runs are already fast is sampled from the cheap
sections.** Its §5.2 cites "a scoped run is 1–181 s (measured)". That range comes from
`docs/measurements/integrity-suite-cost-2026-09-04/results/scoped-timings.txt`, which lists
**17 sections**. `contract-integrity.test.sh --list` reports **24**. The seven with no scoped
timing are `Q, Qscope, IL, RI, MC6, WTI, SA` — and they include **WTI, the single largest cost
center in the suite** (Sage #1: 630 s, 18.8%). The 17 measured sections sum to 1,186 s of a
2,977.9 s suite: **the unmeasured 7 carry roughly 60% of the cost.** The "1–181 s" promise is
measured over the cheapest 40% of the suite.

And the corpus contains the counterexample: a real agent call
`contract-integrity.test.sh --only IL,SA` **hit the 601 s tool cap**
(`results/suite-wait-decomposition.txt`). A two-section scoped run did not finish in ten
minutes. That is the promise "the land waits seconds" failing in the record, today, on the
scoping mechanism both plans build their agent-side step on.

**So on the order: the CEO is right and both reviewers are wrong.** Mutant concurrency is the
only proposed step that lowers the largest scoped unit below the tool ceiling. It needs no
green CI, no push trigger, no red-main risk, and it pays the population that spent 70 of the
84.8 hours. Sage #1 is honest that it costs 2–3 days and needs the two in-place harnesses
restructured first; that is a real prerequisite and it does not change the ranking.

**One correction to Sage #2 on the mutation corpus.** Its §3 states as a preserved invariant:
*"no mutant ever touches a shipped file — the `mutation-harness.sh` sandbox stays the
mechanism."* False. `grep -l BASE_MD5` over the 40 harnesses returns
`guard-worktree-removal.mutation.sh` and `guard-worktree-isolation.mutation.sh` — two
harnesses that mutate in place and restore. Sage #1 found this; femcboost's own CLAUDE.md
records the corrected count as 2. It is not load-bearing for cross-machine sharding (each
shard is the unchanged serial loop) but it **is** load-bearing for the CEO's order, and Sage #2
discusses local concurrency without mentioning it at all.

---

## 5. What makes this fail in practice

### 5.1 The red CI is a newness problem, not a portability problem, and it is a standing tax

The brief asked whether "CI carries the full pass" survives a repo whose CI has been red for
days and whose suite count went 60 → 121 in five days. **It does not survive as sequenced.**

`git log --diff-filter=A --name-only -- 'engine/**/*.test.sh'` since 2026-08-28:
**101 of the 120 suites that exist today were created in the last twelve days** — 5, 10, 5, 6,
7, 7, 2, 10, 9, **35**, 5 per day. And the three non-`contract-integrity` red suites were
created on **2026-09-03, 2026-09-04 and 2026-09-07**.

The suites are red because they are days old, written on macOS, and have never run on Linux.
This is not a defect to be fixed once. It is an inflow of roughly **eight never-Linux-tested
suites per day**. Both plans say "make CI green, then turn on `push:`" and both mark the cause
`unverified` because neither read the failure logs. I read them:
`shell-worktree-sparse` S01 fails with `before=608K after=608K` and S01c with
`before= after= freed=` — that is a `du` flag difference. `contract-integrity` case 33 is
`git-untracked-not-ignored-warns-rc-0 (expected exit=0 got=2)` — reads as a git-version
difference. `terminalize-agent-worktrees` fails 11 of 42 with "ingress WON the claim" and
"states: bound bound", which reads as real behavior, not portability. So the split is roughly
two environment, one real, one unread — *unverified* beyond the log text.

**The chicken-and-egg neither plan sequences: you cannot reach green while eight untested
suites land per day, and you cannot stop that inflow without a required check.** Fixing four
suites today buys a green run that the next day's ten new suites break.

**The step both plans are missing, and it is the cheapest step in this document:** a required
CI job that runs **only the suites the diff adds or changes**, on `ubuntu-latest`, on every
push. It is one job, not a 15–18 job matrix. It does not need the suite to be green. It stops
the inflow on day one and makes green reachable by attrition instead of by a heroic sweep.
Neither document proposes it.

### 5.2 `--only` already exists and was used fourteen times in eight days

`tools/scoped2.py` → `results/what-agents-actually-invoked.txt`:

```
one named .test.sh          10.63 h    807 calls  mean  47 s
contract-integrity FULL      5.69 h    180 calls  mean 114 s
one mutation harness         2.96 h    208 calls  mean  51 s
contract-integrity --only    0.73 h     14 calls  mean 188 s
whole-engine pass            0.37 h     49 calls  mean  27 s
```

**The full suite was invoked 180 times. Its scoped equivalent 14 times.** The low mean on the
full runs is because most were backgrounded — the 62.1 hours of polling is their shadow.

The mechanism both plans make the centerpiece of their agent-side step **already ships,
already returns exit 3, already has independent sections, and was used in 7% of the
opportunities.** Sage #2's Step 3a/3b and Sage #1's Step 4 propose building a new
`affected-suites` script to compute what `--only` already accepts. **Build nothing. Change the
brief and the runner's exit banner.** That is hours of work against the largest measured loss
in the corpus, and it is ranked below a day of CI sharding in both plans.

This also reframes the CEO's order correctly: **once scoping is actually used, the largest
scoped unit still exceeds the tool ceiling** — which is precisely when mutant concurrency
stops being a nicety.

### 5.3 Practical failures neither plan costed

1. **The 20-job concurrency limit is an account limit, not a repository limit.** GitHub's
   limits page gives Free plan 20 concurrent jobs and 5 macOS, and says the macOS limit "is
   shared across standard GitHub-hosted runners and GitHub-hosted larger runners" — which
   reads as account scope; the page does not state scope explicitly (*unverified*). With four
   repositories on this account and 30–48 pushes a day, a 15–18 job matrix per push saturates
   the account and CI wall clock becomes queue-bound. Sage #2's "a 15–18 job matrix fits" is
   sized against a per-repository reading of a limit that is probably per-account.
2. **There is no copy-on-write in CI.** The run log says it in plain text:
   `note: copy-on-write clones are unavailable under /tmp — using a plain recursive copy.
   Identical sandboxes, slower run.` The measurement both plans lean on for "the cost is
   mutants, not sandboxes" (0.1% of the run) was taken on APFS with `clonefile`. On the runner,
   every sandbox is a full recursive copy. Both plans carry a macOS-measured premise into a
   Linux-centric design without noting that the premise's mechanism is absent there.
3. **The two documents derive opposite Mac↔runner conversion factors from the same pair of
   numbers.** Sage #2: "1.4–2.0x runner-vs-container slowdown." Sage #1: "the whole suite ran
   0.78x faster on the runner." Both then use their factor to produce the same "~10 min CI
   wall" estimate. The 2,977.9 s Mac figure was taken when case 50c aborted the suite early,
   so it covered fewer cases than the runner's 167 — the comparison is not valid in either
   direction, and neither document flags it. **The "~10 minutes" both plans promise rests on a
   conversion factor whose sign is unknown.** I verified the runner side independently:
   `contract-integrity` 2,335.9 s, `reconcile-terminal-worktrees` 939.7 s,
   `worktree-transactions` 415.9 s, `row-currency` 387.4 s, `reap-stale-worktrees` 339.3 s,
   `ceo-todos` 322.4 s, total 113.0 min from suite 10 to 121
   (`results/ci-run-34396549904.log`). Sage #1's table reproduces exactly, and its packing
   floor of 38.9 min is real. The Mac side is what nobody has.
4. **A red main after the agent is gone costs a fresh agent, and neither plan costs it.** This
   repository forbids resuming a completed teammate for file work and removes worktrees at land
   time. So a post-merge red is not "Rich fixes it" — it is spawn a new teammate, new worktree,
   re-derive the context, re-land. Agent active time is median 22 min, p90 116 min. Under
   Sage #2's tree-closure guard, every other land is blocked while that happens, with a single
   writer and 30–48 lands a day. **The tree-closure guard is a stall amplifier in a
   single-writer repository**, and its escape hatch (`ci-fix:` or `revert` in the subject) is
   the habitual-waiver shape this project has recorded dying three times in one day as
   g11/g12/g13. Sage #1's post-merge notice, without the block, is the safer of the two.
5. **`cancel-in-progress` plus 48 lands a day destroys the bisect property.** Both plans rely
   on "a red result bisects to a handful of commits." With cancellation on a burst, completed
   runs are sparse and each covers many commits. It is survivable; it is not what either plan
   claims.

---

## 6. What is sound, and should not be relitigated

- **The end state is right and it is the wheel.** Full pass off every human and agent clock,
  scoped checks locally, mutation on its own schedule, per-suite timing as a first-class
  output, red surfaced. Fifteen years old, both documents describe it accurately, and the
  repository genuinely departs from it. No argument from me.
- **Step 0, instrument first, in both documents.** Correct, cheap, and it is the step that
  would have prevented all five wrong explanations. It should be first and it is.
- **Sage #1's CI per-suite table.** Reproduced exactly from the run log. Its conclusion that
  suite-level sharding cannot beat 38.9 min and that `contract-integrity` must be sharded by
  section is correct and load-bearing.
- **Sage #1's in-place mutation census** and its refusal to accept the 2026-09-04 README's
  "embarrassingly parallel by construction." That is the single best catch in either document.
- **Sage #2's committed instrumentation.** Its tools are in the repository and its headline
  number reproduces to the decimal. That is the standard.
- **Both plans preserve coverage.** No case, mutant or section is dropped. Sage #2's coverage
  job — the union of shard manifests must equal discovery — is the right mechanism and should
  survive any re-ordering.

---

## 7. The order I would defend

Every element below is already designed in one of the two documents. Only the order changes,
and it changes because of §2 and §5.2.

| # | Step | Why here | Source |
|---|---|---|---|
| 0 | Instrument: per-suite timing in the runner, the agent-runtime report, per-section timing for **all 24** sections including the seven that have none | Unchanged from both plans. Add the missing seven sections, because the acceptance promise is quoted from a table that excludes them | both |
| 1 | **Scoping discipline**: `--only` becomes what a brief orders and what the runner's banner tells you to run. Hours of work | 180 full invocations against 14 scoped, and 62.1 h of polling is their shadow. Largest measured loss, smallest build | Sage #2 3a/3c, Sage #1 4 — both ranked lower |
| 2 | **Mutant concurrency (the CEO's order)**, with the two in-place harnesses restructured first and CL1/CL2 characterized under load | After step 1 the largest scoped unit still exceeds the 600 s tool ceiling. This is the only step that fixes that, and it pays the 83% | Sage #1 6, Sage #2 §4 "deliberately NOT" |
| 3 | **Required CI job on the diff's own suites only**, `ubuntu-latest`, every push | Stops eight never-Linux-tested suites landing per day. Makes green reachable. One job. **Neither plan has this** | new |
| 4 | Fix or quarantine the four red suites, with the causes actually read | Now it stays fixed, because 3 stops the inflow | both |
| 5 | Shard CI by suite and by section, restore `push:`, coverage job asserts the union | The wheel. Unchanged from Sage #2 1a–1e, sized by 0 | Sage #2 1 |
| 6 | Post-merge red **surfaced** at SessionStart/Stop, no blocking tree-closure guard until red-main windows are measured | The block is a stall amplifier with one writer; the notice is free | Sage #1 7 |
| 7 | Local land check scoped by change | Targets 3.0 h per 8 days. Last, because that is what it is worth | Sage #2 2a, Sage #1 4 |

---

## 8. The one thing I would still not bet on

**That any of this reduces the hours, because the cost is not the suite — it is the rate at
which this repository writes new guards.**

101 of 120 suites in twelve days. Thirty-five in one day. Every guard arrives with a test
suite and often a mutation harness, and each harness multiplies a suite by its mutant count.
Sharding buys a one-time division by the number of runners you can afford; the corpus is
growing at roughly eight suites a day and 84% of it is younger than two weeks. The arithmetic
says sharding stays ahead — about 22 seconds of added wall clock per day against a 20-job
matrix — so Sage #1's "this design does not notice the growth" holds on wall clock.

What it does not hold on is **stability**. A corpus in which four suites are red, three of them
days old, and eight more arrive daily, is not a corpus you can gate a repository on. Both
plans assume green is a state you reach and then keep. On this inflow it is a state you rent.

Neither document questions the inflow, and I would not sign a plan whose value depends on
green without someone asking whether every guard needs a mutation harness, whether a harness
whose mutants have never survived is still buying anything, and what the standing cost per
guard actually is. That is a business decision about how much verification this project can
afford, and it belongs to the CEO. It is the question I would put to him ahead of the ordering
question, because the answer changes what steps 2 and 5 are even for.

---

## 9. What I did not verify

- **The causes of the four red suites.** I read the failure text in the run log, not the code
  paths. The `du` and git-version readings are inferences from the assertion output.
- **Whether the 20-job concurrency limit is account-scoped.** GitHub's limits page does not say.
  The macOS row's "shared across" wording reads as account scope. Treat as *unverified*.
- **Any Mac-side timing.** I ran no suite except `--list` (24 sections) and read the committed
  scoped-timings table. The Mac↔runner conversion factor remains unknown in sign, which is my
  §5.3.3 objection and I have not resolved it either.
- **Per-section time for the seven unmeasured sections.** That is step 0's job and it is the
  measurement that decides whether step 1 alone is sufficient.
- **Whether Zach's 70.5 hours were all necessary.** I established that his task was the
  infrastructure; I did not audit how much of the 180 full invocations a disciplined engineer
  would have scoped. My step 1 assumes a large share; that is an assumption, not a measurement.
- **The 46.9 h figure.** Not reproducible — the script was never committed.

## Method

Scripts in `docs/measurements/frank-review-2026-09-09/tools/`, output in `…/results/`:

- `decomp.py` → `suite-wait-decomposition.txt` — re-runs Sage #2's regex over the same 8-day
  subagent corpus, splits the total into execution / polling / read-only false positives, and
  prints the 35 largest calls and the count that hit the 600 s tool cap.
- `attrib.py` → `suite-wait-attribution.txt` — same corpus and regex, attributed per agent and
  per role token of the worktree path.
- `landwindow.py` → `land-episode-verification.txt` — Rich's main-session transcripts; every
  episode from one push to the next containing at least one merge; verification seconds inside
  the whole episode, not only between merge and push.
- `scoped2.py` → `what-agents-actually-invoked.txt` — what the suite-executing calls actually
  were: full `contract-integrity`, `--only`, whole-engine pass, one named suite, one harness.
- `ci-run-34396549904.log` — the GitHub run log, from which the per-suite durations in §5.3.3
  were re-derived independently of Sage #1.

Caveats stated rather than hidden. The attribution names an agent by the worktree path
appearing in its own commands, so an agent that never names a worktree falls into `?` (0.0 h,
so it does not move the result). The land-episode window is generous in the other direction
from Sage #2's: it counts every suite-shaped call between two pushes, including ones that had
nothing to do with the land, so 3.0 h is an upper bound. The transcript corpus grows while
being read, so counts move by one or two between runs.
