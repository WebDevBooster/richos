# Reclaim round 14 — Sage's five conditions, Frank's two non-conditions, and three observations

**Branch:** `cc/zach-fable-fix3` in `/Users/alex/ab/richos-wt/zach-fable-fix3`, from richos main
`2cf3d7af630a8c585d9fe55f0d79a05186f9150c` (main moved once during the round, to `b43ca8140`,
`app/` only — acknowledged with `inflight-ack.sh`, impact none). **Author:** Zach (Fable, by the
CEO's order; round fourteen of this class). **Date:** 2026-09-11. **This document does not declare
the work fit for use; both reviewers review again, and nobody declares it fit, this author included.**

Every number below carries the command that produced it, or the word UNVERIFIED. Section 7 is
filled from real runs at the final code commit of this branch; a suite that did not exit 0 is
stated as such.

---

## 1. Sage's conditions (§6 of `certification-sage-round3-2026-09-10.md`), each with the commit that closes it and the command that proves it

### 1.1 D1 — a bare repository under a disposable component (SEVERE) — commit `3e01922b`

**Reproduced first, on unmodified code, under the lane's binary** (`completion-proof.GIT` =
`/Library/Developer/CommandLineTools/usr/bin/git`, `git version 2.50.1 (Apple Git-155)`; scratch
`bare_repro.py`, two shapes — a `clone --bare` under `node_modules/pkg/mirror.git` with loose objects,
and a bare store under `.cache/store` named nothing like `.git`, packed-only after `gc --prune=now`):

```
ignored_files entries: 48 trailing-slash entries: []
partition: dropped(keep)=48 residue=0
  any store bytes in residue? False | store bytes in keep (DROPPED, no copy)? True
git worktree remove rc=0 stderr='' exists after=False
```

**Closed.** `ignored_files()` recognizes a git object store by git's own `is_git_directory` test — a
regular `HEAD` beside an `objects/` and a `refs/` directory, checked on disk for every directory whose
`HEAD` the listing names — and collapses everything under the outermost such directory into the ONE
trailing-slash entry a nested repository already gets (`git_store_roots`). Downstream nothing changes:
`never_disposable` refuses it, `_expand_residue` walks it, the archive holds directory entries, the
journal names it under `nested_repositories`, a restore is a repository. The same repro after the fix:

```
ignored_files entries: 2 trailing-slash entries: ['.cache/store/', 'node_modules/pkg/mirror.git/']
partition: dropped(keep)=0 residue=2
```

**The rest of the class, decided.** R1 (round 13) and D1 were the same shape one step apart — "a git
object store the disposable test does not recognize" — so the predicate is now two-layered: (i) a
store git itself would open is collapsed and archived whole; (ii) a file laid out as a git object is
never disposable on its own name, HEAD or no HEAD (`looks_like_git_object`: `objects/xx/<38+ hex>`,
`objects/pack/pack-<hex>.pack|.idx`). Shapes tried, in the test and the scratch repro:

| Shape | Result |
|---|---|
| nested repository with a working tree (R1) | trailing-slash entry from git; archived whole (unchanged) |
| bare clone, loose objects, under `node_modules/` | collapsed; loose object of HEAD asserted in the archive; restored, `rev-parse HEAD` = the commit |
| bare store named `.cache/store`, packed-only after `gc`, refs in `packed-refs` | collapsed; the `.pack` and `packed-refs` asserted in the archive; restored, `cat-file -p HEAD:only-here` |
| a linked worktree's `.git` gitfile under a disposable parent | already a trailing-slash entry (Frank's round-three experiment); its objects live in the parent repository |
| loose objects or packs with **no HEAD** beside them (git would not call it a repository) | never disposable by (ii); name controls that must stay disposable: `objects/readme`, `objects/pack/notes.txt`, `objects/ab/short` |
| a bare store whose `refs/` directory was deleted (git would not open it) | its `HEAD`/`config` are dropped by the parent's name; its **objects** are kept by (ii) — no commit bytes lost, stated as the boundary |

