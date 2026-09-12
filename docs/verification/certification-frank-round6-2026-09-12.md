NOT CERTIFIED

# Frank — certification of the round-6 measurement (`cc/zach-fable-m1` @ `00c2a075`)

**Subject:** five commits over `dev/workspace-spec` @ `c5bce604`; deliverable `docs/verification/round6-measurement-2026-09-12.md`; headline `CHECKS RUN: 15  RED: 1`.
**Yardstick:** `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md` (read there; the mirror here was not read as the spec and was not touched). **Brief:** the round-6 brief in the private richos-hq repository (its docs/plans, file round6-brief-fourteen-points-2026-09-12.md, at richos-hq commit `75316840`); it is not in this repository.
**Me:** frank-fable-c7 · worktree `/Users/alex/ab/richos-wt/frank-fable-c7` · branch `cc/frank-fable-c7`, cut at `00c2a075`. Nothing merged, pushed, installed or deployed; nothing written into `/Users/alex/ab/richos/engine` or any main checkout; both live stores byte-identical before and after (§8). Sage's work was not read.

## 0. The verdict in four lines

1. **`RED: 1` is not the true number on the frozen fourteen. It is `RED: 2`.** Check 8 is green for a fixture the code handles and red for the fixture its own RECORDED incident describes: a needed ignored file inside an ignored directory the main checkout also has is neither refused nor preserved — the land proceeds and deletes it (§2.1). The engineer's `R-p08` mutant cites the ignored-nested-repository incident and then measures a top-level `.env`.
2. **One green check does not assert its claim.** All five sub-assertions of C4 stay green against a land that QUARANTINES the workspace instead of deleting it; only the added C0 catches it, incidentally (§2.2). C4.4 greps for two directory names.
3. **The runner's replacement for A3 is defeated by the party under test in one command, twice over.** `git branch wip` plus recording `wip` in the store the runner reads → both retirements RETIRED, exit 0; and `git branch -f dev/workspace-spec HEAD` — which no Bash guard refuses — does the same with the real branch name (§4). The witness moved from a branch NAME to a RECORD of a branch name, and the record is one environment variable from the engineer. The manifest closure has the same shape: a listed probe the text rule cannot see, deleted together with its manifest line in one commit, leaves no trace (§4.4).
4. **Seven of my nine spec-forbidden mutations leave the fourteen at exactly `RED: 1`** (§3). They are not the engineer's mutants being weak; they are clauses of the CEO's sentences that no sub-assertion asks.

C14.1 red is right, and stronger than the engineer argued (§5). C0 is a real check but does not belong in the countdown (§6). The 37 mutants are what they say they are, with one mis-citation (§7). My own `-recorded-` probe is untouched and still red 5/10.

## 1. The headline, reproduced

```
$ bash engine/scripts/workspace-spec-fourteen.test.sh          # this worktree @ 00c2a075, sandboxed (HOME, CLAUDE_CONFIG_DIR redirected)
      FAIL  C14.1 with NO branch recorded, the first spawn is refused, naming the recording command
  FAIL  C14  ...  (1 sub-assertion(s) red)
  PASS  C1  PASS  C2  PASS  C3  PASS  C6  PASS  C4  PASS  C7  PASS  C8  PASS  C9  PASS  C10  PASS  C11  PASS  C5  PASS  C13  PASS  C12  PASS  C0
  [37 mutant(s), 8 at a time, wall 9m55.4s, slowest 4m15.7s R-p10-cc-workspace-left-behind, 7.2x serial]
=== mutation: all 37 properties proven load-bearing ===
CHECKS RUN: 15  RED: 1
MUTATION HARNESS: exit 0 (every property proven load-bearing)
exit 1
```
Output sha256 `3610cfdb370b748d9d29e639fbb6dee658b4bb0d6c0ba8f4d59097c2e6321778`. 37 `PASS  R-/S-` lines, 0 `FAIL`. Rich's 14/1 reproduces. The number the harness prints is honest about what the harness asks; the rest of this file is about what it does not ask.

