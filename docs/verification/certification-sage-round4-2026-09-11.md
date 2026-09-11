NOT CERTIFIED

# Certification review, round four — richos main `2d2f6cf1` — Sage, 2026-09-11

**Reviewer:** Sage (software architect), on Fable, by the CEO's order, round four. **Reviewed:** the
thirteen commits of `cc/zach-fable-fix3` merged at `2d2f6cf160957614f5344216644e003348e0b2a1`
(`git log --oneline --first-parent 2b8a235d..2d2f6cf1`; 61 files, +3,972/−498 including the app/ CI
fixes and the round-three verdicts), the round-14 record
`docs/verification/reclaim-round-14-zach-fable-fix3-2026-09-10.md`, the live state of this machine
from 00:37Z to 01:35Z, and the suites — 32 runs in the foreground, one process per row, every call
inside its own timeout (section 5). **Independence:** I read Frank's round-one, round-two and
round-three verdicts as instructed; I have not read, sought or received his round-four verdict.
**Platform:** Claude Code 2.1.268; the session pid is 84597.

The verdict is the first line. Nothing below softens it into a score.

---

## 1. Why, in one paragraph

Round 14 closed all five of my round-three conditions, and each closure re-derives from the outside:
the bare-repository shapes are archived whole under the lane's own binary (D1), the tip's own CI
certifies it — *"✓ ci-receipts: 165/165 planned unit(s) ran, all green, all at 2d2f6cf1…"* — and
`process-identity.test.sh` now gives the same verdict on every machine (D2), the fallback event log is
read and the `--locks` (c) count is back from the durable facts (D3), the two leaking suites are
sandboxed and the operator's real files did not move across 32 runs (D4), and the record's suite table
is real (condition 5). The T4 retirement loses nothing on this machine (0 sessions of the T4 shape by my
own count) and the judge's exhaustion step remains for a no-pid row. It is not certified for one thing
the round-14 code introduced, established from the outside and reproduced in a temporary sandbox:
**the judge's new step 2b returns NOT-ALIVE for a cross-repository path — and, write-enabled, appends a
permanent `terminated` witness — whenever it is asked with an entity in which the owner's native shell is
not registered, while that shell is LOCKED by a running pid in the owner's real session repository;
and once the witness is written, step 1 returns NOT-ALIVE for that registration on every later call
with any entity, outranking the lock the design says outranks the record.** It has already happened
on the operator's live ledger: a `platform-terminal-record` witness for my own round-three path was
written at 2026-09-11T00:02:34Z, three minutes after the O2 commit and thirty-three minutes before the
merge, while the reclaim lane's own preview says `hold — LOCKED and the locking pid 84597 is running`
for the same path (D-A). It is not a loss path — the removal route preserves, verifies and renames —
but it is a false termination produced by the one authority every door consults, decided by an
argument the caller passes, and the codebase already documents callers passing the wrong one. That is
the class the 2026-09-03 ruling ended, and the record's sentence *"a door reading it authorizes nothing
the lane would not"* is false on the live record. Two smaller things are boundaries the table does not
state (D-B, D-C).

---

## 2. My five round-three conditions, each re-derived by something other than the fixer's record

**C1 / D1 — bare repository under a disposable component: CLOSED for the class, two boundaries found.**
Code read: `ignored_files()` → `git_store_roots()` (git's own `HEAD` + `objects/` + `refs/` test, checked
on disk, collapsed to the outermost trailing-slash entry) and `looks_like_git_object()` (`objects/xx/<38–62
hex>`, `objects/pack/pack-<hex>.pack|.idx`) as `never_disposable`'s third clause. My own experiment
(`scratchpad/r4/bare_shapes.py`, temp repository, deleted; lane binary `/Library/Developer/CommandLineTools/usr/bin/git`
2.50.1; four shapes the record does not list):

