NOT CERTIFIED

# Certification — the regression runner, attribution order, the refused-call window, the per-body-of-work record, and every consumer

| | |
|---|---|
| **SHA under review** | `4c70bfc296bb8f6b4f7c6297ccc80aa7d1805483` (`cc/zach-opus-g3`), seven commits over `2bc413df` |
| **Yardstick** | `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, sha256 `957d21a4e76262c28bb8b69cd37249cc87eea326e12c927c2997ad9887b10978`. The copy inside this repository was not read as the spec, not edited, and not touched — and it is not the same document; see Beyond the page, B4. |
| **Reviewer** | Sage, from `/Users/alex/ab/richos-wt/sage-opus-c5` on branch `cc/sage-opus-c5`, cut from the SHA under review. Frank reviews the same SHA independently; I did not read his work. |
| **Installed / merged / pushed / deployed** | Nothing. No `install.sh`. Nothing written into `/Users/alex/ab/richos/engine`. The main checkout was read-only throughout: `git -C /Users/alex/ab/richos status --porcelain` → 0 lines, HEAD `dcabcbd99056928a9872cd94c1f3a385f8b21069` on `main`, unchanged from my previous round. |
| **Sandboxing** | Every probe and suite ran with `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR`, `GIT_CONFIG_GLOBAL` and `RICHOS_WORKSPACES_DIR` redirected into scratch, and the runner itself was invoked with `RICHOS_WORKSPACES_DIR` pointed at scratch as a second belt. `~/.claude/state/workspaces` was fingerprinted with `find … \| xargs stat` before the first command and after the last: **11 entries before, 11 after, every name, size and mtime identical.** It was neither created nor touched. |

## The verdict in one paragraph

**The four spec items hold. The item that was built to stop the last two rounds
repeating does not, and it fails in exactly the way I was asked to test it for.**
Items 1 to 4 are right and I re-derived each of them: attribution no longer waits
for the record, a refused call narrows the window instead of widening it, the
integration branch is recorded per BODY OF WORK and bound by id so a correction
reaches an agent in flight while a second body cannot reach backwards into the
first, and every consumer that needs to know whether work has landed now asks one
implementation — I re-derived the enumeration with my own grep and found no ninth
consumer, and each of the six exclusions holds on the question it asks rather than
on the pattern it uses. My own D3 from last round is item 3 and I judge it
satisfied; it is the cleanest thing in the branch. The runner is item 0, and the
brief's instruction for it was *"Undiscovered is worse than red: try to hide a
probe from it."* I tried twice and succeeded twice, with matched controls: one
line of text — `# not-a-probe: superseded elsewhere` — added by the very person
failing a probe makes it vanish, with no author check of any kind, while the
identical act done through the documented route is author-checked and refused by
name; and a probe that drives the library through `sys.argv` without ever
spelling the literal string `workspaces.py`, which is the natural way to write
one, is never discovered at all. In both cases the run printed *"every discovered
probe ran, and every one of them is green"* and exited 0. The affordance the
runner's own header offers as the answer to this — *"counted and named under
`--show-all`, never silently dropped"* — prints its heading and nothing beneath
it: on this repository the counter says 242 and `--show-all` names zero. The
CEO's page says nothing about probes or runners, so by his first rule none of
this is a defect against his page and all of it is in **Beyond the page**. It is
still the reason I cannot certify the round: item 0 is one of the five items, the
hole is the one it exists to close, and the test that found it is the test the
brief asked me to run.

## My retirement ruling on each of my red cases

Both of my probes are retired, by me, in
`docs/verification/workspace-probe-retirements.tsv`. Retirement is per FILE — the
runner keys on the probe's basename — so a file's live cases had to go somewhere
before it could be retired, and they did:
`docs/verification/certification-sage-runner-round-2026-09-12.probe.py`, green
10/10, discovered by the runner without any registration step.

### `certification-sage-attribution-2026-09-12.probe.py` — **OBSOLETE**

