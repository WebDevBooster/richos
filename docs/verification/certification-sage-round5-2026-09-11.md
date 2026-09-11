NOT CERTIFIED

# Certification review, round five — richos main `1c58c017` — Sage, 2026-09-11

**Reviewer:** Sage (software architect), on Fable, by the CEO's order, round five. **Reviewed:** the ten
commits of `cc/zach-fable-fix4` (round 15) merged at `1c58c017420d23b5d0bddaac6ba01fbd097f462d`
(`git log --oneline 32f8567a..1c58c017 --no-merges`; 27 engine files, +1,620/−85), the round-15 record
`docs/verification/reclaim-round-15-zach-fable-fix4-2026-09-11.md`, the live state of this machine from
03:22Z to 04:30Z, the tip's own CI run, and the suites — 30 runs in the foreground, one process per row,
every call inside its own timeout (section 5). **Independence:** I read every earlier verdict of both keys
including both round-four verdicts and both §6 lists; I have not read, sought or received Frank's round-five
verdict. One thing to declare: the session scratchpad is shared between the two keys, and his runner script
overwrote mine at `scratchpad/r5/run-suite.sh` mid-review; the harness showed me its diff as a file-change
notice (a runner, not a finding), and I moved every file of mine to `scratchpad/sage-r5/` and read nothing
else of his. **Platform:** Claude Code 2.1.268; the session pid is 84597.

The verdict is the first line. Nothing below softens it into a score.

---

## 1. Why, in one paragraph

Round 15 closed my three round-four conditions, and each closure re-derives from the outside: the judge now
says ALIVE for `sage-fable-cert3` under either entity on the live ledger, on a copy with the retraction
removed, and on a copy with the round-14 row gone — the lock outranks the record whatever the caller passes
(D-A, section 2); the four store shapes are collapsed and archived whole with zero object files dropped under
my own round-four script (D-B); and a non-UTF-8 line in the fallback no longer raises out of
`running_after_terminal` (D-C). The retraction the coordinator ran reads the way the design says: zero
standing `terminated` rows for that agent. It is not certified because **the tip's own CI does not certify
it** — `✗ ci-receipts: this run does NOT certify 1c58c017…; 6 unit(s) did not reach a green verdict` — and
three of those six are the class this round claims closed: on the record canary's **first** full run it named
**three more suites** that write into the operator's ledger (`demo.test.sh`, `agent-state-claims.test.sh`,
`contract-integrity.test.sh:base`), and the operator's real ledger carries **323 `registered` rows for a
fixture teammate and two `terminated` rows for fixture agent ids** from exactly those suites, the newest from
2026-09-10 (D-1). The mechanism is a path split the round did not see: `worktree-ledger.DEFAULT_PATH` is
built from `~`, while the canary and the suites' redirects honor `CLAUDE_CONFIG_DIR`. The record's "forty
runs, forty exit 0" never ran the runner that carries the canary. Beside that: the canary is **blind to
deletion** — a row deleted, a ledger truncated to zero bytes, a team directory removed, all pass it with empty
output (D-2); a **known-red row** for `worktree-ledger.test.sh` was left in place after the round fixed the
very mutant it names, so CI fails by the table's own first rule (D-3); and the two mutation-harness units
`WTR1` and `WTI1` are red in CI at this tip with their output **discarded** by the unit, green on this machine
seven times out of seven — a failure nobody can read (D-4). None of it loses bytes. All of it is the record
saying one thing and the machine another, which is the standard both keys have held this work to since
round one.

---

## 2. My three round-four conditions, each re-derived by something other than the fixer's record

**C1 / D-A — step 2b against a held lock, wrong entity: CLOSED.** Code read (`worktree-ledger.py` diff,
+338/−…): step 1 filters `RECORD_DERIVED_WITNESSES` and retracted rows; step 2 iterates `_lock_entities`
(native row's repo → every native registration of the id → the transaction's native member → the caller's
entity); 2b reads `platform_terminal_record()` and never appends. **Live, read-only** (`sage-r5/live_case.py`,
output `live_case.out`), `sage-fable-cert3`'s tree, `write=False`, on three ledger views:

```
LIVE (17,447 rows):    prepared(joined→ae904aac) richos ALIVE | femcboost ALIVE ; registered richos ALIVE | femcboost ALIVE ; AGGREGATE ALIVE (both)
retraction removed:    same — ALIVE everywhere
row + retraction gone: same — ALIVE everywhere
_lock_entities(ae904aac1949e5696) -> ['/Users/alex/ab/femcboost', '/Users/alex/ab/richos']
```

