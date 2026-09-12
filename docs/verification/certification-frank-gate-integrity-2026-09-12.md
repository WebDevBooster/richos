NOT CERTIFIED

# Frank — gate integrity, `cc/zach-opus-g4` @ `6fd5aef8fb6dc37934dff8f0f78cf876981dbe25`

**Branch under test:** `cc/zach-opus-g4` @ `6fd5aef8fb6dc37934dff8f0f78cf876981dbe25`
(four commits over `dev/workspace-spec` @ `507ec6dfc1482ffb6ca7126fdce8651fd845d281`)
**Reviewed from:** `cc/frank-opus-c6` at the same tip, worktree `/Users/alex/ab/richos-wt/frank-opus-c6`
**The spec:** `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`. I diffed the
in-repository mirror against it before using either: **byte-identical**, and the mirror does carry
point 14's closing paragraph, so the premise of this round's brief is true.

**The headline, and it is one sentence.** Items 1, 3 and 4 hold. **Item 2 does not.** Two of the
four routes it claims to have closed still work, and I ran one of them to `exit 0` with a false
"every discovered probe ran, and every one of them is green." Worse for the engineer's own
reasoning than the forgery he disclosed: **A3 — the check his defense of both residuals rests on —
is defeated by the ordinary review handoff, with no forged branch, no impersonation and no extra
step.** It refuses nothing in this round today. His stated forgery recipe, meanwhile, does not
work as written.

---

## 1. The runner, as I ran it

```
$ cd /Users/alex/ab/richos-wt/frank-opus-c6
$ python3 engine/scripts/workspace-probes.py
```

```
workspaces.py under test: /Users/alex/ab/richos-wt/frank-opus-c6/engine/scripts/lib/workspaces.py
probes discovered:        11 (11 in the working tree, 0 on other branches)
branch under test:        cc/frank-opus-c6
declared not-a-probe:     1 (each named below; a declaration is checked against git, never read)
probes DELETED from history and not retired: 0
other files under docs/verification/ that are not probes of this library: 241  (--show-all names them)

DECLARED   docs/verification/workspace-probe-regression-2026-09-12-logs/adapt-c3-probes-to-record-the-branch.py
           4c70bfc296bb, witnessed by cc/sage-opus-c6, cc/zach-opus-g4, dev/workspace-spec
           not-a-probe: this BUILDS
GREEN      docs/verification/certification-frank-attribution-2026-09-12-probe.py                                    3.7s
GREEN      docs/verification/certification-frank-four-fixes-2026-09-12-probe.py                                     1.8s
RED        docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py                           3.3s
           exit 1
GREEN      docs/verification/certification-frank-window-and-target-2026-09-12-logs/c4-control-no-refused-call.py    2.8s
GREEN      docs/verification/certification-frank-window-and-target-2026-09-12-probe.py                              2.9s
RETIRED    docs/verification/certification-sage-attribution-2026-09-12.probe.py                                     0.0s
           sage [1329ec67b86e, witnessed by cc/sage-opus-c6, cc/zach-opus-g4, dev/workspace-spec]: Obsolete: ...
RETIRED    docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py                            0.0s
           sage [1329ec67b86e, witnessed by cc/sage-opus-c6, cc/zach-opus-g4, dev/workspace-spec]: Obsolete as a FILE ...
GREEN      docs/verification/certification-sage-runner-round-2026-09-12.probe.py                                    5.3s
GREEN      docs/verification/certification-sage-window-and-target-2026-09-12.probe.py                               3.7s
GREEN      docs/verification/workspace-attribution-seven-cases.probe.py                                             4.1s
GREEN      docs/verification/workspace-call-window-and-recorded-target.probe.py                                     2.1s

... (the REFUSAL block, verbatim from the runner) ...

RED (a prior probe now fails):
    docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py   author: frank
EXIT=1
```

**8 GREEN, 2 RETIRED, 1 RED, 0 UNRUNNABLE, 0 MISSING, exit 1.** The lead's count reproduces
exactly. The two `RETIRED` verdicts each name sage's commit `1329ec67b86e` and a witnessing
branch, which is the behavior the round claims.

### My own RED probe stays red, and I did not take anyone's word for it

```
$ git diff --name-only 507ec6df..6fd5aef8 | grep -c 'certification-frank-recorded-attribution'
0
```

The round touches **zero** files under that name, and it touches no
`engine/scripts/lib/workspaces.py` either — the twelve paths in the diff are the TSV, four suites,
two mutation harnesses, `notice-unlanded-branches.sh`, `lib/unlanded-branches.py`,
`unlanded-branches-lint.sh` and `workspace-probes.py`. Its failing case list is byte-identical
before and after the round:

```
at 6fd5aef8: 5/10 cases hold; BROKEN: outside-stray, floor-timing, serial-stray, serial-side, serial-rename
at 507ec6df: 5/10 cases hold; BROKEN: outside-stray, floor-timing, serial-stray, serial-side, serial-rename
```

Those are the CEO-descoped cases I ruled STILL VALID. They must stay red and they are red for the
same reason as before. **Nothing in this round is credited or debited by them.**

---

## 2. Verdict per item

### Item 1 — an abstention never reads as "clear" — **HOLDS**

