# Worktree reclaim, round 10 — the deference cycle, diagnosed from the code, and what breaks it

Written 2026-09-10, BEFORE any code in this round was changed, because
`richos-hq/wiki/worktree-lifecycle.md` §4 says a round names the fact that
would prove it wrong before it has anything to defend. Every number below was
re-derived on this machine today; the command that produced it is beside it.

The CEO's question, verbatim: *"WHERE THE FUCK IS THE CLEANUP NOW? AND ALSO:
WHAT THE FUCK IS SUPPOSED TO HAPPEN IF THE USER DOESN'T RESTART THE SESSION FOR
A MONTH???"* — *"To be clear: I'm talking about AUTO cleanup. Not manual
cleanup."*

## 0. The state, measured

```
du -sh /Users/alex/ab/richos-wt /Users/alex/ab/femcboost/.claude/worktrees
  29G   /Users/alex/ab/richos-wt
  2.3G  /Users/alex/ab/femcboost/.claude/worktrees
ls -1 /Users/alex/ab/richos-wt | wc -l                      -> 33
df -h /System/Volumes/Data                                   -> 460Gi, 115Gi free, 74% used
reap-stale-worktrees.sh /Users/alex/ab/femcboost --discover  -> would-remove=24 skipped=33
    21 x "not-adoptable(unclaimed) ... transaction X (terminal) already owns"
     3 x "adoptable(T2)"
     9 x "platform-cleanup-pending(native|native-shell)"
reconcile-terminal-worktrees.py --status
    terminal_members_with_a_directory_present=29  blocked=46  pending_retry=55
launchctl print gui/501/com.richos.worktree-reconciler        -> loaded, runs=2, last exit code 0
~/.claude/state/worktree-transactions/last-run.json           -> 2026-09-10T03:02:15Z, adoption 0 of 580
~/.claude/state/worktree-cleanup-schedule.json                -> last_completed_slot 2026-09-10
```

The 29 present terminal members, by the reason the record holds them (read out
of every `~/.claude/state/worktree-transactions/*/*.json`):

