# Mutant concurrency — what it cost, what it bought, and what it did not

Author: Zach (infrastructure). Worktree `richos-wt/zach-opus-mu2`, branch
`zach-opus-mu2`, measured 2026-09-10 on the operator's machine (10 cores,
24 GB, darwin 24.6.0, `/bin/bash` 3.2.57).

Every number below names the command that produced it, and the tools are in
`tools/` so they can be re-run. Where a measurement was taken under contention
it says so, because this machine ran several agents at once all night and a
number taken at load average 31 is not the same number.

---

## 0. What the change is

Mutation harnesses ran their mutants one at a time. They now run them
concurrently, bounded, with the report still printed in declaration order.

The binding constraint is **not total wall clock — it is the 600 s per-check
tool ceiling.** A section that cannot finish inside the cap does not merely take
longer; it converts into a background run plus a poll loop plus a model turn per
re-issue. Section sharding cannot split these: the six mutation sections of
`contract-integrity.test.sh` are each a SINGLE case, so concurrency inside the
harness is the only thing that lowers the largest indivisible unit.

---

## 1. The corpus, re-derived — three of the brief's numbers were wrong

```
find engine -name '*.mutation.sh' | wc -l                    ->  40
grep -c '^mutant ' over all of them                          -> 526
  of which sourced scripts/lib/mutation-harness.sh (23 files) -> 244
  of which carried their own inline mutant loop (17 files)    -> 282
bash scripts/hooks/contract-integrity.test.sh --list          ->  24 sections
```

The brief said **4 own-loop harnesses and 427 mutants**. Both are wrong for this
branch, and the correction mattered to the plan rather than being pedantry:

- **17 harnesses carry their own mutant loop, not 4.** Fifteen define an inline
  `mutant()`; two (`root-contract`, `session-evidence`) have no `mutant` function
  at all and were left alone.
- **526 mutant declarations, not 427.**
- **The split is the load-bearing part.** Of the eight `contract-integrity`
  sections that dominate the suite, exactly ONE (`MC6`) is library-based. `IL`,
  `CL`, `RI`, `MF` and `SA` are all own-loop, and `WTI`/`WTR` are a third shape
  again. So changing the shared library — the obvious first move, and the one
  that looks like it covers everything — reaches 244 of 526 mutants and one of
  the eight expensive sections.

The brief's third premise was right and worth restating: `WTI1` did **not** give
each mutant its own sandbox. It built ONE and restored the guard between mutants,
which is safe while nothing overlaps and unsafe the instant two mutants run at
once. Per-mutant sandboxes there are a precondition of the concurrency, not a
tidy-up beside it.

---

## 2. Per-section, before and after — the acceptance measurement

`tools/sections.sh`. BEFORE is a pristine clone at `437f0134` (the timing commit,
no concurrency); AFTER is the worktree. Each pair runs back to back so a change
in machine load moves both members together. Every AFTER run was checked for
exit code 3, for the same named cases as its BEFORE, and against the 300 s bar.

```
SECTION        BEFORE        AFTER  SPEEDUP  VERDICT
-------        ------        -----  -------  -------
WTI          16m14.5s      4m05.6s     3.9x  ok rc=3 1 cases
RI            8m41.3s      3m02.4s     2.8x  ok rc=3 3 cases
IL            3m44.2s      1m44.9s     2.1x  ok rc=3 11 cases
MF            3m02.8s        55.7s     3.2x  ok rc=3 1 cases
CL            2m50.1s        50.2s     3.3x  ok rc=3 2 cases
SA            2m50.2s        46.1s     3.6x  ok rc=3 2 cases
MC6           2m23.4s        40.5s     3.5x  ok rc=3 1 cases
WTR           1m58.4s        39.5s     2.9x  ok rc=3 1 cases
```

`ok` means all four checks passed: same exit status, same named cases, exit 3
rather than 0, and under 300 s. **The largest scoped unit is now 245.6 s.**

**`WTI` is the result the whole change is for.** At **974.5 s** it did not merely
approach the 600 s per-check tool ceiling — it was **62% past it**, so no agent
could ever run that section in one call. It is now **245.6 s**, which fits in one
call with room. A single mutation case cannot be sharded by section, so nothing
else on anybody's list could have moved it.

**`RI`** at 521 s sat inside the ceiling only by margin on a quiet machine, and
the record contains a real `--only IL,SA` call that hit the 601 s cap. It is now
182 s.

