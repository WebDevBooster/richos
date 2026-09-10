NOT CERTIFIED

# Certification review of the workspace-and-landing work at richos main `86a25f73` — Sage, 2026-09-10

**Reviewer:** Sage (software architect), on Fable, by the CEO's order. **Reviewed:** richos main
`86a25f73` (`Merge branch 'cc/zach-opus-unl1'`), the evidence pack
`richos-hq/docs/verification/lifecycle-failure-record-2026-09-10.md`, the specification
`richos-hq/docs/plans/land-completeness-2026-09-10.md`, `ceo-decisions.md` section 31, the round-11
document, and the live state of this machine as it was during the review (18:15–18:35 BST).
**Independence:** I did not read, seek, or receive Frank's verdict.

The verdict is in the first line and it is the only verdict this document contains. Nothing below
softens it into a score.

---

## 1. Why it is not certified, in one paragraph

The reclamation lane's safety argument is written down in `daily-workspace-cleanup.py`
(`platform_said_the_agent_stopped`): the platform's first `SubagentStop` for an agent id is
terminal, the terminal index makes it impossible to give the agent another turn, and therefore
deleting its workspace in that event cannot destroy live work — *"structural rather than
temporal"*. **The live record on this machine shows that premise is false.** Six agents this session
recorded as terminal were started again by the platform afterwards (`SubagentStart` for the same
agent id, hours later in four cases), and the path that started them was not `SendMessage` — it was
the platform's own background-task notification, which no guard sees and whose text says outright
that *"the same task-id may notify more than once"* and the agent can be resumed. Round 11's own
document names exactly this as the fact that would prove it wrong (its section 7). It is proven
wrong by the ledger the same day. Everything else in this document is secondary to that.

---

## 2. Defects found, with the evidence and how I established each

Severity is mine. "Outside" means established from a record the live system wrote or from the
running machine; "inside" means established by reading code or calling a function.

### D1 — SEVERE. "Terminal" is not "finished": the platform restarts agents the engine has sealed terminal, by a path no guard covers

**Claim under test.** `daily-workspace-cleanup.py:382-410` (`platform_said_the_agent_stopped`):
*"(2) is the whole safety argument ... It does not say the agent has been quiet for a while; it says
the agent cannot be given another turn."* Round 11 section 7: *"If a terminal record is ever
written for an agent that then runs again, the agent-sized ground is unsound and this round has to
be undone."*

**Evidence (outside).** Joining every sealed terminal transaction in
`~/.claude/state/worktree-transactions` against the live `SubagentStart`/`SubagentStop` rows in
`~/.claude/teams/session-*/worker-events.jsonl` (script: `restart_after_terminal.py`, re-runnable,
reproduced in appendix A):

```
terminal transactions (non-adopted): 98 {'SubagentStop': 84, 'NativeMemberGone': 5, 'TaskStop': 9}
agent ids with WorkerStarted (same id) AFTER their terminal record: 6
session   teammate         agent       ingress       terminal_ts          starts stops  max_gap_h
d0eef867  zach-opus-gate1  a892239196  SubagentStop  2026-09-10T06:37:01  1      1      7.96
d0eef867  zach-fable-lc1   a0af7565af  SubagentStop  2026-09-10T07:05:37  3      3      0.04
d0eef867  zach-opus-q1     a57075d069  SubagentStop  2026-09-10T08:22:45  1      1      6.2
d0eef867  zach-opus-deg1   a3f592cf0b  SubagentStop  2026-09-10T08:26:00  1      1      0.0
d0eef867  zach-opus-own1   ac115bc42a  SubagentStop  2026-09-10T08:41:50  1      1      5.88
d0eef867  zach-opus-inf1   aa1627717a  SubagentStop  2026-09-10T10:25:18  1      1      4.16
```

Only three sessions have `worker-events.jsonl` (the start hook is recent), so 6 is a floor, not a
rate. Within session `d0eef867`: 33 terminal transactions, 6 restarted after their terminal record.

