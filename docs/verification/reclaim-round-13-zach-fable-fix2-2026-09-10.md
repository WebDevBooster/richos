# Reclaim round 13 — what closed, with the command that proves each, and what to attack

**Branch:** `cc/zach-fable-fix2` in `/Users/alex/ab/richos-wt/zach-fable-fix2`, from richos main
`9956ab6a` (acknowledged `c8b4ba67`, Sage's section 5a, as a stale-record move). **Author:** Zach
(Fable, by the CEO's order after two refusals). **Date:** 2026-09-10. **This document does not
declare the work fit for use; both reviewers review again.**

Every number below carries the command that produced it and its denominator. Everything in
sections 1–3 was verified by a suite or a mutant; section 4 says which of it the live system has
produced an artifact for, and which it has not.

---

## 1. The three that had to close

### 1.1 Frank R1 — the only loss path found in two rounds: an ignored nested repository under a disposable path component

**Reproduced before touching anything**, under the lane's own binary (`completion-proof.GIT` =
`/Library/Developer/CommandLineTools/usr/bin/git`), scratchpad `r1-repro.py`:

```
git version 2.50.1 (Apple Git-155)
ls-files -o -i --exclude-standard (no --directory): ['extra', 'vendor/lib/', 'vendor/plain-ignored']
...with --directory: ['extra', 'vendor/']
worktree remove rc=0 stderr='' exists after=False
```

The trailing slash is the signature: `ls-files --others --ignored` lists every ignored path as a
file except where it meets a nested repository, which it reports as one directory entry and does
not enter. `partition_ignored()` matched that entry's parent component against the disposable
list and dropped it.

**Closed by** `41a5f9bd`: `never_disposable()` — a trailing-slash entry, or any path with a
`.git` component, is residue whatever its parent is called; `archive_residue()` expands a nested
repository to every object under it (`.git` included, symlinks never followed), the archive holds
and verifies directory entries, and the journal names `nested_repositories`. Anything the archive
cannot take (a socket, a fifo) still holds the workspace.

**Evidence:** `test_a_nested_repository_under_a_disposable_path_is_ARCHIVED_whole_never_dropped`
asserts the listing premise, the partition, that the nested HEAD's loose object is in the
archive, and that the archive restores to a repository whose `HEAD` is that commit. Mutant
`nested-repository-dropped-as-disposable` (`return False` in `never_disposable`) turns it red.

**Examined, not changed:** the reconciler's legacy quarantine-capture route
(`reconcile-terminal-worktrees.build_manifest`) prunes disposable directories in its `os.walk`
the same way, but that lane never erases its quarantine (`automatic erasure is disabled`, a
`BlockedFailure`), so there is no loss path behind it.

### 1.2 Both reviewers — the re-lock-on-restart premise, measured on the wrong case

Not repaired; withdrawn, measured, and the real protection named (`7df05e91`, `e6f68235`).

**Measured**, `python3 engine/scripts/restart-after-terminal-measure.py --locks` on this machine
at this commit (corpus: every native member of a sealed transaction whose admin directory is
still on disk, joined to every `WorkerStarted` for its registration id; unlocked witnesses from
the ownership ledger):

```
(a) initial starts with a lock file on disk : 4; lock PRECEDES the start in 4 of them
(b) restarts with a lock file on disk       : 3; lock mtime moved AFTER the restart (a re-lock OBSERVED) in 0 of them
(c) restarts into a tree the reaper witnessed UNLOCKED : 4; admin directory still on disk for 0 of them
    a57075d0698120f83  witnessed unlocked 2026-09-10T13:11:22  restarted 2026-09-10T14:34:37  (+4994 s)  admin dir GONE -- re-lock unobservable
    a8922391964bc8c3b  witnessed unlocked 2026-09-10T13:11:23  restarted 2026-09-10T14:34:37  (+4994 s)  admin dir GONE -- re-lock unobservable
    aa1627717a25e308e  witnessed unlocked 2026-09-10T13:11:23  restarted 2026-09-10T14:34:37  (+4994 s)  admin dir GONE -- re-lock unobservable
    ac115bc42a1e283a9  witnessed unlocked 2026-09-10T13:11:23  restarted 2026-09-10T14:34:37  (+4994 s)  admin dir GONE -- re-lock unobservable
```

(a) is −48.7, −94.4, −42.9 and −101.6 ms (unl1, this agent, fix1, sage-fable-cert2). (b) is
fix1's two restarts (19:57:02Z, 20:27:11Z) and sage-fable-cert2's one (21:01:09Z), each with the
lock mtime unchanged since the worktree was created: held throughout, never released, never
re-taken. (c) is the case the premise existed for, and it left nothing to read. **So "the
platform re-locks before a restarted run" is UNMEASURED**, the script says so in those words,
and its suite (`restart-after-terminal-measure.test.sh`, 9 cases) pins (a), pins that a lock held
throughout is not counted as a re-lock, pins (c) with the admin directory gone, and carries the
positive probe: a lock re-taken 40 ms after a restart IS counted, so the zero is a measurement,
not a blind spot.

**The true protection, written where it lives** (`platform_lock_is_absent`, the safety-claim
block in `daily-workspace-cleanup.py`, the decision table §3): for a restart into an unlocked
tree, the lock and git's refusal promise nothing. What holds is

1. row 5 from two sources (`post_terminal_run_open`);
2. **the write barrier** — `guard-sealed-worktree.sh` refuses a terminal agent every tool, `Read`
   included (its header: *"refused EVERY tool, sealed or not, read-only or not"*), load-bearing by
   mutant `terminal-not-refused` (G15) in `guard-sealed-worktree.mutation.sh`; observed live on
   fix1's two restarts and, per the coordinator, on sage-fable-cert2's;
3. the ancestor gate re-verified immediately before the removal.

A removal under an unlocked restart is a disruption, never a loss. The lock is defense in depth.

**The binary:** `"git 2.52.0"` named Homebrew's git on the operator's `PATH`. Three binaries are
on this machine and one was cited:

```
$ /Library/Developer/CommandLineTools/usr/bin/git --version   -> git version 2.50.1 (Apple Git-155)   (completion-proof.GIT: the lane)
$ /usr/bin/git --version                                      -> git version 2.39.5 (Apple Git-154)   (hard-coded by discard-workspace-backlog.py)
$ git --version                                               -> git version 2.52.0                   (/opt/homebrew/bin/git, the operator's PATH)
```

All three refuse a locked worktree with exit 128. The citations now name the lane's.

### 1.3 Frank R2/R4 — Type J inside the new code: one source, no expiry, the stop branch untested

**Closed by** `608718e1`:

- **Two sources.** `post_terminal_events()` merges the transaction's `after_terminal` notes with
  the platform's own log (`~/.claude/teams/session-<sid8>/worker-events.jsonl`, `WorkerStarted`
  / `WorkerRunEnded` for this exact registration id in this session, strictly after the terminal
  record). A stop note lost to the 5-second flock is closed by the platform's row; a lost start
  note is opened by it. Hermetic like `session_id_gone`: a redirected transaction store reads no
  event log unless `RICHOS_TEAMS_DIR` names one.