```
ignored entries: 29  trailing-slash entries: ['.cache/gitdir4/', '.cache/mirror256.git/', 'node_modules/pkg3/store.git/', 'node_modules/pkg4/']
S1 symlink-HEAD bare store          git opens it: True  collapsed: False   object files dropped: 0 archived: 3 | HEAD/refs/config dropped: 3
S2 sha256 bare store                git opens it: True  collapsed: True    object files dropped: 0 archived: 8 | dropped: 0
S3 objects symlinked to .cache/objstore3   git opens it: True  (store collapsed)  object files dropped: 3 archived: 0
S4 separate-git-dir under .cache/gitdir4   git opens it: True  collapsed: True    object files dropped: 0 archived: 8 | dropped: 0
git worktree remove rc=0 stderr='' exists after=False
```

S2 and S4 are closed. S1 and S3 are D-B below. The suite the record names
(`…BARE_repository_under_a_disposable_path_is_ARCHIVED_whole…`) is in the 65-case unit run and the
harness proves `bare-repository-dropped-as-disposable` and `git-object-bytes-disposable` (33 of 33, 270 s alone).

**C2 / D2 — a green run whose receipts certify the shipping SHA: CLOSED.** Run 34547178102 (push, created
00:36:08Z, completed 00:57:20Z; `gh run view 34547178102 --repo WebDevBooster/richos --json jobs`: plan,
non-suite-steps, twelve shards, affected-coverage, coverage — every one `success`). Receipts line, from
`gh run view … --log | grep ci-receipts`: `✓ ci-receipts: 165/165 planned unit(s) ran, all green, all at
2d2f6cf160957614f5344216644e003348e0b2a1.` The three red units: `process-identity.test.sh` pins
`RICHOS_SESSION_PROCESSES=none` and an empty `RICHOS_SESSIONS_DIR` inside the suite (diff read); I ran it
bare (12 OK) and with `RICHOS_SESSION_PROCESSES="84597 claude"` pre-set in the environment (12 OK — the
suite's pin wins). `hook-staleness` 28/28; `root-contract` 27 + 11/11 in 216 s (713 s and 1 FAILED in
round three); `session-start-stdin` 11 in 46 s. T4: see section 3.

**C3 / D3 — the substrate stated and the fallback read: CLOSED.** `lifecycle_teams_dir()`,
`post_terminal_run_open()`, table row 5 and the round-13 correction carry the per-session/ephemeral
statement and the 49/3/31/15 count with its command (diff read). `platform_lifecycle_after()` reads the
session log and `lifecycle_fallback_log()` (the sibling of the teams directory) with an exact full-session-id
join on fallback rows. Live, `restart-after-terminal-measure.py --locks` at this tip: `(a) 3; lock PRECEDES
the start in 3`, `(b) 1; re-lock OBSERVED in 0` (my own round-three shell, lock mtime 21:58:03 held through
the 22:55:43 restart), `(c) 4; admin directory still on disk for 0; known only from the start fact (event log
gone) for 4` with a CORPUS LIFETIME footer — where round three printed `(c) 0`. Plain mode: 108 terminal,
74 owning, **14** restarted (18.919 %), 4 logs scanned (three session logs and the fallback). Sandbox
(`fallback_robust.py`): another session's row for the same agent id is excluded, a row with no session
id or an 8-character prefix is excluded, a half-written last line is skipped, the same stop in both files
is de-duplicated. One exception: D-C.

**C4 / D4 — no suite writes the operator's real event log: CLOSED, with my own control.** Before any suite,
`~/.claude/worker-events.jsonl` had 250 rows (the coordinator removed the 130 `feedbeef` rows; `grep -c
feedbeef` → 0; `session-deadbeef/` gone). After all 32 runs: **250**. The ownership ledger grew 17,268 → 17,336,
and every one of the 68 new rows is `finished` / `worker-ended-handoff.sh` / session `b7869424` — this
session's own hook traffic, zero from any fixture session (`ledger_checks.py`). Transaction store 846 → 846
files, team directories 9 → 9, capture store 12 → 12. `finish-row-completion` 16 + 5/5 (F15/F16),
`detect-nonnative-worktree` + 7/7 (L1/L2), `escalations` 17n/17o all green. The 12 `abcd1234` rows from
2026-08-29 remain in the fallback file; they are `WorkerCreated` rows from `worker-created-handoff.sh`, a
different writer from the one D4 named, thirteen days old; not re-produced by anything I ran.

