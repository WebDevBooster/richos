NOT CERTIFIED

# Certification — attribution by recorded creation, point 14 in `land()`, and the end of `extra_branches`

| | |
|---|---|
| **SHA under review** | `84e12d32ddb9278d89328667cd75e0eba0394f6f` (`cc/zach-opus-g1`), three commits over `65dad4d4`, seven files |
| **Yardstick** | `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md` — fourteen points, read there. The copy in this repository was not read as the spec and was not touched. |
| **Reviewer** | Sage. Frank reviews the same SHA independently; I did not read his work. |
| **Installed / merged / pushed / deployed** | Nothing. No `install.sh`. Nothing written into `/Users/alex/ab/richos/engine`. The main checkout was read-only (`git -C /Users/alex/ab/richos status --porcelain` → empty; HEAD `dcabcbd99056928a9872cd94c1f3a385f8b21069`). |
| **Sandboxing** | Every run had `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR` and `RICHOS_WORKSPACES_DIR` redirected into scratch. The real registry at `~/.claude/state/workspaces` was fingerprinted with `find` piped through `xargs stat -f '%N %z %m'` and `sort`, before the first run and after the last; the two listings are identical — 9 entries, byte sizes and mtimes unchanged. No `integration.json` was created there. |

## The verdict in one paragraph

The mechanism is right. Creation is the fact to record, the pair of hook events is the only place
the platform will vouch for it, and the four filters are each load-bearing — I removed the argument
and re-ran, and the seven cases move from 3/7 to 7/7 exactly as declared. Item 3 is clean. What I
cannot certify is the floor under item 2. Point 14's closing sentence says the integration branch
"is RECORDED when that work starts… **Nothing infers it and nothing guesses it**"; the floor reads
the main checkout's current branch, writes it down, and freezes a copy of it onto every agent at
registration. On this machine that value is `main` for `/Users/alex/ab/richos`, while this very
round integrates on `dev/workspace-spec` — and once frozen it cannot be re-recorded, so work merged
onto its dev branch is refused at the land and left behind, which is the sentence of point 14 that
this item exists to satisfy. Second, the attribution window is a single slot per agent, so two of
the agent's own tool calls open at once lose it: a side branch carrying work merged nowhere then
survives a land that reports success, with nothing pending — case 2's own failure, reproduced at
this SHA. Both are defects against his page, and both have a load that exists on this machine.

## Verdict per item

| Item | Verdict |
|---|---|
| **1 — attribution by recorded CREATION** | **Holds for the seven cases as specified, with one defect.** The `PostToolUse` catch-all is registered matcherless (`hooks.json` → `observe-created-refs.sh`), it pairs with the existing matcherless `PreToolUse` (`guard-sealed-worktree.sh` → `barrier()` → `snapshot_refs`), and all three holes the item names are closed when the agent's tool calls are serial. **Defect D2**: the window is one file per agent (`refs/<key>.json`), written by every Pre and unlinked by the first Post, so two concurrent calls lose it. |
| **2 — point 14** | **The change to `land()` is right; the record it rests on is not.** `land()` no longer reads `git rev-parse HEAD`: `integration_target()` resolves the recorded branch once per land and refuses when there is none. Case 6 is the proof. **Defect D1**: the `first-registration` floor supplies a branch nobody recorded, freezes it per agent, and makes point 14's own sentence fail for work that cannot reach main yet. |
| **3 — `extra_branches` and its three readers** | **Clean.** At `65dad4d4` the name occurred 8 times in `workspaces.py` (`git grep -c` → 8): `_workspace_branches` defined at 1477 and reading the field at 1480, the branch prune at 1640–41, and the done-check at 1663 — and **no writer anywhere**, so every reader read an always-empty list. `git grep -n 'extra_branches\|_workspace_branches' 84e12d32` now returns exactly one hit, line 1826, the comment in `_branch_targets` that records why it went. A workspace contributes exactly one branch, and `branch_deleted_at` no longer hides a target from the point 13 retry. |

## Verdict per case

Command, run twice, once per SHA, fully sandboxed:

```
python3 -B docs/verification/workspace-attribution-seven-cases.probe.py <workspaces.py>
```

- parent, `git show 65dad4d4:engine/scripts/lib/workspaces.py` → `3/7 cases hold; BROKEN: stray, side-branch, borrowed, dev-branch`, **exit 1**
- this SHA, `engine/scripts/lib/workspaces.py` → `7/7 cases hold`, **exit 0**

