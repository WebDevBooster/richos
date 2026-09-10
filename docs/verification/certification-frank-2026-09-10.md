NOT CERTIFIED

# Certification review, Frank — workspace reclamation, land disposition, identity repair, `cc/` prefix, §31

**Reviewed at:** richos main `86a25f73e83905f9563fa3744d7029699c711d93` · **Date:** 2026-09-10 · **Reviewer:** Frank (Fable), one of two independent keys
**Evidence pack:** `richos-hq/docs/verification/lifecycle-failure-record-2026-09-10.md` · **Specification:** `richos-hq/docs/plans/land-completeness-2026-09-10.md`
**Method:** read every file named in the brief, then verified each claim against the LIVE record on this machine — the transaction store, the ownership ledger, `worker-events.jsonl`, the orchestrator transcript, the git admin directories, the capture store — and re-ran every derivation script whose number the work publishes. Every number below carries the command or script that produced it; scratch scripts are named where I wrote one.

## 1. The verdict in one paragraph

The reclamation's new ground — *"the platform said this exact agent stopped, and it cannot be given another turn"* — is false on this platform, and the round's own document names that fact as the one that would prove it wrong (`worktree-reclaim-round-11-2026-09-10.md` §7). Seven of the 101 terminal worktree-owning agents on this machine were started again after their terminal record, all in today's session, by two mechanisms no guard can see: a message queued before the stop, and a background task's kill notification delivered to the agent. The measurement §7 offers as proof that this cannot happen counts per-run identifiers, each of which appears once by construction. Nothing was destroyed today because every restart happened to precede the reclaim of that agent's workspace, by minutes. That is ordering luck, not a design. Beside it stand a false-positive rate that does not reproduce (7 of 258, 2.7%, not 7 of 1114, 0.6%), a lock-release premise contradicted by two of the four data points, a sweep placed before the terminal record inside a 20-second hook budget, a process check that reads its own failure as an empty tree, and a ruling (§31) whose text the shipped code contradicts. Several parts of the work are sound and are named in §4. The work as a whole is not fit for use.

## 2. Defects, most important first

### D1. Terminal agents run again, and the round's own falsifier has already occurred — seven times today

**Claim under test:** `daily-workspace-cleanup.py` `platform_said_the_agent_stopped()` — "*(2) is the whole safety argument ... it says the agent cannot be given another turn.*" Round-11 doc §7: "*If a terminal record is ever written for an agent that then runs again, the agent-sized ground is unsound and this round has to be undone.*"

**Established:** joined every terminal transaction's `terminal.ts` to `~/.claude/teams/*/worker-events.jsonl` `WorkerStarted` rows on the same registration id (`scratchpad/restarts.py`):

```
worktree-owning terminal agents restarted after their terminal record: 7 of 101
zach-opus-deg1   terminal 08:26:00Z  RESTARTED 08:26:03Z          (+3 s)
zach-opus-auto1  terminal 14:16:21Z  RESTARTED 14:16:22Z          (+1 s)
zach-fable-lc1   terminal 07:05:37Z  RESTARTED 07:05:41, 07:07:44, 07:08:18Z
zach-opus-q1     terminal 08:22:45Z  RESTARTED 14:34:37Z          (+6 h)
zach-opus-inf1   terminal 10:25:18Z  RESTARTED 14:34:37Z
zach-opus-gate1  terminal 06:37:01Z  RESTARTED 14:34:37Z
zach-opus-own1   terminal 08:41:50Z  RESTARTED 14:34:37Z
```

Each restart is a `SubagentStart` with `cwd` = the agent's native worktree and a matching `WorkerRunEnded` ~20–40 s later. All seven are in session `d0eef867` — the session in which this work was built.

**The two mechanisms, both invisible to `guard-resume-isolation.sh`:**

- *A message queued before the stop.* `inflight-notices.jsonl` shows an InflightNotice sent to `zach-opus-deg1` at 08:25:34Z (agent active, send allowed); deg1 stopped at 08:26:00Z (terminal record claimed); the platform delivered the queued notice at 08:26:03Z and started it again. An inflight notice makes the recipient **write an ack file and commit in its worktree** (`inflight-ack.sh`), and it is triggered by a land — the same land that makes the worktree reclaimable.
- *A background task's end delivered to the agent.* The orchestrator transcript at 14:34:37.066–.084Z holds six `queue-operation enqueue` rows for `<task-notification>...<status>killed</status>` (background `Wait` commands), each removed at 14:34:37.210Z with `reason: delivered_to_agent`. Four terminal agents started 5 ms apart. No SendMessage was involved. This is the "zombie residue" mechanism `CLAUDE.md` already records (a background child outlives its agent), and it *restarts* the agent.

