BRIEF NOT READY

# Frank — audit of the round 6 brief (`round6-brief-fourteen-points-2026-09-12.md` @ `095ab795`)

**What was audited:** `/Users/alex/ab/richos-hq/docs/plans/round6-brief-fourteen-points-2026-09-12.md` at
`richos-hq` `095ab795`, against the spec `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`.
**Nothing was built, installed, merged or pushed.** Every command below ran read-only from
`/Users/alex/ab/richos-wt/frank-fable-b1` (branch `cc/frank-fable-b1`, cut at `dcabcbd9` = `main`) or from a
`git archive c5bce604` export in the session scratchpad. `~/.claude/state/workspaces` was sha256-censused before
and after: **4 files, identical**. Sage's work was not read (the one Sage-authored commit this audit touches,
`a8fc4203`, was identified by file list only).

---

## 0. The finding that decides the verdict

**The brief measures two different engines and prints one scoreboard.**

```
$ ls -la /Users/alex/.claude/richos-engine
lrwxr-xr-x  … /Users/alex/.claude/richos-engine -> /Users/alex/ab/richos/engine
$ cat /Users/alex/ab/richos/.git/HEAD ; git rev-parse main
ref: refs/heads/main
dcabcbd99056928a9872cd94c1f3a385f8b21069
$ grep -rl 'state/workspaces' /Users/alex/.claude/richos-engine/scripts | wc -l        → 0
$ grep -rl 'worktree-ledger.jsonl' /Users/alex/.claude/richos-engine/scripts | wc -l   → 26
$ git grep -l 'state/workspaces' c5bce604 -- engine/scripts | wc -l                    → 10
$ git ls-tree --name-only c5bce604 engine/scripts/ | grep -E 'reconcile|retire'        → (none)
$ git ls-tree --name-only main      engine/scripts/ | grep -E 'reconcile|retire'
engine/scripts/reconcile-terminal-worktrees.py  (+ .test.sh, .mutation.sh)
$ git log --oneline -1 dev/workspace-spec -- engine/scripts/reconcile-terminal-worktrees.py
ca4ba9f8 Remove every workspace deleter the spec does not have, with its tests
```

- **Points 3, 6, 12, 14** were measured by reading `~/.claude/state/workspaces/`. Only the code at `c5bce604`
  writes that store. That code is **not installed** (the installed engine is `main`, which has zero references
  to it). An empty store therefore says nothing about whether registration happens; it says the spec's code
  is not running, which the CEO ordered.
- **Points 4, 10, 13** were measured with `reconcile-terminal-worktrees.py` and `workspace-retire.py` — tools
  that exist on `main` and were **deleted at `ca4ba9f8` on the branch this round is cut from**. Every string
  the brief quotes for those points (`hold=`, `within-retention`, `automatic-erasure-disabled`,
  `branch-checked-out`, `no transaction of this engine owns it`) has **0 hits** in the `c5bce604` engine.

An engineer cut from `c5bce604` cannot reproduce the point 4/10/13 measurements, and nobody can reproduce the
point 3/6/12/14 measurements until the spec's code runs somewhere. The scoreboard is not wrong in one cell; it
is unmeasurable as posed.

---

## 1. Every premise, re-derived

