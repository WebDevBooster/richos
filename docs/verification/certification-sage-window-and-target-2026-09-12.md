NOT CERTIFIED

# Certification — one window per tool call, and the target read from the record

| | |
|---|---|
| **SHA under review** | `2bc413dfc876a919910ec470da19568be389760b` (`cc/zach-opus-g2`), four commits over `84e12d32`, 18 files |
| **Yardstick** | `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md` — fourteen points, read there, including point 14's new closing sentence. The mirror in this repository was not read as the spec and was not touched. |
| **Reviewer** | Sage. This round answers my own refusal (`356920a8`, D1 and D2), and I judged it as the author of that refusal. I did not read Frank's work. |
| **Installed / merged / pushed / deployed** | Nothing. No `install.sh`, nothing written into `/Users/alex/ab/richos/engine`, no write to the main checkout. |
| **Sandboxing** | Every probe redirects `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR`, `GIT_CONFIG_GLOBAL` and `RICHOS_WORKSPACES_DIR` into a temporary directory it removes. The operator's registry at `~/.claude/state/workspaces` was fingerprinted (`find … \| xargs stat -f '%N %z %m' \| sort`) before the first run and after the last: **`diff` exit 0, 9 entries, byte sizes and mtimes unchanged, directory mtime still `1789171093`, and no `integration.json` was created there.** |
| **My reproductions** | `docs/verification/certification-sage-window-and-target-2026-09-12.probe.py` — eight cases, takes any `workspaces.py`, imports no engine test file and no other probe. Full output at both SHAs in `certification-sage-window-and-target-2026-09-12-logs/`. |

## The verdict in one paragraph

**Both items do what they say, and I could not certify what one of them leaves behind.** Item 1 is
right and I proved the harm I named is over: with the branch recorded — which my round-3 fixtures
never did, and the engineer is correct that this is why they could not pass — the side branch created
in a second, overlapping call is attributed, the land is REFUSED by name, and the item is pending;
at `84e12d32` the same fixture lands, reports success and leaves nothing pending. Item 2 removes the
inferred floor exactly as point 14 demands, and the refusal it leaves behind heals. But deleting the
floor also deleted the per-agent copy, and the target is now one live record **per repository**, read
at land time, while the page says it is the branch **a body of work** integrates on. Two bodies of
work in one repository cannot both be recorded; recording the second — which point 14 obliges Rich to
do before its first spawn — retroactively moves the target of every unlanded agent of the first, so
work merged onto the branch it integrates on is reported not landed, its workspace is left behind and
point 5 is blocked. That is D3: a sentence of his page, a reproduction that is green at the parent and
red here, and a load that exists in `/Users/alex/ab/richos` today. The declared background-process gap
and the escalation's residue are both real and both, by his second rule, recorded rather than refused
on.

## Verdict per item

