# Reclaim round 15 — Sage's three conditions and Frank's six, each closed by a commit and proved by a command

**Branch:** `cc/zach-fable-fix4` in `/Users/alex/ab/richos-wt/zach-fable-fix4`, from richos main
`32f8567a993dccb823e3de3231f66e9d94def82b` (main did not move during the round: no in-flight
notice arrived). **Author:** Zach (Fable, by the CEO's order; round fifteen of this class).
**Date:** 2026-09-11. **This document does not declare the work fit for use; both reviewers
review again, and nobody declares it fit, this author included.**

Every number below carries the command that produced it, or the word UNVERIFIED. Section 7 is
filled from real runs at the final code commit `8a46024d`; every one of the forty exited 0, and
`reclaim-round-15-suite-results.txt` beside this file is the runner's row per process.

---

## 0. The operator's record, before and after this round

Read-only, at dispatch (2026-09-11 ~01:40Z, before any edit) and at the end (03:14:07Z):

| Path | Before | After | Command |
|---|---|---|---|
| `~/.claude/state/worktree-ledger.jsonl` lines | 17,354 | 17,424 | `wc -l` |
| … `"event": "terminated"` rows | 46 | **46** | `grep -c` |
| … `"witness": "platform-terminal-record"` rows | 1 | **1** (not retracted by me — §2) | `grep -c` |
| … `"event": "retracted"` rows | 0 | **0** | `grep -c` |
| `~/.claude/worker-events.jsonl` lines | 250 | **250** | `wc -l` |
| `~/.claude/teams/` entries | 9 | **9** | `ls \| wc -l` |

The 70 new ledger lines, classified by a python over the file (`(event, source)` for every row with
`ts > 2026-09-11T01:2`): **91 × `finished` / `worker-ended-handoff.sh`** (the platform's own hook
at every helper turn of every live agent; the count exceeds 70 because the window starts before my
first `wc`), **1 × `prepared` and 2 × `registered`** — `create-teammate-worktree.sh` at 01:37:46Z
and `detect-nonnative-worktree.sh` at 01:38:48Z, teammate `zach-fable-fix4`: the engine's own
writers registering **my own spawn**. No suite of mine wrote a row; the two suites that used to
were run with the operator's real `HOME` on purpose at the final commit (§3, §7) and their negative
arms compared against the real paths.

---

## 1. The judge (Frank 1, Sage 1) — commit `05086a17`

**What round 14 did, re-derived before changing it.** Step 2b of `worktree-ledger._judge_registration`
resolved the owner's native lock with `lock_entity = entity` for a hand-rolled registration — the
caller's argument — fell through to `platform_terminal_record()` when that entity held no shell,
and with `write` on appended a `terminated` row (witness `platform-terminal-record`) that step 1
then returned on every later call, ahead of the lock and ahead of row 5. Both keys reproduced it in
a sandbox; the live row is the one in §0.

**Closed, four ways, all in `scripts/lib/worktree-ledger.py`:**

1. **`_lock_entities(reg, records, entity)`** — the entity join is inside the judge. The lock is
   resolved, in order, in a native row's own repository; in every repository this agent id has a
   **native registration** in on the ledger (the row `detect-nonnative-worktree.sh` writes per spawn,
   in the session's repository); in the **transaction's own native member's** repository (the
   manifest the reclaim lane's `owner_check` reads, so both authorities look in the same place —
   with the `<entity>/.claude/worktrees/agent-<id>` shape as a fallback when a member carries no
   `repo`); and last the caller's entity. ALIVE anywhere wins; INDETERMINATE anywhere holds; an
   OBSERVED unlocked shell anywhere is the observation it always was (still written, witness
   `reaper-observation`, as before). A resolver failure is INDETERMINATE, never a fall-through.
2. **Step 2b never appends.** `platform_terminal_record()` is read live on every judgment, as the lane
   re-reads its transaction; a `terminal` state returns NOT-ALIVE with the reason quoting the
   record, an `open` state returns row 5's INDETERMINATE, and nothing outlives the read.
3. **`RECORD_DERIVED_WITNESSES = ("platform-terminal-record",)`** — step 1 does not return on a row
   of that kind. The fact lives in the transaction store and is re-read at 2b; a copy already on a
   ledger (the one round 14 wrote) is corroboration, never a verdict. Step 1 still returns on the
   ledger's own kinds (`reaper-observation`, `reaper-removal`, `remove-agent-worktree`,
   `rich-observed-return`), and those can now be retracted (§2).