| # | Brief asserts | Command and real output | Verdict |
|---|---|---|---|
| P1 | `ls -d /Users/alex/ab/*-wt/*/` → 11 directories | Same command now → **13** (`frank-fable-b1`, `sage-fable-b1` added since). 4 `zach-opus-dor*`, 7 `codex-*`, 2 `cc/`. | Holds for its time. |
| P2 | `workspaces/agents` holds ONE record "while at least four agents ran" → "Registration is not happening" | Record `registered_at 2026-09-11T23:57:34Z`, `spawned_at 23:58:13Z`, i.e. 00:57–00:58 local — **inside the 00:39:24→01:13 window when the spec build was merged into `/Users/alex/ab/richos` main** (09-12 record §4; unreachable commits `9935e1cb` 00:39, `9b68a1f5` 01:13). Installed ledger, parsed: `rows today 973 … registered 48, prepared 24` → **24 teammates registered today, each with a `native` and a `hand-rolled` row, all under session `16a15be1`**. | **FALSE.** Registration happened exactly when the spec code was on `main` and stopped when `main` was reset. The installed engine registers every spawn in `worktree-ledger.jsonl`. "At least four" is 24. |
| P3 | `ls ~/.claude/sessions/ \| wc -l` → 2 | `ls -la ~/.claude/sessions/` → `24267.json` + `24267.<hex>.key` — **one session**, two files. | **Laundered count.** One session, not two. |
| P4 | `integration.json` ABSENT | ABSENT, true. But `workspaces/events.jsonl` carries **4 `integration-recorded` rows at 12:44 and 13:44 today** for repos under `/private/var/folders/…/land-completeness.*/` and `ls -d` of those paths → none exist. `refs/` mtime 13:44. | Omitted: **a c5-lineage test suite wrote fixture rows into the operator's real store today** — failure S1/S2 of the 09-11 record, recurring, unmentioned. |
| P5 | `reconcile --preview` → `remove=0 … hold=49`; "the sanctioned tool quarantines instead of deleting … so the hold never ends" | Reproduced: `remove=0 branch-only=14 observe=0 hold=49 excluded=9 not-examined=2`. Of the 49 holds, **45 are ledger rows for `richos-wt/<name>` paths that no longer exist** ("removed workspace has no retained completion proof" / "NOT on refs/heads/main by patch id"); **4 are the `dor` trees** held as `RETRY, not a verdict: process 1483 (com.apple.Virtualization.VirtualMachine)`. `lsof -p 1483 \| grep -c zach-opus-dor` → **324** open files. The 14 `branch-only` rows name femcboost branches; `git for-each-ref refs/heads/worktree-agent-*` → only 2 exist (mine and sage-fable-b1's). | `remove=0` means **nothing exists for it to remove**, not "it refuses to delete". Its "unlanded" verdicts come from comparing to `refs/heads/main` — a **second point-14 consumer** the brief does not name. And the tool is not in `c5bce604`. |
| P6 | femcboost `grep -c 'agent-'` → 0 | `.git/worktrees/` now lists `agent-a190161586623495a` (sage-fable-b1) and `agent-a4d89db5ef850b2cd` (me), both locked. | Holds for its time. |
| P7 | Point 10: "Retiring each removed the `cc/` one; the native ones are still registered (`ws-71d9…`, `ws-79d4…`)" | `workspace-retire.py list --repo femcboost` → **130 entries, 128 `present=False`**, the two cited among them; it is a historical registry. femcboost `.git/worktrees/`: no `c6` entry; `for-each-ref worktree-agent-*`: no `c6` branch. richos `.git/worktrees/`: `frank-opus-c6` and `sage-opus-c6` **still registered**, gitdir under `richos-wt/.richos-retired/…`, HEAD detached at `37bb361c` / `a8fc4203`. | **Inverted.** The native workspace AND branch are gone (harness auto-clean of an unchanged tree). The `cc/` workspace survives, renamed into quarantine, still in git's registry. That is the real point-10 leftover. |
| P8 | "Today Rich deleted three landed branches by hand" — is everything on `dev/workspace-spec`? | `git branch --list` in richos → `cc/frank-fable-b1`, `cc/sage-fable-b1`, 5 `codex/`, `dev/workspace-spec`, `main`. Ledger: 24 `cc/` branches prepared today → **22 deleted**, not three. `git log --merges main..dev/workspace-spec` names 13 lands. `merge-base --is-ancestor 37bb361c dev/workspace-spec` → YES; `a8fc4203` → YES. `git fsck --unreachable --no-reflogs` → 218 commits; **none dated after 08:02 today** (the last is the spec-mirror re-pin `1cf17afd`). | **Nothing lost.** But ledger event types today are `finished/prepared/registered` only — **no deletion of any of the 22 branches is recorded anywhere**, which is point 7's "reason recorded" already failing on the live machine. |
| P9 | Point 1: four `zach-opus-dor*` are non-native, non-`codex/`, not `cc/` → FAILS | Real git worktrees (`.git` → `<repo>/.git/worktrees/zach-opus-dorN`), HEAD `refs/heads/zach-opus-dorN`, unlocked, created **2026-09-10 08:30–10:56** by the installed engine (`prepared hand-rolled` rows, session `d0eef867`) — **before the spec existed**. Held open by VM pid 1483 (started Sep 7). Not in `repos.json`. | They are pre-spec legacy. The CEO's own second sentence — *"only `cc/` ones are the system's concern"* — means point 1 **cannot fail on them**; the spec has no sentence for a pre-existing non-`cc/` non-native workspace. That is a **gap for the CEO to close**, not a red cell. |
| P10 | Point 9 "has a recorded failure (2026-07-18 zombie residue) to derive mutations from" | `grep -nE '07-18\|zombie\|orphan' lifecycle-failure-record-2026-09-1{0,1,2}.md` → **none**. | The incident lives in femcboost `CLAUDE.md`, not in the record the brief itself defines as the derivation source. |
| P11 | Point 9 "NOT MEASURED" | `ps -p 1483` → `com.apple.Virtualization.VirtualMachine`, started `Mon 7 Sep 19:57`; 324 open files inside trees of an agent finished 2026-09-10. | **Measurable today and failing**: a process started in an agent's workspace outlives the agent by five days. |
| P12 | Point 11 "NOT MEASURED" | Ledger totals: `finished 18800, registered 654`; today `finished 901` for 24 teammates; **frank-opus-c6: 43 finished rows, sage-opus-c6: 52**; four `finished` rows for `frank-fable-b1` written while I was running (signal `SubagentStop`, `agent_id` ≠ `owner_agent_id`). | **Measurable today and failing** on the installed engine: the recorded "end-of-run signal" fires on every sub-run, so it cannot be point 11's finished signal. |
| P13 | "You [Frank] proved the gate is silenced by one `git branch` yesterday" | `git show --name-only a8fc4203` → `docs/verification/certification-sage-gate-integrity-2026-09-12-logs/*` — **Sage's commit** (worktree `sage-opus-c6`). Frank's `37bb361c` / `certification-frank-gate-integrity-2026-09-12.md` proved route (c): **the ordinary handoff defeats A3 with no forged branch at all.** | Mis-attributed. Small, but it is a claim copied without being checked. |
| P14 | Every item quotes the CEO verbatim | Mechanical diff of all 14 headings vs the spec: **6 full-verbatim, 7 verbatim fragments joined by `…`, 1 mismatch.** Point 11 drops the CEO's parenthetical *"(the quota reset, the CEO's answer)"* with **no ellipsis**, and his `"Finished"` became `'Finished'`. Point 5 quotes **14 %** of his sentence; the parts the check restates in Rich's words (the two allowances, when a turn may end) are the parts not quoted. | Property 2 of the brief's own three fails on point 11; six others pass only under an "excerpt" reading the brief does not declare. |

