FOURTEEN: 14 green, 0 red · self-check: green

# Round 8 — eight items, built and measured

**Branch:** `cc/zach-fable-m5` · **worktree** `/Users/alex/ab/richos-wt/zach-fable-m5` · cut from `dev/workspace-spec` @ `6a04423db60e7da8004fc2fda2b012da07f707b4` (`git rev-parse dev/workspace-spec` → that SHA; verified as the branch tip before the first edit). **`main` is `dcabcbd9`** and was not touched.
**The brief:** `/Users/alex/ab/richos-hq/docs/plans/round8-brief-2026-09-13.md` @ richos-hq **`91ea721b`** — verified byte-identical to the working copy before anything was built (`diff <(git show 91ea721b:…) …` → empty, printed `BRIEF-PINNED-OK`). **The spec:** the CEO's fourteen sentences at `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, read in full; the mirror in this tree was neither read as the spec nor touched, and its pin was not touched.
**Constraints kept:** no merge, no push, no `install.sh`, nothing written into `/Users/alex/ab/richos/engine`, no main checkout touched, nothing `codex/` outside a `mktemp` fixture. Every run is sandboxed twice — each harness redirects `HOME`/`CLAUDE_CONFIG_DIR` (or `RICHOS_WORKSPACES_DIR`) itself, and the wrappers in the log directory export `CLAUDE_CONFIG_DIR`, `RICHOS_WORKSPACES_DIR` and `RICHOS_SESSIONS_DIR` into the session scratchpad on top. The census (§C) is taken before the first command and after the last.

**The rule this report is written under:** a number that was not printed by a run of mine is not in it; every number names the log it was read from, and the logs are committed beside this file in `docs/verification/round8-fixes-2026-09-13-logs/` (the wrappers that produced them are there too). Where a claim could not be re-run it is marked **UNVERIFIED** by name.