| # | Case | At `65dad4d4` | At `84e12d32` | Verdict |
|---|---|---|---|---|
| 1 | a branch created and never checked out goes with the agent | `created_branches []`, `branches after the land ['main', 'spare']` | `created_branches ['spare']`, `branches after the land ['main']` | **HOLDS** — see D2 for the parallel-call qualification |
| 2 | a side branch committed to and switched away from blocks the land | `land with the side branch out landed`, `pending []` | `REFUSED: … tmpwork (315c80f5a731) is not in main …`, `pending ['zach-opus-p2']`, then `landed` once merged | **HOLDS** — see D2 |
| 3 | a pre-existing branch only checked out survives a discard | `created_branches ['human/keep']`, `survived False` | `created_branches []`, `survived True`, `tip unchanged True` | **HOLDS** |
| 4 | a branch Rich cuts in the main checkout is never the agent's | held | `created_branches []`; `rich/notes` and `rich/look` both alive after the land | **HOLDS** for the refs the case names; see D-beyond-1 for a ref cut at a tip the agent only borrowed |
| 5 | two agents in one repository both land cleanly | held | `land A landed`, `land B landed`, `other branches after ['main']` | **HOLDS** |
| 6 | work merged to the dev branch but not main counts as landed | `REFUSED … workspace gone False` | `integration branch recorded dev/work`, `in main False`, `land landed`, `workspace gone True`, `branch gone True` | **HOLDS when the branch was recorded by Rich. It does not hold when the floor supplied the value — D1.** |
| 7 | work merged nowhere does not count as landed | held | `REFUSED …`, `pending ['zach-opus-p7']`, `workspace still there True` | **HOLDS** |

The probe is honest about what it drives: it imports no engine test file, enters through `barrier()`
and `observe()` — the two hooks — and gives the parent no second half rather than faking one. I read
it before I ran it, and I re-derived cases 1, 2, 3, 4 and 6 through my own harness independently.

## The three declared items, judged

### 1. The reflog source — **the distinction holds, and it does not carry the weight put on it**

The factual half of the claim is true, and I measured both halves rather than reasoning about them
(probe S1, S7):

- `$GIT_DIR/logs/HEAD` of a workspace is a **different file** from the main checkout's
  (`.git/worktrees/agent-…/logs/HEAD`, `os.path.samefile → False`), and the commit made inside the
  workspace appears in the workspace's own HEAD reflog (`True`) and **not** in the main checkout's
  (`False`). It is private to that workspace, it dies with it, and reading it is not the
  location-free read that was rejected.
- The rejected file behaves exactly as it was said to. Cut the same branch from the same start point
  twice — once inside the workspace, once in the main checkout — and
  `.git/logs/refs/heads/<name>` records `branch: Created from worktree-agent-azachopuss70000` in
  **both** cases, byte-identical, naming nothing about who ran the command or where. The branch
  reflog cannot tell an agent's ref from Rich's; the per-workspace HEAD reflog is a different
  question asked of a different file.