**What restarted the four late ones.** `worker-events.jsonl` lines 1638–1641: four `WorkerStarted`
rows for `own1`, `gate1`, `inf1`, `q1` at `14:34:37.251–.256` UTC, six milliseconds apart. The main
transcript has **no** `SendMessage`, `Agent` or `TaskStop` call between 14:05 and 14:35 UTC. The
agents' own transcripts show what woke them — `agent-ac115bc42a1e283a9.jsonl` at 14:34:37.209:

> `[SYSTEM NOTIFICATION - NOT USER INPUT] This is an automated background-task event ...
> <task-notification> <task-id>buor0b6cp</task-id> ...`

and the platform's notification text to the lead (main transcript, 14:35:03):

> *"A task-notification fires each time this agent stops with no live background children of its
> own. The user can send it another message and resume it, so the same task-id may notify more than
> once."*

So an agent whose first own-id `SubagentStop` fired while it still had background children is not
finished; the platform starts it again when those children exit. `guard-resume-isolation.sh`
refuses `SendMessage` to a terminal agent (lines 219–293, verified) and covers nothing else.

**Consequence.** With round 11 live, the terminal event reclaims a merged, clean, unlocked
workspace in the event itself. A restart after that lands in a deleted directory — the failure
`guard-resume-isolation.sh` exists to prevent, now reachable through a path it does not see. Whether
that has already happened: **not observed.** The four restarts at 14:34 predate their reclaims (the
reclaims happened *in their second stop*, 15:35:02–07 BST, and the lane went live at 15:17 BST); the
two early restarts (`lc1`, `deg1`) predate the lane. I could not establish whether their locks were
held between first stop and restart, which is the one fact that would decide whether this is
"destroyed nothing by luck" or "destroyed nothing by a platform behavior nobody designed for" (see
D3). Neither is fit for use.

**The round's own falsifier was mismeasured (Type C/G in the pack's taxonomy).** Round 11 section 7
rests on *"1,153 WorkerRunEnded rows across 1,149 distinct agent ids ... 1,147 with exactly one"*
and reads that as "SubagentStop fires once per run." The ledger shows the payload's `agent_id` is a
**per-run** identifier (`worktree-ledger.py:288-330` says so, measured: 211 distinct ids on one
worktree). "Almost every id has exactly one row" is the signature of per-run ids, not of one stop
per agent, so that measurement cannot see a restart. The right join — the assignment id (the
`agent-<id>` in the cwd) against start events — is the one above.

**Two hooks on one event carry contradictory doctrine.** `worker-ended-handoff.sh:42`: *"`run_ended`
means this RUN ended, never 'this worker is gone'."* `terminalize-agent-worktrees.sh`, registered on
the same `SubagentStop` block (`hooks.json:340-355`): the first stop is terminal and the agent is
forbidden to return. The ledger writer is right and the terminalizer is wrong.

**Nothing notices a restart.** `record-subagent-start.sh` and `worker-started-handoff.sh` contain no
check against the terminal index; a terminal agent starting again is logged as an ordinary
`WorkerStarted`. No test in `worktree-transactions.test.sh`, `daily-workspace-cleanup.test.py`,
`terminalize-agent-worktrees.test.sh` models a `SubagentStart` after a terminal record (grep,
appendix A). Type A and Type O together: the falsifying event is recorded and reported to nobody.

### D2 — SEVERE. Section 31 is not in the mechanism; the "registration is the guarantee" cut has a demonstrated hole, used the same day

**Claim under test.** Round 11 section 3: the codex refusal was cut because *"this engine only ever
reclaims what it registered itself ... A folder nothing registered is not refused — it is never
reached."* `daily-workspace-cleanup.py:150-157` says the same.

**What section 31 requires (verbatim):** *"no sweep, reaper, reconciler or land sequence removes a
`codex/` workspace ... There is no blanket flag, no reason string that unlocks the class"* and *"an
excluded workspace is REPORTED, never silently skipped: 'excluded by CEO ruling', never counted as
clean and never absent from the report."* It also says, of the state before this work: *"The record
hole WAS the protection ... Closing it without this ruling in the mechanism would have destroyed all
eight on the first sweep. A correct cleanup that ships without the exclusion is a destructive
change."*