`live_v7_v4.py`: the round-14 row is the only `terminated` row on the machine whose agent's shell is LOCKED
by a running pid, and it is `standing=False` (retracted). **Synthetic** (`sage-r5/entity_r5.py`, two temp
repositories per case, temp ledger and store, deleted after; `entity_r5.out`): V1 shell LOCKED in A, judged
with entity B and with A, `write=True` → ALIVE, ALIVE, rows appended `[]`; V2 no native ledger row → ALIVE;
V3 member without `repo`, standard shell shape → ALIVE; V5 shell UNLOCKED → NOT-ALIVE "OBSERVED now" with
exactly one `reaper-observation` row (the lookup through the manifest is real); V6 the round-14 row's shape
beside a LOCKED shell → ALIVE; V12 the native row naming A through a symlink → ALIVE. The ledger suite: 56
cases, 15/15 mutants (L06e–L06k″), 28 s.

**C2 / D-B — S1 symlink `HEAD` and S3 symlinked `objects`: CLOSED.** My round-four script re-run unchanged
against the round-15 module (`sage-r5/bare_shapes_r5.py`, lane binary git 2.50.1, temp tree deleted):

```
S1 symlink-HEAD bare store   git opens it: True  collapsed: True   object files dropped: 0  archived: 8 | HEAD/refs/config dropped: 0
S2 sha256 bare store         git opens it: True  collapsed: True   dropped: 0  archived: 8
S3 objects symlinked         git opens it: True  collapsed: True   object files dropped: 0  archived: 9
S4 separate-git-dir          git opens it: True  collapsed: True   dropped: 0  archived: 8
git worktree remove rc=0  exists after=False
```

Round four printed `S1 … collapsed: False … HEAD/refs/config dropped: 3` and `S3 … object files dropped: 3`.
The table states the boundary (target outside the worktree; `objects/info/alternates`). Harness alone: 36 of 36.

**C3 / D-C — non-UTF-8 in the fallback: CLOSED.** `sage-r5/fallback_robust_r5.py`: case C (invalid UTF-8 row)
returns the two valid events instead of raising; case E `running_after_terminal` with the bad byte → `False`
(round four: `RAISED UnicodeDecodeError`). Code read: bytes, decoded per line, `UnicodeDecodeError` skipped;
the measure's `event_rows` likewise (M12 green).

**Frank's six, as far as they touched what I ran** (his key, not mine): 1 and 2 closed as above; 3 — the
two suites redirect (`session-start-stdin` 13/13 with 9l/9m, `root-contract` 29 + 11/11 with 6c/6d, both
under my runner's witness of the real record) and the canary is wired in both runners and works (CI proved it
by firing) — but the class is not closed (D-1) and the canary's witness is one-directional (D-2); 4 — the
join: 77 of 97 id-less `prepared` rows on the live ledger join, 18 have no `registered` row at all, 2 face only
a `rich-land-binding` row and stay id-less by design, 0 (session, teammate, path) keys carry two ids
(`join_live.py`, `odd_rows.py`); V8/V9/V10/V11/V11b in `entity_r5.out` — the two-row shape decides NOT-ALIVE
on a terminal record, INDETERMINATE on an open one, and never joins across ids, sessions or a trailing-space
name; 5 — `worker-lifecycle.test.sh` 42/42 and the writer diff read (a known session with no directory returns
`None` → the fallback); 6 — round-14 record §4a present (`grep -n '^### 4a'`).

---

## 3. Defects, most important first

Severity is mine. "Outside" = the live record, the machine or CI; "inside" = code or a scratch sandbox.

### D-1 — SEVERE. The tip's CI does not certify it; three more suites write the operator's ledger, and the operator's ledger already carries 325 of their rows

**Claim under test.** Round-15 record §3: *"The class, closed at the runner"*; §7: *"Forty runs, forty exit
0 … CI: I cannot push; engine-self-verify on the landed tip is the proof."*

**Established (outside), CI.** `engine-self-verify` run **34557992690** at `1c58c017` (push, created 03:19:23Z,
completed 03:45Z): `conclusion: failure`; shards 1, 6, 8, 9, 11 and `coverage` red. The coverage job's own
summary (`gh run view --job 103139583190 --log`):

