NOT CERTIFIED

# Frank — certification of the call-window and recorded-target round

- **Commit certified:** `2bc413dfc876a919910ec470da19568be389760b` (`cc/zach-opus-g2`, four commits over `84e12d32`)
- **Reviewed from:** `/Users/alex/ab/richos-wt/frank-opus-c4`, branch `cc/frank-opus-c4`, HEAD `2bc413df`
- **Yardstick:** `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md` at `c663a823`
  (sha256 `957d21a4e76262c28bb8b69cd37249cc87eea326e12c927c2997ad9887b10978`, 109 lines, read in the
  canonical repository — point 14 carries the new closing sentence). The mirror in this repository was
  not read as the spec and was not touched.
- **Sandboxing:** every probe redirects `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR`, `GIT_CONFIG_GLOBAL` and
  `RICHOS_WORKSPACES_DIR` into a temporary directory. `~/.claude/state/workspaces` was fingerprinted
  before and after (`find … -exec stat -f '%N %m %z %Sp'`); the two are byte-identical — **neither
  created nor touched.** Nothing was installed, merged, pushed or deployed; nothing was written to
  `/Users/alex/ab/richos/engine` or to any main checkout.

---

## Verdict in one paragraph

**Both items do what they claim, and I can prove it.** Item 1's premise is true of the platform
installed on this machine, and item 2 really does delete the floor rather than bypass it. Every number
in the brief reproduced exactly. **But the round is NOT CERTIFIED, on four defects, three of which are
regressions against the parent it was measured red on.** Deleting the floor left a state — a repository
with no recorded integration branch — in which attribution is skipped outright, *permanently* and
*retroactively*: a side branch created in that state carries real commits into no integration branch,
the later recording unblocks the land, `land()` reports LANDED, and nothing is pending. That is the
exact failure item 1 was written to end, arriving through the door item 2 opened. Separately, item 1's
end-of-run half consumes **every** open window and intersects them, so one refused `PreToolUse` — a
thing the engineer's own code comments say happens — widens the comparison from one tool call to the
agent's whole run, and a branch Rich cut outside every call is attributed to the agent and destroyed by
its discard. And the new closing sentence of point 14 binds more than `workspaces.py`: four live
consumers still answer landed-ness with their own answer, and this repository's own work is on
`dev/workspace-spec`, not main, today.

---

## Item 1 — the creation window is keyed by `tool_use_id`

**VERDICT: the fix is real, its premise is true on this machine, and it holds for the case it names.
Its end-of-run half introduces defect D3.**

### The premise, checked rather than accepted

The engineer's load-bearing claim is that `tool_use_id` "is the same string at PreToolUse and at
PostToolUse of one call". I did not take it from the comment.

1. **PreToolUse carries it, in production.** A real agent record written on this machine on
   2026-09-11 by the live `PreToolUse[Agent]` registration:
   `~/.claude/state/workspaces/agents/16a15be1-…--zach-opus-d1.json` →
   `tool_use_id = toolu_0161tgZJfawHovTgJDaCx2eD`.
2. **Both halves carry it, and it is the same string.** Sweeping the 60 most recent session
   transcripts under `~/.claude/projects/*/*.jsonl` for hook attachments
   (`attachment.hookEvent` ∈ {PreToolUse, PostToolUse}, joined on `attachment.toolUseID`): 5241
   PreToolUse and 13 PostToolUse attachments, and **2 toolUseIDs carry both halves** —
   `toolu_01LBkjDPEgqz9zPQ7MQzfj9p` and `toolu_01D7zvkLdr8okmZcVc5ySAV2`, both in
   `b7869424-972c-4693-80f8-5e034a119d86.jsonl`. Two real instances, not an inference.
3. **The platform builds both payloads from the same variable.** `strings` of the installed
   `/Users/alex/.local/share/claude/versions/2.1.269`:
   `hook_event_name:"PreToolUse",tool_name:e,tool_input:r,tool_use_id:n` and
   `hook_event_name:"PostToolUse",tool_name:e,tool_input:r,tool_response:s,tool_use_id:n`.
4. **The overlap the fix addresses is documented by the installed platform itself.** Same binary:
   *"PostToolUse fires per-tool and may run concurrently for parallel tool calls; PostToolBatch fires
   exactly once with the full batch."*

