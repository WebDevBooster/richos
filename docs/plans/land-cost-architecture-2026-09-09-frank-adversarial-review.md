# Both Sages are ~70% right, and the 30% is the part that decides the order

**Adversarial review. Author: Frank (Expert Advisor / Devil's Advocate), Opus.**
Worktree `richos-wt/frank-opus-lc2`, branch `frank-opus-lc2`, written against `d3195bb5`
(the merge carrying both plans). Scripts and captured output:
`docs/measurements/land-cost-review-2026-09-09/`. Every number below either names the
command that produced it or carries the word `unverified`.

Under review:

- `docs/plans/land-cost-architecture-2026-09-09.md` — Sage #2, at `7ae330b3`
- `docs/plans/land-cost-architecture-2026-09-09-second-review.md` — Sage #1, at `d3195bb5`

The brief asked me to find what two Fable instances missed *because they were both looking
the same way*. I found it, and it is not a nuance: **they both looked at the last ten runs of
a CI system that has eighty-six, and eighteen of the eighty-six are green.**

---

## 0. The verdict in five lines

1. **The end state is right.** "The full pass never runs on a clock anyone is watching" is
   correct, standard, and I would not argue with it. Section sharding works — I ran one
   section standalone and it was green in 68 seconds.
2. **The diagnosis is wrong.** Not incomplete — wrong. The cost has a start date of
   **2026-08-28**, and CI's absence cannot explain it, because CI was equally absent through
   all of August when the cost was near zero.
3. **The central recommendation has already been tried.** `push:` was live, and CI was
   **green 18 times on 2026-08-29**. It then went red, and the workflow was manually disabled
   on 2026-09-01. Both plans recommend installing a wheel that was installed, turned, and
   broken eleven days ago.
4. **Neither plan contains a governor on the variable that broke it**, and both explicitly
   promise never to shrink coverage — which is the constraint that guarantees recurrence.
5. **The CEO's ordering is better than either plan's on risk**, for a reason neither engaged
   with: his item is the only one on the list that is not blocked behind an unestimated task.

---

## 1. Where they are both wrong — the shared blind spot

### 1.1 Both mistook a default `--limit` for the history

Sage #1: *"Three dispatches, all red."* Sage #2: *"CI exists and is `workflow_dispatch`-only;
the last three dispatches took 2h16m, 1h35m, 2h04m ... and all three failed."* Both are
literally true and both are the wrong question.

```
gh run list --workflow engine-self-verify.yml --repo WebDevBooster/richos --limit 100 \
  --json conclusion,event,createdAt
  -> total runs: 86
     by conclusion: {'failure': 68, 'success': 18}
     by event:      {'push': 83, 'workflow_dispatch': 3}
     all 18 successes: 2026-08-29, every one push-triggered
     earliest run 2026-08-29T09:22:50Z   latest 2026-09-09T19:41:24Z
```

**Eighty-three of eighty-six runs were push-triggered, and eighteen were green, all on
2026-08-29.** The full pass on every push, in CI, on nobody's clock, is not a wheel this
repository failed to invent. It is a wheel this repository *had*, running green, and then
lost. The nine push runs on 2026-09-01 completed in nine to fifteen minutes each — the
`ubuntu-latest` runner did the whole pass in about ten minutes eight days ago.

Worse for the review: **the reason is written in the file both Sages read.** Both cite
`.github/workflows/engine-self-verify.yml`'s header for other facts. That same header carries
a section titled *"THAT IS THE WHOLE CHANGE" IS WRONG, AND IT IS WRONG IN THE WAY THAT WASTES
A DAY*, which records `state: disabled_manually`, `updated_at 2026-09-01T10:49:51+01:00`, the
`HTTP 422: Cannot trigger a 'workflow_dispatch' on a disabled workflow`, that the lead
re-enabled the workflow on 2026-09-06, and that a manually disabled workflow **does not run
on `push` either** — so adding the triggers back "would have produced a file that reads as
re-enabled, a green checklist item, and not one execution."

Neither plan mentions any of it. Sage #1's step 3 and Sage #2's item 1e both say, in
substance, "restore `push:` and `pull_request:`" — the exact instruction that file spends
sixty lines explaining is insufficient. Two reviewers read the same file the same way and
both skipped the section written to stop precisely this.

### 1.2 Neither plan has a governor, and both forbid the only other lever

Both state, as a preserved constraint, that coverage never shrinks: Sage #2 — *"every case,
every mutant, every full pass, still runs on every commit to main"*; Sage #1 — *"Nothing in
this table shrinks coverage."* Combine that with §2's growth rate and the design has exactly
one degree of freedom left, shard count, which is hard-capped (§4.1). There is no cost budget
on a new suite, no declared wall clock for a new harness, no ceiling that anybody has to ask
to raise. Sharding is a constant-factor fix bolted to an unbounded producer.

### 1.3 The aggregate ratio is generalized from the three agents least entitled to it

Sage #2 validates its instrument against `zach-opus-ob1`, `zach-opus-cg1`, `zach-opus-rg1`
and reports 154–312 of their minutes as suite-wait. That validation is genuinely good — it
reproduces the hand-timed record exactly. But those three are the *infrastructure* agents
whose assigned task **was** the worktree and CI machinery. For an agent hired to make a suite
green, time inside the suite is the work, not the tax. The 43% is then quoted as a property of
all agent time. It is a property of a corpus whose long tail is dominated by agents working on
the test system itself. Sage #2's own distribution says the median agent is 22 minutes active
and p75 is 67 — "3, 4 or 5 hours for a simple task" is 13 agents of 260. Fixing the tail is
right; describing the tail as a 43% tax on everybody is not.

---

## 2. Is the diagnosis the cause? No. The cost has a start date and a covariate.

This is the finding I would put in front of the CEO first.

`docs/measurements/land-cost-review-2026-09-09/tools/trend.py` — suite-wait per calendar day
across all 1,715 subagent transcripts on this machine (matcher: a call that invokes a
suite/probe, or polls one; see §3):

```
date        suite-wait_h   all-bash_h   agents
2026-08-06         0.2          0.7         86
2026-08-10         0.1          0.9        335
2026-08-16         0.5          5.5         74
2026-08-25         0.1          4.5         57
2026-08-27        (no agent activity recorded)
2026-08-28         1.4          4.1         26
2026-08-29         3.5         11.0         36
2026-08-30         7.7         15.2         48
2026-09-01         8.3         20.4         40
2026-09-02        10.3         13.8         40
2026-09-04        10.9         17.4         37
2026-09-05        17.8         27.3         49
2026-09-06        21.2         30.0         46
2026-09-08        10.6         11.4         15
```

For the whole of August — including a day with **335 agents** — suite-wait is at or below
1.2 h/day and usually near 0.1. CI was not carrying the full pass on any of those days
either. **An architectural omission that was present for a month while the cost was zero is
not the cause of a cost that started on 2026-08-28.**

Here is what did start on 2026-08-28
(`docs/measurements/land-cost-review-2026-09-09/tools/counts.sh`, `git ls-tree` at the last
commit of each day on `main`):

```
2026-08-24  suites=15   mutation_harnesses=0     f6d8c240
2026-08-27  suites=15   mutation_harnesses=0     c608a6ee
2026-08-28  suites=22   mutation_harnesses=2     48561e4c   <- first non-zero suite-wait day
2026-08-29  suites=27   mutation_harnesses=2     07380544
2026-08-30  suites=37   mutation_harnesses=4     9fe7456d
2026-09-01  suites=53   mutation_harnesses=12    344aa566
2026-09-02  suites=60   mutation_harnesses=17    b2840131
2026-09-04  suites=70   mutation_harnesses=33    4d5734c7
2026-09-06  suites=89   mutation_harnesses=40    aaba62ed
2026-09-09  suites=128  mutation_harnesses=40    d3195bb5
```

**The first mutation harness was created on the first day suite-wait is non-zero.** Suite
files went 15 → 128 in sixteen days (8.5x); harnesses went 0 → 40 in nine.

And the wall clock moved superlinearly, from the repository's own records:

- workflow header: `timeout-minutes: 45` was set when the runner was **24 suites, about seven
  minutes** on the Mac.
- the 2026-08-29 green push runs: **9 to 15 minutes** each on `ubuntu-latest`.
- run `34396549904`, 2026-09-09: **124 minutes**, 117/121, four red.

**5.3x the suites bought 17x the wall clock**, because each harness runs a whole behavioral
suite once per mutant. Measured, not argued:
`docs/measurements/integrity-suite-cost-2026-09-04/README.md:78` — 19 mutation cases were
**2347.7 s, 70.0%** of `contract-integrity.test.sh`, and that was at **12** harnesses. There
are now 40, declaring **427** `mutant` lines through the shared loop alone
(`docs/measurements/land-cost-review-2026-09-09/results/harness-census.txt`).

**So the correct causal sentence is not "CI was never switched on."** It is: *a nine-day
mutation-harness build-out multiplied the full pass by roughly seventeen, which broke a CI
gate that had been green, and the full pass fell back onto the clocks of whoever was standing
there.* Both plans treat the fallback as the disease. It is the symptom. The disease is still
running at full speed: 89 suites on 09-06, 128 on 09-09 — thirty-nine in three days.

One small consequence: Sage #2 attributes the stale 49.6-minute figure to case `50c` aborting
the suite *"since `28f07ab5`"*. `git log -1 28f07ab5` → **2026-09-08 12:43:12**. That is a
one-day window, not a standing condition, and it cannot explain an onset ten days earlier.

---

## 3. The load-bearing number: 84.8 or 46.9?

**Both are correct, they measure different things, and neither document says which thing.**
That is the failure, not the arithmetic.

I re-ran Sage #2's committed script and reproduced **84.8 h exactly**, then decomposed it by
what the matched command actually was
(`docs/measurements/land-cost-review-2026-09-09/results/attribute.txt`):

```
total Bash wait h  120.5
SAGE#2 match       84.8  (n=4920)
  A_polling_a_background_run   62.9 h  n=854   (74%)
  B_directly_invokes_suite     18.7 h  n=1522  (22%)
  C_only_MENTIONS_suite         3.1 h  n=2544  ( 4%)
```

I went in expecting Sage #2's regex to be the problem — it carries a bare `suites?\b`
alternative and an unconditional `pgrep`. **I was wrong, and the number holds.** The polling
bucket is genuine, and the samples say so in the commands themselves:

```
601s  until ! pgrep -qf 'contract-integrity.test.sh'; do sleep 10; done; echo DONE; tail -20 ...
600s  until ! pgrep -q -f 'bash scripts/hooks/contract-integrity[.]test[.]sh'; do sleep 30; done; ...
600s  lsof -p 62093 +r 5 >/dev/null 2>&1; echo RUNNER_DONE; tail -25 ...
```

Only the 3.1 h C-bucket is arguable, and most of even that is `run-suites.sh`, `demo.test.sh`
and `npm test`. **84.8 h stands.**

Sage #1's 46.9 h counts **only direct invocations**, over **all 1,715 transcripts (all
time)**, and excludes the polling loops. Its own text names the excluded category as the
dominant one — *"377 calls >= 10 min, of which 97 name a suite; most of the rest are `until
... sleep` loops waiting on a suite run in the background"* — and then does not count them.
Same corpus, my independent recomputation
(`docs/measurements/land-cost-review-2026-09-09/results/alltime.txt`):

```
ALL-TIME, 1,715 transcripts
  invoking calls        :  42.2 h  n=2810   <- comparable to Sage#1's "46.9 h / 2,649 calls"
  polling-a-suite calls :  69.6 h  n=1291   <- excluded by Sage#1, counted by Sage#2
  invoking + polling    : 111.8 h