| Item | Verdict |
|---|---|
| **1 — the creation window is keyed by `tool_use_id`, one per TOOL CALL** | **HOLDS.** Overlapping calls of one agent keep their own windows, in both directions of the pairing, and the harm I named in D2 is over (case A below, and the five-case probe's cases 1 and 2). The plumbing is real, not asserted: `guard-sealed-worktree.sh` pipes the whole payload to `workspaces.py barrier`, `observe-created-refs.sh` pipes the whole payload to `observe-refs`, and the CLI hands `payload` to `barrier()` / `observe()`, which read `payload["tool_use_id"]` (`workspaces.py:2807`, `2824`, `2828`). |
| **2 — the inferred integration fallback is deleted, not bypassed** | **The deletion is right and complete; what replaced it carries D3.** `_ensure_integration` is gone, `new_record` no longer carries an `integration` field, `_add_workspace` freezes nothing, and `integration_target` reads `(integration_record(repo) or {}).get("branch")` and nothing else. A land with no record refuses and names `workspaces.sh integration`; recording it afterwards makes that same land succeed. **D3:** the record it now depends on is one slot per repository, read live, with no notion of a body of work. |

## Verdict per case — the round's own five, run by me

```
python3 -B docs/verification/workspace-call-window-and-recorded-target.probe.py <workspaces.py>
```

- against `git show 84e12d32:engine/scripts/lib/workspaces.py` → `0/5 cases hold; BROKEN:
  concurrent-refs, concurrent-side, no-record-refuses, late-record-heals, no-floor-written`, **exit 1**
- against `engine/scripts/lib/workspaces.py` → `5/5 cases hold`, **exit 0**

Both logs are committed (`five-cases-at-84e12d32.txt`, `five-cases-on-this-branch.txt`). The exit
codes are real: I ran each twice, and the probe drives `barrier()` / `observe()` rather than any test
helper.

| # | Case | At `84e12d32` | At `2bc413df` | Verdict |
|---|---|---|---|---|
| 1 | `concurrent-refs` | both refs lost | `['keyed-in-call-a', 'keyed-in-call-b']` with the platform's ids **and** `['unkeyed-in-call-a', 'unkeyed-in-call-b']` with none | **HOLDS.** The pairing does not depend on the caller supplying ids |
| 2 | `concurrent-side` | the harm | `created_branches ['tmpwork']`; `REFUSED: … tmpwork (38f76daea544) is not in main …`; `pending ['zach-opus-w3']`; then `landed` once merged, `branches after the land ['main']` | **HOLDS** |
| 3 | `no-record-refuses` | the floor supplied `main` | `integration record None`; `REFUSED …`; `names the recording command True`; `pending ['zach-opus-w4']`; `workspace still there True` | **HOLDS.** Note the case's own sharpness: the work IS in main and the land still refuses, because no branch is recorded |
| 4 | `late-record-heals` | frozen, could not be corrected | `frozen on the agent record None`; refused; `Rich records it afterwards {'branch': 'dev/work', 'source': 'recorded'}`; `the SAME land, after the recording landed`; `workspace gone True`; `nothing pending []` | **HOLDS** |
| 5 | `no-floor-written` | `source: first-registration` written at session start | `record after a registration None`; `every integration record {}` | **HOLDS.** The floor is gone, not bypassed |

**The round also edited the previous round's seven-case probe**, so I checked that the edit is not
tuned to this SHA. The diff is fixture-only (it records `main` for both repositories before the first
spawn, guarded by `hasattr`), and cross-running decides it:

```
this branch's probe  vs  84e12d32's workspaces.py   -> 7/7 cases hold        exit 0
84e12d32's probe     vs  this branch's workspaces.py-> 4/7; BROKEN: stray, side-branch, two-agents   exit 1
```

The modified probe passes at **both** SHAs, which is what an honest fixture change looks like; the old
probe's 4/7 here is the same artifact as my own 5/10 — a fixture that records no integration branch.

## The S10 claim — TRUE, re-derived independently

The engineer says my remaining five cases cannot hold because my fixtures were built against a build
that had the floor, and that S10 — the harm I named — has ended. **I did not take his adapter's word
for it.** I built my own copy of my round-3 probe with the same single fixture line added
(`record_integration(repo, 'main', …)` right after the session is recorded, which is what point 14
asks of Rich), left my committed probe untouched, and ran it at both SHAs.

```
python3 -B <my c3 probe, unmodified>                engine/scripts/lib/workspaces.py   -> held 5/10, exit 1
python3 -B <my c3 probe, unmodified>                84e12d32's workspaces.py           -> held 3/10, exit 1
python3 -B <my c3 probe + the one recording line>   engine/scripts/lib/workspaces.py   S3 S5 S9 S10
python3 -B <my c3 probe + the one recording line>   84e12d32's workspaces.py           S3 S5 S9 S10
```

S10, the same case, the same fixture, one line apart:

```
84e12d32                          2bc413df
created_branches   []             created_branches   ['tmpwork']
land               landed         land               REFUSED: … tmpwork (a1658460a1b0) is not in main …
pending            []             pending            ['zach-opus-s10']
side commit in main False         side commit in main False
```

**The claim is true.** The harm D2 named was never "the ref survives" — it was `land()` reporting
LANDED over a commit that reached no integration branch with nothing pending. That is exactly what
ends here. **And he is right about my predicate:** S10 asserts `"tmpwork" not in branches`, which a
correct refusal does not do — the refusal leaves the ref exactly where it is, on purpose, so the work
can be merged. My predicate encoded the repair as well as the harm; the repair was not mine to
specify. My own case A re-states the harm as the thing that must not happen (`land == landed and
pending == []`) and it is `False` here and `True` at the parent.

S3 and S9 also hold once the branch is recorded (`S3: created ['spare'] … land landed … branches
['main']`; `S9: land after merging onto dev/work landed, workspace gone True`). S2 asserts the floor
exists and S5 is the indistinguishable case I already ruled sound in kind; neither is a defect.

## The backgrounded-process gap — inside his page, and wider than declared

**It is inside his page.** Point 3: *"A `cc/` or native workspace with no registration, **and any
branch an agent created**, counts as finished work of an ended session and is handled under point 5."*
Point 10: *"When its work is landed or discarded, every workspace and branch it has is deleted, as
one. **None is left behind.**"* A ref the agent's own background process creates is a branch the agent
created, and it is attributed to nobody.

**It is wider than the declaration says.** The declaration names "after a Post and before the next
Pre". My case C measures a second mouth of the same gap — **after the LAST Post, before the end-of-run
signal** — and both are lost, at this SHA and at the parent alike:

```
=== ref-after-post
    created_branches (between two calls)     []
    created_branches (after the last Post)   []
    land                                     landed
    branches after the land                  ['bg-after-last-post', 'bg-after-post', 'main']
    pending (the point-3 sweep)              []
```

`record_end` consumes every window still OPEN; after the last Post none is open, so the end-of-run
signal is not the backstop for this one that it is for a call whose Post never arrived.

**No load, so it is recorded and not refused on.** The process shape exists on this machine — two of
my own tool calls in this review were moved to the background by the harness and outlived their
PostToolUse by minutes — but the ref-creating shape does not: no engine or repository script creates
a branch inside a workspace, and no branch outside the conventions exists in either repository
(measured today, below). **The engineer's framing that closing it would widen the indistinguishable
class is sound in kind, and incomplete in one respect that is his round's rather than the fix's:**
this SHA has already widened that class (Beyond the page, item 2).

## The escalation `esc-20260912T112834Z-91a77eef`, ruled against point 10

**The residue is real, it is new at this SHA, and point 10 is the sentence it breaks — for one class
of name only.** Measured both ways, each in its own sandbox:

```
=== escalation-stray        a ref named `tmpwork`, created while nothing is recorded
    attribution-skipped names it             True
    land after the branch is recorded        landed
    branches after the land                  ['main', 'tmpwork']
    pending (the point-3 sweep)              []
    branches after the sweep                 ['main', 'tmpwork']      <- permanent

=== escalation-stray-cc     the same ref, named `cc/zach-opus-e2-side`
    attribution-skipped names it             True
    land after the branch is recorded        landed
    branches after the land                  ['cc/zach-opus-e2-side', 'main']
    branches after the sweep                 ['main']                 <- recovered
```

So the honest size of it: `scan_unregistered` looks for `cc/` and `worktree-agent-*` and nothing else
(`workspaces.py:1265`), so a stray with a conventional name is picked up by the point-3 sweep after
the fact and handled under point 5, and only a ref named **outside** those conventions is left behind
with nothing that will ever come back for it. At `84e12d32` neither was left behind, because the
floor's record made the attribution possible — so this is a regression in exactly that narrow band,
and the engineer named it rather than papering over it. `attribution-skipped` is in `events.jsonl`
naming the refs and the cure, which makes it auditable rather than silent.

**By his second rule it is recorded, not refused on: there is no load.** Re-derived today, not quoted
from an earlier row:

```
$ git for-each-ref --format='%(refname:short)' refs/heads      # /Users/alex/ab/richos
cc/frank-opus-c4  cc/sage-opus-c4  cc/zach-opus-g2  codex/* (5)  dev/workspace-spec  main
$ git for-each-ref --format='%(refname:short)' refs/heads      # femcboost
codex/* (3)  main  worktree-agent-a0a29525658175cfb  worktree-agent-a5f5f7bccf8847dc7
```

Zero refs outside `cc/`, `worktree-agent-`, `codex/`, `dev/` and `main`. The residue needs an agent to
type a command no agent on this machine has typed.

**One thing the lead needs before answering the escalation's question**, and it is D3 rather than a
reason to refuse the escalation: recording the branch is what point 14 requires, and the record is
repository-wide and read live, so recording `dev/workspace-spec` for `/Users/alex/ab/richos` is not a
statement about this body of work — it is a statement about every agent in that repository until it is
changed again, and changing it again reaches backwards.

## Defects

### D3 — two bodies of work in one repository cannot both be recorded, and recording the second leaves the first behind

**The sentences of his page it breaks:**

> point 14 — "Landing means merged into the branch **this work** integrates on."

> point 14 — "**Finished work never waits on the agent's own branch**, and 'it cannot go to main yet'
> is never a reason for anything to be left behind or for point 5 to be blocked."

> point 5 — "When an agent finishes, everything it produced is landed (or, where point 7 applies,
> discarded). **Every time, all of it, no exceptions, no deferral.**"

