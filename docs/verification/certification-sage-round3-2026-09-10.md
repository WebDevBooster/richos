NOT CERTIFIED

# Certification review, round three — richos main `2b8a235d` — Sage, 2026-09-10

**Reviewer:** Sage (software architect), on Fable, by the CEO's order, round three. **Reviewed:** the
eleven commits `9956ab6a..2b8a235d` on richos main (24 files, +1,865/−151), the round-13 record
`docs/verification/reclaim-round-13-zach-fable-fix2-2026-09-10.md`, the decision table, the files my
round-two boundary said I had not read (`reconcile-terminal-worktrees.py` in full, `worktree-adoption.py`
in full, `escalations.py` in full, the reaper's per-worktree loop, CI), the live state of this machine
from 21:58 UTC, and the suites — run in the foreground, one per call, at this tip (section 5).
**Platform:** this session runs Claude Code 2.1.268 (`version` field of its transcript); every restart
on record was observed on 2.1.266–267. **Independence:** I read Frank's round-one and round-two verdicts
as instructed; I have not read, sought or received his round-three verdict.

The verdict is the first line. Nothing below softens it into a score.

---

## 1. Why it is not certified, in one paragraph

Round 13 closed everything both keys asked for in round two, and the live system produced the artifact
the fixer said only a reviewer could: the round-13 hooks took a real restart 57 seconds after main took
them (section 2, H1). It is not certified for three things I established from the outside, each
reproducible by the command beside it. **First, the table's own falsifier is still answerable:** a
**bare** repository under a disposable path component (`.cache/mirror.git`, `node_modules/x.git`) has no
trailing-slash entry and no `.git` component, so `never_disposable()` does not see it, every one of its
files is dropped without a copy, and non-force `git worktree remove` deletes it — reproduced under the
lane's binary with a commit that existed nowhere else (D1). It is the same class Frank R1 closed for
nested worktrees, one shape over. **Second, the engine's own CI refuses to certify the tip** — its
receipts step prints *"this run does NOT certify 2b8a235d"* — and one of the three red units is in this
area: `process-identity.test.sh` fails wherever no `claude` process is running, because adoption's T4
tier (landed today at 13:39Z) authorizes exactly the identities that suite asserts must never authorize;
it is green on this machine only because a session happens to be running (D2). **Third, the "second
source" row 5 now rests on is per-session and ephemeral:** the platform deleted
`~/.claude/teams/session-d0eef867/` with the session, taking every WorkerStarted row both keys read in
round two; 21 of the 27 sessions in the transaction store never had a team directory at all, so their
rows went to a fallback file the reader does not open; and the `--locks` measurement the table quotes
now re-derives to (b) 0 of 0 and (c) 0 with no line saying the corpus is gone (D3). None of the three is
a hole in the lane's safety argument for tracked work — the ancestor gate, the dirty-tree refusal and
the write barrier hold — but the first is a loss of work git does not hold, the second is the tip's own
verification saying no, and the third is a design document describing a substrate it does not have.

---

## 2. What held, and how I established each

**H1. The round-13 code acted on a real event, live, on the day it landed.** main took `cc/zach-fable-fix2`
at 21:36:17Z (`git -C /Users/alex/ab/richos reflog show main --date=iso` → `479aacd8 … 22:36:17 +0100`).
The fixer's own agent `zach-fable-fix2` (`a446bbe852076df83`, terminal 21:35:47Z) was restarted by the
platform at **21:37:14Z**; its transaction carries `after_terminal` `start 21:37:14.653Z` and
`stop 21:38:09.995Z` (`after_terminal_counts {start:1, stop:1}`), and the catch-up sweep at 21:37:49Z
journaled **both** members `deferred — RETRY, not a verdict: the platform started agent a446bbe8 again …
(the last observed lifecycle event, in the transaction or the platform's event log, is a start at
2026-09-10T21:37:14+00:00)` — the round-13 reason text, from `post_terminal_run_open`. Read from
`~/.claude/state/worktree-transactions/d0eef867-…/a446bbe852076df83.json` (appendix A1). That is the
thirteenth restart on record: `restart-after-terminal-measure.py` → **13 of 70** (18.571 %), up from the
record's 12 of 69; the thirteenth is the author of round 13.

**H2. After the session died, the lane decides the right thing for the restarted agents.** Session
`d0eef867` (pid 8799) is gone (`ps -p 8799` → nothing; `~/.claude/sessions/8799.json` absent; only
`84597.json`, this session, exists). For fix2, fix1 and sage-fable-cert2: `running_after_terminal` False,
`session_gone` True (*"recorded pid(s) 8799 gone or reused; no running registration"*), and every member
`assess()` → **remove** (native: session gone; hand-rolled: clean, integrated, unlocked, residue archived
first). The next pass reclaims `richos-wt/zach-fable-fix2`, `richos-wt/zach-opus-fix1` and
`richos-wt/sage-fable-cert2` — the residue class the CEO complained of, ended for these three by the
design (appendix A2).

**H3. My six round-two conditions are closed, verified in code and by suite.** D1: every "re-locks on
restart" sentence is withdrawn and rewritten UNMEASURED (`platform_lock_is_absent` docstring, the safety
block, the last-look comment, table §3), and the write barrier is named as the protection with its
mutant (G15, `guard-sealed-worktree.mutation.sh`, run: 18 of 18). D2: §31 is at every removal site by
name — `discard-workspace-backlog.validate` refuses before any row is accepted (three spellings + control,
suite run), `workspace-retire.termination_authority` refuses first, under the lock, on both routes
(S31, 53 passed / 420 assertions), `remove-agent-worktree.sh` refuses at its door, and
`reap-stale-worktrees.sh` gate S31 sits at line 1188 with **zero** mutating or removal commands between
the per-worktree loop head (line 1153) and it (appendix A6); reap S31 case run. D3: `residue_last_look`
re-lists and re-digests immediately before the `rm`; mutant `ignored-last-look-removed` killed. D4:
`terminalize(deadline=_DEADLINE)` (`_DEADLINE = _T0 + _BUDGET`, hook line 135) and
`reclaim_now(budget_deadline=, max_files=)`; test run. D5: `vendor` is off the list with the reason beside
it. D6: `worktree_removed_ts` and `removed_ts` in UTC on both routes.

