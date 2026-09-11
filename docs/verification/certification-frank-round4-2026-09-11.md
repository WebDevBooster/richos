DRAFT — no verdict yet

# Certification review, round four, Frank — workspace reclamation at richos main `2d2f6cf1`

**Reviewed at:** richos main `2d2f6cf160957614f5344216644e003348e0b2a1` — the thirteen commits of `cc/zach-fable-fix3` (round 14) on top of the round-three tip `2b8a235d` I certified; `git log --oneline 2b8a235d..2d2f6cf1 --no-merges`, 61 files, +3,972/−498 · **Date:** 2026-09-11, 00:40Z–02:00Z · **Reviewer:** Frank (Fable), one of two independent keys · **Independence:** I did not coordinate with Sage and did not read any round-four document of theirs. I read every earlier verdict of both keys (rounds one to three) as the brief instructed.
**Platform:** Claude Code 2.1.268; session `b7869424`, pid 84597 (`ps -p 84597` → started Thu 10 Sep 22:49:44 2026).
**Method:** read every line of the round-14 engine diff (`worktree-ledger.py`, `daily-workspace-cleanup.py`, `worktree-transactions.py`, `worktree-adoption.py`, `workspace-retire.py`, `remove-agent-worktree.sh`, `land-completeness.py/.sh`, `land-residue-gate.py`, `restart-after-terminal-measure.py`, the three mutation harnesses, `session-start-stdin.test.sh`, the config and the decision table); read the round-14 record as a claim and re-derived each number I relied on; read the live record from the outside (transaction store, ownership ledger, teams directories, the fallback event log, the worktree registries); ran the lane's read-only verbs at this tip; ran five scratch experiments in sandboxes and temporary repositories that touched no live path; and ran the area's suites in the foreground, one per call, with logs beside this file (§5). Every number carries the command that produced it or the word `unverified:`.

## 1. The verdict in one paragraph

My round-three certification does not survive the change. The fixer closed what both keys asked for — the bare-repository loss (D1), the T4 tier, the CI-shape pin, the second source's stated lifetime and the fallback reader, the fixture-row leaks, the residue byte ceiling, the remover's text, the stdin suite split — and every suite in this area is green here (§5). It is not certified because of the one change the brief flagged as riskiest, O2, and what its first live use did. **Step 2b writes a permanent `terminated` row into the ownership ledger on the strength of the transaction record, and step 1 of the same judge then reads that row ahead of the native lock and ahead of row 5, forever** — proven in a sandbox (§2.D1: one judge call with write on, then a post-terminal start, and the verdict L06c promises as INDETERMINATE comes back NOT-ALIVE "witnessed termination"). **It has already happened on the operator's real ledger:** at `2026-09-11T00:02:34.98Z`, thirty-four minutes before the code reached main, a row `witness: platform-terminal-record` was written for `sage-fable-cert3` (agent `ae904aac1949e5696`) while that agent's native shell was, and still is, **LOCKED by running pid 84597** — the reconciler preview at this tip HOLDs both of Sage's workspaces on that lock, and the judge at this tip says NOT-ALIVE for the same registration. Two authorities, two readings of one record: the defect O2 was written to end, reproduced by O2 on its author's machine. **The writer was round 14's own new suite**, `session-start-stdin.test.sh`, which runs the real SessionStart reaper against the real ledger and the real richos registry with a sandbox entity in which no shell can exist (§2.D2) — I reproduced the write twice against a copy of the ledger, once through the hook and once through the whole suite. That is Sage's D4 class, in a suite created the day D4 was closed, and it violated the fixer's own brief. Beside it: O2 does not decide its own motivating case on the real ledger, because every helper-made tree carries an aid-less `prepared` row that outranks 2b while the session lives (§2.D3); the fallback reader misses the writer's single-team-directory branch (§2.D4); and the record's sentence about Echo is false (§2.D5). No bytes are at risk from any of it today — the operator door quarantines rather than deletes, the reclaim lane never reads `terminated` rows, and the aid-less row happens to hold the aggregate at INDETERMINATE — but the CEO's bar is not "no bytes lost"; it is "can't find any fuckshit anymore", and a false witness on his record, written by the fix's own test, made permanent by the fix's own design, is exactly that. §6 says what would change my answer.

