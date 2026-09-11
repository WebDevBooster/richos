NOT CERTIFIED

# Certification review, round five, Frank — workspace reclamation at richos main `1c58c017`

**Reviewed at:** richos main `1c58c017420d23b5d0bddaac6ba01fbd097f462d` — the ten commits of `cc/zach-fable-fix4` (round 15) on top of `32f8567a` (the two round-four verdicts on `2d2f6cf1`); `git log --oneline --first-parent 2d2f6cf1..1c58c017` → 3 merges; `git diff --stat 32f8567a 1c58c017` → 30 files, +2,084/−85. **Date:** 2026-09-11, 03:22Z–04:35Z. **Reviewer:** Frank (Fable), one of two independent keys. **Independence:** I did not coordinate with Sage and did not read any round-five document of theirs. I read every earlier verdict of both keys, including both round-four verdicts and both §6 lists.
**Platform:** Claude Code 2.1.268; session `b7869424`, pid 84597. My worktree `/Users/alex/ab/richos-wt/frank-fable-cert5`, branch `cc/frank-fable-cert5`, cut from `1c58c017`.
**Method:** read every line of the round-15 engine diff (`worktree-ledger.py` — `_lock_entities`, `_judge_registration`, `_join_prepared_rows`, `terminations`, `retractions`, `_cmd_retract`; `record-canary.sh`; both runners' diffs; the four lifecycle writers; `worktree-transactions.py`, `daily-workspace-cleanup.py`, `restart-after-terminal-measure.py`, `land-completeness.py`; every new test and mutant); read the round-15 record as a claim and re-derived every number I relied on; read the live record from the outside before and after (ledger, fallback log, teams, transactions, the retirement journal); judged the live trees read-only at this tip; ran seven scratch experiments in sandboxes (own ledger, own transaction store, throwaway `CLAUDE_CONFIG_DIR`, a seeded COPY of the operator's record); ran 51 suite processes in the foreground, one per call, every one inside its own timeout, with the real record witnessed per run by the round's own canary (§5); and read the CI runs at `32f8567a` (both attempts) and at `1c58c017` by run id. Every number carries the command that produced it or the word `unverified:`.

## 1. The verdict in one paragraph

Every one of my six round-four conditions is closed in the code, and each closure re-derives from something the fixer did not make: the lock is resolved in every repository that can hold the shell and `sage-fable-cert3` now reads ALIVE from its lock with either entity while the retracted row sits beside its retraction (§3); step 2b writes nothing (L06g, mutant `terminal-record-witness-persisted`); the retraction is honored by the judge, the reaper, adoption, the operator door and the measure; the two-row shape is joined and decided — three real trees, both entities (§3); the writers and the reader agree; the record is corrected. Forty-eight of my fifty-one local runs are green and none of mine touched the operator's record (§5). **It is not certified, for three things established from the outside.** First, **the tip's own CI does not certify it**: `engine-self-verify` run `34557992690` at `1c58c017` ends `✗ ci-receipts: this run does NOT certify 1c58c017…` with five red units — three of them the round's new record canary naming three suites that write the operator's ledger (`demo.test.sh`, `agent-state-claims.test.sh`, `contract-integrity.test.sh:base`), which I reproduced locally in CI's shape, all three (§2.D1); and two mutation harnesses in this exact area (`WTR1`, `WTI1`) that pass and fail on identical code across runs while the integrity suite discards their output, so nobody can say which mutant flipped (§2.D4). Second, **the operator's record is already majority fixture**: 355 of the 712 non-`finished` rows on `~/.claude/state/worktree-ledger.jsonl` and 10,659 of the 10,676 rows in the retirement journal are fixture rows written by engine suites between 2026-09-02 and 2026-09-10 — the record's sentence "no suite touches the operator's record" was measured over forty suites, and the class it names has been open for nine days across at least six writers (§2.D2). The canary the round adds is real and it is what caught this in CI; it is also **blind to every deletion** — a suite that empties the ledger, drops rows from it, empties the fallback log or removes a team directory passes it green, proven in a sandbox on all four shapes (§2.D3). The CEO's bar is "can't find any fuckshit anymore"; a shipping tip whose CI says it does not certify it, a ledger the CEO's screen is built from that is half fixtures, and a class-closing canary that cannot see a wipe are three. §6 says exactly what would change my answer.

## 2. Defects, most important first

Severity is mine. "Outside" = the live record, the machine or CI; "inside" = code or a sandbox.

### D1 — SEVERE. CI at the shipping tip is red and does not certify it: three true positives from the round's own canary, two undiagnosable harness failures

**Claim under test** (round-15 record §7): *"CI: I cannot push; `engine-self-verify` on the landed tip is the proof."*

**Established (outside).** `gh run view 34557992690 --repo WebDevBooster/richos --json status,conclusion,headSha` → `completed`, **`failure`**, `1c58c017…` (created 03:19:23Z, finished 03:45:54Z). Jobs: shards 1, 6, 8, 9, 11 and `coverage` failed. The receipts line, from `--log`: `✗ ci-receipts: this run does NOT certify 1c58c017420d23b5d0bddaac6ba01fbd097f462d.` The five red units:

