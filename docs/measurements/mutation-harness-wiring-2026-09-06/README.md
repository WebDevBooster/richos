# What it costs to run the eight orphaned mutation harnesses — measured 2026-09-05/06

Rows 3.22, 3.23, 3.25, 3.26, 3.27, 3.28, 3.29 and 3.31 of `wiki/open-items.md`
(in the `richos-hq` record, deliberately named rather than linked — this
repository is published and that one is not) are eight
write-ups of one fact: eight `*.mutation.sh` harnesses were named on no
non-comment line of any script or workflow in this repository. Wiring them into
the suites they mutate is the fix, and **the fix has a price. This document is
that price, measured rather than estimated, so that whoever decides it is too
much decides on a number.**

## Headline

| | wall clock |
|---|---|
| the eight sibling suites, BEFORE (suite alone, serial) | **123 s — 2 m 03 s** |
| the eight harnesses they now invoke (serial) | **1577 s — 26 m 17 s** |
| the eight suites, AFTER, end to end (serial) | **1761 s — 29 m 21 s** |

**So the engine self-test grows by roughly 26 minutes.** Two independent
arithmetics agree to within 3.6%: `123 + 1577 = 1700 s` predicted against
`1761 s` measured end to end, the gap being machine load between the two
passes.

## The load, named rather than banked

Every number here was taken on this Mac with **about sixty agents live on the
machine**. The absolute figures therefore run high. What is protected is the
COMPARISON: each before/after pair was taken minutes apart under the same load,
and the parallel-versus-serial gap was measured directly rather than assumed —
the first exploratory run of all eight concurrently gave `root-contract` 609 s
where a serial run gave 494 s and 535 s, and `ceo-asks` 230 s against 98 s. A
concurrent number is not comparable to a serial one and none is used that way
below.

## Per suite

| suite | before | harness | after, end to end |
|---|---|---|---|
| `ceo-asks.test.sh` | 8 s | 98 s | 123 s |
| `ceo-ruled.test.sh` | 5 s | 39 s | 46 s |
| `ceo-todos.test.sh` | 36 s | 422 s | 490 s |
| `unasked-deferral.test.sh` | 5 s | 107 s | 135 s |
| `unstarted-rows.test.sh` | 7 s | 298 s | 334 s |
| `waiver-repetition.test.sh` | 2 s | 39 s | 44 s |
| `turn-manifest.test.sh` | 6 s | 39 s | 21 s |
| `root-contract.test.sh` | 54 s | 535 s | 568 s |
| **total** | **123 s** | **1577 s** | **1761 s** |

`turn-manifest`'s after-figure is BELOW its own before-plus-harness, and that
is load rather than a saving: its harness was separately timed at 16.4 s on a
quieter machine and 39 s on a busy one. It is the smallest row here and the
noisiest.

**Two suites are two thirds of the cost.** `root-contract` (535 s) and
`ceo-todos` (422 s) are 61% of the 1577 s. `root-contract` runs eleven mutants
against a suite that itself takes 54 s, so its cost is arithmetic and not
waste: a mutation harness costs N times the suite it mutates, which is what
makes its green tick load-bearing.

## What this is measured AGAINST, and what is not measured here

**A full `run-all-tests.sh` pass was NOT re-run for this document**, and saying
so is the point of this paragraph. 73 suites are discovered, and the largest,
`contract-integrity.test.sh`, was last measured at **2977.9 s** — see
[`integrity-suite-cost-2026-09-04`](../integrity-suite-cost-2026-09-04/README.md).
A before-and-after pair of full passes is about two hours of machine time and
would have added nothing to the DELTA, which is what this change controls and
which is measured exactly above. The delta is mine; the base is quoted.

## The levers, if 26 minutes is judged too much

Stated as options rather than pulled, because the trade is a judgment about the
engine's own budget and not a detail:

1. **A case filter.** Each mutant runs the whole suite in order to check that
   one named case goes red. `contract-integrity.test.sh` already takes
   `--only <section>`; the same in these eight would cut most of the 1577 s.
   **The reason it is not done here** is that a filtered run is exactly the
   shape of the defect this project spent 2026-09-05 finding eleven instances
   of — a check reporting green over something that never ran — and building
   eight filters at speed is how that gets rebuilt. It is a real lever and it
   needs a careful hand, not a fast one.
2. **A separate invocation CI makes explicitly.** Move the harnesses out of the
   default suite path and into a job of their own. **The cost of this is
   stated rather than glossed:** it puts them back on the honor system for
   anybody running a suite locally, which is most of the value of wiring them
   at all.
3. **Concurrency across mutants.** The mutants are independent — the
   exploratory run above proved eight harnesses run concurrently in 609 s of
   wall clock against roughly 1300 s serial. This is the biggest single win
   available and it is a rewrite of eight files.

**The recommendation is to keep them on the default path.** The runner already
lives in `ci-verify.sh` step 3 rather than at a chokepoint, for reasons its own
header argues at length, and it is already a fifty-minute job. Adding 26
minutes there does not change the CATEGORY of the thing; it changes an
already-CI-only suite from long to longer. Skipping the harnesses would keep
eight properties proven by nothing, and two of the eight turned out to be
proving nothing already.

## What running them found, on the first run any of them ever had

Two of the eight went red immediately, which is the argument for this whole
change in one line.

| harness | finding |
|---|---|
| `turn-manifest.mutation.sh` | `can-block`'s needle drifted when the hook gained its stop-hook notice channel. The property — the manifest has no path that can refuse a turn — was proven by nothing from that refactor until now. The harness refused rather than passing, and printed the refusal to nobody. |
| `root-contract.mutation.sh` | `M8`'s target line moved file when model resolution was extracted into `scripts/lib/resolve-model.sh`. Same shape. |
| `root-contract.mutation.sh` | `M1`'s witness case, `1a`, stopped being sensitive to seat resolution when `guard-main-checkout-writes.sh` began resolving governance from the FILE. The mutant is killed at fourteen other cases; the specific claim was false. |

Both harnesses now pass, 7/7 and 11/11, with the mutants killed at the cases
named.

## Method

Serial, one at a time, `date +%s` around each invocation:

```
scripts/hooks/<name>.test.sh          # before, at 58790b4
scripts/hooks/<name>.mutation.sh      # the harness alone
scripts/hooks/<name>.test.sh          # after, at 3e692fa, harness invoked
```

The after-pass additionally asserted `harness_ran=1` by grepping each suite's
own output for its `running the mutation harness` banner, because the first
draft of the wiring skipped the harness in silence and printed a full green
tally in 3.7 seconds. **Wall clock is what caught that**, so wall clock is not
the only thing checked here.