4. The transactions module is loaded once per process (`_TX_MODULE`) rather than per registration.

**Proof — `bash engine/scripts/lib/worktree-ledger.test.sh` → 71 PASS lines (56 cases) + 15/15 mutants, 28 s at `8a46024d`:**

| Case | What it pins |
|---|---|
| L06e | two repositories: shell LOCKED by a running pid in A, both engine rows (native in A, hand-rolled in B), a sealed terminal transaction naming both; judged with entity **B** and with entity **A**, **write ON** → ALIVE both, and the ledger's line count unchanged |
| L06f | no native ledger row at all — only the hand-rolled row and the manifest's native member → ALIVE with the tree's own entity |
| L06f′ | control: the same shape with the shell UNLOCKED → NOT-ALIVE "OBSERVED now", exactly one `reaper-observation` row written — the lookup through the manifest is real, not a stub |
| L06g | the terminal-record verdict with write ON appends **no** `terminated` row |
| L06g′ | Frank's sequence: after that write-enabled judgment, a post-terminal start → row 5's INDETERMINATE (`RETRY, not a verdict…`) — the property one persisted row destroyed |
| L06h | a `platform-terminal-record` row on the ledger (the live row's shape) beside a LOCKED shell → ALIVE |
| L06h′ | control: a `reaper-observation` row still decides at step 1 — the filter is by kind, not a disabled step |

Mutants (`worktree-ledger.mutation.sh`): `lock-resolved-in-callers-entity-only` (L06e),
`terminal-record-witness-persisted` (L06g — re-inserts the append, and L06g′ shows what it destroys),
`record-derived-witness-decides` (L06h). Each verified red by the harness at `8a46024d`.

**The docstring sentence.** `platform_terminal_record`'s "a door reading it authorizes nothing the
lane would not" is true again and now says why (the store is re-read, nothing is written from 2b);
the "two authorities" sentence is rewritten as history plus the round-15 join (§4). The 2b comment
"reached only when the native shell is absent or unregistered" now reads "reached only when no
repository that can hold this owner's shell holds a lock for it".

**Live, read-only, on a copy of the operator's ledger** (`scratchpad/r15/live-case.py`, output kept
in the transcript): `sage-fable-cert3`'s tree at this tip, `write=False`, **entity richos and entity
femcboost: every registration ALIVE, aggregate ALIVE** — `its isolation worktree
/Users/alex/ab/femcboost/.claude/worktrees/agent-ae904aac1949e5696 is LOCKED by running pid 84597` —
with the round-14 row still on the copy. The lock outranks the record again, whichever entity is passed.

**A finding on the way (the harness):** `bound-members-fallback`'s substitute called `read_all()` with
no path, which reads `~/.claude/state/worktree-ledger.jsonl` — the operator's real ledger — and the
mutant was "proven" only because that file held 17,000 rows. Under a redirected `HOME` it read
nothing, L28 stayed green and the red moved to L29. Frank D2's class, read-only. The substitute is
now a constant registration-shaped row (commit `05086a17`).

---

## 2. Retraction (Frank 2, Sage 1) — commit `05086a17`; the operator's ledger NOT touched