```
✗ ci-receipts: this run does NOT certify 1c58c017420d23b5d0bddaac6ba01fbd097f462d.
  - 6 unit(s) did not reach a green verdict:
    scripts/demo.test.sh                               RECORD-TOUCHED (rc=0)
    scripts/hooks/agent-state-claims.test.sh           RECORD-TOUCHED (rc=0)
    scripts/hooks/contract-integrity.test.sh:WTI       FAIL (rc=1)
    scripts/hooks/contract-integrity.test.sh:WTR       FAIL (rc=1)
    scripts/hooks/contract-integrity.test.sh:base      RECORD-TOUCHED (rc=3)
    scripts/lib/worktree-ledger.test.sh                KNOWN-RED-BUT-PASSED (rc=0)
```

The three `RECORD-TOUCHED` rows, from the shard logs (jobs 103136150519, 103136150563, 103136150594):
`agent-state-claims.test.sh` → `ledger row APPEARED: event=terminated witness=remove-agent-worktree
agent=a2222222222222222` and `…a3333333333333333`, `ledger: was ABSENT and now EXISTS`; `demo.test.sh` and
`contract-integrity.test.sh:base` → `ledger row APPEARED: event=registered source=detect-nonnative-worktree.sh
teammate=reed-sonnet-sc1 agent=-` (two rows each), `ledger: was ABSENT and now EXISTS`. In CI the paths did not
exist, so the witness is exact: the suites created the operator-path ledger and wrote into it.

**Established (outside), the operator's live ledger, read-only** (`grep -c` on
`~/.claude/state/worktree-ledger.jsonl`, classified by a python over the matches):

```
a2222222222222222  1 row   terminated / remove-agent-worktree  2026-09-02T09:12:40Z  worktree=/private/var/folders/…/T/agent-state-claims.XXXXXX.KawW18vcSd/entity/.claude/worktrees/agent-a2222222222222222
a3333333333333333  1 row   terminated / remove-agent-worktree  2026-09-02T09:12:40Z  (same temp entity)
reed-sonnet-sc1    323 rows  registered / detect-nonnative-worktree.sh, agent_id "", worktree ""   first 2026-09-02T09:10:30Z  last 2026-09-10T19:39:38Z
```

So the class the round closed "at the runner" has three more members, one of them writing to the operator's
record on nine days out of the last ten, and the record it wrote to is the one every door consults. The
`--once` rule kept the two fake terminations to one row each; nothing kept the 323. They decide no verdict today
(`registrations()` matches an exact non-empty path, and the fake ids own nothing) — and they are 325 rows on the
CEO's record that the platform did not write, which is exactly the thing D4, F3 and the canary were for.

**Mechanism (inside).** `worktree-ledger.py:183 DEFAULT_PATH = os.path.join(os.path.expanduser("~"), ".claude",
"state", "worktree-ledger.jsonl")` — `~`, read once at import; `ledger_path()` honors only
`RICHOS_WORKTREE_LEDGER`. The canary watches `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`; `contract-integrity.test.sh`
redirects `CLAUDE_CONFIG_DIR` to a temp dir (line 209) and `demo.test.sh` says it does the same (line 97); neither
sets `RICHOS_WORKTREE_LEDGER` or moves `HOME`, so the hook they run writes the ledger under the real home. Which
step of `demo.test.sh` runs the hook I did not trace (`unverified:` the step; the rows and the canary's naming are
the evidence). `agent-state-claims.test.sh` runs the remover, which records through the same default.

**Why it is not a loss path and why it is a defect anyway.** No workspace is touched by these rows. The defect is
the claim: a round whose headline is "no suite touches the operator's record" shipped with its own CI red on
three suites doing that, because the forty local runs did not include the runner the canary lives in, and the
fixer's proof was "CI on the landed tip" — which says NOT certified. The canary did its job on day one. The
round's record did not wait for it.

### D-2 — MODERATE. The record canary is blind to deletion

**Claim under test.** `run-all-tests.sh` header (round 15): *"fails the suite that changes them"*; record §3:
*"a change is `RECORD-TOUCHED`, red"*. `rc_escaped`'s own docstring is narrower: *"every entry … that APPEARED or
CHANGED"*.

**Established (inside)** (`sage-r5/canary_probe.sh`, `CLAUDE_CONFIG_DIR` pointed at a temp dir, eighteen shapes,
`canary_probe.out`):

