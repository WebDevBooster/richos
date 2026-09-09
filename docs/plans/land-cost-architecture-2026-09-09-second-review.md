# Landing a small change: the architecture, with every number re-derived

**Status: PLAN ONLY. Implementation is barred until the CEO approves a plan.**
Author: Sage (software architect). Worktree `richos-wt/sage-fable-lc1`, written against richos
`7d77e3bd`. Every number below names the command or file it came from, or carries the word
`unverified`. Nothing is quoted from the two documents under review without being re-derived.

Inputs reviewed:

- `richos-hq/docs/plans/land-cost-plan-2026-09-09.md` (commit `7ff4a7ad`, 2026-09-09 20:42)
- `richos/docs/measurements/integrity-suite-cost-2026-09-04/README.md`

## 1. The CEO's question first: has this not already been solved?

**Yes. Completely, and a long time ago.** The problem "a small change must not cost an hour of
waiting on tests" is the central problem of continuous integration, and the industry answer has
been stable for about fifteen years. It has five parts, and every mainstream stack ships all five:

| The wheel | What it does | Where it is standard |
|---|---|---|
| **Test impact analysis** | Before commit, run only the tests that the changed files can affect | Bazel/Buck target graphs, Nx and Turborepo `--affected`, `pytest-testmon`, Google TAP |
| **CI on every push, sharded** | The full suite runs on a fleet of runners, split into parallel shards, nobody waits for it | GitHub Actions `matrix`, CircleCI parallelism, Buildkite; free on public repositories |
| **Per-test timing as a first-class output** | Every runner records how long each test took, so the slow tail is visible without hand-timing | JUnit XML, `pytest --durations`, Jest `--verbose`, Go `-v`, `ctest --output-on-failure` |
| **Expensive analyses on their own schedule** | Mutation testing, fuzzing and long soak tests run nightly or when their subject changes — never inside the per-commit gate | Stryker, PIT, mutmut, cargo-mutants all document "not on every commit" |
| **Post-merge red is surfaced, not prevented by waiting** | Trunk-based teams accept a red main for minutes, and make the red loud; teams that need main never red use a merge queue | Google (post-submit TAP), GitHub merge queue, Bors |

**Where this repository departs from the wheel**, in order of cost:

1. **The full pass runs on the operator's laptop, at land time, with somebody waiting.** The
   engine's own runner header (`engine/scripts/run-all-tests.sh`, 2026-08-30) rules that the
   full pass belongs in CI and says outright that "a red suite can reach `main` and sit there
   until CI runs" is an accepted cost. The wiki's enforcement table
   (`richos-hq/wiki/enforcement-and-failures.md:46`) lists it as "CI-only". Yet
   `RICH-TODOs.md` (standing facts) prescribes "Rich runs the single full pass at land time", and
   the suite's own exit banner tells every developer "Re-run with no arguments before landing
   anything". The record contradicts itself, and practice followed the laptop version because
   CI was never switched on. **Nobody chose the hour; it is what "CI-only" means when CI is
   disabled.**
2. **Mutation testing runs inside the per-commit suite.** Forty `*.mutation.sh` harnesses
   (`find engine -name '*.mutation.sh' | wc -l` = 40) each run a whole behavioral suite once
   per mutant. That is N times the suite by construction, and it is why the case count grew
   1.7x while the wall clock grew 10x. Every mutation-testing tool in the table above says to
   run this class on its own schedule. Here it is 65-70% of the largest suite and it runs on
   every full pass.
3. **The runner is a serial loop with no timing output.** `run-all-tests.sh` lines 276-293:
   `for t in "${SUITES[@]}"; do ... bash "$t" >"$LOG" 2>&1`. No shard option, no per-suite
   duration, no machine-readable result. The one duration anybody has for any suite was taken
   by hand once.
4. **No branch protection, no required check, no merge queue.**
   `gh api repos/WebDevBooster/richos/branches/main/protection` → `required_status_checks: null`;
   `rulesets` → 0. CI red on main is invisible to the land.
5. **A hand-built bash test framework** (`emit_case`, sandboxes, leak canary) instead of a
   standard one. This is a real departure but it is NOT a cost driver — the framework's own
   measurement shows sandbox construction at 0.1% of the run — so it is named and left alone.

