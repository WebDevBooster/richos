NOT CERTIFIED

# Frank — certification of attribution by recorded CREATION and of point 14 in the code

**Commit reviewed:** `84e12d32ddb9278d89328667cd75e0eba0394f6f`, three commits over `65dad4d4`, branch
`cc/zach-opus-g1`.
**Reviewed from:** `/Users/alex/ab/richos-wt/frank-opus-c3`, branch `cc/frank-opus-c3`, HEAD
`84e12d32ddb9278d89328667cd75e0eba0394f6f`.
**Yardstick:** the CEO's canonical record at `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`
(fourteen points), read there and nowhere else. The pinned mirror in this repository was not read as the
spec, not edited, and its sha256 pin was not touched.

**Verdict in one line: Item 1 (attribution by recorded creation) and Item 3 (deleting `extra_branches`)
hold. Item 2's point-14 FLOOR is a defect, and it is the reason this is not certified.** The floor does
not merely sit outside the CEO's page; it takes a refusal that heals itself and makes it permanent, and
the configuration it breaks on is the one this machine is in right now.

Nothing was installed, merged, pushed or deployed. No write reached `/Users/alex/ab/richos/engine` or any
main checkout. Every probe redirected `HOME`, `CLAUDE_CONFIG_DIR`, `TMPDIR`, `GIT_CONFIG_GLOBAL` and
`RICHOS_WORKSPACES_DIR` into a scratch tree that was removed afterwards.

**The operator's real registry, measured before the first run and after the last:**

```
$ find /Users/alex/.claude/state/workspaces -type f -exec shasum -a 256 {} \; | sort
55d446fc…  agents/16a15be1-c2c1-4d79-82eb-f09c3f533143--zach-opus-d1.json
d7d7ae5d…  repos.json
e1afe44c…  events.jsonl
e3b0c442…  lock
$ diff registry-before.txt registry-after.txt && echo "REGISTRY IDENTICAL"
REGISTRY IDENTICAL
```

Four files, byte-identical, newest mtime 00:58 local — hours before this worktree existed (created 09:34
local), so before anything in this review could have run. No `refs/`
directory and no `integration.json` were created there, which is how I know nothing tried to write a
registry outside the sandbox.

---

## 1. Verdict per item

### Item 1 — attribution by recorded CREATION: HOLDS

The mechanism does what the commit says, and it closes the three holes it names. The pair is real: the
`PreToolUse` half snapshots every ref in the agent's repositories (`barrier()` → `snapshot_refs`), the new
matcherless `PostToolUse` half compares (`observe()` → `observe_created_refs`), and the four filters keep
co-occurrence in time from being read as authorship. I attacked it from four directions — the engineer's
own probe against both SHAs, my two probes from the previous rounds unmodified, a new probe of my own, and
the shipped suites — and the only thing I could break is the window itself (defect 2 below), not the
attribution logic inside it.

Specifically confirmed:

* The destructive case is fixed. `git branch -D` no longer reaches a pre-existing branch the agent merely
  checked out (case 3, and my own round-2 case B4, both below).
* `codex/` is excluded at the candidate step (`fresh_refs` skips `CODEX_PREFIX`), so point 2 is not at
  risk from this mechanism.
* Filter 2 reads other agents' records including `done/`, so a second agent's whole spawn landing inside
  an open window is not attributed (case 5, and my round-1 probe, 4/4).

### Item 2 — point 14 in the code: the land test HOLDS, the FLOOR is a DEFECT

`land()` no longer reads a moving `git rev-parse HEAD`; it tests every branch tip and workspace HEAD
against a branch resolved from a record, once per land, and refuses by name when there is no record. That
half is right, and case 6 proves it: work merged onto a dev branch and not into main now counts as landed
and its workspaces are deleted.

The floor is the defect. See §4, defect 1.

### Item 3 — `extra_branches` and its three readers deleted: HOLDS

```
$ grep -rn 'extra_branches\|_workspace_branches' engine/ docs/
engine/scripts/lib/workspaces.py:1826:    `extra_branches` list, which `_workspace_branches` folded in here. NOTHING
```

One surviving mention, inside the comment that records why the field is gone. No reader, no writer, no
fixture. The retry claim also checks out: `_branch_targets` now skips only a branch whose own deletion has
already succeeded, so nothing can drop out of the retry list (point 13).

---

## 2. Verdict per case — the engineer's own probe, run against both SHAs