The plumbing is complete: `guard-sealed-worktree.sh` pipes the whole payload to `barrier`, which passes
`payload["tool_use_id"]` to `snapshot_refs`; `observe-created-refs.sh` pipes the whole payload to
`observe`, which passes it to `observe_created_refs`.

### Per case

| case | command | result |
|---|---|---|
| `concurrent-refs` | five-case probe at `84e12d32` | **BROKEN** — `['keyed-in-call-a']` / `['unkeyed-in-call-a']`: call B's window lost |
| `concurrent-refs` | five-case probe at `2bc413df` | **HOLDS** — `['keyed-in-call-a','keyed-in-call-b']` and the same unkeyed |
| `concurrent-side` | at `84e12d32` | **BROKEN** — `land → landed`, side commit in main `False`, `pending []`, `tmpwork` survives |
| `concurrent-side` | at `2bc413df` | **HOLDS** — `REFUSED … tmpwork … is not in main`, `pending ['zach-opus-w3']`, merged → `landed`, `branches after the land ['main']` |

Both run through the same entry points the hooks use. The parent's `concurrent-side` line
`land → landed` beside `its side-branch commit in main  False` is the real defect this round ends, and
it is ended.

---

## Item 2 — the inferred integration fallback is deleted

**VERDICT: deleted, not bypassed — the claim is exactly true. The state it leaves behind is defects D1
and D2.**

| case | at `84e12d32` | at `2bc413df` |
|---|---|---|
| `no-record-refuses` | **BROKEN** — record `source: first-registration` written by the floor; `land → landed` | **HOLDS** — `integration record None`; `REFUSED`, names `workspaces.sh integration`, `pending ['zach-opus-w4']`, workspace still there |
| `late-record-heals` | **BROKEN** — frozen copy `{…: 'main'}` beats the later `dev/work`; the same land refuses **twice** and the workspace is left behind | **HOLDS** — `frozen on the agent record None`; refuses, then after the recording `landed`, workspace gone, branch gone, nothing pending |
| `no-floor-written` | **BROKEN** — `every integration record {…'source': 'first-registration'}` | **HOLDS** — `integration_record None`, `all_integration_records {}`, nothing frozen |

I confirm the engineer's own comparison independently: **the refusal heals and the floor's record never
could.** `_ensure_integration` is gone, the `integration` key is gone from `new_record`, `_add_workspace`
freezes nothing, and `integration_target` reads the live record and nothing else. Inside
`workspaces.py`, every landed-ness answer (lines 1831, 1873, 1895, 1897, 2042, 2054, 2066) routes
through `integration_target`. Mutants `p14-floor-restored` and `p14-frozen-copy-restored` both kill.

---

## My own probe on this branch

`docs/verification/certification-frank-window-and-target-2026-09-12-probe.py` — six cases, self-contained,
same entry points, run against both libraries.

| case | at `84e12d32` | at `2bc413df` |
|---|---|---|
| 1 `late-record-stray` | HOLDS | **BROKEN** → D1 |
| 2 `late-record-side` | HOLDS | **BROKEN** → D2 |
| 3 `record-first-control` | HOLDS | HOLDS (the control) |
| 4 `late-record-rename` | HOLDS | **BROKEN** → D1 |
| 5 `leaked-window-widens` | HOLDS | **BROKEN** → D3 |
| 6 `leaked-window-evicts` | HOLDS | BROKEN at the Post, **recovered at the end of the run — not a defect** |

`6/6` at the parent, `1/6` here. Exit 0 and exit 1 respectively.

---

## Defects

### D1 — a branch an agent created while no branch is recorded is attributed to nobody, forever, and the land that the recording unblocks leaves it behind

**The sentence it breaks —** point 10: *"When its work is landed or discarded, every workspace and
branch it has is deleted, as one. None is left behind."* And point 3: *"A `cc/` or native workspace with
no registration, **and any branch an agent created**, counts as finished work of an ended session and is
handled under point 5."*

**Reproduction** (`late-record-stray`, and again as `late-record-rename`):