```
SEEN     P1 append a terminated row                  NOT SEEN P3 DELETE the terminated row (rewrite without it)
NOT SEEN P2 append a finished row (stated)           NOT SEEN P4 TRUNCATE the ledger to zero bytes
SEEN     P5 rewrite one row in place                 NOT SEEN P7 DELETE a fallback line
SEEN     P6 append a fallback line                   NOT SEEN P9 DELETE a team directory
SEEN     P8 create a team directory                  NOT SEEN P17 append an exact DUPLICATE of an existing row
SEEN     P10 create a file in a team directory       NOT SEEN P18 remove a team log file
SEEN     P13 symlink to a DIFFERENT file             NOT SEEN P12 symlink to an identical copy (same bytes — acceptable)
SEEN     P14 remove the ledger entirely              SEEN     P15 remove the teams directory entirely
SEEN     P16 chmod 000 → UNREADABLE
```

`rc_escaped` prints lines in `after` not in `before`, then handles whole-path presence; an entry that was in the
baseline and is gone is never printed. So the most destructive member of the class — a fixture cleanup trap doing
`rm -rf "$TEAMS/session-$SID"` or `: > "$LEDGER"` against a real path — passes the canary silently, while the
fixer's `record-canary.test.sh` (13/13) has no deletion case. **Fix:** report `before − after` as `DISAPPEARED`
(same three kinds), with four suite cases (row deleted, ledger truncated, team directory removed, team log
removed); the runners consume `rc_escaped` and need no change.

### D-3 — MODERATE. The known-red row the round made false was left in the table

`lib/ci-known-red.tsv` carries one row: `scripts/lib/worktree-ledger.test.sh 2026-09-10 → 2026-09-24 … the
bound-members-fallback mutant (L28 expected red, L29 goes red instead) … RED ONLY ON git >= 2.55`. The round-15
record §1 says, of that very mutant: *"the substitute called `read_all()` with no path … Under a redirected HOME
it read nothing, L28 stayed green and the red moved to L29 … The substitute is now a constant registration-shaped
row (commit `05086a17`)"* — the fixer found the cause the table's author could not, fixed it, and did not delete
the row. CI at the tip, shard 1: `scripts/lib/worktree-ledger.test.sh FAIL 45.2s — declared red, but it PASSED …
The defect is fixed; DELETE the entry.` The table's own rule 1, doing exactly what its header promises. One line
to delete, and a sentence in the round record.

### D-4 — MODERATE. Two mutation-harness units are red in CI with their output thrown away

`contract-integrity.test.sh:2759` runs `guard-worktree-removal.mutation.sh >/dev/null 2>&1` and emits WTR1 from
the exit code; line 2972 does the same for the staffing-gate harness (WTI1). CI history, same code in
`engine/` throughout (`git diff --stat 2d2f6cf1 32f8567a -- engine/` is empty; round 15 touches neither guard,
neither harness, nor `mutation-pool.sh`):

| Run | SHA | WTR1 | WTI1 |
|---|---|---|---|
| 34547178102 | `2d2f6cf1` | PASS 31.5 s | PASS 386.9 s |
| 34551424722 attempt 1 | `32f8567a` | **FAIL** 44.5 s | PASS 241.1 s |
| 34551424722 attempt 2 | `32f8567a` | PASS 45.1 s | PASS 241.1 s |
| 34557992690 | `1c58c017` | **FAIL** 44.5 s | **FAIL** 380.6 s |

On this machine: `guard-worktree-removal.mutation.sh` 14 of 14 three times alone and once beside the ledger
suite (35, 35, 38 s) plus `--only WTR` rc 3 (scoped-and-green, 40 s); `guard-worktree-isolation.mutation.sh` 23
of 23 twice alone (297 s, 362 s). So WTR1 is red in 2 of its last 4 CI runs and WTI1 in 1 of 3, at identical
code, never here — and because the unit discards the harness's stdout and stderr, the failing mutant, or the
pool's `NO RESULT`, or an `ALREADY RED` baseline, is unknowable from the record. These are the harnesses for the
two guards that stand between an agent and a destructive removal or an unisolated spawn; a red that cannot be
read is either a real regression nobody can see or a flake that will be waived. Since round 14 the land gate
reads CI (`guard-ci-red-lands`), so this is now on the path of every land. I did not diagnose the cause (no
output exists to diagnose from; `ci-shard.sh` has no per-unit timeout; the pool has no per-mutant timeout;
`guard-worktree-removal.test.sh` H1 forks a `sleep 120` per suite run and H2 treats pid 999999 as dead — both
plausible on a 4-core Linux runner under a 4-wide pool, neither established). **Fix:** capture each harness's
output to a file and print it on failure, as `ci-shard.sh` already does for the unit; then a green run at the
reviewed SHA, or the cause named and fixed.

