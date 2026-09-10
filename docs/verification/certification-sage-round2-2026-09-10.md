NOT CERTIFIED

# Certification review, round two — richos main `891f8d96` — Sage, 2026-09-10

**Reviewer:** Sage (software architect), on Fable, by the CEO's order, round two. **Reviewed:** the
thirteen commits `4ee72c1c..891f8d96` on richos main, the decision table
`engine/docs/reclaim-decision-table.md`, the corrected round-11 document, the live state of this
machine between 19:55 and 20:25 UTC, and — this time — the test suites, run rather than read
(section 5). **Independence:** I read Frank's round-one verdict as instructed. I have not read, sought
or received his round-two verdict.

The verdict is the first line. Nothing below softens it into a score, and the list of what must be
true (section 6) is shorter than round one's because most of round one is now true.

---

## 1. Why it is not certified, in one paragraph

Round 12 did the hard thing right: it withdrew the false premise instead of re-founding it, the
falsifier is a committed script, and the restart it predicted happened live on this machine
during the review — `zach-opus-fix1` restarted 294 s after its terminal record, the new start hook
wrote the fact onto the transaction, and a sweep twenty seconds later refused both of its
workspaces on it. I established that from disk before the coordinator's message about it arrived.
What stops certification is narrower than round one and is of exactly the kind round one was
refused for: **the one fact the table says the replacement "rests on" — that the platform re-locks
a native worktree before a *restarted* run begins, so a mid-reclaim restart makes `git worktree
remove` fail — was measured on two worktree creations and never on a restart.** The only restart
observed with its lock file intact (`fix1`) shows the lock never released and never re-taken
(`mtime`/`ctime` unchanged since creation); the four 14:34Z restarts happened on worktrees the
reaper had recorded unlocked 83 minutes earlier, and nothing on this machine records whether they
were re-locked. The removal is nonetheless non-destructive for tracked work, but for a different
reason than the one written down (section 2, H1). Beside that: two removal tools in the engine
still have no §31 refusal while the table claims "every door"; the ignored-bytes half of the
safety claim has a real, narrow hole; and three smaller things (section 3).

---

## 2. What held up, and how I established each

These are stated first so iteration goes nowhere it is not needed.

**H1. A removal under `F = unknown` cannot destroy tracked work — but the load-bearing reason is
the write barrier, not the lock.** `reconcile()` removes only after `verify_member_proof` proves the
recorded tip an ancestor of `main` (re-run after the archive and again before the branch delete),
`git worktree remove` non-force refuses a dirty tree, and `guard-sealed-worktree.sh` refuses a
terminal agent **every** tool (its header, lines 36–37; the `TERMINAL` verdict at line 271;
confirmed live: the restarted `fix1` was refused even `Read`). So a restarted agent cannot write
after its terminal record, whether or not its workspace still exists. The fixer's stated falsifier
— *a path where a removal under an unknown owner loses work git does not already hold* — I could
not construct for tracked bytes. I could for ignored bytes (D3 below).

**H2. Restart detection works, live, and the record is right.** `record-subagent-start.sh` checks
the terminal index on every start and appends `after_terminal: start`; `terminalize-agent-
worktrees.sh` appends `stop` on a repeat ingress only when a post-terminal run is open;
`owner_check` refuses on `running_after_terminal` for every member class. Live sequence on this
machine: `fix1` stop 19:51:56Z → terminal 19:52:07Z → `WorkerStarted` 19:57:02.259Z → note
19:57:02.266Z → sweep 19:57:22Z journaled `deferred — the platform started this agent again …
that run is still open` on **both** the native and the cross-repo member → `WorkerRunEnded`
19:57:51.458Z → note `stop` 19:57:51.407Z. Read from
`~/.claude/state/worktree-transactions/d0eef867-…/a97f2c691c34e2c0f.json` at 19:57:43Z and 20:07:20Z.

**H3. The per-run-id concern I raised while reading is refuted by the record.** The terminalize
hook keys the `stop` note on the raw SubagentStop payload id, and Frank measured that id as per-run
on all but 63 of 2,976 rows. I joined every post-terminal `WorkerStarted` to the `WorkerRunEnded`
rows that followed: **all eleven carry the registration id** (appendix A3). The per-run ids are
the turn-level stops that fire every ~45 s during an agent's life (fix1 alone has ~100 `finished`
rows between 17:44Z and 19:51Z, all resolved to it by cwd); the registration-id stop is the run's
end. The design holds; the census text's attribution of per-run ids to "helper subagents" is
imprecise but immaterial.