**Proof:** `python3 engine/scripts/daily-workspace-cleanup.test.py Cleanup.test_a_BARE_repository_under_a_disposable_path_is_ARCHIVED_whole_never_dropped`
(asserts git's own file-by-file listing, the collapsed listing, the partition, the object-file clause
with its controls, the journal, the loose object and the pack in the archive, and a restore of both
stores from the archive alone). Mutants `bare-repository-dropped-as-disposable` and
`git-object-bytes-disposable` in `daily-workspace-cleanup.mutation.sh`, each verified killed on a
throwaway copy before the commit (`scratchpad/r14/kill-check.py`) and again by the harness (§7).
The table's falsifier sentence in `reclaim-decision-table.md` §3 is unchanged; §4 gains the row.

### 1.2 D2 — the shipping commit must carry a green `engine-self-verify` run (SEVERE)

I cannot push, so the green run is produced after the land. Every red unit is green locally in CI
shape, with the command:

| Unit | Was | Commit | Command, and result at the final code commit |
|---|---|---|---|
| `scripts/lib/process-identity.test.sh` | 21 failures in CI shape (`'T4' is not None`) | `47a876f9` | `bash engine/scripts/lib/process-identity.test.sh` → `Ran 12 tests … OK`. The suite pins the CI shape itself (`RICHOS_SESSION_PROCESSES=none`, `RICHOS_SESSIONS_DIR=<empty dir>`), so the command is identical on every machine; also verified with the pins duplicated in the environment, same verdict |
| `scripts/hooks/hook-staleness.test.sh` case 11 | `surfaces disagree: only-plugin=[guard-ci-red-lands.sh, session-start-ci-surface.sh]` | `ad7ee29a` | `bash engine/scripts/hooks/hook-staleness.test.sh` → `28/28` |
| `scripts/hooks/root-contract.test.sh` | 1 FAILED of 37 (case 9j: `session-start-ci-surface.sh` never hang-checked), 713 s | `ad7ee29a` | `bash engine/scripts/hooks/root-contract.test.sh` → `all 27 passed` + `all 11 fixes proven load-bearing`, 194 s; `bash engine/scripts/hooks/session-start-stdin.test.sh` → `all 11 passed`, 43 s (9k is the new case) |
| `engine-run-record.yml` | 3 pushes with no run | `71be8846` | `bash engine/scripts/ci-run-record-check.test.sh` → 14/14; the live check re-runs on GitHub's schedule (six-hourly) and cannot be run here without a token — see below |

