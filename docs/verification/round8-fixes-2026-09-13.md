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

**Commit:** `9d9be6c9`.

### Item 6 · One mutant named the wrong witness; the liveness authority over-claimed

**The witness.** `engine/scripts/lib/workspaces.mutation.sh` declared `p14-nothing-bound-falls-back-to-current` against `test_point_14_the_integration_branch_is_recorded_never_inferred`; the red lands at `test_point_14_a_record_bound_to_nothing_is_refused_never_guessed`. Repointed, with the reason in a comment above the declaration. **Measured** (`unit-item6-59-tests-46-mutants.txt`, `bash engine/scripts/lib/workspaces.test.sh`): `=== workspaces spec tests: 59 run, 0 failed ===` · `PASS  p14-nothing-bound-falls-back-to-current — removing it turns "test_point_14_a_record_bound_to_nothing_is_refused_never_guessed" red  [56.1s]` · `[46 mutant(s), 8 at a time, wall 5m16.8s …]` · **`=== mutation: all 46 properties proven load-bearing ===`** · `exit: 0`. The unit tally is **46/46** (45 + item 7's `p05-ceo-wait-unblocks-new-work`), not the `44/45` round 7 reported — that count was true under a wrong witness and is not carried.

**The liveness wording, and a reader.** `engine/scripts/lib/agent-liveness.py` line 87 read `worktree-lock   AUTHORITATIVE. The only source that decides.` The lock's pid is the SESSION's, shared by every agent of that session (the file's own measurement of 2026-08-31), so it decides whether the session runs and never whether an agent is finished. Changed:
- the docstring says what the lock decides and adds the **workspace registry** (`scripts/lib/workspaces.py`, `finished_state` — point 11) as the source that decides *finished*;
- `resolve()` is now a wrapper: `_lock_resolve()` gives the lock's answer, `_registry_says(agent_id)` reads the registry (agents/ or done/ by the platform id), and a record that reads finished turns an `ALIVE` lock verdict into **`NOT-ALIVE`**, keeping the lock's own answer in the evidence (`lock_verdict`, `lock_reason`); a registry record that reads *not finished* beside a `NOT-ALIVE` lock is listed as a disagreement; an agent the registry does not know falls back to the lock;
- `engine/scripts/agent-liveness.sh`: header, the no-entity error, the report banner, a `workspace-registry:` line per agent, and the closing "The lock decides" sentence — all say the two sources and their two questions;
- `engine/scripts/hooks/guard-agent-state-claims.py`: its docstring's *"known false-positive mode"* (a finished, unreaped agent reads ALIVE) is described as closed for registry-known agents, and the notice no longer says *"the AUTHORITATIVE check disagrees … the lock is"* — it says the registry does not record the agent finished and the session's lock is held. The claim guard reads `finished_state` through the resolver it already calls.

**Measured** (`suite-item6-agent-state-claims.txt`, `bash engine/scripts/hooks/agent-state-claims.test.sh`): `PASS  A7a POSITIVE PROBE: a live-locked agent the registry records as RUNNING reads ALIVE` · `PASS  A7 a terminal agent inside a LIVING session (its lock held by a running pid) reads NOT-ALIVE: the registry decides finished (point 11), the lock only proves the session` · `PASS  A7b and the lock's own answer (ALIVE) is kept in the evidence beside the registry's` · `PASS  G- a TRUE claim about a terminal agent INSIDE A LIVING SESSION …` (the guard is silent) · `PASS  R4 MUTANT 'never ask the workspace registry' -> flips A7` · **`=== agent-state-claims tests: all 46 passed ===`** · `exit: 0`. The fixture's registry is a sandbox store (`RICHOS_WORKSPACES_DIR=$SANDBOX/ws`), the record built with the library's own `new_record`/`save_agent` and carrying a `SubagentStop` end signal.

**Mutations:** the unit harness's repointed `p14-nothing-bound-falls-back-to-current` (SPEC-DERIVED, point 14) → its true witness; the claims suite's own in-suite mutant `R4` (the registry never consulted) → A7. Not a sentence of the fourteen; no R-/S- mutant is added to the fourteen's harness for it.

**Not touched, by name:** femcboost's `CLAUDE.md` still sends the lead to `agent-liveness.sh` for "finished" (*"Liveness = the worktree lock"*); that file is in the other repository and is round 9's (§D).

**Commit:** `4d6c3cc4`.

### Item 5 · Four mutants survived the fourteen — the code is right, the checks now ask

Each survivor reproduced by Frank (brief-audit-frank-round8 §5: F-A, F-F, F-G, F-H, each `FOURTEEN: 14 green, 0 red` at `a0c1e1bd`). No library change; three sub-assertions and four mutants:

| survivor | why it survived | new sub-assertion (frozen heading) | new mutant |
|---|---|---|---|
| F-A `_same_file` → always True | C8's `.env` reached the main checkout by `cp`, so the compared bytes were always identical | **C8.8** the main checkout holds `.env` of the SAME NAME and SAME SIZE (14 bytes) with different bytes (`SECRET=nEEded`); the land is refused naming `.env`; sizes asserted equal in the check itself | `S-p08-same-name-is-same-file` |
| F-H same size → identical | same class; the constraint on C8.8's fixture | C8.8 (the same-size design is what makes this one red too) | `S-p08-same-size-is-same-file` |
| F-G the SIGKILL escalation removed | C9's holder is a `sleep`, which dies on TERM | **C9.6a** a `python3` holder that installs `SIG_IGN` for TERM is alive and survives a real SIGTERM (positive control, asserted); **C9.6** after the land it is dead, the workspace is gone, and the store's `processes-stopped` row for that pid records `survivors: null` | `S-p09-sigkill-escalation-removed` |
| F-F `handed_in` read before `end` | C11.7 called `task_completed` and `subagent_stop` back to back | **C11.8** after `TaskCompleted` and BEFORE its own `SubagentStop` the agent may still write (barrier 0) and nothing is pending (gate 0, not named); **C11.8b** after its own end it is refused (as C11.7) | `S-p11-handed-in-finishes-before-the-run-ends` |

**Measured** (`fourteen-item5-no-mutants.txt`): `ok   C8.8 … (exit 2), named by path` · `ok   C9.6a … (pid 59817, alive=1) and IGNORES TERM (still alive after SIGTERM: 1)` · `ok   C9.6 … (exit 0, alive=0): the SIGKILL escalation, and the store records no survivor (survivors: null)` · `ok   C11.8 … (0) … (0)` · `ok   C11.8b … (2 = refused)` · `FOURTEEN: 14 green, 0 red · self-check: green` · **119 `ok` lines** · `exit: 0`. (The first run of this log printed C9.6 red for a quoting defect in my own assertion — the store's `"survivors": null` carried its double quotes into an `eval`'d comparison; the process was dead, the exit 0, the row present. Fixed by stripping the quotes; the committed log is the re-run.)

**Mutations:** SPEC-DERIVED ×4, each labeled *constructed by frank-fable-b3* with the audit section; each turns its named sub-assertion red in the targeted run (`item5-7-mutants/mutants.txt`, §B's closing table). RECORDED: none new — points 8, 9 and 11 keep their existing R- mutants (`R-p08-…` ×2, `R-p09-…` ×2, `R-p11-…` ×1).

**Commit:** `261dc50e`.

### Item 1 · A gutted probe is not reported missing — "holds nothing" now means "not listed"

**The defect, on the base:** `engine/scripts/workspace-probes.py` `deleted_probes()` judged a manifest entry missing only when `not exists_at(root, "HEAD", rel)` — the path absent. A docs-only commit that hollowed a RED probe into a non-probe stub (no library name, no entry point — invisible to the text rule) and dropped its manifest line left `DELETED 0`, `NOT LISTED 0`, the probe gone from the report, exit 0 (certification-sage-round7 §0/§6; brief-audit-sage-round8 §2). Outright deletion was caught (W16, W30).

**The fix (the brief's first option, Sage's "listed" reading):** in the manifest-history scan, an entry listed at ANY commit on the lineage and **not listed at HEAD** is MISSING unless its author retired it — `head_entries = set(entries)` from the HEAD manifest, and an `elif rel not in head_entries` branch beside the existing absent-at-HEAD branch (that line is left byte-identical because the harness's `missing-reads-the-tree` mutant names it). What sits at the path is not asked. The MISSING report and the refusal block say "DELETED or DELISTED". The preferred option (run listed probes at the recorded branch's content) was **not built**; §F says so.

**The checks:** `workspace-probes.test.sh` W31a (ivy's listed probe is RED — positive control), **W31** (gut-and-delist in one commit → `MISSING … NOT LISTED at HEAD`, exit non-zero), **W31c** (jon's probe deleted outright with its line → still MISSING beside ivy's), **W31b** (ivy retires her file whole, landed on the recorded branch → no longer blocks; jon's unretired deletion still would).

**Measured** (`suite-item1-workspace-probes.txt`, `bash engine/scripts/workspace-probes.test.sh`): `PASS  W31a …` · `PASS  W31 a RED probe gutted into a non-probe stub AND delisted in one commit is MISSING and blocks …` · `PASS  W31c deletion is still caught beside delisting …` · `PASS  W31b retired by its own author and landed, the delisted probe no longer blocks …` · **`=== workspace-probes tests: all 47 passed ===`** (43 + 4) · `PASS  delisting-is-free — removing it turns "W31 " red` · **`=== mutation: all 18 properties proven load-bearing ===`** (17 + 1) · `exit: 0`.

**Mutations:** the runner's own harness gains `delisting-is-free` (the `elif` → `elif False:`) → W31. Not a sentence of the fourteen (the runner is the gate's mechanism, round 6 §7); no R-/S- mutant in the fourteen's harness. The runner on the real manifest after this change is measured in item 8's row (§B), since that is the run that reaches `RED 0`.

**Commit:** `fc9cfd42`.

### Item 8 · The attribution window closed before a late ref could be seen — closed on a fact the platform stamps, and the gate does NOT reach `RED 0`

**The defect, on the base (`runner-base-6a04423d.txt`):** `certification-frank-recorded-attribution-2026-09-12-probe.py` RED, cases `outside-stray` and `outside-side`. Run directly (`python3 -B <probe> engine/scripts/lib/workspaces.py outside-stray outside-side` at the base): `created_branches []`, `land landed`, `branches after the land ['main', 'spare']`, `VERDICT BROKEN` — the ref the backgrounded process created after its call's PostToolUse was compared against nothing, the land reported success, the ref was left behind.

**What the brief and both audits said, and what the probe actually does — a premise re-derived and found short.** The brief: *"`record_end` observes only windows still open, so a ref created after the agent's last `PostToolUse` is compared against nothing."* True — and I built exactly that first (the end signal compares once more against the LAST snapshot, `latest.json`; `item8-no-mutants`, C10.7/C10.8 green) — **and Frank's two cases stayed BROKEN** (`created_branches []`; the run is in this section's first bullet of the "measured" list). His cases create the ref between two calls and then make ANOTHER call, whose snapshot already holds it; the end-of-run compare against that snapshot sees nothing new. Neither audit's proposed fix (both: "at the end signal, diff against `latest.json`") makes its own author's red case green. Sage's `ref-after-post` (case C of `certification-sage-window-and-target`) asserts the gap for both shapes and HOLDS only while the gap exists.

**The real contradiction, measured.** The shape that makes Frank's cases green by fiat — attribute any ref that appears between two CLOSED calls and carries the agent's own unlanded work — was built and measured (`runner-item8-ALTERNATIVE-any-point-attribution-REJECTED.txt`, `unit-item8-ALTERNATIVE-any-point-attribution-REJECTED.txt`): Frank's file went GREEN, **and Frank's own control twin `c4-control-no-refused-call.py` went RED** (`leaked-window-widens`: *"'rich/rescue', which Rich cut while no window was open, survives the discard"* → `rich/rescue survived False`, `VERDICT BROKEN`) **and the engine's own `test_point_08_a_branch_that_existed_before_the_call_is_never_created_in_it` failed** (`['rich/bookmark', 'spare'] != ['spare']`). A ref at the agent's unlanded tip that appears between two closed calls is byte-identical in git whether the agent's backgrounded process or Rich cut it; attributing it buys point 3 with point 8 (*"Deletion therefore never loses anything that was meant to land"* — Rich's bookmark deleted by the agent's discard). **Rejected.**

**The fix, on a fact the platform stamps.** A Bash call issued with `run_in_background` is, by the platform's own word (`tool_input.run_in_background: true` on the PostToolUse payload — a field, never the text of the command), a call whose process is still running after its Post. So:
- `observe()` reads the stamp; `observe_created_refs(…, background=True)` compares the call's window now, then `_take_snapshots` writes it BACK marked `background` instead of unlinking it;
- every later observation of the agent (the next call's Post, an unkeyed Post, the end of the run) consumes the background windows as well as its own, and judges them **against their own before-sets, never unioned with a later snapshot** (`_attribute_new_refs(rec, bg_priors, None)`) — the next call's snapshot was taken while the process was still running and already holds what it created, so the union rule would call that ref old;
- the end of the run additionally compares once more against the last snapshot (`priors.append(latest)` when `all_open`), which is the brief's own observable;
- the four filters are unchanged, extracted into `_attribute_new_refs` and shared by all three paths. Between two ordinary CLOSED calls nothing changes: Rich's bookmark stays his.

**The checks (frozen C10 heading):** **C10.7** a ref created after the last PostToolUse is attributed at the end signal; **C10.8** it goes with the land; **C10.7b** a ref created by a backgrounded call's process after that call's Post — nothing recorded at the next call's Pre — is attributed at the next observation, judged against the background window's own before-set; **C10.7c** PRECISION: with a call still in flight, a ref cut at the agent's tip between two Pres is NOT attributed (Sage's case D, the union rule); **C10.7d** PRECISION: between two CLOSED foreground calls, a ref Rich cuts at the agent's tip is NOT attributed. Unit: `test_point_03_a_ref_created_after_the_last_post_is_still_the_agents`, `test_point_03_a_backgrounded_calls_ref_after_its_post_is_still_the_agents`; the pinned point-8 test is untouched and passes.

**Measured** (engine after commit `<item 8 SHA>`): `fourteen-item8-no-mutants.txt` — `ok   C10.7 …` · `ok   C10.8 …` · `ok   C10.7b …` · `ok   C10.7c …` · `ok   C10.7d …` · `FOURTEEN: 14 green, 0 red · self-check: green` · **124 `ok` lines** · `exit: 0`. `unit-item8-61-tests.txt` — `=== workspaces spec tests: 61 run, 0 failed ===`. **The runner on the real manifest** (`runner-item8.txt`): `GREEN` ×8 (`c4-control-no-refused-call.py` green again), `RETIRED` ×2, **`RED` ×2** — `certification-frank-recorded-attribution-2026-09-12-probe.py` (`outside-stray`, `outside-side`: its `post()` payload carries no `run_in_background`, so the engine is told the call is over) and `certification-sage-window-and-target-2026-09-12.probe.py` (`ref-after-post`: *"=> both refs left behind, attributed to nobody"* is its expectation; `bg-after-last-post` is now attributed, so it does not hold) · `exit: 1`. Sage's other five live cases HOLD (`held: 5/6`), case D (`rich-between-calls`) among them.

**The one-field fact, measured on a scratch copy never committed** (`frank-recorded-attribution-probe-with-run-in-background-stamp-SCRATCH-COPY.diff`, 4 lines, one changed: `"tool_input": {"run_in_background": True}` added to the probe's `post()` payload; `…-run.txt`): `=== 1 outside-stray … created_branches ['spare'] · branches after the land ['main'] · VERDICT HOLDS` · `=== 2 outside-side … created_branches ['sidework'] · VERDICT HOLDS` · **`2/2 cases hold`**. So the engine closes the hole for the platform's real shape; what stays red is a fixture that simulates the backgrounded call without stating it, and a case that asserts the gap.

**Verdict on the brief's completion test — honest, not filled in:** *"a ref created after the last PostToolUse is attributed"* — **yes** (C10.7, C10.7b, the unit tests). *"the gate reaches RED 0"* — **no: RED 2**, and it cannot reach 0 from this branch: the runner refuses a retirement signed by anyone but the probe's author (W5/W23) and editing a reviewer's probe is the thing the manifest was built to refuse. It needs Sage's per-case retirement of `ref-after-post` (his own §11 proposed the mechanism that makes it obsolete) and Frank's one-field stamp or retirement of his two cases. Raised to the lead through the ledger (`raise-item8-escalation.sh`, the record file it wrote is committed beside this report); the alternative and its cost are in the same ledger row.

**Mutations:** fourteen's harness — `R-p03-ref-after-the-last-post-left-behind` (RECORDED: the probe's cases, round 7 §6, round 8's base runner, escalation `esc-20260912T225456Z-d34bf4e6`) → C10.7; `R-p03-backgrounded-call-window-consumed-at-its-post` (RECORDED, same incident: the stamp ignored) → C10.7b; `S-p03-background-window-unioned-with-the-next-snapshot` (SPEC-DERIVED, point 3) → C10.7b; `S-p03-every-call-treated-as-backgrounded` (SPEC-DERIVED, point 8 — the rejected design as a mutant) → C10.7d. Unit harness — `p03-end-of-run-ignores-the-last-snapshot`, `p03-backgrounded-window-consumed-at-its-post`.

**Mutant runs, measured** (`mutants-item8-targeted.txt`, engine snapshot `workspaces.py sha256 9e81fb1432a58a74`): `PROVEN    R-p03-ref-after-the-last-post-left-behind — removing it turns "C10.7 " red` · `PROVEN    R-p03-backgrounded-call-window-consumed-at-its-post — … "C10.7b" red` · `PROVEN    S-p03-background-window-unioned-with-the-next-snapshot — … "C10.7b" red` · `PROVEN    S-p03-every-call-treated-as-backgrounded — … "C10.7d" red` · **`4 proven, 0 unproven`**. Unit harness (`unit-item8-61-tests-48-mutants.txt`): `61 run, 0 failed` · `PASS  p03-end-of-run-ignores-the-last-snapshot …` · `PASS  p03-backgrounded-window-consumed-at-its-post …` · **`FAIL  p03-unpaired-post-attributes-nothing — the mutation did not apply`** · `=== mutation: 1 property(ies) NOT proven load-bearing, 47 proven ===`. That one is harness drift my `_take_snapshots` rewrite caused — the line the mutant names moved — not a live hole: its target text is repointed in the same commit and it is re-proven in the targeted run `mutants-item8-unit-repoint.txt` (§B's closing table carries the final full-harness number).

**Commit:** `<item 8 SHA, filled at handoff>`.

---

## C · The census

sha256 over the per-file sha256 list of each directory (`find … -type f | LC_ALL=C sort | shasum -a 256` per file, then `shasum -a 256` of the list — the same method as rounds 6 and 7, so the digests compare). Script: `census.sh` in the log directory.

| | files | before the first command (06:45:28Z) | after the last |
|---|---|---|---|
| `~/.claude/state/workspaces` | 5 | `aa2507954c2ca6ca62a61e58ea87fe48bca2653df966642795ba6d1a25b5b8e1` | *in progress* |
| `~/.claude/state/workspace-retirement` | 11,286 | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` | *in progress* |

The before-digests are byte-identical to Sage's round-8 after-digests (brief-audit-sage-round8 §9), so nothing moved between his audit and my first command either.

---

## D · The round-9 answer: it exists, and here is what is in it, each line measured

The brief asked which reviewer is right — *"no build round remains"* or *"one does"* — and named five things. **The one who says a round 9 exists is right, with evidence:**

1. **Four `land-completeness` fixture rows sit in the operator's store.** `grep -c '' ~/.claude/state/workspaces/events.jsonl` → **8** rows; `grep -n 'land-completeness'` → rows **4, 5, 6, 7**, each `"event": "integration-recorded"`, repos under `/private/var/folders/…/T/land-completeness.rSiULs/{clean,mixed}/repo` and `…/land-completeness.URJ6Yc/{clean,mixed}/repo`, `"ts": "2026-09-12T12…"`. Some harness ran against the real store, once, before round 7's census was taken (both round-7 digests already contained them). The event kinds in the real log: `integration-recorded` ×5, `registered-cc` ×1, `cc-created` ×1, `registered-spawn` ×1. **Read-only; nothing here was changed** (§C's digests prove it).
2. **A registration bound to nothing on disk.** `~/.claude/state/workspaces/agents/16a15be1-…--zach-opus-d1.json`: `name: zach-opus-d1`, `session: 16a15be1-…` (this one), **`agent_id: ""`** (never bound by a PostToolUse[Agent]), `end: None`, `disposition: None`, `registered_at: 2026-09-11T23:57:34Z`, one `cc` workspace at `/Users/alex/ab/richos-wt/zach-opus-d1` on `cc/zach-opus-d1` with `deleted_at: None` — and **`exists: False`**. `integration_work: None` (registered before point 14's record existed; it will bind at the first sweep). `done/`, `ids/` and `sessions/` are empty. On install, point 12 finishes it at this session's end and the next session must land or discard a record whose workspace is gone. Round 9 starts by reconciling that store, and the fixture leak needs its harness named.
3. **The pause is a marker Rich must remember, and nothing implements the 93% pause.** `grep -rn -E '93 ?%|quota' engine/scripts/lib/workspaces.py engine/scripts/hooks/workspace-lifecycle.sh engine/scripts/hooks/guard-workspace-gate.sh` → **nothing**; `grep -rln -E '93 ?%|quota threshold|93% quota' engine/scripts` → **nothing**. A pause is recorded only by a `SendMessage` carrying `pause-until:` (`workspaces.py` line 3177, `prompt_lines(text, "pause-until")`) or by `workspaces.sh pause`. Point 11 names *"the automatic pause at the CEO's 93% quota threshold"*; no mechanism references it.
4. **femcboost's `CLAUDE.md` still sends the lead to the lock.** `/Users/alex/ab/femcboost/CLAUDE.md:209` — *"**Liveness = the worktree lock** (`git worktree list` → `locked` while running …)"* — and `:210` — *"run the authoritative check … `agent-liveness.sh`"*. Item 6 corrected the engine's wording and gave the resolver the registry; the instruction that reads it lives in the other repository, outside this round's branch, and is Rich's edit at cutover.
5. **The runner's witness** (Frank's round-6 closure: print the recorded tip beside `origin/<branch>`, abstain on a non-operator store) is not built and was not in this brief. UNVERIFIED beyond the reviewer's statement: I did not re-derive what the installed runner would print on the operator's store, because nothing is installed.

And two more this round produced (§B item 8): **the two reviewer cases that assert the attribution gap** (Sage's `ref-after-post`, Frank's `outside-stray`/`outside-side` fixture without the platform's stamp) need their authors' hands before the gate can read `RED 0`, and **the open escalation `esc-20260912T225456Z-d34bf4e6`** (`state: work-complete`, `for: ceo`, no ack in the ledger — `escalate.sh show` this session) is resolved as engineering by item 8 and needs Rich's ack with that disposition.

**What remains, listed:** install on `main` and measure the fourteen, the mutants and the runner against the INSTALLED engine with nothing running (the round-7 brief's own definition of the last round); reconcile the operator store (rows 4–7 and the `zach-opus-d1` record); decide how a hold without the `pause-until:` marker is treated (refused or auto-recorded) and build the 93% pause the page names; the two `CLAUDE.md` lines in femcboost; the runner's witness; the two reviewer retirements (or Frank's one-field fixture change) and Rich's ack. **So: round 9 is the install-and-measure round, and it is a build round only for the pause and the witness.**

## E · What I believe is wrong with a frozen check

*in progress*

## F · What I did not do

*in progress*

## G · Commits on `cc/zach-fable-m5`, oldest first

*in progress — filled in at handoff*
