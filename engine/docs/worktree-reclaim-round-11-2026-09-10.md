# Worktree reclaim, round 11 — the event does the work, and nothing is left undecided

> ## THIS ROUND WAS NOT CERTIFIED. Its central premise is FALSE and has been withdrawn.
>
> **Both reviewers refused it on 2026-09-10** (`docs/verification/certification-sage-2026-09-10.md`,
> `…-frank-2026-09-10.md`), converging on the same defect from different evidence.
> Round 12 withdrew the agent-sized ground rather than re-founding it. The
> current design is `docs/reclaim-decision-table.md`; read that first.
>
> **What was false, in this document's own words, with the command that
> disproves each.** These are not softened below — each sentence is corrected in
> place where it appears, so this document cannot be quoted from without meeting
> the correction.
>
> | § | The claim | The command | The answer |
> |---|---|---|---|
> | 7 | a terminal agent cannot run again | `restart-after-terminal-measure.py` | **10 of 66** did, earliest 2026-09-08 |
> | 7 | "SubagentStop fires once per run: 1,147 of 1,149 ids with exactly one" | `…--census` | counts PER-RUN ids; one row per id **by construction** |
> | 0, 2 | the platform releases its lock ~1s after the stop | the `immediate_reclaim` journal | **3 of 3** own-event attempts deferred; one lock held **77 min** |
> | title, 2 | "the event does the work" | the transaction store | **0 of 5** production reclaims happened in their own event |
> | 3 | `zach-opus-red1` "stays forever because of the cut" | `git -C richos-hq worktree list` | gone by 15:23 the same day, through the hole in that very cut |
>
> **What HELD UP and was not touched by round 12:** deletion only on a tip
> proven an ancestor of `main`, re-checked before both the removal and the
> branch delete; `land-disposition.py` never mutating; the identity repair; the
> `cc/` prefix; late binding.

Written 2026-09-10, during the round rather than before it, and that is stated
first because round 10's own document opens by saying it was written before any
code changed. This one was not. Half of it came from corrections that arrived
while it was being built, and one part of it describes machinery that was built
and then removed the same day. Every number below carries the command that
produced it, and the one number I got wrong is named as mine, in section 1(b).

The CEO's question, verbatim: *"WHEN THE FUCK WILL ALL THE **FINISHED** GARBAGE
START GETTING CLEANED UP AUTOMATICALLY AND STOP WASTING MY FUCKING TIME?"* —
and, on the same day, *"if the cc/ prefix helps fix this shitshow once and for
all, add it now and be done with it."*

## 0. The state, measured before anything changed

```
reconcile-terminal-worktrees.py --preview          (10:53)
  === preview: remove=0 branch-only=0 observe=6 hold=6 ===

  observe /Users/alex/ab/femcboost/.claude/worktrees/agent-a0af7565af1a7ae92
          d0eef867/a0af7565af1a7ae92 zach-fable-lc1
          — platform-owned; session d0eef867 pid 8799 is alive        (x6)
```

Six finished teammates' workspaces, held **because the orchestrator was still
running**. A session lasts a working day; an agent lasts minutes.

The lock, read from the live admin directories at 10:55:

```
.git/worktrees/agent-a42c90096292136f0/locked
  claude agent agent-a42c90096292136f0 (pid 8799 start Thu Sep 10 05:39:28 2026)
```

The pid is the HOST SESSION's, identical for every agent of that session
(`pid_shared_with: 2` for three concurrent locks), so it can never distinguish
one agent from another.

And the platform releases it itself, about a second after the stop — dir mtimes
against the two SubagentStop events on record that day:

```
ae66ffef818a38354  stop 06:22:52.653   lock removed 06:22:53.026   (+0.37s)
aea7c66005dd2aa6f  stop 07:24:18.278   lock removed 07:24:19.334   (+1.06s)
```