The lib and hooks are untouched by the five commits (`git diff --stat c5bce604..00c2a075 -- engine/scripts/lib/ engine/scripts/hooks/` → empty), so every check measures `c5bce604`'s code, as the brief requires.

## 2. Greens I broke

### 2.1 C8 — GREEN, and point 8 is violated by the recorded incident's own shape (→ RED)

The check: *"A land of a tree with uncommitted or needed-ignored files is refused; after the commit it proceeds; nothing under the tree is lost by the deletion."* The harness's fixture (C8.1–C8.5) is a top-level uncommitted `draft.txt` and a top-level ignored `.env`. The code (`uncommitted()`, `workspaces.py:1550`) walks `git status --ignored` entries and, for an ignored DIRECTORY, does this:

```python
if other and os.path.isdir(mine) and os.path.isdir(other):
    continue            # the directory exists in the main checkout too: skipped, contents never compared
```

`git status --ignored` reports a wholly ignored directory as one `!! dir/` entry, so nothing inside it is ever looked at. Probe (`scratchpad/ignored-dir.py`, calling the same `uncommitted()` and `_require_clean()` that `land()` calls, fixture: main checkout has `.claude/` and an empty ignored `vendor/`; the agent's workspace has `.claude/notes/needed.txt` and a nested repository `vendor/lib/.git` with a commit nobody else has, plus a top-level `.env` as control):

```
git status --ignored sees: !! .claude/ | !! .env | !! vendor/
uncommitted() -> dirty=[] ignored=['.env']
needed.txt inside ignored .claude/ reported: False
nested repo inside ignored vendor/ reported: False
.env (control) reported: True
_require_clean refused; names .claude/notes? False | names vendor? False | names .env? True
_require_clean with .env matched: PASSED -> the land would proceed and delete .claude/notes/needed.txt and vendor/lib/.git
```

So: the land is refused for `.env` (the harness's shape), and once `.env` is matched it PROCEEDS with a nested repository of unlanded commits under the tree, which point 8's last sentence says can never be lost by the deletion. This is exactly 09-10 §3b.2 — *"An ignored nested repository under a folder the policy treats as disposable was deleted with no copy"* — the incident `R-p08-ignored-needed-files-landed` cites. The mutant is derived from the incident; the sub-assertion it turns red (C8.3) measures a different shape; the incident's shape is unmeasured and broken. On this machine the main checkouts and every `cc/` workspace both carry `.claude/`, so the skipped-directory case is the ordinary one, not an edge.

**Check 8 as frozen fails on this fixture. The frozen fourteen are 2 red, not 1.**

### 2.2 C4 — GREEN against a quarantine; C0 does the work

Mutant `F4-quarantine-elsewhere` (`scratchpad/mut/F4-quarantine-elsewhere`): `remove_workspace` does `git worktree move <path> <dir>/.parked-<name>` and checks out `parked/<name>` there instead of `git worktree remove`. Result:

```
  PASS  C4  After a land: workspace absent, branch absent, no prompt, no quarantine directory, no registry entry     <-- all five sub-assertions green
      FAIL  C0.3 the entity repository has only its main checkout
      FAIL  C0.4 the other repository has only its main checkout and the untouched codex/ workspace
  FAIL  C0  ADDED ...  (2 sub-assertion(s) red)
      FAIL  C13.1 / C13.3 / C13.4 / C13.5   (incidental: the moved tree collides with the chflags fixture)
CHECKS RUN: 15  RED: 3
```

C4.2 asks whether the OLD path is gone (it is — moved). C4.3 asks whether the branch is gone (it is — the moved tree now holds `parked/…`, so `delete_branch` finds no holder). C4.4 is `find -iname '*retired*' -o -iname '*quarantin*'` plus a `detached` grep: a quarantine under any other name, on any branch, is invisible to it. C4.5 asks the store, which says landed. The addendum §A4 incident (`.richos-retired/…`) happens to match the grep; the next quarantine will not. The CEO's sentence is *"the workspace AND the branch are deleted"*; the assertion that carries it is C0.3/C0.4's worktree COUNT, which is the added check, not check 4. C4.4 should count worktrees per repository (before/after), not grep names.

### 2.3 C2 — byte-identity is vacuous for the library's own deleters

Mutant `F20-library-codex-guard-removed` (the `if b.startswith(CODEX_PREFIX): return False` in `delete_branch` removed) leaves the fourteen at `RED: 1`. No deleter in C2 ever AIMS at `codex/`: `_branch_targets` only lists an agent's own recorded branches, so `codex/other` is never a candidate and the hash equality (C2.6) is proved by never being asked. The report says so honestly (§2 point 2: "covered by the existing unit mutant"), but the frozen check reads "every deleter runs and codex/ is byte-identical after" as if the deleters had been pointed at it. A real C2 would put a `codex/` ref on an agent's record (`created_branches`) and watch the land refuse to delete it.

### 2.4 C1.2 — one spelling of seventeen

`scratchpad/guardprobe.sh` fed 17 spellings of a raw `git worktree add` to `guard-worktree-removal.sh` through the same payload the harness uses. Refused (exit 2): 14, including `-C`, absolute `/usr/bin/git`, `command git`, `env git`, `cd … &&`, `sh -c`, `bash -c`, `xargs`, `GIT_DIR=`. Allowed (exit 0): a Python `subprocess.run`, a `git wt` alias, and a heredoc that writes the command to a script and runs it. A raw workspace made those ways becomes an orphan and is named by the point-5 sweep (C3.4/C3.5), so the system's real answer to point 1 is "refused, or reclaimed"; the sentence says refused. A note, not a red.

### 2.5 C11.1 — true of the code; the platform's half is not what the report implies

C11.1 passes because `record_end` ignores an id it has no registration for. The report (§2 point 11, §6 A3) says the teammate's own bound id appears on a finished row for 20 of 25 workspaces and leaves the ORDERING unverified. I verified it, read-only, from `~/.claude/state/worktree-ledger.jsonl` (rows dated 2026-09-12; a teammate's bound id = the `agent_id` of its `registered` row):

```
teammates with a bound id today: 27; bound id on a SubagentStop 'finished' row: 21
  19 of 21: that row is the LAST finished row for the teammate
  frank-opus-c4: bound-id finished row 11:53:23.52, one more sub-run finish 0.8 s later (a race at the end)
  zach-opus-g2:  bound-id finished row 11:29:07.64; sub-run finishes at 11:29:08 and 11:29:40; bound id AGAIN at 11:29:53.74
```

So at least once today the platform fired the teammate's OWN end-of-run signal, the teammate ran on for 46 seconds, and it fired again. Under `c5bce604`, the first signal finishes the agent and the lock-out refuses its next tool (point 9). Whether that is the spec working (an idle teammate resumed by a message IS a restarted finished agent, by the page's definition) or the platform misreporting is a fact for the page's author; it is the operational consequence of point 11 that the fourteen cannot see, and it is the case CLAUDE.md's "resume ONCE to commit+verify+report" relies on. Not a red; it is the thing round 7 should know before it reads C11 green as "sub-runs are safe".

