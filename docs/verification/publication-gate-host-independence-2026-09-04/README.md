# The publication gate now means the same thing in a clone as it does here

**Subject: this repository at `a97df07` plus the commits this record ships with,
on branch `zach-opus-p6`.** Everything below was run; nothing is asserted. The
transcripts in `raw/` are the runs, ANSI stripped, otherwise as they came out.

`engine/scripts/publication-completeness.sh` decides whether this tree is
publishable. Before this change it **passed on the owner's machine and failed in
a fresh clone**, which means every green result in the record up to this point
proved less than it appeared to. Found on 2026-09-04 while proving reproducible
builds from a clone; recorded in
`docs/verification/reproducible-rust-builds-2026-09-04/README.md` and
deliberately not fixed there.

## The defect, precisely

`.richos/publication-completeness` carried a fourth key, `INSTANCE_MECHANISMS`,
naming an executable inside `richos-hq` — a **separate private repository**,
present here as a sibling checkout and present nowhere else.

Check 4 (mechanism misplacement) walks the trees named by `PRIVATE_SOURCES` in
`.richos/publication-boundary`. So:

| | private tree resolves? | Check 4 | the entry | verdict |
|---|---|---|---|---|
| owner's machine | yes | runs, 2768 files walked | suppressed a real finding | **green** |
| any clone | no | **does not run at all** | suppressed nothing | **red** |

The red came from the contract's own deliberate rule — *an exemption that
suppresses nothing FAILS* — firing over a file that is not in the tree being
checked. Both verdicts were sincere. Only one was about the published tree.

**The mechanism is not "a path that failed to resolve".** It is an exemption
being judged by a check that did not run. That distinction is the whole fix: the
rule is untouched, and no "unresolvable reference means skip" was added anywhere.

## What the exemption was actually suppressing, and whether it still fires

It still fires. Running the analysis over this tree with the entry removed and
the private sibling present produces exactly one finding: `MISPLACED`, on a
private one-off script that reads the public contract `.publication-boundary`.

So **deleting the line was not the fix**, and that was checked rather than
assumed. Deleting it would have turned the owner's machine red — and
`guard-completeness-commits.sh` runs this gate on every commit, so it would have
stopped work in the public repository until somebody put the line back.

## The fix

The excuse travels with the thing it excuses. A private mechanism that is one
operator's artifact rather than a withheld capability declares itself, in its own
body:

```
instance-mechanism: <why this is one operator's artifact>
```

That is the discipline `dialect-exempt: <reason>` already uses here: the
declaration sits where a reviewer of that file cannot miss it, it is committed
and diffable in the repository that owns the file, and **a bare marker with no
reason after it exempts nothing**. The marker is itself checked — a marker on a
file that couples to no public contract is reported as a stale exemption and
named for deletion — so it cannot outlive its reason either.

`INSTANCE_MECHANISMS` is **retired** and refused by name, with the migration, not
folded into the generic unknown-key message and never quietly ignored.

**What that buys is a property rather than one fixed instance.** Every key the
declaration still accepts — `CITATION_EXEMPT`, `DECLARATION_EXEMPT`,
`WORKFLOW_EXEMPT` — is a function of `git ls-files` and the tracked bytes, so its
verdict, staleness included, is identical in every clone. There is no key left
whose meaning depends on the host, and a new one cannot be added by accident.

### What was rejected, and why

- **Delete the line.** Would have been the best outcome and is not available: the
  finding it excuses still occurs, proven above.
- **Teach the checker that an unresolvable path is a skip.** This is how a real
  check quietly becomes decorative. Refused outright.
- **Scope an entry's staleness to the private root it names, keeping the entry.**
  Fixes the clone case and leaves the private repository's interior directory
  layout published in the one file the boundary contract exists to keep honest.
- **Hash the path, in the style of `PRIVATE_FILES`.** An exemption a reviewer
  cannot read is not a reviewable exemption; that key publishes its name on
  purpose, for exactly this reason.
- **Delete the private script.** It is a record of a one-off verification, kept
  beside the brief it documents. Its being awkward for a checker is not a reason
  to edit somebody's record, and the next private script would reproduce the
  defect anyway.

## The evidence