**Evidence (inside).** `grep -rn codex engine/scripts --include=*.py --include=*.sh` (non-test):
one comment in `daily-workspace-cleanup.py`, the CEO-owned prefix list in `land-disposition.py`
(report only), and a comment in `reap-stale-worktrees.sh`. **No removal path — reconciler, daily
lane, adoption, transactions, ledger — tests for `codex/` or `~/.codex/worktrees/`, and none
reports an excluded workspace.** The protection is exactly the pre-existing record hole the ruling
says must not be the protection.

**Evidence (outside) that the hole is one JSON line wide.** The ownership ledger is an append-only
JSONL with no writer authentication, and `worktree-ledger.py record` accepts any event. At
14:23:47 UTC today a row was appended by hand:

```
{"event": "registered", "class": "hand-rolled", "source": "rich-operator-amnesty",
 "teammate": "zach-opus-red1", "session_id": "d0eef867-…",
 "worktree": "/Users/alex/ab/richos-hq-wt/zach-opus-red1", "branch": "zach-opus-red1",
 "reason": "Operator amnesty 2026-09-10: this workspace was created before ownership registration
  existed for it and is named by no record, so no tool can ever judge it. …"}
```

`richos-hq-wt/zach-opus-red1` no longer exists (`git -C richos-hq worktree list` shows only the
codex tree). It was brought into the lane by a hand-written row carrying a session id and a
teammate name, which `bind_late_members` (`worktree-transactions.py:1420-1520`, teammate-name join)
and `owner_check` (`daily-workspace-cleanup.py:196-226`, id-less row for this session and teammate)
accept as ownership. The identical row with a codex path would put a codex workspace into the same
lane; nothing would refuse it and nothing would report it. Round 11 section 3 states this risk in
one sentence and then rests on it; the same session exercised it within 45 minutes of writing that
sentence. (Round 11 also says red1 *"stays forever because of the cut"* — false by 15:23 BST.)

### D3 — SEVERE. The lock-release premise was measured twice and is contradicted by the lane's own journal and by the live machine

**Claim under test.** `daily-workspace-cleanup.py:414-438` (`platform_released_its_lock`): the host
*"takes it off within about a second of the stop (dir mtimes 0.37s and 1.06s after the two
SubagentStop events measured that day)"*; the 5-second `IMMEDIATE_RECLAIM_WAIT_SECONDS` default is
*"generous rather than hopeful."* Round 11 section 7 calls a lock the platform stops releasing a
"degradation" to the sweep, then to the nightly pass.

**Evidence (outside).** The `immediate_reclaim` journal on this machine: 15 rows, 10 `deferred`,
5 `reclaimed` (appendix A). Deferred for a held lock: `zach-opus-key1` native at 17:55:18 BST (its
hand-rolled sibling reclaimed at 17:59:19 — the lock took about four minutes, not one second) and
`zach-opus-unl1`, whose terminal stop was 17:12:56 UTC and whose native lock
`/Users/alex/ab/femcboost/.git/worktrees/agent-a2de3c7d8d8590224/locked` still read
`claude agent agent-a2de3c7d8d8590224 (pid 8799 …)` at 18:30 BST — **77 minutes after the stop,
with no run in progress** (`worker-events.jsonl`: last event for that id is `WorkerRunEnded`
17:12:56, no later start). Its two workspaces, landed at 18:13, stand on the CEO's screen now.

