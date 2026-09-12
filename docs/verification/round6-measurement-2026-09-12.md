CHECKS RUN: 15  RED: 1

# Round 6 — the fourteen checks, measured. Fixing is round 7.

**Brief:** richos-hq `docs/plans/round6-brief-fourteen-points-2026-09-12.md` @ `75316840`. **The spec:** richos-hq `docs/plans/worktree-spec-2026-09-11.md` (read there; the mirror here was not read as the spec and was not touched).
**Engineer:** zach-fable-m1 · worktree `/Users/alex/ab/richos-wt/zach-fable-m1` · branch `cc/zach-fable-m1`, cut from `dev/workspace-spec` @ `c5bce604`.
**Nothing merged, nothing pushed, no `install.sh`, nothing written into `/Users/alex/ab/richos/engine` or any main checkout, nothing `codex/` touched.** `main` is `dcabcbd9` (`git rev-parse main` → `dcabcbd99056928a9872cd94c1f3a385f8b21069`).

## 0. Which engine — every number below names one, and none compares across

| | is | writes | this round's use |
|---|---|---|---|
| **running** | `main` @ `dcabcbd9`, via `~/.claude/richos-engine` → `/Users/alex/ab/richos/engine` | `~/.claude/state/worktree-ledger.jsonl`, `workspace-retirement/` | READ ONLY, for the record extension (§6) and the census (§7). Not measured against the fourteen. |
| **spec** | `dev/workspace-spec` @ `c5bce604` = this branch's base | `state/workspaces/` | EVERY check in §2, in a sandbox: `HOME` and `CLAUDE_CONFIG_DIR` redirected, `RICHOS_WORKSPACES_DIR` unset inside (so the store is the sandbox's), `RICHOS_SESSION_PID` a `sleep` the harness owns. |

The one place the two meet is deliberate and labeled: §6 §A3 says what the running engine's ledger shows about sub-run ids, and §2 C11 says what the spec code does with an id it has no registration for.

## 1. The headline, and how it was produced

```
$ bash engine/scripts/workspace-spec-fourteen.test.sh        # cc/zach-fable-m1 @ 79d030c4 (and every commit after); sandboxed
  FAIL  C14  The integration branch is recorded before the first spawn, or the spawn is refused naming what to record; ...  (1 sub-assertion(s) red)
  PASS  C1   PASS  C2   PASS  C3   PASS  C6   PASS  C4   PASS  C7   PASS  C8   PASS  C9   PASS  C10   PASS  C11   PASS  C5   PASS  C13   PASS  C12   PASS  C0
  ...
  === mutation: all 37 properties proven load-bearing ===
CHECKS RUN: 15  RED: 1
MUTATION HARNESS: exit 0 (every property proven load-bearing)
exit: 1
finished: 2026-09-12T19:12:50Z  (355 s)
```

Full output: `round6-measurement-2026-09-12-logs/fourteen-checks-and-mutants.txt`. Fifteen = the fourteen frozen checks plus one ADDED (C0: the sandbox ends clean — every ending in the store reads landed or discarded, no agent workspace or branch survives, the hooks reported nothing unexpected). None of the fourteen was removed or reworded. The harness is `engine/scripts/workspace-spec-fourteen.test.sh`; it drives the hook scripts exactly as `hooks/hooks.json` registers them, with the payload shapes the platform sends. The one red is C14.1, §2 point 14.

## 2. The fourteen, one by one