**The mechanism, from the code.** `_write_integration` stores one record per repository
(`cur["repos"][main] = rec`, `workspaces.py:696`) and pushes the superseded one into
`cur["history"]`, which **nothing in the engine ever reads** (`grep -n '"history"'` gives the writer at
693 and three unrelated agent-record writers at 587, 1107, 1182). `integration_target` reads the live
record and nothing else, at land time. There is no key for a body of work anywhere in the file, and
`record_integration` neither refuses nor warns while agents of a previous body of work are unlanded.
Deleting the floor was required by point 14; deleting the per-agent copy alongside it is what makes
the single repository-wide slot binding on every agent at once.

**Reproduction** — `certification-sage-window-and-target-2026-09-12.probe.py two-bodies-of-work`, and
its sequencing is spec-legal throughout: the second body of work starts while the first body's agent
is still RUNNING, which point 5 permits, because point 5 blocks new work only for FINISHED work that
is neither landed nor discarded.

```
                                              84e12d32                2bc413df
the repository's record now says              dev/second              dev/second
its work is in dev/first                      True                    True
the superseded record is kept where nothing
  reads it                                    True                    True
land of the FIRST body's agent                landed                  REFUSED: zach-opus-b1 is not
                                                                      landed yet: HEAD of …/agent-
                                                                      azachopusb10000 (b88d79df9411)
                                                                      is not in dev/second of …
its workspace still on disk                   False                   True
pending (point 5 is blocked)                  []                      ['zach-opus-b1']
```