Verified against the live state of this machine, not against the fixture.

```
$ python3 engine/scripts/lib/unlanded-branches.py --entity-root /Users/alex/ab/richos --format hook
STATUS	partial
N	0
SUMMARY	
NOTEXAMINED	1
UKEY	/Users/alex/ab/richos
UNEXAMINED	NOT EXAMINED - 1 repository could not be answered for, so this is NOT a clean
            main; it is an unread one. richos: no branch is recorded as the one this
            repository's work integrates on ... (point 14). Record it: workspaces.sh
            integration --repo /Users/alex/ab/richos --branch <main|dev/...> --why '<...>'
EXIT=0
```

`STATUS partial` with `N 0` is the exact shape that used to print "clear again", and it is the
live shape, not a corner. The abstention now travels in three fields of its own.

```
$ bash engine/scripts/unlanded-branches-lint.sh /Users/alex/ab/richos --line
NOT EXAMINED - 1 repository could not be answered for, so this is NOT a clean main; it is
an unread one. richos: no branch is recorded ...
EXIT=2
```

Exit 2, never 0. And the fix is not a word swap: the suite proves it with a paired triple
(U19 fires over the abstention, U20 is the same repository with the branch recorded and the branch
named, U21 is the same repository read end to end where the word "clear" is still reachable), so a
patch that deleted the word cannot pass. `abstention-not-counted` (U18) and `abstention-is-a-no-op`
(U19) are both proven load-bearing by the mutation harness.

**What this fix is worth, said plainly.** `all_integration_records()` returns `{}` — **no
repository on this machine has a recorded integration branch**, `integration.json` is absent from
the registry altogether, and `integration_for()` abstains for both `richos` and `femcboost`. So the
watch was reporting health over an unread machine, and it now reports NOT EXAMINED over an unread
machine. That is strictly better and it is not protection: until a branch is recorded, the watch can
never do its actual job of naming a stranded branch. See the defect in section 5.

### Item 2 — the gate cannot be silenced by the party failing it — **DOES NOT HOLD**

Two of the four routes are still open, both demonstrated below in a throwaway clone. Section 3 is
the ruling on the author check and section 4 the rulings on the residuals; section 6 has the rest.

| route | claim | what I observed |
|---|---|---|
| 1 — annotate the probe | closed | **OPEN.** `not-a-probe:` added to my RED probe **in the same commit as an engine change**, accepted, probe left the run, **exit 0** |
| 2 — a typed name | closed | **NARROWED.** A wrong name is refused. The right name is accepted from anybody who satisfies A1–A3, and 2 of 9 probes have the author `the engineer` |
| 3 — an uncommitted line | closed for retirements and markers | **OPEN where it matters**: the MISSING filter reads the file from disk and asks nothing of git |
| 4 — delete the probe | closed | **OPEN** in combination with 3: a committed deletion is concealed by one uncommitted, wrongly-signed line |

### Item 3 — retirement is per CASE — **HOLDS, and is unusable on a third of the probes**

The mechanism works: both three-field lines in the tree are untouched byte for byte and both still
read RETIRED, the four-field shape is read, a line naming a case the probe does not have is refused
rather than ignored, and `workspace-probes.test.sh` is 30 green with 10 mutants all load-bearing
(`per-case-is-per-file`, `retired-case-still-asked`, `unknown-case-ignored` among them).

**But `cases_of()` reads only `^CASES = [...]` or `SCENARIO == "..."`, and the runner's own
inventory says three of the nine live probes have `cases=0`:**

```
$ python3 engine/scripts/workspace-probes.py --list
 shape=in-tree author=frank cases=0     certification-frank-attribution-2026-09-12-probe.py
 shape=in-tree author=frank cases=0     certification-frank-four-fixes-2026-09-12-probe.py
 shape=argv    author=sage  cases=0     certification-sage-runner-round-2026-09-12.probe.py
 ... six probes with cases 5..10
```

The third of those is the one that matters. `certification-sage-runner-round-2026-09-12.probe.py`
has **ten** selectable cases and accepts them as argv — `RUNNERS = [("R1 reflog-privacy", ...), ...
("R10 rich-at-my-tip", ...)]`, `wanted = argv or [n.split()[0] for n, _f, _r in RUNNERS]` — but it
declares them in a list of tuples, which `cases_of()` cannot read. **It is the probe that exists
BECAUSE of the trade this round abolished**: sage retired two whole files and carried their live
halves into it, including R10, the descoped ref at an agent's own unlanded tip.

So the honest per-case ruling on that probe is not merely unavailable, it is punished. A correct,
minimal, truthfully-signed line naming a case that genuinely exists:

```
$ printf 'certification-sage-runner-round-2026-09-12.probe.py\tR5\tsage\tR5 is the descoped ...\n' \
    >> docs/verification/workspace-probe-retirements.tsv
$ python3 engine/scripts/workspace-probes.py --tree-only --only certification-sage-runner-round
UNRUNNABLE docs/verification/certification-sage-runner-round-2026-09-12.probe.py    0.0s
           its retirement names case 'R5', which this probe does not have. Its cases are:
           (none the runner can read). A retirement that matches nothing is a typo or a line
           copied from another probe, and either way it retires nothing.
EXIT=1
```