```
scripts/demo.test.sh                                RECORD-TOUCHED (rc=0)
scripts/hooks/agent-state-claims.test.sh            RECORD-TOUCHED (rc=0)
scripts/hooks/contract-integrity.test.sh:base       RECORD-TOUCHED (rc=3)
scripts/hooks/contract-integrity.test.sh:WTI        FAIL (rc=1)   WTI1.staffing-gate-mutations-all-load-bearing (expected exit=0 got=1)   380.6 s
scripts/hooks/contract-integrity.test.sh:WTR        FAIL (rc=1)   WTR1.worktree-removal-mutations-all-load-bearing (expected exit=0 got=1)  44.5 s
```

The canary's rows in CI (`--log | grep APPEARED`): `agent-state-claims` — two `terminated` rows, witness `remove-agent-worktree`, agents `a2222222222222222` and `a3333333333333333`, and `ledger: was ABSENT and now EXISTS`; `demo` and `integrity:base` — two `registered` rows each, source `detect-nonnative-worktree.sh`, teammate `reed-sonnet-sc1`, agent `-`, ledger created. **Reproduced (inside), CI's shape** — a fresh empty `HOME` holding only `.gitconfig`, the canary sourced with `CLAUDE_CONFIG_DIR` pointed at it so the witness is exact (`scratchpad/r5/ci-shape.sh`, §5 rows marked CI-SHAPE): `agent-state-claims.test.sh` rc 0 in 6 s, RECORD-TOUCHED, the same two `terminated` rows plus a whole `state/workspace-retirement/` journal created; `demo.test.sh` rc 0 in 114 s, RECORD-TOUCHED, the same two `reed-sonnet-sc1` rows plus `reap-known-repos.txt`, `teammate-idle-events.jsonl`, `teammate-task-events.jsonl`; `contract-integrity.test.sh --only base` rc 3, RECORD-TOUCHED, the same two rows. All three are true positives: the canary is doing exactly what the round built it to do, and what it found is D2.

**The two harness failures are not reproduced here and cannot be diagnosed from CI.** `WTR1` in the last five CI runs: PASS 43.6 s (`2b8a235d`), PASS 44.6 s (`2cf3d7af`), PASS 43.3 s (`b43ca814`), PASS 31.5 s (`2d2f6cf1`), **FAIL 44.5 s** (`32f8567a` attempt 1 — docs-only on top of `2d2f6cf1`; `git diff --stat 2d2f6cf1 32f8567a -- engine/ .github/` is empty), PASS (attempt 2, `conclusion: success`), **FAIL 44.5 s** (`1c58c017`). `WTI1`: PASS 386.9 s at `2d2f6cf1`, **FAIL 380.6 s** at `1c58c017`. The walls of the failures equal the walls of the passes, so neither is a timeout: a mutant's verdict flipped. Locally at this tip: `guard-worktree-removal.mutation.sh` **8 of 8 green** (36–59 s: alone, five in a row under the load of my other suites, once in CI's shape; every run "all 14 mutants proven load-bearing"); `contract-integrity.test.sh --only WTR` rc 3 (scoped-and-green) in 68 s; `guard-worktree-isolation.mutation.sh` green once, 366 s, "23 proven load-bearing, 0 unproven". **Why it cannot be diagnosed:** `contract-integrity.test.sh` lines 2759 and 2971 run both harnesses `>/dev/null 2>&1` and emit only the rc; the pool keeps every mutant's output in `$MUT_POOL_DIR/<seq>.out` (`mutation-pool.sh:268`) and the integrity unit throws it away. A harness whose only surviving evidence is "1" will flip again and nobody will know why the second time either. This is in my area — the guard that refuses a worktree removal and the guard that refuses an un-isolated spawn — and it is the CEO's brief to me by name.

### D2 — SEVERE. The operator's record is majority fixture rows, written by engine suites for nine days, and the round's "no suite touches the operator's record" was measured over forty suites of ~220

**Claim under test** (round-15 record §0, §3): *"No suite of mine wrote a row"*; *"The class, closed at the runner"*; `record-canary.sh` header: *"three instances of one class in two days."*

**Established (outside), read-only, at this tip** (`scratchpad/r5/fixture-residue.py`: every non-`finished` ledger row whose `repo`/`worktree`/`cwd` is under `/var/folders/`, `/private/var/folders/`, `/tmp/` or whose agent id is `a<d>{16}`-shaped):

```
ledger rows (non-finished): 712   fixture-shaped: 355
  323  registered  detect-nonnative-worktree.sh  reed-sonnet-sc1        (demo.test.sh, contract-integrity.test.sh base)
   13  registered  detect-nonnative-worktree.sh  dev-sonnet-led1
   13  registered  detect-nonnative-worktree.sh  deadbeefcafe0001
    1  registered  detect-nonnative-worktree.sh  dev-sonnet-led2
    1  prepared    create-teammate-worktree.sh   victim-opus-v1
    1  terminated  reaper-observation            q4-dead-owner
    1  terminated  reaper-observation            q4-unmerged
    1  terminated  remove-agent-worktree         a2222222222222222      (agent-state-claims.test.sh)
    1  terminated  remove-agent-worktree         a3333333333333333      (agent-state-claims.test.sh)
first: 2026-09-02T09:10:26Z   last: 2026-09-10T19:39:38Z   written on 2026-09-11: 0
retirement journal ~/.claude/state/workspace-retirement/retirements.jsonl: 10,676 rows, fixture-shaped: 10,659
```