**Why the lock is held, and why that matters more than the delay.** Two live shells owned by
session pid 8799 have their cwd inside unl1's native worktree (pids 67273 and 42978, `while ! grep …
ci.out; do sleep 10; done`, 34–44 minutes old). Those are unl1's background children. By D1's
mechanism, when they exit the platform will start unl1 again. So the held lock is not a
"degradation" — it is the only thing standing between the lane and reclaiming the workspace of an
agent the platform is about to restart. The design reads that state as a deferral to retry, not as
"this agent is not over," and measured lock release on two agents that apparently had no children.
The safety property the lane actually enjoys is one nobody designed, nobody measured, and the
document describes as a failure mode.

**What "degrades to the nightly pass" means on this machine.** `_release_dead_lock` refuses a lock
naming a live pid; pid 8799 is the CEO's session, which lasts a working day or longer. So a
workspace whose lock the platform keeps is held for the life of the session — the round-10 complaint
round 11 was written to end.

### D4 — MODERATE. The finish-event acceptance and the "reclaimed in the event" evidence are thinner than the record presents

- Of the 5 `reclaimed` journal rows, **4 were written in the second life of a restarted agent**
  (own1, inf1, q1, gate1's siblings at 15:35 BST — the stop in which the lane fired was the stop of
  a run the platform started at 14:34:37, not the agent's finish). The one clean in-event reclaim is
  `zach-opus-key1`'s hand-rolled tree, and that came from the catch-up sweep four minutes after the
  event, not from the event.
- The identity repair (D5 in the brief's numbering) was accepted by `run-live-proof.sh` in a nested
  session that *"loads NO settings sources so the installed engine never fires"* — a real session,
  not the shipped plugin path. The shipped path does now write the fields (34 finish rows since
  15:00 UTC carry `owner_agent_id`; my own rows do), so this one is established from the outside by
  this review rather than by its acceptance. Recording it because the acceptance's own commit
  message says "not a function anybody called" while the hook path was still unproven.
- The land-disposition demand (`notice-land-disposition.sh`) was registered in `hooks.json` at
  17:30 BST today; hooks snapshot at session start (05:39); the escalation ledger holds **0**
  `land-disposition` rows. It has never run on a live turn end. Its report mode, run by hand against
  real state during this review, was correct and honest (appendix A). Its threshold corpus is
  landings only — branches that never landed are absent by construction — so 7 of 1,114 is the
  false-positive rate among things that were eventually landed and says nothing about misses. The
  header says as much in different words; I am stating it as a limit of the number, not a defect of
  the tool.

### D5 — MODERATE. The plugin cache is a stale real copy, and the installation record points at it

`~/.claude/plugins/installed_plugins.json` says the engine's `installPath` is
`~/.claude/plugins/cache/richos-local/richos-engine/1.0.0` at `gitCommitSha a279a587`. That path
is a **real directory** (34 entries, mtime 15:17 BST), with `1.0.0.bak-2026-09-10` and `1.0.0.old`
beside it (17:32). Against the live engine it lacks `notice-land-disposition.sh`,
`land-disposition.{py,sh}`, `land-disposition-measure.py`, and carries an older
`worktree-ledger.py` and `hooks.json`. The hooks demonstrably execute the live tree (finish rows
written at 17:25 UTC carry `owner_agent_id`, which the cache's ledger cannot write), so the cache
is vestigial today — the probe's "green" in pack section 2.15 is right. But the record says one
thing and the behavior another, and a `.bak` and `.old` were created at 17:32, after 2.15 was
written. This is the 2.15 trap re-armed for the next reader.

### D6 — LOW. Paths nobody exercised, reasoned from code

- **Squash or rebase landings:** `completion-proof.verify_member_proof` (line 247–249) and
  `land-disposition.is_ancestor` both require the recorded tip to be an ancestor of trunk. A
  squash-landed branch is held forever with *"Current canonical main no longer contains the
  delivery"* and its demand can never self-close. Documented in the land-disposition header;
  correct under R3; false-positive class the lander's `git merge` discipline currently avoids.
- **A trunk that is not `main`:** `completion-proof.prove_member` hard-codes
  `integration='refs/heads/main'` (line 216) and `validate_member_schema` refuses any other
  (line 229). On a `master` repository `direct()` raises and the member holds with *"Git proof could
  not complete"* — fail-closed, misleading reason. `worktree-adoption` G7 uses the repository's own
  HEAD branch instead, so the two lanes answer differently for the same tree. Land-disposition
  handles `master` and names anything else as unexaminable.
- **A repository nobody registered:** never reached by reclamation (by construction);
  land-disposition scopes to the entity root plus repositories this session registered in — five
  today — so a repository worked in by hand is invisible, as its header says.
- **A held demand whose reason expired:** never reopened; stated in the header.
- **Live agent between turns and the 3h clock:** a cross-repo branch's liveness is its owner's
  native lock (`unlanded-branches.py:335-357`). The lock tracks a turn, not an assignment (mine is
  held now, while I run; unl1's is held while it idles). An agent paused on a question for more than
  three hours gets a demand saying *"nothing live holds it."* Reporting only; the sentence is
  wrong.

### D7 — LOW. The `cc/` prefix

Verified as claimed: the only occurrence in engine scripts is `create-teammate-worktree.sh:152`;
nothing tests for it, nothing refuses on it, nothing reads it as ownership. Not load-bearing. The
directory keeps the bare name, as documented. **No defect.**

---

## 3. The evidence pack, checked as a suspect document

- **Section 2.15 recurs in the work.** D5 is the same shape (a stale directory whose relationship to
  what runs is asserted rather than measured, now with a `.bak` and `.old` added after the
  correction). D3 is the same shape in the other direction (a two-sample measurement generalized
  into the safety timing of a deletion).
- **Section 5's cut left the hole named in D2**, and the pack's own section 3.4 ("a row with no
  agent id can hold a decided workspace forever") was answered by making id-less rows *bind*
  (`bind_late_members`, `owner_check`) — which is what turned a hand-written row into a removal.
- **The taxonomy omits the class D1 belongs to:** *a policy enforced on one path is read as a
  property of the system.* The CEO's ruling "forbidden to return" became a guard on `SendMessage`;
  the code then reasons from "forbidden" as if it were "unable." Every design in
  `worktree-lifecycle.md` section 14 failed by inferring death from quiet; this one infers death
  from a rule.
- **Section 1's fact stands.** During this review the CEO's screen shows `richos-wt/zach-opus-unl1`
  (landed 18:13, still registered), `deeply-wt/zach-opus-dor{1,2}` and
  `claude-orchestration-kit-wt/zach-opus-dor{1,2}` (held by the VM's open handles, correctly named
  as a RETRY), and nine codex trees. The work reduced the residue; it did not end the class.

---

## 4. Boundary of this review — what I examined and what I did not

**Examined in full:** `daily-workspace-cleanup.py`, `terminalize-agent-worktrees.sh`,
`create-teammate-worktree.sh`, `land-disposition.py`, `land-disposition.sh`, the
`worktree-adoption.py` tiers, gates, `evaluate`/`adopt`/`adopt_all`, `agent-liveness.resolve`,
`guard-resume-isolation.sh` sections (0)/(4a), the `SubagentStart`/`SubagentStop`/`Stop`
registrations in `hooks.json`, `completion-proof.py` lines 60–262, `worktree-ledger.py`
`assignment_workspaces`/`resolve_assignment`/`append`/`no_session_alive`,
`worktree-transactions.py` seal, `claim_terminal`, `is_terminal_agent`, `bind_late_members`,
`terminalize`, `member_paths`, the round-11 document, section 31, the specification, the evidence
pack, `land-disposition-measure.py` header, and the live state: transaction store, ownership
ledger (16,648 rows), `worker-events.jsonl`, the main and four subagent transcripts, lock files,
process table, plugin cache, worktree registries of five repositories.

**Not examined:** the reconciler beyond its main loop and adoption pass (1,392 lines);
`reap-stale-worktrees.sh` beyond its candidate rule; the quarantine/capture path for historical
members; managed-workspace integration; `shell-worktree-sparse`; `escalations.py`;
`unlanded-branches.py` in full; `teammate-identity.py`; the TaskStop and WorktreeRemove ingress
internals; every `*.test.*` and mutation suite (I read their inventories and grepped them; I did not
run them); CI; the ten prior rounds in `worktree-lifecycle.md` beyond their headers; T4's
`claude`-by-process-name check against sessions launched through the RichOS desktop shell
(unverified whether they present as `claude`). I did not exercise squash landings or a non-`main`
trunk on a real repository; D6 is from code.

---

## 5. What would have to be true for me to certify

Each is stated so an engineer can act without asking me. All of them, not some.

1. **The terminal ground is the platform's finish, not its first stop.** Either (a) a measured,
   documented platform fact that an agent with a held native lock is the *only* resumable state and
   the lane refuses on that lock as a liveness signal (not a deferral) — with the measurement
   covering the background-child case, the message case, and any harness path that delivers a turn
   — or (b) the lane never removes a workspace while the platform still lists the agent as
   resumable, established by a positive signal (the platform's own removal of the worktree,
   `WorktreeRemove`, or the task's terminal state), and the `SubagentStop` ingress no longer seals
   terminal on its own. Whichever: `daily-workspace-cleanup.py:382-410` must no longer claim the
   agent cannot be given another turn, because it can.
2. **A restart of a terminal agent is detected, reported, and un-seals nothing silently.**
   `record-subagent-start.sh` (or `worker-started-handoff.sh`) checks the terminal index on every
   `SubagentStart`; a hit is announced on stderr and written to the transaction; the lane refuses
   every member of that transaction until the design in (1) decides it. A test models the sequence
   `seal → claim terminal → SubagentStart(same id) → reclaim attempt` and asserts refusal. The
   re-runnable join in appendix A is committed beside the tests and its count is published in the
   round document in place of the per-run-id count.
3. **Section 31 is in the mechanism.** Every removal path (`reconcile`, `assess`,
   `_absent_native_without_receipt`, adoption `evaluate`, the reaper's `--execute`) refuses a member
   whose branch starts with `codex/` or whose path is under `~/.codex/worktrees/`, before any other
   gate, with no acknowledgement line and no reason string, and reports it as *"excluded by CEO
   ruling."* A test asserts both shapes at each door. The registration-only argument may stay as
   defense in depth; it may not be the defense.
4. **The ledger's binding writers are named.** A `registered`/`prepared` row is accepted as
   ownership only when its `source` is one of the engine's own writers
   (`create-teammate-worktree.sh`, `detect-nonnative-worktree.sh`, the native registration hook),
   and a row with any other source is reported and never bound — so an "amnesty" is a report a
   person reads, not a removal. Alternatively, an operator amnesty is a first-class, refused-by-
   default event with the CEO's word recorded on it, per section 31's "naming ONE workspace."
5. **The lock-release timing is measured over the population, not two agents,** and the
   `IMMEDIATE_RECLAIM_WAIT_SECONDS` default and the "degradation" paragraph in round 11 section 7
   are rewritten from that measurement. A held lock over a terminal agent is journaled as *"the
   platform still considers this agent resumable"*, not as a wait that expired.
6. **The land-disposition demand has run on real turn ends in a real session** with at least one
   demand raised and one self-closed by a real land, and the rows are cited in the round document;
   its sentence *"nothing live holds it"* is qualified when the owner's lock is merely released
   between turns.
7. **The installation record matches the execution path.** Either the plugin cache is a symlink to
   the live checkout, or `installed_plugins.json` points at the live checkout, and `.bak`/`.old`
   copies are removed; `engine-status.sh` prints the resolved path and its HEAD.
8. **The round-11 document is corrected** where this review shows it false on its own day: section
   3's red1 sentence, section 7's falsifier measurement, and section 2's lock paragraph.

---

## Appendix A — how each number was produced

All commands were run on this machine on 2026-09-10 between 18:15 and 18:35 BST against richos
`86a25f73`. Scripts are in the session scratchpad and reproduced here so they can be re-run.

**A1. Restarts after terminal** (`restart_after_terminal.py`): for every `record: transaction` under
`~/.claude/state/worktree-transactions/*/` with a `terminal` record and `kind != adopted`, collect
`WorkerStarted` rows for the same `agent_id` from every `~/.claude/teams/session-*/worker-events.jsonl`
with a timestamp more than 2 s after `terminal.ts`. Output quoted in D1.

**A2. Own-id finish rows after terminal:** for the six above, `~/.claude/state/worktree-ledger.jsonl`
rows with `event: finished` and `agent_id` equal to the transaction's own id, after `terminal.ts`:
`sage-fable-r2` (2026-09-08) 2 rows to +9 min; `zach-fable-lc1` 3 rows to +3 min; `zach-opus-q1`
1 row at +6.2 h (`teammate` populated, so the repair fires live); `zach-opus-deg1` +33 s;
`zach-opus-auto1` +36 s.

**A3. What woke the four:** main transcript
`~/.claude/projects/-Users-alex-ab-femcboost/d0eef867-….jsonl`, tool calls 14:05–14:35 UTC filtered
to `SendMessage|Agent|TaskStop|ListAgents` — none. Subagent transcript
`…/subagents/agent-ac115bc42a1e283a9.jsonl` at `2026-09-10T14:34:37.209Z` — the system notification
quoted in D1. `worker-events.jsonl` lines 1638–1646.

**A4. Immediate-reclaim journal:** every member's `immediate_reclaim` across the transaction store —
15 rows: `reclaimed` ×5 (`zach-opus-auto1` hand-rolled 15:35:02, `zach-opus-inf1` native 15:35:05,
`zach-opus-own1` native 15:35:07, `zach-opus-q1` native 15:39:50, `zach-opus-key1` hand-rolled
17:59:19, all BST); `deferred` ×10 (unintegrated ×2, dirty ×1, lock held ×3, VM process ×4).

**A5. Lock state, live:** `cat /Users/alex/ab/femcboost/.git/worktrees/agent-a2de3c7d8d8590224/locked`
at 18:29:30 and 18:30 BST → `claude agent agent-a2de3c7d8d8590224 (pid 8799 start Thu Sep 10
05:39:28 2026)`; unl1's last worker event `WorkerRunEnded 2026-09-10T17:12:56Z`; its transaction
`terminal.ts 2026-09-10T17:12:56.113042+00:00`. Background shells: `ps -axo pid,ppid,etime,comm |
awk '$2==8799'` → six; `lsof -a -p 67273 -d cwd` and `-p 42978` → cwd
`/Users/alex/ab/femcboost/.claude/worktrees/agent-a2de3c7d8d8590224`; their command lines are
`while ! grep -E … ci.out; do sleep 10; done` / `sleep 15`.

**A6. Codex and cc/ references:** `grep -rn "cc/" engine/scripts --include=*.py --include=*.sh`
(non-test) → four lines, all `create-teammate-worktree.sh` 137–152. `grep -rln codex engine/scripts`
(non-test) → `land-disposition.sh`, `reap-stale-worktrees.sh`, `notice-land-disposition.sh`,
`land-disposition.py`, `daily-workspace-cleanup.py` (comment at 154–157 only).

**A7. The amnesty row:** `grep zach-opus-red1 ~/.claude/state/worktree-ledger.jsonl` → 4 rows; the
last is the `rich-operator-amnesty` row quoted in D2 (`ts 2026-09-10T14:23:47.526289+00:00`).
`git -C /Users/alex/ab/richos-hq worktree list` → main and `codex-rollback-owned-outcome` only.

**A8. Plugin cache vs live:** `diff -rq ~/.claude/plugins/cache/richos-local/richos-engine/1.0.0/scripts
/Users/alex/ab/richos/engine/scripts` → the seven differences listed in D5; `installed_plugins.json`
quoted in D5; `ls` of the cache parent → `1.0.0`, `1.0.0.bak-2026-09-10`, `1.0.0.old`. Finish rows
since 15:00 UTC: 150, of which 34 carry `owner_agent_id` and 36 carry `workspaces` — fields only
the live `worktree-ledger.py` writes.

**A9. Land-disposition, report mode, real state:** `python3
engine/scripts/lib/land-disposition.py --entity-root /Users/alex/ab/richos --session d0eef867-… --format
text` → five repositories examined, one item, `[CEO-OWNED] richos codex/owned-outcome-prd` (19.28 h,
not demanded), `COULD NOT DECIDE (0)`, `NOT EXAMINED (0)`. `grep -c '"kind": "land-disposition"'
~/.claude/state/escalations.jsonl` → 0.

**A10. Test coverage of a restart:** `grep -ln "SubagentStart\|runs again\|resumed after\|restart"`
over `daily-workspace-cleanup.test.py`, `worktree-transactions.test.sh`,
`terminalize-agent-worktrees.test.sh` → only `worktree-transactions.test.sh`, whose two hits (T08,
T15) are about a seal *before* a start, not a start after terminal.