A GREEN probe becomes a blocking UNRUNNABLE, and the report tells the reviewer that a case he can
select from the command line does not exist. The direction is safe — it fails closed and it blocks
rather than passes — and the reviewer is the party it blames. The two in-tree probes carry the same
limitation with a second layer: `run_probe()` ignores `live_cases` entirely for the in-tree shape,
so per-case retirement could not reduce what they ask even if their cases were readable.

### Item 4 — no test writes to the operator's real state — **HOLDS, verified from outside**

`land-completeness.test.sh` asserts this about itself in L20/L22, which is a self-assertion, so I
took a `stat` census of every path under `~/.claude/state/workspaces` before touching anything and
compared it after each stage.

```
$ find ~/.claude/state/workspaces -print0 | xargs -0 stat -f '%N|%z|%m|%c' | sort   # 10 paths
$ bash engine/scripts/land-completeness.test.sh            # exit 0, all 23 passed
$ ...census again, diff against the baseline...
IDENTICAL: land-completeness.test.sh did not touch the operator registry
```

Identical again after the full probe runner, after `unlanded-branches.test.sh`, after
`workspace-probes.test.sh`, and after loading `workspaces.py` in-process to read the integration
records. **`~/.claude/state/workspaces` was neither created nor touched by anything I ran** — same
ten paths, same sizes, same mtimes and ctimes, four times over. The suite's own sandbox export is
at line 134 and the mutation harness aims the mutant at a temp path rather than at the operator's
registry, which is the right call: a harness that reproduces the shipped defect for real is a
second incident, not a proof.

---

## 3. The ruling you asked for: is a forgeable author check worth having?

**Yes — the check earns its place, and the sentence written in its defense does not.** The check is
worth keeping and the claim built on it is not; those are two different questions and the round
answers only the first.

### The forgery, attempted

All of this ran in `git clone --local` of the repository under a throwaway path, with its own refs.
Nothing left my branch and no state outside the clone was written.

**(a) His recipe, exactly as he wrote it — REFUSED.** `git branch cc/frank-opus-anything && git
commit` a docs-only retirement signed `frank`, then run:

```
$ git checkout -b cc/frank-opus-anything
$ printf 'certification-frank-recorded-attribution-2026-09-12-probe.py\tfrank\tForged by the party failing it ...\n' \
    >> docs/verification/workspace-probe-retirements.tsv
$ git commit -am "frank: retire the recorded-attribution probe"     # cc407763, docs-only, 1 file
$ python3 engine/scripts/workspace-probes.py --tree-only --only certification-frank-recorded
UNRUNNABLE ... names the right author ('frank') and is NOT attributable to that author.
           A3: the commit that wrote it (cc407763c9c7) exists only in cc/frank-opus-anything,
           the branch under test.
EXIT=1
```

His recipe is incomplete: the retirement must be in the working tree for `retirements()` to read it
AND its commit must be reachable from HEAD for A1, so a commit that lives only on the side branch
fails A1 when run from the round's branch and fails A3 when run from the side branch. **This
matters in one specific way: a reader who tries the recipe printed in the header, watches it get
refused, and concludes the check holds will have drawn the right conclusion from the wrong
evidence.** An incomplete attack in a header is worse than none, because it looks like it was
tested.

**(b) The recipe completed — WORKS, exit 0.** Same forged commit, merged back:

```
$ git checkout cc/zach-opus-g4 && git merge --no-ff cc/frank-opus-anything
$ python3 engine/scripts/workspace-probes.py --tree-only --only certification-frank-recorded
RETIRED    docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py    0.0s
           frank [cc407763c9c7, witnessed by cc/frank-opus-anything]: Forged by the party
           failing it: I hereby declare my own red probe obsolete.
every discovered probe ran, and every one of them is green.
EXIT=0
```

**(c) The one that needs no forgery at all — WORKS, exit 0. This is the finding.**

No impersonation branch. No merge. The retirement is committed **by the engineer, on the
engineer's own branch, docs-only, signed with the reviewer's name** — and then the lead cuts the
reviewer's worktree at the engineer's tip, which is what happens every single round including this
one.

```
$ git reset --hard 6fd5aef8                     # clean
$ printf '...probe.py\tfrank\tSigned frank, committed by the engineer on the engineer's own branch ...\n' \
    >> docs/verification/workspace-probe-retirements.tsv
$ git commit -am "Retire the probe this round cannot pass (docs-only, on the round's own branch)"
                                                # 04880dfa, docs-only
$ git branch --force cc/frank-opus-c7 HEAD      # the lead cuts the reviewer's branch. That is all.
$ python3 engine/scripts/workspace-probes.py --tree-only --only certification-frank-recorded
RETIRED    docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py    0.0s
           frank [04880dfa39a9, witnessed by cc/frank-opus-c7]: Signed frank, committed by the
           engineer on the engineer's own branch, witnessed by the reviewer worktree the lead
           cut afterwards.
every discovered probe ran, and every one of them is green.
EXIT=0
```

**And this is not hypothetical in the live repository.** Right now:

