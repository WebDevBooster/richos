NOT CERTIFIED

# Certification — the gate's integrity, `cc/zach-opus-g4` @ `6fd5aef8`

**Under test:** `cc/zach-opus-g4` @ `6fd5aef8fb6dc37934dff8f0f78cf876981dbe25`, four commits over
`dev/workspace-spec` @ `507ec6df`.
**Reviewed from:** `/Users/alex/ab/richos-wt/sage-opus-c6`, branch `cc/sage-opus-c6`, cut at
`6fd5aef8` — so every command below ran against the exact tree under test.
**The yardstick:** `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, 14 points. The
copy in this repository is a pinned mirror and I read it as nothing.
**I did not read Frank's work.**

**The verdict in one line.** Item 1 holds, and holds well — the abstention is now data, carried in
its own fields, rendered in its sibling's words, with paired twins and three dedicated mutants, and
I reproduced the defect and the fix live on this machine. Item 4 holds byte for byte — its one soft
spot is that `L21`'s corpus misses two real writers, both of which happen to be sandboxed. Item 3's
mechanism works and fails closed, but it is unavailable on the very file that inherited the five
assertions it was built to protect. **Item 2 does not hold.** All four routes past the gate are
open, and three of them are open to the party failing the probe — not by impersonation, which is the
residual he disclosed, but by `git branch wip` and, for one of them, by an uncommitted line signed
with the wrong name. Item 2 is the round's headline and it is the item I can falsify with one
command, so the round is not certified.

---

## The runner, as I ran it

```
cd /Users/alex/ab/richos-wt/sage-opus-c6
python3 engine/scripts/workspace-probes.py
```

`exit 1`. Full output: `certification-sage-gate-integrity-2026-09-12-logs/runner-output-6fd5aef8.txt`.
The headline, verbatim:

```
workspaces.py under test: /Users/alex/ab/richos-wt/sage-opus-c6/engine/scripts/lib/workspaces.py
probes discovered:        11 (11 in the working tree, 0 on other branches)
branch under test:        cc/sage-opus-c6
declared not-a-probe:     1 (each named below; a declaration is checked against git, never read)
probes DELETED from history and not retired: 0
other files under docs/verification/ that are not probes of this library: 241  (--show-all names them)

DECLARED   docs/verification/workspace-probe-regression-2026-09-12-logs/adapt-c3-probes-to-record-the-branch.py
           4c70bfc296bb, witnessed by cc/frank-opus-c6, cc/zach-opus-g4, dev/workspace-spec
           not-a-probe: this BUILDS
GREEN      docs/verification/certification-frank-attribution-2026-09-12-probe.py                                    3.5s
GREEN      docs/verification/certification-frank-four-fixes-2026-09-12-probe.py                                     1.8s
RED        docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py                           3.4s
           exit 1
GREEN      docs/verification/certification-frank-window-and-target-2026-09-12-logs/c4-control-no-refused-call.py    2.9s
GREEN      docs/verification/certification-frank-window-and-target-2026-09-12-probe.py                              2.9s
RETIRED    docs/verification/certification-sage-attribution-2026-09-12.probe.py                                     0.0s
           sage [1329ec67b86e, witnessed by cc/frank-opus-c6, cc/zach-opus-g4, dev/workspace-spec]: ...
RETIRED    docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py                            0.0s
           sage [1329ec67b86e, witnessed by cc/frank-opus-c6, cc/zach-opus-g4, dev/workspace-spec]: ...
GREEN      docs/verification/certification-sage-runner-round-2026-09-12.probe.py                                    5.2s
GREEN      docs/verification/certification-sage-window-and-target-2026-09-12.probe.py                               3.6s
GREEN      docs/verification/workspace-attribution-seven-cases.probe.py                                             4.6s
GREEN      docs/verification/workspace-call-window-and-recorded-target.probe.py                                     2.3s
```

**8 GREEN, 2 RETIRED, 1 RED, exit 1 — the numbers in the brief reproduce exactly.** The one RED is
`certification-frank-recorded-attribution-2026-09-12-probe.py`, `5/10 cases hold`, and it is red for
the reason the brief says it should be. It stays red.

**The witness printed with my two retirements is real, and it means what it says.**

```
git log -1 --format='%H%n%an <%ae>%n%ad%n%s' 1329ec67b86e
  1329ec67b86e25b802e3e3d29f3c74b094f53a4f
  Alex Booster <webdevbooster@gmail.com>
  Sat Sep 12 15:00:48 2026 +0100
  Both of my probes retired, by me, with the premise that no longer exists named

git show --stat --format='' 1329ec67b86e
  docs/verification/workspace-probe-retirements.tsv | 15 +++++++++++++++
  1 file changed, 15 insertions(+)