| file | what it shows |
|---|---|
| `01-pre-fix-fresh-clone.txt` | the defect: a clone of `a97df07` with no sibling, exit 1 |
| `02-post-fix-fresh-clone.txt` | the same tree with the fix, no sibling, **exit 0** |
| `03-suite-fresh-clone.txt` | the suite inside that clone, 53/53 |
| `04-suite-owner-machine.txt` | the suite here, 53/53 |
| `05-gate-owner-machine.txt` | the gate here, exit 0 |
| `06-red-first-new-suite-vs-pre-fix-checker.txt` | the new coverage RUN RED against `a97df07`'s checker: 6 cases fail |
| `07-check-4-really-runs.txt` | Check 4 is not inert here — it walks 2768 files and the gate is still green |
| `08-gate-inputs-grep.txt` | no path INTO the private repository survives in the gate's declaration inputs |
| `09-check-4-stands-down-in-a-clone.txt` | and in a clone it walks nothing, correctly |
| `10-mutations.txt` | three properties removed one at a time; each turns exactly one named case red |

The clone behind `02`, `03`, `08` and `09` is a real `git clone` of the exact
tracked set — **1341 paths, asserted equal to this tree's** before the clone is
made — into a directory whose only entry is that clone. A run in the working tree
would prove nothing, because the working tree has the sibling.

That clone already contained this record and every other file in it, including
the earlier bytes of those four transcripts. The recursion has to stop one step
short somewhere and it stops there: what the run exercised is the committed
declaration, the committed checker and the committed citation set.

### One thing about the proof itself, because it nearly produced a false finding

The first attempt built the snapshot with `git add -A`, which respects
`.gitignore` and silently dropped `engine/.claude/settings.local.json` — a file
that *is* tracked here. The snapshot then held 1328 of 1329 paths, and three
cases in two other suites went red for a reason that was an artifact of the proof
rather than a property of the tree. It is rebuilt with `--pathspec-from-file` and
asserts the two counts are equal before going on. **A proof that quietly changes
its own subject is worse than no proof**, and it is recorded here rather than
tidied away because the near-miss is the useful part.

## Looking for the same shape elsewhere

The defect class is **a verdict that is a fact about the machine rather than
about the tree**. Six suites were run in both worlds — this repository with the
private sibling resolving, and the sibling-free clone — and their verdicts
compared:

| suite | with sibling | no sibling |
|---|---|---|
| `engine/scripts/publication-completeness.test.sh` | 53/53 | 53/53 |
| `engine/scripts/hooks/publication-boundary.test.sh` | 131/131 | 131/131 |
| `engine/scripts/hooks/completeness-commits.test.sh` | pass | pass |
| `engine/scripts/hooks/ceo-asks.test.sh` | 46/46 | 46/46 |
| `engine/scripts/collect-worktree-artifacts.test.sh` | 14/14 | 14/14 |
| `engine/scripts/hooks/ceo-ruled.test.sh` | 40/41 | 40/41 |

**No suite among these changes its verdict with the sibling**, which is a
narrower result than it looks: six suites is not the engine, and the sweep was
scoped to the files that name the private repository at all.

Two things it did turn up, neither of them fixed here:

- **`engine/scripts/hooks/ceo-ruled.test.sh` is red, in both worlds, and was
  already red at `a97df07`.** One case, `8a LIVE record: f1 refused citing row
  3.14`. The 2026-09-04 pre-publication audit records this suite in its §8 as
  behaving differently when the private sibling exists; that is not what is
  measured here — it fails identically either way. A shipped suite that fails is
  worth someone's attention before the flip, and it is not this branch's to fix.
- Two mentions of interior private paths remain in engine source **prose**
  (`engine/scripts/publication-completeness.sh`,
  `engine/scripts/hooks/guard-completeness-commits.sh`), in incident narration.
  They are not gate inputs.

## What remains, and is not this record's claim

`PRIVATE_SOURCES` in `.richos/publication-boundary` still names `../richos-hq`,
and `PRIVATE_RECORD` still names the repository in prose. That is the private
repository's **root**, not a path into it, and it is required: the leak guards
build their corpus from it, and `CORPUS_MAY_BE_EMPTY=0` means removing it would
report BROKEN rather than clean. The boundary declaration already states that an
entry which is simply not on this machine is skipped. What is gone is the
interior path — the brief name, the date, the assets convention — which a public
file had no reason to carry.