---

## 2. The scoreboard, disputed cell by cell

Brief: **failing 1, 3, 4, 10, 13, 14 — incomplete 2, 6, 12 — never measured 5, 7, 8, 9, 11.**

| Point | Brief | Corrected verdict | Why |
|---|---|---|---|
| 1 | FAILS | **SPEC GAP — CEO's word needed** | P9. Four pre-spec worktrees the spec's own second sentence excludes from concern. The refusal-at-creation half is NOT MEASURED. |
| 2 | PARTIAL | PARTIAL — stands | The reconciler's `EXCLUDED` block is `main`'s behavior, not `c5bce604`'s, so even the measured half is measured on the wrong engine. |
| 3 | FAILS | **NOT MEASURABLE until the spec code runs** | P2. The store is empty because nothing installed writes it. The three refusal clauses: NOT MEASURED. |
| 4 | FAILS | **NOT MEASURED at `c5bce604`** | P5. The quarantine/retention/erasure-disabled machinery quoted was deleted at `ca4ba9f8`. The live leftover is two `.richos-retired` directories still in richos's worktree registry — `main`'s residue. |
| 5 | NOT MEASURED | stands | — |
| 6 | PARTIAL | NOT MEASURABLE (registration half); the measured half **passes** (0 leftover native worktrees) | P2, P6. |
| 7 | NOT MEASURED | **MEASURABLE, FAILS live** | P8. 22 branch deletions today, zero recorded with a reason. |
| 8 | NOT MEASURED | stands | — |
| 9 | NOT MEASURED | **MEASURABLE, FAILS live** | P11. |
| 10 | FAILS | FAILS — **for the inverted reason** | P7. `cc/` left (quarantined), native gone. |
| 11 | NOT MEASURED | **MEASURABLE, FAILS live** | P12. |
| 12 | INCOMPLETE | NOT MEASURABLE until the spec code runs; the "2 vs empty" disagreement is 1 session vs an uninstalled store | P2, P3. |
| 13 | FAILS | NOT MEASURED at `c5bce604`; on `main` the retry semantic **exists** (`RETRY, not a verdict`, re-asked every run) and the failure is the quarantine residue being `NOT-EXAMINED` | P5. |
| 14 | FAILS | FAILS — stands, **and is wider**: add `reconcile-terminal-worktrees.py` (patch-id against `refs/heads/main`) and `workspace-retire.py` as consumers that assume `main`; plus fixture `integration-recorded` rows in the real store | P4, P5. |

