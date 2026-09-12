NOT CERTIFIED

# Certification — the four fixes on `cc/zach-opus-f4`

**Reviewed:** `e41e00f9faa9faad667633d79924bd92ae483ab8` (four commits over `d39e49d9`), from the
worktree `/Users/alex/ab/richos-wt/sage-opus-c1` on branch `cc/sage-opus-c1`.

**Yardstick:** `docs/plans/worktree-spec-2026-09-11.md`, and nothing else. Verified unchanged on
this branch:

```
$ git diff --stat d39e49d9 e41e00f9 -- docs/plans/worktree-spec-2026-09-11.md
(no output, exit 0)
```

**Reviewer:** Sage, independently. I did not read Frank's worktree, his branch, or any file he
writes.

---

## Verdict

| Fix | Point | Verdict |
|---|---|---|
| 1. The answer allowance is consumed once per item and state | 5 | HOLDS (defect D2 recorded against the other half of the same sentence) |
| 2. Branch attribution from the platform's agent id, not git's reflog | 3, 8, 10 | **REFUSED** (defect D1) |
| 3. The gate answers inside a budget | 5 | HOLDS |
| 4. Read-only agents are registered, so the lock-out can find them | 9 | HOLDS |

Three of the four hold. The certification is refused on fix 2, whose defect needs no
interpretation of the page and reproduces in the round's own scenario the moment a second agent is
running — which is this machine's normal state and its state right now.

---

## Fix 1 — the answer allowance is consumed. HOLDS.

The page: *"Two things are always allowed, and only these two: answering the CEO or obeying his stop
order (the reply names the pending work, which is handled right after)."*

The allowance is now spent per item, fingerprinted on the reason it is pending, what it waits on,
its workspaces and the tip of every branch it has (`_allowance_state`, `workspaces.py:1966`), and it
returns only when that fingerprint changes. I ran the shipped test and its mutant:

```
PASS  test_point_05_the_answer_allowance_is_spent_once_per_item
PASS  p05-allowance-never-spent — removing it turns
      "test_point_05_the_answer_allowance_is_spent_once_per_item" red  [26.4s]
```

I then ran my own probe with the CEO's *other* always-allowed case, his stop order
(`probe-fix1-allowance.py`, reproduced in D2 below). Turn 1 allowed, turn 2 refused. The mechanism
does what the brief says it does. What it also does is D2.

## Fix 2 — branch attribution from the agent id. REFUSED.

The page: point 3 counts *"any branch an agent created"*; point 10, *"every workspace and branch it
has is deleted, as one"*; point 8, *"Deletion therefore never loses anything that was meant to
land."*

The shipped tests pass, and both mutants are load-bearing:

```
PASS  test_point_10_branches_created_in_a_workspace_go_with_it
PASS  test_point_10_a_branch_rich_cut_from_its_branch_is_not_the_agents
PASS  p10-branch-not-attributed  [24.8s]
PASS  p10-window-not-closed-at-end  [24.7s]
```

Both tests run exactly one agent. `observe_branches` watches the whole **repository**, not the
agent's workspace, so every ref that appears while **any** agent's window is open is recorded as
that agent's. With a second agent running — the normal case — the round's own scenario inverts.
See D1.

## Fix 3 — the gate answers inside a budget. HOLDS.

The page: *"This is a guarantee, not a habit: it holds whether or not Rich remembers."*

The budget is threaded where the unbounded work is: `uncommitted()` checks the deadline before it
starts, inside the ignored-entry walk every 64 entries, and hands the remaining time to `git status
--ignored` as a subprocess timeout; `git()` returns 124 for a timeout so the caller can tell "did
not finish" from "could not run"; `pending()` drops the auto-land rather than the list and reports
which items it did not check; both gates say so in their own words.

The shipped test and its mutant:

```
PASS  test_point_05_the_gate_answers_inside_its_budget
PASS  p05-gate-has-no-budget — removing it turns
      "test_point_05_the_gate_answers_inside_its_budget" red  [26.3s]
```

The work being bounded is real work, measured on this machine rather than assumed:

```
$ cd /Users/alex/ab/femcboost/.claude/worktrees/agent-a53504db65ce17a7c
$ /usr/bin/time -p git status --porcelain=v1 -z --untracked-files=normal --ignored > /dev/null
real 1.75
```

I looked for a path inside the gate that is still unbounded under a load that exists here, and
found none that matters: the process sweep that runs after the land decision costs `lsof` 0.10 s
and `ps` 0.01 s on this machine, and the repository scan costs 0.00 s (all measured, below). The
theoretical overrun I could construct needs a load I cannot show exists here, so it is recorded
under "Beyond the page" and is not a finding.

## Fix 4 — read-only agents are registered. HOLDS.

The page: *"A restarted agent is refused every tool."*

I drove the whole chain through the same entry points the hooks use — the guard's
`register-readonly`, `PostToolUse[Agent]`, `SubagentStop`, then `barrier` — rather than through the
module's internals (`probe-fix4-readonly.sh`):

```
== 1. the spawn guard registers the read-only spawn ==
REGISTERED	sess-ro-probe-0001--ro-toolu_ro_probe_01
== 3. PostToolUse[Agent] carries the agentId ==
== 4. while it runs, its Bash call is allowed ==
REGISTERED	readonly-toolu_ro_probe_01
== 5. its run ends ==
== 6. the platform restarts it: every tool refused (point 9) ==
FINISHED	agent aexploreprobe01 (readonly-toolu_ro_probe_01) is finished: ...
FINISHED	agent aexploreprobe01 (readonly-toolu_ro_probe_01) is finished: ...
FINISHED	agent aexploreprobe01 (readonly-toolu_ro_probe_01) is finished: ...
== 7. and it blocks nothing: the turn may end ==
   gate-stop exit=0
== 8. status ==
session: sess-ro-probe-0001
pending: none
```

The chain depends on `PostToolUse[Agent]` carrying an `agentId` for a read-only spawn, which the
fix never states and which nothing in the suite proves — the test calls `bind_agent` directly. So I
checked the platform on this machine instead of taking it on trust. Across all 49 femcboost
transcripts there are four read-only Agent results; three are hook errors and the one that
launched carries `agentId`:

```
$ python3 survey-readonly-results.py
transcripts scanned: 49
read-only Agent results by subagent_type: {'Explore': 4}
result shapes: {'dict_with_agentId': 1, 'dict_no_agentId': 0, 'text_result': 0, 'hook_error': 3}
```

One observation, not a proof, but it is the only evidence this machine has and it points the same
way as the fix. The precondition the fix rests on is separately pinned
(`test_point_07_an_agent_with_no_workspaces_at_all_is_landed_not_pending`), and my probe confirms it
end to end: the read-only record was auto-landed into `done/` and `status` reports `pending: none`.

---

## Defects

### D1 — a branch created by anyone, while any agent is running, becomes that agent's, and is deleted with it

**The CEO's sentences it breaks.** Point 3: *"any branch an agent created"*. Point 8: *"Deletion
therefore never loses anything that was meant to land."*

**What happens.** `observe_branches` snapshots every ref in the repository at an agent's tool call
and attributes anything new at the next one. It has no way of knowing who created the ref. Any
branch that appears in that repository while that agent's window is open is recorded as the
agent's, and `_branch_targets` then hands it to `delete_branch` when the agent is landed or
discarded.

**Reproduction — the round's own scenario, plus one other agent.** This is
`test_point_10_a_branch_rich_cut_from_its_branch_is_not_the_agents` with a second agent running:
agent R finishes, Rich cuts a rescue copy of its work with a commit of his own on top, and agent Y
(unrelated, still running, as agents are) makes one more tool call.

```
$ python3 probe-fix2-rescue.py
rescue-rich created, tip d774548a0cd7
Y's created_branches: [['.../entity', 'rescue-rich']]
after R landed, branches: ['main', 'rescue-rich', 'worktree-agent-ayotheragent01']
rescue-rich survived R's land = True
discard recorded tips: {'...:worktree-agent-ayotheragent01': 'b7cf8601...',
                        '...:rescue-rich': 'd774548a0cd77812a992046e2d7e222de8c6d46f'}
after Y was discarded, branches: ['main']

RESULT: rescue-rich survived = False
RESULT: Rich's rescue commit d774548a0cd7 still reachable = True
RESULT: is it in main? = False
```