```
$ git rev-parse cc/frank-opus-c6 cc/zach-opus-g4 cc/sage-opus-c6
6fd5aef8fb6dc37934dff8f0f78cf876981dbe25
6fd5aef8fb6dc37934dff8f0f78cf876981dbe25
6fd5aef8fb6dc37934dff8f0f78cf876981dbe25

$ git branch --contains 6fd5aef8 --format='%(refname:short)'
cc/frank-opus-c6
cc/sage-opus-c6
cc/zach-opus-g4
```

Three branches at one commit. **Every commit the engineer made in this round already has two
"witnesses", and both of them are pointers the lead created at the engineer's own tip so that
reviewers could read the work.** A3 says "A commit that exists ONLY in the lineage being judged
cannot retire anything". These commits are in exactly one lineage and in three branches, so A3
refuses nothing this round contains, and the report prints a reviewer's branch name as the thing
that stood behind the retirement.

The words the report chooses make this worse rather than better: `witnessed by cc/frank-opus-c7`
reads as *the reviewer vouched for this*. Nothing was vouched. A review worktree existing is not a
reviewer's act, and it is the only fact A3 actually establishes.

### The ruling

1. **Keep the check.** It closes the realistic failure, and I say that having tried to break it.
   The engineer failing a probe, in the middle of the work that is failing it, in one commit, with
   a working-tree edit — that is what actually happens under pressure, and A1 and A2 refuse it by
   construction. That is worth having even though a determined forger walks past it.

2. **The check is not what makes retirement safe, and the file must not say it is.** The header
   currently reasons from A1–A3 to "the honest case for a marker is fine because A3 refuses route
   1", and A3 is the one of the three that holds only until a reviewer is spawned. A check that is
   true on an engineer's branch in isolation and false the moment the work is handed out for review
   is false at exactly the moment it is consulted.

3. **The witness is the thing that is actually load-bearing, so it must be a witness.** His defense
   — the branch and commit are printed with every accepted retirement, so the act is on the record
   — is the right defense, and it is the only one standing. It is also the part that is currently
   weakest in practice, because the branch printed is not evidence of anything and reads as though
   it were. On the record means legible to the next reader, not merely present.

4. **So: not false assurance, but assurance of something narrower than what is claimed.** The check
   stops the shortcut. The header claims it stops the party failing the probe. Those differ by the
   whole of case (c), and case (c) needs nothing but the review handoff that this round itself
   went through.

I will not prescribe the fix.

---

## 4. The two residuals he states in code

### Residual A — A2 is asked of a retirement but not of a `not-a-probe:` marker

**His argument does not survive contact, and this is the strongest single finding in the review.**
His reasoning is: refusing a marker committed alongside the engine change that needed it would
produce a waiver, a habit of waiving kills a check, and *"A1 and A3 still apply to the marker, and
A3 is the one that refuses route 1."*

A3 does not refuse route 1. Demonstrated:

```
$ printf '# not-a-probe: this file asserts nothing, says the party failing it.\n' \
    >> docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py
$ printf '\n# An engine change shipped in the very same commit as the marker.\n' \
    >> engine/scripts/lib/workspaces.py
$ git commit -am "Silence the red probe by annotating it, in the same commit as an engine change"
56f41787   docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py | 1 +
           engine/scripts/lib/workspaces.py                                               | 2 ++
$ git branch --force cc/frank-opus-c7 HEAD      # the review branch, again
$ python3 engine/scripts/workspace-probes.py --tree-only
probes discovered:        10 ...
declared not-a-probe:     2 ...
DECLARED   docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py
           56f417875e71, witnessed by cc/frank-opus-c7
           not-a-probe: this file
GREEN ... GREEN ... (the round's only RED is gone from the run entirely)
every discovered probe ran, and every one of them is green.
EXIT=0
```

**One commit that changes the library AND silences the probe that change is failing, accepted,
exit 0, with the runner printing its own all-clear sentence.** That is the precise shape A2 exists
to refuse, reached through the door A2 was not asked to guard. The library change here is a comment,
because I am reviewing and not sabotaging; nothing in the mechanism distinguishes a comment from a
rewrite.

**Ruling: the exemption is not a waiver-avoidance, it is the hole.** And the argument for it is
self-undermining in a way worth naming: the honest case he wants to protect — a helper committed
alongside the engine change that needed it — is *byte-for-byte the same commit shape* as the attack.
A rule that cannot tell the two apart is not a rule with a narrow exemption; it is a rule that is
off for this class. The one genuinely honest case in the tree,
`workspace-probe-regression-2026-09-12-logs/adapt-c3-probes-to-record-the-branch.py`, does not need
the exemption at all: its marker is in the commit that ADDED the file, so `marker_authority()`
accepts it on the first branch of the function and never reaches `attributable()`. The exemption is
paying for a case that does not use it.

### Residual B — a probe that ignores its case arguments runs the retired case and stays RED

**Ruling: correct, and correctly reported.** The fail direction is closed, and the two explanations
are distinguished rather than guessed:

```
exit %d with %d of %d case(s) requested (%s). Either this probe ignores the case arguments the
runner passes, or a case nobody retired is genuinely red.
```