**H4. The measurement script is sound and its three event-log-less findings are real.**
`starts/<id>.json` is written by exactly one function, `record_start` (`worktree-transactions.py:
434–440`), called only from the SubagentStart hook, so a start fact newer than the terminal record
is a SubagentStart after terminal. Re-run at review time: **11 of 67** (fix1 joined it during the
review). Four counts, four denominators, all reconciled: mine (6) used a 2 s window that dropped
`auto1` at +1.3 s and saw only the sessions with event logs; Frank's 7 of 101 used all terminal
transactions as denominator; the fixer's 10 of 66 predates fix1.

**H5. Hook CONTENT runs live; only REGISTRATION snapshots.** The coordinator relayed the fixer's
claim that fix1's restart would carry no note until the next session. It carries one (H2). The
distinction matters for section 4: the SubagentStart/SubagentStop/sweep changes are already live in
this session; `notice-land-disposition.sh` (registered on `Stop` at 17:30 today) is not.

**H6. §31 is in the automatic lane at its first gate.** `ceo_owned_workspace` is the first check
in `owner_check`, which is called at `reconcile` entry, before the removal, before the branch
delete, and in `assess`; `_absent_native_without_receipt` is reached only through `reconcile` after
`owner_check`; adopted transactions reach removal only through the same `reconcile`. The preview
names **9** `EXCLUDED` and **0** `NOT-EXAMINED` against live state (appendix A6). The by-name test
covers `codex/x`, `refs/heads/codex/x`, and `~/.codex/worktrees/…`, with two negative controls.

**H7. The hand-written-ledger-row door is shut.** `row_may_bind_by_name` gates the teammate-name
join in both `bind_late_members` and `owner_check`; a foreign-source row still reserves. Test and
mutant present and run (section 5).

**H8. `processes_using` fails closed in both copies**, and the test makes `lsof` genuinely
unreachable by emptying `PATH` rather than relying on the override. `_release_unattributable_lock`
and `lock_names_nobody` are gone (`assertFalse(hasattr(...))` in the suite). `session_gone` + 
`_release_dead_lock` (row 10a) require every recorded session pid gone or reused, no running
registration, and a lock naming a pid that no process holds; I accept the fixer's distinction from
the deleted route — it is positive evidence, not an uninformative string.

**H9. The sweep runs after the terminal record, under the caller's deadline, with a 20,000
tracked-file ceiling.** femcboost is 3,524 tracked files, richos 5,730 (both counted), so the ceiling
does not silently turn the in-event lane off for either entity. Absent-path members were never sweep
candidates (`sweep_session`, `os.path.lexists` filter), so row 8 being nightly-only is not new.

**H10. The 4.3× number is explained and reproduces.** `land-disposition-measure.py` at review time:
7 of 259, 2.703 %, the same seven landings, the reproducing command printed, `DILUTION WARNING`
emitted (appendix A5).

**H11. D7/D9/D10/D13/D14 (Frank) are done and tested:** the recurring 4 h rung
(`stop_notice_abnormal_recurring`, ledger line `<state>\t<epoch>`, three cases), `ack --until`
refusing free text and reopening on expiry with a permanent-ack negative control, secret-bearing
names surfaced in the archive record, the immediate-reclaim journal appending with a bounded
history and UTC stamps.

**H12. Round 11's document is corrected inline** beside each false sentence; round 10's line-number
citations are converted to symbols.

---

## 3. Defects, most important first

Severity is mine. "Outside" = established from the live record or machine; "inside" = from code.

### D1 — MODERATE. The re-lock-on-restart premise is asserted as measured and was not measured for the case it exists for

**Claim under test.** `reconcile()` last-look comment: *"the platform re-locks the worktree BEFORE
the run starts (measured, 43 ms and 49 ms ahead of the SubagentStart hook on two live agents)"*.
Table §3: *"Two facts hold the race shut, and both are measured rather than reasoned"*, and the
corrected round-11 §7: *"this is the fact the whole replacement rests on"*.