**Corrected scoreboard:** measured-and-failing on the live machine: **7, 9, 10, 11, 14**. Unmeasurable until the
spec's code runs in a sandbox: **3, 4, 5, 6, 8, 12, 13**. Spec gap needing the CEO's word: **1**. Partial: **2**.

---

## 3. Does "scope the round to the fourteen points" terminate? — **No, as written.**

```
$ python3 - (split each "Check must show:" line on ';' and 'and')
total sub-claims across 14 'Check must show' lines: 38
```

1. The countdown counts **points with a check that ran**, not **work remaining**. Fourteen headings hide 38
   sub-claims; nothing fixes that number, so the next round can find a 39th and still be "inside the fourteen".
2. **"Whatever fails is fixed" reopens the stream.** Each fix is new engine code; each review of new code
   produces findings; each finding maps to one of the fourteen sentences. The filter is mechanical, as the
   brief says — but a filter that everything passes is not a bound.
3. Two points are unbounded by their own wording: point 5 is a property of **every turn Rich takes** (no finite
   check certifies "can neither start new work nor end his turn"); point 13 is "retried until it succeeds".
4. The claim to the CEO — "converts a stream into a countdown" — is true only of **measurement**, never of
   **fixing**. He should hear that now: the number of checks can be fixed in advance and will reach zero; the
   number of fixes cannot be bounded by any scoping rule, because a red check may need any amount of engineering.

**What does terminate** (see §7): freeze the check list before the round starts (N checks, each named, each with
its pass predicate and its mutation set), run them, and report `N run, K red`. Fixing is a separate round scoped
to the red list. The countdown is then real: it is the check list, and it is written before the engineer starts.

---

## 4. The mutation bar — "no mutation derived from the record survives"

I tried to derive mutations from `lifecycle-failure-record-2026-09-1{0,1,2}.md`:

| Mutation | Derived from | Point | Date / commit in the record? | Result |
|---|---|---|---|---|
| M1 land done, workspace deleted, `cc/` branch left → check must go RED | 09-12 §2c (`git branch --contains 6fd5aef8` → three reviewer branches) | 4, 10 | date yes; commit `6fd5aef8` (context) | **Derivable.** |
| M2 a `SubagentStop` whose `agent_id` ≠ owner recorded as the teammate's finish → RED | 09-10 §3.4/§3.5 ("per-run identifier, not the owning agent"); live ledger today | 11, 9 | date yes; **no commit** | **Derivable**, and live evidence exists (P12). |
| M3 ignored nested repository under a "disposable" path removed with no copy → land must REFUSE | 09-10 §3b.2 (`partition_ignored()` bare path component) | 8 | date yes; **no commit** ("reproduced under the lane's own binary") | **Derivable**, commit missing. |
| M4 finished agent with committed branch, Rich ends turn → must be BLOCKED | 09-10 §2.11 (five never-landed branches, named) | 5 | date yes; branch names, **no commit** | **Derivable**, weak: the record names outcomes, not the mechanism that let the turn end. |
| M5 a process holding files in the tree during deletion → RETRY, then succeed | 09-10 §2.17 (VM holding files open); live pid 1483 | 13, 9 | date yes; **no commit** | **Derivable**, live now. |
| — points 1, 2 (copy half), 3 (three refusals), 7 (discard reason), 12 (session records itself) | nothing mechanical in any of the three records | — | — | **Not derivable.** The records describe Rich's conduct (types A–T), not these mechanisms. |

Rulings:

1. **Literally, the bar is unmeetable:** "each mutation carries the date and commit of the incident" — the records
   carry dates and agent names; a commit for perhaps 3 of ~20 mechanical incidents.
2. **Partially, the bar is vacuous:** for ~5 points the record yields zero mutations, so "no derived mutation
   survives" is true with zero mutations. An engineer can meet the bar honestly and prove nothing. This is
   failure type A of the 09-10 record (absence reads as success) written into the acceptance criterion.
3. **The record is thin where it matters and rich where it does not.** It is a catalog of the lead's failures
   by type, with the machinery's failures as sub-bullets. Today's live failures (P4, P8, P11, P12) are in no
   record at all, so round 6 cannot derive from them unless they are written down first.

---

## 5. The runner exclusion — **not defensible for the parts that decide the exit code**

The brief's own first sentence: *"all fourteen are asked by one command."* If that command is
`workspace-probes.py` or inherits its A1–A3 / MISSING / discovery logic, then (Frank c6 record, §2 item 2 and §3 (c)):
route 1 — `not-a-probe:` in the same commit as an engine change, accepted, exit 0; route 3+4 — a committed deletion
concealed by one uncommitted wrongly-signed line, because MISSING reads the working tree and asks git nothing;
and A3 refused nothing in round 5 because Rich cut the reviewer branches at the engineer's tip, so every engineer
commit was "witnessed by" a reviewer. **A green from round 6 produced by that runner is unverifiable, and the
brief excludes exactly the defects that make it so.** The A3 header itself concedes the design: *"An engineer who
creates a branch and commits a docs-only retirement on it will pass A1-A3."*

In scope, because they decide whether a check's verdict can be trusted: (a) the witness — must survive point 4
(branches are deleted), so it cannot be a branch name; (b) MISSING derived from git's tree at the commit under
test, never from the working tree; (c) discovery from an explicit committed manifest, not `getattr`.
Legitimately out of scope: the `PASS/PASS` headline, `CASES`-vs-`RUNNERS`. The brief already concedes (a) will
be "forced by point 4"; it should say so as scope, not as an aside.

---

## 6. Laundered, in one list