git branch --contains 1329ec67b86e
  cc/frank-opus-c6   cc/sage-opus-c6   cc/zach-opus-g4   dev/workspace-spec
```

That is my own retirement commit from last round, it touches one file and that file is under
`docs/verification/`, and it is contained in `dev/workspace-spec` — the branch this body of work
integrates on, which is not the branch under test. So A1, A2 and A3 are each answered by something
real here. **The witness list is longer than the brief says** (`cc/frank-opus-c6, cc/zach-opus-g4,
dev/workspace-spec`, not `dev/workspace-spec` alone) because those branches exist in this
repository; `witness_branches()` sorts and prints the first three. That is a presentational
difference, not a disagreement — and it is also the first sign of what §Item 2 below turns into a
break: the runner prints branch NAMES and never asks what a branch is.

---

## Item 1 — an abstention never reads as "clear". **HOLDS.**

I reproduced the defect and the fix on this machine, with the real repositories, by running the base
library and this round's library side by side against the same entity root.

```
python3 <507ec6df:engine/scripts/lib/unlanded-branches.py> --entity-root /Users/alex/ab/richos --format line
  (no output)                                                                   exit 0
python3 engine/scripts/lib/unlanded-branches.py        --entity-root /Users/alex/ab/richos --format line
  NOT EXAMINED - 1 repository could not be answered for, so this is NOT a clean
  main; it is an unread one. richos: no branch is recorded as the one this
  repository's work integrates on, so 'has this landed?' has no reference to be
  asked against (point 14). Record it: workspaces.sh integration --repo
  /Users/alex/ab/richos --branch <main|dev/...> --why '<this body of work>'
  Detail: scripts/unlanded-branches-lint.sh                                     exit 4
```

Identical result for `/Users/alex/ab/femcboost`. In `--format hook`, the base emits `STATUS partial`
/ `N 0` / `SUMMARY` empty and nothing else; this round adds `NOTEXAMINED 1`, `UKEY` and `UNEXAMINED`.
**So the claim that this was the LIVE state and not a corner is true, and I checked it rather than
took it** — neither of the two repositories the engine governs has a recorded integration branch, so
the base's silence was the answer being given in production.

At the lint surface:

```
<base>/engine/scripts/unlanded-branches-lint.sh /Users/alex/ab/richos            -> exit 0
engine/scripts/unlanded-branches-lint.sh        /Users/alex/ab/richos            -> exit 2
```

Exit 0 was the collapse the script's own exit-code table forbids. It is now 2, the text report grows
a `NOT EXAMINED (1)` section that is printed even when empty, and `--format line` maps the sweep's
new 4 onto 2 and never onto 0.

At the hook surface I did not scaffold a fake adopted root; the suite does it, and the suite is
green with the right shape of coverage:

```
engine/scripts/hooks/unlanded-branches.test.sh        -> exit 0, 37/37, 12 mutants
  U18 the sweep carries the abstention as DATA and names the repository it could not read
  U19 FIRING: over an abstention it says COULD NOT LOOK / NOT EXAMINED — the sibling's own words
  U20 PAIRED TWIN: the same repository, branch RECORDED, and now the branch itself is named
  U21 PAIRED TWIN: read end to end with nothing ahead, the word 'clear' is still reachable
  U22 a sweep with findings AND an unread repository names both, and calls the list a floor
  L05 a repository with no recorded integration branch exits 2 and prints NOT EXAMINED, never 0
  PASS abstention-not-counted — removing it turns "U18" red
  PASS abstention-is-a-no-op  — removing it turns "U19" red
  PASS lint-unread-exits-zero — removing it turns "L05" red
```

**U21 is the case that makes this item honest.** The cheap fix for "it said clear" is to delete the
word; U21 requires the word `clear` to still be reachable over a repository read end to end. And the
vocabulary claim checks out: `NOT EXAMINED` is what `land-completeness.sh:287` prints for the same
abstention, and the sweep now uses that string in every format.

**And the engineer's aside is right, though "fully red" overstates it.** I ran the base suite:

```
git archive 507ec6df | tar -x -C <tmp> ; <tmp>/engine/scripts/hooks/unlanded-branches.test.sh
  19 passed, 12 FAILED                                       exit 1
  === mutation: 4 property(ies) NOT proven load-bearing, 5 proven ===