```
python3 -B docs/verification/certification-frank-window-and-target-2026-09-12-probe.py \
    <workspaces.py at 2bc413df> late-record-stray
```

```
    integration record at spawn              None
    created_branches (record missing)        []
    attribution-skipped events               1
    Rich records it afterwards               main
    land after the recording                 landed
    branches after the land                  ['main', 'spare']
    pending after the land                   []
```

The agent created `spare` inside one ordinary tool call, on its own unlanded tip. Because no branch was
recorded at that moment, `observe_created_refs` reached `if why_not:` and skipped the observation
(`workspaces.py:1873–1882`). **Attribution happens at observe time and never again.** Recording the
branch afterwards unblocks the land but cannot go back for what was skipped, so the land succeeds, the
workspace and the agent's own branch are deleted, `spare` remains, and the item is not pending — nothing
in the system will ever pick it up (`spare` is not `cc/`-named, so the unregistered scan does not see it
either). `late-record-rename` is the same result with the agent's own renamed branch: `renamed-work`
left behind, `pending []`.

**It is a regression:** both cases HOLD at `84e12d32`, where the floor guaranteed a record existed.

**The control proves the cause is the ORDER of the recording, not the shape:** `record-first-control`
runs the identical body with the branch recorded before the spawn and HOLDS on both libraries.

### D2 — in the same state, a commit that reached no integration branch is reported LANDED

**The sentence it breaks —** point 5: *"When an agent finishes, everything it produced is landed (or,
where point 7 applies, discarded). Every time, all of it, no exceptions, no deferral."* And point 8:
*"Deletion therefore never loses anything that was meant to land."*

**Reproduction** (`late-record-side`):

```
    created_branches (record missing)        []
    land after the recording                 landed
    its side commit reached main             False
    branches after the land                  ['main', 'sidework']
    pending after the land                   []
    side commit still only on 'sidework'     9f0f0ff1940c98c63bbab232b1f5490be24f9002
```

Line for line the parent's `concurrent-side` failure — `land → landed` beside `side commit in main
False` — reached by a different door. This is the defect item 1 exists to end, alive on the branch that
ends it. HOLDS at `84e12d32`.

**And it is not only reachable through a missing record.** With the branch properly recorded, my c3
case `outside-side` produces the same three lines (`land → landed`, side commit in main `False`,
`pending []`) — see "the backgrounded-process gap" below. In my unmodified c3 run that case read HOLDS
only because the missing record refused the land; with the record present, which is the state point 14
requires, it is BROKEN.

### D3 — one refused `PreToolUse` widens the end-of-run window to the agent's whole run, and a ref created outside every call is attributed to it and destroyed

**The sentence it breaks —** point 8: *"Deletion therefore never loses anything that was meant to
land."*

`record_end` and `stop` now call `observe_created_refs(rec, all_open=True)`, which consumes **every**
open window and intersects their `before` sets — so the comparison runs from the OLDEST open window.
The engineer's own comment states the leak that makes this reachable, at `workspaces.py:1575–1578`:

> *"a PreToolUse that a guard then REFUSES leaves a snapshot no Post will ever consume"*

`barrier()` snapshots for every `REGISTERED`, unfinished agent before any other guard has ruled
(`workspaces.py:2442`), and the engine ships several blocking `PreToolUse` guards. One leak is enough.

**Reproduction** (`leaked-window-widens`):

```
    windows left open by the refused call     1
    created_branches before the end of run    []
    created_branches after the end of run     ['rich/rescue']
    branches after the discard                ['main']
    rich/rescue survived                      False
```

`rich/rescue` was cut by Rich **between two of the agent's tool calls**, with no window open but the
leaked one. At the end of the run it is attributed to the agent and `discard` deletes it with
`git branch -D`.

**Control, isolating the cause to the leak** (same probe, the single line `s.pre(aid, "tu-refused")`
replaced by `pass`; committed as `…-logs/c4-control-no-refused-call.py`):

```
    windows left open by the refused call     0
    created_branches after the end of run     []
    branches after the discard                ['main', 'rich/rescue']
    rich/rescue survived                      True
