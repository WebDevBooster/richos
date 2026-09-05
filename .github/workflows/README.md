# What runs in this directory, what does not, and why

**State on 2026-09-05.** Six workflows, four of them enabled.

- **Enabled:** `app-spine-ci`, `ui-suite-ci` and `windows-companion-ci`, on pushes and pull
  requests, each behind its own path filter.
- **Enabled:** `vouch-pr`, on every pull request opened or reopened. It is the only file here that
  acts on a person rather than on a diff, and it can close somebody's work.
- **Disabled in the file:** `engine-self-verify` and `packaging-ci`, each for a measured reason
  given in the table further down.

The title of this document read "Why every workflow here is disabled" until 2026-09-05, which was
true when it was written and had stopped being true on 2026-09-04. The rest of it is the history
that produced today's state, kept because the history is the reason.

## Why they were all disabled at once, and by whose ruling

**Disabled 2026-09-01, deliberately, by CEO ruling: "I'm certainly not gonna pay anything for this
open-source repo."**

### What happened

GitHub Actions stopped running across this repository at **2026-08-30T04:23:17Z** — a **billing
block, not a code failure**. Every workflow completed as `failure` in three to four seconds with:

> The job was not started because recent account payments have failed or your spending limit needs
> to be increased

Twelve consecutive runs. **Everything CI "verified" between that timestamp and 2026-09-01 verified
nothing.**

### Why they were disabled rather than left failing

A workflow that fails for a reason unrelated to the code is worse than no workflow: it puts a red
cross on every push, and a red cross that always means nothing teaches everyone to ignore the one
that will someday mean something. Disabling is the honest state.

### Why this was not a cost that needed paying

**Actions is free and unlimited on PUBLIC repositories.** The bill was a side effect of the
repository not being public yet — the license decision was sequenced last by CEO ruling
(`richos-hq/wiki/ceo-decisions.md` §18) and nothing went public before it — and never the price of
running CI. That condition is gone: `gh api repos/WebDevBooster/richos --jq .visibility` answers
`public`, which is why three of these are enabled again and why nothing in this directory costs
anything to run.

The cost mix, for whoever re-enables these: two Linux workflows bill at 1x, `windows-companion-ci`
at 2x, and **`packaging-ci` and `ui-suite-ci` run on macOS, which bills at 10x** — that pair is most
of the spend.

### What replaced it meanwhile

Local verification, which is currently stronger than what CI was providing: every engineer runs the
suites in their own worktree and the lander re-runs them independently before merging. The
meta-suite, the hook suites, the browser suites and the contrast walk all run on this machine.

**What is genuinely lost, stated rather than glossed:** the Linux and Windows runners. Nothing on
this Mac exercises `windows-companion-ci`, so the Windows capture path is now proven by neither CI
nor hardware — see CEO item 2.3. Do not let "local verification is stronger" quietly cover that gap.

### When to re-enable

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
| `vouch-pr` | **enabled** | added 2026-09-05, after the flip, so no part of the billing story above applies to it. It runs no suite: it reads `.github/VOUCHED.td` and closes a pull request from an author who is not on it. Never yet executed — see its header, and `docs/verification/pr-trust-gate-2026-09-05/README.md` |

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

## Every action here is pinned to a commit, and here is how to move a pin

**Pinned 2026-09-04.** A tag is a pointer. `actions/checkout@v5` says "whatever
`v5` means on the morning the job runs", and whoever can move that pointer runs
code on a runner that has already checked this repository out — in
`packaging-ci`, next to release machinery. Only a full 40-character commit SHA is
immutable, so that is what every `uses:` line here carries, with the
human-readable version as a trailing comment.

**The inventory is not repeated here on purpose.** The workflow files are the
list; a table in this README would be a second copy of it, free to drift, and the
first thing a reader trusts. `grep -n 'uses:' *.yml` answers the question with no
possibility of being out of date.

**To move a pin, resolve it from the action's own repository and never from
memory, another project, or a search result:**

```
git ls-remote --tags https://github.com/actions/checkout.git 'refs/tags/v5.2.0'
```

If the output has a second line ending `^{}`, the tag is annotated and the peeled
line is the commit — pin that one. Then confirm the SHA belongs to the repository
you think it does, which is the check that catches a SHA copied out of a fork:

```
gh api repos/actions/checkout/commits/<sha> --jq .sha
```

Update the trailing `# vX.Y.Z` comment in the same edit. A version comment that
no longer matches its SHA is worse than no comment, because it is the only thing
a reader can read.

**The worked example for why the peel matters is in this directory.** `vouch-pr`
pins `mitchellh/vouch/action/check-pr`, whose `v1` is an ANNOTATED tag, and the
object that tag names is not a commit:

```
$ git ls-remote https://github.com/mitchellh/vouch.git 'refs/tags/v1' 'refs/tags/v1^{}' 'refs/tags/v1.5.0'
f23dbb5e745334f97414ec70463ce7301071a661        refs/tags/v1
d66fa29a64600490892131ad87597c30c91fcac4        refs/tags/v1^{}
d66fa29a64600490892131ad87597c30c91fcac4        refs/tags/v1.5.0
```

Pinning `f23dbb5e…` would have been the natural mistake: it is a real object ID,
it comes from the right repository, and it fails at run time rather than at
review time. The peeled line is the commit and it is what the file carries.
`v1.5.0` has no `^{}` line at all because it is a lightweight tag — so the
PRESENCE of a second line is the signal, not the version number, and the two
must be resolved together or the pair in the file will not match.

**A pin is only as deep as the action is.** `check-pr` is a composite: its own
first step installs Nushell through `hustcer/setup-nu`, which upstream does pin,
at `version: "*"`, which upstream does not. So pinning a composite action pins
the code it runs and not necessarily the interpreter that runs it. That is named
here because this is where somebody will look for it; what it costs that
particular workflow is in that workflow's own header.

**These pins WILL go stale, and that is the trade being made.** A pinned action
never picks up an upstream security fix on its own. The automated route is
Dependabot's `github-actions` ecosystem, which opens a pull request that bumps
the SHA and the comment together; until that is switched on, moving these is a
manual job with a real cost — which is the honest price of the tag not being able
to move underneath us.

### The repository policy that would ENFORCE this is off, on purpose

GitHub can refuse to run any workflow whose actions are not pinned, rather than
trusting everyone to remember. On **2026-09-04** the repository reports:

```
$ gh api repos/WebDevBooster/richos/actions/permissions
{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}
```

**It is off, and turning it on is the CEO's call, not an engineer's**, because it
does not only judge the seven references pinned today — it judges every workflow
this repository ever gains. A new one added with `actions/checkout@v5` in it does
not warn; per GitHub's documentation, "workflows referencing actions this way will
be blocked and unable to run", which on a bad day looks like CI silently not
starting. Reusable workflows are exempt and may still be referenced by tag.

If it is decided, it is one call — `Settings > Actions > General > Actions
permissions` in the web interface, or:

```
gh api -X PUT repos/WebDevBooster/richos/actions/permissions \
  -F enabled=true -f allowed_actions=all -F sha_pinning_required=true
```

Nothing in the tree needs to change first: as of the commit that added this
section, every action reference under `.github/workflows/` is already a
full-length SHA, so the policy would be satisfied on the day it is switched on.