| count | class | state | `blocked_reason` / `last_error` |
|---|---|---|---|
| 16 | hand-rolled | bound | `Commit intended deliverables, remove disposable local copies/build output or preserve needed non-Git data before completing; do not add secrets to Git` |
| 4 | native | platform-pending | the same string |
| 4 | hand-rolled | bound | *(empty — terminal after today's 04:00 pass, never attempted)* |
| 2 | hand-rolled | bound | `exact sealed native terminal ownership required` |
| 2 | native+hand-rolled | platform-pending / bound | `native owner is live or unknown: isolation worktree ... LOCKED` |
| 1 | native | platform-pending | `Claude Code cleanup pending: native path or registration remains` |

and, not on disk but still pending: **20 native members** at `removed` whose
`worktree-agent-<id>` branch is retained with `removed workspace has no retained
completion proof`.

What the 24 selected `richos-wt` trees actually contain
(`git ls-files --others [--exclude-standard]`, `git status --porcelain`,
`git rev-list --count main..<branch>`, per tree): **0 modified files, 0
untracked files, 0 commits ahead of `main`**, in every one. Their ignored
bytes are `__pycache__`, `app/target` (Rust build output, up to 3.3 GB each),
`app/ui/node_modules`, `tools/richos-service/companion-macos` (90 MB), `app/ui-dist`
(9 MB) and one to seven `.claude/inflight-acks/*.ack` files of a few hundred bytes
each — whose primary copy is `~/.claude/state/inflight-acks.jsonl`
(`scripts/inflight-ack.sh:26-30`).

Sessions: `~/.claude/sessions/` holds exactly one entry, pid 8799 =
`d0eef867` (this session). Sessions `5584bf8d`, `dab4b51d` and `899d5bee`,
which own every one of the 29, have no registered process. `899d5bee`'s pid
14200 is still named by one lock file
(`femcboost/.git/worktrees/agent-acbdd59bc72c530fc/locked`) and is dead.

## 1. The diagnosis — which predicate, on which side

**The cycle in the brief is half right.** Adoption does defer to the
transaction, and correctly. The transaction's own lane then refuses for reasons
that have nothing to do with ownership or terminal state. That is where the
deadlock is, and it is four predicates, not one.

### 1.1 The adoption side — correct, and not the bug

`scripts/lib/worktree-adoption.py:564-569`, gate **G4 `unclaimed`**:

```python
claim = _claimed_by_transaction(path)
if claim:
    return _refuse("unclaimed", "transaction %s already owns %s — the terminal
                   reconciler owns its lifecycle and adoption never competes with it")
```

`_claimed_paths()` (`:443-457`) indexes every member `path` and `quarantine` of
every transaction, so a tree the platform's own terminal ingress claimed is
refused here by design. **580 candidates yield 0 adoptions** because
`candidate_paths()` (`:268-282`) is every path the ownership ledger has ever
named — 580 rows, of which ~550 no longer exist (G1) and the ~24 that do are
either owned by a transaction (G4) or, at 04:00 today, owned by a session
whose process was still running (G6, `owner_evidence` `:385-389`: session
`899d5bee`'s pid 14200 was alive at 04:00 and exited before 05:39). The three
`adoptable(T2)` trees will be adopted at the next pass. **The adoption gate
did its job; 0/580 is the gates working, not failing.**

### 1.2 The reconciler side — four predicates, and none is ownership

Every one of the 29 is owned by a sealed transaction with a recorded terminal
ingress (`SubagentStop` ×59, `NativeMemberGone` ×4, `TaskStop` ×3 over the
store). The reconciler dispatches each `cleanup_policy: integrated-daily`
member to the daily lane at `scripts/reconcile-terminal-worktrees.py:867-879`
and, on any exception, records `blocked=True` and moves on. The daily lane is
`scripts/lib/daily-workspace-cleanup.py:reconcile()` (`:151-239`), and it
raises at four places:

**P1 — the completion proof counts IGNORED files as undelivered work.**
`reconcile()` `:169` calls `completion-proof.py:prove_member()`, which at
`:209` calls `clean_tree(path, head, reclaimable=True)`. `clean_tree`
`:103-107`:

```python
others=['ls-files','--others','-z']
if not reclaimable: others.append('--exclude-standard')
if git(path,*others).stdout:
    raise CompletionError('Commit intended deliverables, remove disposable local copies/...')
```

For a linked worktree (`reclaimable` is true at `:177`) the `--exclude-standard`
is dropped, so `ls-files --others` lists **ignored** files too, and one
`__pycache__/x.pyc` is enough to hold a workspace forever. The engine's own
committed policy (`orchestration.config:133`, `CAPTURE_DISPOSABLE_PATHS`)
already declares `__pycache__`, `target`, `node_modules` and friends disposable.
**20 of the 29 present members are held by this string.** It also means a
teammate with a `__pycache__` in its tree cannot mark its task complete at all
(`complete()` `:392` runs the same proof) — a second live defect behind the same
line.

**P2 — the ingress set omits two real ingresses.**
`daily-workspace-cleanup.py`, `terminal_fact()` / `ACCEPTED_INGRESSES`
*(cited as `:57-60` when written; those lines are now the constant itself —
a line number is a claim with a date on it, which is why this document's
citations were converted to symbol names on 2026-09-10)*: 

```python
def terminal_fact(transaction):
    return (... transaction['terminal'].get('ingress') in ('SubagentStop', 'WorktreeRemove', 'NativeMemberGone'))
```

`terminalize-agent-worktrees.sh` also claims on `PostToolUse[TaskStop]` with
ingress `TaskStop` (`:130-146`), and the adoption module claims with ingress
`Adoption`. Both are refused with `exact sealed native terminal ownership
required` — 2 present members (`echo-opus-dr1`, `echo-opus-vd1`) and every
future adopted member.

**P3 — a native shell is never RichOS's to remove, even after its session is
provably gone.** `reconcile()` `:190-193`:

```python
if tx.platform_native(member):
    # Claude remains the sole owner of its native checkout removal.
    return tx.observe_platform_native(sid, aid, index)
```

`observe_platform_native` (`worktree-transactions.py:1157-1205`) only watches;
"Claude alone removes its native checkout" (`docs/automatic-workspace-cleanup.md:17-22`)
was written to avoid racing the harness's own removal at terminal time. But
the harness of a session that has exited will never remove anything, and its
lock (which names the session pid, PF6) is never released. So 5 native shells
of dead sessions, 266 MB each, sit `platform-pending` forever, one of them
`locked` by pid 14200, dead.

**P4 — adopted members enter the pipeline whose last two steps are hard-coded
refusals.** `worktree-adoption.py:623-627` builds the member with no
`cleanup_policy`, so `terminalize()` sends it down `save_ref -> quarantine`
(`worktree-transactions.py:1405-1408`), and the reconciler's `STEPS`
(`reconcile-terminal-worktrees.py:680-693`) end at

```python
"verified": unregister_member,   # raise BlockedFailure("... automatic erasure is disabled ...")
"unregistered": remove_member,   # raise BlockedFailure(...)
```

So the three `adoptable(T2)` trees would be renamed, archived (adding a copy
to `~/.claude/state/worktree-captures/`) and then retained. Adoption today
**adds** disk and reclaims none.

A fifth, smaller one: **P5 — an absent native member with no completion
receipt keeps its branch forever.** `reconcile()` `:170-175`: the platform
removed the checkout, no `TaskCompleted` receipt was ever written for it, so
`removed workspace has no retained completion proof` — 20 `worktree-agent-*`
branches in femcboost, each with a recorded `head` and a backup ref already
saved by `observe_platform_native`.

### 1.3 The deadlock, restated exactly

The reaper says *"the adoption gate refuses it, so nothing automatic will take
it"* (`reap-stale-worktrees.sh:1461`). That sentence is false: the daily lane
takes it — and refuses on P1. The reconciler's banner says `BLOCKED (46 cannot
proceed by waiting)`, which is true, and the blocked condition is a
`__pycache__` directory. Each side reports accurately and neither report says
what the other would need. Nothing is deferring to a liveness guess; the
ownership and terminal machinery of round 9 is sound and untouched by this
round.

## 2. The design — what changes, and what does not

**Untouched, deliberately:** how ownership is recorded (bound at spawn to the
platform agent id), what makes a transaction terminal (a platform ingress or
T1/T2 evidence), the historical quarantine pipeline and its erasure refusal,
the live-lock veto, the integration requirement (`merge-base --is-ancestor`
against `main`), the untracked-file refusal, and the reaper's DRY-RUN-only
construction. No sweep decides anything. No signal is read as meaning more than
its author said.

**Changed:**

1. **P1** `completion-proof.clean_tree`: for a linked worktree the refusal
   covers untracked, non-ignored files only (`--exclude-standard`). Ignored
   bytes are decided at reclaim time, not at completion time.
2. **P1** `daily-workspace-cleanup.reconcile`: before the non-force
   `git worktree remove`, ignored files are enumerated
   (`ls-files --others --ignored --exclude-standard`) and partitioned by the
   committed disposable policy. Disposable ones are dropped by git's own
   removal. Every other ignored file is archived first into
   `~/.claude/state/worktree-captures/<sid>/<aid>/member-<i>/ignored-residue.tar`,
   the archive re-read and verified digest by digest, and the archive named on
   the member journal — nothing ignored is silently discarded, and the copy is
   kilobytes, not a 266 MB tree tar. A verification failure holds the member.
   A process standing in the tree (`lsof +D`, 0.85 s on the largest tree) holds
   it too; nothing is killed.
3. **P2** `terminal_fact` accepts `TaskStop` and `Adoption`. An adopted
   transaction's ledger reservation for its exact path is its own.
4. **P3** a platform-native member whose OWNING SESSION IS GONE — every
   recorded `(pid, start)` identity of that session answers `gone`/`reused`
   through the ledger's `process_status()`, the harness registry
   `~/.claude/sessions/` names no running pid for it, and the lock line (if
   any) names a dead pid — is RichOS's to remove: the dead-pid lock is
   released with `git worktree unlock`, then the same proof, integration check
   and non-force `git worktree remove` apply as for any member. A session that
   is running, or whose identity cannot be established, keeps deferring to the
   platform exactly as today.
5. **P4** adoption stamps `cleanup_policy: integrated-daily`, so an adopted
   tree goes through the daily lane and is removed when clean and integrated,
   instead of being quarantined into a retained archive.
6. **P5** an absent platform-removed native member with no receipt: the
   branch is deleted only when its tip equals the head the record saved at
   terminal time, that head is an ancestor of `main`, and no registered
   checkout holds the branch — the same compare-and-set the receipt path uses.
7. The reaper's `not-adoptable(unclaimed)` line names the owning transaction's
   state and current hold instead of claiming nothing automatic will take it.
8. Health: `--status` reports the schedule (last completed daily slot, its age,
   the launchd job's load state) and the SessionStart banner leads with
   `RECONCILER OVERDUE` when the store is non-empty and no daily pass has
   completed within `RECONCILE_OVERDUE_DAYS`. The reconciler's log gets a
   timestamped run header and footer with the counts it removed.

## 3. The month question, answered as a property of the job

The launchd job `com.richos.worktree-reconciler` (plist written and verified by
`scripts/hooks/install.sh:704-903`) fires on `StartCalendarInterval` at
`RECONCILE_HOUR` (04:00 local) and `RunAtLoad` (login/boot), and launchd
delivers a missed calendar event at wake. `--scheduled`
(`scripts/lib/cleanup-schedule.py`) admits one pass per local date once the
machine has been HID-idle for 10 minutes, with a 300 s work budget, and
records the completed slot. No Claude session is involved anywhere in that
path; `session-start-reap-worktrees.sh` is status-only and dry-run by
construction (`:29-46`).

**Worst-case reclaim latency with no session for a month:** a member that
becomes eligible at time T is removed by the first pass after T, so ≤ 24 h plus
the time until the machine is awake and idle for 10 minutes, plus one extra day
if the 300 s budget ran out on a large backlog. Over a month it runs ~30 times.

**What could silently stop it, and the signal for each:** the job unloaded
(`launchctl print` fails — the spawn guard 7e refuses spawns, and now the
SessionStart banner says so); the engine path in the plist gone (same); the
job loaded but failing every night (no new slot receipt — `RECONCILER OVERDUE`
in the banner and `--status`). The signal can only surface where somebody
looks, and the two places somebody looks are the next session start and the
next spawn.

## 4. What would prove this round wrong

The falsifying fact, named before the build: **a worktree removed by the daily
lane whose transaction had no terminal ingress, or whose owning session was
running at the moment of removal, or whose branch tip was not an ancestor of
`main`, or that held an untracked file, or that held an ignored non-disposable
file with no verified archive.** Concretely for this machine: any of
`/Users/alex/ab/richos-wt/zach-fable-lc1`, `/Users/alex/ab/richos-wt/zach-opus-gate1`,
`femcboost/.claude/worktrees/agent-{a0af7565af1a7ae92,a8922391964bc8c3b,ae66ffef818a38354}`
(locked by the running pid 8799), `richos-wt/echo-opus-dr1` (+2 unmerged),
`richos-wt/sage-fable-r7` (6 dirty paths) or
`femcboost/.claude/worktrees/agent-a69a6328ea2c81817` (+1 unmerged) being
touched by the run in §5 falsifies it.

Where the corpus already argues against the premise: `docs/terminal-daily-cleanup.md:30-32`
says workers must remove disposable files before completing and the
reconciler "does not silently discard those bytes". This round keeps the
second half (nothing non-disposable is discarded without a verified copy) and
retires the first, because the measured effect of the first was 30 GB of
build output retained on behalf of nobody.

Not closed by its author, and not closed today (§4 of the wiki). Closure is 30
days of the nightly job's slot receipts and a `terminal_members_with_a_directory_present`
that stays at the number of live workers.

## 5. Before / after on real state

**Filled in 2026-09-10 from the run's own output, by a later hand than this
document's author** — `zach-fable-lc1` lost its tools before it could write this
section, and a promise of evidence with no evidence under it is the defect this
page exists to argue against. Every figure below is quoted from
`before.txt` / `run1.txt` / `after1.txt` / `survivors-*.txt` in session
`d0eef867`'s scratchpad, not re-measured later and not rounded.

The automatic path — the daily lane, not a hand-driven removal — ran once at
07:08:13Z. Its own footer
(`reconcile-terminal-worktrees.py:1255-1257`):

```
reconcile: === run end 2026-09-10T07:08:13.594464+00:00 worktrees_removed=34 branches_deleted=34 members_completed=66 holds=7 reconciled=48 ===
```

The same four counters are re-readable afterwards as `schedule.reclaimed_last_run`
in `--status`, which is where a later reader should get them rather than from
this page.

| | before (07:04) | after (07:08) |
|---|---|---|
| `du -sh /Users/alex/ab/richos-wt` | 32G | 18G |
| `ls -1 /Users/alex/ab/richos-wt \| wc -l` | 42 | 13 |
| `du -sh femcboost/.claude/worktrees` | 3.7G | 2.1G |
| `ls -1 femcboost/.claude/worktrees \| wc -l` | 14 | 8 |
| `df -h /System/Volumes/Data` (Avail) | 109Gi | 121Gi |
| `terminal_members_with_a_directory_present` | 36 | 8 |
| `members_blocked_on_a_condition_waiting_cannot_clear` | 46 | 6 |
| `terminal_transactions_pending_normal_retry` | 20 | 2 |
| `sealed_transactions_whose_native_member_is_gone` | 1 | 0 |
| `du -sh ~/.claude/state/worktree-captures` | 0B | 108M |

**The last row is not incidental and is not a cost hidden in a success.** It is
P1's archive-before-drop: every ignored file that the committed disposable
policy does NOT cover was tarred, re-read and verified digest by digest before
git removed the tree. 108 MB kept in place of roughly 14 GB of build output
released is the trade this round was built to make, and if that number were ever
0 while trees were still being removed, the verification would be the thing to
suspect first.

**The survivor check is the half that decides whether §4 was falsified.** Eight
trees were named IN ADVANCE, in §4, as the ones a correct run must not touch —
two locked by the running session's pid, one unmerged, one with six dirty paths,
and the rest live. The same eight are `PRESENT` before and after:

```
$ grep -c GONE survivors-after1.txt
0
```

`echo-opus-dr1` (2 unmerged commits the CEO parked work in), `sage-fable-r7`
(6 dirty paths), `femcboost/.claude/worktrees/agent-a69a6328ea2c81817` (1
unmerged) and every tree locked by pid 8799 survived. **No tree that was
unmerged, untracked, live-locked, owned by a running session, or holding an
ignored non-disposable file without a verified archive was removed.** On this
run, on this machine, §4 is not falsified. That is one night's evidence and not
closure: closure is 30 days of the nightly job's slot receipts (§4).

**One thing this run does NOT show.** It was invoked directly rather than by
`launchd` at `RECONCILE_HOUR`, so it exercises the daily lane and not the
schedule. The schedule is evidenced separately by
`~/.claude/state/worktree-cleanup-schedule.json` and by `--status`'s
`launchd_job: loaded`, and the month question in §3 rests on that, not on this
table.