Rich's rescue branch is gone. Its tip is recorded in Y's discard record, so the commit is
recoverable by someone who knows to look there before garbage collection; the ref is not, and the
work is not in main.

**This is a regression, not a pre-existing condition.** The same probe against the parent commit,
`d39e49d9` (`git show d39e49d9:engine/scripts/lib/workspaces.py`), on the same facts:

```
$ python3 probe-fix2-rescue-parent.py
rescue-rich created, tip a462b28fb676
Y's created_branches: None
workspaces.SpecError: zach-opus-r is not landed yet: rescue-rich (a462b28fb676) is not in
  .../entity at d67578677530. Merge it, then land it; or discard it (point 7).
```

The old reading attributed the rescue copy to R and held R's land hostage — the bug this round set
out to fix, and it loses nothing. The new reading gives the copy to an unrelated agent and
**deletes** it. The failure mode moved from blocking to destroying.

**The plain form of the same defect**, from `probe-fix2-window.py` (case 1): Rich runs
`git branch keep-rich-work` in the main checkout while one agent is running; it is attributed to
that agent and deleted when the agent is discarded. Note that the fix's own commit message lists
this exact command as a case the old code *"missed (correctly)"*.

**The load is this machine, now.** Concurrent agents in one repository is not a constructed
condition:

```
$ git worktree list          # in /Users/alex/ab/richos-wt/sage-opus-c1
/Users/alex/ab/richos                             dcabcbd9 [main]
/Users/alex/ab/richos-wt/codex-owned-outcome-...  ...      [codex/...]   (5 codex worktrees)
/Users/alex/ab/richos-wt/frank-opus-c1            562af078 [cc/frank-opus-c1]
/Users/alex/ab/richos-wt/sage-opus-c1             e41e00f9 [cc/sage-opus-c1]
/Users/alex/ab/richos-wt/zach-opus-f4             e41e00f9 [cc/zach-opus-f4]
/Users/alex/ab/richos-wt/zach-opus-spec2          d39e49d9 [cc/zach-opus-spec2]
```

Three `cc/` agent worktrees in one repository at this moment, and this session's own agent list is
`main, zach-opus-d1, zach-opus-f4, zach-opus-p2a` plus me. The second half of the load — a ref
appearing in that repository during a window — is produced by `create-teammate-worktree.sh` on
every spawn, and by every rescue copy Rich cuts. `probe-fix2-window.py` case 2 shows the spawn
variant: a newly spawned agent's branch is attributed to the agent that was already running.

### D2 — the CEO's stop order is refused the second time he gives it

**The CEO's sentence it breaks.** Point 5: *"Two things are always allowed, and only these two:
answering the CEO or obeying his stop order (the reply names the pending work, which is handled
right after)."*

The gate cannot distinguish "answering the CEO" from "obeying his stop order" — both are a turn a
person started whose reply names the pending work — so both spend the one allowance, and both are
refused the second time while the item has not moved. When the CEO's order is *stop*, nothing can
move, because stopping is what he asked for.

```
$ python3 probe-fix1-allowance.py
TURN 1 (his stop order, obeyed): allowed = True
TURN 2 (his stop order, repeated): allowed = False
--- what the gate says ---
=== That reply has already used its one allowance (point 5) ===
  Spec: ... — "the reply names the pending work, which is HANDLED RIGHT AFTER".
  Naming it a second time is not handling it. ...
  Handling it is the only way past this.
```

**Why this is his to rule on and not mine.** The clause the fix is built on and the clause it
breaks are halves of one sentence: *"always allowed"* and *"which is handled right after"*. The
round read the parenthesis as binding, which is a defensible reading of a sentence he wrote to stop
exactly the behavior the fix removes. I cannot settle which half governs from the page, so I record
it rather than refuse on it. There is an escape inside the build — recording what the item waits on
moves it, which returns the allowance — but taking it requires Rich to record a wait that is true.

---

## Beyond the page

These are not defects. The page does not state them, and I record them only so they are not
discovered later as if nobody had looked.

