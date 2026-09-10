# Worktree reclaim, round 11 — the event does the work, and nothing is left undecided

Written 2026-09-10, during the round rather than before it, and that is stated
first because round 10's own document opens by saying it was written before any
code changed. This one was not: three of its five parts came from corrections
that arrived while it was being built. Every number below carries the command
that produced it, and the two numbers I got wrong are named as mine.

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

## 3. What the `cc/` prefix does, and what it does not

`create-teammate-worktree.sh` now names the branch `cc/<teammate>`. The
DIRECTORY keeps the bare name: eight places in `scripts/lib/inflight.py` name
"worktree basename" as an identity source, and the `-wt/` location already
marks these unambiguously.

**It closes the world.** `OWNED_WORKSPACE_SHAPES` declares three shapes —
`cc-branch`, `native-agent`, `legacy-teammate` — and everything else is NOT
OURS, which is a decision rather than an unknown. `legacy-teammate` is how the
33 workspaces already on disk are not stranded off the list; retiring it later
is one word in a config file.

**It is scope and never permission, and this is the load-bearing sentence of
the round.** A facts-on-disk rule — prefixed, merged, clean, unlocked,
therefore remove — would destroy a running agent's work on an ordinary day. A
cross-repository worktree takes NO lock by construction, a tree is clean
between commits, and this orchestrator lands teammate branches
**mid-assignment** as standing practice. The worktree this document was written
in became merged-and-clean-and-unlocked-and-listed the moment its branch was
landed. That is the 2026-08-24 incident with the record removed instead of
misread.

**Measured, which is why it is one new tier rather than a new rule.** Of 33
standing worktrees, a facts-on-disk authority would newly decide exactly
**one** — `richos-hq-wt/zach-opus-red1`, named by nothing in the ledger or the
transaction store. Everything else was already decided by the ownership record
once the holes above were closed. So authority gains **T4 no-session-alive**:
an allow-listed workspace with no owner on record is adoptable when no
orchestrator session is alive at all. It cannot destroy a live agent's work
because there is no live agent.

## 4. The result on this machine

```
reconcile-terminal-worktrees.py --preview           (after)
  === preview: remove=6 branch-only=2 observe=0 hold=14 ===

workspace-scope.sh
  === 42 worktree(s) across 6 repositories, every one decided:
      EXCLUDED=13, NOT-OURS=1, OURS-HELD=22, OURS-READY=6 ===
```

`observe=6` — the "platform-owned; session alive" class — is now `observe=0`.

## 5. The residue, stated rather than rounded away

**Seven workspaces are held by ONE process.**
`com.apple.Virtualization.VirtualMachine`, pid 1483, holds open directory
handles inside them (12 in `deeply-wt/zach-opus-dor2`, 4 in the
`claude-orchestration-kit-wt` one). No cleanup rule of any design may remove a
tree a process has open. The report names the pid and the command, because that
is a true cause with an owner outside this system and an operator can close it.

**Two are merged but DIRTY** — `richos-wt/sage-fable-r7` and
`femcboost/.claude/worktrees/agent-a8922391964bc8c3b` — carrying uncommitted
files only their author can judge. That is 6%, and it is not a cleanup problem:
it is *the agent did not finish*. What would stop it recurring is a stop-time
refusal, not a sweep — an agent whose terminal event finds uncommitted bytes
has failed its own handoff contract, and the place to say so is the event, to
the orchestrator, while the agent's transcript still exists.

## 6. The fact that would prove this round wrong

**If a terminal record is ever written for an agent that then runs again**, the
agent-sized ground is unsound and this round has to be undone. It rests on
`guard-resume-isolation.sh` refusing every resume of a terminal agent with no
escape hatch, and on the measurement that SubagentStop fires once per run:
1,153 `WorkerRunEnded` rows across 1,149 distinct agent ids in this session,
1,147 of them with exactly one, and zero for either agent that was running when
I looked. If a future harness revision resumes a stopped agent, that measurement
changes and this design must change with it.

**The narrower version of the same fact:** if the platform ever stops releasing
its own lock at the end of a run, the immediate path degrades to the catch-up
sweep, and if the platform stops releasing it at all, to the nightly pass. Both
degradations are visible in the `immediate_reclaim` journal on the member, which
is why the journal records deferrals and not only successes.