Half of the decisive rows on the ledger the CEO's screen is built from are fixtures; 99.8 % of the operator-door journal is. The `reed-sonnet-sc1` rows carry `repo=/var/folders/…/contract-integrity.XXXXXX.<rand>` and `richos-engine-demo.<rand>` — twenty-plus runs of the integrity suite and the demo suite on 2026-09-10 between 13:11Z and 19:39Z, each leaving two rows. The two `terminated` rows for `a2222…`/`a3333…` are dated 2026-09-02, witness `remove-agent-worktree` — the operator door's own copy (`workspace-retire.py:1866`) writing to `DEFAULT_PATH` because the suite never redirects `RICHOS_WORKTREE_LEDGER`. Nothing was written today because nobody ran those three suites with the real `HOME` today; the first CI run with the canary caught all three on the first pass (D1).

**Why it is a defect of this round and not only of the past.** My round-four condition 3 was *"No suite in the engine reads or writes the operator's `~/.claude/state/worktree-ledger.jsonl`, `~/.claude/worker-events.jsonl` or `~/.claude/teams/`"*. The fixer fixed the two suites in the area, added the canary, ran forty suites and wrote "the class, closed". The canary then proved the sentence false at the tip: three more writers, and by the record's own dating the class is not "three instances in two days" but at least six fixture writers since 2026-09-02 and 355 rows. Two consequences today: (a) `run-all-tests.sh` and every CI run at this tip are red on the operator's machine and in CI until those three suites are sandboxed — correct behavior, and it means the runner the CEO is shown is red at the shipping tip; (b) the residue is on the record and nothing in the round names it, so the next reviewer will find it again exactly as I did. The fixer's §0 counts are true (`46 / 1 / 0 / 250 / 9`); they were the wrong counts to prove the claim, because none of the 355 rows is a `terminated`, a fallback line or a team directory — they are `registered` rows on the ledger, which only a per-row comparison sees. **Also:** the retirement journal is a fourth durable record under `~/.claude/state` that the canary does not watch, and it is the worst-polluted of the four.

### D3 — MODERATE. The record canary is blind to every deletion

**Claim under test** (`record-canary.sh` `rc_escaped` docstring): *"every entry of the record that APPEARED or CHANGED since <baseline-file>"*; record §3: *"a change is RECORD-TOUCHED, red."*; test 4a: *"the witness is contents, not a line count."*

**Established (inside)** — `scratchpad/r5/canary-deletion.sh`, throwaway `CLAUDE_CONFIG_DIR`, output `canary-deletion.txt`:

```
A. one ledger row DELETED (the terminated row):   escaped=[]   GREEN
B. ledger TRUNCATED to empty:                       escaped=[]   GREEN
C. fallback log truncated to empty:                 escaped=[]   GREEN
D. a team directory REMOVED (rm -rf session-bbbbbbbb): escaped=[]   GREEN
E. control: a row APPENDED after all that:          ledger row APPEARED: event=terminated … agent=zz   (reported)
```

`rc_escaped` prints lines present in `after` and absent from `before`, then the present/absent transition of each whole path; a line present in `before` and absent from `after` is never printed, and a path emptied in place is still "present". The 13-case suite drives the detector onto three addition shapes and one in-place edit (which appears as a new hash) and never onto a removal. A suite that "resets" its ledger with `: > "${REAP_WORKTREE_LEDGER:-$HOME/.claude/state/worktree-ledger.jsonl}"` with the variable unset — the same env-var-unset mechanism that produced every addition in D2 — wipes 17,000 rows and the canary reports nothing. Contrast the escalations suite's 17n, which counts fixture rows, and the leak canary, which witnesses contents both ways. **Fix:** print `DISAPPEARED` entries symmetrically (the same set difference the other way), and drive the test onto all four shapes above.

### D4 — MODERATE. Two mutation harnesses in this area flip verdicts across CI runs on identical code, and the integrity suite discards the evidence

Detail in D1. The property the CEO's bar names — "a worktree-removal mutation harness gives different verdicts on identical code" — is established: `WTR1` red in 2 of the last 3 CI runs at 44.5 s each, green in the 5 before at 43–45 s, green 8 of 8 here; `WTI1` red at 380.6 s after green at 386.9 s. I could not reproduce either and I state that plainly: 8 + 1 local runs, three shapes (alone, under load, CI-shape empty `HOME`), all green. What I can establish is that the failure is **undiagnosable by construction**: both units are `>/dev/null 2>&1` in `contract-integrity.test.sh` (lines 2759, 2971), so CI's log holds the rc and nothing else. The pool already writes each mutant's `.out`, `.rc`, `.ms` and names a worker that "left no exit code (killed, OOM, or out of disk)" as a FAIL (`mutation-pool.sh:332–353`) — on a two-vCPU runner running eight mutants of a suite that itself spawns `sleep 120` processes (`guard-worktree-removal.test.sh:422, 534`), that is the shape I would look at first; I did not establish it. **Fix:** the two integrity units keep the harness output (a file under the unit's log dir, printed on failure, as `ci-shard.sh` prints a failing suite's log), and the flake is either explained by that output on its next red or the harness's pool width is pinned to the runner's cores. A harness that cannot say which mutant flipped is not proving what it says it proves.

### D5 — LOW. One reader of `terminated` rows does not honor a retraction