### D-5 — LOW, boundaries. Two shapes the judge reads as the record decides

- **V7** (`entity_r5.out`): a `reaper-observation` row on the ledger, and the same shell LOCKED by a running pid
  now → step 1 returns NOT-ALIVE while `resolve(A)` says ALIVE. This is the documented order ("a row of the
  ledger's own kinds still decides at step 1", table row added this round) and it needs an unlock followed by a
  re-lock of the same shell within a session, which the measure has never observed ((b) 0 of 1). Live: 0 standing
  rows of any ledger-own kind contradict a held lock (`live_v7_v4.py`). Stated; not a condition. The one-line
  improvement is to let a lock held by a running pid win before step 1.
- **V4**: a transaction whose native member has no `repo` AND a non-standard shell path AND no native ledger
  row → `_lock_entities` holds only the caller's entity and 2b decides on the record. Live: 0 native members
  without `repo`, 0 non-standard paths across 116 transactions, 0 of 77 hand-rolled ids without a native ledger
  row. Three absences the engine never produces. Stated; not a condition.

---

## 4. What the record said and the machine answered

| Record's claim | Command | Answer at `1c58c017` |
|---|---|---|
| The lock outranks the record, whichever entity is passed | `live_case.py`; `entity_r5.py` V1–V3, V6, V12 | TRUE — ALIVE in every view and shape, zero rows written |
| The class is closed at the runner; forty runs, forty exit 0 | `gh run view 34557992690 --json …`; coverage job log | **FALSE as a closure** — the tip's CI is red on three `RECORD-TOUCHED` suites; the forty runs did not go through the runner |
| No suite touches the operator's record | `grep -c reed-sonnet-sc1 ~/.claude/state/worktree-ledger.jsonl` → 323; `a2222222222222222` → 1; `a3333333333333333` → 1 | **FALSE on the live ledger** — 325 fixture rows, newest 2026-09-10T19:39Z |
| A change to the three paths is `RECORD-TOUCHED` | `canary_probe.sh` | TRUE for additions and edits; **FALSE for deletions** (P3, P4, P7, P9, P17, P18) |
| `bound-members-fallback` made self-contained | CI shard 1: `worktree-ledger.test.sh — declared red, but it PASSED` | TRUE, and the known-red row that said otherwise was left in |
| CI on the landed tip is the proof | `✗ ci-receipts: this run does NOT certify 1c58c017…` | the proof says NOT |
| S1 and S3 collapsed and archived whole | `bare_shapes_r5.py` | TRUE — 0 object files dropped in all four shapes |
| Non-UTF-8 fallback line skipped | `fallback_robust_r5.py` | TRUE — no raise, `running_after_terminal → False` |
| The join decides helper-made trees | `join_live.py` | 77 of 97 join; 18 have no `registered` row; 2 face a `rich-land-binding` row only; 0 ambiguous |
| The retraction is honored | `live_v7_v4.py` (`standing=False`), `live_case.py` | TRUE |
| The operator's record untouched during the round | §0 counts vs. my baseline | the counts named are unchanged; the 323 rows predate the round and were never counted |

---

## 5. What I examined and what I did not — including the suites, run

**Examined in full (diff or file):** `worktree-ledger.py` (the whole diff: `_TX_MODULE`, `RECORD_DERIVED_WITNESSES`,
`retractions`, `terminations`, `platform_terminal_record` docstring, `_lock_entities`, `_judge_registration`,
`_join_prepared_rows`, `judge`, `_cmd_retract`, the CLI), `record-canary.sh` in full, the canary wiring diff in
`run-all-tests.sh` and `ci-shard.sh`, the `session-start-stdin` and `root-contract` diffs, one lifecycle writer's
diff (`worker-ended-handoff.sh`; the other three are stated identical and `worker-lifecycle` 9c covers them),
`daily-workspace-cleanup.py` (`git_store_roots`), `worktree-transactions.py` (`platform_lifecycle_after`),
`land-completeness.py` (`_entities_for` docstring; `_judge_owner` passes `write=False`), `ci-receipts.py`,
`reclaim-decision-table.md` diff, `ci-known-red.tsv`, `registrations()`, `row_may_bind_by_name`,
`BINDING_LEDGER_WRITERS`, `DEFAULT_PATH`, the WTR1/WTI1 sections and `--only` handling of
`contract-integrity.test.sh`, `guard-worktree-removal.mutation.sh` lines 1–200 and 380–434,
`guard-worktree-removal.test.sh` lines 60–140 and 320–450, `mutation-pool.sh` (grep for ceilings), the round-15
record, both round-four verdicts and both §6 lists, the round-14 record's §4a.

**Live record examined (read-only):** the ownership ledger (17,436 rows at 03:22:10Z → see A6), the fallback
event log (250), the teams directory (9), the transaction store (860 files; 116 transactions parsed), the lock
file of `agent-ae904aac1949e5696`, the process table for pid 84597, the `.bak-r15-retract` backup's presence,
four CI runs and seven job logs. Every judge call was `write=False` except the synthetic ones against temp
ledgers; every experiment built and deleted its own sandbox; the canary probe pointed `CLAUDE_CONFIG_DIR` at a
temp dir. I spawned nothing, merged nothing, pushed nothing, and changed no live workspace, ledger, transaction
store or registry. My runner (`sage-r5/sage-run.sh`) sourced the engine's own `record-canary.sh` against the REAL
config before moving `HOME`, so every "record-untouched" below is the negative arm on the operator's record, not
on a sandbox.

**Not examined:** the `managed-workspace-*` and `shell-worktree-sparse` lanes; `contract-integrity.test.sh`
beyond `--only WTR`; `by-reference.test.sh`; `create-teammate-worktree.test.sh`, `guard-worktree-isolation.test.sh`
(its harness ran), `guard-worktree-removal.test.sh` (its harness ran); `demo.test.sh` and
`agent-state-claims.test.sh` beyond CI's naming and the live rows; the ~170 suites outside section 5a; the cause
of the WTR1/WTI1 CI reds (no output exists); `land-completeness.sh --repo richos` live (the fixer's D3 evidence
— I used `judge()` directly instead); a real-`HOME` run of the two redirecting suites (my runner's real-record
witness covers the negative arm for every run, and 9l/6c prove the redirect).

### 5a. Suites — run at `1c58c017` (worktree HEAD `15b872c3`+, docs only on top), foreground, one process per row

`certification-sage-round5-suite-results.txt` beside this file is the runner's row per process (UTC start, rc,
wall, HEAD, home, canary verdict on the REAL record, healthy flag, label), appended as each run ended; its first
four rows predate the canary columns. `HOME` was a scratch home for every row; the heavy harnesses ran alone,
one per call; the rest in small sequential batches, some beside another key's runs, so walls are upper bounds.