```

Red on the base, and nobody saw it. **His explanation for why is not the mechanism he names.**
`engine/scripts/run-all-tests.sh:261` discovers suites with
`find "$ENGINE_ROOT" -type f -name '*.test.sh'`, so this suite is in the full pass, and I found no
list in the tree from which it is excluded. What made the red invisible is that the full pass had
not been run — which is a cost the CEO has already ruled on, not an exclusion.

---

## Item 2 — the gate cannot be silenced by the party failing it. **DOES NOT HOLD.**

Reproduction, self-contained, sandboxed, with a matched control before each attack:

```
docs/verification/certification-sage-gate-integrity-2026-09-12-logs/four-routes-reopened.sh \
    /Users/alex/ab/richos-wt/sage-opus-c6 "$(mktemp -d)"
  -> exit 0    "4 of 4 routes re-opened"
```

Output: `certification-sage-gate-integrity-2026-09-12-logs/four-routes-reopened-output.txt`. Each
fixture is a throwaway git repository holding one RED probe authored `frank` and one GREEN probe
authored `sage`, with HEAD on `cc/zach-opus-toy` — the engineer's branch. `RICHOS_WORKSPACES_DIR` was
aimed inside the scratch directory as a belt; it was never created, so nothing here drove the
library's writers.

### Route 2 — A3 is answered by `git branch wip`

A3 is `witness_branches()` at `engine/scripts/workspace-probes.py:424`: local branches containing the
commit, minus `codex/`, minus the one string `mine`. **It never asks what a branch is, who owns it,
or whether it is anything more than a second pointer at the same commit.**

```
# the engineer, on the branch under test, commits a DOCS-ONLY retirement signed 'frank'
STEP A — no other branch exists:
    UNRUNNABLE certification-frank-toy-2026-09-12.probe.py
      the retirement of this probe names the right author ('frank') and is NOT attributable to
      that author. A3: the commit that wrote it (…) exists only in cc/zach-opus-toy, the branch
      under test.                                                              exit 1
STEP B — git branch wip
    RETIRED    certification-frank-toy-2026-09-12.probe.py
      frank [c756f3117cb4, witnessed by wip]: Obsolete: the premise changed.
    every discovered probe ran, and every one of them is green.                 exit 0
```

**This narrows the residual he disclosed to almost nothing.** He wrote that an engineer "could create
a branch named `cc/frank-opus-anything`" and argued that two things stand against it: the witness is
printed, and naming a branch after another teammate is deliberate impersonation rather than a
shortcut. Neither argument survives the measurement. No reviewer's name is needed anywhere in the
branch — `wip` works, and so would `tmp`, and so would the branch an engineer already has lying
around. And the printed witness, which is the thing he says stands in for the check, reads
`witnessed by wip`: a reviewer scanning that line sees a branch name that looks like housekeeping,
not like a forged signature. **The record he is relying on records the wrong thing.** It records that
some branch contained the commit, which is exactly what the attack manufactures.

### Route 4 — MISSING is silenced by an UNCOMMITTED line signed with the wrong name

`engine/scripts/workspace-probes.py:804`:

```python
missing = [(q, c) for q, c in deleted_probes(root, mine)
           if os.path.basename(q) not in retired]
```

`retired` is `retirements(root)`, parsed from the **working-tree** file. Membership is the whole
test. A1 is not asked, A2 is not asked, A3 is not asked, and the `<who>` field is not compared
against anything.

```
# the engineer commits the deletion of frank's probe
CONTROL:
    probes DELETED from history and not retired: 1
    MISSING    certification-frank-toy-2026-09-12.probe.py                      exit 1
# then one line appended to the working-tree TSV, never committed, signed 'zach':
#   certification-frank-toy-2026-09-12.probe.py<TAB>zach<TAB>I deleted it and I say it was obsolete.
     M docs/verification/workspace-probe-retirements.tsv
    probes DELETED from history and not retired: 0
    every discovered probe ran, and every one of them is green.                 exit 0
```

This is the weakest of the four to defeat and the loudest in its claim: W16 in the suite reads *"A
PROBE THAT WAS DELETED IS MISSING, AND MISSING BLOCKS. Route 4: the file simply disappears, and the
only thing that changes is a count nothing was checking."* The count is now checked, and the check
is turned off by an unstaged edit. The whole `deleted_probes` / MISSING mechanism is new in this
round — `git show 507ec6df:engine/scripts/workspace-probes.py` contains no occurrence of `missing`,
`MISSING` or `deleted_probes` — so the hole arrived with the fix.

### Route 1 — the marker rides in the same commit as the engine change

A2 is deliberately not asked of a `not-a-probe:` marker (`attributable(..., docs_only=False)` from
`marker_authority()`), so the commit that breaks a probe may be the commit that annotates it. Only A1
and A3 apply, and A3 is route 2's `git branch`.

```
# ONE commit that appends to engine/scripts/lib/workspaces.py AND appends
#   "# not-a-probe: this asserts nothing any more"
# to frank's probe. Then: git branch wip
    DECLARED   certification-frank-toy-2026-09-12.probe.py
    every discovered probe ran, and every one of them is green.                 exit 0