`retired-case-still-asked` proves W19 goes red when the property is removed. I accept this residual
as stated with one scope correction he does not make: the branch is gated on
`probe.shape == "argv"`, so an in-tree probe that is red while a per-case retirement is in play
falls through to `probe.detail = "exit %d" % rc`, and because `detail` is then non-empty the
`elif p.case_notes` printer is skipped — **the per-case retirement is not mentioned on the report at
all.** That is the "a reduction nobody can see on the report is a coverage loss nobody can see"
hazard, in the one shape the round did not cover. Not reachable today (per-case retirement cannot be
addressed to an in-tree probe, because their cases read as 0 — see item 3), which is the only reason
it is an observation and not a defect.

---

## 5. Defects against the CEO's page

Rule 1 of this review: a finding is a defect only where I can quote the sentence of his page it
breaks. **One qualifies, and it is not this branch's doing.** Everything else I found is about the
review apparatus, which his page does not govern, and it is in section 6.

### D1 — no repository on this machine has a recorded integration branch, and agents are being spawned for this work anyway

**His sentence, point 14, verbatim:**

> **The branch a body of work integrates on is RECORDED when that work starts, before its first
> agent is spawned. Nothing infers it and nothing guesses it** — without that record there is no
> fact to test a land against, and "landed" goes back to meaning whatever main happens to have.

**Reproduction, on this machine, today:**

```
$ python3 -c "...load engine/scripts/lib/workspaces.py...; print(m.all_integration_records())"
{}
$ ... m.integration_for('/Users/alex/ab/richos')
('', '', "no branch is recorded for /Users/alex/ab/richos as the one this work integrates on ...")
$ ... m.integration_for('/Users/alex/ab/femcboost')
('', '', "no branch is recorded for /Users/alex/ab/femcboost as the one this work integrates on ...")
$ ls ~/.claude/state/workspaces/
agents  done  events.jsonl  ids  lock  refs  repos.json  sessions      # no integration.json
```

This body of work integrates on `dev/workspace-spec` — the whole round exists to land onto it — and
that fact is recorded nowhere. Its agents (`zach-opus-g4`, `sage-opus-c6`, this one) were all
spawned after the work started. `repos.json` names both repositories the engine governs, so this is
not a resolution failure; there is simply no record.

**Whose it is:** not the engineer's, and not fixable inside a branch. It is the lead's recording
step, and it is the reason every consumer this round touched — the sweep, the lint, the notice,
`land-completeness` — abstains on the live machine. **Which makes it the load-bearing fact about
item 1:** the round replaced a false green with a correct abstention, and the abstention is
*permanent* until this is recorded. A watch that can only ever say NOT EXAMINED has been made
honest, not useful. I am reporting it, not prescribing it.

---

## 6. Beyond the page — everything else I broke, and how

His page says nothing about probes, runners or suites, so none of the following is a defect under
rule 1. Every one of them is reproduced, and the ones marked **OPEN** are ways the gate reports
health it has not established.

### B1 — **OPEN.** Route 4 re-opened: a deleted probe is concealed by an uncommitted line signed by the wrong person

`missing` is filtered by `os.path.basename(q) not in retired`. `retirements()` reads the TSV **from
disk**. There is no author check, no A1, no A2, no A3, and no per-case distinction on that path.

```
$ git rm docs/verification/certification-frank-attribution-2026-09-12-probe.py
$ git commit -m "Delete a green probe of the library"                      # f1ba672d
$ python3 engine/scripts/workspace-probes.py --tree-only --list
probes DELETED from history and not retired: 1
MISSING    docs/verification/certification-frank-attribution-2026-09-12-probe.py
           it held a probe of this library and was DELETED in f1ba672da538 ...
EXIT=1                                                                    # correct, it blocks

$ printf 'certification-frank-attribution-2026-09-12-probe.py\tzach\tI deleted it and I am signing this with my own name, uncommitted, in the working tree.\n' \
    >> docs/verification/workspace-probe-retirements.tsv
$ git status --porcelain -- docs/verification/workspace-probe-retirements.tsv
 M docs/verification/workspace-probe-retirements.tsv                      # never committed
$ python3 engine/scripts/workspace-probes.py --tree-only --list
probes discovered:        10 (10 in the working tree, 0 on other branches)
probes DELETED from history and not retired: 0
EXIT=0
```

The probe is gone, the concealment is one uncommitted line signed `zach` over a probe authored by
`frank`, the count reads 0, the path is never named, and the run exits 0. The asymmetry is the
whole of it: **the deletion has to be committed and the concealment does not.** Route 4's own
refusal text — "A probe leaves by retirement, which is attributable, and never by deletion, which is
not" — is true of the retirement path and false of the path that decides whether a deletion is
reported.

### B2 — **OPEN.** `--tree-only` reports an unread source as an empty one

The exact confusion this round fixed in the sibling hook, in the gate that fixed it. I committed a
deliberately RED probe on a second branch and ran the gate from the branch under test:

```
$ python3 engine/scripts/workspace-probes.py --tree-only
probes discovered:        11 (11 in the working tree, 0 on other branches)
   # the reviewer's red probe is not counted, not named, and not hinted at

$ python3 engine/scripts/workspace-probes.py --only certification-frank-treeonly
probes discovered:        12 (11 in the working tree, 1 on other branches)
RED        docs/verification/certification-frank-treeonly-2026-09-12-probe.py    0.0s   [cc/reviewer-only]
```

