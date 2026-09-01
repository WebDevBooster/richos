# Why every workflow here is disabled

**Disabled 2026-09-01, deliberately, by CEO ruling: "I'm certainly not gonna pay anything for this
open-source repo."**

## What happened

GitHub Actions stopped running across this repository at **2026-08-30T04:23:17Z** — a **billing
block, not a code failure**. Every workflow completed as `failure` in three to four seconds with:

> The job was not started because recent account payments have failed or your spending limit needs
> to be increased

Twelve consecutive runs. **Everything CI "verified" between that timestamp and 2026-09-01 verified
nothing.**

## Why they are disabled rather than left failing

A workflow that fails for a reason unrelated to the code is worse than no workflow: it puts a red
cross on every push, and a red cross that always means nothing teaches everyone to ignore the one
that will someday mean something. Disabling is the honest state.

## Why this is not a cost that needs paying

**Actions is free and unlimited on PUBLIC repositories.** This repository is private for exactly one
reason — the license decision is sequenced last by CEO ruling (`richos-hq/wiki/ceo-decisions.md` §18)
and nothing goes public before it. So the bill is a side effect of the repository not being public
yet, not the price of running CI.

The cost mix, for whoever re-enables these: two Linux workflows bill at 1x, `windows-companion-ci`
at 2x, and **`packaging-ci` and `ui-suite-ci` run on macOS, which bills at 10x** — that pair is most
of the spend.

## What replaces it meanwhile

Local verification, which is currently stronger than what CI was providing: every engineer runs the
suites in their own worktree and the lander re-runs them independently before merging. The
meta-suite, the hook suites, the browser suites and the contrast walk all run on this machine.

**What is genuinely lost, stated rather than glossed:** the Linux and Windows runners. Nothing on
this Mac exercises `windows-companion-ci`, so the Windows capture path is now proven by neither CI
nor hardware — see CEO item 2.3. Do not let "local verification is stronger" quietly cover that gap.

## When to re-enable

**The day this repository goes public** — at which point every workflow here is free, forever, on
standard runners. Re-enable with `gh workflow enable <name>.yml`. Nothing else about them needs to
change; they were never broken.