## 2. Defects, most important first

Severity is mine. "Outside" = the live record or machine; "inside" = code or a sandbox.

### D1 — SEVERE. O2 persists a `terminated` row from the record, and the judge reads it ahead of the lock and ahead of row 5, permanently

**Claim under test** (`worktree-ledger.py` step 2b comment, round 14): *"Reached only when the native shell is absent or unregistered: a held lock (ALIVE, or INDETERMINATE with no pid) has already returned above, and the lock outranks the record."* And `platform_terminal_record()`: *"a door reading it authorizes nothing the lane would not."*

**Established (inside).** `_judge_registration()` order: step 1 `terminations(records, aid)` → NOT-ALIVE and return; step 2 the lock; step 2b the record — and 2b, when `write` is on, appends `{"event": "terminated", "witness": "platform-terminal-record"}`. `write` is on by default for the CLI `judge` and for `judge-batch`, which the reaper calls at every session start (`reap-stale-worktrees.sh:966`, no `--no-write`). So the first time 2b decides a path, the ledger gains a row that step 1 returns on for that agent id on every later call, whatever the lock says and whatever row 5 says. Sandbox (`scratch-o2-persist.txt`, its own ledger and transaction store):

```
1. judge, write OFF (the L06b shape):        NOT-ALIVE  platform terminal record: ...
2. judge, write ON (the CLI default):         NOT-ALIVE  ... terminated rows now in the sandbox ledger: 1   witness: platform-terminal-record
3. the platform starts the agent AGAIN (start note, no stop) -- L06c says INDETERMINATE:
                                              NOT-ALIVE  witnessed termination on record for agent live001 ...
4. control: the same state with the terminated row removed:
                                              INDETERMINATE  RETRY, not a verdict: the platform started agent live001 again ...
```

L06c's property does not survive one write. The reclaim lane's row 5 is re-read on every pass because the transaction is re-read; the judge's step 1 is a row nothing voids — the record's Type J, in the one judge "every door consults".

**Established (outside), at this tip.** The operator's ledger holds exactly one such row (`scratchpad/ledger-rows.py`; `grep -c '"witness": "platform-terminal-record"' ~/.claude/state/worktree-ledger.jsonl` → 1):

```
2026-09-11T00:02:34.984941+00:00  terminated  ae904aac1949e5696  sage-fable-cert3  /Users/alex/ab/richos-wt/sage-fable-cert3  witness=platform-terminal-record
```