```

So: Sage #1's figure reproduces as a measurement of invocation only, over a corpus more than
six times larger and a window several times longer than Sage #2's. It is not a competing
estimate; it is a strictly smaller quantity presented in the same units without saying so.

**Three consequences the brief should carry:**

1. **The right total is ~112 h all-time, and 84.8 h of it is in the last eight days — 76%.**
   The load-bearing quantity was never the 43% share. It is the slope, and neither plan
   plots it.
2. **Sage #1's idle threshold is set exactly at the tool ceiling.** It drops gaps over ten
   minutes, and the Bash tool caps at ten minutes, so every maxed-out polling call falls on
   the idle side of its own filter — the precise phenomenon under study, deleted by the
   instrument. Sage #1 states the caveat and then quotes the numbers anyway. Sage #2's
   fifteen-minute cut is the right call, and the sensitivity is real: all-time active time is
   503.2 h at a ten-minute cut and 560.9 h at fifteen.
3. **Only one of the two is reproducible.** Sage #2's scripts are committed and I ran them.
   Sage #1's live in a session scratchpad, and its §8 lists `python3 <transcript reader over
   ~/.claude/projects/*/*/subagents/agent-*.jsonl>` — a description of a command, not a
   command. By this project's own standing rule, Sage #1's headline number as delivered is
   `unverified`.

**Two defects in Sage #2's land-cost work, since the brief called the number load-bearing.**
Its committed `land-cost.py` prints `full-suite invocations by Rich 129`, while the document
says *"27 strict invocations in 8 days ... heredocs excluded"* — two scripts, two numbers,
and the tail of the 129 is heredocs writing documents and `git commit` lines, not suite runs.
The direction is harmless for its conclusion, but the document quotes the clean figure and
ships the dirty script. Second, and more substantive: **§5.1 is circular.** It measures
merge → push (0.8 min median), a window that by the lander's own sequence excludes the
pre-merge verification, then concludes *"the remaining cost is the mechanical land, already
0.8 min median ... 'Seconds' is met by construction."* You cannot establish that a cost is
gone by measuring an interval defined to exclude it. The tail confirms the pairing is loose:
`max 392` minutes with zero full passes in between is a merge paired to an unrelated later
push.

---

## 4. What makes this fail in practice

### 4.1 The concurrency limit drops runs. It does not queue them. This is the one that is fatal.

GitHub Actions reference, fetched 2026-09-09: **Free plan = 20 total concurrent jobs,
account-wide** (not per repository), macOS capped at 5 — and, verbatim on the mechanism:
*"When the limit is reached, the workflow runs that were supposed to be triggered by the
webhook events will be blocked and will not be queued."*

`gh workflow list --all --repo WebDevBooster/richos` — engine-self-verify is **not** the only
consumer:

```
app-spine-ci            active
app-voice-ci            active
engine-self-verify      active
packaging-ci            disabled_manually
ui-suite-ci             active
vouch-pr                active
windows-companion-ci    active
Dependabot Updates      active
```

**Six other active workflows share that 20-job account budget.** Sage #2 asserts the 20-job
number and reads it as headroom — *"A 15–18 job matrix fits"* — for one workflow, consuming
75–90% of the account's entire concurrency. Sage #1 marks the limit `unverified` and dismisses
it: *"It bounds shard count, not the design."* That is backwards. It bounds **throughput**,
and throughput is the design.

**The failure mode is the worst one available.** A dropped run leaves **no run record for that
SHA at all** — not red, not pending, nothing to look at. Sage #2's tree-closure guard (2b)
reads *"the latest **completed** run"*; under drops that is an older SHA, and it reports
green. So the design's headline guarantee — every case and every mutant on every commit to
`main`, coverage unchanged — silently becomes false under exactly the load it was built for,
**and reports success while doing it.** In a repository whose whole doctrine is "identity or
refuse" and whose engine exists to end checks that pass for the wrong reason, that is the
signature defect reintroduced at the center of the fix.

`concurrency: cancel-in-progress: true` (Sage #2 1e, Sage #1 step 3) is chosen deliberately
and makes it worse. Sage #1's own §3.4 records 48 lands on 2026-09-06; the run list shows
three push runs created within **29 seconds** on 2026-09-01. A superseded run concludes
`cancelled`, which is neither green nor red, so a burst of lands leaves most commits with no
verdict at all. At 48 lands/day against a 10-minute pass, the majority of commits are
superseded before they finish.

The missing job neither plan has: **one that fails when a SHA on `main` has no completed run
record.** Without it, "CI carries the full pass" is unfalsifiable.

### 4.2 The rework loop is uncosted, and it lands on the CEO's clock

Post-merge-only CI, plus "Rich is the only writer to `main`", plus Rich never writes code,
plus "never resume a landed/cleaned agent for file work" (the resume guard blocks it), equals:
**every red CI result requires a fresh spawn, a fresh worktree, and re-derived context.**
Neither plan puts a number, or a sentence, on that path. Against 48 lands/day, four known-red
suites, and zero green runs in eleven days, the respawn tax can plausibly exceed the 84.8 h it
saves — and it converts an agent's wait, which the CEO does not watch, into an
orchestration cycle he does. Sage #1 lists "red-main windows per week" as a future
measurement; that sizes the window, not the cost of closing it.

### 4.3 A blocking PreToolUse hook that calls the network, in front of the only writer to main

Sage #2's 2b puts `gh run list` ahead of every `git push … main`. Unspecified: what it does
when the network is down, `gh` auth has expired, or the API rate-limits. Fail-closed wedges
the only writer to `main` on a blip; fail-open is decoration. This repository's own record
already says that a gate chained with a mutation kills the whole call and the report then gets
written from intent. A network dependency in a blocking gate needs its failure semantics
declared in the plan, not discovered at 2 a.m.

### 4.4 Quarantine with a dated expiry is the habitual-waiver pattern with a calendar

Both propose it (Sage #2 1d, Sage #1 step 2). Neither proposes anything that enforces the
expiry. Sage #2 counts guard-waiver frequency in M5 and does not count quarantine age. A
skipped suite with a date in a comment is a rule enforced by attention, which is the exact
thing the engine's own runner header condemns.

### 4.5 The instrument gate is slower than the problem it measures

Sage #2: *"Nothing in Steps 1–3 is trustworthy until Step 0 has produced one week of numbers
on Linux CI."* A week of measurement before the first fix, during a week in which the cost has
been growing about 20% per day. Shard on the numbers that already exist — run `34396549904`'s
per-suite timestamps are enough for a first packing — and refine from the TSV once it lands.

### 4.6 What does survive, and it is worth saying

**Section sharding works, and I verified the part both marked `unverified`.**
`bash scripts/hooks/contract-integrity.test.sh --list` → **24 sections** (Sage #1 correct;
Sage #2 states no count). A mid-list section run standalone from a clean worktree:

```
bash scripts/hooks/contract-integrity.test.sh --only MT
  -> rc=3, green, 68 s   (results/scoped-only-MT.log; wall clock 1788993901-1788993833)