**Evidence (outside).** The two samples are `agent-a2de3c7d8d8590224` (unl1) and
`agent-a97f2c691c34e2c0f` (fix1), and both are **first starts** — the lock's `mtime` equals the admin
directory's `mtime` and the worktree's creation (appendix A4). The only restart with a lock file still
on disk is fix1's: lock `mtime`/`ctime` **17:43:41.993Z**, unchanged across its 19:57:02Z restart, so
the platform neither released nor re-took it — that says the lock was held throughout, and nothing
about what the platform does with a *released* lock on restart. The case that needs the belt is the
released-lock restart, and it has happened: `q1`, `inf1`, `gate1`, `own1` were recorded
`native isolation worktree registered and unlocked` by the reaper at **13:11:22–23Z** and restarted
at **14:34:37Z**. Their admin directories are gone; the ledger's `finished` rows carry no lock field
(appendix A7); no artifact on this machine says whether they were re-locked at 14:34:37.

**Consequence.** For the native member, if the platform does not re-lock a restarted run, the
last-look and git's refusal do not fire, and the race window (owner_check → verify → remove,
sub-second) is open. For the cross-repo member the last-look reads the cross-repo registry, which
carries no lock, so it is open regardless. What actually makes both windows non-destructive is H1 —
the barrier and the ancestor gate — which the code mentions but does not name as the reason. This is
the same shape round 11 was refused for: two samples generalized into the safety timing of a
deletion, written down as *measured*. The fixer named it as its own weakest point and asked for it
to be attacked; this is the attack, and it lands on the sentence, not on the outcome.

### D2 — MODERATE. Two removal tools in the engine have no §31 refusal; the table says "every door"

**Claim under test.** Table row 1: *"REFUSE … at every door"*; test name
`…EXCLUDED_BY_CEO_RULING_at_every_door`. §31: *"There is no blanket flag, no reason string that
unlocks the class"*; a Codex workspace is *"never removed without his express word"*.

**Evidence (inside).** `grep -rn "worktree', 'remove'\|worktree remove"` over non-test engine
scripts (appendix A8) finds two removal sites outside the lane, and `grep -i codex` finds nothing in
either:

- `discard-workspace-backlog.py:141` — `git worktree remove --force --force` from an operator manifest
  whose `authorization` field is a free string. A manifest naming the nine Codex trees would remove
  all nine, locked or dirty, in one run.