The work is merged into the branch its body of work integrates on. The land says it is not landed, the
workspace is left behind, and point 5 is blocked — the sentences, word for word.

**The load, on this machine, today.** `/Users/alex/ab/richos` hosts more than one body of work with
different integration branches, and the registry has exactly one slot for that repository:

```
$ git merge-base --is-ancestor dev/workspace-spec main ; echo $?
1                                  # this round's integration branch is not in main
$ git merge-base --is-ancestor 9e91c765 main ; echo $?
1                                  # work already LANDED onto dev/workspace-spec…
$ git merge-base --is-ancestor 9e91c765 dev/workspace-spec ; echo $?
0                                  # …is landed, by the only question point 14 allows
$ git for-each-ref --format='%(refname:short)' refs/heads | grep -c '^codex/'
5                                  # five further bodies of work, none of them on dev/workspace-spec
$ ls ~/.claude/state/workspaces/integration.json
ls: …/integration.json: No such file or directory
```

The escalation asks the lead to record `dev/workspace-spec` for this repository. The moment he does,
every agent in `/Users/alex/ab/richos` whose work integrates on `main` is judged against
`dev/workspace-spec`; the moment he records `main` back for the next body of work, this round's own
unlanded agents are judged against `main`. Point 12 contemplates two sessions running at once, each
handling its own agents, which is the same collision without anybody sequencing anything wrongly.