"0 on other branches" is `--tree-only`'s way of saying **I did not look**, and it is byte-identical
to "there was nothing there". `--only` at least prints "SO THIS RUN PROVES NOTHING ABOUT THE REST";
`--tree-only` prints a number that reads as a finding. `unexamined_line()` in this same round exists
because *"an abstention that is only a status word gets read by the next consumer as a no-op, and a
no-op reads as clean."*

### B3 — **NARROWED, NOT CLOSED.** Two of nine probes have the author `the engineer`, so the signature check on them is vacuous

`author_of()` falls back to `"the engineer"` when the filename carries no `certification-<name>-`
and the docstring has no `<Name>'s` opener. `workspace-attribution-seven-cases.probe.py` and
`workspace-call-window-and-recorded-target.probe.py` are both in that class. The name check is
`who.lower() != pr.author`, so the string `the engineer` passes it:

```
$ printf 'workspace-attribution-seven-cases.probe.py\tthe engineer\tI am its author by the runners own rule ...\n' \
    >> docs/verification/workspace-probe-retirements.tsv
$ python3 engine/scripts/workspace-probes.py --tree-only --only workspace-attribution-seven-cases
UNRUNNABLE ... the retirement of this probe names the right author ('the engineer') and is NOT
           attributable to that author. A1: it is not in any commit reachable from HEAD ...
```

**"names the right author"** — the check is satisfied. Only A1–A3 remain, and section 3(c) is how
those are satisfied. For these two probes retirement by the party failing them is one docs-only
commit plus a review branch that already exists.

### B4 — the round's gate cannot see the round, and a suite sat 12-red on the dev branch

`unlanded-branches.test.sh` at the base:

```
$ git reset --hard 507ec6df && bash engine/scripts/hooks/unlanded-branches.test.sh
FAIL  U02 U05 U07 U08 U10 U13 U17 C02 C03 L01 L02   (11 cases)
FAIL  M. the mutation harness found a property this suite does not actually prove
=== mutation: 4 property(ies) NOT proven load-bearing, 5 proven ===
  19 passed, 12 FAILED
EXIT=1
```

At `6fd5aef8`: `37/37 cases passed`, 12 of 12 mutants load-bearing, exit 0. **The base red is
obsolete-assertion, not broken code**, and the engineer diagnosed it exactly: the fixture never
recorded an integration branch, so every case ran against an abstention. His comment names all
eleven case ids and adds the single most damning line in the diff — *"L01 was red because the LINT
REPORTED SUCCESS."* Correct diagnosis, correct fix (`record_work()`), and the new U18–U22 cases.

What is worth reporting is how it stayed unseen. `ci-units.sh` discovers suites with
`find ... -name '*.test.sh'` and never a typed list, so a full engine run would have caught it —
but the CEO has ruled against briefing full engine suites (two concurrent runs at 178 and 181
minutes), so the per-round gate is what people actually run, and the per-round gate is
`workspace-probes.py`, which runs **probes** and asks nothing about **suites**. Measured:

```
$ python3 engine/scripts/workspace-probes.py --tree-only   # at 507ec6df
8 GREEN, 2 RETIRED, 1 RED, exit 1
$ python3 engine/scripts/workspace-probes.py --tree-only   # at 6fd5aef8
8 GREEN, 2 RETIRED, 1 RED, exit 1
```

**Verdict-for-verdict identical before and after the round.** The gate is orthogonal to everything
this round changed: it tests `workspaces.py`, and the round did not touch `workspaces.py`. The
round's own four claims are asserted only by `*.test.sh` suites, which the gate never runs. A gate
whose output is unchanged by the work it is gating is not gating that work.

### B5 — every case count this round reports is one more than the number of cases it printed

The mutation harness is counted as a case but prints no case line of its own
(`PASS=$((PASS + 1))` at land-completeness.test.sh:622).

| suite | case lines printed | headline |
|---|---|---|
| `land-completeness.test.sh` | 22 (`L1 L1b L2 L3 L4 L5 L6 L7 L8 L9 L13 L9b L10 L11 L12 L14 L15 L16 L20 L22 L21 L23`) | `all 23 passed` |
| `unlanded-branches.test.sh` | 36 | `37/37 cases passed` |
| `workspace-probes.test.sh` | 29 | `all 30 passed` |

All three are off by exactly one, in the same direction, for the same reason. The commit message
compounds it by mixing denominators — "land-completeness: 16 cases -> 23/23" counts ids on the left
and ids-plus-harness on the right, so the reader cannot reconcile either number with the other or
with the list. This is squarely the class the CEO ruled on: a number in a record carries the command
that produced it, or it carries the word unverified.

**One brief claim I could not reproduce.** The lead's brief says a commit message claims "18/18 for
a suite with 16 ids". `git log --format='%B' 507ec6df..6fd5aef8 | grep '18/18'` returns nothing, and
`git log --all --grep='18/18'` finds no such commit. The real claim in `b208ec07` is
"land-completeness: 16 cases -> 23/23", and 23 is what the suite prints. The reconcilable error is
the one in the table above, not the one in the brief.

### B6 — the `L17` that was never written

