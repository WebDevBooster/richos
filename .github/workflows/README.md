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
standard runners. Re-enable with `gh workflow enable <name>.yml`.

## "Nothing else about them needs to change" was wrong, and here is the measurement

That sentence stood here until 2026-09-04. It was an inference — the runs had failed on billing, so
nothing about the code was implicated — and it was never tested, because a billing-blocked run
produces no log to test it against. **All five were then exercised, verbatim, inside a real clone
of this tree in a directory with no private `richos-hq` sibling and under a throwaway `$HOME` —
the engine's on Linux, in a container, as an unprivileged user, because that is what its runner
is. Two of them were not fine.** The clone, the commands and the transcripts are in
`docs/verification/workflows-on-a-clone-2026-09-04/`.

| workflow | state | why |
|---|---|---|
| `app-spine-ci` | **enabled** | green in the clone; `--locked` accepted; only "does it build on Linux" is left to the runner |
| `ui-suite-ci` | **enabled** | green in the clone under WebKit from its own `node_modules`, after one load-sensitive check in `splash.js` was found flaking and fixed |
| `windows-companion-ci` | **enabled** | restore, the `net8.0-windows` build and all 26 core tests pass off Windows; only the `doctor` smoke step needs the runner |
| `engine-self-verify` | **DISABLED IN THE FILE** | `ci-verify.sh` exits 1 on Linux: 55 of 60 suites, five red, two of them red on macOS too. One Linux-only defect was found and fixed (`sed -i ''` aborted the largest suite outright, exit 2, with two whole layers never reached). Its 45-minute timeout could not have been met on any host and is now 150, from a measured 65m40s full pass |
| `packaging-ci` | **DISABLED IN THE FILE** | 3 of its 7 suites cannot pass on a public runner. One of them needs a compiler that lives in the private repository. Its own header carries the measurement and what would re-enable it |

**So the post-flip step is "dispatch three", not "dispatch five".** The two disabled files have had
their `push` and `pull_request` triggers removed for exactly this reason; dispatching either anyway
produces a red run that says nothing about going public.

**And the important half of that sentence:** two of `engine-self-verify`'s five reds are red on
the machine the engine is developed on, today, and a third is red on the platform CI uses. **The
flip does not cause them; it publishes them.** Each disabled file names its own list and states,
in one line, what puts its triggers back.

**The red lists were measured twice, on purpose.** The first Linux pass ran on a machine carrying
eleven agents at a load average up to 58, and a red list taken under those conditions cannot tell
a defect from a flake — it proved it, by failing a suite that passes 57/57 when quiet. Everything
was re-run on a quiet host before it was written down, and two suites changed classification
between the passes.

**None of this makes any of them CI-verified.** A clone on the author's Mac answers "does this
depend on his machine". It does not answer "does this work on a runner", and no workflow here
should be described as verified until a run of that workflow is green on a SHA somebody can name.
