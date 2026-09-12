NOT CERTIFIED

# Frank — certification of the runner round

    branch      cc/zach-opus-g3
    SHA         4c70bfc296bb8f6b4f7c6297ccc80aa7d1805483
    over        2bc413df (seven commits)
    reviewed on cc/frank-opus-c5, worktree /Users/alex/ab/richos-wt/frank-opus-c5
    yardstick   /Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md
    reviewer    frank-opus-c5. I did not read Sage's work; where a Sage probe
                appears below it is because the runner printed its name.

**The five items are built and, on their own axis, they hold.** My c4 probe and
its control went from 1/6 and 2/6 to 6/6; the library's own suite is 58/58 with
43/43 mutants proven load-bearing; the runner's self-test is 11/11; the runner
catches a real regression of this round's headline fix. The reversal is a clean
revert and the deleted property deserved deleting.

**I am refusing anyway, on one defect.** This round made every consumer ask the
library instead of assuming main. One of those consumers is the sweep behind the
Stop-hook that exists to stop a turn ending with finished work stranded. On a
repository with no branch recorded — which is the state of **both** repositories
on this machine right now — that sweep changed from *naming the unlanded branch*
to *returning nothing*, and the hook above it renders nothing as
**"UNLANDED-BRANCH WATCH: clear again"**. The instrument that enforces point 5
now reports a clean bill of health over stranded work. That is D1 below,
reproduced in both directions against the same fixture.

---

## 0. Was ~/.claude/state/workspaces touched?

No. Snapshot (`name|size|mtime|ctime` of every entry) taken before the first
probe ran and again after everything below; `diff` empty both times.

    UNCHANGED: ~/.claude/state/workspaces identical to the baseline
    STILL UNCHANGED

Every probe, suite and experiment ran with `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR`,
`GIT_CONFIG_GLOBAL`, `RICHOS_WORKSPACES_DIR` and `RICHOS_WORKTREE_LEDGER`
redirected into a temporary directory. Nothing was installed, merged, pushed or
deployed; `/Users/alex/ab/richos/engine` was never written; the pinned mirror of
the spec in this repository was not read as the spec and not touched.

One exception I did **not** cause, and it is F3 below: the live registry already
contained four records written by a test fixture before I started.

---

## 1. The runner, as I ran it

    $ python3 engine/scripts/workspace-probes.py
    workspaces.py under test: .../frank-opus-c5/engine/scripts/lib/workspaces.py
    probes discovered:        10 (5 in the working tree, 5 on other branches)
    other files under docs/verification/ that are not probes of this library: 242

    GREEN      docs/verification/certification-frank-attribution-2026-09-12-probe.py                                    3.4s
    GREEN      docs/verification/certification-frank-four-fixes-2026-09-12-probe.py                                     1.8s
    RED        docs/verification/certification-sage-attribution-2026-09-12.probe.py                                     4.2s
               a scenario failed to run: exit 1
    GREEN      docs/verification/workspace-attribution-seven-cases.probe.py                                             4.1s
    GREEN      docs/verification/workspace-call-window-and-recorded-target.probe.py                                     2.0s
    RED        docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py                           3.3s   [dev/workspace-spec]
               exit 1
    GREEN      docs/verification/certification-frank-window-and-target-2026-09-12-logs/c4-control-no-refused-call.py    2.8s   [cc/frank-opus-c4]
    GREEN      docs/verification/certification-frank-window-and-target-2026-09-12-probe.py                              2.8s   [cc/frank-opus-c4]
    RED        docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py                            2.8s   [dev/workspace-spec]
               exit 1
    GREEN      docs/verification/certification-sage-window-and-target-2026-09-12.probe.py                               3.5s   [cc/sage-opus-c4]
    ...
    RED (a prior probe now fails):
        docs/verification/certification-sage-attribution-2026-09-12.probe.py   author: sage
        docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py   author: frank
        docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py   author: sage

    exit 1

