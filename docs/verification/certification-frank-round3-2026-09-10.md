CERTIFIED

# Certification review, round three, Frank — workspace reclamation at richos main `2b8a235d`

**Reviewed at:** richos main `2b8a235df52d032bb6214335670e1480c60fb1ab` (the fourteen commits `9956ab6a..2b8a235d`; `git log --oneline 9956ab6a..2b8a235d` in this worktree) · **Date:** 2026-09-10, 21:58Z–23:40Z · **Reviewer:** Frank (Fable), one of two independent keys · **Independence:** I did not coordinate with Sage and did not read any round-three document of theirs. I read both keys' round-one and round-two verdicts, as the brief instructed.
**Platform:** this session runs Claude Code **2.1.268** (`"version"` in `~/.claude/projects/-Users-alex-ab-femcboost/b7869424-….jsonl`); the previous session, where every restart on record was observed, ran **2.1.267**.
**Method:** read every line of the round-three diff (24 files, +1,865/−151); read in full the files I declared unread in round two (`reconcile-terminal-worktrees.py` 1,473 lines, `worktree-adoption.py` 876, `discard-workspace-backlog.py` 277, the round-three regions of `workspace-retire.py`, `reap-stale-worktrees.sh`, `remove-agent-worktree.sh`, `terminalize-agent-worktrees.sh`, `record-subagent-start.sh`, and every new test body); ran sixteen suites at this tip in the foreground with logs under this worktree (§5); ran the round-13 code read-only against the live record (§3); ran a scratch experiment on the R1 fix's edge cases in a temporary repository it created and deleted (§2.1); and measured, on this platform build, the two facts row 5 depends on (§3). Every number carries the command that produced it.

## 1. The verdict in one paragraph

The three conditions my round-two key set (§6 of `certification-frank-round2-2026-09-10.md`) are met, each by code with a test and a mutant that I ran, and the one that matters most — that an open post-terminal run cannot outlive its own stop — I additionally verified from the outside on the real record: the previous session died at 21:49Z, its pid 8799 is gone, and the read-only preview at this tip now says `remove` for fix1 (two post-terminal runs on its transaction), fix2, sage-fable-cert2 and unl1 on the ground `session d0eef867: recorded pid(s) 8799 gone or reused; no running registration` — the session-death override doing exactly what round 13 built it to do, on a real event the fixer said it could not produce (§3). The only loss path found in two rounds (R1) is closed and I could not reopen it with a nested repository two levels under `node_modules/`, a nested linked worktree with a gitfile under `.cache/`, or a write into the nested repository after the archive (§2.1). The re-lock premise is withdrawn in every place it stood, the write barrier is named and its mutant ran red-on-removal, and the git binary is the lane's. On this platform build, the two facts row 5 rests on hold: the platform locks before an initial start (−38.8 ms and −45.8 ms for this session's two agents), and a registration id's `WorkerRunEnded` is a run's end, not a turn's (62 helper stops in this session carry per-run ids; neither registration id has a stop row while both agents run). I looked hard for the fixer's six attack surfaces and at the second source's lifetime, and what I found (§4) is one defect of the record — the second source is a file the platform deletes at session exit, which nothing says, and the `--locks` numbers the record cites cannot be re-run because that deletion already happened — plus two bounded latency holes. None loses work, none misstates what protects a removal, and none is a condition of my key. **I stress-tested this and it holds up.** What I am not certifying is in §6.

## 2. The round-two conditions, each re-derived by something that did not make it

### 2.1 R1 — no ignored nested repository is ever dropped as disposable: CLOSED

