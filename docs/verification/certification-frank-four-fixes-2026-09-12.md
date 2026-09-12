NOT CERTIFIED

# Certification — the four fixes of `cc/zach-opus-f4`

**SHA reviewed:** `e41e00f9faa9faad667633d79924bd92ae483ab8` (branch `cc/zach-opus-f4`, four commits
over `d39e49d9`), carried on branch `cc/frank-opus-c1` in worktree `/Users/alex/ab/richos-wt/frank-opus-c1`.

**Yardstick:** `docs/plans/worktree-spec-2026-09-11.md`, unchanged on this branch
(`git log --oneline -1 -- docs/plans/worktree-spec-2026-09-11.md` → `02a7ff38`). Nothing else.

**Verdict at a glance**

| Fix | Point | Verdict |
|---|---|---|
| 1 — the answer allowance is consumed once per item and state | 5 | **HOLDS** |
| 2 — branch attribution from the platform's record, not git's reflog | 8, 10 | **REFUSED** |
| 3 — the gate answers inside a budget | 5 | **HOLDS** |
| 4 — read-only agents are registered, so the lock-out can find them | 9 | **HOLDS** |

Three of the four hold. The second one is refused, and it is refused because it loses work that
another agent is still writing, and because it blocks the land of the agent it was written for.
It is a **regression**: the same probe passes on the parent commit `d39e49d9` and fails here.

Nothing was installed, merged, pushed or deployed. Every probe ran with `HOME`,
`CLAUDE_CONFIG_DIR`, `TMPDIR` and `RICHOS_WORKSPACES_DIR` redirected into scratch; the real
registry at `~/.claude/state/workspaces` is byte-for-byte and mtime-for-mtime unchanged
(evidence at the end), and `/Users/alex/ab/richos/engine/scripts/lib/workspaces.py` still does
not exist, so the spec remains uninstalled.

---

## Fix 1 — Point 5, the allowance is consumed. **HOLDS**

*"Two things are always allowed, and only these two: answering the CEO or obeying his stop order
(the reply names the pending work, which is handled right after)."*

The allowance is now spent per item and returns only when the item's fingerprint moves
(`_allowance_state`: why it is pending, what it waits on, its workspaces, and the tip of each of
its branches). Its test is present and its mutant turns that test red:

```
$ bash scripts/lib/workspaces.mutation.sh
  PASS  p05-allowance-never-spent — removing it turns
        "test_point_05_the_answer_allowance_is_spent_once_per_item" red  [25.3s]
```

I checked the obvious way for a consumed allowance to become a trap — an item that can never move,
so the CEO never gets another word. There is an exit and it works (probe B2):

```
$ python3 probe_b.py   # test_b2_an_exit_exists_after_the_allowance_is_spent ... ok
after recording what it waits on, turn end = True
```

No defect. One thing for the CEO to rule on is in "Beyond the page" below.

## Fix 2 — Points 8 and 10, branch attribution. **REFUSED**

### What it does

`observe_branches` snapshots every branch in each repository the agent has a workspace in, at each
of the agent's tool calls (`barrier`) and at its end of run. **Any branch that appears between two
of those snapshots is recorded as that agent's**, and is then landed-or-deleted with it.

That is not "the platform says whose branch it is". The platform's record says *this agent made a
tool call*; it does not say *this agent created that ref*. Attribution is by co-occurrence in time
— which is a guess, and the page closes with *"No liveness guessing of any kind."*

### The defect, and the sentences of his page it breaks

**(a) It deletes a branch that was never the agent's.** Point 8: *"Deletion therefore never loses
anything that was meant to land."*

```
$ python3 probe_a.py   # test_a4_discard_of_A_deletes_the_other_agents_branch
branches after discard(A): ['main']
AssertionError: 'cc/zach-opus-b4' not found in ['main']
        : a branch that was never A's was deleted with A
```

`cc/zach-opus-b4` was created by nobody but the lead, in the repository, while agent A happened to
be running. Discarding A deleted it.