Three red, exactly as the brief said. One of them is mine.

---

## 2. My c4 probe and its control, re-run first

The engineer reports 1/6 and 2/6 at `2bc413df` and 6/6 here. Both reproduce
exactly. I extracted both files from `cc/frank-opus-c4` with `git show` and ran
them unmodified.

    $ python3 -B c4-probe.py   <branch lib>            -> exit 0   6/6 cases hold
    $ python3 -B c4-probe.py   <2bc413df lib>          -> exit 1   1/6; BROKEN: late-record-stray,
                                                          late-record-side, late-record-rename,
                                                          leaked-window-widens, leaked-window-evicts
    $ python3 -B c4-control.py <branch lib>            -> exit 0   6/6 cases hold
    $ python3 -B c4-control.py <2bc413df lib>          -> exit 1   2/6; BROKEN: late-record-stray,
                                                          late-record-side, late-record-rename,
                                                          leaked-window-evicts

And the cases hold for the RIGHT reasons, not by a disjunction going the easy
way. From the branch run:

    1 late-record-stray    land after the recording: landed
                           branches after the land: ['main']      (the stray is gone)
                           pending after the land: []
    2 late-record-side     REFUSED ... sidework (4e9fc3250973) is not in main
                           its side commit reached main: False
    4 late-record-rename   landed; branches after the land: ['main']
    5 leaked-window-widens rich/rescue survived: True
    6 leaked-window-evicts attributed at the Post (not only at the end): True

This is the substance of D1–D4 from my last round and it is fixed. The
attribution-skipped counter is 0 where it used to fire, the stray and the rename
are deleted by the land, the side branch holds the land and names itself, and a
leaked window from a refused call no longer widens the end-of-run comparison.

---

## 3. My retirement rulings, one red case at a time

My red probe is `certification-frank-recorded-attribution-2026-09-12-probe.py`
on `dev/workspace-spec`. It is **5/10** — and it is 5/10 at `2bc413df` as well:

    $ python3 -B recorded-attr.py <branch lib>    -> exit 1  5/10; BROKEN: outside-stray,
                                                     floor-timing, serial-stray, serial-side, serial-rename
    $ python3 -B recorded-attr.py <2bc413df lib>  -> exit 1  5/10; BROKEN: (the same five)

**First correction to the escalation.** It says these cases are red because
"their repositories record no integration branch, which this round made
mandatory". This round did not make it mandatory. The identical five were red at
`2bc413df`, before a line of this branch existed. The previous round made it
mandatory when it deleted the floor. Nothing turns on it for the rulings below,
but the round that caused a red probe is not a detail to get wrong in the
document asking a reviewer to retire it.

Being hostile about the rest, because "your fixture is stale" is the most
convenient explanation available to the person failing the test. I did not use
his adapter. I patched my own copy, one line per case, and re-ran.

### `floor-timing` — **OBSOLETE**

    record at session start                 None
    main checkout's branch at registration  main
    record after registration               None (source: None)
    agent's frozen copy                     {}

The case asserts `rec["branch"] == "main"` in order to answer **where the floor
reads the branch** — at the session's start or at the first workspace
registration. The floor was deleted in the previous round. There is no record at
either moment, so there is no reading to locate. The premise is gone, not
merely unsatisfied. Retired as obsolete.

I reject the engineer's stated reason for this one. His classifier files it as
"RED ONLY WITHOUT A RECORDED BRANCH <- the fixture, not the build", which is
true and worthless: with `main` recorded, `rec["branch"] == "main"` passes
because the fixture recorded it, not because anything was read at the right
moment. It would be a tautology wearing the shape of a case. The case is
obsolete because the floor is gone. Right verdict, wrong argument.

### `serial-stray` — **OBSOLETE AS WRITTEN**
### `serial-side` — **OBSOLETE AS WRITTEN**
### `serial-rename` — **OBSOLETE AS WRITTEN**