| Suite | rc | wall | Note |
|---|---|---|---|
| `hooks/guard-worktree-removal.mutation.sh` ×3 (alone, alone, beside the ledger suite) | 0, 0, 0 | 35, 35, 38 s | 14 of 14 each — the WTR1 body |
| `lib/worktree-ledger.test.sh` | 0 | 28 s | 56 cases, 15/15 mutants (L06e–L06k″) |
| `lib/record-canary.test.sh` | 0 | 0 s | 13 |
| `run-all-tests.test.sh` | 0 | 2 s | 19 (5a–5f) |
| `ci-shard.test.sh` | 0 | 21 s | 25 (S15b) |
| `restart-after-terminal-measure.test.sh` | 0 | 1 s | 13 (M12, M13) |
| `land-completeness.test.sh` | 0 | 5 s | 18 |
| `hooks/worker-lifecycle.test.sh` | 0 | 4 s | 42 (9a–9c) |
| `lib/finish-row-completion.test.sh` | 0 | 5 s | 16 + 5/5 |
| `lib/process-identity.test.sh` | 0 | 3 s | 12 OK |
| `cleanup-routing-contract.test.sh` | 0 | 52 s | 14 + 9/9 |
| `daily-workspace-cleanup.test.sh` (`RICHOS_MUTATION_INNER=1`) | 0 | 34 s | 67 |
| `reconcile-terminal-worktrees.test.sh` (`RICHOS_MUTATION_INNER=1`) | 0 | 45 s | 59 |
| `lib/worktree-adoption.test.sh` | 0 | 97 s | 43 + 15/15 |
| `hooks/guard-sealed-worktree.test.sh` | 0 | 72 s | 53 + 18/18 |
| `hooks/session-start-reap-worktrees.test.sh` | 0 | 24 s | 16 + 5/5 |
| `hooks/detect-nonnative-worktree.test.sh` | 0 | 85 s | + 7/7 |
| `hooks/terminalize-agent-worktrees.test.sh` | 0 | 121 s | 54 + 15/15 |
| `lib/workspace-retire.test.sh` | 0 | 94 s | 54 passed, 2 not covered (stated), 428 assertions |
| `hooks/session-start-stdin.test.sh` | 0 | 23 s | 13 (9l, 9m) |
| `hooks/root-contract.test.sh` | 0 | 118 s | 29 + 11/11 (6c, 6d) |
| `lib/worktree-transactions.test.sh` | 0 | 120 s | 70 + 25/25 |
| `hooks/contract-integrity.test.sh --only WTR` | **3** | 40 s | scoped-and-green by design (WTR1 PASS) |
| `daily-workspace-cleanup.mutation.sh` (alone) | 0 | 346 s | 36 of 36 |
| `reconcile-terminal-worktrees.mutation.sh` (alone) | 0 | 444 s | 30 of 30 |
| `hooks/guard-worktree-isolation.mutation.sh` ×2 (alone) | 0, 0 | 297, 362 s | 23 of 23 each — the WTI1 body |
| `reap-stale-worktrees.test.sh` (alone) | 0 | 417 s | 54 + 6/6 |