**(b) It blocks the land of the agent it belongs to.** Point 5: *"Rich lands 100% of everything
after the agent is finished — guaranteed... Every time, all of it, no exceptions, no deferral."*
Point 4: *"Landed means the workspace AND the branch are deleted — automatically, with nothing left
undecided."*

```
$ python3 probe_a.py   # test_a2_land_of_A_is_held_hostage_by_the_other_agents_branch
land(A) REFUSED: zach-opus-a2 is not landed yet:
  worktree-agent-azachopusb20000 (00e79d01acb2) is not in .../entity at 7cdc929cca5c.
  Merge it, then land it; or discard it (point 7).
```

A has committed everything it produced and every branch A actually created is merged into main. It
still cannot be landed, and it cannot be landed until the *other, still-running* agent's branch is
merged. The commit message names this exact failure as the thing it was fixing — *"it held the
agent's land hostage forever, exactly as point 8 forbids"* — and it is still here, reached by a
different road.

**(c) When the other agent is still running, the discard fails and retries forever.** Point 7:
*"Nothing finished is ever left neither landed nor discarded."*

```
$ python3 probe_c.py
A.created_branches = ['cc/zach-opus-c1b', 'worktree-agent-azachopusc1b0000']
A.deletion after discard = {'attempts': 1, ...,
  'last_error': 'branch cc/zach-opus-c1b is still checked out at .../other-wt/zach-opus-c1b;
                 branch worktree-agent-azachopusc1b0000 is still checked out at ...'}
```

git refuses to delete a branch checked out in a live worktree, so B's work survives *this* attempt
— and A is left undecided, retried under point 13 until it reaches the CEO as a failure. The
moment B's worktree goes away, a retry deletes B's branch outright, which is case (a).

**(d) It attributes a branch the lead cut in the MAIN CHECKOUT.** Point 3: *"any branch an agent
created"*.

```
$ python3 probe_a.py   # test_a3_a_branch_the_lead_cuts_in_the_main_checkout_is_the_agents
A.created_branches = [['.../other', 'keep-cc-a3']]
AssertionError: 'keep-cc-a3' unexpectedly found in {'keep-cc-a3'}
```

The commit message lists this as one of the three cases it re-derived, and marks it *"git -C
<main-checkout> branch keep cc/a -> missed (correctly)"*. It is no longer missed.

**(e) It is a regression, not a pre-existing condition.** The same probe against the parent commit
`d39e49d9` (the reflog version this fix replaced), in the same sandbox:

```
$ python3 probe_parent.py
library under probe: .../parentlib/workspaces.py     # git show d39e49d9:.../workspaces.py
PARENT: A's branch targets = ['cc/zach-opus-a1', 'worktree-agent-azachopusa10000']
PARENT: land(A) -> {'landed': True}
Ran 2 tests ... OK
```

On the parent, A owns exactly its own two branches and lands cleanly. The reflog reading was wrong
in the two ways the commit message documents, and it was *narrow* — it could only ever see the
agent's own workspace. The replacement is wider than the agent.

### Reproduction

The probe is committed beside this file, so it is re-runnable rather than quoted:
`docs/verification/certification-frank-four-fixes-2026-09-12-probe.py`. It sandboxes itself through
the shipped suite's own `Env`, so it needs no setup:

```
$ python3 docs/verification/certification-frank-four-fixes-2026-09-12-probe.py
Ran 4 tests in 1.327s
FAILED (failures=4)
```

```
$ python3 probe_a.py    # 4 tests, 4 failures, exit 0 (unittest exit=False), wall 2s
A.created_branches = [['.../other',  'cc/zach-opus-b1'],
                      ['.../entity', 'worktree-agent-azachopusb10000']]
B's own branches    = ['cc/zach-opus-b1', 'worktree-agent-azachopusb10000']
```

Both of B's branches — B's `cc/` branch and B's native branch — are recorded in A's record. The
probe uses the shipped suite's own harness (`workspaces.test.py`'s `Base`), so every step is the
hooks' own call path: `register_cc` / `register_spawn` / `record_start` / `bind_agent` / `barrier`.