These three were written as the CONTROL for the overlapping-call cases: the same
shapes with one call open at a time, expected to hold. They now stop at a
precondition they never reach past:

    land after   REFUSED: zach-opus-q6 is not landed yet: ...: no branch is
                 recorded for ... as the one this work integrates on

That refusal is what point 14 requires — *"The branch a body of work integrates
on is RECORDED when that work starts, before its first agent is spawned. Nothing
infers it and nothing guesses it."* The fixture spawns an agent with nothing
recorded, which is the state point 14 forbids. The assertion never reaches the
behavior it was written to measure.

I verified this myself rather than taking it. I inserted exactly one line —
`record_integration(entity, "main", ...)` — at the head of each of the three
cases and re-ran them against this branch's library:

    === 8  serial-stray   land after: landed; branches after the land: ['main']      HOLDS
    === 9  serial-side    REFUSED ... sidework (c98e89a71955) is not in main         HOLDS
    === 10 serial-rename  landed; branches after the land: ['main']                  HOLDS
    === 3/3 cases hold

`serial-side` refuses naming `sidework`, which is the assertion I actually wrote,
not a coincidence. So: correct for the right reason, with the one line point 14
requires.

**And retiring them loses no coverage,** which is the part I checked before
agreeing. Every behavior these three asserted is asserted, green, by my own c4
probe on `cc/frank-opus-c4`, in the same one-call-at-a-time shape:
`late-record-stray` (the stray is deleted by the land), `late-record-side` and
`record-first-control` (the side branch holds the land and names itself), and
`late-record-rename` (the renamed branch goes with it). The control role survives
too — the c4 cases never overlap their calls either.

### `outside-stray` — **STILL VALID. Not retired.**

The premise exists and I measured it on this machine last round: a background
Bash process was still working three seconds after its own PostToolUse had
ended, so a ref it creates is created outside every window. Nothing in this
branch changes that, and the case is red at `2bc413df` and here alike — the
engineer's own classifier agrees ("RED BOTH WAYS <- a real question, not the
fixture"). The CEO put it out of this round's scope. **Descoped is not
obsolete**, and I will not write "obsolete" in a file that will be read years
from now to make an exit code go green today.

### The mechanical consequence, stated plainly

**The runner cannot be made green by any ruling I am entitled to make.**
Retirement is keyed on the probe's **file**, not on its cases:

    base = os.path.basename(p.name)
    if base in retired:
        ...
        p.verdict = "RETIRED"
        continue                      # the probe is not run at all

My four obsolete cases and my one still-valid case live in one file. Retiring
the file to clear `floor-timing` and the `serial-*` three would also stop the
runner asking `outside-side`, `floor-trap`, `floor-control`,
`no-floor-self-heals` and `rich-at-my-tip` — five live assertions, all currently
green, silently dropped. That trade is worse than a red line in a report, so I
have written **no** retirement line. The rulings above are the record; the file
stays as it is and the runner stays non-zero. See F4c.

---

## 4. The five things I was asked to judge rather than accept

### 4.1 The runner itself

**What holds.** Its own suite is real and passes:

    $ bash engine/scripts/workspace-probes.test.sh          -> exit 0
    === workspace-probes tests: all 11 passed ===

The zero-probe fix works — I tried it directly:

    $ python3 engine/scripts/workspace-probes.py --only zzz-no-such   -> exit 1
    NOTHING WAS RUN. 1 probe(s) were discovered and none was selected by --only zzz-no-such.
    A run that asked nothing is not a run that passed.

Spec point 2 is respected: I committed a probe on a `codex/experiment` branch in
a throwaway repository and the runner did not read it.