- **The session's death voids it.** `post_terminal_run_open()` lets `session_gone` override row
  5 at both call sites (`owner_check`, `reclaim_now`).
- **Age.** Past `POST_TERMINAL_RUN_STALE_SECONDS` (3600, declared in `orchestration.config`; every
  post-terminal run observed on this machine lasted under a minute) the hold — still a hold —
  names the remedy and the exact command: `worktree-transactions.py note-after-terminal
  --session-id … --agent-id … --kind stop --detail operator`.
- **The hook branch is tested.** `terminalize-agent-worktrees.test.sh` R40 drives a real repeat
  `SubagentStop` through the real hook after a noted post-terminal start and asserts the stop
  note (`stop {"start": 1, "stop": 1}`, run no longer open); R41 pins that a repeat with no open
  run records nothing. Mutant `post-terminal-stop-unrecorded` (`pass` on the branch).

**Evidence:** `test_a_lost_stop_note_is_closed_by_the_platforms_own_event_log_and_a_lost_start_note_is_opened_by_it`
(also pins the exact join: another agent's rows and another session's rows never count),
`test_a_post_terminal_run_cannot_outlive_its_session`,
`test_a_stale_open_run_names_the_operator_remedy_and_the_remedy_works` (through the real CLI).
Mutants `second-source-ignored`, `session-death-does-not-void-an-open-run`,
`stale-hold-never-names-a-person`.