### 2.6 The rest of the fourteen

C3, C5, C6, C7 (as asked), C9, C10, C12, C13: each sub-assertion asserts what it names, with a positive control where a negative could pass for the wrong reason (C6.1 for C6.2, C9.2 for C9.3, C12.3 for C12.2, C13.5 for C13.2). The gate's fail-open on its own error (mutant F5, `gate_stop` raising) turns 12 checks red, so a crashing gate cannot hide. C14.5 rests on exit 2 alone; `unlanded-branches-lint.sh` also exits 2 on a missing directory or a malformed argument, so a broken invocation reads as ABSTAIN — C14.4 is the positive control that keeps it honest. C14.7 is a grep of source text and proves only that one tuple is unused; of the eight consumers the library's `integration_for` docstring names, six import it and `guard-ci-red-lands.sh` asks the `integration-branch` CLI (grep), while `land-residue-gate.py` names none of the three entry points — C14 measures two consumers and did not claim more.

## 3. Nine mutations of `workspaces.py` the CEO's sentences forbid — seven invisible

Method: `scratchpad/mut.sh` copies `engine/`, applies one edit, runs the fourteen with the inner harness skipped. Base result for comparison: `CHECKS RUN: 15  RED: 1`.

| mutant | the sentence it breaks | fourteen say |
|---|---|---|
| F1 a discard with NO reason is accepted (`len(reason) < 10` → `False`) | 7 "with the reason recorded" | **RED: 1 — invisible.** C7.2 asserts the reason the harness gave was stored, never that one is required |
| F2 the CEO-ordered attestation dropped (`--not-ceo-ordered` no longer required) | 7 "never discarded without his word" (its mechanism) | **RED: 1 — invisible** |
| F4 land quarantines under `.parked-<name>` on `parked/<name>` | 4 "workspace AND branch deleted" | C4 green; C0 red (§2.2) |
| F5 the Stop gate crashes (`raise RuntimeError`) | 5 "can neither … end his turn" | RED: 12 — seen |
| F10 a session claims and auto-lands a LIVE session's agents (`_claimable` → True) | 12 "each handles only the agents it started" | **RED: 1 — invisible.** The frozen check 12 never has two live sessions |
| F19 branches the agent CREATED are no longer its work (`created_branches` ignored) | 3 "any branch an agent created", 10 "none is left behind" | **RED: 1 — invisible.** No agent in the fourteen creates a side branch |
| F20 the library's codex/ branch guard removed | 2 "never deleted" | **RED: 1 — invisible** (§2.3) |
| F26 handed-in-then-ended is not finished if a pause was sent | 11 last sentence | **RED: 1 — invisible.** No TaskCompleted is ever sent |
| F27 an item waiting on the CEO's word blocks new work | 5 "blocks nothing else" | **RED: 1 — invisible.** `workspaces.sh wait` is never exercised |