```

Exit 3, scoped-and-green, in 68 seconds, with no dependence on any earlier section. That
plank holds for at least one section.

**But it puts a floor exactly where the CEO pointed.** The six mutation sections are each a
single case — `WTI1` 630 s, `IN2` 427 s, `MF1` 205.8 s, `SA2` 202 s, `MC6` 181 s, `RI2`
70.3 s — so section sharding cannot split them. The floor of Sage #2's 1b is one mutation
harness. Which means mutant-level concurrency is **load-bearing for their own design**, and
they ranked it last.

---

## 5. Is the deferral of the CEO's order self-serving?

**Verdict: not self-serving, but wrong on sequencing, and there is exactly one place where a
number was inflated to justify the ranking.**

**Credit first, because it is the best single technical contribution in either document.**
Sage #1 found that `guard-worktree-isolation.mutation.sh` — case `WTI1`, 630 s, 18.8% of
`contract-integrity` — reuses **one** sandbox serially rather than one directory per mutant.
I verified it: line 84 `mutation_sandbox_engine "$SRC_ENG"`, line 86
`GUARD="$ENG/scripts/hooks/guard-worktree-isolation.sh"`, line 90 `restore() { cp "$BAK"
"$GUARD"; }`, line 727's check that "mutants were compounding" if the restore failed. Two
naive workers would collide on that file. So the premise carried from the measurement README
into `RICH-TODOs.md` and from there into the plan — *"embarrassingly parallel by
construction: every mutant already gets its own directory"* — **is false for the single
largest cost center**, and Sage #1 is the only one who caught it. Sage #2 repeats the
parallel-by-construction reading.

**Now the inflation.** Sage #1 prices the prerequisite at *"Two to three days"* and puts the
order at step 6 of 7. But the primitive already exists and is public **for this exact
reason**. `engine/scripts/lib/mutation-harness.sh`:

> `mutation_copy_engine <dest> <src-engine-root>` … PUBLIC, because a harness that keeps its
> own mutant loop still needs the sandbox; the kill-proof property belongs to every harness,
> not only to the ones that adopted this file's loop.

One sandbox per worker, not per mutant — and Sage #1's own text prices a sandbox at 32 ms.
The prerequisite is real; the two-to-three-day price tag is the number that moves his item
from first to sixth, and it does not survive reading the library.

**And here is the argument neither engaged with, which I think is decisive.** Both critical
paths run through "make CI green on Linux." Sage #1's own table prices that step
*"Unknown until the 4 logs are read; `unverified`"*, in a repository that has produced **zero
green runs in eleven days** and whose portability defects have already come in three separate
classes (`sed -i ''`, `mktemp -t`, `BASH_CMDS`, per `engine/docs/ci-portability-notes.md`).
**His item is the only one on the list that is blocked on nothing** — no GitHub, no green CI,
no branch protection, no account concurrency budget, no operator-machine change — and it
targets the variable that is 70% of the largest suite and that correlates 1:1 with the cost
onset. If the CI work takes a week, his ordering delivers a faster full pass on day one and
theirs delivers nothing until the week is out.

Sage #2's stated reason for Step 4 does not hold either: *"After Steps 1–3 nobody needs a
local full pass, so a faster local full pass has no consumer."* True only **after** Steps 1–3
land, and contradicted twice inside its own document — its §2 table counts Rich's full passes
over the last eight days, and its M6 asks for a timed full pass on the Mac. Until CI is green,
the local full pass is the only gate that exists.

**One point in Sage #2's favor, and it is real.** Its 1c — `MUT_SHARD=k/n` across CI machines
— is better engineering than Sage #1's step 6, and it is immune to the in-place objection
entirely, because each shard is the unchanged serial loop in its own VM. But it is not what he
asked for, it inherits every dependency in §4.1, and Sage #2 is right to name it as his
decision rather than presenting distribution as though it were concurrency.

**Two corrections while I am here.** Sage #2's harness census is **exactly right** and I was
wrong to doubt it: 4 own-loop harnesses, correctly named (`guard-worktree-isolation`,
`guard-worktree-removal`, `root-contract`, `session-evidence`), 29 on the library loop, 427
`mutant` declarations. Sage #1's §6 claim that a sharded design *"does not notice"* the
60 → 121 growth is false: shard count scales with the **sum** and is hard-capped at 20
account-wide, so the design notices growth at the second doubling — days away at the observed
rate.

---

## 6. What I would do instead, in this order

Not a plan — the ordering that follows from the evidence above.

0. **The CEO's item, now.** Mutant concurrency inside the harnesses, using
   `mutation_copy_engine` once per worker. Unblocked, targets 70% of the largest suite,
   helps every day that CI is red, and is load-bearing for both plans' own section-sharding
   floor. Characterize CL1/CL2 under load first, as the measurement README already demands.
1. **One green Linux run**, then `push:`. Read the four failure logs before estimating
   anything; the portability class has three precedents.
2. **Shard — but budget the shards against the 20-job account limit, and add the job neither
   plan has**: a check that FAILS when a SHA on `main` carries no completed run record.
   Without it, a dropped run is indistinguishable from a green one.
3. **A cost governor.** A new suite or harness declares its wall clock; the total carries a
   ceiling that takes the CEO's word to raise. This is the only item that stops the problem
   from returning, and it is the only item neither plan contains.
4. Instrument in parallel with all of the above, never as a gate in front of them.

---

## 7. The one thing I would still not bet on

**That anything in either plan survives the growth rate that caused the problem.**

Everything else here is recoverable — a wrong number gets re-derived, a missed run history
gets read, a dropped-run hole gets a job that catches it. But both plans are constant-factor
fixes (divide by up to eighteen, capped) bolted to a producer that did 8.5x in sixteen days
and thirty-nine suites in the last three. On that arithmetic, sharding buys somewhere around
two to three weeks — `unverified`, and the growth rate may not hold — and when it runs out,
the eighteen shards are already spent and the 20-job ceiling is already reached. Then the only
levers left are the two both plans rule out by construction: run less, or grow slower.

I do not think the full pass belongs on anybody's clock, and I would ship the end state. I
would not sign the sentence *"this is the best obtainable, not merely better"* while the
variable that broke the last working CI gate has no ceiling on it and is still accelerating.

## 8. Commands

```
gh run list --workflow engine-self-verify.yml --repo WebDevBooster/richos --limit 100 \
    --json conclusion,event,createdAt          # 86 runs, 18 green, all 2026-08-29, all push