Thirty runs; twenty-nine exit 0 and the one exit 3 is the scoped integrity run's documented green. The engine's
record canary reported `record-untouched` with `healthy=1` on every row that carried it (26 of 30; the first four
predate the columns and their window is covered by A6). Nothing was backgrounded; the longest call was 444 s
inside a 590 s timeout. Not run: `contract-integrity.test.sh` in full, `by-reference.test.sh`, and the ~170 suites
outside this table.

---

## 6. What would have to be true for me to certify

Each stated so an engineer can act without asking me. All of them.

1. **D-1, the run.** `engine-self-verify` at the SHA under review prints `✓ ci-receipts: N/N planned unit(s) ran,
   all green, all at <that SHA>` — no `RECORD-TOUCHED`, no `KNOWN-RED-BUT-PASSED`, no `FAIL`. That means, at
   least: `demo.test.sh`, `hooks/agent-state-claims.test.sh` and the `base` section of
   `hooks/contract-integrity.test.sh` reach the ledger only under a redirected path (`RICHOS_WORKTREE_LEDGER` or
   a moved `HOME`), each with both arms as 9l/9m; and `worktree-ledger.DEFAULT_PATH` — and every other
   `~/.claude` default the lifecycle writers and readers hold — derives from `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`
   so that one redirect moves the whole record, with a test that sets `CLAUDE_CONFIG_DIR` and asserts where the
   ledger lands.
2. **D-1, the record.** The 323 `reed-sonnet-sc1` `registered` rows and the two fixture `terminated` rows on the
   operator's ledger are dealt with on the record: the two `terminated` rows retracted with the new verb, and the
   323 either voided by a mechanism every reader honors or named in the round record with the count, the writer
   and the date range (`grep -c reed-sonnet-sc1 ~/.claude/state/worktree-ledger.jsonl`), the way D-A's row was.
3. **D-2.** `rc_escaped` reports an entry present in the baseline and absent after (`DISAPPEARED`, all three
   kinds, including a ledger truncated to zero bytes and a team directory or team log removed);
   `record-canary.test.sh` carries those four cases; the runner tests still pass unchanged.
4. **D-3.** The `worktree-ledger.test.sh` row is deleted from `lib/ci-known-red.tsv` (or, if the mutant is still
   red on git ≥ 2.55 for a different reason, re-declared with a new bisect); CI at the SHA says which.
5. **D-4.** WTR1 and WTI1 keep the harness's output (a file, printed on failure) so a CI red is readable; and
   the reviewed SHA's run shows both green — or, if either is red again, the cause is named from that output
   and fixed. A flake waived without its output is not this condition met.

D-5 is not a condition of my key.

---

## 7. What I am not certifying, whatever the next round does

- The cause of the WTR1 / WTI1 reds — I have four green and three green local runs respectively and no CI output;
  if the next round shows both green in CI at its SHA with output captured, that closes 5 for me, but I am not
  saying they were flakes.
- The `managed-workspace-*` and `shell-worktree-sparse` lanes.
- `contract-integrity.test.sh` in full, `by-reference.test.sh`, and the ~170 suites outside section 5a.
- Any restart of a terminal agent on 2.1.268 beyond the ones already on the record; nothing I ran tripped it.
- The fallback file's scan cost at ten times its size; `_lock_entities` over a ledger ten times this one.
- Whether the platform re-creates a shell in a different repository on a restart (the fixer's §10.1; unobserved
  here, as in round four).

---

## Appendix A — how each number was produced