**H4. Frank R1 is closed for the shape he found.** `never_disposable()` catches the trailing-slash entry
and any `.git` component; `_expand_residue` archives the nested repository whole; the suite restores the
archive and reads the commit back (`…nested_repository_under_a_disposable_path_is_ARCHIVED_whole…`);
mutant `nested-repository-dropped-as-disposable` killed. The reconciler's legacy capture lane prunes
disposables the same way (`build_manifest`, lines 168–199) and never erases (`unregister_member` /
`remove_member` raise `BlockedFailure`, lines 681–699) — confirmed by reading it in full.

**H5. Frank R2/R4 are closed as specified, for the case the substrate covers.** `post_terminal_events`
merges notes and the platform's rows keyed by the exact registration id and session; the live row
schema matches the reader (`agent_id`, `event`, `timestamp`, full `session_id`; appendix A3);
`session_gone` overrides row 5 at both call sites; the 3600 s bound names the operator and the exact
command, and the command works (test through the real CLI); hook case R40 drives a real repeat
`SubagentStop` and mutant `post-terminal-stop-unrecorded` is killed (run). What the substrate does not
cover is D3.

**H6. The reconcile mutation harness my round-two batch left killed at rc=143 is green at this tip:**
rc=0, 375 s, 30 of 30 mutants, run standalone in the foreground; the 59 test cases pass in 46 s.

**H7. The adoption tier removes nothing itself and reaches removal only through the lane** (read in
full): `adopt()` writes a sealed terminal transaction with `cleanup_policy: integrated-daily` and
`terminalize()` records ownership; G5 refuses a locked tree, G4 a claimed one, G7 merged against the
repository's own HEAD branch, G8 clean including untracked, G9 fails closed on an unreadable process
table; `rooting()` refuses a half-redirected sandbox before any candidate. But see D2 for T4.

