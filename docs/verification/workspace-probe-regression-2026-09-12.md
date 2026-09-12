# The regression runner's starting line, and what is still red

**Branch:** `cc/zach-opus-g3`, from `cc/zach-opus-g2` at `2bc413df`.
**Yardstick:** `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, and nothing else.
**Command, for both columns:**

```
engine/scripts/workspace-probes.py --at 2bc413df     # the starting line
engine/scripts/workspace-probes.py                   # this branch
```

Raw output of both is in `workspace-probe-regression-2026-09-12-logs/`.

## Every probe, before and after

| probe | at `2bc413df` | on this branch |
|---|---|---|
| `certification-frank-attribution-2026-09-12-probe.py` | GREEN | GREEN |
| `certification-frank-four-fixes-2026-09-12-probe.py` | GREEN | GREEN |
| `certification-sage-attribution-2026-09-12.probe.py` | RED | RED |
| `workspace-attribution-seven-cases.probe.py` | GREEN | GREEN |
| `workspace-call-window-and-recorded-target.probe.py` | GREEN | GREEN |
| `certification-frank-recorded-attribution-2026-09-12-probe.py` *(dev/workspace-spec)* | RED 5/10 | RED 5/10 |
| `certification-frank-window-and-target-…-logs/c4-control-no-refused-call.py` *(cc/frank-opus-c4)* | RED 2/6 | **GREEN 6/6** |
| `certification-frank-window-and-target-2026-09-12-probe.py` *(cc/frank-opus-c4)* | RED 1/6 | **GREEN 6/6** |
| `certification-sage-recorded-attribution-2026-09-12.probe.py` *(dev/workspace-spec)* | RED 5/10 | RED 5/10 |
| `certification-sage-window-and-target-2026-09-12.probe.py` *(cc/sage-opus-c4)* | RED 4/8 | **GREEN 8/8** |

Five of the ten live on branches that were never merged into this line of work.
Discovering only the working tree would have missed **every probe written to
judge this round** — which is why the runner reads other local branches too.

## The three still red, case by case — measured, not asserted

`classify-remaining-red-cases.py` runs every case of the two `-recorded-`
probes twice: once as committed, once against a `/tmp` copy of the fixture with
the one `record_integration` line point 14 requires before a first spawn. The
committed probes are not touched. Its output is
`remaining-red-cases-classified.txt`.

**Red only because the fixture records no integration branch** — the build is
not what changed; the previous round deleted the inferred floor, with both
reviewers' approval, and these fixtures predate it:

* frank `floor-timing`, `serial-stray`, `serial-side`, `serial-rename`
* sage `S3 parallel-calls`, `S9 no-record-recovers`
* every scenario of `certification-sage-attribution-2026-09-12.probe.py`, which
  crashes on a `land()` refusal it does not catch

**Red both ways — a real question, and not one this round was given:**

* frank `outside-stray` — a ref created **between** two calls, by a backgrounded
  process. Explicitly out of scope: "do not widen the window to chase it."
* sage `S5 rich-then-commits` — the indistinguishable case the library names in
  its own header: a ref Rich cuts, during one of the agent's calls, at that
  agent's own unlanded tip. git keeps no record of where a ref was created.
* sage `S10 parallel-side-branch` — its predicate is `"tmpwork" not in
  branches`, but `tmpwork` carries a commit in no integration branch, so the
  land is correctly REFUSED and the branch correctly survives. **Sage superseded
  this predicate himself** in `certification-sage-window-and-target-2026-09-12`
  case A: "the harm is `land()` reporting LANDED over a commit that reached no
  integration branch with NOTHING pending — not the survival of the ref, which a
  correct refusal leaves exactly where it is." That case is green here.
* sage `S2 floor-vs-dev` — raises `TypeError` on `integration_record(...)[k]`
  because there is no record to subscript. Its premise **is** the deleted floor.

**Green here and green for a reason** — these cases are ABOUT the no-record
state and pass as committed: frank `outside-side`, `floor-trap`,
`no-floor-self-heals`; sage `S6 no-floor-recovers`, `S8 floor-at-session-start`.

## No probe was retired, and none could be

Retiring a probe is its author's act, never the engineer failing it. Nothing in
`workspace-probe-retirements.tsv` was written by this round, and the runner
would refuse a retirement signed by anyone but the probe's own author.

Four of the reds above are, on this evidence, obsolete premises rather than
defects — `floor-timing`, `S2`, `S10`, and the fixtures behind `serial-*`, `S3`,
`S9` and sage's c2 probe. **That call is Frank's and Sage's.** Escalated as
`esc-20260912T132131Z-fda1ccda` rather than decided here.