**The mechanism.** A `retracted` event: `{"event": "retracted", "agent_id", "retracts_ts",
"retracts_witness", "teammate", "session_id", "worktree", "reason", "source", "ts"}`. `terminations()`
— the one reader step 1, `record terminated --once` and adoption's T3 corroboration come through —
returns only `terminated` rows whose exact `ts` no `retracted` row for that agent id names. The
measure's ledger witness (`restart-after-terminal-measure.unlocked_witness_rows`) honors it too. The
ledger stays append-only: the wrong row and the row that voids it sit side by side with the reason.

**The verb.** `worktree-ledger.py retract --agent-id <id> --ts <exact ts> --reason <why> [--source
<who>] [--dry-run]` — refuses (rc 2, nothing written) unless exactly one `terminated` row matches;
prints the row it voids; `--dry-run` writes nothing; a second retraction of the same row is skipped.

**Proof:** L06i (a `ts` naming no row → rc 2), L06i′ (`--dry-run` appends nothing), **L06j** (the
retracted registration is ALIVE again; the record holds both rows with `retracts_witness`), L06j′ (a
repeat is `skipped: already retracted`); mutant `retraction-ignored` (L06j); measure M13 (a
witnessed-unlocked row a retraction names leaves `--locks` (c)). Rehearsed against a **copy** of the
operator's ledger (`live-case.py`): dry-run rc 0 printing the 00:02:34Z row; applied on the copy, rows
17,421 → 17,422, standing `terminated` rows for `ae904aac1949e5696` 1 → 0; the real ledger's row count,
`platform-terminal-record` count (1) and `retracted` count (0) unchanged after the script.

**Rich — run this once after the land, from the richos main checkout** (the row's `ts` is exact;
the command refuses anything but one match):

```
python3 /Users/alex/ab/richos/engine/scripts/lib/worktree-ledger.py retract \
    --agent-id ae904aac1949e5696 \
    --ts 2026-09-11T00:02:34.984941+00:00 \
    --source round-15-record \
    --reason "written by session-start-stdin.test.sh 9b through the shipped reaper with a sandbox entity while the owner's shell was LOCKED by running pid 84597; round 14 step 2b, superseded by round 15"
```

Expected: two JSON lines, `{"retracts": {…the 00:02:34Z row…}}` then the `retracted` row; rc 0.
Verify: `grep -c '"event": "retracted"' ~/.claude/state/worktree-ledger.jsonl` → `1`. Add `--dry-run`
first to see it without writing. Running it twice prints `skipped: already retracted` and appends nothing.

---

## 3. No suite touches the operator's record (Frank 3) — commits `e0217b23`, `5545da9f`