1. **The budget bounds the auto-land, not everything the Stop gate does.** `scan_unregistered`,
   `retry_due`, and `_delete_chain` after a land decision all run outside the deadline. I measured
   each component on this machine and none of them is close to the 60 s Stop hook: repository scan
   0.00 s, `lsof` 0.10 s, `ps` 0.01 s, `git worktree remove` bounded by its own 300 s timeout but
   never reached here. The overrun I can describe needs a load I cannot show exists on this
   machine, so it is a note, not a finding.

2. **Deterministic starvation is possible under a sustained backlog.** `pending()` walks
   `all_agents()` in sorted key order and stops auto-landing when the budget runs out, so the same
   late-sorted items are the ones left unchecked every turn. At the measured 1.75 s per workspace,
   a backlog past roughly a dozen checkable workspaces would starve its tail. Not observed; there
   is no such backlog here now.

3. **A read-only spawn can now be refused where it never could be.** `register_readonly` raises
   when the session's process identity cannot be read, and point 3 makes that a refusal of the
   spawn. That is the page's own rule, applied to a class of spawn that was previously unrefusable.
   Correct by the page; worth knowing.

4. **Every read-only spawn now leaves a record.** It is auto-landed at once and never becomes
   pending (I confirmed this), but `done/` grows by one file per `Explore` call.

5. **Cost of the new observation, measured rather than assumed.** `observe_branches` adds one
   `for-each-ref` per repository on every worker tool call. femcboost has 5 local branches and
   richos 10; both enumerate in 0.00 s. There is no performance finding here.

---

## What I ran

Everything below ran with `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR`, `RICHOS_WORKSPACES_DIR` and
`RICHOS_SESSIONS_DIR` redirected into scratch by a wrapper script. Nothing was installed, nothing
was copied into `/Users/alex/ab/richos/engine`, nothing left this branch, and the main checkout was
not touched.

| What | Exit | Wall |
|---|---|---|
| `engine/scripts/lib/workspaces.test.py` — 42 tests, 0 failed | 0 | 15.50 s |
| `engine/scripts/hooks/guard-worktree-isolation.test.sh` — all 165 passed | 0 | 25.49 s |
| `engine/scripts/workspaces-e2e.test.sh` — 39 passed, 0 failed | 0 | 7.04 s |
| `engine/scripts/lib/workspaces.mutation.sh` — 25 proven load-bearing | 0 | 89.53 s |
| `engine/scripts/hooks/guard-worktree-isolation.mutation.sh` — 23 proven, 0 unproven | 0 | 163.83 s |
| `probe-fix2-window.py` (mine) — attribution of a foreign ref | 0 | 0.73 s |
| `probe-fix2-rescue.py` (mine) — D1 reproduction | 0 | 0.72 s |
| `probe-fix2-rescue-parent.py` (mine) — the same against `d39e49d9` | 1 (expected: the parent refuses the land) | 0.31 s |
| `probe-fix4-readonly.sh` (mine) — the read-only chain through the hook entry points | 0 | 0.57 s |
| `probe-fix1-allowance.py` (mine) — D2 reproduction | 0 | 0.26 s |
| `survey-readonly-results.py` (mine) — 49 transcripts, result shapes only | 0 | 0.68 s |

My probes are in the session scratchpad at
`/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/sage-c1/`.
They are outside the repository deliberately: they are evidence for this certification, not
engine material, and nothing of mine belongs in the engine's suites.

## The sandbox held

The operator's real registry at `~/.claude/state/workspaces` was fingerprinted before the first
command (size, mtime, inode of every entry, plus sha256 of `events.jsonl` and `repos.json`) and
again after the last:

```
$ diff registry-baseline.txt registry-final.txt
REAL REGISTRY UNCHANGED
```

Every write landed in the scratch registry instead:

```
$ ls -R /tmp/sage-sb/sb/wsdir
agents  done  events.jsonl  ids  lock  repos.json  sessions
./done:  sess-ro-probe-0001--ro-toolu_ro_probe_01.json
./ids:   aexploreprobe01
```

`workspaces.py` is confirmed **not** installed in the live engine
(`/Users/alex/.claude/richos-engine/scripts/lib/workspaces.py`: no such file), so nothing I ran
could have reached a live session.