- `remove-agent-worktree.sh` — the sanctioned helper; it requires a BINDING (an ownership-ledger row
  naming the path, or the agent's own isolation worktree) but does not consult `BINDING_LEDGER_WRITERS`,
  so a hand-written row plus `--owner` binds a Codex path exactly as the amnesty row bound `red1`.

Both are operator-invoked, deliberate, and outside "sweep, reaper, reconciler or land sequence"; but
they are doors, the operator is the person §31 exists to stop, and `ceo_owned_workspace` is a
four-line call. The automatic lane is protected (H6); the claim "every door" is not true.

### D3 — LOW. The ignored-bytes half of the safety claim has a window between the archive and the `rm`

**Claim under test.** *"its ignored bytes are archived and verified first"* (table §3, code comment).

**Evidence (inside).** `reconcile()` order: `processes_using` (1171) → `archive_residue` (1177) →
`owner_check` → `verify_member_proof` → last look → `git worktree remove` (1198). The archive is
verified against the manifest at archive time; nothing re-lists ignored files or re-digests them
immediately before the removal, and `git worktree remove` does not refuse on ignored changes (its
clean check ignores ignored files). A writer the probe did not see at 1171 — one that starts after
the probe, or one whose open handle closes between writes — that writes an ignored file inside the
archive-to-remove window loses those bytes. The tracked bytes are covered by the re-verify; the
ignored bytes are not. Narrow (seconds, and a non-agent writer, since the agent itself is barred) and
cheap to close with the same "last look" pattern the tracked side already has.

### D4 — LOW. The own-member in-event reclaim carries no ceiling and no deadline

`_reclaim_in_event` → `reclaim_now(…)` with no `deadline`; `sweep_max_files` and the hook budget
apply only to sweep candidates. In practice it short-circuits at once — every own-event native attempt
on record found the lock held (now 4 of 4, fix1's at +15 s), and a cross-repo member is held on its
native sibling's lock via `_lock_bearing_member` — so the exposure is a `cwd:`-only spawn (refused by
the spawn guard) or a lock that happens to be absent at the stop. Frank's D5 fix is complete for the
sweep and the ordering; the sentence *"bound every candidate's work by the remaining budget"* is not
true of the event's own member.

### D5 — LOW. `vendor` in the disposable list does not meet the list's own bar

`CAPTURE_DISPOSABLE_PATHS` gained `vendor` with the stated bar *"a build reproduces it from what is
committed"*. The list applies only to ignored files, so a committed Go `vendor/` is untouched — but
an ignored `vendor/` is not always regenerable (hand-vendored, gitignored sources exist), and an
ignored directory on this list is discarded **without a copy**. Every other entry is a cache or a
build product; this one is a judgment.

### D6 — LOW. The record cannot say when a workspace was removed

The nightly `reconcile()` writes `daily_cleanup.phase = complete` with no timestamp of the removal;
only the in-event lane's `immediate_reclaim_history` carries one. Ordering a restart against a
removal — the question this whole round turned on — had to be inferred from grounds (`session_gone`
⇒ after the session ended) rather than read (appendix A2). One `removed_ts` field closes it.

### D7 — LOW, record only. Round one's D1/D3 evidence keeps accumulating, in the new design's favor

11 restarts of 67; 4 of 4 own-event native attempts found the lock held; fix1's lock still held
**15 minutes** after its second stop with no run in progress (20:07Z). No restart into a removed
workspace has been observed on this machine: all eleven restarts preceded their removals (appendix
A2). That is still ordering, not design — but the design no longer depends on it.

---

## 4. The three items the fixer refused, decided

- **Killing an agent's background children at its terminal event — refusal ACCEPTED.** The engine
  does not kill processes; a live child's cwd or handle in the tree is a RETRY the probe now fails
  closed on; the restart such a child triggers is detected and refused (H2). Killing would add
  authority to remove a hold, which is the wrong direction.
- **A live-turn-end demonstration of the land-disposition notice — refusal ACCEPTED as a scope
  limit, not as a certification.** `notice-land-disposition.sh` is registered on `Stop` and hook
  registrations snapshot at session start, so it cannot fire before a new session. It is a reporting
  control (`land-disposition.py` never mutates, re-confirmed by reading its git calls), it has 23
  cases plus an incident suite, and the escalation ledger holds 0 `land-disposition` rows. I am not
  certifying that it works on a live turn end; nothing in this round's safety depends on it.
- **Repointing the operator's plugin install — refusal ACCEPTED.** `engine-status.sh` now prints the
  running engine's path and HEAD; the fixer built the installed-record comparison, found it would fire
  in every engine-development session, and deleted it — the right call. The stale cache directory
  and its `.bak`/`.old` copies remain a trap for a reader of `installed_plugins.json` and are the
  operator's to remove; not a defect of this work.

---

## 5. What I examined and what I did not — including the suites, run

**Examined in full (diff or file):** `daily-workspace-cleanup.py` (whole diff, `reconcile`,
`owner_check`, `session_gone`, `_release_dead_lock`, `_absent_native_*`, `sweep_session`,
`_lock_bearing_member`, `processes_using`), `worktree-transactions.py` (`note_after_terminal`,
`restarted_after_terminal`, `running_after_terminal`, `record_start`, `claim_terminal`,
`is_terminal_agent`, `bind_late_members` diff, `_reclaim_in_event`), `worktree-ledger.py` diff,
`record-subagent-start.sh` and `terminalize-agent-worktrees.sh` in full, `completion-proof.py` diff,
`reconcile-terminal-worktrees.py` diff, `restart-after-terminal-measure.py` in full,
`land-disposition.py` and `land-disposition-measure.py` diffs, `escalations.py`, `escalate.sh`,
`stop-hook-notice.sh`, `notice-land-disposition.sh` diffs, `orchestration.config`, `engine-status.sh`,
`cleanup-routing.signature`, `guard-idle-land.sh` diffs, `guard-sealed-worktree.sh` (terminal
verdict path), `discard-workspace-backlog.py`, `remove-agent-worktree.sh` (header and validation),
`hooks/hooks.json` registrations, the decision table, both round documents' diffs, the refused-items
record, and every touched test/mutation suite's diff.

**Live record examined:** the transaction store (106 transactions, 104 terminal), the ownership
ledger (`finished`, `registered`, `terminated` rows for the restarted agents), all three
`worker-events.jsonl`, four native admin directories and their lock files (mtime/ctime),
`reconcile-terminal-worktrees.py --preview`, both measure scripts end to end, and the two
escalation rows.

**Suites — RUN this time, at richos `891f8d96`.** All 38 suites whose name touches this area
(`cleanup|transaction|terminaliz|subagent-start|completion-proof|escalat|land-dispos|stop-hook|
ledger|reconcile|sealed|adoption|liveness|routing|reap`, out of 234 on disk) were run serially with
their exit codes recorded. Results are in section 5a below (filled in from the run log in the final
commit of this document; a first run reported `rc=127` on every suite in 0 s because macOS has no
`timeout`, which was my runner's defect, not the suites', and is recorded so the number is not
mistaken for a pass).

**Not examined:** `reconcile-terminal-worktrees.py` beyond its `processes_using` and `preview`
diffs; `worktree-adoption.py` and T4 beyond confirming adopted transactions reach removal only
through `reconcile`; `discard-workspace-backlog.py` beyond its removal and validation; CI; the ten
prior rounds; whether the platform re-locks on restart (unanswerable from this machine's record —
D1); Codex's own worktrees beyond their presence. I spawned nothing and mutated no workspace; every
command I ran was a reader, except the suites, which build their own sandboxes.

### 5a. Suite results

**Filled in by Rich, not by Sage. Sage never read these results** — the platform restarted it after
its terminal record while the suite batch was still running, and `guard-sealed-worktree.sh` then
refused it every tool including `Read`. Sage's last observed state was **6 of 38 complete, all
`rc=0`**; everything below is Rich reading the file Sage could not.

Source: `scratchpad/suite-results/summary.txt`, 38 suite lines plus a `DONE` marker.

    38 suites recorded
    37 exited 0
     1 did NOT: scripts/reconcile-terminal-worktrees.mutation.sh   rc=143   62s

**`rc=143` is `128 + 15` — SIGTERM. That suite was KILLED, not failed, and it is therefore
UNVERIFIED rather than green.** It is not a pass and must not be counted as one. The most likely
cause is the memory pressure that killed two other long runs on this machine today, but Rich did not
establish that, so it is stated as unknown.

**This does not touch Sage's verdict.** Sage states in section 5 that all three blocking defects were
established from code and the live record, not from suites, and the verdict was committed before the
batch finished.

**Left for whoever acts on this:** `reconcile-terminal-worktrees.mutation.sh` has not been shown to
pass at `891f8d96`. Someone must run it to completion or record it as unverified.

---

## 6. What would have to be true for me to certify

Shorter than round one, and each stated so an engineer can act without asking me.

1. **D1.** Either (a) one observed restart of a native worktree whose lock was **absent** before the
   restart, with the lock file's `mtime`/`ctime` against the `WorkerStarted` timestamp, added to the
   measure script's output and quoted where the "re-locks before the run" sentence stands; or (b)
   every sentence asserting re-lock-on-restart as measured is rewritten as *unmeasured for
   restarts*, and the safety argument in the table §3 and `platform_lock_is_absent` names what
   actually holds — the ancestor gate, the dirty-tree refusal, and the write barrier refusing a
   terminal agent every tool — with the lock as defense in depth. (b) is honest today; (a) is
   better and may be impossible to arrange on demand.
2. **D2.** `ceo_owned_workspace` (or its shell equivalent) refuses in `discard-workspace-backlog.py`
   before `validate()` accepts a manifest, and in `remove-agent-worktree.sh` before any binding is
   accepted; the table's row 1 lists every removal site by name; the "at every door" test exercises
   those two doors.
3. **D3.** Immediately before `git worktree remove`, re-list the ignored files and compare to the
   archive manifest (names and digests); on any difference, RETRY with the reason — the same
   last-look shape as the lock check.
4. **D4.** Pass the hook's deadline and the file ceiling into `_reclaim_in_event`, or state in
   `terminalize()`'s docstring that the own member is unbounded and why the held lock makes that
   acceptable.
5. **D5.** Remove `vendor` from the list or justify it under the list's own bar beside the entry.
6. **D6.** A `removed_ts` (UTC) on `daily_cleanup` when `phase` becomes `complete`.

Item 1 is the certification; 2 is the CEO's ruling; 3–6 are cheap and I would not certify with them
open either.

---

## Appendix A — how each number was produced

All commands were run on this machine on 2026-09-10 between 19:55 and 20:25 UTC against richos
`891f8d96` in `/Users/alex/ab/richos-wt/sage-fable-cert2`. Scratch scripts are in the session
scratchpad and are described so they can be re-written in a minute.

**A1. Restarts, denominator.** `python3 engine/scripts/restart-after-terminal-measure.py` → 101
terminal, 67 workspace-owning, **11** restarted (table quoted in section 2 H4). `--census` →
`WorkerStarted rows=48 distinct=38 registration ids=36`; the two non-registration start ids are
2026-09-07 spawns in session `ed803501` that never sealed, not restarts under fresh ids.

**A2. Restart vs removal ordering.** For every terminal transaction whose `starts/<id>.json` `ts` is
after `terminal.ts`, print each member's `state`, `daily_cleanup.phase` and grounds: all eleven are
`removed/complete` (except fix1, held), with **no removal timestamp in the record**; the three from
sessions `5584bf8d`/`899d5bee` carry `session_gone`, so their removal followed the session's end and
therefore the restart. The eight from `d0eef867` carry `agent_over` and were reclaimed 14:35–15:39Z
or later per round one's A4 — all after their restarts.

**A3. Post-restart stop rows carry the registration id.** Join each post-terminal `WorkerStarted`
to `WorkerRunEnded` rows after it with the same `agent_id`: eleven restarts, every following stop
`payload_id == registration id` (deg1, auto1, q1, inf1, lc1 ×3, gate1, own1, fix1). The `stop` note
on fix1 confirms it end to end.

**A4. Lock file times.** For each `femcboost/.git/worktrees/agent-*/locked`: `os.stat` `mtime`,
`ctime`, admin-dir `mtime`, against `WorkerStarted` rows for the same id:
`a2de3c7d…` lock 16:07:26.643 / start 16:07:26.692; `a97f2c69…` lock 17:43:41.993 / starts
17:43:42.036 **and 19:57:02.259** (lock unchanged); `aa2e08d7…` (me) 19:54:19.894 / 19:54:19.995;
`aeb4b3b8…` 19:54:42.070 / 19:54:42.154. Reaper `terminated … registered and unlocked` rows for
q1/inf1/gate1/own1 at 13:11:22.947–23.601Z.

**A5. Land-disposition measure.** `python3 engine/scripts/land-disposition-measure.py` → 259
teammate landings over five repositories, 3 h: 7 of 259 (2.703 %), `DILUTION WARNING` printed,
reproducing command printed.

**A6. Preview.** `python3 engine/scripts/reconcile-terminal-worktrees.py --preview` →
`remove=0 branch-only=2 observe=0 hold=8 excluded=9 not-examined=0`; the eight holds are unl1 ×2
and fix1 ×2 (native lock, pid 8799 running) and dor1/dor2 ×4 (VM pid 1483).

**A7. Finish rows have no lock field.** Keys on `finished` rows for the restarted agents:
`agent_id, event, owner_agent_id, session_id, signal, source, task_id, teammate, ts, workspaces,
worktree`.

**A8. Removal sites.** `grep -rn "worktree remove\|'worktree', 'remove'\|rm -rf\|shutil.rmtree"`
over `engine/scripts` excluding tests, mutations and comments: `discard-workspace-backlog.py:141`,
`create-teammate-worktree.sh:270,288` (its own failed creation), `remove-agent-worktree.sh`
(header), `demo.sh:850` (its sample), probe/lint sandboxes. `grep -ni codex` in the first and third:
none.

**A9. Tracked-file counts.** `git ls-files | wc -l`: femcboost worktree 3,524; richos worktree 5,730.

**A10. fix1 transaction and lock, twice.** Read at 19:57:43Z (`after_terminal` = one `start`,
both members `deferred … run is still open` at 19:57:22Z, lock present) and at 20:07:20Z
(`start` + `stop`, counts `{1,1}`, both members `deferred … the platform is holding its own lock`,
lock present, `WorkerRunEnded` 19:57:51.458Z).