**The class, closed at the runner.** `scripts/lib/record-canary.sh` (new) watches, per suite, under
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}` as captured when the library is sourced: the ownership ledger
(every row **except `event: finished`**, by content hash), the fallback event log (every line, by
content hash), and the team directory entries (names, one level). `run-all-tests.sh` and `ci-shard.sh`
both take its baseline beside the leak baseline before every suite; a change is **`RECORD-TOUCHED`**,
red, the rows printed; a missing library is refused at rc 2 like the leak canary's. In CI none of the
three paths exists, so there the witness is exact.

**The one exclusion, stated where it is made** (the library header, `run-all-tests.sh` header, and
test 2b / 5d): the platform's own `worker-ended-handoff.sh` appends a `finished` row at every helper
turn of every live agent (91 of them during this round, §0), so a witness that counted them would be
red on nearly every suite of a live-machine run, and a canary that cries wolf gets muted. A `finished`
row is advisory and never decisive; a leaked one is residue, not a false witness. Every other event
is witnessed. The false-positive vectors are named in the header (a real spawn, a real reap, a
no-team-directory session, a new platform log file), and each prints the row so a reader recognizes
the machine's own activity.

**Proof:** `record-canary.test.sh` 13/13 (red on each shape the class took: a `terminated` row, the
feedbeef fallback rows, `session-deadbeef/`; an in-place rewrite; unreadable → unhealthy; green on a
`finished` row); `run-all-tests.test.sh` 5a–5f (19/19 — a touching suite fails the run and is named,
the row is printed, the `finished`-only suite beside it is not blamed, the runner announces the canary,
a missing library is refused); `ci-shard.test.sh` S15b (25/25). Both runner tests point
`CLAUDE_CONFIG_DIR` at a throwaway directory so they neither depend on nor touch the real record.

**The two suites.** `session-start-stdin.test.sh` and `root-contract.test.sh` take the real record's
witness first, then `export HOME="$SANDBOX/home"` (the operator's `.gitconfig` copied in when present;
a fixture identity through the environment when not — CI), and name every path the reaper resolves
under `HOME` explicitly too: `REAP_WORKTREE_LEDGER`, `RICHOS_WORKTREE_LEDGER`, `REAP_TEAM_DIR`,
`RICHOS_TEAMS_DIR`, `WORKER_EVENTS_TEAMS_DIR`, `RICHOS_LIVENESS_TEAMS_DIR`, `REAP_LEDGER`,
`REAP_PROJECTS_DIR`, `RICHOS_PROJECTS_DIR`, `RICHOS_SESSIONS_DIR`, `RICHOS_WORKTREE_TX_DIR`,
`RICHOS_WORKTREE_CAPTURE_DIR`, `CLAUDE_CONFIG_DIR`. **Both arms:** 9l / 6c POSITIVE — with a hand-rolled
worktree of the session repository to judge, the reaper's own blind lines name the **sandbox** ledger
(`no ownership ledger exists yet at $HOME/.claude/state/worktree-ledger.jsonl`) and the **sandbox**
team directory (`no inflight-repos.txt under $HOME/.claude/teams`); 9m / 6d NEGATIVE — `rc_escaped`
against the real record's baseline is empty.

**Run with the operator's real `HOME` on purpose, at `8a46024d`** (`run-suite-realhome.sh`, §7 rows
marked REAL-HOME): stdin 13/13 in 23 s, root-contract 29 + 11/11 in 95 s; the real ledger's
`terminated` count 46 → 46, the fallback 250 → 250, teams 9 → 9, the ledger's line count +1 (one
`finished` row from the platform for one of my helper turns). 9m and 6d passed against
`/Users/alex/.claude`.

---

## 4. O2 on the real shape (Frank 4) — commit `05086a17`

**Decided: the engine's own writer joins the id-less row to the id.** `_join_prepared_rows(regs)` in
`judge()`: a `prepared` row with no agent id is judged **as** the agent named by a `registered` row
for the same **exact path**, same **session id**, same **teammate**, when **both** rows were written by
an engine writer (`row_may_bind_by_name` — a hand-written row still reserves and never binds) and
**exactly one** agent id results. This is the join `owner_check` (daily-workspace-cleanup.py, the
id-less-row clause) and `bind_late_members` already trust; nothing is matched by prefix, basename or
branch. A joined row carries `joined_from: prepared` and its reason begins `prepared row joined to
agent <id> (same session, same teammate, same exact path, both rows from an engine writer): …`.

**Proof:** L06k — the two-row shape, shell absent, session alive, terminal record closed → aggregate
NOT-ALIVE, reason `2 registrations match (ledger); prepared row joined to agent two001 … platform
terminal record …`; L06k′ — a `prepared` row with `source rich-land-binding` is never joined
(INDETERMINATE while the session lives); L06k″ — two agent ids for one name in one session are
ambiguous, no join. Mutant `prepared-row-never-joined` (L06k). Live (`live-case.py`, read-only): the
`prepared` row of `sage-fable-cert3` is judged as `ae904aac1949e5696` and both rows say ALIVE from
the lock.

**The docstring.** The "two authorities, two readings of one record" sentence is rewritten in
`platform_terminal_record` as what happened, followed by "THE TWO-ROW SHAPE" naming why O2 decided no
helper-made tree on the real ledger (76 of 76, both keys' count) and what the join is. The
`land-completeness._entities_for` docstring says the join now lives inside the judge and that its
own list is a second, cheaper reading for the report, no longer what protects the verdict.

---

## 5. Writer and reader agree (Frank 5) — commit `199be0ae`; fallback robustness (Sage 3) — commits `e60fd57d`, `399d723c`; git-store shapes (Sage 2) — commit `399d723c`

**5a. The writer.** All four `worker-*-handoff.sh` writers: `resolve_team_dir()` returns the single
`session-*` directory **only when the payload carries no session id**; a known session whose own
directory is absent writes to the fallback file, which the reader opens keyed by the full session id.
The reader is unchanged. Proof: `worker-lifecycle.test.sh` 9a (one foreign directory, known session →
the fallback file, the foreign log untouched), **9a′ (`platform_lifecycle_after` returns that row —
writer and reader agree)**, 9b (control: no session id → the single directory, as before), 9c (the
same rule in the other three writers) — 42/42. The fixture puts the teams directory under the sandbox
home's `.claude`, so the writer's fallback and the reader's are the same file, as in production (my
first fixture put them apart and 9a′ failed for the fixture's reason; corrected before the commit).

**5b. Non-UTF-8.** `platform_lifecycle_after` and `restart-after-terminal-measure.event_rows` read
bytes and decode line by line; a line that does not decode is skipped like one that does not parse,
in the fallback file and in a session log. Proof: `daily-workspace-cleanup.test.py
test_a_non_UTF8_line_in_the_fallback_log_is_skipped_not_raised` (a `\xff\xfe` line, a valid start, a
line carrying the agent id inside bad bytes; then a `\xc3\x28` line in the session log beside the
stop — no raise, the valid rows read, the lane reclaims); mutant `non-utf8-fallback-line-raises`
(re-raises → red); measure M12 (a non-UTF-8 line: exit 0, M10's numbers unchanged).

**5c. Git-store shapes.** `git_store_roots` accepts a symlink `HEAD` whose target starts with `refs/`
(git's `validate_headref`; any other target is not a store git opens and stays with clause (ii)),
and when `objects/` is a symlink whose target lies under the worktree, collapses the target too.
**Boundary, stated** in the docstring and the table (§3 qualified, §4 two rows): a target outside the
worktree and `objects/info/alternates` are not this tree's bytes — the removal does not touch them and
this lane does not archive them. Proof: `test_git_store_shapes_git_itself_opens_are_collapsed_S1_symlink_HEAD_and_S3_symlinked_objects`
— S1 and S3 are both opened by git before the run (`rev-parse HEAD` = the commit), both are collapsed
(`['.cache/objstore3/', '.cache/s3.git/', 'node_modules/pkg1/s1.git/']`), the archive holds S1's HEAD
as a symlink member **and** its `packed-refs` (the names that were being dropped), S3's `objects` as a
link **and** the loose object at `.cache/objstore3/xx/…` (the bytes that were being dropped), and both
restore to a repository whose `HEAD:only-here` reads back; the control (`HEAD -> ../elsewhere`, git
refuses it) is not collapsed and its objects still survive by clause (ii). Mutants
`symlink-HEAD-store-not-recognized`, `symlinked-objects-target-dropped`; the bare-repository mutant
re-anchored to the new indentation (it read "did not apply" on the first harness run — my anchor
drift, fixed). Harness alone at `8a46024d`: **36 of 36**.

**The cleanup-routing contract fired on the judge commit (commit `8a46024d`),** as it was designed
to: `_lock_entities` tests `member['class']` and `member['path']`. Both are keys the lock classifies
as structural, `--record` classified them without a `?`, and the contract holds: 64 routing tests
across 32 functions, 2 route keys, every converter complete, 7 locked blind spots;
`cleanup-routing-contract.test.sh` 14 + 9/9.

---

## 6. The record (Frank 6) — commit `573811f1` and this file

The round-14 record's Echo sentence is corrected in place, dated (its transaction carries
`SubagentStop 2026-09-10T23:49:01.889703Z`, member removed 23:50:26Z; the INDETERMINATE it showed
was the two-row shape). §4a is added there: the round's own `session-start-stdin.test.sh` 9b wrote
the 00:02:34Z row through the shipped reaper, with the timing (`§7` row began 00:02:28Z; O2 commit
23:59:17Z) and the retraction pointed here. §7 below is from real runs at `8a46024d`.

---

## 7. Suites run at the final code commit `8a46024d`

Every row is one process I ran in the foreground through `scratchpad/r15/run-suite.sh` (rc from the
process, wall from `date +%s` around it), logs under `scratchpad/r15/suites/`, the rows appended to
`RESULTS.tsv` as each ended and copied verbatim to `reclaim-round-15-suite-results.txt`. `HOME` was
redirected to a scratch home seeded with the operator's git identity for every row except the two
marked REAL-HOME. The three heavy harnesses ran **alone, one per call**; the quick and medium rows ran
as two sequential batches while the reaper suite ran beside them, so their walls are upper bounds.
Nothing was backgrounded; the longest call was 318 s inside a 600 s timeout.

| Suite | rc | wall | Note |
|---|---|---|---|
| `lib/process-identity.test.sh` | 0 | 1 s | Ran 12, OK |
| `hooks/hook-staleness.test.sh` | 0 | 4 s | 28/28 |
| `lib/finish-row-completion.test.sh` | 0 | 3 s | 16 + 5/5 |
| `hooks/land-disposition.test.sh` | 0 | 4 s | 33 |
| `lib/completion-proof.test.sh` | 0 | 6 s | Ran 25, OK |
| `hooks/record-subagent-start.test.sh` | 0 | 7 s | 14 + 6/6 |
| `hooks/engine-status.test.sh` | 0 | 3 s | 16/16 |
| `hooks/stop-hook-visibility.test.sh` | 0 | 2 s | 40/40 |
| `hooks/guard-ci-red-lands.test.sh` | 0 | 18 s | 16 |
| `ci-run-record-check.test.sh` | 0 | 1 s | 14 |
| `lib/leak-canary.test.sh` | 0 | 1 s | 23 |
| `lib/global-state-witness.test.sh` | 0 | 3 s | 13 |
| `ci-units.test.sh` | 0 | 8 s | 17 |
| `ci-affected-units.test.sh` | 0 | 7 s | 10 |
| `lib/record-canary.test.sh` (new) | 0 | 0 s | 13 |
| `run-all-tests.test.sh` | 0 | 2 s | 19 (5a–5f new) |
| `ci-shard.test.sh` | 0 | 12 s | 25 (S15b new) |
| `land-completeness.test.sh` | 0 | 2 s | 18 |
| `restart-after-terminal-measure.test.sh` | 0 | 1 s | 13 (M12, M13 new) |
| `hooks/escalations.test.sh` | 0 | 5 s | 79 |
| `hooks/session-start-reap-worktrees.test.sh` | 0 | 20 s | 16 + 5/5 |
| `hooks/worker-lifecycle.test.sh` | 0 | 2 s | 42 (9a–9c new) |
| `hooks/session-start-stdin.test.sh` | 0 | 23 s | 13 (9l, 9m new) |
| `cleanup-routing-contract.test.sh` | 0 | 26 s | 14 + 9/9 |
| `lib/worktree-ledger.test.sh` | 0 | 28 s | 56 cases, 71 PASS lines + **15/15** (L06e–L06k″, five mutants new) |
| `discard-workspace-backlog.test.py` | 0 | 2 s | Ran 10, OK |
| `daily-workspace-cleanup.test.sh` (unit, `RICHOS_MUTATION_INNER=1`) | 0 | 32 s | 67 (two new) |
| `reconcile-terminal-worktrees.test.sh` (unit, `RICHOS_MUTATION_INNER=1`) | 0 | 45 s | 59 |
| `lib/worktree-adoption.test.sh` | 0 | 60 s | 43 + 15/15 |
| `hooks/guard-sealed-worktree.test.sh` | 0 | 49 s | 53 + 18/18 |
| `hooks/detect-nonnative-worktree.test.sh` | 0 | 59 s | + 7/7 |
| `hooks/terminalize-agent-worktrees.test.sh` | 0 | 77 s | 54 + 15/15 |
| `lib/workspace-retire.test.sh` | 0 | 89 s | 54 passed, 2 not covered (stated), 428 assertions; F1c′ proceeds on basis `platform-terminal-record` (from the live reason, no written row) |
| `hooks/root-contract.test.sh` | 0 | 94 s | 29 + 11/11 (6c, 6d new) |
| `lib/worktree-transactions.test.sh` | 0 | 116 s | 70 + 25/25 (T00 green after the re-lock) |
| `reap-stale-worktrees.test.sh` (alone) | 0 | 318 s | 54 + 6/6 |
| `hooks/session-start-stdin.test.sh` — **REAL HOME** | 0 | 23 s | 13; 9m against `/Users/alex/.claude` |
| `hooks/root-contract.test.sh` — **REAL HOME** | 0 | 95 s | 29 + 11/11; 6d against `/Users/alex/.claude` |
| `reconcile-terminal-worktrees.mutation.sh` (alone) | 0 | 259 s | 30 of 30 |
| `daily-workspace-cleanup.mutation.sh` (alone) | 0 | 299 s | **36 of 36** (three new) |

Forty runs, forty exit 0. Not run: `contract-integrity.test.sh` (39 min in CI; the seated surface it
audits is exercised by `engine-status`, `stop-hook-visibility` and `hook-staleness` above),
`by-reference.test.sh`, `create-teammate-worktree.test.sh`, `guard-worktree-isolation.test.sh`,
`guard-worktree-removal.test.sh`, `inflight-ack-durability.test.sh` and the ~170 suites outside this
area. **CI:** I cannot push; `engine-self-verify` on the landed tip is the proof, and `ci-units.sh`
discovers `record-canary.test.sh` from disk (it takes `DEFAULT_WEIGHT` until a run measures it —
same choice as round 14 for the stdin suite).

---

## 8. Numbers in this record, and the commands that produced them

| Number | Command |
|---|---|
| 17,354 / 46 / 1 / 250 / 9 before; 17,424 / 46 / 1 / 0 / 250 / 9 after | `wc -l`, `grep -c`, `ls \| wc -l` on the three real paths, at ~01:40Z and 03:14:07Z |
| 91 finished / 1 prepared / 2 registered since dispatch, and their teammate | python over the real ledger, `(event, source)` for `ts > 2026-09-11T01:2`; the three ownership rows printed with `teammate`, `ts`, `worktree` |
| ALIVE both entities, 1 → 0 standing terminated rows on the copy, real ledger unchanged | `python3 scratchpad/r15/live-case.py` (copies the ledger first; every judge call `write=False`) |
| 64 / 32 / 2 / 7 | `python3 engine/scripts/cleanup-routing-contract.py` after `--record` |
| every rc and wall in §7 | `scratchpad/r15/RESULTS.tsv`, copied to `reclaim-round-15-suite-results.txt` |
| 17,000-row ledger read by the old `bound-members-fallback` mutant | `read_all()` with no path → `DEFAULT_PATH`; under the scratch `HOME` the harness reported the red at L29 instead of L28 (run `ledger-full`, `scratchpad/r15/suites-dev/`) |

---

## 9. Refused, or deliberately not done

- **Retracting the 00:02:34Z row on the operator's ledger** — the operator's record; the exact
  command is in §2, rehearsed on a copy, for Rich to run after the land.
- **Redirecting `HOME` for every suite at the runner** — it would silence `engine-status`'s
  user-scope registration read and the operator's git identity guard for every fixture commit, and it
  would change what CI tests. The canary detects; the two suites that reached the record redirect
  themselves.
- **Counting `finished` rows in the record canary** — 91 platform-written rows during this round
  alone; a canary red on every live-machine run is a canary somebody mutes. Stated as the one
  exclusion, with what it costs.
- **Archiving a store whose `objects/` symlink points outside the worktree, or one with
  `objects/info/alternates`** — not this tree's bytes; stated as the boundary in the table and the
  docstring rather than followed across the filesystem.
- **Running the mutation harnesses in parallel with each other** — each is an 8-wide pool; two at
  once risked the 600 s ceiling that produced the fourteenth restart. Each ran alone.
- **`git` in the operator's repositories** — the live case was judged through the engine's own
  resolver (`git worktree list --porcelain` of femcboost, read-only), never by a git command of mine
  outside this worktree.

---

## 10. What the next reviewer should attack

1. **`_lock_entities` and a shell that moved.** The native registration's `repo` is what the ledger
   recorded at spawn. If the platform ever re-creates a shell in a different repository on a restart
   (unobserved on this machine — both keys said so), the join looks in the wrong repository and falls
   to the record. The exhaustion step and the session pid still stand behind it.
2. **The join's "exactly one id".** Two `registered` rows with the same id for one path (a
   re-registration) join fine; two different ids do not. Is there a shape where the engine's own
   writers legitimately produce two ids for one (session, teammate, path)? I found none; the guard
   forbids name reuse within a session.
3. **The record canary's exclusion.** A suite that leaks only `finished` rows is invisible to it.
   `finished` rows are advisory today; if a future consumer ever decides on them, the exclusion must go.
4. **`RECORD_DERIVED_WITNESSES` as a tuple of one.** If another door ever persists a fact that lives
   elsewhere, it must be added here or step 1 will return on it. The rule "the ledger holds only its own
   facts" is a sentence in the docstring, not a guard.
5. **The S3 target under a different disposable component.** The target is collapsed by its own
   relative path; `partition_ignored` sends a trailing-slash entry to residue whatever its parent is
   called (`never_disposable`), and the test asserts it. A target that is itself inside another
   store's directory would produce two overlapping roots, collapsed to the outer one by
   `git_store_roots`' outermost filter — untested.

---

## 11. Commits on `cc/zach-fable-fix4`, oldest first (`git log --reverse 32f8567a..HEAD`)

| SHA | What |
|---|---|
| `e534216c` | this record opened, before any condition was closed |
| `05086a17` | **Frank 1, 2, 4 / Sage 1** — the judge resolves the lock where the shell lives, writes nothing from the record, joins the two-row shape, and can retract a terminated row; L06e–L06k″; five mutants; `bound-members-fallback` made self-contained |
| `e0217b23` | **Frank 3 (the class)** — the runner-level record canary in both runners; `record-canary.sh` + 13-case suite; runner tests 5a–5f, S15b |
| `5545da9f` | **Frank 3 (the instance)** — `session-start-stdin` and `root-contract` move `HOME` with both arms (9l/9m, 6c/6d) |
| `199be0ae` | **Frank 5** — the four lifecycle writers file a known session's row into the fallback file; 9a–9c |
| `e60fd57d` | **Sage 3** — non-UTF-8 lines skipped in both readers; measure M12, M13 |
| `399d723c` | **Sage 2** — S1 and S3 collapsed and archived whole, the boundary stated; the two daily tests and three mutants; the table |
| `8a46024d` | the cleanup-routing signature re-locked for `_lock_entities` — **the final engine-code commit** |
| `573811f1` | **Frank 6** — the round-14 record corrected (Echo; the 9b write) |
| (this commit) | this record filled, and `reclaim-round-15-suite-results.txt` beside it |