This is my c2 probe, committed at `b728514b` under the title *"CERTIFIED: a
branch is the agent's by possession."* Three reasons, and the first is the one
that matters.

1. **Its premise is possession, and possession was deleted with my agreement.**
   `84e12d32` replaced attribution by possession with attribution by recorded
   CREATION, and my own c3 certification opens *"The mechanism is right.
   Creation is the fact to record."* The probe's harness drives `barrier()`
   alone and never `observe()`, because under possession there was no second
   half to drive. Under the Pre/Post pair there is nothing for a Pre-only
   harness to observe, and the measurement says so plainly: with the fixture
   otherwise untouched, **every one of its eight scenarios now reports
   `A.created_branches []`** — including `stray-plain-branch` and
   `stray-switch-away`, whose entire subject was what got attributed.
2. **Its RED is a fixture that predates point 14's mandatory record.** Two
   scenarios call `ws.land()` outside a `try`, and `land()` now refuses where no
   integration branch is recorded, which point 14 has required before the first
   spawn since `2bc413df`. Adding the two lines point 14 asks of anybody starting
   a body of work — and nothing else — makes all eight scenarios exit 0:

   ```
   ENTITY = mkrepo("entity"); OTHER = mkrepo("other"); session()
   +ws.record_integration(ENTITY, "main", "sage adaptation", SID)
   +ws.record_integration(OTHER,  "main", "sage adaptation", SID)
   ```

   Eight scenarios, eight exits of 0, `OVERALL=0`.
3. **It can never certify anything, by the runner's own account.** Its shape is
   `argv-scenario`, which the runner reports as OBSERVED with the words *"this
   probe ASSERTS NOTHING, so it can neither regress nor certify."* Nothing is
   carried forward because there is no assertion in it to carry.

A note I am putting on the record rather than in a retirement: an
`argv-scenario` probe can only go red by RAISING, so whether it blocks the gate
at all depends on which of its `land()` calls its author happened to wrap in a
`try`. In this file two were wrapped and two were not. That is an accident of my
typing in the c2 round, not a property of the build.

### `certification-sage-recorded-attribution-2026-09-12.probe.py` — **OBSOLETE as a file; one case is NOT obsolete and is carried forward**

This is my c3 probe (`356920a8`), whose docstring says outright that it goes red
by design at the build it was written against. Five of its ten cases are red on
this branch. I ruled on each, with the fixture as committed and again with the
integration branch recorded, which is the only way to tell "the build broke it"
from "point 14 changed what a fixture owes".