### The load is this machine, right now — not a construction

This is the ordinary state of the repository, not a contrived one. In `/Users/alex/ab/richos`:

```
$ git reflog show --date=iso cc/sage-opus-c1  | tail -1
e41e00f9 cc/sage-opus-c1@{2026-09-12 02:11:51 +0100}: branch: Created from cc/zach-opus-f4
$ git reflog show --date=iso cc/frank-opus-c1 | tail -1
e41e00f9 cc/frank-opus-c1@{2026-09-12 02:11:53 +0100}: branch: Created from cc/zach-opus-f4
```

Two agents of the same review round, branched **two seconds apart** into the same repository, then
run concurrently. And in `/Users/alex/ab/femcboost`:

```
$ git worktree list
/Users/alex/ab/femcboost/.claude/worktrees/agent-a3a8b0498a5eb2fe6  [worktree-agent-a3a8b0498a5eb2fe6] locked
/Users/alex/ab/femcboost/.claude/worktrees/agent-a53504db65ce17a7c  [worktree-agent-a53504db65ce17a7c] locked
```

Two native workspaces, both locked, both live, both in the repository both agents have registered.
Whichever of the two made a tool call before the other's branch existed and another after it owns
the other's branch. Nothing has been harmed, because the spec is not installed — which is exactly
why this is the moment to catch it.

## Fix 3 — Point 5, the gate answers inside a budget. **HOLDS**

*"This is a guarantee, not a habit: it holds whether or not Rich remembers."*

`Deadline` is a `SpecError`, so every `except SpecError` that already means "this item cannot be
landed now" handles it; `pending()` drops the auto-land rather than the list; both gates name the
items they could not check. The test asserts no time, only that an exhausted budget still yields an
announced decision, and its mutant turns it red:

```
$ bash scripts/lib/workspaces.mutation.sh
  PASS  p05-gate-has-no-budget — removing it turns
        "test_point_05_the_gate_answers_inside_its_budget" red  [25.9s]
```

Two things run inside the Stop gate before any deadline is consulted — `retry_due()` (its own 5 s
budget, checked only *between* items, so one large `_delete` is unbounded) and `scan_unregistered()`.
I measured the second on this machine's real repositories rather than assert it:

```
$ python3 probe_time.py
femcboost   worktrees=6   (0.004s)  cc/native branches=2  (0.006s)
richos      worktrees=10  (0.004s)  cc/native branches=4  (0.004s)
the read side of scan_unregistered over both repositories: 0.014s
```

14 ms under a 60 s hook. Recorded, not refused on — there is no load on this machine that makes it
matter, and I am not going to construct one.

## Fix 4 — Point 9, read-only agents are registered. **HOLDS**

*"The platform restarts finished agents (14 times observed). A restarted agent is refused every
tool, so it cannot write anywhere, including after its workspace is gone."*

I checked the one way this could have been hollow: whether the lock-out survives the record being
retired. It does — `land()` moves a finished, empty record to `done/`, but `load_agent` reads
`done/` as a fallback and `ids/<agent_id>` is never removed, so `barrier` still answers `FINISHED`
after the record is landed. The shipped test asserts exactly that, in that order:

```
ws.record_end(...); for tool in ("Read", "Bash", "Grep"): ... == "FINISHED"
self.assertTrue(ws.gate_stop(...)[0])            # it is landed here
ws.barrier(...)[0] == "FINISHED"                 # and still refused afterwards
```

```
$ bash scripts/lib/workspaces.mutation.sh
  PASS  p09-readonly-not-registered — removing it turns
        "test_point_09_a_restarted_read_only_agent_is_refused_every_tool" red  [25.6s]
```

One behavior change, and the page sanctions it. A read-only spawn is now refused when the session's
process identity cannot be read (probe B3):

```
read-only spawn REFUSED: the session's process identity could not be read from the operating
system; a registration that could never tell its session ended is refused (point 12)
```