**T4, decided as the coordinator directed (Sage's first option).** `owner_evidence()` no longer
authorizes an owner whose identity is malformed or unknown; T1 and T2 are untouched, so the ordinary
crash (a recorded pid gone or reused) still authorizes on T2. The T4 tier is retired in the docstring,
`_ledger_no_session_alive` and `worktree-ledger.no_session_alive` are removed (the tier was their only
caller). **The check the brief asked for — does this break what `2e0242d8` was written to fix:** that
commit's own message says T4 was "the narrowest thing that closes the hole" for a session that dies
before recording an identity. Measured on the operator's ledger before the change
(`scratchpad/r14/`, the python in §2): 17,120 rows, 650 ownership rows, 12 sessions with ownership
rows, **0 sessions with no pid on every ownership row, 0 T4-shaped paths on disk**. The tier had no
live case, so nothing that commit fixed is lost and I proceeded rather than stopped. Adoption cases
A70/A71/A71b now assert the refusal in every shape the old tier authorized, with an identical verdict
and reason across an empty table, a live `claude` in the table and a live registry entry; mutants
`t4-resurrected` (A70) and `no-record-is-not-refused` (A72) replace the two that pinned the retired
tier. `bash engine/scripts/lib/worktree-adoption.test.sh` → 43 passed, 15/15 proven.

**hook-staleness 11 and root-contract 9j** had one cause: `guard-ci-red-lands.sh` and
`session-start-ci-surface.sh` reached `hooks/hooks.json` on 2026-09-10 and not the seated
`.claude/settings.local.json` (the same omission commit `1095bd4e` caught for another hook the same
afternoon). Both are seated now at the plugin's position and timeout; 9k hang-checks the second and
the covered list 9j derives against includes it. `engine-status.test.sh` 16/16 and
`stop-hook-visibility.test.sh` 40/40 (both read the surfaces) — green.

**engine-run-record, explained and fixed.** The three run-less pushes (`cc4ec69e` 01:34Z, `1efbbbab`
02:20Z, `0c37c356` 03:20Z) are inside a four-hour gap the day-grained `--since` could not see: the
restoring commit `328ff8c9` is dated `2026-09-10T00:46:20Z` (`gh api repos/WebDevBooster/richos/commits/328ff8c9`)
and the first run the trigger ever produced is `8bec9050` at `04:11:27Z`, `event=push`
(`gh run list --repo WebDevBooster/richos --workflow engine-self-verify.yml --branch main --json headSha,createdAt,event`).
Seven pushes fell between (`a84784d3 01:27Z, cc4ec69e 01:34Z, e587a7bb 02:10Z, 1efbbbab 02:20Z,
05124e66 03:03Z, 3a0c6925 03:13Z, 0c37c356 03:20Z`, from the PushEvent feed) and none has a run.
Whether GitHub had not yet honored the trigger or dropped the runs is **UNVERIFIED** — the workflow's
enable time is not in the API (`state: active, updated_at 2026-09-06`). It does not matter to the fix:
a `workflow_dispatch` ref must be a branch or a tag, so the remedy the check printed
(`gh workflow run --ref <sha>`) cannot target a superseded SHA and the gap is permanent. `--since` is
now the push that produced the first run (`2026-09-10T04:11:26Z`), with the seven SHAs and the
reasoning in the workflow file; the checker's usage states the grain; the printed remedy is one that
works (push a branch at the SHA, dispatch on it) plus the honest alternative. **Rich:** the next
scheduled firing after the land is the proof; if it is still red, the log names the SHA.

### 1.3 D3 — the second source is per-session and ephemeral (MODERATE) — commit `f33fe11e`

**Substrate, re-derived by my own command** (`scratchpad/r14/fallback-overlap.py`, 2026-09-11):

```
transaction-store sessions: 49
  with a team directory: 3 | with a team directory AND a worker-events.jsonl: 3
  with lifecycle rows ONLY in the fallback file: 31
  with neither: 15
fallback file rows: 380 | distinct session ids in it: 40 | feedbeef rows: 130
team directories on disk: 10 | with a worker-events.jsonl: 3
```

(Sage's 21 of 27 counted sessions with transactions; mine counts every session directory in the store.
Both say the same thing: the fallback is the common case.)

**Stated truthfully** in `lifecycle_teams_dir()` (the whole substrate, counts and command),
`post_terminal_run_open()` (why it still fails safe: two sources hold exactly while the session lives,
which is the only time a note can be lost; `session_gone` takes over after), decision-table row 5, and
the round-13 record (a dated correction under §1.2 rather than a rewrite).

**The choice, reasoned: read the fallback.** `platform_lifecycle_after()` now reads the session log when
it exists AND the fallback beside the teams directory (`lifecycle_fallback_log()`, rooted with
`lifecycle_teams_dir` so a sandbox never reads the real file), same exact join; a fallback row must
carry the full session id. Cost: one sequential scan of a 380-row file behind the existing
`agent_id in line` prefilter. Benefit: the second source is true for 31 sessions instead of 3.

**`--locks` no longer drops what it cannot see.** (c) falls back to the ledger witness plus the start
fact when a session's log is gone and says so; `event_rows()` reads the fallback too; a CORPUS LIFETIME
footer dates every (a)/(b) number. Live at this commit (`python3 engine/scripts/restart-after-terminal-measure.py --locks`):

```
(a) initial starts with a lock file on disk : 3; lock PRECEDES the start in 3 of them
(b) restarts with a lock file on disk       : 1; lock mtime moved AFTER the restart (a re-lock OBSERVED) in 0 of them
(c) restarts into a tree the reaper witnessed UNLOCKED : 4; admin directory still on disk for 0 of them; known only from the start fact (event log gone) for 4 of them
```

— where the tip printed `(c) 0`. The plain join: `106 terminal, 72 owning, 14 restarted (19.444 %),
4 logs scanned` (three session logs and the fallback). The round-13 (b)/(c) quote in the decision table
is kept, dated as measured on session `d0eef867`'s log since deleted, and followed by this output.

**Proof:** `bash engine/scripts/restart-after-terminal-measure.test.sh` → 11/11 (M10: the fallback is read;
M11: (c) from the start fact, named unobservable from the log; the pre-existing M9 assigned the empty store
into the shell — `VAR=x OUT=$(…)` has no command word — and is re-exported before M10).
`python3 engine/scripts/daily-workspace-cleanup.test.py Cleanup.test_the_second_source_is_read_from_the_FALLBACK_log_for_a_session_with_no_team_directory`
(another agent's rows, another session's rows and a row with no session id never count; a lost start
note seen only in the fallback holds; the run's end in the same file closes it). Mutant
`fallback-log-ignored`, verified killed.

### 1.4 D4 — a suite writes fixture rows into the operator's real event log (LOW) — commits `9816e7b6`, `3ee58da7`

`finish-row-completion.test.sh` moves `HOME` and `WORKER_EVENTS_TEAMS_DIR` into its sandbox and asserts
both arms like `escalations.test.sh` 17o: F15 (positive: the sandbox fallback log received the rows —
8 on my run) and F16 (the real file's fixture-row count, read from its real path captured before `HOME`
moved: 130 before, 130 after). `bash engine/scripts/lib/finish-row-completion.test.sh` → 16 cases, 5/5.

`session-deadbeef/` was **not** that suite's: its 25 KB of names (`dev-1` ×2,483, `deviceqa-1` ×241,
`dev-2` ×160, `worker-oneoff1`, `funcqa-1` …) are `detect-nonnative-worktree.test.sh`'s, whose six
firing sites passed no `GUARD_ISOLATION_TEAMS_DIR`. Same fix, same two arms (L1/L2), 7/7 mutants.

**Not deleted by me — Rich, run these** (they touch the operator's real record):

```
cp ~/.claude/worker-events.jsonl ~/.claude/worker-events.jsonl.bak-r14
python3 - <<'PY'
import os
p = os.path.expanduser('~/.claude/worker-events.jsonl'); tmp = p + '.tmp'
kept = dropped = 0
with open(p, encoding='utf-8') as src, open(tmp, 'w', encoding='utf-8') as dst:
    for line in src:
        if '"session_id": "feedbeef-' in line: dropped += 1; continue
        dst.write(line); kept += 1
os.replace(tmp, p); print('kept', kept, 'dropped', dropped)   # expect dropped 130, kept 250
PY
rm -rf ~/.claude/teams/session-deadbeef
```

### 1.5 D5 / F2 — the in-event lane is bounded on tracked files, not on residue bytes (LOW; Frank's non-condition) — commit `599d3b52`

`residue_bytes(path, repo)` sizes the residue by `os.lstat` before anything is archived (stores expanded,
disposables excluded, nothing opened, `None` when unlistable — and `None` is not zero). Checked in
`reclaim_now` (new `max_residue_bytes`, passed by `_reclaim_in_event` from the member's repository config)
and in `sweep_session` before a candidate starts. `IMMEDIATE_RECLAIM_RESIDUE_MAX_BYTES=268435456` (256 MiB)
in `orchestration.config`, reasoning beside it: four passes (digest, tar, verify, last look) at a
conservative 150 MB/s is ~7 s of the hook's ~15 s; this machine's sha256 measured **3,209 MB/s on
256 MiB in memory** (`python3 -c` timing, §2), so the number leaves an order of magnitude for a real disk.
**The nightly pass has no ceiling** — it defers nothing on size and skips nothing; what the hook defers it
takes with the same refusals (`test_the_nightly_pass_has_no_residue_ceiling_and_archives_what_the_event_deferred`).
Test `test_the_events_own_member_is_bounded_by_the_residue_byte_ceiling`; mutants
`residue-byte-ceiling-ignored-in-event` and `…-in-sweep`, verified killed.

### 1.6 Condition 5 — the round-13 record's §5

Removed rather than back-filled: it now says it was never filled and points at the two reviewers' suite
tables at `2b8a235d` and at §7 here. This record's §7 is from real runs at the final code commit.

---

## 2. Numbers in this record, and the commands that produced them

| Number | Command |
|---|---|
| 48 entries / 0 trailing-slash / 48 dropped; after: 2 / 2 / 0 | `python3 scratchpad/r14/bare_repro.py` (temp repository, deleted) |
| 0 T4-shaped sessions, 0 paths; 12 sessions with ownership rows | python over `~/.claude/state/worktree-ledger.jsonl`: ownership rows grouped by `session_id`, sessions with no `session_pid` on any row, their `worktree` paths tested with `os.path.isdir` |
| 49 / 3 / 31 / 15 sessions; 380 fallback rows, 130 `feedbeef` | `python3 scratchpad/r14/fallback-overlap.py` |
| 3,209 MB/s sha256 | `python3 -c` hashing 4 × 64 MiB of `os.urandom` in memory (0.08 s) |
| inner root-contract 61 s of cases in a 91 s call, 9b 28 s, 6a 14 s | `scratchpad/r14/time-inner.sh` (per-line elapsed seconds) |
| root-contract 194 s, session-start-stdin 43 s | `scratchpad/r14/run-suite.sh` (wall via `date +%s`), logs under `scratchpad/r14/suites/` |
| 328ff8c9 00:46:20Z; first run 8bec9050 04:11:27Z; seven pushes | `gh api repos/WebDevBooster/richos/commits/328ff8c9 --jq .commit.committer.date`; `gh run list … --json headSha,createdAt,event`; `gh api repos/WebDevBooster/richos/events?per_page=100` filtered to PushEvent |
| (a) 3 of 3, (b) 0 of 1, (c) 4 / 4 start-fact; 106 / 72 / 14 | `python3 engine/scripts/restart-after-terminal-measure.py --locks` and without flags, at this commit |
| four registered quarantines; `unowned` → `quarantined` 4 | `scratchpad/r14/land-completeness-richos.sh` (read-only `land-completeness.sh --repo /Users/alex/ab/richos`), before and after O1 |
| Frank refused 22:57:02Z, reclaimed 23:00:31Z; Sage restart 22:55:43Z | `scratchpad/r14/evidence-o2b.py` over the transaction store, the rm-*.log mtimes, `session-b7869424/worker-events.jsonl` and the ledger |

---

## 3. The three observations, decided

### O1 — the remover says it prunes; it does not — commit `3f9539f5`

**Confirmed and fixed (text), fixed (gate), fixed (report).** All four outcome JSONs read
`git_registration: present`, `git_worktree_prune: not-attempted`, `git_worktree_repair: ok`,
`branch.reason_code: branch-checked-out`; the route is the second review's design (2026-09-06:
"repair the exact quarantine registration without unlocking or bulk prune"), and the usage text was the
thing that lied. Usage and header now say: registration RETAINED and repaired to the quarantine,
nothing pruned, `--branch` left in place because the quarantine has it checked out; `retire-branch`
after the sweep. **The gate's printed command** (`remove-agent-worktree.sh <path>`) exits 2 with usage;
land-completeness now carries `owner_agent_ids` on every row (from the same `judge()` result that made
it blocking) and the gate prints `--owner <id> <path>`, or the `--workspace` form with `list` when no id
is on the row. **Does the completeness check count a quarantined-but-registered tree as finished?** No —
it counted it as `unowned` in the COULD-NOT-DECIDE column (the rename moved the tree to a path no record
names), never blocking and never finished. It is now the `quarantined` disposition, RETAINED WITH A
REASON, on its own line: the same read-only run went from `COULD NOT DECIDE (8)` to
`quarantined (retired, registered by design) .... 4` and `COULD NOT DECIDE (4)` — the four Codex trees,
which this report still calls `unowned` (out of scope here; noted for the next reviewer).
`land-completeness.test.sh` 18/18, `land-disposition.test.sh` 33/33, `guard-ci-red-lands.test.sh` 16/16.

### O2 — a cross-repo worktree loses its termination witness when its native shell is unchanged — commit `2392c68e`

**Why the two shells differ — established from the record, not the platform's documentation.** Frank's
transaction: terminal `SubagentStop 22:44:29Z`, one `WorkerRunEnded` for his registration id, native shell
and admin directory gone (`os.path.isdir` False for both). Sage's: terminal `22:52:36Z`, then
`after_terminal start 22:55:43Z / stop 22:56:08Z` — the fourteenth restart, the harness-background door of
O3 — and the native shell present and **locked by pid 84597**, this session. The one observable difference
is the restart; the platform removed the unchanged shell of the agent that ended once and kept the shell of
the agent it ran again. Whether a change in Sage's shell also played a part is **UNVERIFIED** (I did not run
git in his worktree).

**The positive signal exists and one authority was not reading it.** The reclaim lane authorizes on the
transaction's terminal record (`owner_check`: `terminal_fact` + row 5 + the liveness veto) and reclaimed
Frank's cross-repo tree at `23:00:31Z`, sixteen minutes after his terminal record, once main held his
commits. The operator door (`workspace-retire.termination_authority` → `worktree-ledger.judge`) never
opened the transaction store: with the native shell absent and the session alive it landed in step 3's
`INDETERMINATE … decidable once that session ends`, refusing the same path at `22:57:02Z`. That judge is
also what `land-completeness` and the residue gate print — the live row on the CEO's screen.

**Decided: the judge reads the record, to the lane's own standard.** `worktree-ledger.platform_terminal_record()`:
a sealed, non-adopted transaction for this exact (session, agent) whose members name this exact path,
with `post_terminal_run_open` false — the same row-5 check, two sources, session death voiding it.
Step 2b of `_judge_registration`, reached only when the native shell is absent or unregistered (a held
lock has already returned ALIVE or INDETERMINATE above it, and outranks the record): `terminal` →
NOT-ALIVE "platform terminal record: …" (and a `terminated` row with witness `platform-terminal-record`
when writing); `open` → INDETERMINATE with row 5's own reason ("RETRY, not a verdict: the platform started
agent … again"). `workspace-retire` gains basis `platform-terminal-record`. **Not a relaxation of the
positive-evidence rule:** the fact is the platform's own SubagentStop for the registration id, the same
one the lane removes on; an adopted transaction (the engine's derivation) never counts; a store that cannot
be read counts for nothing. Proof: ledger cases L06a/L06a′ (controls: another path, an adopted transaction
→ unchanged INDETERMINATE), L06b (NOT-ALIVE on the record), L06c (open run → row-5 INDETERMINATE), L06d
(closed → NOT-ALIVE); mutants `platform-terminal-record-ignored` and `open-post-terminal-run-ignored`;
retire F1c′ end-to-end through `remove-agent-worktree.sh` (refused with the store silent, refused with the
run open, proceeds once closed, the liveness reason quoting the record).

### O3 — the harness backgrounds a call over 600 s and the job's exit restarts a barred agent — commit `ad7ee29a`

**Recorded** in the decision table §4 (two rows: the fourteenth restart with its door; "a foreground Bash
call stays foreground — FALSE over the tool ceiling") and in the header of `session-start-stdin.test.sh`,
which is where the next person who trips it will be standing. **Made un-trippable for this suite** by the
split: section 9 (36 s of the 61 s inner run, replayed seven times by the harness) is its own suite; each
half fits one call with room (194 s and 43 s here, on a machine also running the other key's suites), and
M10 is proven against the suite that now owns 9c. The record's "nothing scoped now exceeds 300 s" was
wrong for `root-contract.test.sh` (713 s under load, 190 s in CI); §7 gives every wall time I measured.
Two suites in §7 stay near the ceiling by construction (`reconcile-terminal-worktrees.mutation.sh` 375–446 s,
`daily-workspace-cleanup.mutation.sh` ~400 s with 33 mutants now); I ran each **alone, as its own call**,
never chained after its unit suite, and they are the two a reviewer should run the same way.

---

## 4. Refused, or deliberately not done

- **Deleting the 130 `feedbeef` rows and `session-deadbeef/`** — the operator's record; commands in §1.4.
- **Re-dispatching the three run-less pushes** — a remote mutation, and a `workflow_dispatch` ref cannot be a SHA; the gap is recorded as permanent in the workflow file instead.
- **Reading Sage's native shell with git** to settle why the platform kept it — a worktree-isolated agent's git stays in its own worktree; stated UNVERIFIED with the one observable difference named.
- **The Codex trees' `unowned` line in land-completeness** — §31 excludes them from every door; the report's wording is a separate change and out of this round.
- **Adding a weight row for `session-start-stdin.test.sh`** to `ci-unit-weights.tsv` — every row there is from one CI run for comparability; the unit takes `DEFAULT_WEIGHT` (60) until the next full pass measures it, and `root-contract`'s 192.3 s row is now an overestimate (balance only).
- **echo-opus-ci1** appeared as an INCOMPLETE LAND in the read-only run after main took Echo's branch: merged, registered, owner INDETERMINATE (native shell absent, session alive, and its transaction is sealed but carries **no terminal record** though a SubagentStop finish row exists at 23:49:01Z). Not touched: it is a live teammate's tree at the time of writing, and whether the terminal record is missing because the stop carried a per-run id is the next reviewer's to establish.

---

## 5. Commits on `cc/zach-fable-fix3`, oldest first (`git log --reverse 2cf3d7af..HEAD`)

| SHA | What |
|---|---|
| `fa9a3df1` | this record opened, before any condition was closed |
| `3e01922b` | **D1** — a bare repository under a disposable path is recognized as a git store and archived whole; the object-file clause; two mutants |
| `ad7ee29a` | **D2** (hook-staleness 11, root-contract 9j) and **O3** — two hooks reach the seated surface; the stdin hang checks become `session-start-stdin.test.sh` (9k added); M10 re-pointed |
| `47a876f9` | **D2** (process-identity) — T4 retired; the suite pins the CI shape; A70/A71/A71b rewritten; two mutants replaced; `no_session_alive` removed |
| `71be8846` | **D2** (engine-run-record) — `--since` is the push that produced the first run; the checker's usage and remedy corrected |
| `9816e7b6` | **D4** — `finish-row-completion.test.sh` redirects `HOME`/`WORKER_EVENTS_TEAMS_DIR`, F15/F16 both arms |
| `599d3b52` | **D5 / F2** — `IMMEDIATE_RECLAIM_RESIDUE_MAX_BYTES`, `residue_bytes`, both lanes, two tests, two mutants |
| `f33fe11e` | **D3 / F1** — substrate stated; the fallback file read; `--locks` (c) from the ledger witness and the start fact; docs and the round-13 correction; measure M10/M11, daily test, mutant |
| `3ee58da7` | **D4's sibling** — `detect-nonnative-worktree.test.sh` stops writing `session-deadbeef/spawned-names.log`, L1/L2 |
| `3f9539f5` | **O1** — remover usage text; the gate's FINISH THE LAND command; `quarantined` disposition and `owner_agent_ids` in land-completeness |
| `2392c68e` | **O2** — `platform_terminal_record` in the ledger judge (step 2b), row 5 applied; `platform-terminal-record` basis; L06a–L06d, F1c′, two mutants — **the final engine-code commit** |
| `cee2aab6` | the daily mutation harness's `nested-repository-dropped-as-disposable` anchor follows D1's two-line `return` (32 of 33 → 33 of 33) |
| (this commit) | this record filled, and `reclaim-round-14-suite-results.txt` beside it |

---

## 6. What the next reviewer should attack

1. **The object-file clause's regex** (`_GIT_OBJECT_RE`): a loose object named with 62 hex characters is SHA-256 layout; a store with `objects/info/alternates` pointing elsewhere is not covered (its objects are elsewhere by construction). Is there a fourth shape — a store git recognizes that neither `HEAD`+`objects`+`refs` nor the object regex catches? I found none.
2. **Step 2b's ordering against the lock.** A held lock with no pid returns INDETERMINATE before 2b; a held lock with a live pid returns ALIVE. Is there a lock state in which 2b is reached while the platform still holds the shell? (`registered=False` is the only route.)
3. **`--since` as a timestamp** hides the seven pushes forever. If GitHub was in fact dropping runs at 01:27–03:20Z, the drop class is real and the check now cannot see those instances; it sees every later one.
4. **The fallback file's growth.** It is one file for every session with no team directory; `platform_lifecycle_after` scans it per member per sweep behind a substring prefilter. Measure it when it is ten times its current 380 rows.
5. **The byte ceiling is a size, not a time.** A residue of 100 MiB in 200,000 tiny files is under the ceiling and slow in the tar; the tracked-file ceiling does not see ignored files. A file-count ceiling on the residue is the obvious next bound if it is ever hit.

---

## 7. Suites run at the final code commit

All at `2392c68e` (engine code) — the harness rows marked † at `cee2aab6`, which changes one
anchor in `daily-workspace-cleanup.mutation.sh` and no engine code. Every row is one process I ran
in the foreground through `scratchpad/r14/run-suite.sh` (rc from the process, wall from `date +%s`
around it), logs under `scratchpad/r14/suites/`, the rows appended to `RESULTS.tsv` as each run
ended and copied verbatim to `reclaim-round-14-suite-results.txt` beside this file. The heavy
harnesses ran **alone, one per call**; the quick suites ran sequentially in one call; nothing was
backgrounded and no call exceeded 318 s. The machine was shared with the other keys' sessions.

| Suite | rc | wall | Note |
|---|---|---|---|
| `lib/process-identity.test.sh` | 0 | 1 s | 12 OK, CI shape pinned by the suite |
| `hooks/hook-staleness.test.sh` | 0 | 3 s | 28/28 (case 11 was red) |
| `restart-after-terminal-measure.test.sh` | 0 | 1 s | 11 (M10, M11 new) |
| `lib/finish-row-completion.test.sh` | 0 | 3 s | 16 + 5/5 (F15/F16 new) |
| `ci-run-record-check.test.sh` | 0 | 1 s | 14 |
| `hooks/engine-status.test.sh` | 0 | 3 s | 16 |
| `hooks/stop-hook-visibility.test.sh` | 0 | 2 s | 40 |
| `land-completeness.test.sh` | 0 | 2 s | 18 |
| `hooks/land-disposition.test.sh` | 0 | 4 s | 33 |
| `lib/completion-proof.test.sh` | 0 | 6 s | 25 |
| `hooks/record-subagent-start.test.sh` | 0 | 7 s | 14 + 6/6 |
| `hooks/escalations.test.sh` | 0 | 5 s | 79 |
| `lib/worktree-ledger.test.sh` | 0 | 17 s | 42 + 10/10 (L06a–L06d, two mutants new) |
| `hooks/session-start-reap-worktrees.test.sh` | 0 | 20 s | 16 + 5/5 |
| `cleanup-routing-contract.test.sh` | 0 | 26 s | 14 + 9/9 |
| `lib/worktree-adoption.test.sh` | 0 | 60 s | 43 + 15/15 (`t4-resurrected`, `no-record-is-not-refused` new) |
| `hooks/guard-ci-red-lands.test.sh` | 0 | 18 s | 16 |
| `hooks/session-start-stdin.test.sh` | 0 | 41 s | 11 (new suite; 9k new) |
| `discard-workspace-backlog.test.py` | 0 | 2 s | 10 |
| `daily-workspace-cleanup.test.sh` (unit, `RICHOS_MUTATION_INNER=1`) | 0 | 28 s | 65 cases |
| `hooks/root-contract.test.sh` | 0 | 188 s | 27 + 11/11 (was 713 s / 1 FAILED) |
| `daily-workspace-cleanup.mutation.sh` (alone) | **1** | 240 s | **32 of 33**: `nested-repository-dropped-as-disposable` "the mutation did not apply" — the harness's anchor, not the code (§5, `cee2aab6`) |
| `daily-workspace-cleanup.mutation.sh` (alone) † | 0 | 268 s | 33 of 33, incl. the five new |
| `lib/worktree-transactions.test.sh` | 0 | 117 s | 70 + 25/25 |
| `hooks/terminalize-agent-worktrees.test.sh` | 0 | 77 s | 54 + 15/15 |
| `reconcile-terminal-worktrees.test.sh` (unit, `RICHOS_MUTATION_INNER=1`) | 0 | 45 s | 59 |
| `hooks/guard-sealed-worktree.test.sh` | 0 | 49 s | 53 + 18/18 |
| `hooks/detect-nonnative-worktree.test.sh` | 0 | 58 s | + 7/7 (L1/L2 new) |
| `lib/workspace-retire.test.sh` | 0 | 89 s | 54 passed, 2 not covered (stated), 428 assertions (F1c′ new) |
| `reconcile-terminal-worktrees.mutation.sh` (alone) | 0 | 252 s | 30 of 30 |
| `reap-stale-worktrees.test.sh` (alone) | 0 | 318 s | 54 + 6/6 |

Thirty-one runs; thirty exit 0 and the one that did not is the anchor drift named in its row, re-run
green after the one-line harness fix. Not run: `contract-integrity.test.sh` (39 min in CI; the seated
surface it audits is exercised by `engine-status`, `stop-hook-visibility` and `hook-staleness` above),
`by-reference.test.sh`, and the ~180 suites outside this area.