| Case | Ruling | Why |
|---|---|---|
| **S2 floor-vs-dev** | **OBSOLETE — the premise is gone** | Its whole subject is the first-registration floor: *"The floor writes `main`; the work integrates on a dev branch recorded after."* The floor was deleted at `556d3e62` because my own D1 said point 14's *"Nothing infers it and nothing guesses it"* forbids it. With no floor there is no record to read and the case raises `TypeError: 'NoneType' object is not subscriptable` on its first observation line. Its ASSERTION (`verdict == "landed"`) is now satisfiable and is asserted by R4. |
| **S3 parallel-calls** | **OBSOLETE as written — fixture, and the property is preserved** | Red with the fixture as committed, **green the moment the integration branch is recorded**: `land → landed`, `branches after the land ['main']`, sweep empty. The window fix is real; the fixture owed point 14 a record it was written before. Carried forward verbatim as **R5**, green. |
| **S5 rich-then-commits** | **STILL VALID — and out of this round's scope by the brief** | Red both ways. A ref Rich cuts at the agent's own unlanded tip is attributed to the agent, and a discard then deletes it along with a commit Rich made on it after the run ended. The brief names this out of scope for this round, so I do not raise it as a finding — but its premise has not gone anywhere, and retiring it silently would be how a known limitation becomes an unknown one. It is carried forward as **R10**, which asserts the in-scope half (the discard ends the pending state and RECORDS every tip it deleted, so the destroyed commit is on the record) and PRINTS the out-of-scope half under `[OUT OF SCOPE]` rather than asserting it away. |
| **S9 no-record-recovers** | **OBSOLETE as written — fixture, and the property is preserved** | It fails on `os.unlink(.../integration.json)` with `FileNotFoundError`, because it was written to remove a file the deleted floor used to create and nothing writes any more. With the fixture adapted the case is **green**: `land after merging onto dev/work → landed`, `workspace gone → True`. The refusal heals, which is point 14 working. Carried forward, merged with S2/S6/S8, as **R4**. |
| **S10 parallel-side-branch** | **OBSOLETE — the predicate is superseded by my own c4 case A** | Red both ways, and this is the one I most wanted to be a real defect. It is not. Its predicate is `"tmpwork" not in branches`, written when the parallel-call window lost the side branch entirely and nobody would ever come back for it. The window is fixed — `created_branches ['tmpwork']` — and the land now REFUSES with `pending ['zach-opus-s10']`, because tmpwork carries a commit that reached no integration branch. Deleting it is what point 8 forbids: *"Deletion therefore never loses anything that was meant to land."* My own c4 case A is the same scenario with the predicate stated correctly — the harm is a land that reports LANDED with nothing pending — and it is green on this branch. Carried forward as **R6**, which uses the c4 predicate and then merges tmpwork and watches the land succeed. |

The remaining five cases (S1, S4, S6, S7, S8) are green and would have been lost
with the file. S1, S4 and S7 are carried forward unchanged as R1, R2 and R3; S6
and S8 are subsumed by R4, which asks the question they were both circling — with
no floor, is anything inferred before the first spawn, and does recording it
afterwards heal the land.

### The runner's exit after my rulings

A retirement only binds where the `.tsv` is committed, so the runner will keep
exiting 1 on `cc/zach-opus-g3` until this branch lands — which is correct, and is
what makes a retirement an act rather than a flag. On my branch, which carries
them:

```
RETIRED    docs/verification/certification-sage-attribution-2026-09-12.probe.py
RETIRED    docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py   [dev/workspace-spec]
GREEN      docs/verification/certification-sage-runner-round-2026-09-12.probe.py
RED        docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py  [dev/workspace-spec]
EXIT=1
```

The one remaining red is Frank's, and only Frank may retire it. I did not read it
and I express no view on it.

## The runner's output, as I ran it

Sandboxed, from my worktree, against this branch's library. Full log:
`docs/verification/certification-sage-runner-round-2026-09-12-logs/runner-as-i-ran-it.txt`.

```
$ python3 engine/scripts/workspace-probes.py
workspaces.py under test: …/sage-opus-c5/engine/scripts/lib/workspaces.py
probes discovered:        10 (5 in the working tree, 5 on other branches)
other files under docs/verification/ that are not probes of this library: 242

GREEN      certification-frank-attribution-2026-09-12-probe.py                        3.6s
GREEN      certification-frank-four-fixes-2026-09-12-probe.py                         2.1s
RED        certification-sage-attribution-2026-09-12.probe.py                         4.8s
           a scenario failed to run: exit 1
GREEN      workspace-attribution-seven-cases.probe.py                                 4.4s
GREEN      workspace-call-window-and-recorded-target.probe.py                         2.3s
RED        certification-frank-recorded-attribution-2026-09-12-probe.py               3.6s  [dev/workspace-spec]
GREEN      certification-frank-window-and-target-…-logs/c4-control-no-refused-call.py 3.0s  [cc/frank-opus-c4]
GREEN      certification-frank-window-and-target-2026-09-12-probe.py                  3.0s  [cc/frank-opus-c4]
RED        certification-sage-recorded-attribution-2026-09-12.probe.py                3.0s  [dev/workspace-spec]
GREEN      certification-sage-window-and-target-2026-09-12.probe.py                   3.8s  [cc/sage-opus-c4]
EXIT=1
```