Point 3: *"If registration fails, the spawn does not happen."* That is the page's own answer, so it
is not a defect. It is worth knowing that an `Explore` now costs a registration that can fail.

---

## Beyond the page

These are not defects. His page does not settle them, so they are his to rule on, and none of them
is a reason to refuse this round.

1. **A second consecutive stop order is refused (fix 1).** Observed (probe B1):

   ```
   first stop order allowed  = True
   second stop order allowed = False
   refusal: === That reply has already used its one allowance (point 5) ===
   ```

   His sentence contains both halves of this: *"Two things are always allowed, and only these two:
   answering the CEO or obeying his stop order"* and *"(the reply names the pending work, which is
   handled right after)"*. The implementation reads the parenthesis as the binding condition, which
   is a defensible reading and the one this round was commissioned to build; the other reading is
   that "always" wins and repetition is his prerogative. The item still has exits (probe B2), so
   this is not a deadlock — it is a question of whether the CEO repeating himself is ever refused.
   His call, not mine.

2. **Attribution by time window is a policy choice, not only a bug.** The refusal above stands on
   what the window *does* — it takes branches that are not the agent's. But even scoped correctly,
   "the platform's own record" does not contain who created a ref. If he wants that property, the
   fact has to come from somewhere that records it. I am not prescribing where; that is the
   builder's problem, not the reviewer's.

3. **`done/` grows one record per read-only spawn, and `scan_unregistered` reads all of them on
   every Stop hook** (`all_agents(include_done=True)`). Observed (probe B4): 25 `Explore` spawns
   leave 25 `done/` records. Milliseconds today; it only ever grows. No page sentence covers
   retention, so it is recorded, not refused on.

4. **A duplicated comment line** in `workspaces.py` (line 75 repeats `# impossible ("a guarantee,
   not a habit").`). Cosmetic, named only so it is not rediscovered.

---

## What I ran

Every command below ran with `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR` and `RICHOS_WORKSPACES_DIR`
redirected into the session scratchpad.

| Command | Exit | Wall | Result |
|---|---|---|---|
| `python3 engine/scripts/lib/workspaces.test.py` | 0 | 15 s | 42 run, 0 failed |
| `bash engine/scripts/hooks/guard-worktree-isolation.test.sh` | 0 | 26 s | 165 passed |
| `bash engine/scripts/lib/workspaces.mutation.sh` | 0 | 90 s | 25 mutants, all proven load-bearing |
| `bash engine/scripts/hooks/guard-worktree-isolation.mutation.sh` | 0 | 161 s | 23 proven, 0 unproven |
| `python3 probe_a.py` (mine, fix 2) | 0 | 2 s | 4 run, **4 failed** |
| `python3 probe_b.py` (mine, fixes 1 and 4) | 0 | 1 s | 4 run, 1 failed (B1, recorded above) |
| `python3 probe_c.py` (mine, blast radius) | 0 | 1 s | 1 run, 0 failed |
| `python3 probe_parent.py` (mine, parent `d39e49d9`) | 0 | 1 s | 2 run, 0 failed |
| `python3 probe_time.py` (mine, real-repository cost) | 0 | <1 s | 0.014 s |

The shipped suites are green. They are green because none of them runs two agents in one repository
at the same time; every workspace test uses one agent per assertion. That is the gap my probe fills,
and it is the gap the load on this machine sits in.

## Sandbox evidence

```
$ diff registry-before.txt registry-after.txt && echo "REAL REGISTRY UNCHANGED"
REAL REGISTRY UNCHANGED

$ ls /Users/alex/ab/richos/engine/scripts/lib/workspaces.py
ls: .../workspaces.py: No such file or directory        # nothing installed

$ python3 probe_time.py | head -1
state_dir (must be the sandbox): .../scratchpad/sb/home/.claude/state/workspaces
```

The snapshots are `stat` of every entry under `~/.claude/state/workspaces` (name, size, mtime,
mode), taken before the first probe and after the last. The guard mutation harness reports its own
version of the same guarantee: *"the shipped guard was never opened for writing (contents AND mtime
unchanged)"*.