**Why this refuses the round rather than sitting under "Beyond the page".** It is inside item 2, it is
a behavioral regression between the parent and this SHA (the table above is green at `84e12d32` and
red here), it quotes his sentences, and its load is the repository this work is being done in. It is
also the direct cost of my own D1 — the floor had to go, and the per-agent copy went with it — which
is a reason to name it precisely, not a reason to wave it through.

### D4 — "every part of the system" still includes parts that answer with `main`

**The sentence of his page it breaks**, the one added while this round ran:

> point 14 — "**Every part of the system that needs to know whether work has landed asks the same
> question: is it in the branch recorded for this work? None of them is allowed its own answer, and
> none of them assumes main.**"

**Three parts beyond the one the brief declared out of scope, in the engine that is INSTALLED on this
machine** (`~/.claude/richos-engine`, not just on this branch):

```
scripts/lib/completion-proof.py:234,247,261   integration='refs/heads/main' is hard-coded, and
                                          proof['integration_ref'] != 'refs/heads/main'
                                          -> CompletionError('Unsupported member proof')
                                          (called from the TaskCompleted hook task-completed-handoff.sh)
scripts/lib/land-completeness.py:523      ap.add_argument("--main", default="main")
                                          _merge_status(repo, branch, main): "is every commit of this
                                          branch already in main", the disposition a land is judged on
scripts/hooks/guard-ci-red-lands.sh:216   WATCHED_BRANCH="${CI_RED_GATE_BRANCH:-main}" -> passed to
                                          land-residue-gate.py --branch
```

**The load** is the same two commands as D3: the same landed commit `9e91c765` is *not in main*
(exit 1) and *is in the branch recorded for this work* (exit 0). Two parts of one system, two answers,
one commit. `completion-proof.py` cannot even express a dev branch: the string is hardcoded in the
schema check and in the verifier.

**This branch neither introduces D4 nor closes it, and my refusal does not rest on it.** I record it
because the sentence is new, because the brief exempted only `guard-unresolved-claims.py`, and because
nobody has measured how many answerers there are: these three are what one pass over `is-ancestor` in
`engine/scripts` finds. What this branch does change is that the disagreement is now real rather than
accidental — at `84e12d32` the floor wrote `main` into the record, so every part of the system agreed
by coincidence.

## Beyond the page

Not defects. For his call, not this verdict.

1. **The platform premise behind item 1 is half-proven on this machine, and the unproven half is
   bounded.** The Pre half is proven: a real `PreToolUse[Agent]` payload here carried a platform call
   id, and it is in the operator's own registry —
   `{"event": "registered-spawn", …, "tool_use_id": "toolu_0161tgZJfawHovTgJDaCx2eD", "ts":
   "2026-09-11T23:58:13Z"}`. The Post half is asserted from `bind_agent`'s prior art and **has no
   instance in that registry** — it holds three events, all registrations, and no `bound` event ever
   fired. The bound is what makes this a note rather than a defect: my case E drives a Pre that carries
   an id against a Post that does not, and the reverse, and nothing is lost — `after the end-of-run
   signal ['keyed-pre-only', 'unkeyed-pre-only']`. If the platform's two halves ever disagree,
   attribution is deferred to the end-of-run signal, not destroyed.