---

## 2. Also open, closed

| Item | Commit | What | Evidence |
|---|---|---|---|
| Sage D2 / Frank R6 — two doors without §31 | `c2fafb67` | `discard-workspace-backlog.validate` (`refuse_ceo_owned`, path + checked-out branch + every branch row), `workspace-retire.termination_authority` first gate (`excluded_by_ceo_ruling`, both routes, under the lock, before any mutation), `remove-agent-worktree.sh` at the door, `reap-stale-worktrees.sh` gate S31 reporting `excluded-by-ceo-ruling(...)` never `operator-worktree` | discard `…even_under_explicit_discard_authority` (3 spellings + control), workspace-retire S31 (53 passed, 420 assertions, rc=0), reap S31, unit `…at_every_door` exercises both operator doors by name |
| Sage D3 — archive-to-`rm` window on ignored bytes | `41a5f9bd` | `residue_last_look()` re-lists and re-digests the residue immediately before `git worktree remove`; any difference is a RETRY | `test_an_ignored_file_written_after_the_archive_HOLDS_the_removal`; mutant `ignored-last-look-removed` |
| Sage D4 — own-member reclaim unbounded | `31e7bae0` | `terminalize(deadline=)` from the hook's `_DEADLINE`; `reclaim_now(budget_deadline=, max_files=)` — exhausted budget defers before work, tracked-file ceiling read from the member's own repository config, lock wait capped by the hook's deadline | `test_the_events_own_member_is_bounded_by_the_ceiling_and_the_hooks_deadline` |
| Sage D5 — `vendor` on the disposable list | `65a54fdd` | removed, reason beside the line; the nested-repository test moves to `node_modules/` | `assertNotIn('vendor', disposable_paths(...))` |
| Sage D6 — no removal timestamp | `08eecc21` | `worktree_removed_ts` and `removed_ts` (UTC) on both routes | `test_the_record_says_WHEN_a_workspace_was_removed` |
| Frank R5 — record and code disagree | `7df05e91` | terminalize header, start-hook announcement, relock-test comment, two mutant descriptions say what the code does | read |
| Frank R7 — measure script has no suite | `7df05e91` | `restart-after-terminal-measure.test.sh`, 9 cases | run |
| Frank — children refusal's stated reason | `e6f68235` | the reason is corrected beside the original in the escalation record: the lock was absent for 83 minutes on q1; the protection is the process probe, row 5 and the barrier | `grep a57075d0698120f83 ~/.claude/state/worktree-ledger.jsonl` |
| Sage §5a — `reconcile-terminal-worktrees.mutation.sh` killed by SIGTERM, unverified | — | run to completion at this tip; result in section 5 | section 5 |

**The restart count, re-derived at this commit:** `python3 engine/scripts/restart-after-terminal-measure.py`
→ 103 terminal transactions, **69** workspace-owning (denominator), **12** restarted after their
terminal record (17.391 %), 3 event logs scanned. The twelfth is sage-fable-cert2.

---

## 3. Refused, or deliberately not done

- **Killing an agent's background children** — still refused (both reviewers accepted); the
  reason is corrected (section 2).