**C5 — the round-13 record's §5: CLOSED.** Removed and pointed at the reviewers' tables and the round-14 §7;
§7 is filled from real runs, and my table in section 5 reproduces its rows (every rc 0 at my tip).

---

## 3. The T4 retirement, judged on what `2e0242d8` was written for

`2e0242d8` (2026-09-10 14:39:58 +0100) made T4 *"crash recovery … a folder WE REGISTERED whose owner cannot
be IDENTIFIED, with no orchestrator session alive anywhere"* — the "no session alive" half being a
process-NAME scan (`no_session_alive()`: `comm == "claude"`). Round 14 removed the tier and the predicate.
What is lost: authorization of a registered folder whose owner identity is `unknown`. `process_status()`
(read) answers `unknown` only when the pid is missing, unprobeable, or running with a legacy/malformed start
token — an identified, gone owner is `gone` → T2, unchanged. So *"a merged, clean, unlocked worktree whose
owner is identified and provably gone"* is still authorized on T2; the retired case is the unidentified
owner, and for that the judge's step 4 (exhaustion against the harness's registry, `INDETERMINATE` never
collapsed) still exists in `worktree-ledger._judge_registration` — a different, ruled-on mechanism, not a
name scan. Re-derived by my own command on the live ledger (`ledger_checks.py`): 656 ownership rows, 12
sessions, **0** sessions with no pid on every row, 0 such paths on disk — the fixer's 650/12/0/0 with 68
hook rows since. Adoption's read-only `evaluate` on the two live shapes: `richos-wt/sage-fable-cert3` →
`REFUSED unclaimed — transaction … already owns`; a `.richos-retired/` quarantine → `REFUSED owner-terminated —
no ownership record … absence of a record is never a claim` (that route is `workspace-retire.py sweep`'s by
O1's design). Nothing on disk changes hands by the retirement, and nothing that was authorized safely is now
stranded. The retirement is right and it aligns the code with the ruling.

---

## 4. Defects, most important first

Severity is mine. "Outside" = the live record or machine; "inside" = code or a scratch sandbox.

### D-A — SEVERE. Step 2b authorizes and writes a termination for a cross-repository path against the owner's held lock, on a caller's entity argument; the witness then outranks the lock forever

**Claim under test.** `platform_terminal_record` docstring: *"a door reading it authorizes nothing the lane
would not"*; step 2b comment: *"Reached only when the native shell is absent or unregistered: a held lock
(ALIVE, or INDETERMINATE with no pid) has already returned above, and the lock outranks the record."*

**Established (outside), on the live record, read-only.** The ownership ledger holds a `terminated` row,
`witness: platform-terminal-record`, `ts 2026-09-11T00:02:34.984941+00:00`, for agent `ae904aac1949e5696`
(my round-three registration) and path `/Users/alex/ab/richos-wt/sage-fable-cert3` (`grep '"witness":
"platform-terminal-record"' ~/.claude/state/worktree-ledger.jsonl` → exactly 1 row on the machine). At the
same time the reclaim lane's read-only preview says, for both members of that transaction, `hold — native
owner is live or unknown: isolation worktree /Users/alex/ab/femcboost/.claude/worktrees/agent-ae904aac1949e5696
is LOCKED and the locking pid 84597 is running` (`reconcile-terminal-worktrees.py --preview`, lines 4–5 of
`scratchpad/r4/preview-at-2d2f6cf1.txt`), and `--locks` shows that lock held since 21:58:03Z through the
22:55:43Z restart. Per registration (`judge_per_reg.py`, `write=False`), with **either** entity:

```
reg prepared   aid=None             -> INDETERMINATE: no native isolation worktree is registered for agent ? … while its session pid 84597 is still running
reg registered aid=ae904aac1949e5696 -> NOT-ALIVE: witnessed termination on record … platform's own terminal record … SubagentStop at 2026-09-10T22:52:36
agent-liveness.resolve(/Users/alex/ab/femcboost, ae904aac1949e5696) -> ALIVE: … LOCKED and the locking pid 84597 is running
agent-liveness.resolve(/Users/alex/ab/richos,    ae904aac1949e5696) -> NOT-ALIVE: no registered entity worktree … (absent/unregistered)
```

So the one authority every door consults now says NOT-ALIVE for that registration while the platform's lock
— *"the ONE authoritative liveness signal"* — says ALIVE, and it says so for the correct entity too, because
step 1 (a witnessed termination on record) runs before step 2 (the lock). The composite verdict is
INDETERMINATE only because an id-less `prepared` row for the same path falls to step 3 (pid alive) — an
accident of a different row, not the design.

**Who wrote it.** The witness value exists only in round-14 code (`2392c68e`, committed 00:59:17 +0100 =
23:59:17Z); the row is 00:02:34Z, three minutes later and thirty-three minutes before the merge (01:35:38
+0100). It was written by a write-enabled `judge` of the branch code run against the operator's real ledger
from this session's team, with an entity in which the shell is not registered — the round-14 record does not
mention the write, and its §4 says the fixer *"did not run git in his worktree"* but not that it ran the judge
with write on. Whether the fixer or the coordinator ran it I did not establish; the row is on the record either
way.

**Reproduced (inside), self-contained** (`wrong_entity_repro.py`: two temp repositories A and B, a native
shell in A locked with `(pid <this process>)`, a hand-rolled path X registered in a temp ledger, a sealed
terminal transaction naming both members, a temp transaction store; deleted after):

```
agent-liveness.resolve(A): ALIVE
judge(entity=A, write=False) -> ALIVE
judge(entity=B, write=False) -> NOT-ALIVE: platform terminal record: …
judge(entity=B, write=True)  -> NOT-ALIVE ; rows appended to the ledger: [('terminated', 'platform-terminal-record')]
judge(entity=A, write=False) AFTER the write -> NOT-ALIVE: witnessed termination on record …   …while resolve(A) still says: ALIVE
```

**Why the entity is wrong in practice.** `_judge_registration` resolves the lock with `lock_entity = reg.repo`
only for `class == native`; a hand-rolled registration uses the caller's `entity`. `workspace-retire.
termination_authority` and `remove-agent-worktree.sh` pass ONE entity — the session's resolved root, or
`--entity-repo` — and `land-completeness._entities_for`'s own docstring records that on 2026-09-10 the same
path answered INDETERMINATE with `--entity richos` and ALIVE with `--entity femcboost`. Round 14 turned that
INDETERMINATE (safe) into NOT-ALIVE plus a permanent row.

**Consequence and blast radius.** No bytes are lost: the retirement route preserves, verifies and renames.
The exposure is a cross-repository tree removed while its owner's shell is locked — the platform has run
terminal agents again 14 times on this machine, and my own round-three agent was one of them, restarted into
exactly this shell at 22:55:43Z. On this machine today every hand-rolled registration (76 of 76) also has an
id-less `prepared` row, so the composite verdict happens to hold at INDETERMINATE while the session lives;
that is not a property of the design and `bind_late_members`-style registrations need not have it. What is
certain is that the record now carries a termination the platform did not give, and that the judge will
repeat it for any entity from now on.

**Fix.** In 2b, before reading the record, resolve the owner's native lock from the TRANSACTION's own native
member (`members[].class == 'native'` → `repo`, `path`) exactly as `owner_check` does (line 319–323), so the
answer does not depend on the caller's entity; ALIVE or INDETERMINATE there returns before the record is
read, and nothing is written. Do not append a `terminated` witness from 2b at all — the transaction store
already holds the fact, and a witness row adds only permanence — or, if a witness is kept, make step 1
re-check a currently held lock for the `platform-terminal-record` kind. Test: two repositories, shell locked
by a running pid in A, judge with entity B → not NOT-ALIVE and zero rows appended; a mutant that turns it red.
And the live row at 00:02:34Z is dealt with on the record (the ledger is append-only; a retraction row type
or an operator note, and a sentence in the round-14 record saying the write happened).

### D-B — LOW. Two D1 shapes git itself opens are outside the fix, and the table does not say so

**S1, symlinked `HEAD`** (`core.preferSymlinkRefs`; git's `validate_headref` accepts a symlink under `refs/`,
and `git rev-parse HEAD` in the store returned the commit): `git_store_roots()` requires `not os.path.islink(HEAD)`,
so the store is not collapsed; its objects survive by `looks_like_git_object` (3 archived) and its `HEAD`,
`config` and `packed-refs` are dropped (3). The commit bytes are held; the branch names are not — recoverable
by `fsck --lost-found`, which is a loss of what git holds by name. One-line fix: accept a symlink `HEAD` whose
target starts with `refs/`, as git does. **S3, `objects` symlinked to a sibling not named `objects`**: the store
is collapsed and archived with the symlink as a symlink; the three object files at `.cache/objstore3/` carry no
`objects/` component and are dropped. Hand-built shape (no git command produces it); a stated boundary is the
minimum. Table §3's *"true again without qualification"* is false by S3 as written.

### D-C — LOW. The shared fallback file couples every member's row 5 to one byte

`platform_lifecycle_after` opens the fallback with `encoding="utf-8"` and catches `OSError` only; a line with
an invalid byte raises `UnicodeDecodeError` out of `running_after_terminal` (sandbox: `C … RAISED
UnicodeDecodeError`, `E … RAISED`). In the lane, `reclaim_now` and `assess` catch `Exception` and journal a
hold — safe — and `platform_terminal_record` returns `none`. But the fallback is one file every session with
no team directory writes, so one such byte holds every candidate on the machine until a person finds it. The
engine's writers are `json.dumps` (ASCII-escaped) and cannot produce it; a foreign writer or disk fault can.
Two-line fix (`errors="replace"`, or catch `ValueError` with `OSError`) and a test; or state the boundary.

### D-D — record only. The fixer's §6 attack list, answered

1. `_GIT_OBJECT_RE` — S1/S3 above; SHA-256 (S2) is covered. 2. Step 2b's ordering against the lock —
D-A: `registered=False` is reached by the wrong entity, which is the common shape for a cross-repository
path judged from where it lives. 3. `--since` as a timestamp — read; the seven SHAs are in the workflow file
with the reasoning; a permanent gap stated as permanent, accepted. 4. Fallback growth — 250 rows; the
per-member scan is behind an `agent_id in line` prefilter; not measured at 10×. 5. Byte ceiling is a size,
not a time — accepted as stated; the nightly pass has no ceiling by design (`sweep_max_residue_bytes`
docstring and `orchestration.config`, read).

---

## 5. What I examined and what I did not — including the suites, run

**Examined in full (diff or file):** every engine file in `2b8a235d..2d2f6cf1` (`daily-workspace-cleanup.py`
+189, `worktree-transactions.py` +115, `worktree-ledger.py` +150 including `_judge_registration`, `judge`,
`platform_terminal_record`, `process_status`, `claude_processes`, the CLI; `worktree-adoption.py` −90;
`workspace-retire.py` gate and its three `termination_authority` callers; `land-completeness.py`,
`land-residue-gate.py`, `land-completeness.sh`, `remove-agent-worktree.sh`; `restart-after-terminal-measure.py`;
`ci-run-record-check.sh`, `ci-run-records.py`, `engine-run-record.yml`; `orchestration.config`;
`process-identity.test.py`; the L06/F1c′ test bodies), `agent-liveness.resolve()` in full, `_entities_for`,
`owner_check`, `post_terminal_run_open`, `session_gone`/`session_id_gone`, `assess`, `_expand_residue`,
`partition_ignored`, `residue_manifest`, `completion-proof.git()`; the round-14 record; the commit message of
`2e0242d8`; both round-three verdicts.

**Live record examined (read-only):** the ownership ledger (17,268 → 17,336 rows), the fallback event log
(250), this session's event log (238), the teams directory (9), the sessions registry (84597 only), the
transaction store (846), the capture store (12), `git worktree list` for richos (12 entries: main, four
quarantines, five codex, frank-fable-cert4, sage-fable-cert3, sage-fable-cert4), the reconciler preview
(`remove=4 branch-only=6 observe=0 hold=10 excluded=9 not-examined=4`), both measure modes, adoption
`candidates`/`evaluate`, the CI run and its log.

**Not examined:** the `managed-workspace-*` and `shell-worktree-sparse` lanes beyond the reconciler cases
C65/C66 passing; `contract-integrity.test.sh` and `by-reference.test.sh` (not run — the 165-unit CI plan
ran what the diff could affect); the ~180 suites outside the list below; CI's workflow logic beyond the
run-record diff; `reap-stale-worktrees.sh` beyond S31, candidates and remover routing (unchanged this round);
`guard-resume-isolation.sh` (unchanged); who, precisely, ran the write-enabled judge at 00:02:34Z. I spawned
nothing, merged nothing, pushed nothing, and mutated no live workspace, ledger, transaction store or registry;
the three scratch experiments ran in temporary directories they created and deleted, with `RICHOS_TEAMS_DIR`
/ `RICHOS_WORKTREE_TX_DIR` redirected and a temporary ledger passed by path.

### 5a. Suites — run at `2d2f6cf1` (worktree HEAD `76ad5fb1`, docs only on top), foreground, one process per row

`certification-sage-round4-suite-results.txt` beside this file is the runner's row per process (UTC time, rc,
wall, HEAD), appended as each run ended. The three heaviest ran alone, one per call; the rest in small
parallel groups on a machine shared with the other key's session, so wall times are upper bounds.

| Suite | rc | wall | Note |
|---|---|---|---|
| `lib/process-identity.test.sh` | 0 | 1 s | 12 OK; pinned CI shape inside the suite |
| same, with `RICHOS_SESSION_PROCESSES="84597 claude"` pre-set | 0 | 1 s | 12 OK — the suite's pin overrides the environment |
| `hooks/hook-staleness.test.sh` | 0 | 4 s | 28/28 (case 11 was red) |
| `daily-workspace-cleanup.test.sh` (`RICHOS_MUTATION_INNER=1`) | 0 | 29 s | 65 cases |
| `lib/worktree-ledger.test.sh` | 0 | 17 s | L06a–L06d; 10/10 |
| `lib/worktree-adoption.test.sh` | 0 | 60 s | 43; 15/15 (`t4-resurrected`, `no-record-is-not-refused`) |
| `lib/worktree-transactions.test.sh` | 0 | 119 s | 70; 25/25 |
| `daily-workspace-cleanup.mutation.sh` (alone) | 0 | 270 s | **33 of 33** |
| `lib/finish-row-completion.test.sh` | 0 | 4 s | 16; 5/5 (F15/F16) |
| `restart-after-terminal-measure.test.sh` | 0 | 1 s | 11 (M10, M11) |
| `land-completeness.test.sh` | 0 | 3 s | 18 |
| `hooks/land-disposition.test.sh` | 0 | 4 s | 33 |
| `lib/completion-proof.test.sh` | 0 | 5 s | 25 |
| `hooks/record-subagent-start.test.sh` | 0 | 8 s | 14; 6/6 |
| `hooks/root-contract.test.sh` | 0 | 216 s | 27; 11/11 (713 s, 1 FAILED in round three) |
| `hooks/session-start-stdin.test.sh` | 0 | 46 s | 11 (new suite) |
| `hooks/terminalize-agent-worktrees.test.sh` | 0 | 174 s | 54; 15/15 |
| `lib/workspace-retire.test.sh` | 0 | 161 s | 54 passed, 2 not covered (stated), 428 assertions; F1c′ |
| `hooks/guard-sealed-worktree.test.sh` | 0 | 51 s | 53; 18/18 |
| `hooks/detect-nonnative-worktree.test.sh` | 0 | 85 s | 7/7 (L1/L2) |
| `reconcile-terminal-worktrees.test.sh` (`RICHOS_MUTATION_INNER=1`) | 0 | 60 s | 59 |
| `hooks/session-start-reap-worktrees.test.sh` | 0 | 29 s | 16; 5/5 |
| `hooks/escalations.test.sh` | 0 | 5 s | 79; 17n/17o |
| `discard-workspace-backlog.test.py` | 0 | 3 s | 10 (a first row `rc=2` in the results file is my runner invoking a `.py` with bash; corrected and re-run) |
| `cleanup-routing-contract.test.sh` | 0 | 28 s | 14; 9/9 |
| `ci-run-record-check.test.sh` | 0 | 2 s | 14 |
| `hooks/engine-status.test.sh` | 0 | 6 s | 16 |
| `hooks/stop-hook-visibility.test.sh` | 0 | 3 s | 40 |
| `hooks/guard-ci-red-lands.test.sh` | 0 | 20 s | 16 |
| `reconcile-terminal-worktrees.mutation.sh` (alone) | 0 | 361 s | 30 of 30 |
| `reap-stale-worktrees.test.sh` (alone) | 0 | 394 s | 54; 6/6 |

Thirty-two runs, thirty-one exit 0 and the one that did not is my own invocation error, re-run green.
Every rc is from a process I ran and whose log I read (`scratchpad/r4/suites/*.log`). Nothing was
backgrounded; the longest call was 394 s inside a 600 s timeout.

---

## 6. What would have to be true for me to certify

Each stated so an engineer can act without asking me. All of them.

1. **D-A.** Step 2b of `worktree-ledger._judge_registration` reads the owner's native lock from the
   transaction's own native member (repository and path), not from the caller's entity, and returns ALIVE or
   INDETERMINATE — writing nothing — whenever that lock is held; the record is consulted only past that check.
   No `terminated` witness is appended from 2b (the transaction store is the fact), or step 1 re-checks a
   currently held lock before honoring a `platform-terminal-record` witness. A test with two repositories
   (shell locked by a running pid in A; judge with entity B and with entity A) asserts no NOT-ALIVE and zero
   ledger rows; a mutant turns it red. `platform_terminal_record`'s docstring sentence about the lane is true
   again. The row at `2026-09-11T00:02:34.984941+00:00` on the operator's ledger is dealt with on the record
   — a retraction mechanism or an operator note — and the round-14 record states that the write happened.
2. **D-B.** Either `git_store_roots()` accepts a symlink `HEAD` whose target starts with `refs/` (git's own
   rule) with S1 added to the suite, or S1 is stated as a boundary; S3 is stated as a boundary in the table's
   §3/§4, and the *"without qualification"* sentence is qualified by it.
3. **D-C.** `platform_lifecycle_after` (and `restart-after-terminal-measure.event_rows`) survive a non-UTF-8
   line in the fallback file — skipped like an unparsable row — with a test; or the boundary is stated beside
   the fallback in `lifecycle_teams_dir()`.

D-D is not a condition of my key.

---

## 7. What I am not certifying, whatever the next round does

- Any restart of a terminal agent on 2.1.268 beyond the one observed (mine, 22:55:43Z, through the
  harness-background door O3 records); the mechanism is unchanged and green.
- The `managed-workspace-*` and `shell-worktree-sparse` lanes beyond their reconciler cases.
- `contract-integrity.test.sh`, `by-reference.test.sh`, and the ~180 suites outside section 5a.
- The fallback file's scan cost at ten times its size.
- Cross-session immediacy of the four `remove` candidates (the design: the 04:00 pass).

---

## Appendix A — how each number was produced

All on this machine, 2026-09-11 from 00:37Z, in `/Users/alex/ab/richos-wt/sage-fable-cert4` at `2d2f6cf1`
(+ this document). Scratch scripts are in the session scratchpad (`r4/`) and are described so they can be
rewritten.

**A1. CI.** `gh run list --repo WebDevBooster/richos --branch main --workflow engine-self-verify --limit 8
--json databaseId,headSha,conclusion,status,createdAt,event` → 34547178102 at `2d2f6cf1`, queued at dispatch,
`{"conclusion":"success","status":"completed"}` at 00:58Z; jobs via `--json jobs`; the receipts line via
`gh run view 34547178102 --log | grep ci-receipts`.

**A2. D1 shapes.** `bare_shapes.py`: a temp main repository with a linked worktree, `node_modules/` and
`.cache/` ignored via `info/exclude`; four throwaway sources each with a commit that exists nowhere else;
S1 `clone --bare` then `HEAD` replaced by `symlink → refs/heads/main`; S2 `init --object-format=sha256`
then `clone --bare`; S3 `clone --bare` then `objects/` moved to `.cache/objstore3` and symlinked back; S4
`clone --separate-git-dir=.cache/gitdir4 … node_modules/pkg4`; sources deleted; `daily.ignored_files`,
`daily.partition_ignored`, `daily.disposable_paths(<this worktree>)`, `daily._expand_residue`; then
`git worktree remove -- <work>` under the lane's env. Output quoted in section 2.

**A3. The live O2 evidence.** `judge_per_reg.py <path>`: `wl.registrations(records, worktree=path)`, then
`wl._judge_registration(reg, entity, records, live, False, None)` per registration for both entities,
`live.resolve(entity, aid)`, and the raw `terminated` rows for the path. The preview:
`python3 engine/scripts/reconcile-terminal-worktrees.py --preview` (read-only) → `scratchpad/r4/preview-at-2d2f6cf1.txt`.
Commit times: `git log -1 --format='%h %ci' 2392c68e` (00:59:17 +0100), `… 2d2f6cf1` (01:35:38 +0100).
Ledger neighbors: rows with `ts` in `[00:00:00Z, 00:05:00Z]` → the witness, then two `finished` rows.

**A4. The synthetic O2 reproduction.** `wrong_entity_repro.py`, output quoted in D-A; `git worktree lock
--reason 'Claude Code isolation worktree (pid <pid>)'` matches `LOCK_PID_RE = \(pid\s+(\d+)`; the transaction
carries `record: transaction, sealed: true, state: terminal, terminal: {ingress: SubagentStop}`, members
native + hand-rolled; `RICHOS_WORKTREE_TX_DIR` redirected; the ledger passed by path.

**A5. Fallback robustness.** `fallback_robust.py`, `RICHOS_TEAMS_DIR` redirected; cases A–E quoted in
section 2 (C3) and D-C.

**A6. Controls.** Before: `wc -l ~/.claude/worker-events.jsonl ~/.claude/state/worktree-ledger.jsonl`
→ 250 / 17,268; `ls ~/.claude/teams | wc -l` → 9; `find ~/.claude/state/worktree-transactions -name '*.json'
| wc -l` → 846; captures 12 (00:44:18Z). After (01:29:53Z): 250 / 17,335 (17,336 at 01:31Z) / 9 / 846 / 12.
The delta classified by `ledger_checks.py`: 68 × (`finished`, `b7869424`, `worker-ended-handoff.sh`).

**A7. T4 re-derivation.** `ledger_checks.py`: ownership rows (`prepared`/`registered`) grouped by session;
sessions where every row lacks `session_pid`; their paths tested with `os.path.isdir`; hand-rolled
`registered` rows with an agent id versus id-less `prepared` rows naming the same path (76 / 76; on disk:
`claude-orchestration-kit-wt/zach-opus-dor2`, `deeply-wt/zach-opus-dor2`, `richos-wt/frank-fable-cert4`,
`richos-wt/sage-fable-cert3`, `richos-wt/sage-fable-cert4`, all with a prepared row).

**A8. Measure.** `python3 engine/scripts/restart-after-terminal-measure.py --locks` and without flags;
output quoted in section 2 (C3).