**Code:** `never_disposable()` (trailing-slash entry, or any `.git` component) runs first in `partition_ignored()`; `_expand_residue()` walks a nested repository whole, `residue_manifest()` records every file, directory and symlink, `archive_residue()` tars directories as directory entries, `verify_residue_archive()` checks them, the journal names `nested_repositories`. `vendor` is off the disposable list (`orchestration.config`), with the reason beside the line.
**Suite:** `test_a_nested_repository_under_a_disposable_path_is_ARCHIVED_whole_never_dropped` (asserts the listing premise, the partition, the nested HEAD's loose object in the tar, and a restore whose `rev-parse HEAD` is that commit) — PASS; mutant `nested-repository-dropped-as-disposable` — killed (§5).
**My own experiment** (`scratchpad/r1edge.py`, temp repo created and deleted, under the lane's binary `/Library/Developer/CommandLineTools/usr/bin/git` = `git version 2.50.1 (Apple Git-155)`), calling the real module functions:

```
ignored_files: ['.cache/linked/', 'build.log', 'node_modules/link-to-other', 'node_modules/scope/pkg/']
dropped (disposable): ['node_modules/link-to-other']          <- a symlink under node_modules; removing it removes nothing it points at
residue: ['.cache/linked/', 'build.log', 'node_modules/scope/pkg/']
manifest entries: 38  files=25 dirs=13 symlinks=0
nested .git dir objects in manifest: 31                       <- a repo two levels under node_modules, .git and all
linked-worktree gitfile in manifest: ['.cache/linked/.git'] file   <- a nested LINKED worktree (gitfile) is also a trailing-slash entry
linked-worktree dirty file in manifest: True
last look: (True, '')
last look after a late write into the nested repo: (False, "... (1 added, 0 gone, 0 changed; e.g. ['node_modules/scope/pkg/late.txt']) ...")
```

An empty ignored directory is not listed and is not evidence. A tracked submodule is refused by non-force `git worktree remove` itself (`check_clean_worktree` → `validate_no_submodules`), so its object store under the admin directory is never reached. I could not construct a path where a non-force removal loses bytes the archive does not hold.

### 2.2 R2/R4 — an open post-terminal run cannot outlive its own stop: CLOSED

**Code:** `post_terminal_events()` merges the transaction's notes with `platform_lifecycle_after()` (this exact registration id, this session, strictly after the terminal record); `post_terminal_run_open()` lets `session_gone` void the run at both call sites (`owner_check`, `reclaim_now`), and past `POST_TERMINAL_RUN_STALE_SECONDS=3600` the hold names the operator and the exact `note-after-terminal` command. The hook branch that writes the closing stop note is unchanged in shape and now tested through the real hook.
**Suites:** `…lost_stop_note_is_closed_by_the_platforms_own_event_log_and_a_lost_start_note_is_opened_by_it` (also pins that another agent's rows and another session's rows never count), `…cannot_outlive_its_session`, `…stale_open_run_names_the_operator_remedy_and_the_remedy_works` (through the CLI) — PASS; mutants `second-source-ignored`, `session-death-does-not-void-an-open-run`, `stale-hold-never-names-a-person` — killed. Hook-level R40 (a real repeat `SubagentStop` after a noted start records `stop {"start": 1, "stop": 1}` and the run is no longer open) and R41 (a repeat with no open run records nothing) — PASS; mutant `post-terminal-stop-unrecorded` — killed.
**Live:** §3.

### 2.3 R3/R5 — the row-17 argument names its real protection and its real measurement: CLOSED

`platform_lock_is_absent()`'s docstring, the safety-claim block, the last-look comment in `reconcile()`, the decision table §3, the relock test's comment, the terminalize header and the start hook's announcement all now say: lock-precedes-start is measured on INITIAL starts; re-lock on a restart is UNMEASURED ((b) 0 of 3 held throughout, (c) 4 unobservable); what protects a restart into an unlocked tree is row 5, the write barrier, and the ancestor gate. The barrier's mutant `terminal-not-refused` (G15) — killed in `guard-sealed-worktree.test.sh` at this tip. The git citation names `completion-proof.GIT` (Apple Git 2.50.1) and records that Homebrew 2.52.0 and `/usr/bin/git` 2.39.5 refuse identically. `record-subagent-start.sh` now says a restarted terminal agent "can neither read, write nor report".

### 2.4 The rest of what round two asked

- **R6 / Sage D2 (every door):** `discard-workspace-backlog.validate` refuses on path and on the branch git reports (`refuse_ceo_owned`, before any other check on the row) and on every branch row; `workspace-retire.termination_authority` asks `excluded_by_ceo_ruling` as its FIRST gate on both routes; `remove-agent-worktree.sh` refuses at the door on the spelled branch/path; `reap-stale-worktrees.sh` gate S31 reports `excluded-by-ceo-ruling(…)` before eligibility, never `operator-worktree`. Suites: `discard-workspace-backlog.test.py` 10/10, `workspace-retire.test.sh` S31 (18 assertions), `reap-stale-worktrees.test.sh` S31, unit `…at_every_door` exercising both operator tools by name — all PASS.
- **R7:** `restart-after-terminal-measure.test.sh`, 9 cases incl. the positive probe (a lock re-taken 40 ms after a restart IS counted) — PASS.
- **Sage D3** (`residue_last_look`), **D4** (`terminalize(deadline=)`, `reclaim_now(budget_deadline=, max_files=)`), **D5** (`vendor` off the list), **D6** (`worktree_removed_ts`, `removed_ts`) — read, and each has the test the record names; `ignored-last-look-removed` killed.
- **The record:** `reclaim-round-13-zach-fable-fix2-2026-09-10.md` §5 ("Suites run at this tip") is EMPTY — the placeholder line and nothing after it, as the brief said. §5 below is the suite record at this tip.

## 3. What the live system produced under the round-13 code, read from the outside

- **The session-death override, on a real event.** The previous session (`d0eef867`, pid 8799) ended at 21:49:10Z (last transcript timestamp); `ps -p 8799` exits 1; the ownership ledger holds 117 rows recording `session_pid: 8799` for it. `python3 engine/scripts/reconcile-terminal-worktrees.py --preview` at this tip (`docs/verification/certification-frank-round3-suite-logs-2026-09-10/preview-at-2b8a235d.txt`): `remove=8 branch-only=3 observe=0 hold=4 excluded=9 not-examined=0`. The eight are the native and cross-repository members of unl1, fix1, fix2 and sage-fable-cert2, on `session d0eef867: recorded pid(s) 8799 gone or reused; no running registration` for the native members and `clean, integrated, unlocked` for the hand-rolled ones. fix1's transaction carries `start/stop/start/stop` and fix2's `start/stop` after their terminal records; `post-terminal` on fix1 exits 1 (not open). The four holds are dor1/dor2 ×2 on VM pid 1483 standing in the tree; the nine EXCLUDED are the Codex trees. The round-13 record said the branch had produced no artifact of its code acting on a real event; this is one, read-only, at the landed commit.
- **The thirteenth restart.** `restart-after-terminal-measure.py` → 104 terminal, **70** workspace-owning, **13** restarted (18.571 %); the thirteenth is the round-13 author, `zach-fable-fix2`, restarted 86.7 s after its terminal record (21:37:14Z, on 2.1.267), noted `start` then `stop` on its transaction, both members deferred on the platform's lock while the session lived, and now `remove` (above).
- **On 2.1.268:** no terminal transaction exists in this session yet (`b7869424`: 0), so no restart of a terminal agent has been observed on this build either way — stated, not assumed. Two facts row 5 depends on were re-measured on this build: `--locks` (a) lock PRECEDES the initial start for both agents of this session (−45.8 ms sage-fable-cert3, −38.8 ms this agent); and in this session's `worker-events.jsonl`, 2 `WorkerStarted` rows carry the two registration ids and **0** of the 62 `WorkerRunEnded` rows do — every stop row carries a per-run helper id (`agent_type` empty). So a registration-id stop in the second source is the run's end, which is what `running_after_terminal` assumes.

## 4. What I found this round — none a condition of my key

### F1. The second source is a file the platform deletes at session exit, and nothing says so; the record's `--locks` citations no longer reproduce

**Established:** `~/.claude/teams/session-d0eef867/` no longer exists (`ls ~/.claude/teams/`); no `worker-events.jsonl` on this machine names fix1's or fix2's agent id (`grep -l` over `~/.claude/teams/*/worker-events.jsonl ~/.claude/worker-events.jsonl` → nothing); the previous transcript contains 0 `TeamDelete` calls; no engine script removes a team directory (`grep -rn "rmtree\|rm -rf" engine/scripts | grep -i team` → only the probe's own canary). So the platform (or the operator, by hand — I cannot distinguish; `unverified:` which) removed it between 21:49Z and 22:49Z. Consequences:

1. The claim "TWO SOURCES" is true exactly while the owning session lives — which is exactly when the flock race it exists for can occur (a hook losing a 5 s flock to a sweep or nightly pass of the same live session). After the session ends, hooks no longer fire, no note can be lost, and `session_gone` voids any open run — verified live in §3. A session with no ledger identity (none observed; this session recorded pid 84597 on 6 rows at spawn) would be one-source and would hold until the stale bound names a person. Every case fails in the safe direction. **The design is coherent; the sentence explaining why is missing** from `lifecycle_teams_dir`'s docstring, `post_terminal_run_open`'s, and decision-table row 5.
2. `restart-after-terminal-measure.py --locks` at this tip prints `(a) 2 of 2, (b) 0, (c) 0` — this session's two agents only. The record's `(a) 4 … (b) 3 … (c) 4`, the docstrings' "four of four initial starts, 42.9 to 101.6 ms", "(b) 0 of 3", and "Sage H3: all eleven post-terminal restarts on record carry it" all cite a corpus that the platform has since deleted. They were true when run; they are now claims with a date on them, and the script's own output does not say its corpus is transient. The restart COUNT still reproduces (it rests on the durable `starts/` fact in the transaction store). Nothing load-bearing rests on (a)/(b)/(c): they support a sentence that says UNMEASURED, and that sentence is still true.

**Fix (prose and one footer, next commit):** state the lifetime — "the platform's per-session event log is deleted at session exit; it exists for as long as a note can be lost, and `session_gone` takes over after" — in the two docstrings and row 5; make `--locks` print that its corpus is the live team directories only and date-stamp the record's numbers as measured in session `d0eef867`, no longer on disk.

### F2. The in-event lane is bounded on tracked files, not on ignored residue (the fixer's attack 4 and 6, quantified)

`sweep_session` and `reclaim_now` check `IMMEDIATE_RECLAIM_SWEEP_MAX_FILES` against `git ls-files`; the residue archive (now including a nested repository whole) and `residue_last_look`'s second hash are unbounded, and `stop_at` is checked only between candidates. A candidate under the ceiling with a large ignored residue starts its archive inside the 15 s budget of a 20 s hook, is killed, and is retried by the next event's sweep 15 s later — every subagent stop in that session then spends the whole hook budget until the 04:00 pass takes it. No loss: the tmp tar is unlinked on retry, the member's journal advances only after verify, and the terminal record is written before the sweep. Pre-existing shape, widened by round 13. **Fix:** a residue byte ceiling from `os.lstat` sizes (no hashing) checked before `archive_residue` in the in-event lane only.

### F3. The fixer's remaining attack surfaces, decided

- **6.1 ordering across sources:** the window exists only if the platform starts a restarted run before the previous stop's `SubagentStop` hooks return (fix1's note preceded its event row by 51 ms). `unverified:` whether it awaits them; on this build a registration id has no turn-level stops (§3), so the only stop that can close a run is the run's end. If the window is real, the cross-repository member is removed under an agent the barrier refuses every tool — disruption, the class the table already accepts.
- **6.2 fallback log:** `~/.claude/worker-events.jsonl` was last written 17:38 today, by three `pinger` agents in sessions with no team directory (`451ab625`, `6630c4ae`, `8d990c00` — probe sandboxes, none workspace-owning). One source there, then the stale bound. Boundary.
- **6.3 stale lever:** an operator recording a stop on a genuinely open run makes the lane proceed under a barred agent — disruption; the reason reads as a hand on the record. Accepted.
- **6.5 Codex definition:** §31's own words are "*workspaces starting with `codex/`*" plus the `~/.codex/worktrees` path; a custom `CODEX_HOME` is outside the ruling's definition. Boundary, and the ruling's to widen.

## 5. Suites run at this tip — every one in the foreground, one per call, logs in `docs/verification/certification-frank-round3-suite-logs-2026-09-10/`

| Suite | Result | rc | Wall |
|---|---|---|---|
| `reconcile-terminal-worktrees.mutation.sh` (Sage's round-two batch left this KILLED at rc=143) | **30 of 30 proven load-bearing** | 0 | 446 s |
| `reconcile-terminal-worktrees.test.sh` (`RICHOS_MUTATION_INNER=1` so it did not re-chain the harness above) | all 59 passed | 0 | 45 s |
| `daily-workspace-cleanup.test.sh` (61 cases + harness) | all 61 passed; 28 of 28 mutants incl. `nested-repository-dropped-as-disposable`, `second-source-ignored`, `session-death-does-not-void-an-open-run`, `stale-hold-never-names-a-person`, `ignored-last-look-removed`, `restart-after-terminal-ignored` | 0 | 321 s |
| `lib/worktree-transactions.test.sh` | all 70 passed; 25 of 25 | 0 | 166 s |
| `hooks/terminalize-agent-worktrees.test.sh` | all 54 passed incl. R40/R41; 15 of 15 incl. `post-terminal-stop-unrecorded` | 0 | 79 s |
| `hooks/record-subagent-start.test.sh` | all 14 passed; 6 of 6 | 0 | 7 s |
| `lib/worktree-adoption.test.sh` | all 43 passed; 15 of 15 | 0 | 108 s |
| `reap-stale-worktrees.test.sh` | all 54 passed incl. S31; 6 of 6 | 0 | 386 s |
| `lib/workspace-retire.test.sh` | 53 passed, 0 failed, 2 stated not covered, 420 assertions, incl. S31 | 0 | 90 s |
| `discard-workspace-backlog.test.py` | Ran 10 tests, OK | 0 | 2 s |
| `hooks/guard-sealed-worktree.test.sh` | all 53 passed; 18 of 18 incl. `terminal-not-refused` (G15) | 0 | 54 s |
| `cleanup-routing-contract.test.sh` | 14 passed; 9 of 9 | 0 | 26 s |
| `hooks/session-start-reap-worktrees.test.sh` | all 16 passed; 5 of 5 | 0 | 21 s |
| `lib/completion-proof.test.sh` | Ran 25 tests, OK | 0 | 6 s |
| `lib/worktree-ledger.test.sh` | all 37 passed; 8 of 8 | 0 | 12 s |
| `restart-after-terminal-measure.test.sh` | all 9 passed | 0 | 1 s |

Sixteen runs, sixteen exit 0, no run killed; 165 mutants proven load-bearing. Every suite the brief listed as unrun at this tip (the daily harness, the reconciler test and mutation, adoption, completion-proof, session-start-reap) is in this table. Wall times are `time` on the call; the machine was shared with the other key's runs throughout.

## 6. What I am not certifying

- The record's F1 lifetime statement and the re-derivability of the `--locks` numbers (§4.F1) — a prose defect I would fix in the next commit; not a condition.
- The in-event lane's behavior on a large ignored residue (F2) — bounded by the hook's kill, no loss, unmeasured on a real workspace.
- Any restart of a terminal agent on Claude Code 2.1.268: none has occurred yet on this build; the mechanism that records and refuses one is unchanged and its suites are green here, but the observation is from 2.1.267.
- CI (`engine-self-verify.yml`, which runs the reconciler suite at ~940 s in a 60-minute job) — not run by me.
- Cross-session immediacy: the eight `remove` candidates from the dead session wait for the 04:00 pass, because `sweep_session` sweeps only the current session's transactions — the design, stated.
- The 186 suites outside this area; `legacy-workspace-*` / `managed-workspace-*` lanes beyond confirming the reconciler routes them to their own protocols and never erases a quarantine (`unregister_member`/`remove_member` raise `BlockedFailure`).
- That the platform awaits `SubagentStop` hooks before starting a new run (F3, 6.1).

## 7. What I examined and what I did not

**Examined at `2b8a235d`:** the full round-three diff; `daily-workspace-cleanup.py` regions `ceo_owned_workspace`, `owner_check`, `post_terminal_run_open`, `session_gone`/`session_id_gone`, `_release_dead_lock`, `platform_recorded_a_stop`, `platform_lock_is_absent`, `ignored_files`…`residue_last_look`, `verify_residue_archive`, `assess`, `reconcile` in full, `unlock_wait_seconds`…`sweep_session` in full; `worktree-transactions.py` `lifecycle_teams_dir`, `platform_lifecycle_after`, `post_terminal_events`, `restarted_after_terminal`, `running_after_terminal`, `open_run_since`, `terminalize`, `_reclaim_in_event`, the two new CLI verbs, `note_after_terminal`'s lock; `reconcile-terminal-worktrees.py` in full; `worktree-adoption.py` in full; `discard-workspace-backlog.py` in full; `workspace-retire.excluded_by_ceo_ruling`/`termination_authority` gate; `reap-stale-worktrees.sh` gate S31 and summary; `remove-agent-worktree.sh` door; `terminalize-agent-worktrees.sh` lines 150–275 and `record-subagent-start.sh` diff; `worker-ended-handoff.sh` team-directory resolution and fallback; `hooks.json` registrations and timeouts; `orchestration.config`; `cleanup-routing.signature`; `reclaim-decision-table.md` row 5 and §3; every new test body in `daily-workspace-cleanup.test.py` and `terminalize-agent-worktrees.test.sh`; the mutation harness/pool (no single-mutant switch exists, so the killed harness had to be run whole — it was); `engine-self-verify.yml` timing notes; `ceo-decisions.md` §31.

**Live record examined:** the transaction store (104 terminal, 70 owning; fix1, fix2 in detail); the ownership ledger (identity rows for `d0eef867` and `b7869424`); `~/.claude/teams/` and every surviving `worker-events.jsonl`; the fallback log; the process table for pid 8799; both session transcripts' version and boundary timestamps; the preview and both measure verbs at this tip.

**Not examined:** CI; the 186 suites outside this area; `reap-stale-worktrees.sh` beyond S31, its candidate rule and `--execute` routing (1,905 lines); `workspace-retire.py` beyond its round-three gate and header (2,766 lines); the managed-image daemon; `guard-resume-isolation.sh` (unchanged). I spawned nothing, merged nothing, pushed nothing, and mutated no live workspace, ledger, transaction store or registry; every suite built its own sandbox and the scratch experiment created and deleted its own temporary repository.

## 8. Reproduction pointers

- §3 preview: `python3 engine/scripts/reconcile-terminal-worktrees.py --preview` (read-only); `ps -p 8799`; `grep -c '"session_id": "d0eef867' ~/.claude/state/worktree-ledger.jsonl`.
- §3 build facts: `python3 engine/scripts/restart-after-terminal-measure.py --locks`; `grep -c '"event": "WorkerRunEnded"' ~/.claude/teams/session-b7869424/worker-events.jsonl` vs `grep '"agent_id": "a522d0a7173c7d3a1"' … | grep -o '"event": "[A-Za-z]*"'`.
- F1: `ls ~/.claude/teams/`; `grep -c TeamDelete ~/.claude/projects/-Users-alex-ab-femcboost/d0eef867-….jsonl` → 0; `grep -rn "rmtree\|rm -rf" engine/scripts | grep -i team`.
- R1 experiment: `scratchpad/r1edge.py` (session scratchpad; output quoted in §2.1).
- Suites: `docs/verification/certification-frank-round3-suite-logs-2026-09-10/SUMMARY.txt` and the per-suite logs beside it in this worktree.