All on this machine, 2026-09-11 from 03:22Z, in `/Users/alex/ab/richos-wt/sage-fable-cert5` at `1c58c017`
(+ this document). Scratch scripts live in the session scratchpad under `sage-r5/` and are described so they can
be rewritten.

**A1. CI.** `gh run list --repo WebDevBooster/richos --branch main --workflow engine-self-verify --limit 6 --json
databaseId,headSha,conclusion,status,createdAt,event`; `gh run view 34557992690 --json status,conclusion,jobs`
(five shards + coverage `failure`); `gh run view --job <id> --log` for jobs 103136150581, 103136150496,
103136150519, 103136150563, 103136150594, 103139583190; `gh run view 34551424722 --attempt 1|2 --log`; the
`2d2f6cf1` log from my round-four scratch (`r4/ci-34547178102.log`); `grep -E 'contract-integrity.test.sh:(WTI|WTR) '`
across them for the table in D-4; `gh run view <id> --log-failed | grep WTR` on the three earlier red runs
(34543861760, 34539881673, 34533162792) → no WTR1 line.

**A2. D-A live.** `live_case.py`: `wl.registrations(records, worktree=path)` → `wl._join_prepared_rows` →
`wl._judge_registration(reg, entity, records, live, False, None)` per row and entity, `wl.judge(...)` aggregate,
`wl._lock_entities`; three record views built in memory (live; minus `retracted`; minus both). `live_v7_v4.py`:
every `terminated` row's agent resolved through `agent-liveness.resolve` in each native repo it has a row in;
`wl.terminations` for standing; transaction members' `repo`/path shape; hand-rolled ids without native rows.

**A3. D-A synthetic.** `entity_r5.py`: per case two `git init` repos, a native shell via `git worktree add` +
`git worktree lock --reason 'Claude Code isolation worktree (pid <this pid>)'`, a hand-rolled path, rows written
to a temp ledger, a transaction JSON under `RICHOS_WORKTREE_TX_DIR`, `HOME` set to the temp root; `judge()` with
`write=True` where stated; rows appended read back from the temp ledger; `shutil.rmtree` after.

**A4. Join.** `join_live.py`: every id-less `prepared` row on the live ledger against `_join_prepared_rows` over the
exact-path rows; outcome counter `{'joined': 77, 'no-candidate(other-registered=0)': 18, 'unexpected': 2}`;
`odd_rows.py` prints the two (`rich-land-binding` rows, agent `af3b228967dc2b627`, deeply-wt and
claude-orchestration-kit-wt `zach-opus-dor2`); `(session, teammate, path)` keys with >1 id: 0.

**A5. D-B, D-C.** `bare_shapes_r5.py` = round four's `bare_shapes.py` with the library path changed (`sed`), output
quoted in section 2; `fallback_robust_r5.py` likewise, cases A–E.

**A6. Controls.** Before (03:22:10Z, `wc -l` / `grep -c` / `ls | wc -l` / `find -name '*.json' | wc -l`):
ledger 17,436 lines, `terminated` 46, `platform-terminal-record` 1, `retracted` 1, fallback 250, teams 9,
transaction files 860. After (04:27:14Z, `sage-r5/after_counts.py`): ledger **17,513**, `terminated` **46**,
`platform-terminal-record` **1**, `retracted` **1**, fallback **250**, teams 9 session directories (the script's
`os.listdir` counted 10 — the tenth is a `.DS_Store` dated 29 March, which `ls` had skipped; `ls -laT`), transaction
files 860 by the same `find` (the script's 116 is the depth-2 count of transaction JSONs, a different question).
The 77-line delta classified by `(event, source)` for every row with `ts > 2026-09-11T03:22`: **78 × `finished`
/ `worker-ended-handoff.sh`, session `b7869424`, no teammate on any non-`finished` row** — the platform's own hook
at every helper turn of every live agent, none from anything I ran (the count exceeds the line delta because the
window opens before my first `wc`). The engine's own canary, sourced against the real config before each run,
reported `record-untouched` on all 26 rows that carried it.

**A7. Canary probe.** `canary_probe.sh`: seeds a ledger of four rows, a two-line fallback, two team directories
under a temp `CLAUDE_CONFIG_DIR`, sources the shipped library, and for each of eighteen mutations takes
`rc_baseline`, applies it, prints the first line of `rc_escaped` or `NOT SEEN`, and restores the seed.

**A8. Fixture rows.** `grep -c '<id>' ~/.claude/state/worktree-ledger.jsonl` and a python over the matches for
`(event, witness|source)`, `min/max ts`, `worktree`.