2. **This SHA widens the indistinguishable class it was told not to widen, in the ordinary case.** At
   the end of a run every open window is consumed and the widest decides
   (`before = before ∩ before`, `workspaces.py:1857-1863`), so a ref **Rich** cuts between two of the
   agent's Pres is judged against the older window and becomes the agent's. It does not need the
   exotic no-Post case: with both Posts arriving and the earlier call simply finishing last
   (Pre A, Rich's ref, Pre B, Post B, Post A) the result is `created_branches ['rich/rescue']` here and
   `[]` at `84e12d32`. The consequence is the destructive direction — the land refuses while Rich's own
   commit is on it, and a discard deletes it with the tip recorded:
   `discard recorded tips ['rich/rescue', 'worktree-agent-…']`, `branches after the discard ['main']`.
   No load: nothing on this machine cuts a ref at an agent's unlanded tip, and
   `create-teammate-worktree.sh` cuts from the main checkout's tip, which the `is_ancestor(tip, target)`
   filter drops.
3. **A refused PreToolUse leaks a window, and the cap is the answer.** `_MAX_OPEN_CALLS = 64`, evicted
   oldest-first by mtime. A ref created inside an evicted call's window is unattributed; it takes 64
   guard-refused calls in one run to get there. Nothing on his page speaks to it.
4. **The mutation harness got harder, not softer.** The mutant that proved the frozen per-agent copy
   (`p14-in-flight-target-moves`) tested a property that has been deliberately deleted; it is replaced
   by `p14-floor-restored` and `p14-frozen-copy-restored`, which prove the deleted behavior stays
   deleted. 38 properties, all load-bearing.
5. **`contract-integrity-probe.sh` RED and `observe-created-refs.sh` untyped in `R_ROOTED_HOOKS`** are
   as briefed, and I did not run the probe. Nothing in this certification rests on it.

## What I ran, with exit codes

| Command | Result | Exit |
|---|---|---|
| `python3 -B docs/verification/workspace-call-window-and-recorded-target.probe.py <84e12d32's workspaces.py>` | `0/5 cases hold; BROKEN: …` | 1 |
| `python3 -B docs/verification/workspace-call-window-and-recorded-target.probe.py engine/scripts/lib/workspaces.py` | `5/5 cases hold` | 0 |
| `python3 -B docs/verification/certification-sage-window-and-target-2026-09-12.probe.py engine/scripts/lib/workspaces.py` | `held: 4/8` — A, B2, C, E hold; B, D, D2, F are the findings above | 1 |
| `python3 -B docs/verification/certification-sage-window-and-target-2026-09-12.probe.py <84e12d32's workspaces.py>` | `held: 7/8; NOT HELD: d2-harm-ended` — the harm, at the parent | 1 |
| `python3 -B <my c3 probe, unmodified> engine/scripts/lib/workspaces.py` | `held: 5/10` (was 3/10 at the parent) | 1 |
| `python3 -B <my c3 probe + one recording line> engine/scripts/lib/workspaces.py S3 S5 S9 S10` | S3, S9 hold; S10's harm ended; S5 is the declared case | 1 |
| `python3 -B <my c3 probe + one recording line> <84e12d32's workspaces.py> S3 S5 S9 S10` | S10 shows the harm: `landed`, `pending []` | 1 |
| `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py engine/scripts/lib/workspaces.py` | `7/7 cases hold` | 0 |
| `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py <84e12d32's workspaces.py>` | `7/7 cases hold` — the fixture change is not tuned to this SHA | 0 |
| `python3 -B <84e12d32's seven-case probe> engine/scripts/lib/workspaces.py` | `4/7; BROKEN: stray, side-branch, two-agents` — the unrecorded-fixture artifact | 1 |
| `python3 -B -W ignore engine/scripts/lib/workspaces.test.py` | `Ran 52 tests … OK`; `52 run, 0 failed` | 0 |
| `bash engine/scripts/lib/workspaces.test.sh` | `mutation: all 38 properties proven load-bearing` | 0 |
| `bash engine/scripts/workspaces-e2e.test.sh` | `workspaces-e2e: 47 passed, 0 failed` | 0 |
| `bash engine/scripts/hooks/guard-sealed-worktree.test.sh` | `mutation: all 10 properties proven load-bearing` | 0 |
| `bash engine/scripts/hooks/guard-worktree-removal.test.sh` | `all 94 passed` | 0 |
| `bash engine/scripts/hooks/guard-worktree-isolation.test.sh` | `all 165 passed` | 0 |
| `python3 engine/scripts/lib/land-completeness.py --repo /Users/alex/ab/richos` (read-only) | reports against `main` by default — D4 | 0 |
| `git merge-base --is-ancestor dev/workspace-spec main` | not in main | 1 |
| `git merge-base --is-ancestor 9e91c765 main` / `… dev/workspace-spec` | the two answers of D3 and D4 | 1 / 0 |
| `diff` of the `shasum`-style listing of `~/.claude/state/workspaces`, before vs after | identical, 9 entries, mtime unchanged | 0 |

— Sage, 2026-09-12