**`--only IL,SA`, the call in the record that hit the cap:** 224.2 + 170.2 =
394 s of section time before, 104.9 + 46.1 = 151 s after.

Summed across the eight sections: **2745 s → 745 s**, and every one of them now
fits inside a single 600 s call, which none of `WTI` did before.

### The measurement that was thrown away, and why

The first `WTI` pair reported BEFORE 51.9 s / rc=1 and AFTER 4m06.9s — an
apparent 0.2x regression. It was not one, and the re-measured row above (974.5 s
before) is 19x the discarded figure. The before-side harness was **SIGKILLed**:

```
contract-integrity.test.sh: line 2873: 9325 Killed: 9  guard-worktree-isolation.mutation.sh
  FAIL  WTI1.staffing-gate-mutations-all-load-bearing  (expected exit=0 got=137)
```

Exit 137 is 128+9. Nothing in this branch kills that process; this machine was
running several agents concurrently all night. Run directly from the same
pristine clone the same harness completes **23 proven, 0 unproven, rc=0**. The
row was re-measured rather than reported.

---

## 3. Per-harness, original versus converted

`tools/ab-original-vs-converted.sh`. This is the comparison that matters: the
ORIGINAL harness against the CONVERTED one at degree 8. Running the converted
file at degree 1 would only ever test the scheduler.

| harness | mutants | verdicts | exit codes | speedup |
|---|---|---|---|---|
| `guard-worktree-isolation` | 21 | identical | 0 = 0 | 5.1x |
| `guard-worktree-removal` | 12 | identical | 0 = 0 | 4.6x |
| `interactive-prompt` | 13 | identical | 0 = 0 | 6.6x |
| `claim-roles` | 20 | identical | 0 = 0 | 6.8x |
| `idle-land` | 18 | identical | 0 = 0 | — |
| `waiver-repetition` | 18 | identical | 0 = 0 | 6.6x |
| `ceo-asks` | 13 | identical | 0 = 0 | — |
| `ceo-todos` | 12 | identical | 0 = 0 | — |
| `ceo-ruled` | 6 | identical | 0 = 0 | 5.8x |
| `turn-manifest` | 7 | identical | 0 = 0 | 6.5x |
| `guard-resume-isolation` | 9 | identical | 0 = 0 | 5.7x |
| `guard-unresolved-claims` | 4 | identical | 0 = 0 | 3.9x |

Speedups here were taken while the machine was at load average up to 31 and are
therefore floors, not ceilings.

The only lines that differ anywhere are the appended `[duration]`, the pool's own
one-line summary, and one informational sentence in the two worktree harnesses
that was reworded on purpose from *"sandbox guard restored byte-for-byte"* to
*"reference sandbox guard never written to"*.

### The A/B instrument was itself a defect, once

The first version wrote the original harness back into `scripts/hooks/` under a
temporary name so its `$SCRIPT_DIR/../..` would resolve. That injected a file
into the engine under test and **`waiver-repetition` noticed** — its control
sandbox went red at *"17. an unadopted repository gets no notice at all"*, the
harness aborted with *"the CONTROL sandbox is already red"*, and the A/B duly
reported the ORIGINAL failing and the CONVERTED passing. Run from a pristine
clone the original is green with 18 kills, matching the converted run exactly.
The conversion was innocent; the instrument was the defect. The tool now runs the
original side from a clone and modifies neither engine.

---

## 4. The degree, chosen from the measurement rather than from the core count

`tools/degree-sweep.sh`, `guard-model-ceiling.mutation.sh` (17 mutants), 10 cores:

```
JOBS             WALL    SPEEDUP         RC
1             2m23.1s       1.0x          0
2             1m12.3s       1.9x          0
4               46.3s       3.0x          0
6               38.5s       3.7x          0
8               41.4s       3.4x          0
10              35.8s       3.9x          0
12              37.2s       3.8x          0
```

**The knee is at 4–6 and everything past 6 is inside the noise** — 8 measuring
slower than 6, and 12 slower than 10, are variance rather than signal. A mutant
is a whole shell suite: process spawning, git, python3, and a recursive copy of
the mechanical layer. It neither saturates one core nor scales with them, so the
ceiling is reached well below the core count.