The probe is the engineer's claim, so I ran it against the parent as well as the branch and checked that
its exit code is real rather than decorative (it is: `sys.exit(main(...))`, 0 against the branch and 1
against the parent — unlike my own round-1 probe, which uses `unittest.main(exit=False)` and always
exits 0).

```
$ python3 -B docs/verification/workspace-attribution-seven-cases.probe.py \
      /Users/alex/ab/richos-wt/frank-opus-c3/engine/scripts/lib/workspaces.py
...
=== 7/7 cases hold
EXIT:0

$ git show 65dad4d4:engine/scripts/lib/workspaces.py > /tmp/.../parent/workspaces.py
$ python3 -B docs/verification/workspace-attribution-seven-cases.probe.py /tmp/.../parent/workspaces.py
=== 1 stray            VERDICT  BROKEN
=== 2 side-branch      VERDICT  BROKEN
=== 3 borrowed         VERDICT  BROKEN
=== 4 rich             VERDICT  HOLDS
=== 5 two-agents       VERDICT  HOLDS
=== 6 dev-branch       VERDICT  BROKEN
=== 7 merged-nowhere   VERDICT  HOLDS
=== 3/7 cases hold; BROKEN: stray, side-branch, borrowed, dev-branch
EXIT:1
```

| # | case | at `65dad4d4` | at `84e12d32` | my verdict |
|---|---|---|---|---|
| 1 | a branch created and never checked out goes with the agent | BROKEN | HOLDS | holds — `created_branches ['spare']`, land refused until merged, `branches after the land ['main']` |
| 2 | a side branch committed to and switched away from blocks the land | BROKEN | HOLDS | holds — refusal names `tmpwork` by name, its commit is NOT in main, `pending ['zach-opus-p2']` |
| 3 | a pre-existing branch only checked out survives a discard | BROKEN | HOLDS | holds — `human/keep` survives with its tip unchanged |
| 4 | a branch Rich cuts in the main checkout is never the agent's | HOLDS | HOLDS | holds — `rich/notes` and `rich/look` both survive the land |
| 5 | two agents in one repository both land cleanly | HOLDS | HOLDS | holds — neither takes the other's, both repositories end at `['main']` |
| 6 | work merged to the dev branch but not main counts as landed | BROKEN | HOLDS | holds **for the recorded case only** — the probe records the branch BEFORE the spawn every time, which is the one ordering in which the floor never fires. See defect 1. |
| 7 | work merged nowhere does not count as landed | HOLDS | HOLDS | holds — refused, pending, workspace still present |

**Where I broke the probe:** not in a case, but in what it does not cover. Cases 6 and 7 both call
`s.dev(...)` — `record_integration` — *before* `s.spawn(...)`. That is the page's own ordering, and it is
also the only ordering in which the point-14 floor is never exercised. The probe therefore cannot see
defect 1, and a reviewer reading `7/7` would not know the floor had never run. Case 4 likewise avoids the
one shape the engineer declares as indistinguishable, which is honest of him but means the probe measures
none of the bound he claims for it; I measured it myself (§3.2).

---

## 3. My own probes

### 3.1 The two from the earlier rounds, unmodified