**H8. `escalations.py`** (read in full): append-only ledger outside every repository, `ack --until`
requires a date and reopens on expiry with the disposition quoted, malformed lines are counted and
reported, and its suite proves nothing escapes to the operator's real ledger (case 17o). Sound, and not
part of any removal path.

---

## 3. Defects, most important first

Severity is mine. "Outside" = the live record or machine; "inside" = code or a scratch repository.

### D1 — SEVERE. A bare repository under a disposable component is dropped without a copy: the table's falsifier, answered again

**Claim under test.** Table §3: *"The claim above is true again without qualification, and the same
falsifier stands for the next reviewer: a path where a removal under `F = unknown` loses work git does
not hold."* `never_disposable()`: *"two things are never disposable, whatever their parent is called: a
nested repository (the trailing-slash entry), and any path carrying a `.git` component."*

**Established (inside), under the lane's own binary** (`completion-proof.GIT` =
`/Library/Developer/CommandLineTools/usr/bin/git`, `git version 2.50.1 (Apple Git-155)`, global config
nulled as `completion-proof.git()` does; scratch `bare_repro.py`, temp repository, deleted after):

```
push rc 0  -> bare HEAD 9b131a9a3cd5  objects present: True
ignored_files entries: ['.cache/mirror.git/HEAD', '.cache/mirror.git/config', ...] total 22
any trailing-slash entry: False
partition: dropped(keep)=22 residue=0
bare repo objects in residue (archived)? False
bare repo objects in keep (DROPPED, no copy)?  True
git worktree remove rc=0 stderr='' exists after=False
```

A bare repository has no working tree, so `git ls-files --others --ignored` lists its files one by one
(no trailing slash) and none of them carries a `.git` component (`.cache/mirror.git/objects/9b/…`). Every
file matches the disposable parent and goes to `keep`; nothing is archived; the non-force removal deletes
it. The commit `9b131a9a` existed nowhere else. The list's own bar — *"a build reproduces it from what is
committed"* — is not met by anybody's commits, which is the sentence round 13 used to close R1.

**How exotic.** `git clone --bare` / `--mirror` into an ignored cache or build directory is a vendoring
and mirroring pattern, not a fault injection; a `node_modules/<pkg>/.git`-less package that ships a bare
repository is rarer. Narrow, deterministic, and exactly the stated falsifier. **Fix:** treat a directory
holding `HEAD` and `objects/` and `refs/` (a bare repository) — or any path beneath one — as residue in
`partition_ignored()`, with a test that clones `--bare` under `node_modules/` and asserts the loose object
is in the archive, and a mutant. Alternatively archive disposables too under a size ceiling; that is a
design choice and not the minimum.

### D2 — SEVERE. The tip's own CI does not certify it, one red unit is this area, and that unit's verdict depends on which machine runs it

**Established (outside).** `gh run list --repo WebDevBooster/richos --branch main --workflow
engine-self-verify`: every run today from 09:07Z through the tip is `failure`; the run at `2b8a235d`
(id 34533162792) ends *"✗ ci-receipts: this run does NOT certify 2b8a235df52d032bb6214335670e1480c60fb1ab
— 3 unit(s) did not reach a green verdict: scripts/hooks/hook-staleness.test.sh FAIL (rc=1),
scripts/hooks/root-contract.test.sh FAIL (rc=1), scripts/lib/process-identity.test.sh FAIL (rc=1)"*.
The same three are red in every failed run back to at least 14:18Z (appendix A7). The round-13 record's
section 5 ("Suites run at this tip") is the placeholder sentence and nothing else.

**The one in this area.** `process-identity.test.sh` fails 21 assertions in CI, every one the same
shape: `AssertionError: 'T4' is not None : crash-recovery (no-session-alive): … no session is registered
to a running pid (0 registration(s) checked) and no claude process is in the table (152 rows scanned)`.
`worktree-adoption.owner_evidence()` returns tier **T4** for a path whose owner cannot be identified
whenever `no_session_alive()` is true — and on a CI runner it is always true. The suite was last changed
2026-09-06 (`git log -- engine/scripts/lib/process-identity.test.py`); T4 landed **today at 13:39Z**
(`git log -S"crash-recovery (no-session-alive)"` → `2e0242d8 2026-09-10 14:39:58 +0100`). So T4 is the
newer rule and it contradicts the invariants that suite documents by name:
`test_malformed_identity_cannot_prove_reuse`, `test_unknown_owner_vetoes_an_older_dead_owner`,
`test_missing_named_owner_cannot_borrow_an_old_owner_termination`,
`test_prepared_worktree_survives_repeated_reconciler_processes`. Nobody reconciled them.