And it catches a real regression. I took this branch's `workspaces.py`, put back
the one thing this round removed — the `attribution-skipped` early `continue` in
`observe_created_refs` — and pointed the runner at the result:

    $ python3 engine/scripts/workspace-probes.py --lib ws-regressed.py   -> exit 1
    RED   .../c4-control-no-refused-call.py   [cc/frank-opus-c4]
    RED   .../certification-frank-window-and-target-2026-09-12-probe.py  [cc/frank-opus-c4]

Both of my c4 probes go red on it. On its stated axis, the runner works.

**Now the two attacks I was asked to make.** Both succeed. Details and
reproductions in F4.

*Hide a probe:* a probe that drives the library as a **child process** is not
discovered. Discovery needs the file's text to contain `workspaces.py` **and**
one of the `DRIVES` tokens, all of which are in-process loader spellings. A
probe that shells out — to `workspaces.sh`, say, which is a legitimate and
obvious probe shape — has none of them. I wrote two and neither was discovered,
including one whose docstring says "Frank's probe of workspaces.py".

*Make it pass while a real regression is present:* two ways. A **forged
retirement** — the author check compares the TSV's second column against a name
parsed out of the probe's **filename**, so anyone who can write the file can
type `frank`; the red probe becomes `RETIRED` and the runner exits 0. And
**same-path shadowing** — a file committed in the working tree at the same path
as a reviewer's branch probe silently replaces it, the branch version is never
read, never named, and the runner prints the all-clear.

### 4.2 Reading other local branches — sound, or a gate that depends on branches deleted at land?

**Sound for the case it was built for; the hole is discarding, not landing.**
Point 4 does delete a reviewer's branch at the land — but landing is a merge, so
the probe arrives in the tree on the way out and `branch_probes` correctly
prefers the tree copy afterwards. Of the five branch-borne probes here, two are
already on `dev/workspace-spec`, which is this work's integration branch and is
not deleted at all.

The real exposure is point 7. **A discard deletes the branch without merging**,
so a reviewer's probe on a discarded branch is destroyed, and the runner's only
witness to the loss is a number that nothing checks: `probes discovered: 10`
becomes `9` and the run still prints *"every discovered probe ran, and every one
of them is green."* There is no manifest, no expected count and no floor. That
is the same "undiscovered is worse than red" the runner was written to end,
arriving by subtraction instead of by a discovery rule. F4d.

### 4.3 The reversal — the age-based open-window cap

**Complete, and his reasoning holds.** The net diff of `workspaces.py` from
`2bc413df` to `4c70bfc2` contains no change to `_evict_old_slots`, and
`git log -S"_evict_old_slots" 2bc413df..4c70bfc2` returns nothing — no commit on
this branch ever touched it. The function is byte-identical to the baseline; the
only thing the diff adds near it is a comment. Nothing was left half-reverted
because nothing was ever committed.

His reasoning checks out independently: my `leaked-window-evicts` case — 70
refused calls opened on top of a live one — holds on this branch
(`attributed at the Post (not only at the end): True`), and the mutant that
removes the unpaired-Post fallback is proven load-bearing by the mutation run
below. So the fallback rescues the case, the eviction change was a second fix
for a symptom one fix already covers, and declining to ship it is right.

**One inaccuracy.** The comment he added says *"The cap evicts the OLDEST window
by position"*. It does not: `_evict_old_slots` re-sorts by `os.path.getmtime`
before evicting. That is age, of a kind. It has no effect on the verdict — the
sort was there at `2bc413df` too — but a comment that misdescribes the code
beside it is how the next round gets the premise wrong.

### 4.4 The deleted property

**`p03-end-of-run-consumes-one-window`**, replaced by
`p03-no-end-of-run-observation`. **I rule the deletion correct.** Its assertion
was that consuming *every* open window at the end of a run rather than *one* is
load-bearing. Once the before-sets are unioned, which window is consumed no
longer changes what is attributed, so it was an assertion that could not fail for
its stated reason — a dead rule wearing the shape of a live one. The replacement
mutates what is still load-bearing (that the end-of-run signal observes at all)
and is proven.

