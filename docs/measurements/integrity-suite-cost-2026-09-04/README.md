# Where the integrity suite's time actually goes — measured 2026-09-03/04

`scripts/hooks/contract-integrity.test.sh` is the engine's largest suite. Two
places in the record stated where its time goes. **Both were wrong, and neither
had been measured.**

> **`RICH-TODOs.md` row v1:** *"the cost is SETUP repeated 81 times, not the
> checks."*

> **`scripts/run-all-tests.sh` header:** *"their cost is sandbox construction,
> which is cacheable."*

Sandbox construction was **2.9%** of the run.

Nothing in the harness could answer the question, so nothing did. This document
therefore exists before the fix does, and the fix it justifies is deliberately
the small one.

## Headline

| | full pass | cases | verdict |
|---|---|---|---|
| BEFORE (`e41355b`, timing only) | **3353.9 s — 55.9 min** | 165 | 165 pass, 0 fail |
| AFTER (`e1ef0df`, as committed) | **2977.9 s — 49.6 min** | 165 | 165 pass, 0 fail |
| a scoped run of one section | **21 s to 181 s, typically ~50 s** | 1 to 14 | exit 3, never 0 |

**Do not read 55.9 → 49.6 as the effect of the change.** The BEFORE pass ran
while scoped verification runs of my own were competing for the machine and the
AFTER pass ran quiet, so that pair carries a load difference of the same order
as the effect. The honest attributable saving is **92 s**, and it is measured
twice, independently, below. The load confound is named here rather than banked.

## What this change is actually worth

**Per phase, and immune to machine load** — the harness stamps every
`make_sandbox` call:

| | BEFORE | AFTER |
|---|---|---|
| sandbox construction, all 85 builds | **95.7 s (2.9%)** | **3.8 s (0.1%)** |
| of which `gen_sidecars` | 74.6 s | — |
| one `make_sandbox` call | 1050 ms | 32 ms |
| one-time template build | — | 1.07 s |

**Head to head on identical work, both runs quiet.** The re-taken baseline was
killed at case 45, which still leaves an exact comparison over the prefix both
runs completed — the same 59 stamped cases, in the same order, building the same
53 sandboxes:

| | BEFORE-clean | AFTER |
|---|---|---|
| cumulative wall clock to case 45 | 617.5 s | 570.2 s |
| sandbox construction within it | 56.9 s | 1.7 s |

**47.3 s saved, against 55.1 s of setup removed.** The whole measurable
difference is the setup and nothing else, which is exactly what a change that
only touches the sandbox factory should look like.

## The real cost center: nineteen cases that are each a whole other suite

Nineteen of the 165 cases are not cases. Each runs **another entire test suite**
in a subprocess, and ten of them are `*.mutation.sh` harnesses that run a guard's
full behavioral suite once per mutant.

```
WTI1.staffing-gate-mutations                    630.0 s   18.8%
IN2.inflight-notify-mutations                   427.1 s   12.7%
MF1.mechanical-findings-mutations               205.8 s    6.1%
SA2.stated-actions-mutations                    202.0 s    6.0%
MC6.model-ceiling-mutations                     181.0 s    5.4%
IL7.idle-land-mutations                         165.2 s    4.9%
IP7.interactive-prompt-mutations                125.5 s    3.7%
CL2.claim-gate-mutations                        111.3 s    3.3%
RI2.resume-isolation-mutations                   70.3 s    2.1%
WTR1.worktree-removal-mutations                  49.9 s    1.5%
54 / RI1 / 53 / IP6 / 48 / IL6 / SA1 / CL1 / 40 179.6 s    5.4%
--------------------------------------------------------------
19 cases                                       2347.7 s   70.0%
everything else, including all setup           1006.2 s   30.0%
```

Full table: `results/nested-suites-before.txt`.

That is also why the suite outgrew the last measurement in `run-all-tests.sh`
(313 s for 98 cases on 2026-08-30): **the case count grew 1.7x while the wall
clock grew 10x**, because what was added were mutation harnesses. The suite's
cost tracks the number of MUTANTS, not the number of sandboxes — and a guess
that reads "81 sandboxes" off the source and calls that the cost is looking at
the wrong noun.

The remaining ~24% is the probe itself: about 10 s a run, roughly 80 runs.
Nearly half of each one is the worktree-lifecycle canaries — Q 2.1 s, Q4 2.2 s,
Q6 0.4 s (`results/probe-layer-profile.txt`). One probe run spawns 139 `python3`
processes (2.4 s at 17 ms each), 40 `git`, 23 `shasum`, and executes eight
guards for real as two-sided canaries.

**None of this is waste.** A mutation harness that runs a suite per mutant is
doing precisely the work that makes a green tick load-bearing, and this
repository has twice shipped a green suite over a script that never ran. The
answer is not to run less of it. The answer is to stop making a developer who
changed one line in one guard pay for the other eighteen.