**Reproduced locally (appendix A8).** On this machine the suite is green (12 OK) because a `claude`
process is running. With the CI runner's shape — `RICHOS_SESSION_PROCESSES=none` and an empty
`RICHOS_SESSIONS_DIR` — it fails **21** assertions, identically. The suite pins `RICHOS_ADOPTION_PROCESSES`
but not the session-process table, so its verdict is a fact about the machine, not the code. On the
operator's machine the nightly pass at 04:00 runs after the CEO's session has closed — which is the
CI runner's shape — and T4 then authorizes every registered, merged, clean, unlocked tree whose owner
cannot be identified. That is T4's stated design; it is also what these tests say must not happen, and
the record holds both without noticing.

The other two red units (`hook-staleness` case 11: `surfaces disagree: only-plugin=['guard-ci-red-lands.sh',
'session-start-ci-surface.sh']` — reproduced here, rc=1; `root-contract` — did not finish in 300 s on this
machine and was backgrounded; unverified) are outside my area and inside the tip. A fit-for-use
declaration on a commit whose own receipts refuse it is not one I will sign, whatever the cause.

### D3 — MODERATE. The second source is per-session and ephemeral, absent for most sessions, and the measurement it fed has silently lost its corpus

**Claim under test.** Table row 5: *"in the transaction's notes OR the platform's own event log"*;
`lifecycle_teams_dir()` docstring: *"The platform writes its own log of the same two events …
<teams>/session-<sid8>/worker-events.jsonl … read as a second source"*; table §3 (b)/(c) quoted as
`0 of 3` and `4`.

**Established (outside).**