The default is therefore the core count **capped at 8**: one step past the knee,
so that a harness whose mutants are not uniform in cost (WTI's are not) still has
somewhere to put a long one, and no further. The cap is what stops a 64-core CI
runner starting 64 sandbox builds at once and going IO-bound — and that is not
hypothetical on Linux, where the run log states in plain text that
`clonefile` copy-on-write is unavailable under `/tmp`, so on the runner **every**
sandbox is a full recursive copy rather than a CoW clone.

`RICHOS_MUTANT_JOBS` overrides it. Junk in that variable is refused loudly rather
than becoming 0, because a degree of 0 blocks the throttle for ever.

---

## 5. Constraint 3, proven against a real `kill -9` mid-run

`tools/kill9-proof.sh`. The claim: no mutant mutates a shipped file in place, so
a run killed at the worst moment leaves the operator's live enforcement
byte-identical **and never opened for writing**.

The witness is contents AND mtime, because *"restored correctly"* and *"never
touched"* are different guarantees and only the second survives a kill — a
restore is a promise conditional on reaching the restore.

```
=== kill -9 proof: guard-worktree-isolation.mutation.sh at degree 8, killed after 150s ===
witness = contents AND mtime (sub-second mtime proved)
before: 403 shipped files witnessed; shipped guard sha=eb83220bd071
at the instant of the kill: 8 worker sandbox(es) present, 8 holding a MUTATED guard
killing pgid 88583 with SIGKILL
after the kill: 8 orphaned sandbox(es) under TMPDIR — the only casualty
RESULT: PROVEN — 8 live mutation(s) were in flight, the whole process group
        was SIGKILLed, and every one of the 403 shipped engine files is
        byte-identical AND its mtime is unchanged.
```

`guard-worktree-removal`, killed at 20 s, is the same result: **8 in flight,
8 mutated, 403 files unchanged** (`results/kill9-proof-WTR.txt`).

**The kill has to land while a mutation is live, or the proof is that nothing
happens when nothing is running.** The tool reports the in-flight count and
**exits 2 with `INCONCLUSIVE`** rather than claiming a proof it did not make —
which it did three times before it produced either result above:

- killed at 40 s, `0 sandboxes present`: still inside M0's baseline suite run;
- killed at 75 s on WTR, `0 present`: that harness had already FINISHED, because
  concurrency had cut it to ~40 s;
- killed at 60 s on WTR, `8 present, 0 mutated`: **all eight were orphans of the
  previous WTI proof**. A killed run leaves its sandboxes behind by design, and
  each one is a whole engine copy containing every guard, so the later proof
  counted the earlier run's residue and correctly refused. The tool now purges
  stale sandboxes before it starts and says how many it purged.

That third one is the interesting one: a proof tool that had simply asserted
"nothing changed" would have passed all three of those runs while establishing
nothing at all.

The SIGKILL goes to the whole process group. A kill to the parent alone would let
the workers finish tidily, which is the opposite of the scenario.

---

## 6. What this does NOT establish

- **No full-pass before/after.** A `run-all-tests.sh` baseline was started and
  abandoned: it was competing with several other agents' suites, and a contended
  BEFORE would have overstated the improvement. The per-section pairs are the
  on-criterion measurement and they are what is claimed here.
- **The partial baseline it did produce is contended and is not quoted as a
  clean figure.** It did contain one genuinely new fact worth keeping —
  `ceo-todos.test.sh` at 451.3 s is larger than `by-reference.test.sh` at
  253.3 s, and no plan or header has ever named it. `contract-integrity` was
  terminated by a cleanup during that run, so its 2285 s reading is a killed run
  and is **not** a completed measurement of anything.
- **Nothing on Linux.** Every number here is macOS. The `clonefile` point in §4
  is quoted from an existing run log, not re-measured.
- **`root-contract` and `session-evidence`** declare no `mutant` calls and were
  not converted.
- **The two harnesses main changed under me** —
  `shell-worktree-sparse.mutation.sh` (11 mutants) and
  `terminalize-agent-worktrees.mutation.sh` (13) — were verified against the
  PRE-merge versions of their suites. They are the pair worth re-running once
  merged.

---

## 7. Commands

```
tools/sections.sh [SECTION...]                # per-section BEFORE/AFTER pairs
tools/ab-original-vs-converted.sh <rel> [jobs] # original vs converted, no pollution
tools/degree-sweep.sh [harness]               # wall clock at degrees 1..12
tools/kill9-proof.sh <harness> <guard> <s> <n> # constraint 3
tools/order-check.sh                          # init before first submit, drain after last
```
