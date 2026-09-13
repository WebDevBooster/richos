NOT CERTIFIED

# Certification, round 8 — Sage (sage-fable-c9), 2026-09-13

| | |
|---|---|
| **Certified** | `cc/zach-fable-m5` @ `151fa53f0026c14405bf19a91399fef16d8f2daf`, 16 commits over `dev/workspace-spec` @ `6a04423d` (`git log --oneline 6a04423d..HEAD \| wc -l` → 16, run in my worktree, whose branch was cut at that tip). `main` @ `dcabcbd9`, untouched. |
| **Spec** | `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, read in full, sha256 `957d21a4…`. The mirror in this tree hashes the same (`shasum -a 256 docs/plans/worktree-spec-2026-09-11.md` → `957d21a4e76262c28bb8b69cd37249cc87eea326e12c927c2997ad9887b10978`); `git log --oneline 6a04423d..HEAD -- docs/plans/ \| wc -l` → `0`, so neither the mirror nor its pin moved on this branch. |
| **Brief** | `/Users/alex/ab/richos-hq/docs/plans/round8-brief-2026-09-13.md` @ `91ea721b` (`git -C richos-hq show 91ea721b:…`, read in full). It is the round built from my `BRIEF NOT READY` (brief-audit-sage-round8-2026-09-13.md) and Frank's. |
| **Where I stood** | `/Users/alex/ab/richos-wt/sage-fable-c9`, branch `cc/sage-fable-c9`. Every run below is sandboxed twice: the harness's own redirection of `HOME`/`CLAUDE_CONFIG_DIR`/`RICHOS_WORKSPACES_DIR`, plus the engineer's wrappers (`docs/verification/round8-fixes-2026-09-13-logs/run-*.sh`) exporting `CLAUDE_CONFIG_DIR`, `RICHOS_WORKSPACES_DIR`, `RICHOS_SESSIONS_DIR` into my scratchpad; my own attack scripts redirect the same variables themselves. |
| **Constraints kept** | nothing installed, merged or pushed; no `install.sh`; nothing written into `/Users/alex/ab/richos/engine`; no main checkout touched; every `codex/` ref I created lives in a `mktemp`/scratchpad fixture. **Frank's work not read:** I opened none of his files. The engineer's committed logs quote the output of his probes (`runner-*.txt`), and I read those logs as the engineer's evidence; the two red cases of his are his to rule on and I say nothing about them. |
| **Census** | §8: both directories identical before and after, by two instruments. |

## 0 · The verdict, and exactly what it rests on

The headline reproduces on my own runs (§1). The direction of every mechanism is right, and this is the best build of the eight rounds. It is **NOT CERTIFIED** for two measured reasons, each named to its line and each closable without a new design:

- **R1 — the gate reads GREEN for a reviewer's probe that no longer asserts anything** (§5, V2 and V6). A listed probe replaced on the branch under test by a file that imports the library and returns 0, or a reviewer's `return 1` flipped to `return 0`, runs GREEN and the runner exits 0. Item 1 was built to the brief's first option (the manifest rule) and meets that option's observable exactly (V1, V3, V4, V5, V7 all block); the brief's second option — run every listed probe at the recorded branch's content — is what closes V2/V6, and the engineer says in §F of his report that he did not build it. A gate a failing engineer can silence by editing the assertion is the thing round 7 was refused on; the route has changed, the property has not.
- **R2 — a protected ref is restored only inside a window, and an agent's process acts outside one** (§5, E2, E4, E5, E7a). A `codex/` ref deleted between two of the agent's closed foreground calls stays deleted through the next call and the end of the run (E4 — point 2, *"never deleted"*); a `codex/` ref force-moved to the agent's tip after its last PostToolUse stands (E5); the agent's own branch merged onto the recorded branch after its last PostToolUse stands and the land then reports `landed` with nothing pending (E2 — point 14, point 5); a stray ref cut between two closed foreground calls is left behind by a land that reports success (E7a — point 3). Every one of these is the act of a child the agent backgrounded itself inside a foreground call, which the platform does not stamp. The report declares the E2 shape (§B items 2/3, the R8 bound my own case forced) and the E7a shape (§E, `run_in_background`); it does not declare E4 or E5, and its sentence *"a codex/ ref … moved or deleted by ANY means … is restored"* holds inside a window only.

And one bound I record without resting the verdict on it — **R3** (E1): inside a window, a move of the recorded branch to a descendant that carries none of the agent's *workspace* tips is spared as "the lead's land". An agent's own `git -C <main checkout> commit` while that checkout sits on the recorded branch is exactly that shape, and the Bash guard passes it by name (§5 G-table: `commit`, `merge`, `reset --hard`, `rebase` in the main checkout all `0` from an agent's call). The brief's item-2 observable — *"moved by any means, named or unnamed, from either checkout, is restored"* — is therefore met for deletions, non-descendant moves and own-work descendants, and not for this one.

**What reaches CERTIFIED, in one build, no new design:** (a) item 1's second option, as the brief already words it; (b) at a PreToolUse with no window open, compare the protected tips against the previous `latest.json` before overwriting it and restore a DELETION (a deletion is never the lead's legitimate act — his deleters are refused with no override — so nothing has to be told apart; a `codex/` deletion the CEO has ordered needs a recorded path through the library, which today does not exist either); (c) for moves outside a window and for E7a, the fact the engine already reads for point 9 — a process of the agent's still alive inside its workspace at the call's PostToolUse — keeps the window open exactly as the platform's stamp does; where that fact is absent too, the bound is the same one item 8 declares and I accept it. (d) E1 needs a fact about the lead's move (his land recorded by the library, or the lead's own Pre/Post pair) and is a design choice for the brief writer; until then the isolation guard covers it by name (**unverified against the richos hooks by me** — my own calls in this session were refused by it, which is evidence it is live for this session's agents, not a measurement of the richos engine).

## 1 · The headline, reproduced

Engine: `engine/` of my worktree at `151fa53f` (cut from `cc/zach-fable-m5`; `git status` clean before my first commit). Commands are the engineer's wrappers with `RICHOS_R8_WORKTREE` and `RICHOS_R8_SCRATCH` pointed at my worktree and scratchpad; logs under `<scratchpad>/sage-c9/`.

| harness | my run | verdict lines (verbatim) | exit |
|---|---|---|---|
| the fourteen, checks | `run-fourteen.sh fourteen-with-mutants with-mutants` (the check pass of that run) | `139` `ok` lines (`grep -c '^      ok'`), no `FAIL`; every round-8 sub-assertion `ok`: C2.9–C2.14, C5.13–C5.16b, C8.8, C9.6a/C9.6, C10.7/7b/7c/7d/8, C11.8/8b, C14.13–C14.16, C14.15b | — (the run continues into the mutation pass) |
| the fourteen, mutants | the same run | **see §6** — the pass was still running at load 94–130 (three mutation pools on the machine) when this file was first committed; the number is filled in by the commit that follows, from the run's own tally line, never from the engineer's | — |
| unit tests | `run-unit.sh unit-all` | `=== workspaces spec tests: 64 run, 0 failed ===` | 0 |
| Bash guard suite | `run-suite.sh suite-guard engine/scripts/hooks/guard-worktree-removal.test.sh` | `=== guard-worktree-removal tests: all 161 passed ===` | 0 |
| lock-out suite + mutants | `run-suite.sh suite-sealed engine/scripts/hooks/guard-sealed-worktree.test.sh` | `=== guard-sealed-worktree tests: 0 FAILED, 23 passed ===` · `=== mutation: all 11 properties proven load-bearing ===` | 0 |
| liveness + claims | `run-suite.sh suite-claims engine/scripts/hooks/agent-state-claims.test.sh` | `=== agent-state-claims tests: all 46 passed ===` | 0 |
| probe-runner suite + mutants | `run-suite.sh suite-probes engine/scripts/workspace-probes.test.sh` | `=== workspace-probes tests: all 47 passed ===` · `=== mutation: all 18 properties proven load-bearing ===` | 0 |
| end to end | `run-suite.sh suite-e2e engine/scripts/workspaces-e2e.test.sh` | `workspaces-e2e: 47 passed, 0 failed` | 0 |
| the runner on the real manifest (store COPY) | `run-runner.sh runner-c9` | `probes discovered: 11` · `GREEN` ×8, `RETIRED` ×2, `RED` ×2 (`certification-frank-recorded-attribution-2026-09-12-probe.py`, `certification-sage-window-and-target-2026-09-12.probe.py`), `DECLARED` ×1 | 1 |
| the runner after my retirement commit | `run-runner.sh runner-c9-after-tsv` | my file `UNRUNNABLE` with the note *"the retirement of case 'ref-after-post' names the right author ('sage') and is NOT attributable to that author. A3: the commit that wrote it (cf2317d34090) has not landed on dev/workspace-spec"* — the signature and case parse; A3 waits on Rich's land, as designed | 1 |
| my own probe, every case | `python3 -B certification-sage-window-and-target-2026-09-12.probe.py <lib>` | `held: 5/8; NOT HELD: escalation-stray, escalation-stray-cc, ref-after-post` — B and B2 retired in round 7, C retired here (§2); A, D, D2, E, F hold | 1 |

Not re-run: the base's `RED 1` (measured by me at `a0c1e1bd` in brief-audit-sage-round8 §8, and `git diff --stat 44a7d5d4..a0c1e1bd -- engine` was empty then; the engineer's `runner-base-6a04423d.txt` reads the same), and round 7's 59-mutant run.

## 2 · Ruling on `ref-after-post` — obsolete as a case; retired per case, signed `sage`

Case C of my `certification-sage-window-and-target-2026-09-12.probe.py` asserted the **gap**: it holds only when both `bg-after-post` (cut between two closed foreground calls) and `bg-after-last-post` (cut after the last PostToolUse, before the end signal) are left behind attributed to nobody. It was written in round 7 to make a declared-and-unfixed hole visible; its predicate is the negation of the spec, so no correct fix can turn it green. Measured on this branch with its own driver (my `attack-effects.py` E7, and the probe itself): `created_branches at the end ['bg-after-last-post']`, `branches after the land ['bg-after-post', 'main']`.

- The half the brief's sentence names — *"a ref created after the last PostToolUse is attributed"* — is closed: C10.7/C10.8 green, mutant `R-p03-ref-after-the-last-post-left-behind` declared against C10.7, and E7 shows `bg-after-last-post` attributed and gone with the land.
- The platform-stamped shape of the other half is closed: a `run_in_background` call keeps its window open until the next observation, judged against its own before-set (C10.7b; my E8: `created_branches after the next call ['from-bg']`, and Rich's bookmark between two closed foreground calls stays his).
- **What it costs, said plainly:** the first half for a child the agent backgrounded *itself* inside a foreground call (no stamp) is still open — E7a — and after this retirement no live case on the manifest asserts it. I did not add one: git cannot tell that ref from one Rich cuts at the agent's tip (my case D, C10.7d, the engine's point-8 test), so a case that demands attribution demands the point-8 loss the engineer rightly refused, and the closure is the point-9 process fact named in §0(c), a build item for the next brief. The retirement line carries this in its own words so the record does not lose it.

The line: `docs/verification/workspace-probe-retirements.tsv`, last line, four fields (`<file>\tref-after-post\tsage\t<why>`), committed alone as `cf2317d3` (docs-only). Cases A, D, D2, E, F stand: `held: 5/5` with B, B2, C excluded.

**A correction of my own record.** My audit's §11 told the engineer the fix was "at the end signal, diff against `latest.json`". He built exactly that first and it did not make the between-calls shape green (his §B item 8, first bullet); the stamped-window design is his, not mine, and it is the right one. Both audits under-derived the shape; he re-derived it.

## 3 · Ruling on the rejected any-point alternative — upheld

The alternative attributes any ref that appears between two closed calls and sits on the agent's own unlanded line. His measurement (`runner-item8-ALTERNATIVE-any-point-attribution-REJECTED.txt`, `unit-item8-ALTERNATIVE-…`): Frank's file goes green, Frank's control twin goes RED (`rich/rescue survived False`, `VERDICT BROKEN`), and the engine's `test_point_08_a_branch_that_existed_before_the_call_is_never_created_in_it` fails (`['rich/bookmark', 'spare'] != ['spare']`). I did not rebuild the alternative; the two failures are the property my own case D pins (`rich-between-calls`: Rich's ref not attributed, not deleted — held on this branch), and my E8 shows the chosen design keeps it. A ref at the agent's unlanded tip cut between two closed calls is byte-identical in git whether the agent's child or Rich cut it; the only fact that separates them is the platform's stamp; attributing on nothing is guessing, which the page forbids in so many words, and it buys point 3 with point 8 (*"Deletion therefore never loses anything that was meant to land"*). Rejection right. The residual (E7a) is the cost of not guessing, and §0(c) names the non-guess that shrinks it.

## 4 · Verdict per item

| item | verdict | evidence |
|---|---|---|
| 1 gut-and-delist | **met as briefed (first option); the gate is still silenceable — R1** | V7 gut-and-delist → `MISSING`, exit 1; V1 gut-and-keep-listed → `UNRUNNABLE`, exit 1; V3 delist-only → `UNLISTED`+`MISSING`; V4 rename with the line updated → old path `MISSING`, new path runs `RED`; V5 rename without → `UNLISTED`+`MISSING`. **V2** (a listed file that imports the library and asserts nothing) → `GREEN`, exit 0. **V6** (`return 1` → `return 0` on the branch under test) → `GREEN`, exit 0. |
| 2 recorded branch moved | **not met for two shapes — R2 (E2), R3 (E1)** | By name: the eight verbs and the doorway refused (C14.16 `ok`; my G-table: `push . HEAD:refs/heads/dev/work` and `push . 'HEAD:dev/work'` refused). By effect: deletion from the main checkout restored (C14.14), doorway from the agent's worktree restored (C14.13), the lead's land spared (C14.15), the lead's fast-forward after the last call spared (C14.15b); my E1b (agent merges its own branch onto main from the main checkout inside a window) restored. **E1** (agent's own commit onto main from the main checkout inside a window) not restored, no event; **E2** (self-merge after the last Post) not restored, land `landed`, pending `[]`. |
| 3 codex/ deleted or moved | **met by name and inside a window; not outside — R2 (E4, E5)** | By name, agent: `update-ref -d` (bare, double- and single-quoted), `push . :codex/fix`, `branch -D`, `branch --delete --force`, `branch -D codex/{fix}`, `push . +HEAD:refs/heads/codex/fix`, `update-ref --stdin` naming it, `branch codex/new HEAD`, `worktree remove --force <codex worktree>`, and any command with cwd inside the codex worktree (`ls` included) — all `2`; reads and a copy cut from the tip pass. Lead: `update-ref -d`, `branch -D`, `push --delete`, `worktree remove`, `rm -rf <codex worktree>` refused. Misses by name (tripwire limits, all covered by effect inside a window): `B=codex/fix; git branch -D $B`, `for-each-ref … \| xargs git branch -D`, `symbolic-ref --delete` (harmless: git refuses it on a non-symref), a redirect or `cp` into the codex worktree from outside; from the lead also `update-ref --stdin`. By effect inside a window: E3 (the loose ref file removed) restored, E6 (force-move) restored, C2.9–C2.11 `ok`, C2.6 byte-identity `ok`. **E4** (deleted between calls) never restored; **E5** (moved after the last Post) not restored. |
| 4 stamped fields | **met; both numbers verified** | My own instrument (`census-item4.py`, read-only, 2,593 files): old-shape peer rows with no origin, no promptSource, not meta → **68**, every one accepted by the base's deny-list; no-origin `promptSource: sdk` rows → **670**, all `entrypoint: sdk-cli`. Main-session user text rows 4,678 (his 4,675 + this session's). C5.15/C5.15b/C5.16/C5.16b `ok`. |
| 5 four surviving mutants | **met** | C8.8, C9.6a/C9.6, C11.8/C11.8b `ok`; the four `S-` declarations present in the harness; their proofs are in the mutant pass (§6). |
| 6 wrong witness; liveness wording | **met** | claims suite 46/46 with A7/A7a/A7b and in-suite mutant R4; the unit mutant repointed (its proof is in the unit mutation pass, §6). |
| 7 `blocks_new_work` | **met** | `workspaces.py` `_item`: `"blocks_new_work": True`, `blocks_turn_end` unchanged; C5.13 `ok` (turn may end `0`, unrelated spawn refused `2`, named), C5.14 `ok`; unit 64/64. |
| 8 attribution after the last Post | **met for the spec's sentence and the stamped shape; `RED 0` not reached (expected); residual E7a — R2** | C10.7/C10.8/C10.7b/C10.7c/C10.7d `ok`; E7, E8 above; runner `RED 2` with both reds reviewer cases; mine retired here (§2). |

## 5 · What I broke, and what held

Scripts (all in my scratchpad, sandboxed): `attack-item1.sh`, `attack-effects.py` (drives the library through the hooks' entry points, reusing my probe's `Sandbox`), `attack-guard.sh` (the Bash guard with agent and lead payloads on a fixture whose main checkout sits ON the recorded branch and whose `codex/fix` is checked out in a linked worktree).

**Item 1 (runner, fixture repo, seven reviewer probes, branch under test `cc/engineer`):**

| variant | verdict | exit |
|---|---|---|
| control: 1 green, 6 red, all listed | `RED` ×6 | 1 |
| V1 gut into a stub (`print`), still listed | `UNRUNNABLE` | 1 |
| **V2 replace with a file that imports the library, `return 0`, still listed** | **`GREEN`** | **0** |
| V3 delist, file intact | `UNLISTED` + `MISSING` | 1 |
| V4 `git mv` + manifest line updated | old `MISSING`, new `RED` | 1 |
| V5 `git mv`, manifest not updated | `UNLISTED` + `MISSING` | 1 |
| **V6 `return 1` → `return 0` on the branch under test** | **`GREEN`** | **0** |
| V7 gut-and-delist (the engineer's W31) | `MISSING` | 1 |

**Items 2/3/8 by effect (library, sandbox, recorded branch `main`):**

| case | shape | result |
|---|---|---|
| E1 | agent commits onto `main` from the main checkout, inside a window | **not restored** (`f1ea0051 → da6b142a`, 0 events) |
| E1b | agent merges its own branch onto `main` from the main checkout, inside a window | restored |
| E2 | agent's own branch merged onto `main` after its last Post, before the end | **not restored**; land `landed`; pending `[]` |
| E3 | `codex/fix` deleted inside a window by `rm` of the loose ref file | restored |
| E4 | `codex/fix` deleted between two closed calls; another call; the end | **absent at every later observation** |
| E5 | `codex/fix` force-moved to the agent's tip after its last Post | **not restored** |
| E6 | `codex/fix` force-moved to the agent's tip inside a window | restored |
| E7 | my case C split: between two closed calls / after the last Post | first **left behind**, second attributed and gone |
| E8 | `run_in_background`-stamped Post, ref cut after it, next call | attributed; Rich's later bookmark not |

**Guard by name:** §4 items 2 and 3 carry the table; the full log is `attack-guard.out`. The eight point-14 verbs, the doorway, every deleter I could spell, `--stdin`, creation, `worktree remove`, `rm -rf` of a codex worktree (lead too), and cwd-inside-codex all refuse; variable indirection, `xargs`, a redirect into the codex path from outside, `checkout -`/`@{-1}`, and an agent's `commit`/`merge`/`reset --hard`/`rebase` in a main checkout that sits on the recorded branch all pass by name. The last group is E1's entry.

**Item 4:** both numbers re-derived on my own instrument (§4). **Item 7:** C5.13/C5.14 in my run. **Item 5/6:** the checks in my run; the proofs in §6.

## 6 · The mutation floor

Counts from the harness file at `151fa53f` (`grep -c` on `engine/scripts/workspace-spec-fourteen.mutation.sh`): `^mutant R-` → **24**, `^mutant S-` → **59**, `^mutant ` → **83**; `engine/scripts/lib/workspaces.mutation.sh` → **53**.

**RECORDED, spot-checked against the incidents they cite** (`grep -n` in `/Users/alex/ab/richos-hq/docs/verification/` and this tree): `R-p02-codex-deleter-passes-the-guard` → lifecycle-failure-record-2026-09-13.md:126 *"Point 2 of the CEO's page is violable today"* ✓; `R-p03-registration-without-identity` → 09-10 §3.4 (1 hit) ✓; `R-p04-branch-left-after-land` → 09-12.md:69 `git branch --contains 6fd5aef8` ✓; `R-p04-quarantine-instead-of-delete` → 09-12-addendum.md:75–86 `.richos-retired` ✓; `R-p05-new-work-not-blocked` → 09-12.md:138 §5 Type D ✓; `R-p07-discard-records-no-reason` → addendum §A2 *"Twenty-two cc/ branches deleted today"* (line 29) ✓; `R-p08-ignored-needed-files-landed` → `inflight-ack.sh` names echo-opus-529 ✓; `R-p09-finished-agent-not-locked-out` → 09-10.md:251 *"Thirteen agents have now been restarted"* ✓; `R-p11-sub-run-end-finishes-the-teammate` → 09-10.md:213 *"per-run identifier, not"* ✓; `R-p12-ended-session-agents-not-finished` → brief-audit-sage-round6 line 242 *"26 of the 49"* ✓; `R-p13-failed-deletion-not-retried` → 09-10.md:155 *"virtual machine holding files"* ✓; `R-p14-land-assumes-main` → 09-12 §2c exists (line 64) and brief-audit-sage-round6 §4.6 is my own; the quoted phrase is a paraphrase, not verbatim, in both — the incident is real, the quotation marks are loose. 12 of 24 checked; none invented.

**The pass:** filled in below from `fourteen-with-mutants/fourteen.txt` when the run ends (PENDING at this commit); any mutant it leaves unproven under this load is re-run alone with the engineer's `run-mutants.sh` and reported by name. The unit mutation harness (53) is run after it, for the same reason.

## 7 · Round 9

The engineer's §D list stands (install-and-measure; reconcile rows 4–7 and the `zach-opus-d1` record; the pause without a marker and the 93% pause; the two femcboost `CLAUDE.md` lines; the runner's witness; Frank's two cases; Rich's ack of `esc-20260912T225456Z-d34bf4e6` and `esc-20260913T073621Z-4d12a19f`). Add: **R1** (item 1's second option), **R2** (deletion restored at a Pre with no window open; the point-9 process fact keeping a window open; a recorded path for a `codex/` deletion the CEO has ordered), **R3** (a fact about the lead's move, or the isolation guard measured against the richos hooks). So round 9 is a build round for those and for the pause and the witness, then install-and-measure.

## 8 · Census

Two instruments, both read-only. (1) Per-file sha256 of every file (`find -type f`, sorted, `shasum -a 256` each, then sha256 of the list; absolute paths, so the digests do not compare to the engineer's relative-path ones — his counts do). (2) A listing census: name, size, mtime of every entry under `locks/` and `preserved/` plus sha256 of every top-level file.

| | before (10:56Z) | after |
|---|---|---|
| `~/.claude/state/workspaces` (5 files) — full content | `fa74f1e6812e6776c2335ae1cbc032817f6e143328ba31dd602e92f93d2c5bd4` | see the follow-up commit |
| `~/.claude/state/workspace-retirement` (11,286 files) — full content | `67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1` | see the follow-up commit |
| `workspaces` — listing instrument | `fa74f1e6…` (same 5 files) | |
| `workspace-retirement` — listing instrument (5,979 entries) | `48b2d8ef91c50df95c329bfbf732ebbe6f41b64b5cdc0c75f8e51f899db4de37` | |

## 9 · What I ran, with exit codes

`scripts/inflight-ack.sh --sha 151fa53f… --impact none` → 0 (row in `~/.claude/state/inflight-acks.jsonl`); `census.sh before` → 0; `run-unit.sh unit-all` → 0; `run-runner.sh runner-c9` → 1 (RED 2, expected); `run-suite.sh suite-guard` → 0; `suite-sealed` → 0; `suite-claims` → 0; `suite-probes` → 0; `suite-e2e` → 0; `census-item4.py` → 0; `attack-item1.sh` → 0 (per-variant exits in §5); `attack-effects.py e1 e1b e2 e3 e4 e5 e6 e7 e8` → 0 (results in §5); `attack-guard.sh` → 0 (per-command exits in §4/§5); my probe, every case → 1 (`held: 5/8`, the three not held are retired cases); `run-runner.sh runner-c9-after-tsv` → 1; `run-fourteen.sh fourteen-with-mutants with-mutants` → §6.

## 10 · What I did not do

- Did not read Frank's files; did not rule on his two cases.
- Did not rebuild the any-point alternative; ruled on the engineer's committed measurement of it and on my own case D.
- Did not run the full engine self-test (the CEO's standing rule).
- Did not re-run the base (`6a04423d`) — my round-8 audit measured the identical engine at `a0c1e1bd`.
- Did not measure the isolation guard against the richos hooks (R3's by-name cover is marked unverified).
- Did not add a new case to my probe for E7a or E4 (§2 says why); the findings live here with their reproducing scripts.