1. "Registration is not happening" — an uninstalled engine's store read as the live engine's behavior (P2).
2. "at least four agents ran" — 24 (P2).
3. "`ls ~/.claude/sessions/ | wc -l` → 2" sessions — one session, two files (P3).
4. "`remove=0` … the hold never ends" — 45 of 49 holds are rows for absent paths; 4 are a live VM retry (P5).
5. Point 10's sentence — inverted against git's registry (P7).
6. "three landed branches deleted by hand" — 22 `cc/` branches gone, none ledgered (P8).
7. Point 1 "FAILS" — a spec gap presented as a red cell (P9).
8. Point 9's "recorded failure" — not in the record the brief defines (P10).
9. Points 9 and 11 "NOT MEASURED" — both measurable in one command each, both failing (P11, P12).
10. Point 11's quotation — an elision with no ellipsis (P14).
11. The gate-silencing proof attributed to Frank — Sage's commit (P13).
12. Every quoted string for points 4 and 13 — `main`'s engine, absent from `c5bce604` (§0).

---

## 7. THE BETTER VERSION

### 7.1 The premise block, corrected (lift verbatim)

```
INSTALLED ENGINE = /Users/alex/.claude/richos-engine -> /Users/alex/ab/richos/engine (main @ dcabcbd9).
  It writes ~/.claude/state/worktree-ledger.jsonl (26 files reference it) and never state/workspaces (0).
SPEC ENGINE = dev/workspace-spec @ c5bce604. It writes ~/.claude/state/workspaces (10 files) and has NO
  reconcile-terminal-worktrees.py / workspace-retire.py (deleted at ca4ba9f8). It is not installed.
STATE OF THE SPEC STORE: agents/ 1 record (written 00:57–00:58 local, inside the 00:39→01:13 window the
  spec build was on main); sessions/ ids/ done/ empty; events.jsonl carries 4 fixture rows from today's
  test runs; integration.json absent.
STATE OF THE INSTALLED LEDGER TODAY: 24 teammates registered (native + cc rows each), 901 'finished' rows,
  0 deletion events for the 22 cc/ branches removed today.
LIVE LEFTOVERS: richos-wt/.richos-retired/{frank,sage}-opus-c6.* still in richos .git/worktrees (detached);
  4 zach-opus-dor* worktrees (pre-spec, 2026-09-10) held by VM pid 1483 with 324 open files.
SESSIONS: one (~/.claude/sessions/24267.json + its .key).
```

### 7.2 The scoreboard, corrected — §2 table, last two columns.

### 7.3 The shape of the round I would run

**Round 6 is a MEASUREMENT round, not a fix round.** Its output is `N checks run, K red`, with a check list frozen
before the engineer starts. Fixing is round 7, scoped to the red list.