> **TWO SAMPLES, GENERALIZED INTO THE SAFETY TIMING OF A DELETION.** Both rows
> are real; the sentence around them is not. Against them, from the same day:
>
> ```
> zach-opus-key1     own-event reclaim deferred, lock still held   +6.0 s
> sage-fable-cert1   own-event reclaim deferred, lock still held   +6.2 s
> zach-opus-unl1     lock still held, no run in progress          +77 min
> production reclaims that happened IN their own terminal event    0 of 5
> ```
>
> Three of three own-event native attempts expired the 5-second wait; all five
> real reclaims came from a later sweep. The consistent reading is that the
> platform tears down only AFTER the stop hook returns, so a wait INSIDE that
> hook can never observe the release — it is pure latency on every stop of
> every workspace-owning agent. The default is now 0.
>
> The measurement worth having is the other direction, and round 12 rests on
> it: the platform takes the lock **before** a run begins (49 ms and 43 ms
> ahead of the `SubagentStart` hook, two live agents), so an ABSENT lock is a
> fact about the present rather than a prediction about the future.
>
> **ROUND 13:** before an **initial** run. Both samples were initial starts;
> re-lock on a restarted run is unmeasured (`--locks`, (b) 0 of 3, (c) 4
> unobservable). Round 12 does not rest on it any more; see §7 below.

## 1. Two defects, and what each one actually was

**(a) The ingress fired at the right moment and did not finish the job.**
`terminalize-agent-worktrees.sh` claims the transaction and marks members
terminal, then hands reclamation to a launchd job that runs at 04:00. The
system learned an agent was finished immediately and acted on it up to 24 hours
later. That part of the brief was exactly right.

**(b) "A finished agent's lock is never released" was true, and not for the
reason anyone thought.** `_release_dead_lock` refuses a lock whose reason
carries no pid — *"locked without a pid; retained"* — so a lock with an empty
reason is unreclaimable by that route forever. Three lock files were empty when
I measured them at 11:25, and I published a false cause for it: I wrote that
the platform had emptied them and that "no unlock was recorded in between by a
20ms poller". **The poller had recorded the unlock, at 11:24:02, fifteen
minutes after I last read its log.** The orchestrator had unlocked and
re-locked all three while finishing a land, and `git worktree lock` without
`--reason` writes an empty file. The correction is appended to
`docs/verification/escalations/2026-09-10-zach-opus-auto1-*.md`; the mechanism
is real whatever writes it, which is why it got an answer rather than a repair.

## 2. What now happens when an agent finishes

**The same lane, called from the event.** `terminalize()` calls
`daily-workspace-cleanup.reclaim_now` → `reconcile` — the identical function
the nightly pass calls, with every refusal intact. The nightly pass is
unchanged and is still the backstop for a crash, a killed process, a machine
that slept.

**The ingress waits for the platform's own lock release and never takes it
off.** Bounded by `IMMEDIATE_RECLAIM_WAIT_SECONDS` (5s). The lock is the host's
artifact; its removal is the host saying it is finished with the workspace.

**The next terminal event finishes what the last one could not.** If the wait
expires, the member would otherwise sit until 04:00. Every terminal event —
including one for an agent that owns no worktree, of which this machine records
over a thousand a session — first spends a small budget on this session's
deferred members.

**The session stopped being the unit.** A platform terminal ingress for one
exact agent id, plus the terminal index that makes `guard-resume-isolation.sh`
refuse its every resume with no escape hatch, is agent-sized positive evidence
that stands beside "the owning session is provably gone". It removes no
refusal; it adds a ground.

**A lock nobody can be behind gets answered.** The reconciler — never the
ingress — may release a lock that names NO pid over an agent the platform said
stopped, with no process standing in the tree. A lock naming a live pid is
refused as before.

**A workspace created after the seal can still join.** `bind_late_members`
binds a ledger row of this session that carries this agent id, or carries none
and names this transaction's teammate when exactly one transaction in the
session carries that name. Measured: `zach-opus-dor2` had FOUR workspaces and
its manifest sealed with two.

**A row that names no agent stops reserving a path forever.** Two rows written
by session `44276098` on 2026-09-02 were still holding
`richos-wt/zach-opus-prem1` eight days later; nothing keyed to them could ever
retire them.

## 3. The exit event now names every folder, and one design was cut

**The finish event described one folder out of four and named nobody.**
Measured over 15,728 finish rows in the ownership ledger:

```
finished rows naming a CROSS-REPOSITORY (<repo>-wt/) workspace :      0
finished rows naming a NATIVE worktree                         : 10,749
finished rows with a BLANK teammate                            : 15,728
```

Both follow from the payload: `cwd` is the agent's native isolation worktree,
and SubagentStop carries none of the name keys the hooks look for. The entry
side always had the whole set — 65 agents had folders registered at spawn that
day and **61 of them had more than one**. So `worktree-ledger.append()` now
completes a finish row from the record this engine already holds: the teammate,
and every folder of the assignment. It lives in the ledger so all three writers
(worker-ended, teammate-idle, task-completed) get it and none of them grows a
second writer. `worktree` still carries the native cwd exactly as before.

**The row is ADVISORY and stays advisory.** `judge()` prints finish signals as
"advisory, never decisive"; adoption quotes T3 without authorizing. Reclamation
is anchored on the transaction's terminal record, which the same event writes
about every member — and the proof that this is the anchor rather than the
ledger row is `zach-opus-dor1`: **zero finish rows of any kind**, and its
transaction sealed, terminal, carrying all four of its workspaces.

### What was cut, and why the cut was right

A closed-world allow-list (`cc-branch` / `native-agent` / `legacy-teammate`), a
report over every worktree on the machine, and a named `codex` refusal were
built and then **removed on the same day**. The reasoning that removed them is
better than the reasoning that built them:

**this engine only ever reclaims what it registered itself**, so there is no
open world to bound. A folder nothing registered is not refused — it is never
reached. That is a stronger guarantee than an allow-list and it needs no
machinery, and it is also how the CEO's codex ruling
(`richos-hq/wiki/ceo-decisions.md` section 31) is satisfied here: measured the
same day, **0 codex paths in any transaction manifest and 0 codex rows in the
ownership ledger**, for nine standing codex worktrees. Two cases assert exactly
that, one at each door into the lane.

**The `cc/` branch prefix stays** — the CEO asked for it, it is one line in
`create-teammate-worktree.sh`, and it makes his terminal legible. It is not a
safety mechanism and nothing here treats it as one.

**The residual risk of the cut, stated plainly:** the codex protection now
rests on Codex's folders never being registered by this engine's tooling. If
anyone ever registers one with `create-teammate-worktree.sh`, it becomes a
candidate like any other, and only the ruling — not the code — says it should
not be.

**And one workspace stays forever because of the cut.**
`richos-hq-wt/zach-opus-red1` is merged, clean, landed and named by NOTHING in
either store. The allow-list would have decided it; registration-only will not.
It is one row on his screen, and it is the honest price of "we only remove what
we wrote down".

> **FALSE BY 15:23 THE SAME DAY, AND THE WAY IT BECAME FALSE IS THE DEFECT.**
> `git -C richos-hq worktree list` shows it gone. It did not stay forever
> because, 45 minutes after this sentence was written, a row was appended to
> the ownership ledger BY HAND — `source: rich-operator-amnesty`, a session id,
> a teammate name, no agent id — and both the transaction store's late binding
> and the cleanup's owner check accept that as ownership. The workspace was
> reclaimed.
>
> So "we only remove what we wrote down" is not a guarantee while anything can
> write a line saying we wrote it down. **The identical row with a `codex/`
> path would have passed the same lane**, and `ceo-decisions.md` §31 says a
> Codex workspace is never removed without the CEO's express word — resting, in
> that section's own words, on this very argument.
>
> Round 12 closes both halves: the name join now requires a row written by an
> engine writer (`worktree-ledger.BINDING_LEDGER_WRITERS`; a foreign row still
> RESERVES and never binds — it may protect a workspace and may never destroy
> one), and §31 is in the mechanism as a refusal at the first gate plus a
> by-name report, rather than resting on the record hole §31 explicitly says
> must not be the protection.

## 3b. The one fallback, and it is narrow on purpose

Adoption gains **T4 — crash recovery**, for the single failure the two-event
model cannot cover on its own: a session that dies between registering a folder
and finishing it. Its preconditions are a folder THIS ENGINE REGISTERED whose
owner cannot be IDENTIFIED at all, and NO orchestrator session alive on this
machine — every registered session pid gone and no `claude` process in the
table.