**A second deletion in the same commit is not named in the brief and is worth
naming.** `bac187f3` also deletes a **test**:
`test_point_03_a_burst_of_refused_calls_never_evicts_a_live_window`, replaced by
`test_point_08_a_branch_that_existed_before_the_call_is_never_created_in_it`.
That is consistent with the reverted eviction — the test asserted the reverted
change — and its behavior is still covered by my c4 `leaked-window-evicts`,
which is green. I do not call it a defect. But the commit's own summary line is
"one property deleted", and two things were deleted; a reader counting on that
sentence would miss the test.

Both suites reproduce:

    $ python3 -B engine/scripts/lib/workspaces.test.py      -> exit 0   58 run, 0 failed
    $ bash engine/scripts/lib/workspaces.mutation.sh        -> exit 0   all 43 properties proven load-bearing

### 4.5 Consumers — re-derived, and the exclusions

I re-derived the list with a wider net than his (adding `merge-base`,
`origin/main`, `MAIN_BRANCH`, `DEFAULT_BRANCH` to his terms), over
`engine/scripts`. Discounting test and mutation files, the candidates are his
nine plus **three he names nowhere**:

* `hooks/guard-worktree-removal.sh` — its `merge-base` hits are a read-only git
  verb allowlist and two comments. **Correctly excluded**, though silently.
* `hooks/contract-integrity-probe.sh` — its two hits are prose about
  `worktree.baseRef`. **Correctly excluded**, silently.
* `hooks/notice-unlanded-branches.sh` — the caller of `unlanded-branches.py`.
  It keeps no answer of its own, so it is not a ninth consumer. **But leaving it
  out of scope is how D1 below got shipped**: he changed what the sweep returns
  and did not look at what the hook says about the new return.

The eight he changed are all genuine second answers and all now ask the library.
`land-completeness` is the model of how to abstain — I ran it on a repository
with nothing recorded and it says so where a reader cannot miss it:

    NOT EXAMINED (1) — the absence of a finding is not a finding
        /...//repo
            no branch is recorded for ... (point 14); nothing infers it. Record it: workspaces.sh integration ...

**The exclusions: sound on the letter of the sentence, with one false reason.**
Point 14 binds *"Every part of the system that needs to know whether work has
landed"*. `guard-stale-staging.sh` and `staging-current.sh` ask what is deployed;
`land-completeness-measure.py` decides no landedness; `ci-red.py`,
`ci-surface.py` and `ci-run-records.py` read CI runs. All out of scope. Verdicts
upheld.

His **reason** for the CI three is wrong, though: *"they take --branch from their
caller"*. They do not always.

    engine/scripts/lib/ci-red.py:181          ap.add_argument("--branch", default="main")
    engine/scripts/lib/ci-run-records.py:89   ap.add_argument("--branch", default="main")
    engine/scripts/ci-surface-watch.sh:319    python3 "$REDPROBE" --repo "$slug" --refresh --json   # no --branch
    engine/scripts/ci-run-record-check.sh:84  REPO=""; WORKFLOW=""; BRANCH="main"; ...

`guard-ci-red-lands.sh:563` does pass `--branch "$WATCHED_BRANCH"`, so the path
he cares about is covered. But `ci-surface-watch.sh` passes no branch at all and
the file's own default decides. The exclusion survives on scope; the rationale
should not have been written as a statement of fact about the callers.

---

## 5. Defects — the sentence, and the reproduction

### D1. The unlanded-branch watch reports "clear again" over stranded work

**The sentence it breaks**, point 5:

> **Enforced:** while any finished agent's work is neither landed nor discarded
> (point 7), Rich can neither start new work nor end his turn.