Columns: the frozen check (brief §4, verbatim), the engine, the command, its real output (the decisive lines), the verdict, and the mutations by label — **R** = RECORDED (incident file, section, date), **S** = SPEC-DERIVED (the sentence's negation, constructed). Every mutant was watched turning its named sub-assertion red (`round6-measurement-2026-09-12-logs/fourteen-checks-and-mutants.txt`, the `PASS  R-…`/`PASS  S-…` lines). Commands are the harness's own sub-assertions; the sandbox `T` is a `mktemp -d`.

### 1 · Creating a non-native workspace not named `cc/` is refused — non-zero exit, nothing created.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C1.1 workspaces.sh register-cc --branch feature/x            -> exit 2 "is not named cc/ (point 1)"; no record, no directory
C1.2 Bash guard: git worktree add $T/raw-feature -b feature/y  -> exit 2 "REFUSED"; $T/raw-feature absent
C1.3 Bash guard: git worktree add $T/raw-cc -b cc/zach-opus-raw -> exit 2 (a raw add is refused even when named cc/: it is registered by nothing)
C1.4 POSITIVE CONTROL create-teammate-worktree.sh other zach-opus-c1 -> exit 0, cc/zach-opus-c1 exists and is registered
C1.5 that control, registered but never spawned into: discard exit 2 (not finished), stop, discard exit 0, gone   [OBSERVED, see §8]
```
Mutations: **R 0** — the three records hold no mechanical incident for point 1 (the four pre-spec `zach-opus-dor*` trees are excluded by the CEO's own second sentence and are not a failure of this code). **S 2**: `S-p01-non-cc-registered` → C1.1 red; `S-p01-raw-worktree-add-allowed` → C1.2 red.

### 2 · No deletion path reaches a `codex/` path or ref: with `codex/` present in the fixture, every deleter runs and `codex/` is byte-identical after. An agent briefed against `codex/` work gets a `cc/` copy.
Engine: spec (sandbox). Verdict: **GREEN**.
```
fixture: codex/fix worktree with a commit, branch codex/other; state hash = refs + worktree listing + every file (sha256)
C2.1 an automatic land (Stop gate exit 0), a discard (exit 0), `workspaces.sh retry`, a SessionStart scan — all ran
C2.2 Bash guard: git branch -D codex/other / git worktree remove <codex> / rm -rf <codex> / ...with worktree-remove-ack -> 2 2 2 2 (no override)
C2.3 spawn with cross-repo-worktree: <codex path>            -> exit 2, names codex/
C2.4 create-teammate-worktree.sh --base codex/fix             -> exit 3 "branch from the commit instead"
C2.5 create-teammate-worktree.sh --base $(rev-parse codex/fix) -> exit 0: cc/zach-opus-cc at the codex/fix commit (the copy)
C2.6 state hash before == after; codex/fix and codex/other present, worktree listed
```
Mutations: **R 0** — no record holds a `codex/` incident (the 09-11 record's G2/G3/G6 are Rich's over-wide briefs about `codex/`, not the machinery touching one). **S 2**: `S-p02-bash-guard-lets-codex-branch-go` → C2.2; `S-p02-cc-copy-not-required` → C2.4. The library's own `delete_branch`/`remove_workspace` codex guards are covered by the existing unit mutant `p02-codex-branch-deleted` (§3).

### 3 · A registration failure means the spawn does not happen; `claude -w` is refused; an unregistered `cc/` or native workspace appears in point 5's pending list.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C3.1 RICHOS_SESSION_PID=999999 (no such process): spawn guard exit 2, mentions registration; no record
C3.2 Bash guard: claude --worktree / claude -w / cd x && claude -w --model opus -> 2 2 2
C3.3 SessionStart with cwd inside .claude/worktrees/lead-here: session record carries "forbidden"; lead Edit -> 2, lead Read -> 0
C3.4 raw cc/ worktree with a commit: Stop gate exit 2 naming orphan-rogue-cc
C3.5 raw native agent-deadbeef... worktree with a commit: Stop gate names orphan-agent-deadbeefdeadbeef0
C3.6 spawn refused while they are pending (exit 2)
C3.7 both discarded (0 0), directories and branches gone
```
Mutations: **R 2**: `R-p03-registration-without-identity` [09-10 §3.4: an ownership row with no agent id; sage brief-audit §4.2: the live spec store's one record has `agent_id ""`] → C3.1; `R-p03-unregistered-never-listed` [09-10 §3.1, §2.11] → C3.4. **S 2**: `S-p03-worktree-session-allowed` → C3.3; `S-p03-claude-w-allowed` → C3.2.

### 4 · After a land: workspace absent, branch absent, no prompt, no quarantine directory, no registry entry.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C4.1 merged cc/ work: the Stop gate lands it itself, exit 0, no "land" in its message (no prompt)
C4.2 both workspaces absent from disk and from `git worktree list`
C4.3 both branches absent
C4.4 find $T -iname '*retired*' -o -iname '*quarantin*' -> empty; no `detached` entry in either repository's worktree list
C4.5 agents/ holds nothing for it, `workspaces.sh status` lists nothing for it, done/ has its ending
```
Mutations: **R 2**: `R-p04-branch-left-after-land` [09-12 §2c: `git branch --contains 6fd5aef8` → three branches left after the land; addendum §A2: 22 deleted by hand, none by the system] → C4.3; `R-p04-quarantine-instead-of-delete` [addendum §A4: two `.richos-retired` quarantines at 16:12Z/16:13Z; frank P7; sage §4.4] → C4.4. **S 1**: `S-p04-no-automatic-land` → C4.1.

### 5 · With one finished-and-unlanded agent, a spawn and a turn end are both refused; the two allowances his sentence names are allowed; nothing else is.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C5.1  spawn refused (2), naming zach-opus-a1;  C5.1b turn end refused (2), naming it
C5.4  NOTHING ELSE: a turn begun by <task-notification> naming the work -> 2
C5.5  NOTHING ELSE: a reply to the CEO not naming it -> 2
C5.2  ALLOWANCE 1: a reply to the CEO (transcript has his message) naming it -> 0
C5.3  NOTHING ELSE: the same reply again, nothing moved -> 2 (allowance spent)
C5.6  ALLOWANCE 2: spawn with `lands-pending: zach-opus-a1` -> 0;  C5.7 turn may end while it waits on that agent (0)
C5.8  NOTHING ELSE: unrelated new work still refused (2)
C5.9  merged: both landed on their own, turn ends (0)
```
Mutations: **R 2**: `R-p05-turn-end-not-blocked` [09-10 §3.1, §2.11: the notice went quiet, the turn ended over five never-landed branches] → C5.1b; `R-p05-new-work-not-blocked` [09-12 §5 Type D: four more finished agents' worktrees left while new agents were spawned] → C5.1. **S 2**: `S-p05-answer-allowance-unlimited` → C5.3; `S-p05-notification-counts-as-the-ceo` → C5.4.

### 6 · Points 3 and 4 again, against a native `agent-<id>` / `worktree-agent-<id>` pair.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C6.1 spawn registered (0); after SubagentStart + PostToolUse[Agent] the record carries "kind": "native", the path and worktree-agent-<id>
C6.2 PostToolUse[Agent] for a tool_use_id no PreToolUse registered: no record, no ids/ entry; lock-out refuses Edit (2)
C6.3 merged: automatic land (0); native workspace absent, branch absent, no quarantine, no agents/ record, done/ has it
(C3.5 above: an unregistered native workspace is in point 5's list)
```
Mutations: **R 1**: `R-p06-native-workspace-not-registered` [09-10 §3.4: "the sealed manifest is taken at spawn, so a workspace created later joins nothing"; two workspaces unreclaimable for a session] → C6.1. **S 1**: `S-p06-native-branch-kept` → C6.3.

### 7 · Every ending reads `landed` or `discarded` in the store; a discard carries its reason; an agent that produced nothing reads `landed`; CEO-ordered work cannot be discarded without a recorded word.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C7.1 done/…zach-opus-l1.json disposition.kind == "landed"
C7.2 done/…zach-opus-c2b.json kind == "discarded", reason present, tips present
C7.3 spawn, no commits, SubagentStop: Stop gate 0, done/ kind "landed", workspace gone
C7.4 prompt line `ceo-ordered: build the thing, his words 2026-09-12`: discard --not-ceo-ordered -> 2 "his word"; workspace kept
C7.5 discard --ceo-word 'drop it, he said 2026-09-12' -> 0; done/ disposition.ceo_word == that string
C0.1 every record in done/ at the end: kinds == ['discarded', 'landed']
```
Mutations: **R 1**: `R-p07-discard-records-no-reason` [addendum §A2: 22 deletions with no reason anywhere; 09-10 §2.2] → C7.2. **S 2**: `S-p07-ending-reads-neither` → C7.1; `S-p07-ceo-order-discardable` → C7.4.

### 8 · A land of a tree with uncommitted or needed-ignored files is refused; after the commit it proceeds; nothing under the tree is lost by the deletion.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C8.1 draft.txt uncommitted, .env ignored: land -> 2 "uncommitted entr… draft.txt"; tree untouched;  C8.2 Stop gate pending (2)
C8.3 draft committed and merged: land -> 2 "ignored" (.env the main checkout lacks); .env kept
C8.4 .env copied to the main checkout: land -> 0; workspace and branch gone
C8.5 every path of the agent's tip is in the main checkout; .env bytes match; tip is an ancestor of main
```
Mutations: **R 1**: `R-p08-ignored-needed-files-landed` [09-10 §3b.2: an ignored nested repository deleted with no copy; `inflight-ack.sh` header, 2026-09-05: three gitignored acks deleted with an unchanged worktree] → C8.3. **S 1**: `S-p08-uncommitted-landed` → C8.1.

### 9 · A restarted finished agent gets no tool; a process started inside the workspace is dead before deletion (fixture: a sleeper holding an open file).
Engine: spec (sandbox). Verdict: **GREEN**.
```
fixture: `cd <workspace>; exec 3<held.txt; sleep 3600 &` — cwd inside, a file open
C9.1 finished: lock-out refuses Read (2) and Bash (2)
C9.2 POSITIVE CONTROL: the sleeper is alive before the land
C9.3 automatic land (0): kill -0 <pid> fails; workspace gone
C9.4 events.jsonl order for that agent: processes-stopped, then deleted
C9.5 restarted after the workspace is gone: Write refused (2)
```
Mutations: **R 2**: `R-p09-finished-agent-not-locked-out` [09-10 §3b.1, §3b.5: thirteen restarts after the terminal record; 09-11 S4] → C9.1; `R-p09-processes-not-stopped` [femcboost CLAUDE.md "Corollary (zombie residue, 2026-07-18)"; frank P11: VM pid 1483 holding 324 files five days after] → C9.3. **S 0** (both mutations the record supplies are the sentence's two clauses).

### 10 · Landing a two-workspace agent removes both workspaces and both branches in one operation.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C10.1 POSITIVE CONTROL: the record holds 2 live workspaces (cc/ in other, native in entity), both exist
C10.2 ONE `workspaces.sh land` (0): both directories gone, both unlisted
C10.3 both branches gone
C10.4 the store: exactly one `landed` and one `deleted` event for it (landed=1 deleted=1)
```
Mutations: **R 1**: `R-p10-cc-workspace-left-behind` [addendum §A4: native halves gone, cc/ halves quarantined; 09-10 §3.4: zero of 15,882 finish rows named a cross-repository workspace] → C10.2. **S 1**: `S-p10-cc-branch-kept` → C10.3.

### 11 · A `SubagentStop` for a sub-run does not finish the teammate; a pause is recorded with what ends it; a pause naming nothing appears in point 5's list.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C11.1 two SubagentStops with sub-run ids (asubrun00000000001/2): teammate may still write (0), nothing pending (0)
C11.2 SendMessage `pause-until: the CEO's answer` through the lifecycle hook: record.pause.until == "the CEO's answer"
C11.3 its own SubagentStop while paused: not locked out (0), not pending (0)
C11.4 a later message resumes it (0), pause cleared
C11.5 `workspaces.sh pause --until ''` then its end: Stop gate 2, names it, "nothing named"
C11.6 stopped: refused (2); merged: landed (0)
```
Mutations: **R 1**: `R-p11-sub-run-end-finishes-the-teammate` [09-10 §3.5: the finish event's id is a per-run id and the owner was derived from the folder; addendum §A3: 974 rows / 25 teammates / 973 ids] → C11.1. **S 2**: `S-p11-pause-ignored` → C11.3; `S-p11-nameless-pause-not-pending` → C11.5.
What this does not settle: the check's first clause is satisfied on `c5bce604` by `record_end` ignoring an id it has no registration for. Whether the platform's FINAL `SubagentStop` for a teammate carries the bound id is a fact about the platform, not about this code; §6 §A3 shows it does for 20 of 25 teammates today (unverified for the ordering — see there).

### 12 · The session is recorded at start; its end is read from the process start-time, never a pid alone; the next session lands or discards the previous session's agents before any spawn.
Engine: spec (sandbox). Verdict: **GREEN**.
```
C12.1 sessions/<id>.json carries pid AND pid_start
C12.2 same live pid, recorded start time rewritten: the agent is locked out (2) — "no longer session"
C12.3 POSITIVE CONTROL: start time restored, the agent is live again (0)
C12.4 session process killed; SessionStart of the next: its context names zach-opus-w1 and says FIRST
C12.5 spawn in the new session refused (2) until it is handled
C12.6 landed by the next session (0); workspace gone; then the spawn is allowed (0)
```
Mutations: **R 1**: `R-p12-ended-session-agents-not-finished` [sage brief-audit §4.3: 26 holds from two ended sessions still held; 09-10 §2.5] → C12.4. **S 2**: `S-p12-a-pid-alone-is-the-session` → C12.2; `S-p12-next-session-does-not-take-over` → C12.5.

### 13 · A deletion blocked by a held file is retried without involvement and succeeds when the hold clears; the CEO hears only after a stated number of failures.
Engine: spec (sandbox). Verdict: **GREEN**.
```
fixture: `chflags uchg pinned.txt` inside the native workspace (the OS refuses the delete); RICHOS_WORKSPACES_RETRY_BASE=0
C13.1 Stop gate 0: disposition landed, deletion.attempts 1, workspace still there, next_at set
C13.2 no "TELL THE CEO" at attempt 1
C13.3 two unrelated SubagentStop hook events later: attempts >= 3 — no command was run
C13.4 attempts below the stated number (RETRY_TELL_CEO_AFTER = 5): still not told
C13.5 at 5: "TELL THE CEO" names zach-opus-k1; the turn still ends (0)
C13.6 chflags nouchg; the next hook event: workspace and branch gone, nothing retrying, done/ has it
```
Mutations: **R 1**: `R-p13-failed-deletion-not-retried` [09-10 §2.17: "a virtual machine holding files open, and the prefix was irrelevant"; frank P5: four trees held by VM pid 1483, RETRY forever] → C13.3. **S 1**: `S-p13-ceo-told-at-the-first-failure` → C13.2.

### 14 · The integration branch is recorded before the first spawn, or the spawn is refused naming what to record; **every** consumer asks the recorded branch and none asks `main` — `guard-unresolved-claims.sh`, `unlanded-branches.py`, and on `main` also `reconcile-terminal-worktrees.py` and `workspace-retire.py`.
Engine: spec (sandbox). Verdict: **RED — C14.1.**
```
C14.1 with NO branch recorded, spawn zach-opus-n0 -> guard exit 0, stderr empty        <<< RED: the spawn is not refused
C14.2 workspaces.sh integration --repo <entity|other> --branch main; --repo <dev> --branch dev/work -> 0 0 0, record names dev/work
C14.3 work fast-forwarded onto dev/work (never on main): landed on its own (0); workspace and branch gone; tip not on main
C14.4 unlanded-branches-lint.sh <dev> --json: "trunk": "dev/work"; a branch ahead of dev/work is named, exit 1
C14.5 unlanded-branches-lint.sh <repo with no record>: exit 2 (ABSTAIN), not an answer against main
C14.6 guard-unresolved-claims.py state_verdict("integrated", <tip on dev/work>) -> ('ok',); with no record -> ('unknown',)
C14.7 INTEGRATION_REFS = ("main", "master", ...) still declared at guard-unresolved-claims.py:609; referenced by no code (0 uses)
```
`reconcile-terminal-worktrees.py` and `workspace-retire.py`: not on this base (deleted at `ca4ba9f8`); the check names them "on `main`", and `main` was not measured (§0).
Mutations: **R 1**: `R-p14-land-assumes-main` [09-12 §2c and sage brief-audit §4.6: a true land onto `dev/workspace-spec` refused by a `main` check; 19 holds "NOT on refs/heads/main"] → C14.3. **S 2**: `S-p14-consumer-keeps-its-own-answer` → C14.6; `S-p14-unlanded-sweep-assumes-main` → C14.5. C14.1 has no mutant: it is red on the base, and its mutation is round 7's fix.
Why it is red, in the code: `register_spawn` → `_add_workspace` → `_bind_body_of_work`, whose comment says *"nothing recorded yet: bound to nothing, heals later"* — the base chose to let the LAND refuse instead of the SPAWN. The frozen check reads the sentence "recorded … before its first agent is spawned" as a guarantee the system gives, which only a refusal can give. I believe the check is right as written; the alternative reading (Rich's habit records it, the land catches the omission) is exactly the kind of "holds whether or not Rich remembers" that point 5 forbids for its own guarantee. Round 7's call, not this round's.

### Added · C0 — the sandbox ends clean.
Every `done/` record reads landed or discarded; no agent holds a workspace in `agents/`; the entity repository has one worktree; the other has two (main and the untouched `codex/`); no `cc/` or `worktree-agent-*` branch survives; `hooks.err` is empty. **GREEN.**

### Mutations, counted per point

| point | RECORDED | SPEC-DERIVED | record thin? |
|---|---|---|---|
| 1 | 0 | 2 | **yes** — no mechanical incident in any of the three records |
| 2 | 0 | 2 | **yes** — none |
| 3 | 2 | 2 | |
| 4 | 2 | 1 | |
| 5 | 2 | 2 | |
| 6 | 1 | 1 | |
| 7 | 1 | 2 | |
| 8 | 1 | 1 | |
| 9 | 2 | 0 | |
| 10 | 1 | 1 | |
| 11 | 1 | 2 | |
| 12 | 1 | 2 | |
| 13 | 1 | 1 | |
| 14 | 1 | 2 | (C14.1 itself has none: it is the red) |
| **total** | **16** | **21** | 37 mutants, 37 proven |

Every want names a sub-assertion, never a check: C14 is red on the base, so a mutant wanting `FAIL  C14 ` would have been "proven" by a suite that was red before the mutation touched anything (the 09-10 record's Type A, absence reading as success). The first run of the harness caught two of my own mutants passing for that reason at C5.4 and C8.1 — the notification case was asked after the answer allowance was already spent, and the uncommitted-file grep matched the refusal's boilerplate — both are fixed in the committed harness and both now turn red for their own reason.

## 3. The 105 existing cases, mapped onto the fourteen

Baseline on this base, sandboxed (`round6-measurement-2026-09-12-logs/baseline-*.txt`):
```
$ bash engine/scripts/lib/workspaces.test.sh     -> Ran 58 tests, OK; === mutation: all 43 properties proven load-bearing ===
$ bash engine/scripts/workspaces-e2e.test.sh     -> workspaces-e2e: 47 passed, 0 failed
```
(The implementation record's "20 mutants" was the count when it was written; the harness on `c5bce604` declares 43.) The 47 end-to-end checks are E0.1, E1.1–E1.10, E2.1–E2.7, E3.1–E3.8, E4.1–E4.10, E6.1–E6.7, E5.1–E5.4.

| point | unit tests (class, count) | end-to-end cases | what they already ask | what only the fourteen ask |
|---|---|---|---|---|
| 1 | `Point01_CcNaming` (2) | E3.1 (positive) | register_cc refuses a non-cc branch | refusal of a raw `git worktree add` through the Bash guard (C1.2, C1.3) |
| 2 | `Point02_Codex` (1) | none | delete_branch/remove_workspace refuse codex; spawn into codex refused; a land leaves codex alone | every deleter driven through the hooks with a byte-identity hash (C2.6); the Bash guard (C2.2); the `cc/` copy via `--base` (C2.4, C2.5) |
| 3 | `Point03_TwoEvents` (7) | E3.6, E3.7 | failed registration = no spawn; unregistered cc/ and branch are finished work; `claude --worktree` session forbidden; attribution cases | `claude -w` through the Bash guard (C3.2); the forbidden session's lock-out through the hook (C3.3); an unregistered NATIVE workspace in the list (C3.5) |
| 4 | `Point04_LandedMeansDeleted` (1) | E1.7–E1.9, E2.4, E3.3–E3.5, E4.8, E6.7 | workspace and branch gone after an automatic land | "no quarantine directory" and "no registry entry" by name (C4.4, C4.5) |
| 5 | `Point05_Guarantee` (9) | E1.5, E1.6, E4.2, E4.4, E4.5, E6.3, E6.4 | gate and spawn refusals; the CEO answer; the allowance spent once; waiting items; started helper; next session | the "nothing else" cases through the Stop hook with a transcript (C5.3–C5.5, C5.8) |
| 6 | `Point06_Native` (2) | E1 entire (a real native workspace) | registration at SubagentStart/PostToolUse in either order; deleted on land | an unregistered native id refused by the lock-out (C6.2) |
| 7 | `Point07_LandedOrDiscarded` (5) | E2.3–E2.6 | discard with reason; CEO-ordered needs his word; produced nothing = landed; continuation | CEO-ordered end to end from the prompt line to the recorded word (C7.4, C7.5); produced-nothing through the hooks (C7.3); every done/ kind (C0.1) |
| 8 | `Point08_NothingUncommitted` (2), `Point08b` (1) | E4.6, E4.9, E6.3 | uncommitted refuses; ignored-needed refuses; a borrowed branch survives | ignored-needed end to end (C8.3), nothing lost by path listing (C8.5) |
| 9 | `Point09_NeverWritesAgain` (4) | E1.4, E1.10, E4.3 | finished refused every tool; read-only restarted refused; paused not locked out; processes stopped | a real sleeper with an open file, and the ORDER stopped-then-deleted from the store (C9.2–C9.4) |
| 10 | `Point10_AllTogether` (4) | E3.4, E3.5, E6.7 | both workspaces as one; created branches go with it; side branch blocks; Rich's cut is not the agent's | "in one operation" as one land event and one deletion event (C10.4) |
| 11 | `Point11_Finished` (5) | **none** | finished vs paused; pause via SendMessage; nameless pause pending; handed-in then ended; stopped | all of C11 through the hooks; a sub-run's `SubagentStop` under a foreign id (C11.1) |
| 12 | `Point12_Sessions` (4) | E1.1, E4.2–E4.5 | SessionEnd; process gone; reused pid; two sessions | reused pid through the lock-out hook (C12.2); spawn refused in the next session until landed (C12.5) |
| 13 | `Point13_Retry` (1) | **none** | retry until success, CEO told after 5 (chmod fixture) | all of C13 through the hooks with an OS-held file (`chflags uchg`), retries driven by unrelated hook events, the threshold read from the source (C13.1–C13.6) |
| 14 | `Point14_IntegrationBranch` (10) | E0.1 | dev-branch land; unmerged not landed; recorded never inferred; second body of work; attribution windows | the consumers (`unlanded-branches-lint.sh`, `guard-unresolved-claims.py`) end to end against a dev branch and against no record (C14.4–C14.7); the spawn with no record (C14.1 — RED) |

The brief's two columns held: on the base every point had a green check; 2, 11 and 13 lacked an end-to-end case (now they have one each); no mutation was record-derived (now 16 are).

## 4. The regression runner (§7) — three things changed, and what they measured

`engine/scripts/workspace-probes.py` @ `3ceba3ea`, its suite and mutation harness, and `docs/verification/workspace-probes.manifest`:

1. **The witness is the recorded integration branch.** A3 accepts a retirement, or a later-added `not-a-probe:` marker, when its introducing commit has LANDED on the branch `integration_for(<repo>)` records (point 14). Only Rich writes that branch; point 4 never deletes it. With nothing recorded, every retirement is refused and the recording command is named — never a fallback to `main`.
2. **MISSING is asked of git.** A path counts as present only at HEAD; a manifest entry absent at HEAD is MISSING; a deletion is excused only by a whole-file retirement that passes the name check and A1–A3 — an uncommitted line, or a landed line signed by anyone else, excuses nothing.
3. **Discovery is a committed manifest**, read from `HEAD:docs/verification/workspace-probes.manifest`, never the working tree; the text rule stays as the backstop in the other direction: a committed file that looks like a probe and is not listed is UNLISTED and blocks.

Its suite, with the fixture reshaped to the real repository (main = the recorded branch, `cc/engineer` = the branch under test, a reviewer's line landed on main and merged in):
```
$ bash engine/scripts/workspace-probes.test.sh      # round6-measurement-2026-09-12-logs/runner-suite-and-mutants.txt
=== workspace-probes tests: all 40 passed ===        (W1–W29; new: W26 UNLISTED blocks, W27 manifest-from-git, W28/W28b the witness survives
=== mutation: all 16 properties proven load-bearing   branch deletion / a branch cut at the tip is no witness, W29 no record -> refuse)
```
On the real tree, with `dev/workspace-spec` recorded in a SANDBOX store (`round6-measurement-2026-09-12-logs/runner-on-this-branch.txt`):
```
$ RICHOS_WORKSPACES_DIR=<sandbox> engine/scripts/workspaces.sh integration --repo <this worktree> --branch dev/workspace-spec --why '...'   -> exit 0
$ python3 engine/scripts/workspace-probes.py
probes discovered:        11 (11 listed at HEAD, 0 on other branches)
integration branch:       dev/workspace-spec @ c5bce604b6cd (recorded; the witness every retirement must have landed on)
DECLARED   …/adapt-c3-probes-to-record-the-branch.py
GREEN  x8   RETIRED x2 (sage's two, "1329ec67b86e, landed on dev/workspace-spec @ c5bce604b6cd")
RED        docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py   exit 1
```
The one RED is the pre-existing 5/10 of Frank's `-recorded-` probe, red on the base before this round (`workspace-probe-regression-2026-09-12.md`, escalated by the previous engineer as `esc-20260912T132131Z-fda1ccda`); it is its author's to retire or the build's to fix, and this round does neither. On this machine with the operator's store the runner says `integration branch: NOT RECORDED` and refuses both retirements — which is point 14 applied to the runner, and the reason the recording command is printed in the header.

Two defects found in the runner's own fixture while doing this, both explained in place in the suite: the runner wrote `__pycache__` beside the library it loaded and `git add -A` swept it into a reviewer's commit (A2 then refused the reviewer for "changing the engine"); and clearing the retirements by deleting the file made the next land a modify/delete conflict that no merge strategy resolves, so every case after it measured a half-merged fixture.

Left as it was, stated: A2 is still not asked of a later-added marker (Frank's Residual A). Under the new A3 that route needs Rich to LAND the bundled commit, which the old route did not; that is narrower than closed, and it is not one of the three items the brief scoped in.

## 5. Two documents

- `docs/verification/workspace-spec-implementation-2026-09-11.md`: "The thirteen points" → fourteen, a row for point 14, and a note on which counts are which day's (`f2d0943a`). `engine/scripts/lib/workspaces.py` line 4 still says "(thirteen points)" — a library edit, so not this round's.
- `docs/verification/lifecycle-failure-record-2026-09-12-addendum.md` (`c13f8f06`): the record extension, §6 below.

## 6. The record, extended (running engine, read only)

`docs/verification/lifecycle-failure-record-2026-09-12-addendum.md`, mirror-ready as section 11 of the richos-hq record; the brief's CEO constraint forbids touching any main checkout and `/Users/alex/ab/richos-hq` is one, and no richos-hq workspace exists for this round (`ls /Users/alex/ab/richos-hq-wt/` → `codex-rollback-owned-outcome` only). Raised as `esc-20260912T192638Z-f5d5af5e`, state work-complete; the record file it wrote is `docs/verification/escalations/2026-09-12-zach-fable-m1-round-6-…md`, committed. Every number in it is from `round6-measurement-2026-09-12-logs/measure-live.py`, output in `measure-live.out`:

- **A1** four `integration-recorded` fixture rows at 12:44Z in the operator's live `state/workspaces/events.jsonl`, for temp-directory repositories that no longer exist.
- **A2** 25 `cc/` branches prepared today, 22 gone; the ledger's whole-history event vocabulary is `finished, prepared, registered, retracted, terminated` — no deletion event exists; 0 rows of any other type mention the gone branches.
- **A3** 974 `finished` rows today, all `SubagentStop` from `worker-ended-handoff.sh`, 973 distinct ids, 0 with a branch, 893 naming a teammate; and for 20 of 25 native workspaces the teammate's own bound id does appear on a finished row.
- **A4** the two `.richos-retired` quarantines, still registered git worktrees of richos at `37bb361c`/`a8fc4203`; `retirements.jsonl` rows `retire quarantined` at 16:12:40Z/16:13:07Z; both `cc/*-opus-c6` branches gone.
- **A5** the ledger grew ten rows in the ninety seconds between the census and its copy, through nobody's action.

## 7. The census — before the first command, after the last

```
$ bash census.sh                                  (round6-measurement-2026-09-12-logs/census-before.txt, 18:31:38Z)
07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9  ~/.claude/state/workspaces (tree, 4 files)
67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1  ~/.claude/state/workspace-retirement (tree, 11286 files)
e6bf7d4ae5759e0813f74c1775cd87ef51047972f51388b02efdb2bbad2321d7  ~/.claude/state/worktree-ledger.jsonl (19691 lines)
$ bash census.sh                                  (census-after.txt, 19:27:41Z)
07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9  ~/.claude/state/workspaces (tree, 4 files)          IDENTICAL
67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1  ~/.claude/state/workspace-retirement (tree, 11286 files)   IDENTICAL
bf90bde29cea0f2ca7b56edf5a94a270de6a9787a8a147362a7ae593abe8f3d5  ~/.claude/state/worktree-ledger.jsonl (19743 lines)   +52 lines
$ python3 ledger-delta.py ledger-before.jsonl ~/.claude/state/worktree-ledger.jsonl        (ledger-delta.txt)
before: 19701 lines   after: 19743 lines
appended: 42 rows; the copy is a prefix of the live file (append-only)
by source: {'worker-ended-handoff.sh': 42}
by event:  {'finished': 42}
rows naming zach-fable-m1 (this agent's own SubagentStop hooks, written by the running engine, not by any command of this round): 42
```
The two stores the spec code and the retirement path write are byte-identical. The ledger is append-only and every appended row is the RUNNING engine's `SubagentStop` hook recording one of this agent's own sub-runs as `finished` — 42 of them in an hour, which is §6 §A3 happening to the agent that measured it. No command of this round wrote to any of the three; the census is not a failed round. The only commands after the census were the write of this file and its `git add`/`git commit` inside this worktree.

## 8. What I believe is wrong, and what is worth knowing that is not a check

- **C14.1's reading of point 14** — see point 14 above. Implemented as written, red; I think the check is right.
- **C11's first clause is a code fact, not a platform fact.** The sandbox can only show the spec code ignores an unregistered id; the platform's real signal shape is in §6 §A3. If round 7 wants the platform half measured, the ledger has the rows.
- **A registered, never-spawned `cc/` workspace is invisible to point 5 until its session ends** (C1.5, observed): `create-teammate-worktree.sh` then a spawn that never happens leaves a registration with no end signal — not finished (point 11), so not pending, and `discard` refuses it until `workspaces.sh stop`. The page's own answer is session end (point 12), which the harness confirmed. Not one of the fourteen; noted for the page's author.
- **`workspace-spec-fourteen.test.sh` exits 1 while C14.1 is red**, by design; `RICHOS_FOURTEEN_SKIP_MUTANTS=1` runs it without its 5-minute mutation harness.
- **The two retirements on this machine are refused by the new runner** until `dev/workspace-spec` (or `main`, once landed there) is recorded for `/Users/alex/ab/richos` in the store the running engine uses — which today is no store at all. That is point 14 applied to the runner; the header says what to run.

## 9. What I did NOT do

No merge, no push, no `install.sh`, no write into `/Users/alex/ab/richos/engine` or `/Users/alex/ab/richos`, no write into `/Users/alex/ab/richos-hq`, nothing `codex/` read or written. No fix to any red point (C14.1 stands). No edit to `workspaces.py`, the hooks, or any probe or retirement. No run of the running engine's reconciler or retirement tools (`--preview` could append to the ledger under census; both reviewers' numbers are cited instead). The full engine test sweep and `contract-integrity.test.sh` were not run (the brief did not ask; a land does).

## 10. Commits on `cc/zach-fable-m1`, oldest first

| sha | what |
|---|---|
| `79d030c4` | the fourteen checks, frozen, measured through the real hooks; 37 mutants (16 recorded, 21 spec-derived), all proven |
| `3ceba3ea` | the runner: witness = the recorded integration branch, MISSING from git, discovery from a committed manifest; suite 40/40, 16 mutants |
| `f2d0943a` | the implementation record counts fourteen |
| `c13f8f06` | the record extension (addendum §A1–A5) |
| (this) | this report, its logs, and the escalation record |