**Why nothing was lost today:** q1 restarted at 14:34:37Z; its native worktree was reclaimed at 14:39:50Z (`immediate_reclaim.ts`, `scratchpad/*.py` over the transaction store). Five minutes the other way and four agents would have been started in deleted worktrees. Rich's own transcript at 14:35:20–14:36:05Z shows him investigating "the deleted branches" for exactly these four.

**What the design relied on instead, and why it does not hold:** the platform's lock. Round 11 waits for the platform to release the native lock and treats that release as "the host saying it is finished with the workspace." D3 shows the release is not reliably observed, and the four 14:34Z restarts show an agent can be restarted after its lock was released (their `terminated` rows are at 13:11Z; the restart is at 14:34Z). A released lock is a fact about a turn, not about the assignment.

**Severity:** existential for the round. The round's document says what to do when this fact is observed: undo the agent-sized ground.

### D2. The §7 measurement is a tautology, and the corpus is exactly the poisoned one the brief warned about

**Claim:** round-11 §7 — "*SubagentStop fires once per run: 1,153 WorkerRunEnded rows across 1,149 distinct agent ids in this session, 1,147 of them with exactly one.*"

**Established:** `worktree-ledger.py` `resolve_assignment()` docstring, in the same landing: "*The SubagentStop payload's `agent_id` is a PER-RUN identifier ... 211 DISTINCT payload agent ids appear on finish rows for the single worktree `agent-a42c90096292136f0`.*" Re-keyed by worktree id (`scratchpad/rekey.py`): 2,976 SubagentStop finish rows; the payload id equals the registration id on **63** of them; `zach-opus-auto1`'s worktree has 212 stop rows under 211 ids. A count of per-run ids will show one row per id for as long as the platform mints a fresh id per run. It measures the platform's id scheme, not whether an agent runs again. Re-keyed on the registration id (D1), the number is 7 of 101.

The 1,149-id corpus is 99.8% helper subagents with no workspace; among the population that owns a workspace, one in fourteen restarted today. This is the brief's own objection to the 3h threshold — "the tail it learns from is made of the failures it must catch" — applied to the round's central safety premise. Type D and Type G in the record's taxonomy.

### D3. "The platform takes its lock off within about a second of the stop" is contradicted by half the data

**Claim:** `platform_released_its_lock()` docstring and round-11 §0: 0.37 s and 1.06 s after two SubagentStop events.

**Established:** those two (ecs3 `ae66ffef…`, rec1 `aea7c66…`) are real. Against them:

- `zach-opus-key1` native: own-event reclaim journaled `deferred — Claude Code still holds its own lock` at terminal + 6.0 s (the 5 s wait expired).
- `zach-opus-unl1` native (`agent-a2de3c7d8d8590224`): `WorkerStarted` 16:07:26Z, lock file mtime 16:07:26.64Z, `WorkerRunEnded` 17:12:56Z, `terminated` (rich-observed-return) 17:14:08Z — and at 17:26Z the lock file is present, unchanged, `pid 8799` (`scratchpad/unl1.py`; `git -C femcboost worktree list --porcelain`). The reconciler preview holds both of unl1's workspaces on it.

**Consequence, verified in the production record:** of the 5 `reclaimed` outcomes in the transaction store, **zero** happened in the agent's own terminal event; every one was a later catch-up sweep (auto1 +1,121 s, key1 +247 s, q1/inf1/own1 +15,000–22,000 s). The mechanism the round is named for — "the event does the work" — has not done the work once. The 5 s wait is paid on every stop of every worktree-owning agent for nothing, and the journal only records the deferral when nothing later overwrites it (D14).

### D4. Round 11 opens a path that releases the platform's lock over an agent that may run again