1. **Run the spec's code in a sandbox, not on the live engine.** The CEO's order (nothing installed while
   sessions run) is satisfied by the code's own redirects: `state_dir()` honors `RICHOS_WORKSPACES_DIR` /
   `CLAUDE_CONFIG_DIR`; `session_pid()` honors `RICHOS_SESSION_PID` / `RICHOS_SESSIONS_DIR`. The harness exports
   a throwaway config dir, fixture repositories, and drives the `c5bce604` hooks (`workspace-lifecycle.sh` on
   SessionStart/SessionEnd/SubagentStart/SubagentStop/TaskCompleted, `guard-worktree-isolation.sh`,
   `detect-nonnative-worktree.sh`, `guard-workspace-gate.sh` on Stop) through spawn → register → land → delete.
   `workspaces-e2e.test.sh` exists at `c5bce604`; **unverified** whether it already covers this — the engineer
   states which of the 14 it asks and which it does not. **Precondition, enforced:** a sha256 census of
   `~/.claude/state/workspaces` and `worktree-ledger.jsonl` before and after; any change is a failed round
   (today's four fixture rows prove this precondition is not yet met).
2. **The check list, frozen in the brief, one line per point, pass predicate stated** — the engineer may add
   checks, never remove or reword these:
   - 1 · creating a non-native workspace not named `cc/` is refused (exit ≠ 0, nothing created). Legacy `dor*`:
     **CEO's word** — rename to `cc/` and land/discard, or leave and declare out of scope.
   - 2 · no deletion path reaches a `codex/` path or ref (fixture with `codex/` present, run every deleter,
     `codex/` byte-identical after); an agent briefed against `codex/` work gets a `cc/` copy.
   - 3 · registration failure ⇒ spawn refused; `claude -w` refused; unregistered `cc/`/native ⇒ appears in
     point 5's pending list.
   - 4 · after a land: workspace absent, branch absent, no prompt, no quarantine directory, no registry entry.
   - 5 · with one finished-unlanded agent, a spawn and a turn end are both refused; the two allowances are
     allowed; nothing else is.
   - 6 · same as 3 and 4 against a native `agent-<id>` / `worktree-agent-<id>` pair.
   - 7 · every ending is `landed` or `discarded` in the store; a discard carries a reason; a no-commit agent
     reads `landed`; CEO-ordered work cannot be discarded without a recorded word.
   - 8 · land of a tree with uncommitted / needed-ignored files is refused; after commit it proceeds; nothing
     under the tree is lost by the deletion.
   - 9 · a restarted finished agent gets no tool; a process started in the workspace is dead before deletion
     (fixture: a sleeper with an open file).
   - 10 · landing a two-workspace agent removes both workspaces and both branches in one operation.
   - 11 · a `SubagentStop` for a sub-run does not finish the teammate; a pause is recorded with what ends it;
     an unnamed pause appears in point 5's list.
   - 12 · session recorded at start; end read from `ps` start-time, never pid alone; the next session lands or
     discards the previous session's agents before any spawn.
   - 13 · deletion blocked by a held file is retried without involvement and succeeds when the hold clears;
     the CEO hears only after a stated number of failures.
   - 14 · integration branch recorded before the first spawn or the spawn is refused naming what to record;
     every consumer (`guard-unresolved-claims.sh`, `unlanded-branches.py`, and on `main`
     `reconcile-terminal-worktrees.py`, `workspace-retire.py`) asks the recorded branch, none asks `main`.
3. **The mutation bar that is reachable and proves something:** every check carries ≥ 1 mutation. Each is
   labeled **RECORDED** (record file, section, date; commit where the record has one — M1–M5 above are the
   starting set) or **SPEC-DERIVED** (the sentence's negation; labeled as invented). Where the record has any
   mechanical incident for a point, at least one RECORDED mutation is required. No mutation of either label
   survives. The report prints, per point, how many of each — so the CEO sees where the record is thin instead
   of a vacuous pass. **First, extend the record with today's live failures** (P4, P8, P11, P12, the quarantine
   residue), each with command + output, so they are derivable next round.
4. **Runner scope:** in — witness that survives branch deletion (a commit reachable from the **recorded
   integration branch**, which point 14 supplies), MISSING from git's tree, discovery from a committed manifest.
   Out — headline cosmetics.
5. **Brief hygiene, mechanical:** every heading is the full CEO sentence or marks every elision with `…`; every
   number carries its command and output; every measurement names **which engine** it ran against; a claim
   about a reviewer's proof cites the commit and its author's worktree.

### 7.4 What the CEO should hear now, in three sentences

The spec's code is not installed, so nothing measured against its store today says anything yet; the four
`zach-opus-dor*` worktrees are outside his fourteen sentences and need his word; and the count that goes to zero
is the list of checks, which can be fixed before the round starts — the amount of fixing behind a red check
cannot be bounded by any scope, and no brief should tell him otherwise.

---

*Frank, `frank-fable-b1`, worktree `/Users/alex/ab/richos-wt/frank-fable-b1`, branch `cc/frank-fable-b1`,
native workspace `/Users/alex/ab/femcboost/.claude/worktrees/agent-a4d89db5ef850b2cd`.*