**The observed instance.** One sandbox repository, one branch `cc/zach-opus-x1`
carrying a commit `main` does not have, nothing recorded, everything redirected
into a temporary directory. The same fixture, the two libraries:

    # engine/scripts/lib/unlanded-branches.py at 2bc413df
    STATUS   swept
    N        1
    KEY      repo/cc/zach-opus-x1@6a3466f1d782
    SUMMARY  UNLANDED WORK, NOBODY HOLDING IT - 1 branch(es) ahead of main that no live
             worktree claims: repo cc/zach-opus-x1 (1 commit, 0.0d). ... do not end on
             the word clean.

    # engine/scripts/lib/unlanded-branches.py at 4c70bfc2
    STATUS   partial
    N        0
    KEY      (empty)
    SUMMARY  (empty)

`trunk_of` now returns `None` when nothing is recorded, the repository is skipped
as unanswerable, and the sweep's verdict carries no finding. The hook above it,
`engine/scripts/hooks/notice-unlanded-branches.sh` — unchanged by this branch —
treats `partial` as a no-op and then reads `N`:

    partial)
        : ;;  # some repository could not be answered for; the findings below
              # are still real and the lint script names the gap.
    ...
    if [ "${N:-0}" = "0" ] || [ -z "$SUMMARY" ]; then
        stop_notice_normal \
            "UNLANDED-BRANCH WATCH: clear again — every branch ahead of main is held by a live teammate, or there are none. $HOOK_TAG"

So the turn ends on the words **"clear again"** with a finished agent's branch
sitting outside everything.

**The load exists on this machine.** `~/.claude/state/workspaces/integration.json`
records four bodies of work, all of them temporary fixture directories. Asked
about the two real repositories (against a *copy* of that registry):

    /Users/alex/ab/richos     -> ('', '', "no branch is recorded for /Users/alex/ab/richos ...")
    /Users/alex/ab/femcboost  -> ('', '', "no branch is recorded for /Users/alex/ab/femcboost ...")

Both abstain. The moment this branch is installed, the watch is silent-and-green
on both, and this is the hook whose own header exists because *"SIX finished
branches sat outside main, one of them the fix for the CEO's own..."* and whose
own words elsewhere are *"A clean main and an absent checker must never look the
same."*

The abstention itself is right — point 14 forbids inferring. The defect is that
one consumer renders abstention as a clean bill of health while its sibling,
`land-completeness`, renders the identical abstention as `NOT EXAMINED`. The same
round produced both.

### D2. `guard-idle-land` confirms a land from HEAD alone, and its comment says the opposite

**The sentence it breaks**, point 14:

> Every part of the system that needs to know whether work has landed asks the
> same question: is it in the branch recorded for this work? None of them is
> allowed its own answer, and none of them assumes main.

`engine/scripts/hooks/guard-idle-land.py`, `confirm_landing()` as it now reads:

    branch = _recorded_integration_branch(repo)
    if not branch:
        return True