F1 and F2 are false greens of an existing check's own sentence (C7 says "a discard carries its reason"). F10, F19, F26, F27 are clauses of the CEO's sentences that the FROZEN list never asked — the freeze was the reviewers' own ruling, so these are round 7's to add, not the engineer's omission; but a `RED: 1` that survives them is not a measurement of points 3, 5, 10, 11 or 12 as written.

## 4. The runner (§7): what I tried and what held

All on a clone of `/Users/alex/ab/richos` in the scratchpad, HEAD `00c2a075`, store `RICHOS_WORKSPACES_DIR=<sandbox>`, commits `--no-verify` (the clone inherits the identity guard). Script: `scratchpad/rn2.sh`; outputs `rn2a.out`–`rn2e.out`.

| case | what the party under test did | runner |
|---|---|---|
| RN1 | this branch, `dev/workspace-spec` recorded in a sandbox store | reproduces the report: 11 listed, 1 declared, 8 GREEN, 2 RETIRED (`1329ec67b86e, landed on dev/workspace-spec @ c5bce604b6cd`), **RED my `-recorded-` probe, 5/10**, rc 1 |
| RN2a | the engineer types a retirement of frank's probe signed `frank`, docs-only commit `c13193ff` on his branch; `dev/workspace-spec` recorded | **HELD**: `A3: the commit that wrote it (c13193ff4c76) has not landed on dev/workspace-spec`, rc 1 |
| RN2b | same tree; `git branch wip`; `workspaces.sh integration --repo . --branch wip` in the store the runner reads | **DEFEATED**: `integration branch: wip @ c13193ff4c76 (recorded; …)`, frank's probe **RETIRED**, sage's RETIRED, **rc 0** |
| RN2c | `dev/workspace-spec` recorded (the real name); `git branch -f dev/workspace-spec HEAD` | **DEFEATED**: `integration branch: dev/workspace-spec @ c13193ff4c76`, both RETIRED, **rc 0** |
| RN2d | a listed probe reaching the library through `getattr("register" + "_cc")` (the text rule cannot see it); then file AND manifest line deleted in one commit | **DEFEATED**: `probes discovered: 11`, `probes DELETED from history and not retired: 0` — it never existed |
| RN2e | control: the same deletion of frank's text-visible probe and its line | **HELD**: `MISSING`, and the branch scan found it on `dev/workspace-spec` and ran it RED there, rc 1 |