Everything in section 4 is the wheel, applied. Nothing in it is invented here.

## 2. Are the two documents trustworthy?

### 2.1 The measurement README (2026-09-04)

**Its numbers reproduce; one of its premises is false, and it is the one that matters most.**

- `run END-START` from `results/before-timing.tsv` = 3353.9 s and from `after-timing.tsv` =
  2977.9 s (recomputed with a five-line Python read of the TSVs). The headline holds.
- The scoped-run contract holds: `contract-integrity.test.sh --only python3` exits **3**
  (run in this worktree; log in the session scratchpad), `--list` shows **24 sections**.
- **False premise, "What is left" item 1:** *"embarrassingly parallel by construction: every
  mutant already gets its own directory."* `guard-worktree-isolation.mutation.sh` — which IS
  case WTI1, the single largest cost center at 630 s / 18.8% of the suite
  (`contract-integrity.test.sh:2870`) — mutates ONE sandbox guard in place, restores it, and
  moves to the next mutant (`GUARD=` at line 86, `BASE_MD5=` at line 103, and the line-727 check
  that "mutants were compounding" if the restore failed). `guard-worktree-removal.mutation.sh`
  is built the same way. `inflight-notify.mutation.sh` (427 s, second largest) does copy the
  suite into a per-mutant directory (line 64). So the population is mixed: **2 confirmed
  in-place, 1 confirmed per-directory, 37 unclassified.** The README's premise was carried
  verbatim into `RICH-TODOs.md` ("independent mutants are, by construction, independent") and
  from there into the plan's item 4. The largest harness cannot be parallelized as it stands.

### 2.2 The plan (2026-09-09)

**Its diagnosis is right and its arithmetic is wrong in four places.**

Right: the hour exists because a working CI pass was never switched on, and the answer is to
move the full pass to where nobody waits. That is the wheel, and it is correct.

Wrong, each re-derived:

| Plan says | Re-derived | Source |
|---|---|---|
| Item 2 is "one green `workflow_dispatch` run, then restore `push`" | Three dispatches, **all red**: `34052820610` (09-06, 136 min), `34230560204` (09-08, 95 min), `34396549904` (09-09, **124 min, 117/121, 4 FAILED**: `contract-integrity`, `terminalize-agent-worktrees`, `legacy-workspace-orphan.acceptance`, `shell-worktree-sparse`) | `gh run list --workflow engine-self-verify.yml`; `gh run view 34396549904 --log` |
| "The same CI job measured on Linux: 65.7 minutes" | 65.7 min was a 10-core arm64 container on the dev machine. On GitHub's runner the three real runs are 95-136 min. The plan itself notes this lower down and leaves the 65.7 in its inputs table | workflow header vs. run list above |
| "Run it faster has a hard floor: 2977.9 ÷ 10 = 298 s" | Wrong unit and wrong model. The parallel floor is the **largest indivisible unit**, not total ÷ cores; on the runner the largest suite is 2336 s and its largest section is one harness (~10 min). And CI does not have 10 cores on one box — it has N boxes | timestamps in the `34396549904` log; `--list` |
| "Item 4 alone: CI pass 65.7 min → ~10 min" | Mutant concurrency touches only the mutation harnesses. `contract-integrity` is 39 of 124 min on the runner; the other 85 min are 119 suites run one after another. Without sharding the runner, item 4 leaves a floor near 85 min | per-suite durations derived from the run log (top 20 sum to 113 of 124 min) |
| "Nothing currently records how long an agent runs"; the ledger "gives one teammate 6.6 days" | **Something does.** Every subagent transcript at `~/.claude/projects/*/*/subagents/agent-*.jsonl` timestamps every message. 1,713 of them exist. And the ledger's `registered → last finished` span maxes at **337.8 min (5.6 h)**; 6.6 days did not reproduce | section 3 |

The plan also records item 1 (the brief gate, femcboost `68bcc89d2`) as DONE. Verified: the
hook exists, is registered once in `.claude/settings.local.json`, and refuses a brief that
orders a full pass. That item stands.

## 3. What is actually measured, today, before any instrument is built

### 3.1 Where the CI run's time goes (GitHub runner, run `34396549904`, 2026-09-09)

Derived from the timestamp on each `[n/121] <suite> PASS` line minus the previous one:

```
contract-integrity.test.sh             2336 s   38.9 min   31%
reconcile-terminal-worktrees.test.sh    940 s   15.7 min
worktree-transactions.test.sh           416 s
row-currency.test.sh                    387 s
ceo-asks.test.sh                        340 s
reap-stale-worktrees.test.sh            339 s
ceo-todos.test.sh                       322 s
...
suites >= 60 s:  18 of 120, carrying 91% of the 123.5 min
suites >= 10 min: 2, carrying 44%
```

Greedy packing of these 120 durations into 4, 6 or 8 shards gives the same answer every time:
**38.9 min**, because one suite is that long. Suite-level sharding is therefore not enough;
`contract-integrity` must be sharded by its own 24 sections, which `--only` already supports.

Also read off this log: `guard-sealed-worktree.test.sh` took 130 s. The workflow header calls
it "roughly half an hour". That line is stale.

### 3.2 How long agents actually run (all 1,713 subagent transcripts on this machine)

```
span, first to last message:  median 8.2 min   p90 53 min   153 agents >= 1 h   16 >= 3 h   4 >= 5 h
active time (gaps > 10 min dropped): median 8.2   p90 47      121 >= 1 h   16 >= 2 h   3 >= 3 h
tool calls paired by id:      115,295
tool calls that invoke a suite or the probe:  2,649 — 46.9 hours of wall time in total
tool calls >= 10 min:         377, of which 97 name a suite; most of the rest are
                              `until ... sleep` loops waiting on a suite run in the background
agents with span >= 1 h:      spend a median 59% of that span inside tool calls
per-Bash-call floor (ls/echo/cat): median 0.08 s, p90 0.19 s
```

Two conclusions and one caveat. (a) The hours are real and they are mostly verification: the
suite-invocation total across the corpus is 46.9 h, and the 10-minute Bash tool ceiling is why
agents sit in polling loops. (b) Hook-chain overhead per call is not where the time goes: with
13 hooks on every Bash call, a trivial command still returns in under a fifth of a second at p90.
Caveat: a 10-minute gap threshold also discards any single tool call longer than 10 minutes,
which is exactly where a full-suite run hides, so "active time" undercounts verification;
the per-call figures are the trustworthy ones.

### 3.3 The ledger, re-read

`~/.claude/state/worktree-ledger.jsonl`: 13,577 rows, 13,106 `finished`, 405 `registered`.
`finished` is written by `worker-ended-handoff.sh` on `SubagentStop`, and its own comment says
so: "SubagentStop fires every turn". It is a turn counter, not a lifetime. Only 19 of 71
registered worktrees have any `finished` row at all. `~/.claude/worker-events.jsonl` has
`WorkerStarted` for 50 agents and `WorkerRunEnded` for 159 — the start event is missing for two
thirds of them, cause `unverified`. Neither is an instrument. The transcripts are.

### 3.4 How often a land happens

`git log --merges --since=2026-09-02 main` on richos: 5, 32, 28, 48, 1, 6, 7 merges per day.
On 2026-09-06 there were 48 lands. A 50-120 minute full pass per land is 40-96 hours in one day,
so **the "full pass at every land" cannot have been what happened on the busy days.** The hour
is paid on the lands where it is run, and nothing records which those were. That is why step 0
below exists.

## 4. The design, ordered, with what each step removes

The end state is the plan's: **landing a one-line change costs seconds of waiting, and nobody
watches a suite.** The order is by what each step removes, given the numbers above.