`reconcile()` (non-immediate) → `_release_unattributable_lock()`: a lock whose reason names no pid, over an agent with a platform terminal record and a terminal index, is unlocked and the workspace removed. Rationale: "*a lock nobody can be behind.*" But the platform holds a lock by the file's presence, not its content — and §2.5/2.6 of the evidence pack records Rich emptying the lock reasons of **three live agents** that morning with `git worktree lock` sans `--reason`. Combine: emptied reason + a terminal record (D1: written for agents that run again) + the nightly pass = the platform's lock on a restartable teammate removed and its clean, landed worktree deleted, followed by a restart into nothing. `lock_names_nobody()` answers "who holds it"; the correct answer is "the platform, whatever it wrote."

### D5. The catch-up sweep sits BEFORE this event's terminal record, inside a 20-second hook budget

`engine/hooks/hooks.json`: `SubagentStop`, `WorktreeRemove`, `PostToolUse[TaskStop]` → `terminalize-agent-worktrees.sh`, `timeout: 20`. In the hook, `sweep_session()` (budget `IMMEDIATE_RECLAIM_SWEEP_SECONDS=10`) runs first; then the event's own `claim_terminal` and `terminalize`, which waits up to `IMMEDIATE_RECLAIM_WAIT_SECONDS=5` and then runs `reconcile()`. The sweep's deadline is checked **only between candidates** (`for aid, index, path in candidates: if time.time() >= deadline: break`); one candidate runs `lsof -t +D` (subprocess timeout 120 s), `clean_tree()` (SHA-1 of every tracked file), `git ls-files --ignored`, and `archive_residue()` (tar + re-read + digest of every ignored non-disposable file — one production archive holds 2,117 files of a SwiftPM `.build` tree).

Measured: `lsof -t +D` on `femcboost/avelor` (60,629 files, `node_modules` present) = 2 s; on this worktree (3,527 files) = 0.3 s. Not the 120 s worst case, but the budget is 20 s for sweep + wait + own reclaim + record, and the hook's own header promises the opposite order: "*writes the irrevocable `terminal` record BEFORE mutating any worktree.*" When the harness kills the hook at 20 s, the outcomes are: this agent's terminal record silently never written (the hook exits 0 by design, so nothing says so), or a `git worktree remove` cut mid-way, leaving a half-deleted tree whose proof can never again pass (`Working file changed during proof`) — a hold nothing clears.

### D6. `processes_using()` reads its own failure as an empty tree (Type A)

```python
try:
    res = subprocess.run(['lsof', '-t', '+D', path], ..., timeout=120)
    pids.update(...)
except Exception:
    pass
```

A timeout, a missing `lsof`, a permission error — each returns no pids, and the caller proceeds to `git worktree remove`. On macOS an open directory handle does not stop `rm`, so the VM's seven held workspaces (`pid 1483 com.apple.Virtualization.VirtualMachine`) are protected exactly as long as `lsof` answers. "RETRY, not a verdict" becomes "nobody is here" on the day `lsof` is slow. The record's Type A, in the one predicate whose whole purpose is to refuse.

### D7. The published false-positive rate does not reproduce (Type G)

**Claim:** `land-disposition.py` docstring, evidence pack §5, the brief: "*Against 1114 teammate landings ... At 3 hours, 7 of those 1114 landings would have carried a demand (0.628%).*"

**Re-derived** with the script the docstring names as the derivation, `python3 engine/scripts/land-disposition-measure.py`, today, this machine:

```
teammate landings measured : 258
landings skipped (subject names no teammate branch): 1055
3h :    7 of 258 landings would have been demanded (2.713%)
```

The seven landings are the same seven (3.95 win1, 5.63, 6.90 dor1, 6.93 prem1, 12.45, 44.61, 47.44 dr1). The denominator is not. 1,313 merges across five repositories, 258 matched by the name regex; I did not establish where 1,114 came from, and the rule this project wrote on 2026-09-05 says that is not my job — the number carries the command or the word unverified, and the command says 2.7%. Whether 2.7% is acceptable for a reporting-only check is a different question (I think it is); the finding is that a quoted number went into three documents and one brief and does not survive its own script.

### D8. §31 as written and the code as shipped disagree, and the ruling page was not amended

`ceo-decisions.md` §31: "*an excluded workspace is REPORTED, never silently skipped: 'excluded by CEO ruling', never counted as clean and never absent from the report.*" Round-11 doc §3: the named codex refusal and the closed-world report were "*built and then removed on the same day*"; a folder nothing registered "*is not decided by anything here and is not looked at.*"