It is deliberately the narrowest thing that closes the hole. An owner that can
be identified is already answered: alive refuses, and **gone or reused
authorizes on T2, which is the ordinary crash**. It cannot destroy a live
agent's work because there is no live agent, and it is a kernel fact of the same
KIND as T2 rather than an observation a sweep made.

It must stay rare. The failure this project actually had is that the recovery
path became the main path: nine rounds of inference existed because a fact the
system HELD was being thrown away. The main path is the finish event.

## 4. The result on this machine

```
reconcile-terminal-worktrees.py --preview           (after)
  === preview: remove=6 branch-only=2 observe=0 hold=14 ===
```

`observe=6` — the "platform-owned; session alive" class, six finished agents'
workspaces held because the orchestrator was running — is now `observe=0`. Of
the fourteen holds, seven are the VM's open handles, two are uncommitted work,
and the rest are unmerged branches that must never be swept.

## 5. The residue, stated rather than rounded away

**Seven workspaces are held by ONE process.**
`com.apple.Virtualization.VirtualMachine`, pid 1483, holds open directory
handles inside them (12 in `deeply-wt/zach-opus-dor2`, 4 in the
`claude-orchestration-kit-wt` one). No cleanup rule of any design may remove a
tree a process has open. **That is a RETRY, not a verdict, and it now says so
in those words** with the pid and the command on the member — it must never
enter the same vocabulary as liveness, because "an operator has a VM open" and
"we cannot tell whether the owner is alive" are different sentences and only
one of them clears by itself.

**Two are merged but DIRTY** — `richos-wt/sage-fable-r7` and
`femcboost/.claude/worktrees/agent-a8922391964bc8c3b` — carrying uncommitted
files only their author can judge. That is 6%, and it is not a cleanup problem:
it is *the agent did not finish*. What would stop it recurring is a stop-time
refusal, not a sweep — an agent whose terminal event finds uncommitted bytes
has failed its own handoff contract, and the place to say so is the event, to
the orchestrator, while the agent's transcript still exists.

## 6. The title of this document, checked against what it delivers

"Nothing left undecided" is what the closed-world report was for, and that
report was cut. What is left is narrower and true: every workspace THIS ENGINE
REGISTERED is decided, with the cause on the member -- reclaimed, retryable
(a process is standing in it), or held for a stated refusal. A folder nobody
registered is not decided by anything here and is not looked at, which is the
guarantee that replaced the report. `richos-hq-wt/zach-opus-red1` is the one
row on his screen that this leaves standing, and section 3 says so.

## 7. The fact that would prove this round wrong — AND IT HAD ALREADY HAPPENED

> **THIS SECTION WAS RIGHT ABOUT THE TEST AND WRONG ABOUT THE ANSWER.** The
> falsifier below was correctly identified and correctly written down. It had
> occurred SEVEN TIMES before this document was written and three times in the
> two days before it, and the measurement offered as proof could not see any of
> them. The round was undone on the day it shipped, exactly as this section
> required.

**If a terminal record is ever written for an agent that then runs again**, the
agent-sized ground is unsound and this round has to be undone.

> **It is. Run the falsifier:**
>
> ```
> $ python3 engine/scripts/restart-after-terminal-measure.py
>   DENOMINATOR: those that own at least one workspace : 66
>   NUMERATOR  : those with a start strictly after their terminal record : 10
>   rate       : 15.152%
> ```
>
> The earliest is `sage-fable-r2`, restarted 8.8 minutes after its terminal
> record on **2026-09-08 — two days before this document was written**. Four
> more restarted inside a nine-millisecond span at 14:34:37Z on 2026-09-10, six
> to eight hours after their terminal records. `zach-opus-auto1` restarted 1.3 s
> after its terminal record and had its workspace reclaimed 79 minutes LATER.

It rests on
`guard-resume-isolation.sh` refusing every resume of a terminal agent with no
escape hatch,