| # | Step | Removes | Cost to build |
|---|---|---|---|
| 0 | **Instrument** — per-suite duration in `run-all-tests.sh` (printed and as a TSV artifact); switch `CI_TEST_TIMING` on in CI; a `land` stamp (start, end, SHA, which checks ran) written by the lander; an `agent-cost` report derived from the subagent transcripts (span, tool-call time, suite-call time) | Nothing. Makes every later claim checkable. Until this exists "agents no longer take five hours" is a sentence | Hours. The transcript reader is already written (session scratchpad, ~60 lines) |
| 1 | **Brief gate** (DONE, femcboost `68bcc89d2`) | The in-brief full passes: 46.9 h of suite time across the corpus, 97 calls of 10+ minutes | Done |
| 2 | **Make CI green on Linux**: fix or, with a named SKIP that prints what goes unproven, quarantine the 4 red suites | The reason the `push` trigger is still off. A red gate teaches everyone to ignore it | Unknown until the 4 logs are read; `unverified` |
| 3 | **Shard CI and turn on `push`**: a `matrix` job over (a) every `*.test.sh` except `contract-integrity`, greedy-packed by the step-0 durations, and (b) `contract-integrity --only <section>` per section, plus one job that runs `bash -n`, `install.sh`, the probe and the demo. Exit 3 from a scoped shard is the shard's green; the aggregate job requires every shard green. `concurrency:` cancels a superseded run on the same ref | **The full pass leaves every laptop.** CI wall 124 min → the largest section, about 10 min (`unverified` on the runner; 630 s on the Mac and the whole suite ran 0.78x faster on the runner) | A day. The only engine change is a `--shard i/N` or a suite-list argument on the runner |
| 4 | **Local land check scoped by a static map**: `git diff --name-only` → every suite that mentions a changed file's basename (`grep -lF`; every one of the 63 hooks is mentioned by at least one suite, verified) → run those, and `contract-integrity --only` for the matching sections; syntax check on everything. Lands touching only `docs/` run nothing | Land verification → the measured section times: 2 s to 181 s, typically under a minute | Half a day |
| 5 | **Mutation harnesses get their own job**: run when the mutated guard or its suite changed (path filter) and nightly on `schedule:`; never in the pre-merge shard set and never in the local land check unless the guard itself changed | 65-70% of `contract-integrity` and an `unverified` share of the other large suites leave the pre-merge CI wall; pre-merge CI ≈ largest behavioral suite (`reconcile-terminal-worktrees`, 940 s on the runner, itself carrying 30 mutation properties that would move too) | A day. Needs an exclude selector (`--only` has no negation today) or a section tag |
| 6 | **Mutant-level concurrency** (CEO order, 2026-09-08). Prerequisite: give WTI1 and WTR1 per-mutant sandbox copies (32 ms each after the template build), then run mutants with a bounded worker count; characterize the CL1/CL2 flakes first, because naive parallelism turns a rare flake into a common one (the README's own warning) | The nightly and path-triggered job's wall: ~10 min → a few minutes. Under this design **nobody waits on that job**, which is why it is last | Two to three days |
| 7 | **Surface post-merge red** where Rich already looks: a SessionStart and Stop notice reading the latest CI conclusion for `main` (the engine already has fifteen `notice-*.sh` scripts on those events), and a row in RICH-TODOs when it is red | The blindness that makes a red main a discovery instead of a notice | Hours |

Steps 0 through 4 are the whole answer to the CEO's complaint. Steps 5 through 7 shorten the
background loop and make its result visible. **Nothing in this table shrinks coverage**: every
suite and every mutant still runs on every push to `main`; steps 5 and 6 change when and where
the mutation harnesses run, not whether.

### The 2026-09-08 order, stated as the decision it is

The CEO put mutant concurrency at the top of the list on 2026-09-08. Under this design it is
step 6, because it shortens a job nobody waits on once step 3 exists, and because its largest
target (WTI1) needs a restructure first. If the CEO wants it first anyway, nothing else in the
table changes — only the order in which the waiting disappears. That is his call, not mine.

### Pre-merge gate or post-merge notice

This design runs CI on push to `main` and surfaces red rather than blocking the land on a green
check. The alternative — branch protection with a required check and GitHub's merge queue —
gives "main is never red" at the cost of PR ceremony on every land and a ~10 minute latency per
land (batched by the queue). With one lander doing 30-48 lands on a busy day and the engine's
own runner header having already accepted a red main for the length of one CI run, the
post-merge form is the simpler one that meets the requirement. The measurement that would
reverse this: the count of red-main windows per week after step 3, and their length. If that
number hurts, the merge queue is the upgrade and nothing built here is thrown away.

## 5. What must be measured before any of it is trustworthy

1. **Per-suite duration on the runner**, emitted by the runner itself (step 0). Everything in
   3.1 was reverse-engineered from log timestamps once; it must be a first-class output.
2. **Land duration**: start and end stamps per land, with the SHA and the list of checks that
   ran. Until then "an hour per land" is a claim, and section 3.4 shows it cannot be uniformly
   true.
3. **Agent verification share**: from the transcripts — per agent, total tool-call time and
   the subset spent inside suite or probe invocations. The corpus figure is 46.9 h; the figure
   that matters is per task after the brief gate, and it does not exist yet because the gate
   is hours old.
4. **Per-section time on the runner** for `contract-integrity`, to pack the section shards and
   to know the real floor of step 3. Only Mac numbers exist (21-181 s per section, 630 s for
   WTI1).
5. **The mutation-harness census**: for each of the 40, per-mutant directory or in-place. Two
   are known in-place. This decides how much of step 6 is restructure versus parallelism.
6. **CL1/CL2 flake characterization** under load, before any concurrency (the README's own
   precondition, still unmet).
7. **Red-main windows** after step 3, to decide whether the merge queue is needed.

## 6. Why this is the best obtainable, not merely better

Waiting time has exactly three components, and each has a floor set by the requirements
rather than by the machine.

- **Time a person or agent waits before a land.** Floor: the smallest check sufficient for the
  change, which is "the tests that can be affected by what changed". That is step 4, and it is
  measured at seconds to three minutes. Going lower means not running a test the change can
  affect, which is refused.
- **Time until a red main is known.** Floor: the largest indivisible unit of the full pass,
  run in parallel with everything else. With section shards that is one harness (~10 min);
  with step 6 it is one suite run per mutant, in parallel, so a few minutes. Going lower means
  splitting a single suite's cases, which is possible but past the point where anyone is
  waiting.
- **Time a person spends watching either.** Floor: zero, once the full pass runs where nobody
  is sitting. That is step 3.

So the design reaches the floor of every component and stays there as the suite grows, because
the pre-land cost scales with the size of the change rather than the size of the suite, and
the CI cost scales with the largest unit rather than the sum. The suite count went 60 → 77 →
119 → 121 in five days (workflow header, run logs); a serial design loses to that growth every
week, and this one does not notice it. The only non-optimal choice in the design is
pre-merge-gate versus post-merge-notice, which is a tradeoff and is named as one above.

## 7. What I could not verify

- How long a richos land actually takes today. No instrument; the merge counts prove it is not
  an hour every time.
- Why the 4 suites are red on the Linux runner. Scoped verification only, per the brief; the
  logs were not read.
- Per-section times on the GitHub runner. Mac-only numbers exist.
- The census of the 40 mutation harnesses: 2 in-place, 1 per-directory, 37 unclassified.
- Why `WorkerStarted` is recorded for 50 of 159 agents.
- The plan's "6.6 days" ledger span. It did not reproduce; the maximum I can derive is 5.6 h.
- The exact semantics of the transcript timestamps (whether the hook chain runs inside the
  `tool_use` → `tool_result` interval). The 0.08 s floor should be read as "not the cost", not
  as an exact hook-chain time.
- GitHub's free-plan concurrency limit for standard runners (believed to be 20 jobs;
  `unverified`). It bounds shard count, not the design.