```

At `84e12d32` the case HOLDS, because the single slot had already been consumed by the last call's
Post. **This is new.**

### D4 — parts of the system outside `workspaces.py` still keep their own answer to "has it landed", and assume main

**The sentence it breaks —** point 14, the sentence added mid-round: *"Every part of the system that
needs to know whether work has landed asks the same question: is it in the branch recorded for this
work? None of them is allowed its own answer, and none of them assumes main."*

**The load is this repository, today.** This round's own base is on the dev branch, not main:

```
$ git merge-base --is-ancestor 84e12d32 main               ; echo $?   → 1
$ git merge-base --is-ancestor 84e12d32 dev/workspace-spec ; echo $?   → 0
```

Four live consumers, none of them declared out of scope in the brief:

1. **`engine/scripts/hooks/guard-idle-land.py`** — a registered `Stop` hook. It confirms a land with
   `merge-base --is-ancestor <ref> HEAD` (line 489) and a push with `branch@{upstream}` (line 494–496).
   `HEAD` of whatever checkout it is pointed at is its own answer, and in the richos main checkout today
   that is `main`. A merge onto `dev/workspace-spec` is not counted as a land at all.
2. **`engine/scripts/lib/land-residue-gate.py`** — `--branch` default `main` (lines 8, 125).
3. **`engine/scripts/lib/land-completeness.py`** — `analyze(repo, main="main")` (line 332), `--main`
   default `"main"` (line 523), and the predicate itself `merge-base --is-ancestor <branch> <main>`
   (line 220). Reached from the live `scripts/hooks/task-completed-handoff.sh`.
4. **`engine/scripts/lib/completion-proof.py`** — hard-codes `integration='refs/heads/main'` (line 234)
   and **rejects** any proof whose `integration_ref` is anything else (lines 247, 261). This one cannot
   be corrected by an argument; it refuses a non-main integration branch by construction.

`guard-unresolved-claims.py` is the fifth and is declared next round's. The point of listing these is
that the class the CEO named is larger than the one instance he named, so the next round is scoped for
five, not one.

---

## Rulings asked for

### On the engineer's claims about my c3 cases — every one is true

Verified by re-deriving the adapted copy myself (I did not run his), then running seven cases against
this branch (`…-logs/frank-c3-recorded-on-branch.txt`):

| his claim | my result |
|---|---|
| my fixture records no integration branch, so the cases fail on that, not on attribution | **true** — every BROKEN case in my unmodified run printed `created_branches []` and `REFUSED … no branch is recorded` |
| `floor-trap` HOLDS **unmodified** | **true** — unmodified run, case 3: `floor wrote None`, `Rich recorded dev/workspace-spec`, `land → landed`, workspace gone |
| `serial-stray` holds with the branch recorded | **true** — `created_branches ['spare']`, `land after → landed`, `branches ['main']` |
| `serial-side` holds with the branch recorded | **true** — `created_branches ['sidework']`, `REFUSED … sidework … is not in main` |
| `serial-rename` holds with the branch recorded | **true** — `created_branches ['renamed-work']`, `landed`, `branches ['main']` |
| `floor-timing` cannot hold because there is no floor | **true, and it is a stale assertion, not a defect** — the case asserts `integration_record(...)["branch"] == "main"` in order to locate *when the floor reads the branch*. With the floor gone the question no longer exists. Obsolete, correctly so. |
| my unmodified probe gives 5/10 (was 6/10) | **true, and the five are exactly the five he named** — `outside-stray, floor-timing, serial-stray, serial-side, serial-rename` |

He did not paper over a single one of these, and he did not touch my files. Credit where it is due.

### On the backgrounded-process gap (`outside-stray` / `outside-side`)

**Ruling: it is inside the CEO's page, it is a defect, it is NOT a regression — and his reason for
declining to close it is defeated by his own build.**

1. **Inside the page.** Point 3 says *"any branch an agent created"* and point 10 says *"None is left
   behind."* Neither carries an exception for a branch the platform gave no window to observe. The page
   states the outcome; it does not permit a mechanism that cannot reach it.
2. **The load exists on this machine, measured today.** A backgrounded Bash call returned, a later tool
   call ran at `t=1789213567.410`, and the backgrounded process was still alive — it wrote its own end
   at `t=1789213570.340`, having started at `t=1789213564.299`. The process outlived its own tool call
   by 6.0 s and was still running 3.1 s into a *subsequent* call. Anything it creates after a Post and
   before the next Pre is outside every window by construction, exactly as declared.
3. **It is worse than "a stray left behind".** With the branch recorded — the state point 14 requires —
   `outside-side` gives `land → landed`, `its side commit is in main False`, `pending []`. Same three
   lines as D2. Declaring it as "a stray" undersells it.
4. **His argument is sound in the abstract and false in fact.** He says closing it means widening the
   window to the whole run, which widens the indistinguishable class. Correct — and **his build already
   widens the window to the whole run, unconditionally, whenever one call is refused** (D3). He is
   paying the full price of the wide window and getting none of its benefit. The two positions cannot
   both stand: either a run-wide comparison is acceptable, in which case `outside-stray` can be closed,
   or it is not, in which case the leaked windows must not be intersected at the end of the run.

Not a regression: it fails at `84e12d32` too. It stays a declared, named gap — but the declaration
should say that it can strand commits, not only refs.

### On the escalation `esc-20260912T112834Z-91a77eef`

**Ruling: the escalation is correct to exist and it understates what it found. Against point 10, this is
not an operational precondition; it is defect D1, and the answer to the question it asks cannot repair
it.**

The escalation asks: *"Before the next spawn in richos, does Rich run `workspaces.sh integration …`?"*
It reports the consequence as: with no record a ref is not attributed, the land refuses by design, and
once the branch is recorded the stray is left behind.

Three things are true that the escalation does not say:

1. **The damage is retroactive and permanent, not prospective.** Attribution is a one-shot observation
   at `PostToolUse`. Recording the branch at *any* later moment — including before the very next spawn —
   does nothing for the refs already created. Rich answering "yes" fixes future agents and no existing
   one.
2. **It is not confined to strays. It strands commits and reports LANDED over them** (D2), which is the
   failure class this round was convened to end.
3. **`attribution-skipped` holds nothing.** `grep -rn "attribution-skipped"` across the repository
   returns exactly one producer — `workspaces.py:1880` — and **no consumer**. It is not read by
   `land()`, by `pending()`, by the point-5 gate or by any hook. It is an audit line, and the land
   proceeds over it. "Auditable rather than silent" is accurate; "held rather than lost" it is not.

Point 10's sentence — *"every workspace and branch it has is deleted, as one. None is left behind"* —
is unconditional. It does not say "provided the branch was recorded in time."

I also note, without calling it a defect: **no integration record exists in the live registry today**
(`~/.claude/state/workspaces/` contains `agents/ done/ ids/ sessions/ events.jsonl repos.json lock` and
no `integration.json`), while `repos.json` names both `/Users/alex/ab/richos` and
`/Users/alex/ab/femcboost`. The moment this installs, every land in both repositories refuses until the
command is run twice. That is the design working, and it is the reason D1's window is not a rare one —
it is the state the machine is in right now.

---

## Beyond the page

Not defects. No sentence of the page is broken; recorded because they are load-bearing for the next
round.

1. **`_MAX_OPEN_CALLS` eviction loses nothing.** My case 6 opens 70 refused windows after a live one,
   evicting it; the ref created in the live call is NOT attributed at its own Post — but it *is*
   attributed at the end of the run by `all_open`. Nothing is lost, and 64 concurrent open calls for one
   agent is not a load that exists on this machine. Worth knowing that the recovery exists and that it
   depends on the end-of-run signal arriving.
2. **The intersection comment says the opposite of what the code does.** `workspaces.py:1858` reads
   *"With more than one window open, the widest one decides"*, and the code is `before = b if first else
   (before & b)` — an intersection, which yields the *narrowest* `before` and therefore the *widest*
   set of refs judged new. What the code does is what was intended; the sentence describes the wrong
   object, and it is the sentence a future reader will trust.
3. **Both of the round's own test fixtures had to be taught to record the branch to keep working** —
   `workspaces.test.py` `setUp` (+2 lines), `workspaces-e2e.test.sh` E0.1 (+2 recordings),
   `guard-sealed-worktree.test.sh` (+1). That is not a criticism of the change; it is the clearest
   available evidence that the recording is now an unavoidable precondition of every path, which is
   what makes D1's window ordinary rather than exotic.
4. **`_key_segment` truncates at 120 characters**, so two keys agreeing on their first 120 characters
   would share one refs directory. Not reachable with today's `<session_id>--<name>` keys (~68
   characters); it becomes reachable if key composition ever changes.
5. **Legacy slot cleanup uses the raw key.** `_drop_snapshots` unlinks `_p("refs", key + ".json")` for
   the pre-2026-09-12 single slot while everything else uses `_key_segment(key)`. Harmless for today's
   keys, inconsistent with the rest of the file.
6. **Expected and confirmed, not counted against the round:** `contract-integrity-probe.sh` is RED
   (`hooks.json` changed, `install.sh` forbidden), and `observe-created-refs.sh` is registered in the
   branch's `hooks.json` (matcherless `PostToolUse`) but is not present in the installed engine at
   `~/.claude/richos-engine/`, which also has no `scripts/lib/workspaces.py`. Nothing in this review
   depended on the installed copy.

---

## What I ran, with exit codes

All from `/Users/alex/ab/richos-wt/frank-opus-c4`. `PARENT` =
`git show 84e12d32:engine/scripts/lib/workspaces.py` extracted to scratch (sha256
`0a3db713…fcca7bc3`); `BRANCH` = this worktree's `engine/scripts/lib/workspaces.py` (sha256
`1d17d32a…041c916`).

| # | command | exit | result |
|---|---|---|---|
| 1 | `python3 -B docs/verification/workspace-call-window-and-recorded-target.probe.py $PARENT` | 1 | **0/5** — all five BROKEN |
| 2 | `python3 -B docs/verification/workspace-call-window-and-recorded-target.probe.py $BRANCH` | 0 | **5/5** |
| 3 | `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py $BRANCH` | 0 | **7/7** |
| 4 | `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py $PARENT` | 0 | **7/7** (no regression either way) |
| 5 | `python3 -B engine/scripts/lib/workspaces.test.py` | 0 | **52 run, 0 failed** |
| 6 | `bash engine/scripts/workspaces-e2e.test.sh` | 0 | **47 passed, 0 failed** |
| 7 | `bash engine/scripts/hooks/guard-sealed-worktree.test.sh` | 0 | **10/10 mutants** |
| 8 | `bash engine/scripts/lib/workspaces.mutation.sh` | 0 | **38/38 mutants**, incl. all four new ones (`p14-floor-restored`, `p14-frozen-copy-restored`, `p03-one-window-per-agent`, `p03-end-of-run-consumes-one-window`), wall 4m54.9s |
| 9 | `python3 -B <my c3 probe, unmodified> $BRANCH` | 1 | **5/10**; BROKEN: `outside-stray, floor-timing, serial-stray, serial-side, serial-rename` |
| 10 | `python3 -B <my c3 probe + my own recording adapter> $BRANCH serial-stray serial-side serial-rename floor-trap floor-timing outside-stray outside-side` | 1 | **5/7**; BROKEN: `outside-stray, outside-side` |
| 11 | `python3 -B docs/verification/certification-frank-window-and-target-2026-09-12-probe.py $BRANCH` | 1 | **1/6** |
| 12 | `python3 -B docs/verification/certification-frank-window-and-target-2026-09-12-probe.py $PARENT` | 0 | **6/6** |
| 13 | `python3 -B …-logs/c4-control-no-refused-call.py $BRANCH leaked-window-widens` | 0 | **1/1** (the control for D3) |
| 14 | `find ~/.claude/state/workspaces -exec stat …` before and after, `diff` | 0 | **identical — the real registry was neither created nor touched** |

Full captured output of 1–12 is in
`docs/verification/certification-frank-window-and-target-2026-09-12-logs/`.

---

## What would change my verdict

D1 and D2 are one defect with two faces: a repository with no recorded integration branch is a state in
which refs are created and never attributed. D3 is one defect. D4 is four files. None of the three
touches the two items themselves — item 1 and item 2 are sound, and I would certify either on its own.
The round is refused on what deleting the floor left open and on what the end-of-run window now
consumes, not on what it fixed.