With nothing recorded it answers "a land was confirmed" from the main checkout's
HEAD — its own answer to the question the sentence reserves for the record. On
this machine that is the state of both repositories (D1's measurement).

What makes it worth reporting rather than filing as a disclosed trade-off is the
comment sitting directly above it:

    # Where nothing is recorded, HEAD alone stands: abstaining here means
    # "no land was confirmed", which is this gate's QUIET direction, and a
    # gate that cannot answer must round toward quiet.

The code returns `True` — *a land WAS confirmed*. The commit message repeats the
same inversion ("guard-idle-land confirms no land"). The direction is quiet
either way, so I am not claiming the gate misfires; I am claiming the only thing
a future reader has to go on says the opposite of what the branch shipped.

`inflight.py` keeps the same HEAD fallback and is the contrast that makes this
one a defect rather than a design note: it names the guess in the output the
caller reads (`tip is: the main checkout's HEAD, because ...`). One consumer
discloses its own answer where it is used. The other discloses it backwards in a
comment.

---

## 6. Beyond the page

These are not defects under rule 1 — I cannot quote a sentence of the spec they
break. Three of them decide whether the runner can be trusted as a gate, so I am
not burying them.

### F3. A test fixture writes into the operator's live registry — and the commit says it cannot

`/Users/alex/.claude/state/workspaces/integration.json` **right now** contains:

    "why": "the land-completeness fixture"        x4
    "repo": "/private/var/folders/.../land-completeness.rSiULs/clean/repo"   (and three more)
    "recorded_at": "2026-09-12T12:44:07Z" ... "2026-09-12T12:44:24Z"

Four records for temporary directories that no longer exist, in the operator's
durable state. `engine/scripts/land-completeness.test.sh` sandboxes
`RICHOS_WORKTREE_LEDGER` (line 87) and **not** `RICHOS_WORKSPACES_DIR`, then
calls, at line 132:

    "$WORKSPACES" integration --repo "$repo" --branch main \
        --why "the land-completeness fixture" >/dev/null 2>&1 || true

The `--why` string in the fixture is the `why` in the live file. The commit
message for `f0ee9622` says *"two of them gained a sandbox registry so the
recording can never reach the operator's real one"* — two of three, and the third
is this one. I did not run that suite, deliberately; the artifact was already
there when I took my baseline.

### F4. The runner — four ways it can be quiet when it should be loud

All four reproduced in throwaway git repositories built from this branch's own
`workspace-probes.py`.

**F4a — a probe driven as a child process is not discovered.** Two probes
committed under `docs/verification/`, both red, both loading the library (one
in-process for contrast, one via `subprocess`):

    probes discovered:        1 (1 in the working tree, 0 on other branches)
    other files under docs/verification/ that are not probes of this library: 2

The second and third are counted as "not probes". Adding `workspaces.py` to the
docstring does not help — discovery needs a `DRIVES` token as well, and every
token in that tuple is an in-process loader spelling. A shell-level probe of
`workspaces.sh` would be invisible by construction.

**F4b — the author check is a string anybody can type.** Baseline: one red probe,
`certification-frank-realprobe-2026-09-12.py`, runner exits 1. Then one line
appended to `docs/verification/workspace-probe-retirements.tsv` by a hand that is
not mine:

    certification-frank-realprobe-2026-09-12.py<TAB>frank<TAB>obsolete, trust me

    RETIRED    docs/verification/certification-frank-realprobe-2026-09-12.py    0.0s
    every discovered probe ran, and every one of them is green.
    exit 0

`author_of()` parses the name out of the **probe's filename**
(`certification-([a-z]+)-`). Signing it `zach` is correctly refused (UNRUNNABLE,
exit 1) — but nothing ties the signature to the reviewer: not git authorship of
the TSV line, not a commit, not anything. The runner's central protection —
*"an engineer failing a probe is the person least able to tell 'this assertion
is obsolete' from 'I broke this'"* — is enforced against typing the wrong name,
not against the engineer.

Note also the last line above: **"every discovered probe ran, and every one of
them is green"** is printed when a probe was retired and did not run. That is the
same false all-clear as the zero-probe case they already fixed, on the other
branch of the same function.

**F4c — retirement is per-file, so it cannot express the truth.** `retired` is
keyed on `os.path.basename(p.name)` and a match skips the probe entirely. My own
file needs four cases retired and one kept; the mechanism offers all or nothing.
Obsolescence is a property of a case; the record can only hold it at the file.

**F4d — a probe that disappears reads as a probe that passed.** Nothing pins the
expected count. `probes discovered: 10` going to `9` — a discarded reviewer
branch (point 7), a deleted file, a renamed one — changes no verdict and no exit
code, and the all-clear line reads identically.

**F4e — same-path shadowing, silently.** `branch_probes` skips any path the tree
already has (`if not rel.endswith(".py") or rel in have: continue`). A reviewer's
red probe on `cc/frank-review`, and a file at the same path committed in the
tree:

    probes discovered:        1 (1 in the working tree, 0 on other branches)
    GREEN      docs/verification/certification-frank-shadowed.py    0.1s
    every discovered probe ran, and every one of them is green.
    exit 0

Nothing names the branch, nothing says the two copies differ. This is not only an
attack: the benign accident is a reviewer landing probe v1, then committing v2
under the same filename on a new branch — the runner runs v1 and says so to
nobody. The party who owns the tree is the party failing the probes.

### F6. `argv-scenario` probes cannot go red on an expectation

`OBSERVED` is excluded from both `red` and `stuck`, so a probe of that shape
never affects the exit code. The runner says this out loud in its own verdict
text, so it is disclosure rather than a lie — but it means the gate's real
strength is the subset of probes that assert, and a reader looking at
"10 probes discovered, exit 0" is not being told the denominator.

---

## 7. What I ran, with exit codes

    scripts/inflight-ack.sh --sha 4c70bfc2... --impact none ...                     0
    python3 engine/scripts/workspace-probes.py --list --show-all                    0
    python3 engine/scripts/workspace-probes.py                                      1   (3 RED)
    python3 engine/scripts/workspace-probes.py --lib <regressed copy>               1   (5 RED; both c4 probes)
    python3 engine/scripts/workspace-probes.py --only zzz-no-such                   1   (NOTHING WAS RUN)
    bash    engine/scripts/workspace-probes.test.sh                                 0   (11/11)
    python3 -B engine/scripts/lib/workspaces.test.py                                0   (58 run, 0 failed)
    bash    engine/scripts/lib/workspaces.mutation.sh                               0   (43/43 load-bearing)
    python3 -B c4-probe.py   <branch lib>                                           0   (6/6)
    python3 -B c4-probe.py   <2bc413df lib>                                         1   (1/6)
    python3 -B c4-control.py <branch lib>                                           0   (6/6)
    python3 -B c4-control.py <2bc413df lib>                                         1   (2/6)
    python3 -B recorded-attr.py <branch lib>                                        1   (5/10)
    python3 -B recorded-attr.py <2bc413df lib>                                      1   (5/10)
    python3 -B recorded-attr-withrecord.py <branch lib> serial-stray serial-side serial-rename   0   (3/3)
    python3 -B unlanded-branches.py --entity-root <sandbox> --format hook  (4c70bfc2)  0   STATUS partial N 0
    python3 -B unlanded-branches.py --entity-root <sandbox> --format hook  (2bc413df)  0   STATUS swept   N 1
    bash    engine/scripts/land-completeness.sh --repo <sandbox>                    0   (NOT EXAMINED (1))
    runner attacks A/A2/B/B2/C/codex in throwaway repositories                      as quoted above
    baseline + two re-checks of ~/.claude/state/workspaces                          identical

## 8. The verdict

**NOT CERTIFIED.**

The five items are done and they are done well. What refuses this is D1: the
round moved every consumer onto the recorded branch, and one of those consumers
sits under the Stop-hook that enforces point 5. On both repositories on this
machine it now returns nothing, and the hook turns nothing into *"clear again"*.
A gate that goes quiet is worse than a gate that is red, and this branch makes it
quiet by default on the only two repositories that matter here.

D2 is smaller and is mostly a claim that contradicts its own code. F3 is a live
contamination of the operator's durable state by a test fixture, with the commit
message asserting it cannot happen. F4 is the runner: real, and effective against
the regression class it was built for — I proved that by regressing the library
and watching it go red — but it is quiet against a probe hidden by shape, a
probe shadowed by a same-named file in the tree, a probe that disappears, and a
retirement signed by whoever is holding the pen.

My rulings stand as written: `floor-timing`, `serial-stray`, `serial-side` and
`serial-rename` are obsolete; `outside-stray` is still valid and stays. I have
written no retirement line, because the mechanism cannot retire a case and
retiring the file would drop five green assertions to buy one green exit code.

— frank-opus-c5