- `~/.claude/teams/session-d0eef867/` **no longer exists**. The engine has no code that removes a team
  directory (`grep -rn "rmtree\|rm -rf" engine/scripts | grep -i team` → only the probe's own canary), the
  session process is gone, so the platform removed it at session end. With it went the event log both keys
  read in round two (fix1's `WorkerStarted 19:57:02.259Z`, the four 14:34:37Z rows). Ten team directories
  remain; only this session's carries a `config.json` and a live log (appendix A4).
- **21 of the 27 sessions in the transaction store have their `WorkerStarted`/`WorkerRunEnded` rows in
  `~/.claude/worker-events.jsonl`, the fallback file**, and exactly 1 (this session) has a team directory
  (appendix A5). `worker-ended-handoff.resolve_team_dir()` falls back when `session-<sid8>` does not exist;
  `platform_lifecycle_after()` opens only `session-<sid8>/worker-events.jsonl`. For those sessions the
  second source never existed — the fixer's attack item 2, measured: it is the common case on this machine,
  not an edge.
- **The measurement lost its evidence and does not say so.** `restart-after-terminal-measure.py` now prints
  `events 0` for all 13 restarts (the `starts/<id>.json` fact carries the count, correctly, and the footer
  says a session without a log "contributes only its start fact"). But `--locks` now prints
  `(a) 2 of 2 (this reviewer and the other key), (b) 0; 0 of them, (c) 0; 0 of them` — where the table
  quotes `(b) 0 of 3` and `(c) 4`. The four witnessed-unlocked restarts are still in the ownership ledger
  (`terminated … registered and unlocked` rows) and their later starts are still in `starts/<id>.json`;
  `--locks` joins only against event rows, finds none, and drops them from (c) with no "unobservable"
  line. The table's rule is *"A number that cannot be re-derived from its own command does not ship"*;
  (b) and (c) cannot be re-derived, and the re-run reads as if the case never happened.

**Why it is not a safety hole.** The flock contention the second source exists for happens only while a
session is alive, and while it is alive its team directory (when it has one) exists. After the session
ends, `session_gone` voids an open run (verified live, H2). So the design fails safe. **Why it is a
defect anyway:** the record describes a durable second source and has an ephemeral, minority one; the
round-13 document's *"the platform wrote both events down in its own log and nothing would read it"*
is true of 1 session in 27 today; and the measurement that anchors table §3 has quietly become
unreproducible. **Fix:** state the substrate in row 5, `lifecycle_teams_dir()` and the round-13 record
(per-session, deleted at session end, absent without a team directory — with the 21-of-27 count and its
command); make `--locks` report a witnessed-unlocked restart whose event log is gone as
*"unobservable — the session's event log no longer exists"* using the ledger witness and the start fact;
replace the quoted (b)/(c) with "observed 2026-09-10 on session d0eef867's log, since deleted" or the
current output; and either read the fallback file for a session with no team directory (keyed by the
full `session_id` the rows carry) or say in the row-5 text that such a session has one source.

### D4 — LOW. A suite in this area writes fixture rows into the operator's real event log

**Established (outside).** `~/.claude/worker-events.jsonl` holds **130** rows with `session_id`
`feedbeef…`, all `source_hook: SubagentStop`, written 13:20–16:30Z today, and `~/.claude/teams/
session-deadbeef/spawned-names.log` (25 KB, 20:53Z today). The writer is
`scripts/lib/finish-row-completion.test.sh` — the only suite that uses `feedbeef` and drives
`worker-ended-handoff.sh`, with no `HOME`/`WORKER_EVENTS_TEAMS_DIR` redirect (appendix A5). None of my
runs added rows (380 before and after). `escalations.test.sh` has the control this suite lacks (case 17o,
*"no fixture row reached the operator's REAL ledger"*). Not in round 13's diff; in the engine under
review, in the file family row 5 now reads from.

### D5 — LOW. The residue archive is unbounded, and now archives repositories whole

A nested repository under `node_modules/` is archived `.git` and all, hashed at archive time and again
at the last look, into `~/.claude/state/worktree-captures/` with no size ceiling; the in-event ceiling
counts tracked files only, so the nightly pass takes any size. Operational, not a loss; the fixer's
attack item 4, confirmed by reading `_expand_residue` and `residue_manifest`. State a ceiling or state
that there is none.

### D6 — LOW, record only. The merged-timeline window (attack item 1) is real, sub-second, and a disruption

`post_terminal_events` decides by the last event across both sources; a restart whose `WorkerStarted`
lands inside the hook-latency offset between a stop note and its event row (≈7 ms on fix1 in round two)
would read as closed. The smallest observed stop-to-restart gap is 1.3 s (`auto1`); the barrier refuses
the restarted agent every tool; the exposure is a cross-repository member removed under a barred agent.
Disruption by the table's claim, and I agree.

---

## 4. The fixer's six attack points, answered

1. **Merged ordering** — D6: real, sub-second, disruption only.
2. **Fallback path** — D3: 21 of 27 sessions; the common case, not the edge.
3. **Stale bound as a lever** — a hand on the record, written with `detail: operator` and the actor's
   command line; disruption only because of the barrier. Accepted.
4. **Archive size** — D5.
5. **§31 classifier** — the ruling's own text names exactly two shapes, the `codex/` prefix and
   `~/.codex/worktrees/`, and the classifier implements those two; a custom `CODEX_HOME` is outside the
   ruling as written. A boundary, not a defect.
6. **`residue_last_look` cost** — bounded by the same residue set and the disposable exclusion; a hook
   killed inside it removes nothing (the `.tmp` archive is unlinked on the next run). Accepted.

---

## 5. What I examined and what I did not — including the suites, run

**Examined in full:** the whole round-13 diff (24 files); `reconcile-terminal-worktrees.py` (1,473 lines);
`worktree-adoption.py` (876); `escalations.py` (745); `daily-workspace-cleanup.py` and
`worktree-transactions.py` diffs with the surrounding functions; `terminalize-agent-worktrees.sh`,
`record-subagent-start.sh`, `worker-started-handoff.sh` / `worker-ended-handoff.sh` (row schema and
team-dir resolution); `discard-workspace-backlog.py`, `workspace-retire.py` (`termination_authority`,
`excluded_by_ceo_ruling`), `remove-agent-worktree.sh` (door), `reap-stale-worktrees.sh` (loop head to
gate S31, `--execute` routing); `restart-after-terminal-measure.py` (`--locks`); the decision table; the
round-13 record; `hooks.json` registrations and order; `ceo-decisions.md` §31; the CI workflow and the
receipts of the run at the tip; the suite diffs.

**Live record examined:** the transaction store (104 terminal, 70 workspace-owning), the ownership
ledger, all three surviving `worker-events.jsonl` plus the fallback file (380 rows), the teams directory,
the sessions registry, the process table, fix1/fix2/sage-cert2 transactions and journals, richos `main`
reflog, CI run history and logs.

**Not examined:** `worktree-ledger.py` beyond `claude_processes`/`no_session_alive`; the
`managed-workspace-*` and `shell-worktree-sparse` lanes; `guard-resume-isolation.sh` (unchanged);
`hook-staleness` and `root-contract` beyond running them; whether Claude Code documents team-directory
deletion at session end (established from the machine, not from a document); the 190-odd suites outside
the list below. I spawned nothing and mutated no live workspace, ledger, transaction store or registry;
the two scratch experiments ran in temporary repositories they created and deleted.

### 5a. Suites — run at `2b8a235d`, foreground, one per call, output captured

| Suite | rc | wall | Note |
|---|---|---|---|
| `daily-workspace-cleanup.test.sh` (+ 28 mutants) | 0 | 401 s | incl. `nested-repository-dropped-as-disposable`, `second-source-ignored`, `session-death-does-not-void-an-open-run`, `stale-hold-never-names-a-person`, `ignored-last-look-removed` |
| `lib/worktree-transactions.test.sh` (+ 25 mutants) | 0 | 120 s | |
| `hooks/terminalize-agent-worktrees.test.sh` (+ 15 mutants) | 0 | 167 s | R40/R41; `post-terminal-stop-unrecorded` killed |
| `reconcile-terminal-worktrees.mutation.sh` (standalone) | 0 | 375 s | 30 of 30 — the harness left killed at rc=143 in round two |
| `reconcile-terminal-worktrees.test.sh` (59 cases; scratch copy with the mutation chain removed so it fits one call) | 0 | 46 s | |
| `lib/worktree-adoption.test.sh` (+ 15 mutants) | 0 | 63 s | |
| `lib/completion-proof.test.sh` (25) | 0 | 6 s | |
| `hooks/session-start-reap-worktrees.test.sh` (+ 5 mutants) | 0 | 22 s | |
| `restart-after-terminal-measure.test.sh` (9) | 0 | <1 s | new this round |
| `hooks/record-subagent-start.test.sh` (+ 6 mutants) | 0 | 7 s | |
| `discard-workspace-backlog.test.py` (10) | 0 | 2 s | |
| `lib/worktree-ledger.test.sh` (+ 8 mutants) | 0 | 12 s | CI lists it KNOWN-RED-BUT-PASSED |
| `hooks/guard-sealed-worktree.test.sh` (+ 18 mutants) | 0 | 76 s | G15 `terminal-not-refused` |
| `lib/workspace-retire.test.sh` (53 + safety) | 0 | 139 s | S31 |
| `hooks/land-disposition.test.sh` (33) | 0 | 4 s | |
| `hooks/escalations.test.sh` (79) | 0 | 6 s | |
| `reap-stale-worktrees.test.sh` (54 + 6 mutants) | 0 | 333 s | S31 |
| `lib/process-identity.test.sh` — this machine | 0 | 3 s | green because a `claude` process is running |
| `lib/process-identity.test.sh` — CI shape (`RICHOS_SESSION_PROCESSES=none`, empty sessions dir) | **1** | 3 s | **21 failures**, all `'T4' is not None` |
| `hooks/hook-staleness.test.sh` | **1** | 4 s | case 11 red, same as CI |
| `hooks/root-contract.test.sh` | — | >300 s | did not finish inside the call; backgrounded by the harness; **unverified** |

Every rc is from a process I ran and whose log I read (`scratchpad/suites/*.log`); the results file
`certification-sage-round3-suite-results.txt` beside this document was appended after each run and
committed. A killed or unfinished run is recorded as such, never as a pass.

---

## 6. What would have to be true for me to certify

Each stated so an engineer can act without asking me. All of them.

1. **D1.** `partition_ignored()` never drops a git object store: a directory containing `HEAD`,
   `objects/` and `refs/` (a bare repository), and every path beneath it, is residue whatever its parent
   is called; a test clones `--bare` under an ignored `node_modules/` (or `.cache/`), pushes a commit
   that exists nowhere else, and asserts the loose object is in the archive and restorable; a mutant
   turns it red. The table's falsifier sentence stays as it is.
2. **D2.** The commit that ships carries a green `engine-self-verify` run whose receipts certify its SHA.
   For `process-identity.test.sh`: the T4-versus-identity contradiction is decided on the record — either
   T4 never authorizes an owner whose identity is malformed or unknown (the suite's invariants stand and
   T4 narrows to "identified session, provably gone"), or the suite is rewritten to T4's rule with the
   CEO's 2026-09-03 "a sweep never decides liveness" ruling cited as satisfied by a kernel fact — and the
   suite pins `RICHOS_SESSION_PROCESSES` and `RICHOS_SESSIONS_DIR` so its verdict is the same on every
   machine. `hook-staleness` case 11 and `root-contract` green or explained in the same run.
3. **D3.** Row 5, `lifecycle_teams_dir()` and the round-13 record state the substrate truthfully:
   per-session, deleted at session end, absent for sessions without a team directory (21 of 27 here,
   with the command). `--locks` reports a witnessed-unlocked restart whose event log is gone as
   unobservable, from the ledger witness and the start fact, instead of dropping it. The quoted (b)/(c)
   are replaced by the current output or dated as no-longer-reproducible. Either the reader opens the
   fallback file for a session with no team directory, or the row-5 text says such a session has one
   source.
4. **D4.** `finish-row-completion.test.sh` redirects the event log (`WORKER_EVENTS_TEAMS_DIR` and `HOME`)
   and asserts, as `escalations.test.sh` 17o does, that no fixture row reached the operator's real file;
   the 130 `feedbeef` rows and `session-deadbeef/` are the operator's to remove.
5. **Section 5 of the round-13 record** is filled from real runs at the shipping commit, with rc and
   wall time, or deleted.

D5 and D6 are not conditions of my key.

---

## Appendix A — how each number was produced

All on this machine, 2026-09-10 from 21:58 UTC, in `/Users/alex/ab/richos-wt/sage-fable-cert3` at
`2b8a235d`. Scratch scripts are in the session scratchpad and are described so they can be rewritten.

**A1. fix2's transaction.** `python3 engine/scripts/lib/worktree-transactions.py post-terminal
--session-id d0eef867-5636-46b7-a2bd-53dfd26564be --agent-id a446bbe852076df83` → two rows, both
`notes`, exit 1 (no run open); the JSON's `after_terminal`, `after_terminal_counts` and each member's
`immediate_reclaim_history` (five entries: lock held 21:35:49, **row 5 two-source reason 21:37:49**,
lock held 21:38:10 / 21:38:12 / 21:45:04). Reflog: `git -C /Users/alex/ab/richos reflog show main
--date=iso | head -4`.

**A2. The lane after session death.** A reader calling `tx.post_terminal_events`,
`daily.session_gone`, `daily.post_terminal_run_open` and `daily.assess` on the three transactions
(scratch `live_lane.py`); `ps -p 8799`; `ls ~/.claude/sessions/`.

**A3. Row schema, live.** Keys of a `WorkerStarted` row in `~/.claude/teams/session-b7869424/
worker-events.jsonl`: `agent_id, agent_type, cwd, decision, event, host_pid, lifecycle_state,
session_id, source_hook, timestamp`; `WorkerRunEnded` adds `agent_transcript_path, stop_hook_active`.
This session: 2 `WorkerStarted` (both registration ids, mine at 21:58:03.661Z), 16 `WorkerRunEnded`
(all per-run ids), **0 repeats** — no restart observed on 2.1.268 yet.

**A4. Teams directory.** `ls ~/.claude/teams/` → ten `session-*` directories, none `d0eef867`;
`grep -rn "rmtree\|rm -rf" engine/scripts --include=*.py --include=*.sh | grep -i team` → the probe's
canary only. Measure: `python3 engine/scripts/restart-after-terminal-measure.py` → 104 / 70 / **13**
(18.571 %), `events 0` on every row, "event logs scanned: 3"; `--locks` → (a) 2 of 2 (−38.8 ms,
−45.8 ms), (b) 0 of 0, (c) 0.

**A5. Fallback file.** `~/.claude/worker-events.jsonl`: 380 rows, 2026-08-29 → 2026-09-10T16:38Z.
Join against the transaction store's session ids (scratch `fallback_overlap.py`): 27 sessions; **21**
have lifecycle rows only in the fallback; **1** has a team directory; 5 have neither. Fixture rows:
`feedbeef` 130 (13:20–16:30Z, all `SubagentStop`), `abcd1234` 12 (2026-08-29). Writer:
`grep -rl feedbeef engine/scripts | xargs grep -l "worker-ended-handoff\|SubagentStop"` →
`scripts/lib/finish-row-completion.test.sh`, `grep -c 'HOME=' → 0`.

**A6. Reaper ordering.** Python over `reap-stale-worktrees.sh`: loop head line 1153
(`for i in $(seq 0 …WT_PATH…)`), gate S31 comment line 1188, **0** non-comment lines matching
`worktree remove|prune|unlock|branch -[dD]|update-ref|rm -r|mv |remove-agent-worktree|workspace-retire`
between them; `remove-agent-worktree.sh` is invoked only via `REMOVER_SH` (line 994) later in the loop.

**A7. CI.** `gh run list --repo WebDevBooster/richos --branch main --workflow engine-self-verify
--limit 16 --json databaseId,headSha,conclusion,createdAt` → 16 of 16 `failure` (09:07Z–21:37Z);
`gh run view 34533162792 --log-failed` → the receipts line quoted in D2; per-run red units for the nine
newest failures: `hook-staleness`, `root-contract`, `process-identity` in every one (plus
`contract-integrity:WTI` in three earlier ones). Jobs at the tip: shards 6, 8, 9 and `coverage` failed;
nine shards, `plan`, `non-suite-steps`, `affected-coverage` succeeded.

**A8. process-identity, two shapes.** `bash engine/scripts/lib/process-identity.test.sh` → `Ran 12
tests … OK`; `RICHOS_SESSION_PROCESSES=none RICHOS_SESSIONS_DIR=<empty> bash …` → `FAILED
(failures=21)`: 9× `test_malformed_identity_cannot_prove_reuse`, 5×
`test_missing_named_owner_cannot_borrow_an_old_owner_termination`, 2×
`test_missing_session_id_does_not_hide_live_or_unknown_ownership`, 2×
`test_pidless_path_considers_every_resumed_session_incarnation`, 1× each
`test_direct_old_pid_cannot_hide_a_resumed_session_elsewhere`,
`test_prepared_worktree_survives_repeated_reconciler_processes`,
`test_unknown_owner_vetoes_an_older_dead_owner`. Dates: `git log -3 --format="%h %ci" --
engine/scripts/lib/process-identity.test.py` → newest `521f4665 2026-09-06 22:53`;
`git log -S"crash-recovery (no-session-alive)" -- engine/scripts/lib/worktree-adoption.py | tail -1`
→ `2e0242d8 2026-09-10 14:39:58 +0100`.

**A9. The bare-repository repro** (D1): scratch `bare_repro.py` — a temp repository with a linked
worktree, `.cache/` ignored via `info/exclude`, `git init --bare .cache/mirror.git`, a commit pushed
into it from a throwaway clone that is then deleted, `daily.ignored_files` / `daily.partition_ignored`
/ `daily.disposable_paths` called directly, then `git worktree remove -- <work>` under the lane's binary
with `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null`. Output quoted in D1. Temp tree removed.