**This report is written incrementally and committed with each item** (the brief's instruction; two engineers before me lost their reports). A section that says *in progress* is exactly that.

---

## A · The starting state, re-measured (not assumed)

All against `engine/` of this worktree at `6a04423d`, working tree clean except the untracked log directory (`dirty: 1` in the log headers is that directory).

| measurement | command (wrapper) | its own verdict lines (verbatim) | log |
|---|---|---|---|
| the fourteen, no mutants | `run-fourteen.sh base-6a04423d-no-mutants` → `RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh` | `CHECKS RUN: 15  RED: 0` · `FOURTEEN: 14 green, 0 red · self-check: green` · `exit: 0` — **113 `ok` lines** (`grep -c '^      ok'`) | `base-6a04423d-no-mutants/fourteen.txt` |
| the fourteen's mutant list | `grep -c '^mutant R-' / '^mutant S-' / '^mutant ' engine/scripts/workspace-spec-fourteen.mutation.sh` at `6a04423d` | **21 / 38 / 59** (the brief's starting numbers, reproduced by count; the 59-mutant RUN at the base is round 7's `m3-fourteen-with-59-mutants.txt`, not re-run here — the run that matters is the one after the fixes, §B) | — |
| the probe runner on the real manifest, store COPY with `dev/workspace-spec` recorded as `richos-001` | `run-runner.sh runner-base-6a04423d` → `RICHOS_WORKSPACES_DIR=<copy> python3 engine/scripts/workspace-probes.py --tree-only` | `probes discovered: 11` · **`GREEN` ×8, `RETIRED` ×2, `RED` ×1** (`certification-frank-recorded-attribution-2026-09-12-probe.py`, cases `outside-stray`, `outside-side`), `DECLARED` ×1 · `exit: 1` | `runner-base-6a04423d/runner.txt` |

The brief's starting state — `14 green, 0 red · self-check: green`, 113 sub-assertions, 59 mutants (21 RECORDED, 38 SPEC-DERIVED), gate `GREEN 8, RETIRED 2, RED 1, UNRUNNABLE 0, MISSING 0` — **reproduces**.

---

## B · Per item: the check, the engine, the command, the output, the verdict, the mutations

Engine for every row: `engine/` of this worktree at the commit named in the row. Every fourteen run is `run-fourteen.sh <label>` (the harness's own sandbox plus the outer one); every unit run is `run-unit.sh <label> [class]`.

### Item 7 · `blocks_new_work` exempted an item waiting on the CEO's word — one token, both halves asserted

**The defect, reproduced on the base before the edit:** `engine/scripts/lib/workspaces.py:1608` read `"blocks_new_work": kind != "ceo-discard"` (the round-7 build of Rich's inverted paraphrase). The page: *"that one item then waits on him, is on his TODO list, and blocks nothing else"* governs the other pending items and the turn; *"New work stays blocked either way"* governs new work, and its own parenthesis names *"the CEO's word"*. Both hold at once.

**The fix:** `"blocks_new_work": True` (`workspaces.py`, `_item`, with the reason in a comment beside it); `blocks_turn_end` untouched.

**The checks (under the frozen C5 heading):**
- **C5.13** now asserts BOTH halves: the wait is recorded with its TODO reference (`rc1=0`), the turn may end (`rc2=0`) naming the item, AND an unrelated spawn is refused (`rc3=2`) naming the item. The harness header's *"One clause is deliberately NOT asserted either way"* sentence and C5.13's abstaining comment are deleted; the page settles it.
- **C5.14** (new): a second agent, spawned while nothing was pending, finishes and is merged while the first still waits on his word — it lands on its own (`rc4=0`), its workspace is gone, its ending reads `landed`, and the first is still pending by name. *"blocks nothing else"*, observable.
- Unit: `test_point_05_a_ceo_discard_question_blocks_nothing_else` rewritten to assert the same three facts (it used to assert the inversion — `self.spawn("zach-opus-unrelated")  # new work is not blocked by it`).

**Measured** (`item7-no-mutants/fourteen.txt`, engine at the item-7 edit, `workspaces.py` sha256 prefix in the log header): `ok   C5.13 … (0): that item waits on him and the turn may end (0) … an unrelated spawn is refused (2), naming it` · `ok   C5.14 'blocks nothing else': the second finished item lands on its own (0) …` · `FOURTEEN: 14 green, 0 red · self-check: green` · **114 `ok` lines** (113 + C5.14) · `exit: 0`. Unit (`item7-unit-p05/unit.txt`, `Point05_Guarantee`): `9 run, 0 failed` · `exit: 0`.

**Mutations:** SPEC-DERIVED ×3 in the fourteen's harness — `S-p05-his-word-blocks-the-turn` (existing) → C5.13; `S-p05-ceo-wait-unblocks-new-work` (new: the round-7 line restored) → C5.13; `S-p05-his-word-blocks-the-other-items` (new: an auto-land that waits for his answer) → C5.14. Unit harness: `p05-ceo-wait-unblocks-new-work` (new) → `test_point_05_a_ceo_discard_question_blocks_nothing_else`. RECORDED: none — the record holds no mechanical incident for this clause; its incident is a mis-build measured by a reviewer (brief-audit-sage-round8 §3, `rc=0` at `a0c1e1bd`), which the new mutant's reason cites. Verdicts of the mutant RUNS are in §B's closing table, not here.

---

## C · The census

sha256 over the per-file sha256 list of each directory (`find … -type f | LC_ALL=C sort | shasum -a 256` per file, then `shasum -a 256` of the list — the same method as rounds 6 and 7, so the digests compare). Script: `census.sh` in the log directory.

| | files | before the first command (06:45:28Z) | after the last |
|---|---|---|---|
| `~/.claude/state/workspaces` | 5 | `aa2507954c2ca6ca62a61e58ea87fe48bca2653df966642795ba6d1a25b5b8e1` | *in progress* |
| `~/.claude/state/workspace-retirement` | 11,286 | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` | *in progress* |

The before-digests are byte-identical to Sage's round-8 after-digests (brief-audit-sage-round8 §9), so nothing moved between his audit and my first command either.

---

## D · The round-9 answer

*in progress*

## E · What I believe is wrong with a frozen check

*in progress*

## F · What I did not do

*in progress*

## G · Commits on `cc/zach-fable-m5`, oldest first

*in progress — filled in at handoff*