- **A live demonstration of these changes' behavior.** The hooks this session runs are the live
  engine at richos main; a worktree cannot make its own hook code fire on a real event. The
  measurement script (`--locks`, the restart count) ran on the live record and its numbers are
  the live system's. Every behavioral change here is proven by suites and mutants only — which
  is exactly the standard the brief says is insufficient on its own, and it is stated rather
  than glossed. A reviewer at the landed commit can produce the artifact: the next restart of a
  terminal agent will carry `after_terminal` notes and `post-terminal` will show both sources.
- **Frank R6, the preview's NOT-EXAMINED pass** enumerating only repositories that already have
  a transaction member — not changed; a repository worked in only by hand has no transaction
  and is outside the lane by construction. A boundary, stated.
- **`BINDING_LEDGER_WRITERS` as a string allowlist** — a boundary against the accident that
  happened, not forgery; unchanged.
- **The legacy capture lane's `os.walk` pruning** — examined, not changed (section 1.1).
- **`discard-workspace-backlog.py` hard-codes `/usr/bin/git` (Apple Git 2.39.5)**, a third binary
  beside the lane's and the operator's — observed, not changed; it is that tool's own choice and
  outside this round's scope.

---

## 4. What the live system produced, and what it did not

Produced by the live system under the round-12 code, read from the outside during this round:

- fix1 (`a97f2c691c34e2c0f`) restarted a **second** time at 20:27:11.386Z and stopped at
  20:27:28.313Z; its transaction carries four notes, `after_terminal_counts {start: 2, stop: 2}`;
  its lock mtime is still `2026-09-10T17:43:41.993Z` (`os.stat` on
  `femcboost/.git/worktrees/agent-a97f2c691c34e2c0f/locked`).
- sage-fable-cert2 (`aa2e08d7c39345d84`) restarted at 21:01:09.603Z; lock mtime `19:54:19.894Z`,
  unchanged.
- q1's ledger: `terminated … native isolation worktree registered and unlocked` at 13:11:22.947Z;
  `finished` rows at 14:34:59Z and 14:35:09Z (the restart's run).

Not produced: any artifact of the code on this branch acting on a real event (section 3).

---

## 5. Suites run at this tip

(filled in below from the run logs; a suite that did not exit 0 is stated as such)

---

## 6. What a reviewer should attack

1. **The merged timeline's ordering across sources.** `post_terminal_events` decides by the
   LAST event across both sources. The same run appears in both, offset by hook latency
   (fix1: event row 19:57:02.259Z, note 19:57:02.266Z). A restart that begins inside the
   window between a stop NOTE and the same stop's EVENT ROW (tens of milliseconds) would read as
   closed by the later event row. Row 6 (the lock) covers the native member and the barrier
   covers the write; a cross-repository member has neither and would be removed under a
   restarted-but-barred agent — a disruption by the table's claim. Is the window real, and is
   "disruption" the right word for it?
2. **The event log's fallback path.** `worker-ended-handoff.sh` falls back to
   `~/.claude/worker-events.jsonl` when it cannot resolve a team directory; the second source
   reads only the session directory. A session whose rows went to the fallback has one source,
   as before.
3. **The stale bound as a lever.** Past 3600 s the hold names a command an operator can run;
   an operator who records a stop on a run that is genuinely still open makes the lane
   proceed under an agent the barrier refuses. Disruption, not loss — but it is a hand on the
   record, and the reason should be read as one.
4. **Archive size.** A nested repository under `node_modules/` is now archived whole; nothing
   bounds its size, and the in-event ceiling counts tracked files only. A large clone would run
   in the nightly pass with no budget.
5. **The §31 classifier's notion of "Codex".** `~/.codex/worktrees` via `HOME`, and `codex/`
   branches. A Codex tree under a custom `CODEX_HOME`, or a detached-HEAD Codex tree outside
   that directory, is not the class by the ruling's own definition — say whether the ruling
   meant more than that.
6. **`residue_last_look` re-hashes the whole residue** a second time; on a large residue the
   window it closes is replaced by the time it takes. Cheap by construction (disposables
   excluded), but unmeasured on a real workspace.