**So the distinction he draws is real.** What does not follow is the use he puts it to. The HEAD
reflog records **where a workspace's HEAD went**, not **what the agent made** — and `_own_unlanded_tips`
treats every entry in it as "this agent's OWN work". An agent that checks out a pre-existing branch
therefore acquires somebody else's unlanded commit as its own, and the docstring's guarantee — *"An
agent that has produced no unlanded commit of its own in that repository is attributed NOTHING"* —
is false in that state. Probe S4: an agent that made **no commit at all** checked out `human/keep`,
Rich cut `rich/backup` at `human/keep`'s tip during the agent's next tool call, and the result was
`created_branches after Rich's cut ['rich/backup']`. Filter 4 stopped being a fact about the agent's
work at the moment the reflog was added to it. This is not a defect against his page (see "Beyond
the page"), but it is a correction to the declaration I was asked to judge: the file is private, the
fact it yields is not authorship.

### 2. The one thing that cannot be told apart — **the bound holds as stated, and it is narrower than what it bounds**

Both halves of the bound are real. Probe S5: Rich cuts `rich/rescue` at the agent's own unlanded tip
inside the window; it is attributed (`created_branches ['rich/rescue']`); Rich then commits on it
after the agent's run ends; the land **refuses by name** (`rich/rescue (99153c823a1a) is not in main
…`) rather than deleting it, and the discard records every tip
(`…:rich/rescue`, `…:worktree-agent-…`). Nothing is silently destroyed, and the recorded tip is
enough to get a commit back. He named the case instead of papering over it, which is the right
instinct, and his "Rich rescues a finished agent's work, which is outside every window by
construction" is correct — `observe()` drops the snapshot for a finished agent, and I confirmed that
path.

Where the bound understates itself is the direction he did not name. Both of its exits cost
something: the refusal makes **Rich's own branch** a reason the agent's work is not landed, and the
only other exit deletes it (S5: `branches after the discard ['main']` — `rich/rescue` gone, its
commit unreferenced though its tip is in the record). And S4 shows the "at that agent's own unlanded
tip" qualifier is not the true edge of the window: a ref cut at a tip the agent merely **borrowed**
is taken too. I have no observed instance of either on this machine, so neither is a defect; the
ruling is that the bound is sound in kind and wrong in extent.

### 3. Point 14's floor — **OUTSIDE his page. Plainly.**

His sentence: *"The branch a body of work integrates on is RECORDED when that work starts, before its
first agent is spawned. **Nothing infers it and nothing guesses it** — without that record there is
no fact to test a land against."*

The floor reads the main checkout's current branch and writes it down. Nobody recorded it. Deriving
the integration branch from what Rich happens to have checked out is precisely inference, and it is
inference from the exact quantity the page's next clause rejects — *"'landed' goes back to meaning
whatever main happens to have."* Freezing it makes it stop moving; it does not make it recorded.
Marking it `source: first-registration` is honest bookkeeping, and honest bookkeeping of an inferred
value is still an inferred value: every consumer in `land()` treats the two sources identically.

Two facts decide it beyond the wording:

- **It is not a floor, it is the normal case.** The only path that leaves no record is a main
  checkout that is detached at the moment the record is written. Every attached repository gets it.
  The `recorded` source is reachable only if Rich acts before anything else touches that repository.
- **It is written earlier than declared, and for the session's own repository Rich cannot get in
  front of it.** The declaration says the floor is written "at the registration of the first
  workspace in that repository". It is also written at **session start**: `record_session_start` →
  `_remember_repo` → `_ensure_integration`. Probe S8, before a single workspace exists:
  `integration record before any registration {'branch': 'main', 'source': 'first-registration'}`,
  `workspaces registered so far []`, with the `integration-recorded` event standing beside
  `session-start` in the log. The temporal part of his claim survives (this is still before the first
  spawn); the provenance part does not. For the session's own repository the value is the main
  checkout's branch when the terminal opened, and no command Rich can run in that session precedes
  it.

The in-page behavior is the one the code already has for the no-record case and states well: refuse,
and name the command. I am not saying what should replace the floor — only that the floor is not in
his fourteen points, and that D1 is what it costs.

## Defects

### D1 — work merged onto its dev branch is refused and left behind, because the integration branch was inferred and then frozen

**The sentence of his page it breaks — point 14, both of them:**

> "The branch a body of work integrates on is RECORDED when that work starts, before its first agent
> is spawned. Nothing infers it and nothing guesses it"

> "**Finished work never waits on the agent's own branch**, and 'it cannot go to main yet' is never a
> reason for anything to be left behind or for point 5 to be blocked."

**The load, on this machine, today** (commands and their output):

```
$ git -C /Users/alex/ab/richos rev-parse --abbrev-ref HEAD
main
$ git -C /Users/alex/ab/richos merge-base --is-ancestor dev/workspace-spec main ; echo $?
1                       # the dev branch this round integrates on is not in main
$ ls ~/.claude/state/workspaces/integration.json
absent
$ grep -l '/Users/alex/ab/richos' ~/.claude/state/workspaces/agents/*.json
16a15be1-c2c1-4d79-82eb-f09c3f533143--zach-opus-d1.json
```

A workspace in `/Users/alex/ab/richos` is already registered, no integration branch has ever been
recorded, and the main checkout is on `main` while this round's work integrates on
`dev/workspace-spec` (the branch `cc/zach-opus-g1`, `cc/sage-opus-c3` and `cc/frank-opus-c3` all
branch from, and the branch the last two lands went onto). The first registration after this code is
live writes `main` for that repository and freezes it onto every agent registered from then on.

**Reproduction** — `docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py S2`,
sandboxed, real output:

```
main checkout branch at first registration main
integration.json after registration {'branch': 'main', 'source': 'first-registration'}
frozen on the agent record         {'…/entity': 'main'}
Rich records it afterwards         {'branch': 'dev/work', 'source': 'recorded'}
still frozen on the agent record   {'…/entity': 'main'}
land after merging onto dev/work   REFUSED: zach-opus-s2 is not landed yet: HEAD of …/agent-azachopuss20000 (b…) is not in main of …
pending (point 5 gate)             ['zach-opus-s2']
workspace still on disk            True
```

The work is merged onto its dev branch. It cannot reach main yet. It is left behind on the agent's
own branch and it blocks point 5 — the sentence, word for word.

**That the floor is the cause, and not the freeze alone:** case `S9` runs the identical sequence with
no record in existence at registration (`integration.json after registration None`, `frozen on the
agent record {}`). Rich records `dev/work` afterwards and the land returns `landed`, `workspace gone
True`. A repository with no fact recovers; a repository handed an inferred one does not. `S6` shows
the inferred one cannot be dodged by detaching the main checkout before the spawn, because it was
already written at session start.

`record_integration` rewrites the repository-level record only; the per-agent copy is written in
exactly one place and read in exactly one place —
`grep -n 'setdefault("integration"\|"integration": {}\|get("integration")' engine/scripts/lib/workspaces.py`
gives `580` (the empty field on a new record), `737`
(`rec.setdefault("integration", {})[realpath(repo)] = ir["branch"]`, inside `_add_workspace`) and
`1866` (`integration_target`, which prefers it over the repository's record). Nothing in the file re-records it for an agent in flight,
and the mutation harness proves that on purpose (`p14-in-flight-target-moves`). The tested envelope
is exactly the case where the frozen value is `main` and the work is then merged **to main**
(`test_point_14_the_integration_branch_is_recorded_never_inferred`, lines 1048–1058); the case point
14 was written for — the frozen value is `main` and the work **cannot go to main** — is not in it.

### D2 — two of an agent's own tool calls open at once lose the attribution, and a land then reports success over work that is in no integration branch

**The sentences of his page it breaks:**

> point 4 — "**Landed means the workspace AND the branch are deleted — automatically, with nothing
> left undecided.**"

> point 10 — "When its work is landed or discarded, every workspace and branch it has is deleted, as
> one. **None is left behind.**"

> point 3 — "A `cc/` or native workspace with no registration, **and any branch an agent created**,
> counts as finished work of an ended session and is handled under point 5."

**The mechanism, from the code rather than from a race:** the window is one file per agent —
`_refs_path(key)` → `refs/<key>.json`. Every `PreToolUse` overwrites it (`snapshot_refs`) and the
first `PostToolUse` consumes it (`observe_created_refs` calls `_drop_snapshot` before it does
anything else, "whatever the outcome"). Two calls of the same agent open at once therefore share one
slot, and a ref created after the first Post fires is compared against nothing.

**The load on this machine:** parallel tool calls are the normal shape here, not an exotic one — this
session's own agent instructions require independent calls to be issued in one block, and I issued
several while doing this review. Each call carries the same `agent_id` through both hook halves.
What I did **not** capture is a live hook trace showing two `PostToolUse` firings interleaved; I drove
the interleaving through the library's own entry points, in the order concurrency produces, and the
CEO should weigh it as that.

**Reproduction** — `…probe.py S3` and `S10`, sandboxed, real output:

```
S3   Pre(A) Pre(B) Post(A)  <branch created in call B>  Post(B)
     created_branches                   []
     land                               landed
     branches after the land            ['main', 'spare']
     scan calls the stray unregistered work []

S10  the same window, with the work on a side branch (case 2's own shape)
     created_branches                   []
     land                               landed
     its side-branch commit in main     False
     branches after the land            ['main', 'tmpwork']
     pending after the land             []
     the side commit is still only on tmpwork True
```

S10 is the harm. The agent's workspace and its branch are deleted, `land()` returns landed, nothing
is pending, and a commit the agent made is on a branch that reached no integration branch and that
nothing will ever come back for — the failure case 2 was written to end, at a SHA that ends it for
serial calls only. Nor does the point 3 backstop catch it: `scan_unregistered` lists branches
matching `cc/` and `worktree-agent-*` only (`local_branches(repo, ["cc/", NATIVE_BRANCH_PREFIX + "*"])`),
so a ref named `spare` or `tmpwork` is invisible to it — which is exactly why creation had to be
recorded in the first place.

## Beyond the page

Not defects, not reasons to refuse. Listed because he should see them.

1. **A ref cut at a tip the agent only borrowed is taken as the agent's** (S4, above). No sentence of
   the fourteen points forbids deleting a ref the agent did not create — point 2 protects `codex/`
   and point 7 protects the CEO's work, and nothing protects Rich's. It contradicts the code's own
   stated guarantee rather than the page, so it sits here.
2. **The cost of the catch-all.** `observe-created-refs.sh` is registered against every tool with a
   20 s timeout. The lead's path is one `grep` before `python3` starts, and I confirmed all four
   shapes exit 0 silently and write nothing: a lead payload, an unknown `agent_id`, an escaped
   literal `\"agent_id\"` inside a Bash command string (correctly read as the lead's), and closed
   stdin. For a registered agent it is a `for-each-ref` per repository plus a small write per call.
   That is cheap, and it is now on the critical path of every tool call every agent makes; nothing on
   his page says either way.
3. **`contract-integrity-probe.sh` is RED on this branch, as briefed and as expected** — `hooks.json`
   changed and `install.sh` was forbidden, and `observe-created-refs.sh` is not yet in the typed
   `R_ROOTED_HOOKS`. I did not run it. The second commit that closes both is the merge's, per the
   convention in the hook's own header; I note only that until it lands, the probe's answer to "are
   the hooks wired" is unavailable rather than negative, and nothing in this certification rests on
   it.
4. **One shellcheck warning**, `SC2034 ENGINE_ROOT appears unused`, at `observe-created-refs.sh:78`.
   It comes from the shared root-resolution bootstrap block that Layer R requires to be
   byte-identical (`guard-sealed-worktree.sh:165` carries the same line), so it is the convention, not
   this file.
5. **The floor makes attribution itself possible.** Filter 3 needs an integration target, and
   `observe_created_refs` skips the repository entirely when there is none. So in a repository with
   no record, no ref is ever attributed to anyone. That coupling is worth knowing when the floor is
   reconsidered.

## What I ran, with exit codes

All sandboxed (`HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR`, `RICHOS_WORKSPACES_DIR` into scratch); the real
registry was identical before and after.

| Command | Result | Exit |
|---|---|---|
| `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py <65dad4d4's workspaces.py>` | `3/7 cases hold; BROKEN: stray, side-branch, borrowed, dev-branch` | 1 |
| `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py engine/scripts/lib/workspaces.py` | `7/7 cases hold` | 0 |
| `python3 -B -W ignore engine/scripts/lib/workspaces.test.py` | `Ran 51 tests … OK`; `workspaces spec tests: 51 run, 0 failed` | 0 |
| `bash engine/scripts/lib/workspaces.test.sh` (unit + mutation) | `mutation: all 35 properties proven load-bearing` | 0 |
| `bash engine/scripts/workspaces-e2e.test.sh` | `workspaces-e2e: 46 passed, 0 failed` (E6.1–E6.7 drive the real pair) | 0 |
| `bash engine/scripts/hooks/guard-sealed-worktree.test.sh` | `mutation: all 10 properties proven load-bearing` | 0 |
| `python3 -B docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py` (this certification's own, 10 cases) | `held: 3/10; NOT HELD: S2, S3, S4, S5, S6, S8, S10` — the six findings above plus S10 | 1 |
| `bash -n engine/scripts/hooks/observe-created-refs.sh` | clean | 0 |
| `shellcheck -S warning engine/scripts/hooks/observe-created-refs.sh` | one `SC2034` (shared bootstrap block) | 1 |
| the hook itself, four payload shapes (lead / unknown agent / escaped literal / closed stdin) | silent, nothing written | 0, 0, 0, 0 |
| `git diff --stat 65dad4d4..84e12d32` | 7 files, 1405 insertions, 189 deletions | 0 |
| `git -C /Users/alex/ab/richos status --porcelain` | empty | 0 |
| `contract-integrity-probe.sh` | not run — RED by construction on this branch, as briefed | — |

The reproductions in this document are one file, committed beside it:
`docs/verification/certification-sage-recorded-attribution-2026-09-12.probe.py`. It takes an optional
path to any `workspaces.py` and an optional list of case names, sandboxes itself, and exits 1 while
S2, S3, S4, S5, S6, S8 and S10 do not hold.