Disclosed, three times, in the file itself: line 74 (`The ids skip L17..L19`), lines 131–133 (`an
L17 named in mkrepo()'s comment was never written, and reusing the id would make that reference
point at a case about something else`), and the dangling reference itself at line 175 (`L17 is the
case ...`). A comment pointing at a case that does not exist is a reader walking away with a wrong
belief about what is proven, and leaving the id unused is the right call for a different reason than
the one that created it. Declared, so it is an observation, not a finding.

### B7 — the mutation harness matches its target case by unanchored substring, and one of the two suites this round wrote is prefix-unsafe

`mutation-harness.sh:255` is `grep -q "FAIL  $want" "$dir/out.txt"`. Demonstrated:

```
$ printf '  FAIL  L13  NEGATIVE CONTROL: something\n' > /tmp/.../prefix.txt
$ grep -q "FAIL  L1" /tmp/.../prefix.txt && echo 'MATCHED: want="L1" is satisfied by a red at L13'
MATCHED: want="L1" is satisfied by a red at L13
```

`land-completeness.test.sh` ids are prefixes of one another in four families (`L1` ⊂ `L10`–`L16`
and `L1b`; `L2` ⊂ `L20`–`L23`; `L9` ⊂ `L9b`). `workspace-probes.test.sh` has six such families and
its harness works around them by hand, with a trailing space inside the string — `mutant
marker-taken-on-trust "W14 "`, `"W15 "`, `"W16 "`. Meanwhile **the sibling suite written in the
same round solved it structurally by zero-padding: `U01`, `U06`, `U08`, `U11`, `U18`, `U19`, `C02`,
`C06`, `C07`, `C08`, `L05`.** No live mutant currently targets a prefix id, so this is latent and
not a defect under rule 2 — but the round shipped both a structural answer and a manual one, and
the manual one is the one guarding two suites.

### B8 — `worktree-transactions.py` does not exist, and L14's fixture copies it anyway

`land-completeness.test.sh:380` copies four library files and one is not there, so a green suite
prints a raw error in the middle of its own output:

```
  PASS  L12  the third acknowledgement for the same worktree says so — a habit becomes evidence
cp: /Users/alex/ab/richos-wt/frank-opus-c6/engine/scripts/lib/worktree-transactions.py: No such file or directory
  PASS  L14  with no liveness module every owner is UNRESOLVED -> unowned, never incomplete-land
```

`ls engine/scripts/lib/` confirms it is absent, and `grep -rn worktree-transactions
engine/scripts/lib/*.py` finds it only inside comments — nothing imports it. **I checked whether the
unchecked `cp` could produce a false pass**, since the case's own comment says a missing
`workspaces.py` would make it "pass without testing anything": I renamed `workspaces.py` out of the
copy list in the sandbox and L14 failed loudly (`landed-agent -> '(absent)'`, 22 passed 1 FAILED).
So the loop is not load-bearing in the dangerous direction. It is a dead file name and an error
line that a reader of a green run has to know to ignore.

### B9 — the runner's report cannot be tied to a commit

The report's first line is a path. There is no SHA of the library under test, no SHA of HEAD, and no
statement about whether the working tree is clean. `retirements()` and the default `--lib` both read
the working tree while `attributable()` reads commits, which is how B1 works at all. This project's
freshness contract is "every artifact carries a commit SHA baked INSIDE it" and the round's
certification records are artifacts produced from these runs.

### B10 — observations I am recording without calling them problems

- **`events.jsonl` fixture rows: right call.** The four `integration-recorded` rows at
  `2026-09-12T12:44` name temp directories under `land-completeness.rSiULs` /
  `land-completeness.URJ6Yc` that no longer exist, with `"why": "the land-completeness fixture"`.
  Leaving them is correct on two independent grounds. First, `workspaces.py:229` is explicit that
  this file is "The history, never the authority" — the authority is `integration.json`, which is
  absent, and `all_integration_records()` returns `{}`, so the rows influence no answer anywhere.
  Second, rewriting an append-only log to tidy away an incident destroys the record that the
  incident happened; the rows are the only durable trace that a suite once wrote to the operator's
  registry. And they are findable: `grep -rl 'the land-completeness fixture'` lands on the suite's
  own comment and on a prior certification, so a future reader of the log can reach the
  explanation. Keep them.
- **The lint collapses "broken" and "could not look" onto exit 2.** Declared in its own exit-code
  table ("2 broken, OR IT COULD NOT LOOK") and the text output names which. Both mean do not trust
  this, so collapsing them is defensible — though the argument the round makes one notch down
  ("nothing is unlanded" and "nothing was read" must not share a code) applies here too, since the
  two call for different actions: fix the install versus record the branch.
- **`--help` range.** `sed -n '2,50p'` was widened with the table; line 50 is the last comment line
  and 52 is `set -eo pipefail`. Correct.
- **`deleted_probes()` looks back `HISTORY_LIMIT = 400` commits.** Measured on this branch:
  `git log --format=%H -- 'docs/verification/*.py' | wc -l` is **52** against 2503 commits on the
  branch. A probe deleted beyond that window would stop being MISSING silently. Not live; 52 of 400.
  Recorded with the number so nobody has to guess later.