## So the lever that answers the complaint is scoping, not copying

The CEO's words on 2026-09-03: *"changing every little fart that only should
take a few minutes stops being a 4+ hour long shitshow."*

The suite now takes `--only <section>`. Every one of the 24 sections, measured
on a quiet machine (`results/scoped-timings.txt`):

```
python3   4 cases    2s     N         4 cases   21s     worktree 4 cases  31s
config   14 cases   37s     K         8 cases   43s     S        6 cases  43s
M         7 cases   46s     WTR       1 case    48s     MC       9 cases  53s
MT        9 cases   53s     shim      6 cases   63s     P       12 cases  86s
base     11 cases   96s     manifest 10 cases   98s     CL       2 cases 108s
IP       10 cases  177s     MF        1 case   181s
```

Changing the cost-ceiling guard costs **53 seconds**, not 49.6 minutes. Every
one of those runs exited **3** with zero failures.

**A scoped run cannot be mistaken for a full pass**, in three independent ways,
because this suite's own history is the argument for belt and braces:

1. a banner before the first case;
2. a banner in the exit summary naming **every** case that did not run, section
   by section, with a total;
3. **exit code 3** when a scoped run is green — never 0. Banners are read by
   people; exit codes are read by land gates and CI, and 0 is the one thing a
   partial run must not be able to say.

An unmatched selector is fatal (exit 2), never an empty green run. `run-all-tests.sh`
invokes every suite as `bash "$t"` with no arguments, so what CI gets is still,
always, the full pass.

## What did NOT change

The case list and every verdict. `results/before-verdicts.txt` and
`results/after-verdicts.txt` are the ordered `(verdict, case)` lists from the two
full passes, 165 lines each, and

```
diff before-verdicts.txt after-verdicts.txt   ->  exit 0, 0 bytes
```

`results/verdict-diff.txt` is that output. **It is a zero-byte file, and its
emptiness is the point** — both lists are committed beside it so the diff can be
re-run by anyone rather than taken on trust.

No case was deleted, no assertion weakened, no layer skipped, no sandbox shared.
The 24 section markers are two inserted lines per boundary; not one character of
any case body changed.

## Method

`CI_TEST_TIMING=<file>` makes the harness append TSV records:

```
run       <t>  -    START | END
template  <t0> <t1> TOTAL          the one-time skeleton build (AFTER only)
sandbox   <t0> <t1> TOTAL          one per make_sandbox call
case      <t>  -    <case-name>    one per emit_case
```

`tools/analyze-timing.py` turns that into the ranked table. A case's *segment* is
the interval between the previous stamp and its own; a sandbox build finishing
inside a segment is attributed to it and the remainder is the case body.

**Stated rather than hidden:** 48 of the 165 verdicts are printed by hand-rolled
`PASS=$((PASS+1))` lines rather than `emit_case`, so they carry no stamp and
their cost lands in the following segment. That inflates a handful of segments
slightly and changes no conclusion, since the largest segments are each a single
nested suite. The verdict diff uses stdout and therefore covers all 165.

The clock is `perl -MTime::HiRes`, ~7 ms a call against 17 ms for a `python3`
start; BSD `date` has no sub-second format and bash 3.2 has no `EPOCHREALTIME`.
With `CI_TEST_TIMING` unset every added line is a no-op branch.

Subprocess costs on this machine, for anyone redoing this arithmetic:
`results/subprocess-costs.txt`. Clone fidelity and independence:
`tools/clone-independence-check.sh` — it proves a tampered clone leaves the
template and its siblings byte-identical, and that exec bits, empty directories
and the directory mode all survive.

## What is left, with numbers attached

1. **The ten `*.mutation.sh` harnesses — 2168 s, 65% of the run.** They are
   embarrassingly parallel by construction: every mutant already gets its own
   directory. Deliberately NOT attempted here — the CL1/CL2 flakes are documented
   as load-related, and naive parallelism turns a rare flake into a common one.
   The point of landing scoping first is that those flakes can now be
   characterized without paying 50 minutes per attempt.
2. **The probe's ~10 s, about 24% across ~80 invocations**, nearly half of it the
   Q/Q4/Q6 worktree-lifecycle canaries. Any change there changes what every case
   exercises, so it is deliberate work, not a cleanup.
3. **Nine `*.test.sh` suites run twice per CI pass** — once by
   `run-all-tests.sh`'s own discovery, once nested inside this harness. Whether
   the second run earns its place is a real question; the comment at each call
   site argues that it does. Named with a number attached rather than assumed
   either way.
4. **`RICH-TODOs.md` row v1 still carries the refuted diagnosis.** It lives in
   `richos-hq`, not this repository, so it is named here for whoever holds the
   pen on it. Its lever (1) is real but worth 92 s; its lever (2) is the one that
   answers the CEO and it has landed; its lever (3) is where the 65% is.