main took `cc/zach-fable-fix3` at 00:36:08Z (`gh run list` → the push-triggered run's `createdAt`). At the moment of the write, and now: `cat /Users/alex/ab/femcboost/.git/worktrees/agent-ae904aac1949e5696/locked` → `claude agent agent-ae904aac1949e5696 (pid 84597 start Thu Sep 10 21:49:44 2026)`, pid running; `reconcile-terminal-worktrees.py --preview` at this tip (`preview-at-2d2f6cf1.txt`) → `hold /Users/alex/ab/richos-wt/sage-fable-cert3 — native owner is live or unknown: isolation worktree ... is LOCKED and the locking pid 84597 is running`. The judge at this tip, read-only, for the registration carrying that agent id, under the CORRECT entity (femcboost, where the shell is locked):

```
reg event=registered agent='ae904aac1949e5696' -> NOT-ALIVE :: witnessed termination on record for agent ae904aac1949e5696 (sage-fable-cert3): the platform's own terminal record ...
```

The lock is held by a running pid; the judge says witnessed termination. Sage's run did in fact end at 22:56:08Z, so the row's *content* was true when written; what is false is the witness — a termination nobody witnessed, written while the platform held the shell — and what is dangerous is its rank: if the platform ran Sage again now (the door is real: 14 of 74 terminal owners on this machine, `restart-after-terminal-measure.py`), the start note would open row 5 and the judge would still answer NOT-ALIVE from step 1. Today the aggregate for that path is INDETERMINATE only because of D3's aid-less row.

**Why it is not a loss path today:** the operator door (`workspace-retire`) preserves and renames, never erases; `land-completeness` and the residue gate print; the reclaim lane consults no `terminated` row (`grep -n terminated daily-workspace-cleanup.py` → comments only); the write barrier refuses a restarted terminal agent every tool (G15 green here). **Why it is a defect anyway:** the ledger is the record the CEO's screen is built from, `witness` is the field the design's whole argument turns on ("NOT-ALIVE only on positive evidence"), and O2 made a row of positive-evidence rank out of a fact the same code admits can be followed by a restart. **Fix:** 2b never appends; `platform_terminal_record` is cheap and is re-read every time (as the lane re-reads its transaction). If a persisted witness is wanted for the CEO's screen, it must carry a kind step 1 does not return on, or step 1 must skip `witness: platform-terminal-record` rows and re-run 2b. And the entity join `_entities_for` documents in `land-completeness.py` (a cross-repository tree's lock lives in the owner's SESSION repository) belongs inside `_judge_registration`, so a call with the tree's own repository as entity — the documented, observed misuse — cannot reach 2b while a shell is locked elsewhere.

### D2 — SEVERE. The round's new suite writes into the operator's real ledger, and with O2 the write is a false witness

**Claim under test:** the fixer's brief and record — *"Do not ... change any live workspace, ledger, transaction store or registry"*; round-14 record §7: thirty-one suite runs at the final commit, each in its own sandbox.

**Established (outside).** The one `platform-terminal-record` row (D1) is timed `00:02:34.98Z`. The fixer's `RESULTS.tsv` (copied into `reclaim-round-14-suite-results.txt`): `session-start-stdin.test.sh rc=0 wall=41s 2026-09-11T00:03:09Z` — the run began at 00:02:28Z. The fixer's transcript carries no tool call naming `judge`, `reap-stale`, `remove-agent-worktree`, `workspace-retire` or `land-completeness` between 00:00Z and 00:05Z (`subagents/agent-ac47dedc61b0044b2.jsonl`, filtered).

**Established (inside).** `session-start-stdin.test.sh` line 50 unsets `CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT` and nothing else; `HOME` is never moved; case 9b runs `session-start-reap-worktrees.sh` with `CLAUDE_PROJECT_DIR=$SESSREPO` (a sandbox repository that HAS an `orchestration.config`, so the inventory runs). The hook runs the reaper in dry-run; the reaper reads `WT_LEDGER=$HOME/.claude/state/worktree-ledger.jsonl` (line 706) and discovers repositories through `TEAM_DIR_BASE=$HOME/.claude/teams/*/inflight-repos.txt` (lines 576–599) — the operator's real richos registry — then judges every hand-rolled tree in `judge-batch --entity $ENTITY_ROOT` with write ON. Under a sandbox entity no native shell exists, so step 2 falls through and 2b decides.

**Reproduced, twice, against a copy — the real ledger's `terminated` count stayed 46 throughout** (`scratch-repro-9b.txt`, `scratch-stdin-suite-redirected.txt`):

```
ARM 1 (ledger copy WITHOUT the 00:02:34Z row, as when the fixer's suite ran): terminated rows before=45 after=46
   NEW ROW: 2026-09-11T00:59:33Z platform-terminal-record ae904aac1949e5696 /Users/alex/ab/richos-wt/sage-fable-cert3
ARM 2 (ledger copy WITH the row, as today):                                   before=46 after=46
session-start-stdin.test.sh with REAP_WORKTREE_LEDGER=<copy without the row>: rc=0, all 11 passed;
   copy terminated rows before: 45  after: 46  — the same row, written by the suite.
```

So the suite that round 14 created to make the restart door un-trippable trips a different door: it exercises the shipped reaper against the shipped machine. Before O2 the same run would have written nothing for a cross-repository tree (step 3 → INDETERMINATE, no append); O2 gave it something to write. `root-contract.test.sh` carried section 9 before the split and has the same shape; every reviewer who ran it since 2026-09-10 ran the real reaper against the real ledger, which is why I ran both suites with `REAP_WORKTREE_LEDGER` redirected (§5) and record here that **they cannot be run as shipped without mutating the operator's record.** This is Sage D4's class — a suite writing fixture-shaped rows into the real record — fixed for two suites in this very round (`finish-row-completion`, `detect-nonnative-worktree`, each now with a both-arms control) and reopened by the third. **Fix:** the suite redirects `HOME` (or at least `REAP_WORKTREE_LEDGER`, `REAP_TEAM_DIR`, `RICHOS_WORKTREE_LEDGER`) and asserts both arms as 17o/F16/L2 do; and because this is the third instance of the class in two days, a canary over `~/.claude/state/worktree-ledger.jsonl` and `~/.claude/worker-events.jsonl` in the suite runner (the escalations suite's 17n/17o shape) so the class is closed, not the instance. The false row itself is on the operator's ledger and is Rich's to deal with — but the engine must be able to express its retraction (D1).

### D3 — MODERATE. O2 does not decide its own motivating case on the real ledger

**Claim under test:** `platform_terminal_record()` docstring — Frank's round-three tree was *"INDETERMINATE by step 3 ... refused by the operator door at 22:57:02Z"*, and O2 makes the judge read the record so *"every finished cross-repository reviewer"* stops sitting as a live row until session end.

**Established (outside), read-only, at this tip.** Every tree `create-teammate-worktree.sh` makes carries TWO ownership rows: a `prepared` row with **no agent id** (written before the spawn) and a `registered` row with the id (written by `detect-nonnative-worktree.sh` after it) — `scratchpad/ledger-rows.py` lists both for all six round-three and round-four trees. `judge()` judges every registration and lets INDETERMINATE outrank NOT-ALIVE. The aid-less row has no aid, so steps 1, 2 and 2b are skipped and step 3 answers "session pid 84597 is still running → INDETERMINATE". For the exact tree the docstring names, and the two like it:

```
/Users/alex/ab/richos-wt/frank-fable-cert3   prepared agent=None -> INDETERMINATE | registered a522d0a7 -> NOT-ALIVE (2b) | AGGREGATE INDETERMINATE  (both entities)
/Users/alex/ab/richos-wt/echo-opus-ci1       prepared agent=None -> INDETERMINATE | registered a2187141 -> NOT-ALIVE (2b) | AGGREGATE INDETERMINATE  (both entities)
/Users/alex/ab/richos-wt/sage-fable-cert3    prepared agent=None -> INDETERMINATE | registered ae904aac -> NOT-ALIVE (step 1, D1) | AGGREGATE INDETERMINATE
```

`land-completeness.sh --repo /Users/alex/ab/richos` at this tip (`land-completeness-richos.txt`) shows the consequence on the CEO's screen: `sage-fable-cert3 ... owner INDETERMINATE — 2 registrations match (ledger); no native isolation worktree is registered for agent ? (sage-fable-cert3) while its session pid 84597 is still running`. The operator door would refuse Frank-cert3 today exactly as it did at 22:57Z. The tests that prove O2 — L06a–L06d and `workspace-retire` F1c′ — each register ONE row carrying the agent id; none has the two-row shape every real tree has. So O2's claimed effect is unproven on real data and false on the three real trees I checked. It is safe in the direction it fails (the aid-less row is what keeps D1 from reaching the door), which is the same accident-as-protection shape Sage named in round one. **Fix:** decide it on the record — either the aid-less `prepared` row is joined to the aid (same session, same teammate, the engine's own writer, the join `bind_late_members` already trusts) so 2b decides the path, or O2's docstring says the operator door stays INDETERMINATE until session end for helper-made trees and the "two authorities" sentence is withdrawn. Either way a test with both rows.

### D4 — LOW. The fallback reader misses the writer's single-team-directory branch

**Claim under test:** D3/F1 fix — *"the fallback file is now READ, keyed by full session id"*; *"the second source is true for 31 sessions instead of 3."*

**Established (inside).** `worker-started-handoff.sh` / `worker-ended-handoff.sh` `resolve_team_dir()`: when `session-<sid8>` does not exist and EXACTLY ONE `session-*` directory exists under the teams directory, the row is written into THAT directory — another session's log; only with 0 or ≥2 directories does it fall to `~/.claude/worker-events.jsonl`. `platform_lifecycle_after()` opens `session-<sid8>/` and the fallback, never a foreign directory. Sandbox (`scratch-one-teamdir.txt`): one foreign directory present → the row lands in `session-aaaaaaaa/worker-events.jsonl`, the reader returns `[]`; two directories present → fallback file, the reader returns the row. **Established (outside):** 0 foreign rows in any of the 9 team directories on this machine today (`own 254, FOREIGN 0`), so no live instance; the state recurs whenever the teams directory is down to one entry. Same failure direction as before D3 (one source; safe). **Fix:** either the writer never files into a foreign session's directory, or the reader scans every `session-*/worker-events.jsonl` filtered by the full session id; both arms tested.

### D5 — LOW, record. The round-14 record's sentence about Echo is false

Record §4: echo-opus-ci1's transaction *"is sealed but carries no terminal record though a SubagentStop finish row exists at 23:49:01Z"*. The transaction (`~/.claude/state/worktree-transactions/b7869424-…/a2187141d264f4da9.json`) carries `terminal: {ingress: SubagentStop, ts: 2026-09-10T23:49:01.889703Z}`, and its cross-repository member is `removed`, `removed_ts 2026-09-10T23:50:26Z` — the lane took it eighty-five seconds after the stop. The question the record handed the next reviewer was already answered by the record it was read from.

### D6 — LOW, boundary. Two more answers to the fixer's "fourth shape" question

`scratch-d1edge.txt`, against the real module, under the lane's binary, temporary repository deleted after:

- **HEAD as a symlink** (`HEAD -> refs/heads/master`; git opens it, `rev-parse HEAD` rc=0): `git_store_roots` requires a regular HEAD, so the store is not collapsed; `refs/` and `packed-refs` are dropped, the objects survive by clause (ii). The commits' names are lost, the bytes are not (recoverable by `fsck --lost-found`).
- **`objects/` as a symlink to a sibling under the same disposable parent** (git opens it): the store IS collapsed, the archive holds `objects` as a symlink entry (`residue_manifest` records links, by design), and the real object files under `.cache/objs-elsewhere/` are DROPPED — `real object files DROPPED? True`. A store git recognizes, whose commits are on disk under the worktree, archived as a dangling link.
- A `git bundle` under `build/` is dropped (a pack with a header; a transport artifact).

The SHA-256 layout is handled (`{38,62}`), with and without HEAD. None of the three is a shape anyone on this project has produced; I state them because the fixer asked, and they are not conditions of my key.

### D7 — LOW, record hygiene. Four operator-retired members hold forever in the preview

The four hand-rolled members Rich retired on 2026-09-10 at 22:53–22:55Z (`richos-wt/.richos-retired/*`) read `hold — removed workspace has no retained completion proof` in the preview at this tip and will on every nightly pass: the lane sees an absent path with no proof it never wrote. `land-completeness` now decides them (`quarantined 4`, O1); the reconciler's report does not. Pre-existing consequence of the O1 route, not of round 14.

## 3. What held — re-derived by something that did not make it

- **D1 (bare repository).** `git_store_roots` collapses `HEAD`+`objects/`+`refs/` into one trailing-slash entry; `looks_like_git_object` refuses loose objects and packs by layout; `never_disposable` has three clauses. `test_a_BARE_repository_under_a_disposable_path_is_ARCHIVED_whole_never_dropped` PASS; mutants `bare-repository-dropped-as-disposable`, `git-object-bytes-disposable` killed (33 of 33, §5). My own edge run: a bare SHA-256 store under `node_modules/` collapsed and archived; with HEAD removed, its 64-hex object kept by clause (ii). The quarantine route (`workspace-retire`) prunes nothing (`grep -n disposable workspace-retire.py` → none), so D1's class does not reach that door.
- **T4 retired, nothing lost.** `no_session_alive` has no caller (`grep -rn no_session_alive engine/scripts` → the tombstone comment only); `owner_evidence` returns RETAIN with the reason naming the missing identity; T1/T2 untouched; A70/A71/A71b + `t4-resurrected`, `no-record-is-not-refused` — adoption 43 + 15/15 here. `process-identity.test.sh` pins `RICHOS_SESSION_PROCESSES=none` and an empty `RICHOS_SESSIONS_DIR` itself: 12 OK on this machine AND 12 OK with the CI shape forced from the environment (§5). The fixer's "0 T4-shaped sessions" count I did not re-derive (`unverified:`); the retirement is conservative regardless.
- **D5/F2 (residue byte ceiling).** `residue_bytes` sizes by `os.lstat` after `partition_ignored` + `_expand_residue`, `None` defers; checked in `reclaim_now` (from `_reclaim_in_event`) and in `sweep_session` before a candidate starts; the nightly `reconcile()` passes no ceiling; `IMMEDIATE_RECLAIM_RESIDUE_MAX_BYTES=268435456` with the reasoning beside it; both mutants killed. My F2 is closed.
- **D3/F1 (substrate).** Stated in `lifecycle_teams_dir`, `post_terminal_run_open`, row 5 and the table's §3; the fallback read with the full-session-id join; `--locks` line (c) from the ledger witness and the start fact (`(c) 4 ... known only from the start fact (event log gone) for 4 of them` at this tip, `measure-locks.txt`) with the CORPUS LIFETIME footer. My F1 is closed except for D4 above.
- **D4 (fixture rows).** `finish-row-completion.test.sh` 16 + 5/5 (F15/F16), `detect-nonnative-worktree.test.sh` + 7/7 (L1/L2); the operator's record is clean of them (`grep -c feedbeef ~/.claude/worker-events.jsonl` → 0, 250 rows; `ls ~/.claude/teams` → no `session-deadbeef`). Closed for the two named suites; the class is not (D2).
- **O1.** Remover usage says RETAINED and repaired, nothing pruned; the gate prints `--owner <id> <path>`; `land-completeness.sh --repo richos` at this tip prints `quarantined (retired, registered by design) .... 4` and the four Codex trees as `unowned` (out of scope, as the record says).
- **O3.** `root-contract.test.sh` and `session-start-stdin.test.sh` each fit one call with room (§5); the decision table records the fourteenth restart and its door.
- **The lane itself, live:** zach-fable-fix3's cross-repository tree was reclaimed at 00:38:26Z, 3.5 minutes after its terminal record and 2.3 after main took its branch; Echo's at 23:50:26Z; Frank-cert3's at 23:00:32Z. Sage-cert3's two workspaces HOLD on the platform's lock, correctly. `remove=4 branch-only=6 observe=0 hold=10 excluded=9 not-examined=4` (`preview-at-2d2f6cf1.txt`).
- **CI at the tip:** see §5, last row.

## 4. What the record said and the machine answered

| Record's claim | Command | Answer at `2d2f6cf1` |
|---|---|---|
| 2b is reached only when the native shell is absent or unregistered, and the lock outranks the record | `scratch-o2-persist.txt`; live: `_judge_registration` on `sage-fable-cert3`'s aid row under entity femcboost | **FALSE after the first write** — step 1 returns the persisted row before the lock is read; live: NOT-ALIVE "witnessed termination" while the shell is LOCKED by running pid 84597 |
| 31 suite runs, each in its own sandbox; no live ledger changed | `grep '"witness": "platform-terminal-record"' ~/.claude/state/worktree-ledger.jsonl`; `scratch-repro-9b.txt`; `scratch-stdin-suite-redirected.txt` | **FALSE** — one row at 00:02:34Z, written by `session-start-stdin.test.sh` 9b through the real reaper; reproduced twice against a copy |
| O2 turns a finished cross-repository reviewer's row from INDETERMINATE to NOT-ALIVE while the session lives | `judge(...)` read-only on frank-fable-cert3, echo-opus-ci1 | **FALSE** — aggregate INDETERMINATE (aid-less `prepared` row), both entities |
| The second source is read from the fallback for a session with no team directory | `scratch-one-teamdir.txt` | TRUE with ≥2 or 0 team directories; **FALSE with exactly 1** (row filed in the foreign directory) |
| Echo's transaction carries no terminal record | the transaction file | **FALSE** — `SubagentStop 23:49:01.889Z`, member removed 23:50:26Z |
| 106 terminal / 72 owning / 14 restarted | `restart-after-terminal-measure.py` | 108 / 74 / 14 (18.919 %) — two more owners finished since |
| `--locks` (a) 3 of 3, (b) 0 of 1, (c) 4 from the start fact | `--locks` | (a) 3 of 3, (b) 0 of 1, (c) 4 — reproduces |
| feedbeef 130 rows; `session-deadbeef` | `grep -c`, `ls` | 0 rows / gone (the coordinator's cleanup, confirmed) |

## 5. Suites run at this tip — foreground, one per call, logs in `docs/verification/certification-frank-round4-suite-logs-2026-09-11/` (`RESULTS.tsv` is the row-per-run record)

SUITE-TABLE-PLACEHOLDER

## 6. What would have to be true for me to certify

Each stated so an engineer can act without asking me. All of them.

1. **D1.** Step 2b never appends a ledger row. `platform_terminal_record()` is read live on every judgment, as the lane re-reads its transaction; if a persisted witness is wanted for reporting, it carries a kind that step 1 does not return on. The entity join lives inside `_judge_registration`: before 2b, the lock is resolved in every repository the agent id has a native registration in (the `_entities_for` logic, moved down), so a call with the tree's own repository as entity cannot reach 2b while a shell is locked elsewhere. Tests: the sandbox sequence in D1 (write, then an open post-terminal start → INDETERMINATE); a wrong-entity call with a locked shell in the session repository → ALIVE; mutants on both.
2. **D1, the record.** The engine can express the retraction of a `terminated` row (an event that supersedes it, read by step 1), and the row written at 00:02:34Z for agent `ae904aac1949e5696` is either retracted that way or removed by the operator with the reason on the record. Not silently.
3. **D2.** No suite in the engine reads or writes the operator's `~/.claude/state/worktree-ledger.jsonl`, `~/.claude/worker-events.jsonl` or `~/.claude/teams/`: `session-start-stdin.test.sh` and `root-contract.test.sh` redirect `HOME` (or `REAP_WORKTREE_LEDGER`, `REAP_TEAM_DIR`, `RICHOS_WORKTREE_LEDGER`, `WORKER_EVENTS_TEAMS_DIR`) and assert both arms as 17o/F16/L2 do; and the class is closed by a canary in the shared runner that fails any suite that changes those three paths (the escalations suite's 17n/17o shape, pointed at the record).
4. **D3.** O2 is proven on the real shape: a test registers the two rows every helper-made tree has (`prepared` without an agent id, `registered` with it), session alive, shell absent, terminal record closed — and the verdict is the one the design intends, documented. Either the aid-less row is joined to the aid by the engine's own writer, or the docstring says the door stays INDETERMINATE until session end and the "two authorities" sentence goes.
5. **D4.** The writer and the reader agree on where a session with no team directory writes: either `resolve_team_dir()` never returns a foreign session's directory, or `platform_lifecycle_after()` opens every `session-*` log filtered by the full session id. Both arms tested.
6. **D5.** The record's Echo sentence corrected, and the round-15 record's suite table filled from runs at the shipping commit.

D6 and D7 are not conditions of my key.

## 7. What I examined and what I did not

**Examined at `2d2f6cf1`:** the full round-14 engine diff; `worktree-ledger.py` `registrations`…`judge` and the CLI verbs (lines 845–1300); `worktree-transactions.py` `record_start`, `note_after_terminal`, `lifecycle_teams_dir`, `lifecycle_fallback_log`, `platform_lifecycle_after`, `post_terminal_events`…`load_tx`, `claim_terminal`, `is_terminal_agent`, `bind_late_members`; `daily-workspace-cleanup.py` `ignored_files`, `git_store_roots`, `looks_like_git_object`, `never_disposable`, `reclaim_now`, `sweep_max_residue_bytes`, `residue_bytes`, `sweep_session`; `worktree-adoption.py` `owner_evidence`; `workspace-retire.py` `termination_authority` and `sweep`'s erasure rule; `remove-agent-worktree.sh` header, usage and entity resolution; `land-completeness.py` `_entities_for`, `_judge_owner`, `analyze`; `land-residue-gate.py`; `reap-stale-worktrees.sh` discovery sources, ledger path and the judge-batch call; `session-start-reap-worktrees.sh`; `worker-started-handoff.sh` / `worker-ended-handoff.sh` `resolve_team_dir`; `guard-sealed-worktree.sh` identification (payload `agent_id`, not cwd) and the TERMINAL branch; `session-start-stdin.test.sh` in full; the L06 and F1c′ test bodies; the three mutation harness diffs; `ci-run-record-check.sh` / `ci-run-records.py` diff; `orchestration.config`; the decision table diff; the round-14 record; all six earlier verdicts.

**Live record examined:** the transaction store (108 terminal, 74 owning; Echo's, both round-three keys', both round-four keys', the fixer's in detail); the ownership ledger (17,29x rows; every ownership and termination row for the six round-three/four trees; every `terminated` row since 2026-09-10T20:00Z); all nine team directories and their logs (254 rows, 0 foreign); the fallback log (250 rows, 0 `feedbeef`); the richos worktree registry; Sage-cert3's lock file; the process table for pid 84597; the fixer's transcript (00:00–00:05Z) and scratchpad; CI run 34547178102.

**Not examined:** `reconcile-terminal-worktrees.py` beyond `build_manifest`'s disposable pruning and the preview; the managed-image lanes; `guard-resume-isolation.sh` (unchanged); `contract-integrity.test.sh` and `by-reference.test.sh` (not run by the fixer either); the ~180 suites outside this area; whether the platform re-creates a native shell on a restart into an absent one (unobserved on this machine; the barrier identifies by payload id, so it does not depend on the shell). I spawned nothing, merged nothing, pushed nothing, and changed no live workspace, ledger, transaction store or registry: every judge call was `write=False`/`--no-write`, every reaper run pointed at a copy, every experiment built and deleted its own sandbox. The real ledger's `terminated` count was 46 before and after (`real-record-baseline.txt`, §5 last rows); its line count grew by the `finished` rows the platform's own hooks write for my helper turns, which is the engine at work and not a write of mine.

## 8. Reproduction pointers

- D1 sandbox: `scratchpad/o2-persist.sh` (own ledger, own `RICHOS_WORKTREE_TX_DIR`); output in `scratch-o2-persist.txt`. Live: `python3 -c` over `worktree-ledger.py` calling `_judge_registration(reg, '/Users/alex/ab/femcboost', records, mod, False, None)` for each `registrations(records, worktree='/Users/alex/ab/richos-wt/sage-fable-cert3')`.
- D2: `scratchpad/repro-9b.sh` (both arms, ledger copies), `scratchpad/stdin-suite-redirected.sh`; outputs `scratch-repro-9b.txt`, `scratch-stdin-suite-redirected.txt`. The row: `grep '"witness": "platform-terminal-record"' ~/.claude/state/worktree-ledger.jsonl`.
- D3: the same per-registration call on `frank-fable-cert3` and `echo-opus-ci1`; `bash engine/scripts/land-completeness.sh --repo /Users/alex/ab/richos` (`land-completeness-richos.txt`).
- D4: `scratchpad/one-teamdir.sh` → `scratch-one-teamdir.txt`; live count: python over `~/.claude/teams/session-*/worker-events.jsonl` comparing each row's `session_id[:8]` to its directory.
- D6: `scratchpad/d1edge.py` → `scratch-d1edge.txt`.
- Measures and preview: `measure-plain.txt`, `measure-locks.txt`, `preview-at-2d2f6cf1.txt`.