Neither file is touched by the three commits under review (`git diff --name-only 65dad4d4..84e12d32 --
docs/verification/` names only the engineer's new probe), so both ran as written.

```
$ python3 -B docs/verification/certification-frank-four-fixes-2026-09-12-probe.py
test_a1_another_agents_branch_is_attributed_to_this_one ... ok
test_a2_land_of_A_is_held_hostage_by_the_other_agents_branch ... ok
test_a3_a_branch_the_lead_cuts_in_the_main_checkout_is_the_agents ... ok
test_a4_discard_of_A_deletes_the_other_agents_branch ... ok
Ran 4 tests in 1.871s
OK
A.created_branches = []          land(A) -> {'landed': True}
branches after discard(A): ['cc/zach-opus-b4', 'main']
```

**4-of-4, including the destructive one.** `discard(A)` no longer deletes the other agent's branch:
`cc/zach-opus-b4` is still there afterwards. This is the case the brief asked me to re-run, and it is the
strongest single result in the round.

```
$ python3 -B docs/verification/certification-frank-attribution-2026-09-12-probe.py
Ran 7 tests in 3.270s
FAILED (failures=3)         # B1 stray, B3 side-work, B6 renamed-work
```

**I do not count those three as defects, and I say so rather than banking them.** That probe was written
against a build in which attribution was read from POSSESSION, so it does its git work between two
COMPLETE tool calls — `tool_call()` fires Pre and Post back to back and the branch is created afterwards.
Against a build that measures creation inside a bracket, that models a ref appearing when no call is open,
which for an agent's own foreground git command cannot happen. Re-run faithfully — the same three shapes
with the creation inside one call — all three hold (cases 8, 9 and 10 below). What those failures do show
is that this mechanism is exactly as good as its bracket, which is defect 2.

### 3.2 A new probe for this round

Committed beside this file as
`docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py`. Self-contained: it
imports no engine test file and no other probe, drives the same two entry points the hooks use, sandboxes
everything, and its exit code is real.

```
$ python3 -B docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py \
      /Users/alex/ab/richos-wt/frank-opus-c3/engine/scripts/lib/workspaces.py
=== 1 outside-stray        VERDICT  BROKEN
=== 2 outside-side         VERDICT  BROKEN
=== 3 floor-trap           VERDICT  BROKEN
=== 4 floor-control        VERDICT  HOLDS
=== 5 no-floor-self-heals  VERDICT  HOLDS
=== 6 floor-timing         VERDICT  BROKEN
=== 7 rich-at-my-tip       VERDICT  HOLDS
=== 8 serial-stray         VERDICT  HOLDS
=== 9 serial-side          VERDICT  HOLDS
=== 10 serial-rename       VERDICT  HOLDS
=== 6/10 cases hold; BROKEN: outside-stray, outside-side, floor-trap, floor-timing
EXIT:1
```

Cases 8, 9 and 10 are the controls, and they matter as much as the breaks: with one call open at a time,
the stray is attributed and deleted, the side branch holds the land by name, and a branch the agent
renames its own into goes with it. The mechanism works. Cases 1, 2, 3 and 6 are §4.

**Case 7, the declared indistinguishable one, measured rather than accepted:**

```
    created_branches                       ['rich/rescue']
    land while rich/rescue is unmerged     REFUSED: … is not in main …
    branches after the discard             ['main']
    the record of what was deleted         (none on the record)
    the deleted tip is in the event log    True
    rich/rescue survived                   False
```

Both halves of the declared bound are true: the land refuses while the ref carries anything unlanded, and
the tip survives in `events.jsonl`. The branch itself is destroyed, and the agent's own `disposition`
carries no list of what was deleted — the event log is the only copy. That is the bound, and it is
thinner than the word "records" suggests. Ruling in §5.2.

---

## 4. Defects

### Defect 1 — the point-14 floor infers the integration branch, freezes it, and the land can then never succeed

**The CEO's sentences, in his words (point 14):**

> **The branch a body of work integrates on is RECORDED when that work starts, before its first agent is
> spawned. Nothing infers it and nothing guesses it**

> **Finished work never waits on the agent's own branch**, and "it cannot go to main yet" is never a
> reason for anything to be left behind or for point 5 to be blocked.

**What the build does.** Where nobody has recorded a branch, `_ensure_integration` reads the main
checkout's own branch and writes it as the record with `source: "first-registration"`. `_add_workspace`
then copies that value onto every agent registered afterwards, and `integration_target` prefers the
agent's frozen copy over the repository's live record. So a value derived from whatever the operator's
checkout happened to be on is frozen onto the agent, and **a later, correct recording by Rich cannot reach
it.**

**Reproduction, three cases, one command each.**

```
=== 3 floor-trap
    floor wrote                            main (source: first-registration)
    agent's frozen copy                    {'…/entity': 'main'}
    Rich recorded                          dev/workspace-spec (source: recorded)
    merged onto dev/workspace-spec         True
    in main                                False
    land                                   REFUSED: zach-opus-q3 is not landed yet: HEAD of
                                           …/agent-azachopusq30000 (0b8b9faf80bc) is not in main of …
    workspace still there                  True
    pending (point 5 blocks on this)       ['zach-opus-q3']
    VERDICT                                BROKEN
```

The work is merged onto the branch it integrates on. The land refuses. The workspace is left behind. The
item is pending, so point 5 blocks Rich from starting new work or ending his turn — and the stated reason
is that it is not in main, which is the sentence above, word for word.

The other two cases isolate the cause, so this is not a complaint about dev branches:

```
=== 4 floor-control   recorded BEFORE the first registration → land landed, workspace gone      HOLDS
=== 5 no-floor-self-heals
    record at session start                (none)
    land with no record at all             REFUSED: … no branch is recorded for … (point 14); nothing
                                          infers it. Record it: workspaces.sh integration …
    land after Rich records the dev branch landed
    workspace gone                         True                                                 HOLDS
```

**With no record at all the refusal heals: Rich records the branch and the land succeeds. With the floor's
record, it does not.** The floor is the only difference between those two runs. It converts an actionable
refusal into a permanent one whose message names the wrong branch (`is not in main`) and never mentions
re-recording. The escapes left are merging to main — which point 14 exists to say is not required — or a
discard, which for work the CEO ordered needs his word (point 7).

**The load is this machine, right now, not a synthetic.**

```
$ git -C /Users/alex/ab/richos rev-parse --abbrev-ref HEAD
main
$ git -C /Users/alex/ab/richos rev-parse dev/workspace-spec
65dad4d458ed8a97fe29f01dc87ea68ee753e507          # the parent of the commits under review
$ git -C /Users/alex/ab/richos merge-base --is-ancestor dev/workspace-spec main; echo $?
1                                                  # main has none of it
$ git -C /Users/alex/ab/richos rev-list --left-right --count main...dev/workspace-spec
0   62                                             # 62 commits off main
$ cat /Users/alex/.claude/state/workspaces/repos.json
{ "repos": [ "/Users/alex/ab/richos", "/Users/alex/ab/femcboost" ] }
$ ls /Users/alex/.claude/state/workspaces/integration.json
ls: No such file or directory
```

This body of work integrates on `dev/workspace-spec`, which is 62 commits off main; the richos main
checkout is on `main`; and no integration record exists yet. Install this build and the first thing that
happens in richos is that the floor writes `main`.

**And it fires earlier than declared** — case 6, `floor-timing`:

```
=== 6 floor-timing
    record at session start                whatever-rich-was-on
    main checkout's branch at registration main
    record after registration              whatever-rich-was-on (source: first-registration)
    agent's frozen copy                    {'…/entity': 'whatever-rich-was-on'}
```

The commit message and the code comment both say the floor reads the branch "at the registration of the
first workspace in that repository — which is before its first agent is spawned". It is in fact reached
from `record_session_start` → `_remember_repo` → `_ensure_integration` (`workspaces.py:597`), so the value
is the branch the main checkout held when the SESSION started. Rich cannot get in front of it: it is
written before he can run anything. That makes the recorded "fact" the branch a checkout happened to be on
at boot — which is what "nothing infers it" is there to forbid.

### Defect 2 — a ref that comes into existence outside the pre/post bracket is attributed to nobody

**The CEO's sentences:** point 3 — "A `cc/` or native workspace with no registration, and **any branch an
agent created**, counts as finished work of an ended session and is handled under point 5." Point 10 —
"every workspace and branch it has is deleted, as one. **None is left behind.**" Point 8 — "Deletion
therefore never loses anything that was meant to land."

**Reproduction:**

```
=== 1 outside-stray
    created_branches                       []
    land                                   landed
    branches after the land                ['main', 'spare']
    pending after the land                 []
    VERDICT                                BROKEN

=== 2 outside-side
    created_branches                       []
    land                                   landed
    its side commit is in main             False
    branches after the land                ['main', 'sidework']
    pending after the land                 []
    VERDICT                                BROKEN
```

Case 2 is the one that matters: `land()` reports **landed**, the branch carrying the agent's commit is
left behind, the commit is in no integration branch, and the unregistered scan lists nothing — because the
name is not `cc/`-prefixed. That is precisely the points 5/8 hole this round exists to close, still open
whenever the creation falls outside a bracket.

The cause is structural rather than a slip: there is one snapshot file per agent (`refs/<key>.json`),
written at every Pre and **unlinked at the Post**. A ref that appears after a Post and before the next Pre
is already in the next snapshot before anything compares it, so it is never new and never anyone's.

**The load that exists on this machine.** A backgrounded Bash call returns to the model while its process
keeps working, so anything that process creates is created outside every window. Measured here today, in
this session:

```
BG start            1789203115.2007       # the tool call returned at this point
probe now           1789203118.2615       # a later tool call: the process is still working
BG made-the-branch  1789203119.2112       # 4.0 s after its own tool call, outside every bracket
```

**Honesty about the other path.** The installed platform binary documents a second one — "PostToolUse
fires per-tool and **may run concurrently for parallel tool calls**; PostToolBatch fires exactly once with
the full batch" (`strings /Users/alex/.local/share/claude/versions/2.1.269`). Two open calls would defeat
the single consumed snapshot in the same way. **I could not observe it:** two Bash calls issued in one
block ran serially here, 0.32 s apart (`A end 1789203084.1187`, `B start 1789203084.4419`). So I rest this
defect on the background overhang I did measure, and I record the concurrency as documented-but-unobserved
rather than banking it.

I hold this defect to be real and second in weight to defect 1: a branch created by a backgrounded git
command is uncommon, and the bound the engineer states — under-attribution loses nothing — is true for
`cc/`-named refs, which the unregistered scan catches as orphans (my round-2 case B2 shows
`pending ['orphan-cc-zach-opus-n2-spare']`). It is not true for any other name, and point 10 does not
distinguish.

---

## 5. Rulings on the three things the engineer declared

### 5.1 The reflog source — the distinction HOLDS

He is right, and it is a fact about git's layout rather than an argument. Measured in a live linked
worktree on this machine:

```
$ git rev-parse --git-dir
/Users/alex/ab/femcboost/.git/worktrees/agent-a185a46f96422ce61
$ git rev-parse --git-common-dir
/Users/alex/ab/femcboost/.git
$ ls /Users/alex/ab/femcboost/.git/logs/refs/heads/     # the COMMON dir: shared by every worktree
codex  main  worktree-agent-a185a46f96422ce61  worktree-agent-a239fb764169a2909
$ ls /Users/alex/ab/femcboost/.git/worktrees/agent-a185a46f96422ce61/logs/
HEAD                                                   # private, and deleted with the worktree
```

The rejected reflog, `logs/refs/heads/<name>`, lives in the common directory, is one file per branch
shared by every worktree, and records `branch: Created from <X>` identically whoever ran the command and
wherever — it cannot answer who made a ref. `$GIT_DIR/logs/HEAD` of a linked worktree is a different file
in a different place with a different property: it records only that workspace's own HEAD movements and
goes away with it.

Two further things make the use of it sound rather than merely different. It is used **only** as a source
of the agent's own unlanded tips (filter 4), never as evidence of authorship — authorship comes from the
snapshot comparison. And an agent with no unlanded tip of its own in a repository is attributed nothing
there, which is what keeps a second agent's whole spawn out of an open window (case 5).

One dependency to name rather than a fault: it requires `core.logAllRefUpdates`. It is `true` in both
repositories here (`git config --get core.logAllRefUpdates` → `true` in the femcboost worktree and in
richos). Turn it off and the side-branch-inside-one-call case reverts to the old hole silently.

### 5.2 The one thing that cannot be told apart — the bound holds, and it is thinner than it reads

The claim is sound: a ref Rich cuts during the agent's own tool call at that agent's own unlanded tip is
genuinely indistinguishable from `git branch spare` run inside the workspace, by any fact git keeps. I
accept that, and resolving it in the agent's favor is the safe direction: it makes a land refuse rather
than let something vanish.

The bound's first half is true and I measured it — the land refuses while such a ref carries anything
unlanded (case 7). The second half is weaker than the word "records" implies: the discard deletes Rich's
branch with `git branch -D`, the tip appears **only** in `events.jsonl`, and the agent's own
`disposition` carries no list of what was deleted (`the record of what was deleted (none on the record)`).
Recovery therefore depends on one append-only log outside the repository, plus git's own unreferenced
object window. And the window is narrower than the bound needs to be for a different reason worth stating:
Rich cutting a branch at an agent's tip is overwhelmingly a RESCUE, which by construction happens after
the run has ended, and both halves refuse a finished agent (`observe()` throws the open snapshot away).
I did not find a realistic path into this window on this machine. **Not a defect, and correctly declared.**

### 5.3 Point 14's floor — OUTSIDE his page, plainly

The brief asks me to say plainly whether the floor is inside his page or outside it. **It is outside it.**

His page names exactly one way the fact comes into existence: it "is RECORDED when that work starts,
before its first agent is spawned", and then closes the door — "**Nothing infers it and nothing guesses
it.**" A value read off the main checkout's current branch is inferred from what a checkout happens to be
on. Calling it "a floor, not a guess about intent" describes the intent of the code, not the nature of the
value; the value is derived from state, which is the thing the sentence forbids. His page also supplies
its own answer for the missing case — nothing is recorded, so there is no fact, so nothing may be tested
against a made-up one — and the engineer's own reasoning agrees with him one paragraph earlier: "Refusing
is the only answer that is not a guess."

I would have left it there as a judgment call for him, under "Beyond the page", **if the floor were inert
when wrong.** It is not. §4 defect 1 shows it is strictly worse than the refusal it replaces: the refusal
heals when Rich records the branch, and the floor's record does not. That is what moves this from a
difference of reading to a defect, and it is what the verdict rests on.

---

## 6. Beyond the page

Not defects, not reasons to refuse, and his to weigh:

1. **The PostToolUse leg is proven through the library, not live.** Installation was forbidden, so the new
   hook never fired in a real session; every case above drives `observe()` directly, exactly as the hook
   would. The platform premise the hook depends on is documented by the build installed here: "Subagent
   identifier. Present only when the hook fires from within a subagent (e.g., a tool called by an AgentTool
   worker). Absent for the main thread… Use this field (not agent_type) to distinguish subagent calls from
   main-thread calls." Nothing in that is Pre-specific, so a subagent's PostToolUse carries `agent_id`.
   The first real session after the merge is still the first time the wiring itself is exercised.
2. **The cost is not a problem, and I went looking for one.** The Post half is one `git for-each-ref` per
   repository plus a small read, and the expensive path (reflog walk, ancestry tests) runs only when a ref
   actually appeared. Measured: library import 0.009 s; ten `for-each-ref` on richos (10 branches) 0.036 s
   total; the HEAD reflog of a live agent worktree is **2 entries** (`git reflog show --format=%H HEAD |
   wc -l` → 2, in both a femcboost native worktree and a richos `cc/` one), because a workspace is
   short-lived. There is no 40,000-entry shape here to make the ancestry loop expensive.
3. **The floor can write a name that `record_integration` itself refuses.** `record_integration` rejects a
   `cc/` or `worktree-agent-` branch by name, citing "Finished work never waits on the agent's own branch".
   `_ensure_integration` applies no such check, so a session that starts with the main checkout on such a
   branch would record it and every land would then be tested against an agent's own branch. Not observed
   here — this project's IDE-visibility rule keeps HEAD on main — so I am not calling it a defect.
4. **`integration.json` has no per-body-of-work identity.** It is one record per repository, so two bodies
   of work running in one repository at once share one target; the agent's frozen copy is what keeps them
   apart, which works only because it is copied at registration. Worth knowing before a second dev branch
   exists.
5. **The commit message and the code comment misstate where the floor fires** ("at the registration of the
   first workspace in that repository"); it is reached from `record_session_start`. Whoever reads that
   comment next will believe Rich can get in front of it, and he cannot.
6. **The expected-red items are as declared and I did not re-test them:** `contract-integrity-probe.sh` is
   RED because `hooks.json` changed and `install.sh` was forbidden, and `observe-created-refs.sh` is not
   yet in the probe's typed `R_ROOTED_HOOKS`. Both are stated in the commit and in the hook's own header as
   a two-commit convention.

---

## 7. What I ran, with exit codes

| command | exit | result |
|---|---|---|
| `inflight-ack.sh --sha 84e12d32… --impact none …` | 0 | ack row in `~/.claude/state/inflight-acks.jsonl` |
| `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py <branch lib>` | 0 | 7/7 cases hold |
| `python3 -B docs/verification/workspace-attribution-seven-cases.probe.py <parent lib>` | 1 | 3/7; BROKEN: stray, side-branch, borrowed, dev-branch |
| `python3 -B docs/verification/certification-frank-four-fixes-2026-09-12-probe.py` | 0 | `Ran 4 tests … OK` (verdict is the OK line; this probe's exit is always 0) |
| `python3 -B docs/verification/certification-frank-attribution-2026-09-12-probe.py` | 0 | `FAILED (failures=3)` — B1/B3/B6, artifacts of that probe's model, see §3.1 |
| `python3 -B docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py <branch lib>` | 1 | 6/10; BROKEN: outside-stray, outside-side, floor-trap, floor-timing |
| `bash engine/scripts/lib/workspaces.test.sh` | 0 | `51 run, 0 failed`; `all 35 properties proven load-bearing` |
| `bash engine/scripts/workspaces-e2e.test.sh` | 0 | `46 passed, 0 failed` |
| `grep -rn 'extra_branches\|_workspace_branches' engine/ docs/` | 0 | one comment, no readers |
| `diff registry-before.txt registry-after.txt` | 0 | REGISTRY IDENTICAL |

The engineer's three suite claims reproduce exactly: 51/0 with 35 mutants, and 46/0 on the end-to-end
suite, whose E6 block drives the real pair of hook scripts — serially, which is why it does not see
defect 2.