`land-completeness-measure.py` `ledger_index()` (lines 298–326) indexes every `terminated` row by agent id itself, and `OwnerLiveness.verdict_at()` (line 427) returns `NOT-ALIVE "witnessed termination at <ts>"` from it; no `retracted` row is read. Every other reader goes through `worktree-ledger.terminations()` — step 1, `record --once`, adoption's T3 (`worktree-adoption.py:453`), the operator door (`workspace-retire.py:1366, 1866`) — or honors it itself (`restart-after-terminal-measure.unlocked_witness_rows`, M13). The measure is a report, not a door (`land-residue-gate.py` names it as *"the measured rate he is being shown"*); on the live record the one retracted row is `ae904aac1949e5696` at `00:02:34Z`, so the measure would report that agent NOT-ALIVE at any instant after 00:02:34Z that the founder is shown. **Fix:** the measure's index skips rows a `retracted` row names — one set, as the measure's `--locks` already does — with a test.

### D6 — LOW, boundaries and observations. Not conditions of my key

- **A stale native repository holds forever.** `_lock_entities` adds every repository a native row of this agent names; `agent-liveness.resolve()` on a path that no longer exists returns INDETERMINATE (`git worktree list exited 128`), and "INDETERMINATE anywhere holds" (`scratchpad/r5/stale-repo.py`: `('INDETERMINATE', "git worktree list exited 128: fatal: cannot change to '…/repo-that-was-deleted'…")`). Before round 15 the same tree fell through to the session step. Fail-closed; stated in the docstring as the design ("a resolver failure is INDETERMINATE, never a fall-through"); the trees on this machine whose session repositories are gone (`claude-orchestration-kit-wt/`, `deeply-wt/`, both keys' round-four count) will now hold until a person looks.
- **A hand-appended `retracted` row is honored** (`retract-attack.sh` B: `printf` of a row with `source: anybody` → the observed termination no longer stands → INDETERMINATE). There is no writer allowlist on retraction as there is on binding (`row_may_bind_by_name`). The direction is safe — a retraction can only move a verdict away from NOT-ALIVE, and a hand can already append a `terminated` row that authorizes a removal, which is the more dangerous direction — so I state it rather than condition on it.
- **Two `terminated` rows with the same `ts` for one agent can never be retracted through the verb** (D: `matches: 2`, rc 2). Only a hand produces that shape; `append()` stamps `now_iso()` per row.
- **`platform_terminal_record()` still `exec_module`s the transaction library per call** while `_transactions_module()` caches it; cosmetic.

## 3. What held — re-derived by something that did not make it

**Condition 1 (D1 — 2b never appends; the entity join inside the judge).** Code: `_judge_registration` step 2 iterates `_lock_entities()` — native row's repo, every native registration of the id, the transaction's native member, the caller's entity — ALIVE anywhere returns, INDETERMINATE anywhere holds, observed writes `reaper-observation` as before; 2b reads `platform_terminal_record()` and returns, no `append` on that path (grep: the only `append` in the function is the observation at line 1249). Tests: L06e (both entities, write ON, line count unchanged), L06f/L06f′ (the manifest's member, and its unlocked control writing once), L06g/L06g′ (Frank's sequence: no row, then a post-terminal start → row 5's INDETERMINATE), L06h/L06h′; mutants `lock-resolved-in-callers-entity-only`, `terminal-record-witness-persisted`, `record-derived-witness-decides` killed (15 of 15, §5). **Live, read-only** (`scratchpad/r5/live-judge.py`, `write=False` on every call): `/Users/alex/ab/richos-wt/sage-fable-cert3` → both registrations ALIVE "LOCKED by running pid 84597", aggregate ALIVE, with entity richos (`lock entities: ['/Users/alex/ab/femcboost', '/Users/alex/ab/richos']`) and with entity femcboost; `standing terminations: []`, `retractions: {'2026-09-11T00:02:34.984941+00:00'}`, `platform_terminal_record: ('terminal', …)` — the record says terminal, the lock outranks it, and nothing is written. `reconcile-terminal-worktrees.py --preview` at this tip: both of Sage's workspaces `hold — … LOCKED and the locking pid 84597 is running`; `remove=0 branch-only=1 observe=0 hold=10 excluded=9 not-examined=4`. `agent-liveness.sh --entity femcboost ae904aac1949e5696` → ALIVE. `land-completeness.sh --repo richos` no longer lists `sage-fable-cert3` as incomplete (only `quarantined … 4` and the four Codex `unowned`).
**Condition 2 (the retraction, and the live row).** `terminations()` excludes rows whose exact `ts` a `retracted` row for the agent names; `retract` refuses unless exactly one row matches, prints what it voids, `--dry-run` writes nothing, a repeat is skipped (L06i/i′/j/j′; mutant `retraction-ignored`). The `record` verb cannot write a `retracted` row (`invalid choice: 'retracted'`, `retract-attack.sh` C). **Live:** `~/.claude/state/worktree-ledger.jsonl` holds exactly one `retracted` row, `ts 2026-09-11T03:19:31.158740+00:00`, `retracts_ts 2026-09-11T00:02:34.984941+00:00`, `retracts_witness platform-terminal-record`, `source round-15-record`, reason quoting the cause; the backup `worktree-ledger.jsonl.bak-r15-retract` exists (5,742,820 bytes); ledger `terminated` count 46 before and after the retraction (the row is superseded, not removed). **Attacked** (`retract-attack.sh`, own ledger): A — a TRUE observation retracted after the shell is gone → INDETERMINATE (session alive), never ALIVE ("ALIVE needs a held lock"); `record terminated --once` re-witnesses. E — retracted while the shell is still unlocked → the next write-enabled judge re-observes and writes a fresh row (6 → 7). So a retraction cannot resurrect a dead owner; it can only hand the question back to the live evidence. Readers: judge, reaper (`judge-batch`; `record --once` via `terminations`), adoption T3, operator door, measure `--locks` (M13) — all honor it; `agent-liveness.sh` does not read the ledger; `land-completeness-measure.py` does not honor it (D5).
**Condition 3 (the class; the two suites).** `record-canary.sh` is sourced by `run-all-tests.sh` and `ci-shard.sh`, baseline before every suite, `RECORD-TOUCHED` red with the rows printed, refused at rc 2 when missing; `ci-receipts.py` names `RECORD-TOUCHED` red. Tests 13/13, runner 19/19 (5a–5f), shard 25/25 (S15b). **It works on real suites:** it named the three writers in CI (D1) and named them again here in CI's shape. `session-start-stdin.test.sh` and `root-contract.test.sh` capture the real record's witness, move `HOME`, and name every reaper path explicitly; 9l/9m and 6c/6d pass. **My own both-arms proof against a seeded COPY of the operator's record** (`scratchpad/r5/seeded-home.sh`: a scratch `HOME` holding copies of the ledger, the fallback log, all nine team directories, the transaction store, the sessions directory and `.gitconfig`; the copy's counts compared before and after): stdin rc 0, 23 s, **copy unchanged**; root-contract rc 0, 97 s, **copy unchanged** — where round four's ARM 1 against a copy gained the `platform-terminal-record` row. The condition is met for the two suites and the runner, and not met as I wrote it ("no suite in the engine"): D2.
**Condition 4 (the two-row shape).** `_join_prepared_rows()` joins an id-less `prepared` row to the `registered` row's id on same session, same teammate, same exact path, both engine writers, exactly one id; L06k/k′/k″; mutant `prepared-row-never-joined`. **Live, read-only, four trees:** `sage-fable-cert3` → prepared row `joined=prepared` → ALIVE (lock); `frank-fable-cert4` and `zach-fable-fix4` (both reclaimed by the lane — `ls /Users/alex/ab/richos-wt/` shows neither; the preview shows zach's native shell `branch-only … workspace already gone`) → both rows NOT-ALIVE "platform terminal record", aggregate NOT-ALIVE, both entities; my own `frank-fable-cert5` → ALIVE. The "two authorities" case is decided on the real shape in the direction the design intends, and my D3 is closed.
**Condition 5 (writer/reader).** All four `worker-*-handoff.sh` return `None` from `resolve_team_dir()` for a known session with no directory (the fallback file); the single-directory guess survives only for a payload with no session id. `worker-lifecycle.test.sh` 9a (one foreign directory → fallback, foreign log untouched), **9a′ (the reader returns it)**, 9b control, 9c in the other three writers; 42/42.
**Condition 6 (the record).** The round-14 record carries the dated CORRECTION on Echo (the transaction's `SubagentStop 23:49:01.889703Z`, member removed 23:50:26Z) and a new §4a stating that its own 9b wrote the 00:02:34Z row, with the timing; the round-15 §7 is filled from `RESULTS.tsv` at `8a46024d`, forty rows, and my table reproduces every row (§5).
**Sage's three (re-derived for completeness):** S1 symlink `HEAD` under `refs/` is a store and S3's symlinked `objects/` target is collapsed too, both archived whole and restored (`test_git_store_shapes…`, mutants `symlink-HEAD-store-not-recognized`, `symlinked-objects-target-dropped`; the daily harness 36 of 36 here); the boundary (a target outside the worktree, `alternates`) is in the table's §3 and §4; a non-UTF-8 line is skipped in both readers (`…non_UTF8_line…`, M12, mutant `non-utf8-fallback-line-raises`). The cleanup-routing signature carries `_lock_entities` (class, path) and the contract suite is 14 + 9/9.
**The lane, live:** zach-fable-fix4's cross-repository tree reclaimed after its 03:18:03Z terminal record and before my 03:22Z start; frank-fable-cert4's likewise after 01:36:42Z; Sage's two workspaces HOLD on the lock; the reap-stale suite 54 + 6/6.

## 4. What the record said and the machine answered

| Record's claim | Command | Answer at `1c58c017` |
|---|---|---|
| `engine-self-verify` on the landed tip is the proof | `gh run view 34557992690 --json conclusion` | **`failure`** — `✗ ci-receipts: this run does NOT certify 1c58c017…`; 5 red units (D1) |
| No suite touches the operator's record; the class is closed at the runner | CI's canary; `ci-shape.sh` on the three named suites; `fixture-residue.py` on the real ledger | **FALSE as a sentence, TRUE as a mechanism** — three suites write it (reproduced), and 355 fixture rows / 10,659 journal rows are already there (D2) |
| Any suite that changes the ledger, fallback log or team directories fails | `canary-deletion.sh` | **FALSE for deletions** — four shapes green (D3) |
| `sage-fable-cert3`: ALIVE with either entity, the lock outranks the record | `live-judge.py`, `--preview`, `agent-liveness.sh` | TRUE — ALIVE both entities; preview HOLD on the lock; the retraction stands beside the row |
| `retracted` rows: 0 before / 0 after the round; Rich runs the command after the land | `record-baseline.py` | 1 `retracted` row at 03:19:31Z, source `round-15-record`; backup present; `terminated` 46 → 46 |
| 17,354 / 46 / 1 / 250 / 9 → 17,424 / 46 / 1 / 0 / 250 / 9 | `record-baseline.py` at 03:23:09Z and 04:28:42Z | 17,439 / 46 / 1 / 1 / 250 / 9 → 17,517 / 46 / 1 / 1 / 250 / 9; the 78 new rows are all `finished`/`worker-ended-handoff.sh` (the platform, not me) |
| 40 runs, 40 exit 0 at `8a46024d` | my 51 runs (§5) | reproduces for every suite I re-ran (48 green + 3 CI-shape true positives) |
| L06e–L06k″, 15/15 mutants | `worktree-ledger.test.sh` | 71 PASS lines + 15/15, 29 s |
| "three instances of one class in two days" | `fixture-residue.py` | at least six fixture writers since 2026-09-02 (D2) |
| 76 of 76 helper-made trees held INDETERMINATE by the two-row shape (round four) | `live-judge.py` on four trees | decided now: 2 NOT-ALIVE from the record, 2 ALIVE from the lock |

## 5. Suites run at this tip — 51 processes, foreground, one per call, logs in `certification-frank-round5-suite-logs-2026-09-11/` (`RESULTS.tsv` is the row-per-run record)

Every row is one process run through `scratchpad/r5/run-suite.sh` (rc from the process, wall from `date +%s` around it), `HOME` moved to a scratch home seeded with the operator's `.gitconfig`, and **the real record witnessed before and after each run by the round's own `record-canary.sh` sourced with the real paths** (`healthy=1` on every row; `record-untouched` on every row of mine). The three heavy harnesses ran alone, one per call; the rest in small parallel groups on a machine shared with the other key's runs, so walls are upper bounds. Rows marked SEEDED-COPY-HOME ran with `HOME` = a copy of the operator's record (`seeded-home.sh`); rows marked CI-SHAPE ran with an empty `HOME` and the canary watching it (`ci-shape.sh`). Nothing was backgrounded; the longest call was 569 s inside a 600 s timeout.

| Suite | rc | wall | Note |
|---|---|---|---|
| `hooks/guard-worktree-removal.mutation.sh` (WTR1's harness) — run 1, alone | 0 | 36 s | 14 of 14 |
| same — runs 2–6, sequential, under load | 0 ×5 | 37 / 44 / 53 / 59 / 52 s | 14 of 14 each |
| same — CI-SHAPE (empty `HOME`) | 0 | 36 s | 14 of 14 |
| `hooks/contract-integrity.test.sh --only WTR` | 3 | 68 s | scoped-and-green (rc 3 is the suite's own "scoped" code) |
| `hooks/guard-worktree-isolation.mutation.sh` (WTI1's harness), alone | 0 | 366 s | 23 proven, 0 unproven |
| `lib/worktree-ledger.test.sh` | 0 | 29 s | 71 PASS + 15/15 (L06e–L06k″) |
| `lib/record-canary.test.sh` | 0 | 1 s | 13/13 |
| `run-all-tests.test.sh` | 0 | 2 s | 19/19 (5a–5f) |
| `ci-shard.test.sh` | 0 | 12 s | 25/25 (S15b) |
| `hooks/worker-lifecycle.test.sh` | 0 | 3 s | 42/42 (9a–9c) |
| `restart-after-terminal-measure.test.sh` | 0 | 2 s | 13 (M12, M13) |
| `daily-workspace-cleanup.test.sh` (unit, `RICHOS_MUTATION_INNER=1`) | 0 | 30 s | 67 |
| `land-completeness.test.sh` | 0 | 3 s | 18 |
| `cleanup-routing-contract.test.sh` | 0 | 26 s | 14 + 9/9 |
| `lib/worktree-transactions.test.sh` | 0 | 128 s | 70 + 25/25 |
| `lib/workspace-retire.test.sh` | 0 | 92 s | 54 passed, 2 not covered (stated), 428 assertions |
| `lib/worktree-adoption.test.sh` | 0 | 96 s | 43 + 15/15 |
| `hooks/guard-sealed-worktree.test.sh` | 0 | 72 s | 53 + 18/18 (G15) |
| `hooks/session-start-reap-worktrees.test.sh` | 0 | 25 s | 16 + 5/5 |
| `hooks/session-start-stdin.test.sh` — SEEDED-COPY-HOME | 0 | 23 s | 13; the copy unchanged; 9l/9m against the copy |
| `hooks/root-contract.test.sh` — SEEDED-COPY-HOME | 0 | 97 s | 29 + 11/11; the copy unchanged |
| `hooks/detect-nonnative-worktree.test.sh` | 0 | 61 s | + 7/7 |
| `hooks/terminalize-agent-worktrees.test.sh` | 0 | 81 s | 54 + 15/15 |
| `reconcile-terminal-worktrees.test.sh` (unit) | 0 | 54 s | 59 |
| `hooks/escalations.test.sh` | 0 | 9 s | 79 (17n/17o) |
| `lib/finish-row-completion.test.sh` | 0 | 6 s | 16 + 5/5 |
| `reap-stale-worktrees.test.sh` (alone) | 0 | 569 s | 54 + 6/6 |
| `daily-workspace-cleanup.mutation.sh` (alone) | 0 | 410 s | **36 of 36** |
| `reconcile-terminal-worktrees.mutation.sh` (alone) | 0 | 265 s | 30 of 30 |
| `lib/process-identity.test.sh` — this machine / CI shape forced | 0 / 0 | 4 / 3 s | 12 OK both |
| `hooks/hook-staleness.test.sh` | 0 | 8 s | 28/28 |
| `hooks/land-disposition.test.sh` | 0 | 9 s | 33 |
| `lib/completion-proof.test.sh` | 0 | 12 s | 25 |
| `hooks/record-subagent-start.test.sh` | 0 | 15 s | 14 + 6/6 |
| `hooks/stop-hook-visibility.test.sh` | 0 | 4 s | 40 |
| `hooks/guard-ci-red-lands.test.sh` | 0 | 20 s | 16 |
| `ci-run-record-check.test.sh` | 0 | 1 s | 14 |
| `lib/leak-canary.test.sh` | 0 | 1 s | 23 |
| `lib/global-state-witness.test.sh` | 0 | 5 s | 13 |
| `ci-units.test.sh` / `ci-affected-units.test.sh` | 0 / 0 | 13 / 13 s | 17 / 10 |
| `discard-workspace-backlog.test.py` | 0 | 3 s | 10 OK |
| `hooks/engine-status.test.sh` | 0 | 3 s | 16 |
| `hooks/agent-state-claims.test.sh` — CI-SHAPE | 0 | 6 s | 46 passed; **RECORD-TOUCHED**: 2 `terminated` rows (`a2222…`, `a3333…`, witness `remove-agent-worktree`), ledger created, retirement journal created (D1/D2) |
| `demo.test.sh` — CI-SHAPE | 0 | 114 s | 10 passed; **RECORD-TOUCHED**: 2 `registered` rows `reed-sonnet-sc1`, ledger created (D1/D2) |
| `hooks/contract-integrity.test.sh --only base` — CI-SHAPE | 3 | 110 s | scoped-and-green; **RECORD-TOUCHED**: 2 `registered` rows `reed-sonnet-sc1` (D1/D2) |
| **CI** `engine-self-verify` **34551424722** at `32f8567a` | — | — | attempt 1 `failure` (WTR1 only); attempt 2 **`success`** (re-dispatched, all 17 jobs green) |
| **CI** `engine-self-verify` **34557992690** at `1c58c017` | — | — | **`failure`** — 5 red units, `does NOT certify` (D1) |

Fifty-one local processes: 48 rc 0, two rc 3 that are the integrity suite's own scoped-and-green code, one rc 0 with three CI-shape runs flagged RECORD-TOUCHED (true positives). 235 mutants proven load-bearing. Not run: `contract-integrity.test.sh` in full (the brief scopes it; ~50 min), `by-reference.test.sh`, `create-teammate-worktree.test.sh`, `guard-worktree-isolation.test.sh` on its own, `guard-worktree-removal.test.sh` on its own, `inflight-ack-durability.test.sh`, and the ~170 suites outside this area — which is exactly where D2's three writers live, and why CI found them and the forty-suite pass did not. **The operator's record before and after my whole pass** (`real-record-baseline.txt` 03:23:09Z, `real-record-after.txt` 04:28:42Z): `terminated` 46 → 46, `platform-terminal-record` 1 → 1, `retracted` 1 → 1, `registered` 568 → 568, `prepared` 97 → 97, fallback 250 → 250 lines, teams 9 → 9, transactions 116 → 116; ledger lines 17,439 → 17,517, all 78 new rows `finished`/`worker-ended-handoff.sh` — the platform's hooks for my helper turns, not a write of mine.

## 6. What would have to be true for me to certify

Each stated so an engineer can act without asking me. All of them.

1. **D1.** An `engine-self-verify` run on the shipping tip whose receipts line certifies that SHA (`✓ ci-receipts: N/N planned unit(s) ran, all green, all at <sha>`), with no re-dispatch and no known-red entry for `WTR1`, `WTI1` or the three suites. The run id in the record.
2. **D2, the instances.** `demo.test.sh`, `agent-state-claims.test.sh` and `contract-integrity.test.sh` (the `base` section, and any other section that runs `detect-nonnative-worktree.sh` or the operator door) redirect the record — `HOME` or `RICHOS_WORKTREE_LEDGER` plus the retirement journal's root — and each carries both arms as 9l/9m do. Then `run-all-tests.sh` on a machine with a real `~/.claude` is green at the tip, and CI's canary is silent.
3. **D2, the residue.** The 355 fixture rows on the operator's ledger and the 10,659 in the retirement journal are dealt with on the record: either removed by the operator with the reason and the backup named (the ledger is append-only by design, so this is the operator's call, not the engine's), or stated in the round record with the count, the writers and the date range, so the next reviewer does not rediscover them. The canary's header sentence "three instances in two days" corrected to what `fixture-residue.py` measures.
4. **D2, the fourth path.** The record canary watches `~/.claude/state/workspace-retirement/retirements.jsonl` (the operator door's journal) beside the three paths it has, with a red test on a fixture retirement row.
5. **D3.** `rc_escaped` reports entries that DISAPPEARED as well as those that appeared (the symmetric set difference, plus an emptied-in-place path), and `record-canary.test.sh` drives it onto all four shapes in `canary-deletion.sh`: one row removed, the ledger emptied, the fallback emptied, a team directory removed.
6. **D4.** `WTR1` and `WTI1` in `contract-integrity.test.sh` keep their harness's output (written to a file under the unit's log directory and printed in full on any non-zero rc, as `ci-shard.sh` prints a failing suite's log), so the next red names the mutant and the reason. And either the next three CI runs at a tip carrying that change are green for both, or the flake is explained from that output and fixed.
7. **D5.** `land-completeness-measure.ledger_index()` skips a `terminated` row that a `retracted` row for the same agent names by exact `ts`, with a test.

D6 is not a condition of my key.

## 7. What I examined and what I did not

**Examined at `1c58c017`:** the full round-15 engine diff (`git diff 32f8567a 1c58c017 -- engine/`); `worktree-ledger.py` lines 200–470 (`row_may_bind_by_name`, `ledger_path`, `append`, `read_all`) and 895–1560 (`bound_members`, `_transactions_module`, `RECORD_DERIVED_WITNESSES`, `retractions`, `terminations`, `platform_terminal_record`, `_lock_entities`, `_judge_registration`, `_join_prepared_rows`, `judge`, `_cmd_record`, `_cmd_retract`, `_cmd_judge_batch`); `record-canary.sh` and its test in full; the `run-all-tests.sh` and `ci-shard.sh` diffs; `ci-receipts.py`; the four `worker-*-handoff.sh` diffs; `worktree-transactions.platform_lifecycle_after`; `daily-workspace-cleanup.git_store_roots`; `restart-after-terminal-measure.event_rows` / `unlocked_witness_rows`; `land-completeness._entities_for`; `land-completeness-measure.ledger_index` / `OwnerLiveness`; `land-residue-gate.py`'s use of the measure; `workspace-retire.py` 1295–1370 and 1855–1875; `worktree-adoption.py` 280–300 and 453; `agent-liveness.py` (`resolve`, no ledger read); `reap-stale-worktrees.sh` `record_terminated` and its callers; `contract-integrity.test.sh` lines 2740–2775 and 2950–2980 and its `--only` switch; the L06e–L06k″ test bodies and the five new mutants; the daily, lifecycle and measure test diffs; the round-14 record's correction and §4a; the decision table's diff; the round-15 record and its results file; every earlier verdict of both keys.

**Live record examined, read-only:** the ownership ledger (17,439 → 17,517 rows; every ownership, termination and retraction row for the six round-three/four/five trees and for the fixture shapes; every `retracted` and `platform-terminal-record` row); the fallback log (250); all nine team directories; the transaction store (116 files); the retirement journal (10,676 rows); `git worktree list` of richos through the engine's resolver; the reconciler preview; `land-completeness.sh --repo richos`; `agent-liveness.sh`; the process table for pid 84597; CI runs 34533162792, 34539881673, 34543861760, 34547178102, 34551424722 (both attempts) and 34557992690 by run id and log.

**Not examined:** the managed-image and sparse lanes beyond their reconciler cases; `guard-resume-isolation.sh` (unchanged); the full `contract-integrity.test.sh` pass; `by-reference.test.sh`; the ~170 suites outside this area beyond the three CI named; who ran the twenty-plus integrity/demo passes on 2026-09-10 that left the `reed-sonnet-sc1` rows (the dates and paths are on the record; the actor is not); why `WTR1`/`WTI1` flip in CI (not reproduced; D4 says what would let the next person know). I spawned nothing, merged nothing, pushed nothing, and changed no live workspace, ledger, transaction store or registry: every judge call was `write=False`; every reaper run pointed at a copy or an empty scratch home; every experiment built and deleted its own sandbox or wrote only under the session scratchpad; the real record's decisive counts are identical before and after (§5, last paragraph). The retraction on the live ledger was the coordinator's, before my dispatch, and I read it rather than wrote it.

## 8. Reproduction pointers (all under the session scratchpad `r5/`, copied to the logs directory beside this file)

- D1: `gh run view 34557992690 --repo WebDevBooster/richos --log | grep -E 'FAIL|ci-receipts|APPEARED'`; `ci-shape.sh <label> <suite>` → `suites/<label>.log`, `.ci-record-before.txt`, the `RESULTS.tsv` rows marked CI-SHAPE.
- D2: `fixture-residue.py` → `fixture-residue.txt`; `live-rows.py reed-sonnet-sc1 a2222222222222222 a3333333333333333` → `fixture-residue-on-real-ledger.txt`.
- D3: `canary-deletion.sh <richos-worktree>` → `canary-deletion.txt`.
- D4: `wtr-repeat.sh 5`; `run-suite.sh wti-run1 scripts/hooks/guard-worktree-isolation.mutation.sh`; CI walls from `gh run view <id> --log | grep 'contract-integrity.test.sh:WT[IR] '`.
- D5: `sed -n 298,326p engine/scripts/land-completeness-measure.py`; line 427.
- D6: `stale-repo.py` → `stale-repo.txt`; `retract-attack.sh` → `retract-attack.txt` (A–E).
- §3 live: `live-judge.py <engine/scripts> <tree>…` → `live-judge.txt`; `preview-at-1c58c017.txt`; `land-completeness-richos.txt`; `seeded-home.sh` → `suites/*-seeded.copy-before.txt` / `.copy-after.txt`.
- The record: `record-baseline.py` → `real-record-baseline.txt` (03:23:09Z), `real-record-after.txt` (04:28:42Z).