```

`probes discovered` silently drops from 2 to 1. **Ruling on the residual he disclosed here:** his
reasoning is sound and his conclusion is not. He is right that refusing a marker committed alongside
the engine change it belongs to would produce a waiver, and right that a waiving habit kills a
check — this repository has the instances. But the consequence is that the marker path is now
strictly weaker than the retirement path, and a marker needs no name at all, so route 1 is a
one-commit silencer that leaves the green sentence intact. A check that is weaker where it is easier
to attack is not a residual; it is the route. What to do instead is not mine to say.

### Route 3 — a probe driven through `getattr` is still not discovered

This one needs no engineer at all. The runner's header says:

> *a probe reaching the library through `getattr`, or naming an entry point without calling it, was
> SILENTLY NOT DISCOVERED … **So loading the library at all counts**, which is something every probe
> of it must do however it then drives it.*

`engine/scripts/workspace-probes.py:293` is `return loads and drives_entry`, and `drives_entry`
requires `\b<entry point>\s*\(`. **Loading the library does not count. It is one half of an AND.**

```
# a probe that loads the library from argv[0] and drives it through
#   getattr(m, "register" + "_spawn")   — never spelling an entry point with a paren
by hand:  F1 FAILS -- this is the assertion that should block                   exit 1
runner:   GREEN certification-sage-toy-2026-09-12.probe.py
          every discovered probe ran, and every one of them is green.           exit 0
```

`--show-all` names the file under "not probes of this library", which is the mitigation the header
offers — but the exit code is 0 and the green sentence is printed, and the header's whole argument is
that **undiscovered is worse than red.**

### Ruling: is an author check that any teammate can forge worth having?

**Yes, keep it — but not for the reason given, and not while it is the load-bearing part.**

The name check earns its place as a *typo and copy-paste* check. It caught nothing adversarial in my
tests and it does not need to: a retirement line is hand-written prose in a shared file, a line
copied from another probe is the ordinary mistake, and a check that names the mismatch costs nothing
and prevents a silent wrong retirement. `W21`'s refusal of a case the probe does not have is the same
kind of value, and I watched it fire on my own tree (§Item 3).

**What is not worth having is the claim built on top of it.** He argues the witness and the branch
name stand where a check cannot. Measured, they do not: the witness is a branch name the attacker
chooses and it prints as housekeeping, and no impersonating name is required. So the honest statement
of what A1–A3 buy is narrower than the round's:

* **A1 is real and cheap.** An unstaged edit retires nothing — except where A1 is not asked, which is
  route 4.
* **A2 is real** for retirements, and absent for markers, which is route 1.
* **A3 is a name comparison dressed as a provenance check.** It is worth exactly one `git branch`.

The false-assurance risk is not hypothetical, and it is not about a malicious engineer. It is that a
reviewer reading `RETIRED … witnessed by <branch>` has been told that line is the record standing in
for a check, and the line is satisfiable by accident — an engineer who happens to have a second
branch pointing at its own tip passes A3 without ever intending to. **A check whose bypass is
indistinguishable from ordinary housekeeping will be bypassed by ordinary housekeeping.**

### Ruling on the second residual — the probe that ignores its case arguments

**Correct as disclosed, and I verified it rather than read it.** A probe whose only failing case is
retired, honestly, by its own author on its own branch, landed:

```
RED  certification-sage-deaf-2026-09-12.probe.py
     exit 1 with 2 of 3 case(s) requested (X1, X3). Either this probe ignores the case arguments
     the runner passes, or a case nobody retired is genuinely red. case 'X2' retired by sage
     [d3be11fd8f17, witnessed by cc/sage-review, main]: Obsolete: X2 asserted a premise that no
     longer exists.                                                             exit 1
     | argv it was given: ['X1', 'X3'] -- IGNORED
     | ran: X1, X2, X3 ; failed: X2
```

It fails closed, it names both explanations instead of choosing, and the witness is printed. That is
the right shape and I have nothing against it. (It also happens to be the one place in this round
where an honest witness — a reviewer's own branch, landed on main — was produced and printed, which
is what A3 was supposed to be about.)

---

## Item 3 — retirement is per CASE, not per file. **WORKS, AND DOES NOT REACH MY CASE.**

The mechanism is right and it is properly controlled: `W19`–`W25` in
`engine/scripts/workspace-probes.test.sh`, `exit 0`, 30/30 with 10 mutants proven load-bearing. One
case retired leaves the probe running, its other cases still decide, the retired case is not asked, a
case the probe does not have is refused rather than ignored, every case retired is said as a
whole-file verdict rather than arrived at by subtraction, and the per-case path is checked exactly as
hard as the whole-file one. I drove it end to end myself in the `deaf` fixture above and it did all of
that.

**And it is not available on the file that inherited the five assertions it was built for.**

```
docs/verification/certification-sage-gate-integrity-2026-09-12-logs/per-case-unavailable.sh \
    /Users/alex/ab/richos-wt/sage-opus-c6
  === what the runner reads as this probe's cases:
             shape=argv author=sage cases=0
  === the probe DOES take case arguments — its own interface:
      474:    wanted = argv or [n.split()[0] for n, _f, _r in RUNNERS]
  === an honest per-case retirement of R4, signed by its own author:
      runner exit 1
      UNRUNNABLE docs/verification/certification-sage-runner-round-2026-09-12.probe.py
        its retirement names case 'R4', which this probe does not have. Its cases are: (none the
        runner can read). A retirement that matches nothing is a typo or a line copied from
        another probe, and either way it retires nothing.
```

`cases_of()` reads `^CASES\s*=\s*\[...\]`. My carried-forward probe declares its ten cases as a
`RUNNERS` list of tuples, so the runner reads none of them, and the `W21` refusal then fires on an
honest retirement. **My ruling last round was that retiring a file would cost five green assertions.
Those assertions now live in `certification-sage-runner-round-2026-09-12.probe.py`, and for that file
the trade is not removed — it is worse.** Before, I could retire the file and lose ten assertions.
Now, naming one case turns the file UNRUNNABLE and blocks the whole gate, so the only move available
to me is still the whole-file line. It fails closed and it names the reason, which is the right
direction. Both of Frank's in-tree probes read `cases=0` too, though for them the shape is the reason
— an in-tree probe is one process for the whole file, so there is nothing for a case argument to
select. Three of the nine runnable probes are outside the mechanism, and mine is the one where that
costs something.

The one place it matters most is fine: the RED probe,
`certification-frank-recorded-attribution-2026-09-12-probe.py`, declares `CASES = [...]` and the
runner reads all ten, so Frank's descoped case is retirable per case when he rules on it.

---

## Item 4 — no test writes to the operator's real state. **HOLDS, BYTE FOR BYTE.**

```
# before: ~/.claude/state/workspaces recursive shasum + stat
bash engine/scripts/land-completeness.test.sh
  === mutation: all 4 properties proven load-bearing ===
  === land-completeness tests: all 23 passed ===                                exit 0
# after
REGISTRY CONTENT IDENTICAL
REGISTRY STAT IDENTICAL
fixture rows in events.jsonl BEFORE: 4    AFTER: 4
integration.json present BEFORE: no       AFTER: no
```

The four cases are the right four, and both absences have positive controls:

```
PASS  L20  every fixture recording went to the SANDBOX registry; the operator's real one is untouched
PASS  L22  POSITIVE CONTROL: the same search names a planted fixture record and stays silent on an empty registry
PASS  L21  none of the 10 suites driving a registry WRITER leaves RICHOS_WORKSPACES_DIR un-redirected
           (declared as test data, and named rather than dropped: hooks/guard-worktree-removal.test.sh)
PASS  L23  POSITIVE CONTROL: the scan flags a mention-only suite and a bare marker, and clears only
           the declared and the sandboxed
```

`REAL_REGISTRY` captured before the override is exported is the detail that makes L20 mean anything,
and the mutant `no-registry-sandbox` aims the registry outside the sandbox rather than at the
operator's — a mutation harness that reproduced the incident for real would have been a second
incident. That is a good call and it is documented as one.

**I asked L21's question my own way, and the corpus it answers over is incomplete. There is an
instance on this machine.** L21's INVOKE half recognizes four spellings of the command —
`workspaces.sh`, `$WORKSPACES`, `$WS`, `$WORKSPACES_SH` — and its other half recognizes the library's
entry points called in process. **The tree already uses a fifth spelling, `$WS_PY`, in five suites**,
and two of them run a writer through it:

```
docs/verification/certification-sage-gate-integrity-2026-09-12-logs/l21-corpus-gap.sh \
    /Users/alex/ab/richos-wt/sage-opus-c6/engine/scripts        -> exit 1

  hooks/guard-sealed-worktree.test.sh   (sandboxed anyway: YES)
      :92    python3 "$WS_PY" --entity "$ENTITY" --session "$SID" integration --repo "$ENTITY" \
                 --branch main --why "the lock-out suite's body of work"
      :123   python3 "$WS_PY" --session "$SID" pause dev-opus-g7 --until "the quota reset"
  hooks/guard-resume-isolation.test.sh  (sandboxed anyway: YES)
      :492   python3 "$WS_PY" --session "$SESSION_ID" pause dev-held --until "the CEO's answer"
```

(The other four files the loose predicate names are its own false positives — a prose `land`, a
`$FIN_REPORT` followed by the word `stop` — and the script prints every hit in full so a reader
decides rather than a second regex.)

**L21's verdict today is correct**: both missed suites export `HOME` and `CLAUDE_CONFIG_DIR` into
their own sandbox, so nothing reaches the operator's registry, and my own before/after snapshots
agree. **What is wrong is the shape of the answer.** `L21` prints *"none of the 10 suites driving a
registry WRITER"*, and the corpus is 10 because two writers are invisible to it — not flagged, not
cleared, absent. The `≥3` floor exists to refuse an answer over an empty corpus and cannot see a
corpus that is merely short.

This is the same mistake the commit message says it corrected. It found the pattern keyed on the file
name `workspaces.sh`, wrote *"No suite in this tree spells the invocation that way; they all hold the
path in a variable"*, and then enumerated three variable names. The tree has four. **It is not a
defect — there is no incident, and the CEO's page says nothing about test hygiene — but it is a
finding with an instance, not a hypothetical, and the enumeration will need re-deriving every time a
suite is added.**

**Registry hygiene across my whole review.** Every command I ran was bracketed by a recursive
snapshot of `~/.claude/state/workspaces`. At the end:

```
diff <first snapshot> <last snapshot>   ->  IDENTICAL: not created, not touched
shasum -a 256 ~/.claude/state/workspaces/events.jsonl
  4dfa7993994ddf3db700924b70d49af4da765d7f58cd7812cffd6a3410a50bb3   (unchanged throughout)
```

---

## The three things he asked me to judge

### `events.jsonl` still carries the four fixture rows — **right call.**

`record_integration()` writes `integration.json`; `all_integration_records()` and
`integration_for()` read `integration.json`; `events.jsonl` is written by `_event()` with the
docstring *"The history, never the authority"* and is read by nothing in
`engine/scripts/lib/workspaces.py`. The four rows naming
`/private/var/folders/.../T/land-completeness.*/…` are therefore inert for every consumer, and I
confirmed the live consequence: both real repositories abstain with *"no branch is recorded"*, which
is the same answer they would give if those rows did not exist.

**And there is a better reason than inertness.** The fix removed the four records from
`integration.json` — the file is now absent entirely — so the append-only rows in `events.jsonl` are
**the only surviving evidence on this machine that the incident happened.** Editing them would have
deleted the record of the defect while claiming to clean up after it. He was right not to, and right
to report them.

One thing he did not flag as clearly as he flagged the rows he left: **removing the records from
`integration.json` is itself a write to the operator's live state**, by an agent, in the round whose
subject is agents not writing to the operator's live state. It is disclosed in the commit message
(*"the four records were removed from integration.json"*) and I am not calling it wrong — the records
were garbage pointing at deleted temp directories. I am noting that the round contains one
unwitnessed mutation of the state it is protecting, and that no artifact records when or by what
command.

### `land-completeness.test.sh` cites an `L17` that was never written — **confirmed, and still live.**

```
grep -n L17 engine/scripts/land-completeness.test.sh
   74:#       planted case whose answer is known. The ids skip L17..L19 (an L17 named
  131:# (L17..L19 are deliberately unused: the comment in mkrepo() below already names
  132:# an L17 that was never written, and reusing the id would make that reference
  175:    # does -- one command, before anything else happens in it. L17 is the case
  176:    # where nothing is recorded, and it asserts the ABSTENTION.
```

Lines 74 and 131–132 disclose it. **Line 175–176 is still a positive claim of coverage that does not
exist**, and the coverage it claims is precisely this round's item 1 — *"L17 is the case where nothing
is recorded, and it asserts the ABSTENTION."* No case in this suite asserts that abstention. The
abstention is asserted in the sibling suite, as `U18`–`U22` and `L05`. Reserving the id rather than
reusing it is the right instinct; leaving the sentence that names it as if it were written is a claim
a reader has no way to disbelieve. This is the one finding in my report that a reader of the file
would hit first and trust.

### "A commit message claiming 18/18 for a suite with 16 ids" — **the two numbers are swapped, and the real error is smaller.**

```
git log 507ec6df..6fd5aef8 --format='%h%n%B' | grep -nE '[0-9]+/[0-9]+'
  workspace-probes.test.sh   23/23 -> 30/30
  workspace-probes.test.sh   10 cases -> 23/23 … 7/7 properties load-bearing
  land-completeness: 16 cases -> 23/23 … 4/4 properties load-bearing
  after:   37/37              (12 of 12 properties proven load-bearing)
```

**There is no `18/18` in any of the four commit messages.** `18` is what the BASE suite prints, which
I measured by running it — with `CLAUDE_CONFIG_DIR` aimed at a decoy, because the base suite is the
one that writes into whatever config directory resolves and running it against the operator's would
have been a second incident rather than a measurement:

```
CLAUDE_CONFIG_DIR=<decoy> bash <507ec6df>/engine/scripts/land-completeness.test.sh
  === land-completeness tests: all 18 passed ===                                exit 0
  18 PASS lines, 18 distinct ids (L1, L1b, L2..L16, L9b)
  operator registry: UNTOUCHED
  written into the decoy: state/workspaces/{lock,events.jsonl,integration.json}
  occurrences of "the land-completeness fixture" in that integration.json: 2
```

So: the commit message's `16 cases` is wrong — the base suite had **18** — and it understates rather
than overstates, which is the harmless direction. The round's own side is right: 22 case ids
(`L1, L1b, L2..L16, L9b, L20..L23`), 22 `PASS` lines, plus one increment for the mutation harness as a
whole at `land-completeness.test.sh:622`, printed as `all 23 passed`. **The brief's version of this
finding does not reproduce**; what does is one understated count in one commit message.

**And that decoy run is the best independent confirmation of item 4 I have.** The base suite really
does create `integration.json` and `events.jsonl` under whatever config directory it resolves, and it
really does put two `"the land-completeness fixture"` records in them. The premise of item 4 is not
taken on the engineer's word.

### Case ids that are prefixes of each other — **the trap is real, and latent here.**

`engine/scripts/lib/mutation-harness.sh:255` is `if ! grep -q "FAIL  $want" "$dir/out.txt"`, a raw
substring:

```
printf '  FAIL  L20  the case that is really red\n' | grep -q "FAIL  L2"   -> matched
printf '  FAIL  L1b  a different case\n'            | grep -q "FAIL  L1"   -> matched
```

So a mutant wanting `L2` would be satisfied by `L20` going red, and one wanting `L1` by `L1b`. **No
mutant in `land-completeness.mutation.sh` currently uses `L1` or `L2` as its `want`** — they use
`L20`, `L23`, `L23`, `L22` — so nothing is wrong today and I am not calling it a defect. Two things
make it worth writing down anyway. The suite's own header says the ids *"carry no letter suffix,
because mutation-harness.sh greps `FAIL <id>` as a raw string and `L20` would match `L20a`"* — and
`L1b` and `L9b` are letter-suffixed ids in that same file. And the sibling suite in the same round,
the one that lost nine mutants to this exact trap, zero-pads everything (`U01`–`U22`, `C01`–`C08`,
`L01`–`L05`) and is immune. One round, two files, two conventions, and the one that states the rule
is the one that breaks it.

---

## Defect against the CEO's page

**One, and it is not this round's doing.** I am holding to the rule: a finding is a defect only where
I can quote his sentence.

> **Point 14:** *"The branch a body of work integrates on is RECORDED when that work starts, before
> its first agent is spawned. Nothing infers it and nothing guesses it"*

Neither repository has that record, and agents are spawned into both.

```
python3 engine/scripts/lib/unlanded-branches.py --entity-root /Users/alex/ab/richos --format hook
  NOTEXAMINED  1
  UNEXAMINED   NOT EXAMINED - 1 repository could not be answered for … richos: no branch is
               recorded as the one this repository's work integrates on, so 'has this landed?'
               has no reference to be asked against (point 14).
python3 engine/scripts/lib/unlanded-branches.py --entity-root /Users/alex/ab/femcboost --format hook
  NOTEXAMINED  1                        (same sentence, femcboost)
```

```
git worktree list
  /Users/alex/ab/richos                       dcabcbd9 [main]
  /Users/alex/ab/richos-wt/frank-opus-c6      6fd5aef8 [cc/frank-opus-c6]
  /Users/alex/ab/richos-wt/sage-opus-c6       6fd5aef8 [cc/sage-opus-c6]
  (+ five codex/ worktrees, which point 2 puts out of reach)
git merge-base --is-ancestor cc/zach-opus-g4 dev/workspace-spec   -> not an ancestor
```

Two `cc/` workspaces of `/Users/alex/ab/richos` are live, a third branch (`cc/zach-opus-g4`) carries
the work under test with its workspace already gone, and the branch this body of work integrates on —
`dev/workspace-spec`, which `507ec6df` is a land onto — exists and is being merged onto. It is simply
not recorded, so every consumer that asks "has this landed?" abstains. **Recording it is an operator
act (`workspaces.sh integration --repo … --branch …`), not a hook**, so this is not downstream of the
expected-RED contract probe.

**This round is what makes it impossible to keep missing.** Before `6fd5aef8` the same state printed
`UNLANDED-BRANCH WATCH: clear again`. I am recording it as a defect because his sentence is plainly
broken and I can reproduce it in one command — and recording that the round under test is the reason
I can see it at all.

---

## Beyond the page

Everything in Item 2 and Item 3 above belongs here by the CEO's rule: his page says nothing about
probes, retirements or runners, so no sentence of it is broken by a forgeable witness. **The
certification question is different from the defect question, and Item 2 fails the certification
question** — the round claims the gate cannot be silenced by the party failing it, and it can be, in
one command, four different ways. That is why the first line of this file reads as it does.

Three smaller things, none of them a defect:

* **`probes discovered` is a count with two meanings.** A declared `not-a-probe:` file is subtracted
  from it (2 → 1 in the route-1 fixture) while a retired probe is not. Both numbers are printed
  honestly in their own lines; it is the word "discovered" that does two jobs.
* **`--show-all` names the route-3 file and the exit code still says green.** The naming is the
  mitigation the header offers for a probe the runner cannot classify, and it is a good one — but it
  is advisory output in a mechanism whose whole design principle is that advisory output is what
  failed twice.
* **The declared non-probe in this tree is witnessed by three branches including the branch under
  test's siblings.** `4c70bfc296bb, witnessed by cc/frank-opus-c6, cc/zach-opus-g4, dev/workspace-spec`
  is an honest case (a builder committed with the runner), and it passes for the honest reason. I
  name it only because it is the same print that route 1 forges.

---

## What I ran, with exit codes

| command | exit |
|---|---|
| `~/.claude/richos-engine/scripts/inflight-ack.sh --sha 6fd5aef8… --impact none …` | 0 |
| `python3 engine/scripts/workspace-probes.py --list` | 0 |
| `python3 engine/scripts/workspace-probes.py` | **1** (1 RED, as required) |
| `python3 engine/scripts/workspace-probes.py --only certification-sage-runner-round` (+ R4 retirement) | **1** (UNRUNNABLE) |
| `bash engine/scripts/workspace-probes.test.sh` | 0 — 30/30, 10 mutants |
| `bash engine/scripts/hooks/unlanded-branches.test.sh` | 0 — 37/37, 12 mutants |
| `bash engine/scripts/land-completeness.test.sh` | 0 — 23/23, 4 mutants |
| `bash engine/scripts/hooks/guard-worktree-removal.test.sh` | 0 — 94/94 |
| `bash <507ec6df>/engine/scripts/hooks/unlanded-branches.test.sh` | **1** — 19 passed, 12 FAILED |
| `CLAUDE_CONFIG_DIR=<decoy> bash <507ec6df>/engine/scripts/land-completeness.test.sh` | 0 — all 18 passed, and it wrote into the decoy |
| `python3 <507ec6df>/…/lib/unlanded-branches.py --entity-root /Users/alex/ab/richos --format line` | 0 (the collapse) |
| `python3 engine/scripts/lib/unlanded-branches.py --entity-root /Users/alex/ab/richos --format line` | 4 |
| `<507ec6df>/engine/scripts/unlanded-branches-lint.sh /Users/alex/ab/richos` | 0 (the collapse) |
| `engine/scripts/unlanded-branches-lint.sh /Users/alex/ab/richos` | 2 |
| `engine/scripts/unlanded-branches-lint.sh --help` | 0 |
| `…-logs/four-routes-reopened.sh <tree> <scratch>` | 0 — **4 of 4 routes re-opened** |
| `…-logs/per-case-unavailable.sh <tree>` | 0 |
| `…-logs/l21-corpus-gap.sh engine/scripts` | **1** — two real writers outside L21's corpus |
| `git log -1 … 1329ec67b86e`, `git show --stat 1329ec67b86e`, `git branch --contains 1329ec67b86e` | 0 |
| registry snapshot diff, first vs last | 0 — **identical** |

Every attack ran in a throwaway git repository under the session scratchpad. The one command that
touched the tree under test (`per-case-unavailable.sh`) appended a single line to the working-tree
TSV and reverted it; `git status --porcelain` is empty. `~/.claude/state/workspaces` was neither
created nor touched, verified by recursive `shasum` and `stat` before and after every run.

---

## What would change this verdict

Nothing in Items 1, 3 or 4. Item 2 is the whole of it: the round says the gate cannot be silenced by
the party failing it, and `four-routes-reopened.sh` exits 0 saying otherwise. The fix is not mine to
prescribe and I have not. When it is claimed closed again, that script is the thing to run: it exits
0 while the routes are open and 1 when they are not, and each case carries the control that would
catch a gate that simply refuses everything.