> **and that guard covers `SendMessage` and nothing else.** Neither path that
> actually fired goes through it: a message the platform had QUEUED before the
> stop and delivered after it, and a background task belonging to the agent
> exiting, whose notification resumes the agent. No hook this platform offers
> can refuse either. A policy that an agent is FORBIDDEN to return was read as a
> description of what the platform DOES.

and on the measurement that SubagentStop fires once per run:
1,153 `WorkerRunEnded` rows across 1,149 distinct agent ids in this session,
1,147 of them with exactly one, and zero for either agent that was running when
I looked.

> **THAT MEASUREMENT IS A TAUTOLOGY AND COULD NEVER HAVE SEEN A RESTART.** The
> `agent_id` in the SubagentStop payload is a PER-RUN identifier — the ledger's
> own `resolve_assignment` docstring says so, in the same landing. "Almost every
> id has exactly one row" is the signature of per-run ids, not of one stop per
> agent. Measured today: 1,765 run-end rows carry 1,756 distinct payload ids, of
> which only **27** are ids this engine ever registered a workspace to.
>
> The right key is the REGISTRATION id, and the corpus is workspace-owning
> agents, because a helper subagent with no workspace cannot have one deleted
> under it. That join is `restart-after-terminal-measure.py`, committed beside
> the tests so the next reader re-runs it instead of quoting this.

If a future harness revision resumes a stopped agent, that measurement
changes and this design must change with it.

> No future revision was needed. It was already true.

**The narrower version of the same fact:** if the platform ever stops releasing
its own lock at the end of a run, the immediate path degrades to the catch-up
sweep, and if the platform stops releasing it at all, to the nightly pass. Both
degradations are visible in the `immediate_reclaim` journal on the member, which
is why the journal records deferrals and not only successes.

> **THIS WAS BACKWARDS, AND IT IS THE MOST USEFUL CORRECTION IN THE ROUND.** A
> held lock was called a DEGRADATION to be retried. It is the platform holding
> the workspace, and it was the only thing standing between this lane and the
> workspace of an agent the platform was about to restart. **The safety came
> from the lock, not from the premise.**
>
> Measured, against the two samples this document generalized from: three of
> three own-event native attempts found the lock still held (+6.0 s, +6.2 s),
> `zach-opus-unl1`'s lock was still held 77 minutes after its stop with no run
> in progress, and ZERO of five production reclaims happened in their own event
> — all five came from a later sweep. `IMMEDIATE_RECLAIM_WAIT_SECONDS` is now 0.
>
> Round 12 reads the lock the other way round, and this is the fact the whole
> replacement rests on: **the platform takes the lock BEFORE a run begins** —
> lock mtime 49 ms and 43 ms ahead of the `SubagentStart` hook on two live
> agents — so an absent lock is a statement about the present, and non-force
> `git worktree remove` refuses a locked worktree (exit 128, git 2.52.0). A
> restart mid-reclaim makes the removal FAIL rather than race.
>
> **ROUND 13 (2026-09-10), correcting the round-12 correction above — both
> round-two reviewers, independently.** The two samples were **initial**
> starts; "the fact the whole replacement rests on" was measured on the case
> it was not written for. Re-lock on a **restarted** run is UNMEASURED:
> `restart-after-terminal-measure.py --locks` — (a) 4 of 4 initial starts
> have the lock ahead of the start; (b) 0 of 3 restarts with a lock on disk
> re-took it (fix1 twice, sage-fable-cert2 once, lock held throughout); (c) 4
> restarts into trees the reaper witnessed unlocked (q1, inf1, gate1, own1,
> 14:34:37Z) left no admin directory. The binary was misnamed too: the lane
> runs `completion-proof.GIT`, Apple Git 2.50.1, not Homebrew's 2.52.0 (both
> refuse). What protects a restart into an unlocked tree is row 5 from two
> sources, the write barrier (`guard-sealed-worktree.sh` refuses a terminal
> agent EVERY tool), and the ancestor gate — see the decision table §3. The
> lock is defense in depth.
>
> **And the journal could not have shown any of this**, which is why the
> finding had to be established from timestamps: it wrote ONE
> `immediate_reclaim` object per member and the last writer erased every
> earlier outcome. It appends now.