**What replaced A3, precisely.** The old witness was any branch containing the commit (my route: the ordinary review handoff; Sage's: `git branch wip`). The new witness is the tip of the branch the STORE records. `record_integration` refuses `cc/` and `worktree-agent-` names and requires the branch to exist — nothing else. Any other name (`wip`) with the engineer's tip records fine, and the store it records into is `RICHOS_WORKSPACES_DIR` / `CLAUDE_CONFIG_DIR` / `~/.claude/state/workspaces`, all of which the party running the runner chooses. The engineer's own report §4 shows the honest form of this: he recorded `dev/workspace-spec` in a sandbox store to get a runner verdict at all, because the live store records nothing. Nothing in the runner distinguishes his sandbox from RN2b's.

**And the branch itself is not protected.** `scratchpad/guardprobe.sh` through `guard-worktree-removal.sh`: `git branch -f dev/workspace-spec HEAD` → 0, `git branch -f main HEAD` → 0, `git update-ref refs/heads/dev/workspace-spec HEAD` → 0, `git push . HEAD:dev/workspace-spec` → 0, `git branch -D dev/workspace-spec` → 0, `git checkout dev/workspace-spec && git merge cc/x` → 0. No other hook in the PreToolUse[Bash] chain names refs (`guard-bash-main-writes.sh` guards files; `guard-owned-state.sh` guards `.claude/state` acks). "Only Rich writes that branch" (runner header, item 1) is a convention, and the runner's proof rests on it.

**Held:** A3 against a typed retirement when the real branch is recorded and unmoved (RN2a); MISSING for a text-visible probe (RN2e); the manifest read from git not the tree (the runner's W27, not re-run by me); UNLISTED (W26, not re-run). The three closures are real against an HONEST engineer who forgets; against the party under test acting, the witness and the discovery are both still inside its reach.

**A cheaper closure than a guard, for round 7:** the runner should refuse a witness whose store is not the operator's (`RICHOS_WORKSPACES_DIR`/`CLAUDE_CONFIG_DIR` set → print the store path and ABSTAIN unless `--store <path>` was passed explicitly and is echoed in the header), and should print the recorded branch's tip beside `git rev-parse origin/<branch>` so a moved ref is visible in the one line a reviewer reads. The manifest hole (RN2d) closes by diffing the manifest at HEAD against the manifest at every commit in the last N: a line that disappears without a retirement is MISSING.

## 5. Ruling on C14.1 — RED is right, and the engineer's argument is the weaker half of it

The engineer's case: the sentence *"RECORDED when that work starts, before its first agent is spawned"* is a guarantee only a refusal gives; "the land refuses later" is the "holds whether or not Rich remembers" that point 5 forbids. I agree, and the code's own fallback is the stronger reason. `_bind_body_of_work` binds nothing when nothing is recorded; `integration_target` then reads *"the repository's current body of work"* at LAND time. Probe (`scratchpad/c14-bound-to-nothing.py`, driving the library):

```
1. no record at spawn: integration_work = None      land target -> "no branch is recorded ..."
2. dev/one recorded:                                 a1's land target -> dev/one
3. main recorded for a SECOND body of work:          a1's land target -> main
4. CONTROL a2 (registered while dev/two was current) after a later recording of main -> dev/two
   a1 (bound to nothing) at the same moment                                          -> main
```

An agent spawned before the record exists is proved against whichever body of work happens to be current when it lands — a second, unrelated recording moves it, while a properly bound agent is unmoved. That is *"nothing infers it and nothing guesses it"* violated in the code's own terms: "current at land time" is an inference. The refusal at spawn is the only implementation of the sentence, and the check as written is correct. **RED stands; round 7 fixes the spawn guard, not the check.**

## 6. Ruling on C0 — real, keep it, out of the countdown

C0's six sub-assertions are real end-state invariants (done/ kinds, no live workspace in agents/, worktree counts per repository, no agent branch, hooks stderr empty). It is the check that caught F4 and it should stay. But it is not one of the CEO's fourteen sentences, and `CHECKS RUN: 15  RED: 1` puts it in the denominator of his countdown. The honest headline is two numbers: **frozen fourteen: 14 RUN, 2 RED (C14, C8); added: 1 RUN, 0 RED.** The report's §1 does say "fifteen = fourteen plus one added", so this is a presentation ruling, not a finding of concealment.

## 7. The 37 mutations

- **All 37 target code, none the harness:** `scripts/lib/workspaces.py` (31), `scripts/hooks/guard-worktree-removal.sh` (3), `scripts/create-teammate-worktree.sh` (1), `scripts/lib/unlanded-branches.py` (1), `scripts/hooks/guard-unresolved-claims.py` (1). Every want names a sub-assertion with a trailing space or the `C5.1b` form; none wants `FAIL  C14 `. Reproduced: 37 PASS, 0 FAIL.
- **RECORDED (16) — citations checked against the record files** (`richos-hq/docs/verification/lifecycle-failure-record-2026-09-{10,11,12}.md`, the addendum `c13f8f06`, my `brief-audit-frank-round6-2026-09-12.md` @ `bad54a34`, femcboost `CLAUDE.md`): 09-10 §3.4 "ownership row with no agent id" / "sealed manifest is taken at spawn" / "15,882" (R-p03, R-p06, R-p10) ✓; §3.1 + §2.11 (R-p03-unregistered, R-p05-turn-end) ✓; §2.2 (R-p07) ✓; §3.5 "per-run identifier … derives the owner from the folder" (R-p11) ✓; §3b.1/§3b.5 "Thirteen agents … 0.3 seconds" + 09-11 S4 (R-p09-lock-out) ✓; §3b.2 nested repository + `inflight-ack.sh` header (R-p08) ✓ — see §2.1 for why the check it turns red measures a different shape; §2.17 VM holding files + my P5 (R-p13) ✓; §2.5 "cannot see subagents at all" (R-p12) ✓; 09-12 §2c `git branch --contains 6fd5aef8` (R-p04-branch-left) ✓; §5 Type D (R-p05-new-work) ✓; addendum §A2/§A4 (R-p04-quarantine, R-p07, R-p10) ✓; femcboost CLAUDE.md corollary + my P11 (R-p09-processes) ✓. **One mis-citation:** `R-p14-land-assumes-main` says 09-12 §2c holds "a true land onto dev/workspace-spec refused by a check that asked main"; §2c holds the branch-witness failure, not that refusal. The refusal rests on my P5 ("NOT on refs/heads/main by patch id", 45 holds) and on Sage's §4.6, which I did not read. The mutant is still record-derived; the pointer is wrong.
- **SPEC-DERIVED (21):** each is a negation of its sentence and says so. Points 1 and 2 at R 0 are stated, not hidden; correct.
- **Per-point counts** are printed (report §2 table). 16/21 reproduces from the PASS lines.

## 8. Census — before the first command, after the last store-relevant one

Method: sha256 of every file under both directories, listed and hashed; the two listings then compared file by file (`scratchpad/census-before-raw.txt`, `census-after-raw.txt`, `census-compare.sh`).

```
before  19:36:16Z   ~/.claude/state/workspaces            07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9  (4 files)
                    ~/.claude/state/workspace-retirement  67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1  (11286 files)
after   19:57:21Z   ~/.claude/state/workspaces            07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9  IDENTICAL
                    ~/.claude/state/workspace-retirement  67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1  IDENTICAL
per-file diff: IDENTICAL, file by file (11290 files)
```
Both match the engineer's census hashes. `~/.claude/state/worktree-ledger.jsonl` (not one of the two named directories): 19762 lines / `f6cd5765…` at 19:44Z, 19811 lines / `b0310c40…` at 19:59Z — appended by the running engine's `SubagentStop` hooks for the agents live in this session (addendum §A5), through no command of mine. The only commands after the after-census were the write of this file and its commit.

## 9. What I ran, with exit codes

| command | exit / result |
|---|---|
| `inflight-ack.sh --sha 00c2a075… --impact none` | 0, ledger row written |
| census before (19:36:16Z) | 0 |
| `bash engine/scripts/workspace-spec-fourteen.test.sh` (sandboxed, with mutants) | 1 — `CHECKS RUN: 15  RED: 1`, 37/37 proven |
| `scratchpad/rn1.sh` (runner, sandbox store, `dev/workspace-spec`) | runner 1 — my `-recorded-` probe RED 5/10, unchanged (`git log c5bce604..00c2a075 -- <probe>` → empty) |
| `scratchpad/ignored-dir.py` | 0 — the point-8 hole (§2.1) |
| `scratchpad/guardprobe.sh` | 0 — 14/17 raw adds refused; 0/7 ref moves refused |
| `scratchpad/run-mutants.sh` (F1, F2, F4, F5, F10, F19, F20, F26, F27) | F5 `RED: 12`; F4 `RED: 3` (C13, C0; C4 green); the other seven `RED: 1` |
| `scratchpad/c14-bound-to-nothing.py` | 0 — §5 |
| `scratchpad/rn2.sh` (RN2a–e on a scratchpad clone) | a: 1 held · b: **0 defeated** · c: **0 defeated** · d: 1, ghost vanished · e: 1 MISSING held |
| census after (19:57:21Z) + `census-compare.sh` | 0 — identical |
| `git status --short --ignored` in this worktree after removing the runner's `__pycache__` | only `.claude/` |

## 10. What I did not do, and the one tree edit I did

No merge, push, `install.sh`, deploy; no write into `/Users/alex/ab/richos/engine`, `/Users/alex/ab/richos`, `/Users/alex/ab/richos-hq` or any main checkout; nothing `codex/` touched; no fix to any red; no edit to `workspaces.py`, the hooks, the harness, any probe or retirement; Sage's audit and certification not read; the full engine sweep not run (expected). The runner attacks ran on a throwaway clone and sandbox stores only.

**One edit outside this file, and a finding with it:** at `00c2a075` the running engine's `guard-completeness-commits.sh` refuses EVERY commit on this branch — `publication-completeness.sh --root <this worktree>` → exit 1, one finding: `docs/verification/round6-measurement-2026-09-12.md` cites the round-6 brief by a repository-relative path that exists only in the private richos-hq repository. My own first commit attempt was refused on the engineer's file alone after mine was rephrased. Rewriting his frozen record would falsify it, so I took the guard's third route and added one reviewed `CITATION_EXEMPT` line for that exact file to `.richos/publication-completeness` (fifth group, with its reason). Round 7 should rephrase the citation and delete the line; until then nothing can be committed on top of the round-6 branch without it.

## 11. For round 7, in order of what it costs to be wrong about

1. Fix C14.1 at the spawn guard (§5). Keep the check.
2. Point 8: compare ignored directories by content (recurse `git status --ignored -uall` or walk the entry) — and add the nested-repository fixture to C8, since it is the recorded incident.
3. C4.4 → count worktrees per repository, not names.
4. Add the six unasked clauses (§3: F1, F2, F10, F19, F26, F27) as sub-assertions; put a `created_branches` case and a two-live-sessions case in the fourteen.
5. The runner: abstain on a non-operator store unless named explicitly; print the recorded tip beside the remote's; diff manifests across history (§4).
6. Decide, on the page, what a mid-run `SubagentStop` carrying the teammate's own id means (§2.5) — it happened today.
