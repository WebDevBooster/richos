# Where the hours go, and the permanent fix — architecture, 2026-09-09

**Status: PLAN ONLY. The CEO has barred implementation until he approves a plan.**
Author: Sage (architect). Written from the richos worktree `sage-fable-lc2` at `7d77e3bd`,
against femcboost `fd9f18637`, richos-hq `d11a8fe7`. Every number below carries the command
that produced it (the `tools/` and `results/` directories under
`docs/measurements/agent-runtime-2026-09-09/`), or the word *unverified*.

This document was asked for as a check on two earlier ones:
`richos-hq/docs/plans/land-cost-plan-2026-09-09.md` (the lead's plan, `7ff4a7ad`) and
`docs/measurements/integrity-suite-cost-2026-09-04/README.md`. The verdict on each is in §1.

---

## 0. The answer to the CEO's question first

**Has this not already been solved by millions of developers?** Yes. Completely. The wheel
has a name and a date, and every piece of it is standard practice in any engineering
organization that ships daily:

| The wheel | What it is | Where it is used |
|---|---|---|
| **"Not Rocket Science" rule** (bors, 2014; GitHub merge queue today) | *Automatically maintain a repository of code that always passes all the tests* — the full suite runs on the merge result, on a machine nobody is sitting at, and a human never waits for it | Rust, Servo, every merge-queue user |
| **CI sharding** (matrix jobs) | Split one long suite across N machines so wall clock is the longest shard, not the sum | universal |
| **Test tiers** (the pyramid) | Seconds locally, minutes on every push, hours nightly. **Mutation testing is a nightly or sharded tier everywhere it is used** — PIT, Stryker, mutmut and cargo-mutants all ship `--shard`/incremental modes for exactly this reason. It is never on the commit path | universal |
| **Test selection by change** (Bazel/TAP affected targets, `nx affected`, `cargo-mutants --in-diff`) | Run locally only what the changed paths can affect; the full pass still runs in CI | Google, Meta, every monorepo |
| **Tree closure / sheriff** | When main is red, only a fix or a revert may land; everyone else waits for green, not for the suite | Chromium, Mozilla |
| **Per-test timing** | Every runner records how long every suite took; nobody parallelizes what they cannot see | every CI system |
| **Flake quarantine** | A known-flaky test is reported, not required, with a dated expiry | Google, Dropbox, Spotify |

**Where this repository departs from the wheel — measured, not inferred:**

1. **The full pass runs on people's clocks.** CI exists (`engine-self-verify.yml`) and is
   `workflow_dispatch`-only; the last three dispatches took **2h16m, 1h35m, 2h04m** on
   `ubuntu-latest` and all three failed (`gh run list`, runs 34052820610 / 34230560204 /
   34396549904). So the full pass is run by hand, on the operator's Mac, or by agents inside
   their own task — which is the anti-pattern the wheel was invented to end.
2. **Mutation testing sits inside the correctness tier.** 40 `*.mutation.sh` harnesses declare
   roughly 540 `mutant` lines (plus four with their own loops); each mutant runs a whole suite;
   all of it runs serially on every full pass. The measurement README already showed this is
   65% of `contract-integrity.test.sh`.
3. **Agents wait synchronously for suites.** The dominant Bash call in every long-running
   agent transcript is `until … sleep`/`pgrep` polling a suite it was told to run, capped at the
   10-minute Bash timeout and re-issued. The CI is running inside the agent.
4. **No per-suite timing, and no agent-runtime report.** `run-all-tests.sh` prints PASS/FAIL
   only. The raw agent data does exist (§2), but nothing reads it.
5. **The engine's own doctrine is being violated by its own verification.** `run-all-tests.sh`'s
   header says *"a check that runs when somebody remembers is a rule enforced by attention."*
   The full pass is exactly that check.

---

## 1. Premises re-derived — three of the plan's load-bearing numbers are wrong

| Claim in the brief or plan | What the record shows | Command |
|---|---|---|
| *"Landing a one-line change costs about an hour"* | **The mechanical land is 0.8 min median, 3.0 min p75** (174 merge→push pairs in Rich's own transcripts, 8 days). Only **10 of 174** lands had a full-suite call between merge and push. The hour is not the land; it is the *verification around it* (§2) | `docs/measurements/agent-runtime-2026-09-09/tools/land-cost.py` → `docs/measurements/agent-runtime-2026-09-09/results/land-cost.txt` |
| *"full pass 2977.9 s (49.6 min)"*, used for the 298 s floor and the "65.7 → ~10 min" row | **Stale.** `richos-hq/RICH-TODOs.md:257` records that `contract-integrity.test.sh` now costs 50–70 min and the full suite about two hours, because case `50c` had been aborting the suite under `set -e` since `28f07ab5` and everything after it never ran. CI corroborates: 1.5–2.3 h on a 4-vCPU runner. Nobody has timed the full suite on the Mac since | `sed -n 255,262p richos-hq/RICH-TODOs.md`; `gh run list --workflow=engine-self-verify.yml` |
| *"Ten suites are red on Linux"* | **Four** at HEAD `1bd9f688` (run 34396549904): `contract-integrity` (case 33, `expected exit=0 got=2`), `terminalize-agent-worktrees` (11 R-cases), `legacy-workspace-orphan.acceptance` (errors=3), `shell-worktree-sparse` (S01/S01c). Ten was the previous day's run at `28f07ab5`. A red list here perishes in a day, which the workflow file itself already says | `gh run view 34396549904 --log-failed \| grep FAIL` |
| *"the worktree ledger cannot answer how long an agent runs"* | **True of the ledger** (13,099 of 13,570 rows are `finished`, emitted on every `SubagentStop`, so my own worktree shows a 1-minute "span" while I am writing this). **False of the record as a whole:** every subagent transcript carries a timestamp on every message. See §2 | `docs/measurements/agent-runtime-2026-09-09/tools/agent-active-time.py` |
| *"Item 1 (brief gate) DONE"* | Landed in **femcboost only** (`68bcc89d2`, fixed `34d23cf6d`); registered in `femcboost/.claude/settings.local.json`; richos has no `.claude/settings.local.json` hooks, so a richos-session brief is not gated. It fired twice on its first day, one true positive and one false positive, and is named by no test (richos-hq `wiki/open-items.md` row 3.35). A prose-matching blocking gate is the g11/g12/g13 class | `python3 -c 'import json;…' .claude/settings.local.json` in each repository |
| *"Run it faster has a hard floor: 2977.9 ÷ 10 = 298 s"* | The arithmetic assumes the suite runs on the operator's ten cores. Sharded across CI machines the floor on **any human clock is zero**, and the CI wall clock is bounded by the longest single shard, not by total work ÷ 10 | §4 |

**Is either earlier document trustworthy?**

- The **measurement README** (`integrity-suite-cost-2026-09-04`) is trustworthy *for what it
  measured*: where the time inside `contract-integrity.test.sh` went at `e1ef0df`. Its
  headline number is now stale for the reason above, and it says so about itself in advance
  ("a red list is perishable"). Its structural conclusion — the cost is mutants, not
  sandboxes — stands and is the basis of §4.
- The **lead's plan** is right about the three levers and right that CI must carry the full
  pass. It is wrong about the size of the problem (49.6 min), wrong about the location of the
  hour (the land), and its item 4 — local mutant concurrency — buys a 5–12 minute floor on the
  operator's laptop for something CI can do on nobody's clock. Its "DONE" item is a stopgap in
  one of two repositories. It should be replaced by this document, not amended.

---

## 2. Where the time actually goes — measured for the first time

**The instrument already exists and nobody had read it.** Every subagent transcript at
`~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl` carries an ISO timestamp
per message, and `tool_use`/`tool_result` pairs give the wait on every command. Eight days,
260 agents (`docs/measurements/agent-runtime-2026-09-09/results/agent-active-time.txt`):

```
agents 260   span 237.7 h   ACTIVE 195.1 h   idle (gaps > 15 min) 42.6 h
bash-wait 120.5 h   of which suite/poll-wait 84.8 h   => 43 % of ALL active agent time
active minutes: median 22   p75 67   p90 116   max 368
active >= 3 h: 13 agents   1-3 h: 58   < 1 h: 189
agents active >= 1 h: 71, active 146.3 h, suite-wait 79.7 h  => 54 %
```

**The instrument reproduces the hand-timed record exactly**, which is the proof it is
reading the right thing: `zach-opus-ob1` = **338 min active** (RICH-TODOs: "5 h 37 m"),
`zach-opus-cg1` = **181 min**, `zach-opus-rg1` = **178 min** (RICH-TODOs: "181 and 178").
For all three, suite-wait is 154–312 of those minutes. Their *span* was 890–1028 minutes; the
difference is idle time waiting on the lead, which is why span is the wrong number to quote.

So the CEO's "3, 4 or 5 hours for a simple task" decomposes as:

| Component | Measured | Source |
|---|---|---|
| Suites the agent was told to run, waited for by polling | **43 % of all active agent time**; 54 % for agents over an hour | `docs/measurements/agent-runtime-2026-09-09/results/agent-active-time.txt` |
| The mechanical land (merge → push) | 0.8 min median, 3.0 min p75 | `docs/measurements/agent-runtime-2026-09-09/results/land-cost.txt` |
| Rich's own full passes | 27 strict invocations in 8 days, nearly all backgrounded and polled | `docs/measurements/agent-runtime-2026-09-09/results/rich-full-passes.txt` |
| Engine PreToolUse[Bash] hooks, 12 per call | **0.76 s per Bash call** (≈ 4 min for a 300-call agent) — real, not the problem | `docs/measurements/agent-runtime-2026-09-09/results/hook-latency.txt` |
| Guard refusals ("too complex to verify") | 843 in 8 days across 184 agents, **median 4 s** to recover, 2.4 h total — a nuisance, not the cost | `docs/measurements/agent-runtime-2026-09-09/results/agent-active-time.txt` |

**What is not in any of those rows:** model thinking time and ordinary command latency,
which is the remainder (~50 % of active time). That is the work. The 43 % is the tax.

---

## 3. What the end state is

**The full pass never runs on a clock a person or an agent is watching. A land waits for
nothing but its own scoped checks, in seconds. Red on main closes the tree until fixed.**

That is the wheel, stated for this repository. Three constraints of the repository's own,
each earned by an incident, are preserved unchanged:

- coverage does not shrink — every case, every mutant, every full pass, still runs on every
  commit to main (in CI);
- a scoped or sharded run **can never say 0** — exit 3 stays the only green a partial run can
  emit (verified today: `--only python3` → `rc=3`, 1 s, `docs/measurements/agent-runtime-2026-09-09/results/scoped-only-python3.log`);
- no mutant ever touches a shipped file — the `mutation-harness.sh` sandbox stays the
  mechanism.

---

## 4. The design, ordered — what each step removes

### Step 0 — Instrument (prerequisite; hours of work; no risk)

| Change | Removes |
|---|---|
| `run-all-tests.sh` prints wall-clock per suite and a slowest-10 tail; writes `suite\tseconds\trc` TSV when `CI_TEST_TIMING` is set (the same mechanism `contract-integrity.test.sh` already has) | The blindness RICH-TODOs item 1 names: "nobody can parallelize what nobody can see" |
| A new engine script (proposed name: agent-runtime, beside run-all-tests) — the measurement script `docs/measurements/agent-runtime-2026-09-09/tools/agent-active-time.py` productized: per-agent active/idle/suite-wait, daily roll-up, joined to teammate names through `worker-events.jsonl` (`agent_id` + `agent_transcript_path` are already there) | The claim "agents no longer take five hours" becomes checkable by anyone in one command |
| `land-cost` mode of the same script (merge→push from Rich's transcripts) | The next "50 minutes per land" answer gets measured before it is spoken |

Nothing in Steps 1–3 is trustworthy until Step 0 has produced one week of numbers on Linux
CI and one baseline on the Mac. **The baseline as of today is the table in §2.**

### Step 1 — CI carries the full pass, sharded, green, automatic

| # | Change | Removes |
|---|---|---|
| 1a | `run-all-tests.sh --shard k/N`: deterministic partition of the discovered suite list by index. A shard with zero suites exits 2. `ci-verify.sh` gains a **coverage job** that runs `--list` and asserts the union of shard manifests equals discovery, so a shard cannot be silently dropped (the "18/18 suites" defect, refused by construction) | CI wall clock from ~2 h to the longest shard |
| 1b | `contract-integrity.test.sh` sharded **by section** using the existing `--only`: sections are self-contained by design ("its section builds the fixtures it needs"). Each section job accepts exit 3 and the coverage job asserts every section id from `--list` was named by some shard | Its 50–70 min from the critical path |
| 1c | `mutation-harness.sh mutant()` honors `MUT_SHARD=k/n` (a counter; mutants outside the shard are skipped and *named*). `mutation_end` refuses exit 0 when sharded — exit 3, same contract as `--only` — and the coverage job asserts every mutant name ran somewhere. The four harnesses with their own loops (`guard-worktree-isolation`, `guard-worktree-removal`, `root-contract`, `session-evidence`) get the same counter | The CEO's 2026-09-08 order — mutants run concurrently — delivered **across machines**, which is why the CL1/CL2 load-flake objection to local concurrency does not apply: each shard is the unchanged serial loop over a subset, on its own VM |
| 1d | The four Linux-red suites: fix if portability (three of the four read as `du`/path/git-version differences, *unverified*), otherwise **quarantine** — a separate non-required job with a dated expiry written into the workflow, reported on every run | A red main that means nothing |
| 1e | Restore `push:` and `pull_request:`; add `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }` | The full pass from every human and agent clock — permanently |

Capacity, from GitHub's own limits pages (fetched 2026-09-09): standard runners are free and
unlimited on public repositories (richos is public: `gh api repos/… --jq .visibility` → `public`);
Free plan concurrency is 20 jobs (5 for macOS); `ubuntu-latest` is 4 vCPU / 16 GB x64;
`macos-latest` is 3 vCPU / 7 GB arm64. A 15–18 job matrix fits. **Estimated CI wall clock
after 1a–1c: about 10 minutes** — *unverified*, derived from the Linux container numbers
(contract-integrity 18.2 min unsharded; `guard-sealed-worktree.test.sh` "roughly half an hour",
18 mutants) and the 1.4–2.0x runner-vs-container slowdown visible in the three real runs.
Step 0's per-suite TSV is what turns that estimate into a shard plan.

### Step 2 — The land becomes seconds

| # | Change | Removes |
|---|---|---|
| 2a | A new engine script (proposed name: affected-suites, taking `<base>..<head>`) prints the suites a change can affect: `X.sh` → `X.test.sh`; a changed guard → its `contract-integrity --only <section>`; anything under `scripts/lib/`, `hooks/hooks.json`, `orchestration.config`, `run-all-tests.sh` → **nothing locally**, CI decides (a conservative rule, not a dependency graph — the repository has no import graph to read). Docs-only → nothing. The lander runs its output and nothing else | The last local full pass. A typical land: 0.8 min mechanical + 0–3 min scoped |
| 2b | **Tree-closure guard**, PreToolUse[Bash] on `git push … main` in richos: one `gh run list --branch main --limit 1 --json conclusion,status` (~1 s). Latest *completed* run red → refuse unless the commit subject carries `ci-fix:` or `revert`. In-flight → allowed (the Chromium model: lands continue while CI runs; a red result bisects to a handful of commits). Plus a `Stop`-time notice (proposed name: notice-ci-red) when main's latest run is red | "Rich remembers to run the full pass" replaced by a mechanical read of CI, in the engine's existing guard shape (two-sided canary, auditable opt-out, logged) |
| 2c | Retire the standing fact "Rich runs the single full pass at land time" (`RICH-TODOs.md:263`, `:418`) and re-point the brief gate's message from "Rich runs that at land time" to "CI runs that on every push" | The instruction that put the hour on Rich's clock |

### Step 3 — The agent's clock

| # | Change | Removes |
|---|---|---|
| 3a | Move `guard-brief-verification-scope.sh` into the engine so it fires in every governed session, and give it the test row 3.35 says it lacks (two-sided: refuses a full-pass brief, silent on a scoped one, silent on a prohibition sentence) | The 43 %: a brief can no longer put a two-hour pass on an agent's clock in either repository |
| 3b | The affected-suites script is what a brief tells the teammate to run — the same script the lander runs, so engineer and lander agree by construction on "what this change can affect" | Re-derived baselines, and the argument about scope |
| 3c | Doctrine line in the femcboost worktree skill (private record, skills directory, using-git-worktrees): an agent never polls a suite longer than its own section; a full pass belongs to CI | The `until … sleep` loops that are the signature of every 3-hour transcript |

### Step 4 — Deliberately NOT in the plan

- **Local mutant concurrency on the Mac** (the literal reading of the 2026-09-08 order). After
  Steps 1–3 nobody needs a local full pass, so a faster local full pass has no consumer. It
  would carry the documented load-flake risk and a floor of 5–12 minutes on the operator's own
  machine. If the CEO wants it anyway, it is a later, optional item, not the fix.
- **A PR-based merge queue.** GitHub's merge queue is the purest form of the wheel, but it
  requires PR-only landing and branch protection, which conflicts with the single-writer,
  local-merge, IDE-visibility model this repository runs on. Tree closure (2b) gives the same
  guarantee at the cost of a bounded red window instead of a workflow change.
- **Shrinking coverage.** Not one case, mutant or section is dropped from the CI pass.

---

## 5. Why this is the best obtainable, not merely better

There are exactly three levers — run less, run faster, run elsewhere — and the plan was right
about that. What makes this design the ceiling rather than an improvement:

1. **On the operator's clock, the remaining cost is the mechanical land, already 0.8 min
   median.** Below that there is nothing to remove but `git` itself. "Seconds" is met by
   construction, not by optimization.
2. **On the agent's clock, the tax goes to zero, not to a smaller number.** A scoped run is
   1–181 s (measured), and CI owns everything else. Any design that leaves a full pass on an
   agent's clock — however parallel — leaves a floor; this one leaves none.
3. **Sharding across machines dominates local concurrency on every axis that matters here:**
   no CPU contention (the recorded flake class), no correctness argument (each shard is the
   unchanged serial loop over a subset), scales to 20 jobs for free, and touches nothing on the
   operator's machine.
4. **Coverage is unchanged and its integrity is proven by a coverage job, not by trust** —
   the union of shards must equal discovery, or CI is red. That is the same belt-and-braces
   this suite already demands of `--only`.
5. **The failure mode of the new arrangement is bounded and named:** a red suite can reach
   main and sit there for one CI cycle (~10 min after Step 1). Tree closure stops the next land
   on top of it. The failure mode of the *current* arrangement is unbounded and measured:
   84.8 hours of agent time in eight days.

What would beat it: nothing on the operator's or agent's clock. A faster CI cycle is possible
(more shards, up to the 20-job limit) and changes only how quickly a red is known.

---

## 6. What must be measured before any of it is trustworthy

| # | Measurement | Why it gates the design | Exists today? |
|---|---|---|---|
| M1 | Per-suite wall clock on `ubuntu-latest`, all 121 suites | Sizes the shards; names the critical-path suite; turns "~10 min" from an estimate into a number | **No** — nothing records it |
| M2 | Agent active-time roll-up, daily, for one week after Step 3 | Acceptance: suite-wait share < 5 % of active time; p90 active < 60 min | Raw data yes; script under `docs/measurements/agent-runtime-2026-09-09/tools/` |
| M3 | Land cost (merge → push) and full-suite-calls-between-merge-and-push | Acceptance: 0 of N lands carry a full-suite call; scoped-suite time p90 < 3 min | Raw data yes; script under `docs/measurements/agent-runtime-2026-09-09/tools/` |
| M4 | CI stability: ≥ 10 consecutive runs on main with the same conclusion before `push:` is restored | The red list changed 10 → 4 in one day; a trigger promised on one green run is the workflow file's own recorded mistake | **No** |
| M5 | Tree-closure guard refusal and opt-out counts | A guard waived habitually is a guard that dies (g11/g12/g13) | Log by construction |
| M6 | One full pass on the Mac, timed, at HEAD | Confirms the "about two hours" standing fact, which is currently a claim corroborated only by Linux CI | **No** |

---

## 7. What I could not verify

- **Whether the four Linux-red suites are portability defects or real ones.** I read the case
  names and the assertions, not the causes.
- **Per-suite durations.** They do not exist anywhere for the 121 suites; every CI estimate
  in §4 is marked *unverified* for that reason.
- **The "about two hours" full-suite number on the Mac.** RICH-TODOs claim; CI corroborates on
  a slower machine; not timed since case 50c was fixed.
- **Section independence of `contract-integrity.test.sh` on separate machines.** Documented
  as designed-in ("its section builds the fixtures it needs"); not exercised by a run.
- **The mutant count.** ~540 `mutant` lines by grep plus four own-loop harnesses; not a
  manifest.
- **Agent names for most of the 260 transcripts.** The ledger joins names for only a
  fraction; the product script must join through `worker-events.jsonl`. The three named
  agents that matter for the CEO's complaint are matched exactly.
- **I did not run any suite** beyond `--only python3` (1 s, exit 3) and `--list`. Scoped
  verification only, as briefed.

---

## 8. Decisions that are the CEO's

1. **Where the mutant concurrency runs.** His 2026-09-08 order was concurrency "at the top of
   the list." This plan delivers it across CI machines (Step 1c) and deliberately does not
   build it locally (Step 4). Same order, different place; if he wants the local form as well,
   it is a later item with a known floor.
2. **How the Linux-red suites are handled** before the push trigger returns: fix (unknown
   effort, *unverified* cause) or quarantine with a dated expiry (known effort, honest red
   reporting, coverage on macOS unchanged). The plan recommends fix-if-portability, quarantine
   otherwise, and either way the trigger waits on M4.

Nothing else in this document needs his word; the rest is engineering that follows from the
end state he already set.

---

## Method

All scripts and their captured output are in `docs/measurements/agent-runtime-2026-09-09/`:

- `docs/measurements/agent-runtime-2026-09-09/tools/agent-active-time.py` — reads every subagent transcript modified in the last 8 days;
  span, active (gaps ≤ 15 min), idle, Bash wait, suite/poll wait (regex on the command), guard
  refusals and their recovery time. Output: `docs/measurements/agent-runtime-2026-09-09/results/agent-active-time.txt`.
- `docs/measurements/agent-runtime-2026-09-09/tools/land-cost.py` — Rich's main-session transcripts; every `git merge` paired with the
  next `git push … main` in the same session; whether a full-suite call sits between. Output:
  `docs/measurements/agent-runtime-2026-09-09/results/land-cost.txt`.
- `docs/measurements/agent-runtime-2026-09-09/tools/rich-full-passes.py` — strict match of `run-all-tests.sh` / `ci-verify.sh` /
  `contract-integrity.test.sh` without `--only`, heredocs excluded, with tool wait. Output:
  `docs/measurements/agent-runtime-2026-09-09/results/rich-full-passes.txt`.
- `docs/measurements/agent-runtime-2026-09-09/tools/hook-latency.sh` — each engine PreToolUse[Bash] hook timed on a plain `ls -la`
  payload from this worktree. Output: `docs/measurements/agent-runtime-2026-09-09/results/hook-latency.txt`.
- `docs/measurements/agent-runtime-2026-09-09/results/scoped-only-python3.log` — the one scoped run, exit 3 in 1 s.

Caveats stated rather than hidden: "suite-wait" is a regex over command text and will count a
polling loop that waits on something other than a suite (Docker log tails were included on
purpose; they were waiting on a suite inside a container). Active time treats any gap over
15 minutes as idle, which under-counts a single command that legitimately ran longer than
that; the Bash tool's 10-minute cap makes such gaps rare. Neither caveat moves the 43 % by
more than a few points in either direction.