gh workflow list --all --repo WebDevBooster/richos       # 6 other active workflows
gh api repos/WebDevBooster/richos --jq '{visibility,private,fork}'   # public, not a fork
git log -1 --format='%ad %s' --date=iso 28f07ab5         # 2026-09-08 12:43:12
bash scripts/hooks/contract-integrity.test.sh --list     # 24 sections
bash scripts/hooks/contract-integrity.test.sh --only MT  # rc=3, green, 68 s
docs/measurements/land-cost-review-2026-09-09/tools/attribute.py   # 84.8 h decomposed 74/22/4
docs/measurements/land-cost-review-2026-09-09/tools/alltime.py     # 42.2 h invoke vs 69.6 h poll
docs/measurements/land-cost-review-2026-09-09/tools/trend.py       # suite-wait per day
docs/measurements/land-cost-review-2026-09-09/tools/counts.sh      # suites/harnesses per day
docs/measurements/land-cost-review-2026-09-09/tools/census.sh      # 4 own-loop, 29 library, 427 mutants
```

Sources for §4.1: <https://docs.github.com/en/actions/reference/limits> (fetched 2026-09-09).

## 9. What I did not verify

- **Why the four suites are red on Linux.** I did not read the failure logs. Every estimate
  of step 1's effort in either plan, and in mine, is therefore `unverified`.
- **Whether all 24 sections are independent.** I ran one (`MT`). The six mutation sections
  are single cases and cannot be split at all, which is the point that matters.
- **The "two to three weeks" runway in §7.** A linear extrapolation of a nine-day build-out.
  `unverified`, and it is a rate, not a law.
- **Whether the 20-job limit has ever actually dropped a run here.** The mechanism is
  documented and the six competing workflows are real; I did not catch a drop in the act.
  The absence of a run record for a SHA is exactly what a drop looks like, and nothing
  currently records it — which is the point of the job I ask for in §6.2.
- **Any full pass.** Scoped verification only, as briefed: `--only MT` and `--list`.