## 8. Commands that produced the numbers above

```
gh run list --workflow engine-self-verify.yml --repo WebDevBooster/richos --limit 10 --json databaseId,status,conclusion,createdAt,updatedAt,headSha,event
gh run view 34396549904 --repo WebDevBooster/richos --log          # per-suite durations from line timestamps
gh api repos/WebDevBooster/richos/branches/main/protection ; gh api repos/WebDevBooster/richos/rulesets
find engine -name '*.test.sh' | wc -l        # 121
find engine -name '*.mutation.sh' | wc -l    # 40
bash scripts/hooks/contract-integrity.test.sh --list                 # 24 sections
bash scripts/hooks/contract-integrity.test.sh --only python3 ; echo $?   # 3
grep -lE 'BASE_MD5|^restore\(\)' engine/scripts/**/*.mutation.sh     # 2 in-place harnesses
git log --merges --since=2026-09-02 --format=%ad --date=short main | sort | uniq -c
python3 -c '<read run START/END from results/{before,after}-timing.tsv>'   # 3353.9 s / 2977.9 s
python3 <transcript reader over ~/.claude/projects/*/*/subagents/agent-*.jsonl>   # section 3.2
python3 <ledger reader over ~/.claude/state/worktree-ledger.jsonl>            # section 3.3
```