That is the count the brief reported and the three reds it named. After my
retirements and my replacement probe:
`…-logs/runner-after-my-retirements.txt`, 11 discovered, 2 RETIRED, 8 GREEN,
1 RED (Frank's), `EXIT=1`.

## Verdict per item

| Item | Verdict |
|---|---|
| **0 — the regression runner** | **It does the job it was named for and fails the job it was ASKED to be judged on.** It discovers by being committed, it drives both shapes, it names the branch a probe came from, it refuses a retirement signed by anyone but the probe's author (I watched it refuse one), it blocks on UNRUNNABLE as loudly as on RED, and its own suite passes 11/11. Two ways to hide a probe from it, both reproduced with matched controls and both ending in `exit 0` with the all-clear printed — B1 and B2 below. |
| **1 — attribution stops waiting for the record** | **Holds.** `p14-attribution-waits-for-the-record` mutates it back and `test_point_14_attribution_never_waits_for_the_record` goes red; both are in the 43/43. My R4 measures the consequence end to end: with nothing recorded, a ref created in the window is still attributed, the land refuses and NAMES the recording command, and recording it afterwards makes the same land succeed and takes the workspace and the branch with it. |
| **2 — a refused call stops widening the window** | **Holds.** `_before_set` unions the open windows instead of intersecting them, and the last snapshot always joins that union, so a leaked window can only ever NARROW what is attributed. That is the safe direction, and the file says why in those terms. My R9 drives 81 Pres against a cap of 64, watches the live call's own window get evicted, and the ref created inside it is still attributed at the Post. |
| **3 — the record is per BODY OF WORK (my D3)** | **Holds, and it is the best-argued change in the branch.** The indirection is the whole design and the code says so: an agent binds the work's ID, never its branch, so the branch stays live and correctable for an agent in flight while a second body of work gets a different id and cannot reach backwards. I asked both halves for the first time. **R7**: with `main` recorded and an agent registered, a `--correct` to `dev/work` reaches the already-registered agent and its land goes from REFUSED to landed. **R8**: STARTING a second body (`dev/two`) leaves the first agent bound to `entity-001` and it still lands against `main`. Both green; `p14-second-body-of-work-moves-the-first` is the matching mutant. |
| **4 — every consumer asks the library** | **Holds, and the enumeration survives being re-derived.** Nine call sites now route to one implementation: `integration_for()` in `workspaces.py`, called by `completion-proof.py`, `land-completeness.py`, `land-residue-gate.py` (through `lc.analyze`), `unlanded-branches.py`, `inflight.py`, `guard-idle-land.py`, `guard-unresolved-claims.py`, `guard-ci-red-lands.sh` (through `workspaces.sh integration-branch`) and `land-completeness.sh`. My own grep found one file his did not name — `hooks/guard-worktree-removal.sh` — and it is a false positive: its only hit is a COMMENT about a false-positive class, and it classifies whether a command is destructive, never whether work has landed. |

Command and real output for the four spec items, run from my worktree:

```
$ bash engine/scripts/lib/workspaces.test.sh        → Ran 58 tests … OK
                                                      === workspaces spec tests: 58 run, 0 failed ===   EXIT=0
$ bash engine/scripts/lib/workspaces.mutation.sh    → [43 mutant(s), 8 at a time, wall 4m24.9s]
                                                      === mutation: all 43 properties proven load-bearing ===   EXIT=0
$ bash engine/scripts/workspaces-e2e.test.sh        → workspaces-e2e: 47 passed, 0 failed   EXIT=0
$ bash engine/scripts/workspace-probes.test.sh      → === workspace-probes tests: all 11 passed ===   EXIT=0
```

Full log: `…-logs/four-suites-as-i-ran-them.txt`. I ran the mutation suite twice
without meaning to and both runs reported 43/43, four and a half minutes apart,
which is at least evidence that it is not order-dependent.

## The five points I was told to judge rather than accept

### 1. The runner itself — I hid a probe from it, twice

Reproduction, self-contained, throwaway repository under `$TMPDIR`, touching no
real repository and no state:

```
$ bash docs/verification/certification-sage-runner-round-2026-09-12-logs/hide-a-probe-from-the-runner.sh
```

Captured output beside it as `.txt`. Four steps, each with the runner's exit code:

```
A. CONTROL      2 discovered, 1 RED                                    exit=1
B. ATTACK 1     1 discovered, "every discovered probe … green"         exit=0
C. --show-all   heading printed, NOTHING under it (counter says 1)
D. ATTACK 2     1 discovered, "every discovered probe … green"         exit=0
D-control       2 discovered, 1 RED                                    exit=1
```

Both attacks and both controls are in Beyond the page as **B1** and **B2**; C is
**B3**. What I want on the record here is the shape they share, because it is the
same shape in both: the runner's protection is a rule about WHO may retire a
probe, and both holes are ways to stop a file being a probe at all — at which
point there is nothing for the rule to protect. The docstring already says this
better than I can: *"Undiscovered is strictly worse than red — a red probe stops
a commit and an invisible one does not exist."* The zero-probe refusal added in
this round is a real fix and it caught attack 1 when the hidden probe was the
ONLY probe; with one other probe present it does not fire. On this repository
there are ten others.

### 2. Reading other local branches — sound as a stopgap, unsound as the gate's basis

**It is not "cc/ and dev/".** The code skips the current branch and anything
under `codex/`, and reads **every other local branch**, `main` included. I
confirmed both halves:
`bash …-logs/the-gate-depends-on-local-branches.sh` puts a red probe on a branch
named `stale/old-round` — neither `cc/` nor `dev/` — and it is read and BLOCKS;
the identical probe on `codex/thing` is correctly never read, which is spec point
2 honored.

Reading branches is the right call for the situation it was built for, and the
justification in the file is exactly right: five of the ten probes — including
both of the ones written to judge this very round — live only on branches this
round has not merged, so a tree-only runner would be blind to precisely the
evidence that matters. On this repository, `--tree-only` drops discovery from 11
to 6.

But it cannot be what a GATE rests on, for a reason that comes out of the CEO's
own page. Spec point 4: *"Landed means the workspace AND the branch are deleted
— automatically, with nothing left undecided."* The population the runner reads
is therefore guaranteed to be destroyed, by the same system it is gating, at the
moment each reviewer's work is landed. Step I of the reproduction is that
moment: the branch is deleted, and the same commit, the same tree and the same
library now run green with nothing printed to say a probe was dropped. A probe
survives only by being MERGED into the tree — which is the right answer and is
what makes the branch-reading a bridge rather than a foundation. Two further
consequences worth naming: the verdict is not a function of the commit under
test, so two people on the same SHA get different answers depending on which
branches they happen to have locally; and a stale branch nobody remembers can
block a round on an assertion three rounds dead, with no way to retire it except
its author, who may be long gone.

### 3. The reversal — the revert is complete

`bda86802` made the cap age-based (`_MAX_OPEN_CALLS = 4096`,
`_MAX_CALL_AGE = RICHOS_WORKSPACES_CALL_AGE or 6h`) and `bac187f3` took it out
again. The revert is complete in the executable code and in the knobs:

- `git diff 2bc413df..4c70bfc2 -- engine/scripts/lib/workspaces.py | grep -E '^[-+].*(_MAX_OPEN|_evict_old_slots|getmtime|_open_slots)'` returns **only** the three unrelated `_take_snapshots` lines. `_MAX_OPEN_CALLS`, `_evict_old_slots` and the mtime sort are byte-identical to the parent.
- `grep -rn 'RICHOS_WORKSPACES_CALL_AGE\|_MAX_CALL_AGE' engine docs` → **no residue**. The env knob is gone, not merely unread.
- What remains is the comment explaining why, which is the right thing to keep.

**And the reasoning is right, which matters more than the revert being tidy.**
Under `_before_set`'s union, `latest` — the most recent snapshot the agent ever
took, and therefore the LARGEST before-set — always joins, so the extra priors
are subsumed and the number of open windows barely moves the answer. Evicting the
OLDEST is, under union semantics, evicting the window that contributes least.
I measured the case the reversal turns on rather than reasoning about it alone:
R9 with the shipped library attributes `spare` at the Post; the same case against
a copy with one line changed (`paths = [p] if os.path.exists(p) else
_open_slots(key)[:1]` → `else []`) attributes `[]`. Matched control, so R9 is
discriminating the fallback and not the weather.

One correction to the claim, offered as precision and not as a defect: with the
fallback removed the end-of-run pass still recovers the ref, so the OUTCOME at
the land is the same either way. What the fallback buys is that
`created_branches` is right WHILE the agent is running, which is what the point-3
sweep and any in-flight decision read. R9 prints both values side by side so the
two can never be confused again.

### 4. The deleted property — `p03-end-of-run-consumes-one-window`, and deleting it was right

38 mutants at `2bc413df`, 43 at `4c70bfc2`; six added, and exactly one removed:

```
$ comm -23 <names at 2bc413df> <names at 4c70bfc2>
p03-end-of-run-consumes-one-window
```

The property it asserted was that consuming EVERY open window at the end of the
run, rather than one, is load-bearing. **Deleting it was right, for a reason
stronger than the one the commit message gives.** The old mutant's stated harm
was that with one window the ref "would be attributed to nobody" — but the one
window `_take_snapshots` falls back to is the OLDEST, whose before-set is the
SMALLEST, so under union semantics it attributes MORE, not less. The assertion
was not merely dead; it had been inverted by the change to `_before_set` in the
same branch. A mutant asserting the opposite of what the code does proves
nothing and would have been re-anchored round after round.

The replacement, `p03-no-end-of-run-observation`, removes the end-of-run
observation entirely, which IS still load-bearing — and the four drifted mutants
were re-anchored rather than dropped, three of which were reporting MUTATION
TARGET ABSENT and so proving nothing while looking green. That is the right
instinct and it is the same instinct as the round.

The one place I would not repeat the commit message's wording: *"WHICH windows
are consumed no longer changes what is attributed"* is true up to a ref that
existed when an earlier call opened and was deleted before the last snapshot, in
which case the union differs. It is a corner nobody will hit, and the conclusion
does not move.

### 5. The consumers — re-derived, and the exclusions hold

I re-derived the enumeration with my own grep over `engine/scripts`, excluding
test and mutation files:

```
$ grep -rn --include=*.py --include=*.sh -E \
    "is-ancestor|is_ancestor|--merged|branch --contains|TRUNK_NAMES|INTEGRATION_REFS|\
WATCHED_BRANCH|refs/heads/main|refs/heads/master|:-main\}|default=\"main\"|default='main'" scripts/
```

49 hits across 14 files, plus a second pass for `rev-parse main`, `rev-list …
main`, `MAIN_BRANCH=` and the word `merged`, which added `escalations.py`,
`turn-manifest.py`, `guard-stated-actions.py`, `collect-worktree-artifacts.sh`
and `contract-integrity-probe.sh` as candidates. Every one of those five is prose
or an unrelated verb; none decides landedness.

**The two he found and was not given are real and I confirm both.**
`unlanded-branches.py`'s `TRUNK_NAMES = ("main", "master")` picked whichever
existed — a file assuming main by any other name — and `inflight.py`'s `assess()`
measured each worktree's `landed` against the main checkout's HEAD, which is the
moving value point 14 exists to replace. `land-completeness.sh`'s `:-main`
default is the same thing in shell. Nine call sites, one answer.

**The exclusions, ruled one by one:**

| Excluded | My ruling |
|---|---|
| `hooks/guard-stale-staging.sh`, `owned-state-checks/staging-current.sh` | **Correct.** `STAGING_MAIN_REF:=refs/heads/main` asks "is the deployed staging behind this checkout's main", which is a deployment question. A body of work integrating on a dev branch does not change what staging deploys from. |
| `land-completeness-measure.py` | **Correct.** It scores historical transcripts to produce a false-positive RATE, for the R6 requirement that a blocking behavior is measured before it ships. It decides no landedness about any live body of work. |
| `lib/ci-red.py`, `lib/ci-surface.py`, `lib/ci-run-records.py` | **Correct, and the reasoning is the subject rather than the pattern — which is the right axis.** All three carry `--branch default="main"`, the same shape that made `land-completeness.py --main` a defect. The difference is that they answer "is CI red on branch B", which is not landedness, and `guard-ci-red-lands.sh` — the consumer that does ask about landing — now passes them the recorded branch. I checked their other callers (`ci-surface-watch.sh`, `ci-status.sh`, `ci-run-record-check.sh`) and none of them uses the answer to decide whether work has landed. The exclusion holds on the question; it would not hold on the pattern, and the commit message is careful to say so. |

The one thing I would flag rather than accept is the sentence *"Loading
workspaces.py by path is repeated in five consumers. That is a duplicated LOADER,
not a duplicated ANSWER."* That is true today and the distinction is the right
one. It is also the exact shape that a future round will be tempted to inline
"just this once", and the page's *"None of them is allowed its own answer"* would
then be broken by five files that each look like a loader. Nothing to fix; worth
a mutant one day.

## Defects against the CEO's page

**None found.** Everything I could break, I could not break against a sentence of
`worktree-spec-2026-09-11.md`. The two red cases of mine that survive a recorded
fixture (S5, S10) are, respectively, declared out of this round's scope by the
brief and a predicate my own later case states correctly. The three reds the
brief named are accounted for: two retired by me here, one Frank's.

## Beyond the page

None of these breaks a sentence of his page, and none is offered as one.

**B1 — a probe is hidden by one unauthored line, and the run prints the
all-clear.** `is_workspaces_probe()` returns False for any file containing
`not-a-probe: <two words>` — anywhere in it, comment or string, with no check of
who wrote it. The documented route to neutralize a probe (`workspace-probe-
retirements.tsv`) is author-checked and refused by name when signed by anyone
else; this route is not checked at all. The asymmetry is the finding: the person
with the motive to silence a probe is the person failing it, and the cheap route
is the unguarded one. Reproduced with a matched control in
`…-logs/hide-a-probe-from-the-runner.sh`, steps A and B: the same file, one line
apart, `exit=1` then `exit=0` with *"every discovered probe ran, and every one of
them is green."*

**B2 — a probe that does not spell `workspaces.py` is never discovered.**
Discovery is `(names the library) AND (drives the library)`. This round widened
the DRIVES half precisely because indirect access was being missed — *"a probe
reaching the library through `getattr` … was SILENTLY NOT DISCOVERED. Undiscovered
is strictly worse than red"* — but the NAME half is still a literal substring
test, and in an `and` the narrower conjunct governs. A probe that takes the
library as `sys.argv[1]` and loads it with `spec_from_file_location`, which is
how both reviewers' argv probes work and the most natural way to write one, is
invisible unless the string happens to appear in a docstring. Step D with its
control: identical file, one string concatenation apart, invisible then RED.

**B3 — `--show-all` names nothing, so the hiding is invisible even when you
look.** The header prints *"other files under docs/verification/ that are not
probes of this library: 242  (--show-all names them)"*, and the `--show-all`
block filters with `if rel not in have: continue` where `have` is the set of
PROBE names — so the only files it can ever print are probes excluded by
`--only`, and never a non-probe. On this repository: counter 242, names printed
**0**. The runner's docstring promises the opposite (*"counted and named under
`--show-all`, never silently dropped"*), and it is the one affordance that would
have surfaced B1.

**B4 — the spec copy inside this repository is missing the sentence this round
implements, and its recorded pin matches neither document.**
`docs/plans/worktree-spec-2026-09-11.md` here differs from the canonical page by
exactly one paragraph — the closing three lines of point 14:

> **Every part of the system that needs to know whether work has landed asks the
> same question: is it in the branch recorded for this work? None of them is
> allowed its own answer, and none of them assumes main.**

That is the sentence item 4 exists to satisfy, quoted verbatim in the docstrings
of `completion-proof.py`, `guard-unresolved-claims.py`, `unlanded-branches.py`
and `integration_for()` — all of which live in the repository whose copy of the
page does not contain it. Three shas, no two equal: canonical
`957d21a4e76262c2…`, mirror here `6d190cdde551ac30…`, and the pin recorded in
`docs/verification/workspace-spec-implementation-2026-09-11.md` names a third,
`b3fd6cd33b8c1135`. I read only the canonical page and did not touch the mirror
or the pin, as the brief required.

**B5 — the runner's own suite tests the hiding route as a feature and never tests
who may use it.** W9 asserts *"a declared non-probe is not run; a BARE marker with
no reason exempts nothing"*, and W5 asserts that a retirement signed by the wrong
author is refused. There is no W-case for a declaration signed by the wrong
author, because a declaration carries no author; and W2 asserts the non-probe
COUNT without asserting that `--show-all` names them, which is why B3 shipped
green.

## What I ran, with exit codes

Every command from `/Users/alex/ab/richos-wt/sage-opus-c5`, sandboxed as
described above.

| Command | Exit |
|---|---|
| `~/.claude/richos-engine/scripts/inflight-ack.sh --sha 4c70bfc296bb… --impact none …` | 0 — ledger row written |
| `python3 engine/scripts/workspace-probes.py --list` | 0 — 10 discovered (5 tree, 5 branches) |
| `python3 engine/scripts/workspace-probes.py` | **1** — 3 RED, as the brief said |
| `python3 -B <c3 probe> <lib> S2 S3 S5 S9 S10` (as committed) | 1 — 0/5 held |
| `python3 -B <c3 probe, fixture records the branch> <lib>` (all ten) | 1 — 5/10; S3 and S9 now GREEN, S2/S5/S6/S8/S10 as ruled above |
| `python3 -B <c2 probe, fixture records the branch> <lib> <each of 8 scenarios>` | 0 for all eight — `OVERALL=0` |
| `python3 -B docs/verification/certification-sage-runner-round-2026-09-12.probe.py` | 0 — **held 10/10** |
| the same probe, R9 only, against a library with the unpaired-Post fallback removed | 1 — `created_branches []`, the matched control |
| `bash engine/scripts/lib/workspaces.test.sh` | 0 — 58 run, 0 failed |
| `bash engine/scripts/lib/workspaces.mutation.sh` (twice) | 0, 0 — all 43 properties load-bearing, both runs |
| `bash engine/scripts/workspaces-e2e.test.sh` | 0 — 47 passed, 0 failed |
| `bash engine/scripts/workspace-probes.test.sh` | 0 — all 11 passed |
| `bash …-logs/hide-a-probe-from-the-runner.sh` | 0 — the runner exits 1, 0, 0, 1 across its four steps |
| `bash …-logs/the-gate-depends-on-local-branches.sh` | 0 — the runner exits 1 then 0 across the branch deletion |
| `python3 engine/scripts/workspace-probes.py` (after my retirements) | **1** — 2 RETIRED, 8 GREEN, 1 RED (Frank's) |
| `git -C /Users/alex/ab/richos status --porcelain` | 0 — no output, HEAD `dcabcbd99056…` on `main` |
| `find ~/.claude/state/workspaces \| xargs stat`, before and after | 11 entries both times, every name, size and mtime identical |