- **`--only` filters MISSING as well as probes**, consistently, and both carry the "SO THIS RUN
  PROVES NOTHING ABOUT THE REST" warning. Correct as designed.
- **The `NOTHING WAS RUN` guard works.** A `--only` matching nothing exits 1 with "A run that asked
  nothing is not a run that passed." It caught my own mistyped selector during the marker test.
- **No per-case retirement line exists anywhere in the tree.** Both live lines are the three-field
  whole-file shape. The round's headline feature is exercised only by its own suite.

---

## 7. What I ran, with exit codes

Everything below ran from `/Users/alex/ab/richos-wt/frank-opus-c6` on branch `cc/frank-opus-c6` @
`6fd5aef8`, except the forgeries, which ran in `git clone --local` at
`<scratchpad>/forge` with its own refs and its own object store.

| # | command | exit | what it settled |
|---|---|---|---|
| 1 | `scripts/inflight-ack.sh --sha 6fd5aef8... --impact none` | 0 | ack row written to the durable ledger |
| 2 | `diff /Users/alex/ab/richos-hq/.../worktree-spec-2026-09-11.md docs/plans/...` | 0 | mirror byte-identical to the spec |
| 3 | `python3 engine/scripts/workspace-probes.py` | 1 | 8 GREEN, 2 RETIRED, 1 RED — the lead's count reproduces |
| 4 | `git diff --name-only 507ec6df..6fd5aef8` | 0 | 12 paths; 0 touch my probe; 0 touch `lib/workspaces.py` |
| 5 | `python3 engine/scripts/lib/unlanded-branches.py --entity-root /Users/alex/ab/richos --format hook` | 0 | live `NOTEXAMINED 1` over `STATUS partial / N 0` |
| 6 | `bash engine/scripts/unlanded-branches-lint.sh /Users/alex/ab/richos --line` | 2 | NOT EXAMINED, never 0 |
| 7 | `bash engine/scripts/land-completeness.test.sh` | 0 | 22 case lines, `all 23 passed`, 4 mutants |
| 8 | `bash engine/scripts/hooks/unlanded-branches.test.sh` | 0 | 36 case lines, `37/37`, 12 mutants |
| 9 | `bash engine/scripts/workspace-probes.test.sh` | 0 | 29 case lines, `all 30 passed`, 10 mutants |
| 10 | `python3 engine/scripts/workspace-probes.py --list` | 0 | shapes and case counts: three probes at `cases=0` |
| 11 | `python3 -c "...integration_for / all_integration_records..."` | 0 | `{}` — nothing recorded for either repository |
| 12 | `find ~/.claude/state/workspaces \| xargs stat` ×4, diffed against baseline | 0 | **identical every time** |
| 13 | forge: recipe (a), run from `cc/frank-opus-anything` | 1 | A3 refuses — his recipe as written does not work |
| 14 | forge: recipe (b), merged back onto the branch under test | **0** | forged retirement accepted, false green |
| 15 | forge: (c) docs-only on the engineer's branch + review branch cut at the tip | **0** | **no forgery needed at all** |
| 16 | forge: `git rm` a green probe, commit, run | 1 | MISSING blocks, as designed |
| 17 | forge: + one uncommitted line signed `zach` | **0** | route 4 re-opened, probe vanishes from the count |
| 18 | forge: marker + engine change in one commit, full run | **0** | route 1 re-opened via the A2 exemption |
| 19 | forge: red probe on a second branch, `--tree-only` | 1 | "0 on other branches" over an unread branch |
| 20 | forge: same, without `--tree-only` | 1 | discovery works; the flag is the cause |
| 21 | forge: per-case line naming `R5` on sage's runner-round probe | 1 | GREEN becomes blocking UNRUNNABLE |
| 22 | forge: retirement signed `the engineer` | 1 | "names the right author" — the check is vacuous there |
| 23 | forge: `land-completeness.test.sh` with `workspaces.py` dropped from L14's copy list | 1 | L14 fails loudly; the unchecked `cp` is not load-bearing |
| 24 | forge at `507ec6df`: `unlanded-branches.test.sh` | 1 | 19 passed, **12 FAILED**, 4 mutants not load-bearing |
| 25 | forge at `507ec6df`: `workspace-probes.py --tree-only` | 1 | same verdicts as at the tip |

**CEO constraints observed.** Nothing installed. No merge, no push, no `install.sh`, no write into
`/Users/alex/ab/richos/engine`, no touch of any main checkout. Every probe and every forgery ran
sandboxed — the suites into their own `mktemp` trees with `RICHOS_WORKSPACES_DIR` redirected, the
forgeries into a throwaway local clone. `~/.claude/state/workspaces` was neither created nor
touched, verified by `stat` census four separate times. I did not read Sage's work; the only
mentions of sage here are the two retirement lines the runner printed at me and the case ids inside
his probe, which I had to read to test per-case retirement.

**Not in scope, not assessed:** `contract-integrity-probe.sh` RED, `observe-created-refs.sh` absent
from `R_ROOTED_HOOKS`, my own RED probe's five descoped cases, anything `codex/`, the spec page and
its mirror beyond confirming they match, the descoped background-process ref, and the
indistinguishable ref at an agent's own unlanded tip.