**Established:** `reconcile-terminal-worktrees.py --preview` against real state names six holds and **no** Codex workspace, with three standing (`~/.codex/worktrees/06e6`, `~/.codex/worktrees/67ec`, `richos-hq-wt/codex-rollback-owned-outcome`); `grep -ci codex` over the preview = 0. Only `land-disposition.py` honors the "reported, never silent" clause (it prints `[CEO-OWNED]`). The reclaim lane satisfies the *refusal* half of §31 by construction — I accept that argument — and violates the *reporting* half by construction, and R5 ("the check reports what it did NOT examine") with it. Separately, §31's "general principle" half (facts on disk suffice; no ownership record participates) is refuted by the pack's own §2.17 (an agent proved it would have deleted a live agent's workspace) and still stands in the ruling as "the more valuable half." Record and code must say the same thing; today they do not, and the record is the one the CEO reads.

### D9. The land-disposition notice goes quiet for a working day (Type F)

`notice-land-disposition.sh` → `stop_notice_abnormal "owed:${NRAISED}:${KEY}"`, state-change de-duplicated. The escalation ledger's own ladder re-announces at 1 h, 24 h and 72 h. A demand raised at 3 h of standing is therefore announced at ~3 h and ~4 h, then **not again until ~27 h**. The pack's §3.1 describes `notice-unlanded-branches.sh` failing in exactly this shape: "*It spoke once, was right, and went silent for a working day.*" The new mechanism has a 23-hour silent gap that starts where a working day starts. The de-duplication rationale ("a condition repeated under every turn is a condition the eye is trained to skip") is a judgment; the gap is a measurement.

### D10. A hold's stated reason has no expiry (Type J)

`land-disposition.py` says so itself: "*nothing REOPENS a held item when its reason expires: 'waiting on a decision that is the CEO's' closes the demand permanently, including on the day after he decides.*" The pack's §2.7 is the same day's lesson in the same words: "*A claim baked into a record with no condition that voids it will outlive its truth.*" A design that names its own Type-J instance is more honest than one that hides it; it is still a Type-J instance, and the CEO's "no third state" has a fourth one: held for a reason that is no longer true.

### D11. A laundered line number in the brief itself (Type G, small)

The brief: "*Deletion claimed to happen ONLY on a tip proven an ancestor of main (`daily-workspace-cleanup.py:853`).*" Line 853 at `86a25f73` is inside `assess()`, the read-only twin that "*writes nothing, takes no lock, unlocks nothing.*" The deletion sites are `reconcile()` (`git worktree remove` at line 962; `update-ref -d` at 987 and 997) and `_absent_native_without_receipt()` (`update-ref -d` at 771 and 780) — `grep -n "'worktree', 'remove'\|'update-ref', '--no-deref', '-d'"` at `86a25f73`. The claim itself is true (D-OK-1 below); the citation is not. Noted because the rule about numbers in briefs was written five days ago, by the author of this brief.

### D12. Late-binding by teammate name can bind a fresh workspace to a finished transaction — unverified risk

`bind_late_members()` binds an id-less ledger row that names this transaction's teammate, when that name is unique among the session's transactions. A worktree created by `create-teammate-worktree.sh` has tip == main and is clean, i.e. it passes every reclaim refusal the instant it is bound. If a worktree is ever created for a name whose transaction is already terminal in the session, the next terminal event's sweep binds it and removes it before any spawn seals. The name-reuse guard makes the trigger unlikely; the row carries no agent id by construction and the seal is later, so the window exists. **I did not reproduce this**; it is listed so the boundary is visible, not as an established defect.

### D13. The capture store archives ignored files without a secret filter or a retention bound (low)

51 archives under `~/.claude/state/worktree-captures/`; at least 15 hold `avelor/.env.local` and `fitapp/.env.local` (`scratchpad/captures.py`). Today those files carry only `PUBLIC_CONVEX_URL`/`PUBLIC_CONVEX_SITE_URL` (`scratchpad/envcheck.py`), so nothing leaked. The mechanism would archive a real secret with the same care, forever, in a store `scan-secrets.sh` does not watch, and the disposable policy misses `.build` (2,117 files archived once), `.svelte-kit`, and similar. Not a certification blocker; a hole to close before the next `.env` that is not public.

### D14. The `immediate_reclaim` journal overwrites; only the last outcome survives

`reclaim_now()` → `update_member(immediate_reclaim={...})`. key1's own-event deferral is readable only because no later sweep re-ran on that member; unl1's own-event outcome is gone under its 18:20 sweep row. "*The ingress's decision is a line in the record and not an inference*" — one line, replaced. D3's "zero in-event reclaims" is established from timestamps and phases, not from journals, because the journals cannot show it.

## 3. What I examined, and what I did not

**Examined, at `86a25f73`:** `engine/scripts/lib/daily-workspace-cleanup.py` (all 1,205 lines), `engine/scripts/lib/worktree-transactions.py` (§§ `_ModuleSelf` through `close_if_empty`, function index of the rest), `engine/scripts/hooks/terminalize-agent-worktrees.sh` (all), `engine/scripts/lib/completion-proof.py` (lines 1–300, the proof/verify core), `engine/scripts/lib/worktree-ledger.py` (`assignment_workspaces` tail, `agent_id_from_worktree`, `resolve_assignment`, `append`, the reaper's `terminated` writer), `engine/scripts/lib/land-disposition.py` (all 962 lines), `engine/scripts/land-disposition.sh` (all), `engine/scripts/land-disposition-measure.py` (definitions and a full run), `engine/scripts/hooks/notice-land-disposition.sh` and `notice-escalations.sh` (de-duplication), `engine/scripts/lib/stop-hook-notice.sh` (`stop_notice_abnormal`), `engine/scripts/hooks/guard-resume-isolation.sh` (structure and exemptions), `engine/scripts/lib/unlanded-branches.py` (liveness rule), `engine/scripts/create-teammate-worktree.sh` (the `cc/` lines), `engine/hooks/hooks.json`, `engine/orchestration.config` (the new keys), `engine/docs/worktree-reclaim-round-11-2026-09-10.md`, `richos-hq/docs/plans/land-completeness-2026-09-10.md`, `richos-hq/wiki/ceo-decisions.md` §31, and the evidence pack.

**Live record examined:** the full transaction store (103 transactions, 101 terminal), the ownership ledger (16,651 rows), `~/.claude/teams/session-d0eef867/{worker-events,inflight-notices}.jsonl`, the orchestrator transcript for 14:30–14:36Z, femcboost's worktree registry and lock files, the capture store, `reconcile-terminal-worktrees.py --preview` and `land-disposition.sh` (report mode) against current state, and `land-disposition-measure.py` end to end.

**Not examined:** `reconcile-terminal-worktrees.py`'s 1,392 lines beyond its preview output; `worktree-adoption.py` and the T4 crash-recovery tier; the test suites (`land-disposition.test.sh`, the reconcile cases) — I judged the shipped behavior, not the tests' opinion of it; `guard-resume-isolation.sh` beyond the terminal check and exemption order; the squash/rebase and non-`main` trunk paths beyond confirming they hold rather than delete (`integration_ref` is hard-coded `refs/heads/main`; a `master` repository is refused, not swept, and `land-disposition.py` reports it as undecidable); Codex's own worktrees beyond their presence; the ten prior rounds in `worktree-lifecycle.md` except where round 11 cites them. I did not spawn anything or mutate any workspace; every command I ran was a reader.

## 4. What held up

So that iteration goes where it is needed and nowhere else:

- **D-OK-1. Deletion only on a tip proven an ancestor of `main`.** `verify_member_proof()` re-derives `merge-base --is-ancestor <head> refs/heads/main` against the current tip before `git worktree remove` and again before `update-ref -d`, and `_absent_native_branch_tip()` does the same for the receipt-less path, by compare-and-set on the tip checked. R3 holds. A squash-landed branch is refused, not swept.
- **D-OK-2. `land-disposition.py` never mutates.** Every git call in it is a reader (`merge-base`, `rev-parse`, `log`, `cat-file`, `for-each-ref`, `worktree list`); its one write is an append to the escalation ledger. Its report against real state today was truthful: one `codex/` branch, `[CEO-OWNED]`, exit 0; undecided and not-examined sections printed even when empty.
- **D-OK-3. The identity repair.** `resolve_assignment()` is prefer-the-resolvable as described, keeps both ids, and never overwrites `agent_id`. It has produced **three** correct production rows, not one: q1 (14:34:59Z), inf1 (14:35:02Z), key1 (16:54:59Z), each with `teammate` and both `workspaces`. Advisory, as claimed.
- **D-OK-4. The `cc/` prefix** is one line (`[ "$MANAGED" -eq 0 ] && BRANCH="cc/$NAME"`), nothing in the reclaim lane reads it, and the measure script's name regex still matches `cc/<name>` merge subjects (`/` is a word boundary).
- **D-OK-5. The RETRY vocabulary.** A process in the tree is journaled with pid and command, never as liveness — as long as `lsof` answers (D6).
- **D-OK-6. Late binding closed the hole it was built for**: 3 transactions carry `late_bindings`, and dor2's four workspaces are all members.

## 5. What would have to be true for me to certify

Specific enough to act on without asking me:

1. **The agent-sized ground is withdrawn or re-founded on a fact the platform actually provides.** Either remove `agent_workspace_is_reclaimable()` as an authorization and return to "owning session provably gone" plus an explicit orchestrator shutdown event (a `terminated` row witnessed by the reaper *or* a TaskStop result — never a SubagentStop), or show, on this machine, over the population of worktree-owning agents keyed by registration id, that no agent has a `WorkerStarted` after the event you call terminal. D1's seven must read zero under the new definition, and the measurement must be keyed the way D2 says.
2. **A queued message or a background-task notification cannot start a reclaimed agent** — or a reclaimed agent's restart is made harmless: at minimum, `SubagentStart` for an agent whose transaction is `removed` is refused or immediately re-terminalized before any tool runs, and a background task belonging to an agent is killed at that agent's terminal event (reap processes, not just directories — `CLAUDE.md` already says this).
3. **The terminal record is written before any sweep and before any wait.** Reorder `terminalize-agent-worktrees.sh` so `claim_terminal` precedes `sweep_session`, bound every candidate's work by the remaining budget (pass the deadline into `reconcile()`, or skip a candidate whose tree exceeds a file-count ceiling), and make the hook say so on stderr when it ran out of time.
4. **`processes_using()` fails closed.** Any exception from `lsof` or `ps` returns a hold with the exception named, never an empty list.
5. **`_release_unattributable_lock()` is removed**, or it requires the owning *session* to be gone. A lock's content is not its holder.
6. **Every published number is the current output of the named script.** Replace 7/1114 (0.628%) with what `land-disposition-measure.py` prints at the commit that ships, in the docstring, the evidence pack and the round document; replace the §7 tautology with the registration-keyed count.
7. **§31 and the code say the same thing.** Either the reclaim lane's preview names every Codex workspace and every unregistered workspace under "not examined" (R5), or §31 is amended by the CEO to drop the "never absent from the report" clause and the refuted "facts on disk" half. Not both silently.
8. **The land-disposition notice does not go silent for a working day.** Either an intermediate rung (every N turns while owed, or a 4 h / 8 h bucket) or a written CEO decision that the 1 h → 24 h gap is acceptable.
9. **A hold carries an expiry or a re-ask.** `escalate.sh ack --disposition` for a land-disposition demand takes a `--until <date|condition>` and the demand re-opens when it passes; or the CEO rules that expired reasons are his problem to notice.

Items 1–5 are the certification. Items 6–9 are what "can't find any fuckshit anymore" means to me on this evidence; I would not certify with them open either, but they are cheaper.

## 6. Reproduction pointers

Scratch scripts (session scratchpad, not committed): `restarts.py` (D1), `rekey.py` (D2), `locks.py`/`unl1.py`/`term.py` (D3), `queue.py` (D1's trigger), `captures.py`/`envcheck.py` (D13). Everything in them is a read of `~/.claude/state/worktree-transactions/`, `~/.claude/state/worktree-ledger.jsonl`, `~/.claude/teams/session-d0eef867/*.jsonl`, the orchestrator transcript, and `git worktree list --porcelain`. Re-derivations: `python3 engine/scripts/land-disposition-measure.py` (D7); `python3 engine/scripts/reconcile-terminal-worktrees.py --preview | grep -ci codex` (D8); `bash engine/scripts/land-disposition.sh --root /Users/alex/ab/femcboost --session d0eef867-5636-46b7-a2bd-53dfd26564be` (D-OK-2).
