NOT CERTIFIED

# Frank — certification of round 7 (`cc/zach-fable-m3` @ `44a7d5d4`)

**Branch:** `cc/frank-fable-c8` · **worktree** `/Users/alex/ab/richos-wt/frank-fable-c8` · cut from `cc/zach-fable-m3` @ `44a7d5d4939801698b7047e254a12e6ea4fd74ec` (seven commits over `dev/workspace-spec` @ `fa65987e`). **The spec:** the CEO's fourteen sentences in the private richos-hq repository, plans directory, `worktree-spec-2026-09-11.md` @ `c663a823`; the mirror in this tree was neither read as the spec nor touched. **The brief:** the round-7 brief in that repository @ `16f6cd25`. **Sage's work was not read**, with one exception I name: `workspace-probe-retirements.tsv` is a shared file and I read it whole before appending to it, so his two lines passed my eyes; nothing below uses them.

**Nothing installed, nothing left this branch.** No merge, no push, no `install.sh`, nothing written into `/Users/alex/ab/richos/engine`, no main checkout touched, nothing `codex/` touched. Every run was sandboxed twice: each harness redirects `HOME`/`CLAUDE_CONFIG_DIR`/`RICHOS_WORKSPACES_DIR` itself, and my wrapper (`scratchpad/c8/run.sh`) exports all four (`HOME`, `CLAUDE_CONFIG_DIR`, `RICHOS_WORKSPACES_DIR`, `RICHOS_SESSIONS_DIR`) into the scratchpad on top.

---

## 0. The verdict in six lines

1. **The headline is true.** I reproduced `FOURTEEN: 14 green, 0 red · self-check: green`, 113 `ok` / 0 `FAIL`, per-check counts identical to the engineer's, and the on-base measurement `FOURTEEN: 10 green, 4 red` with its "failed 71 times" tell — every number the engineer printed, I saw printed (§1, §6).
2. **The two reds I filed in round 6 are fixed and measured fixed**, my count was short by one defect of my own finding (F20), and the engineer's three-defect reading is right (§6 claim 1).
3. **Not certified, for four things a hostile agent or a broken build can still do that the CEO's sentences forbid and the fourteen cannot see** — each shown with its command and exit code, each a small fix (§2). The largest is the same class that refused round 6: an agent's call can still move the RECORDED integration branch with `git checkout -B`, `git switch -C` or `git fetch <refspec>`, and can rewrite a `codex/` ref with `git branch -f` — the guard enumerates verbs, not effects.
4. **Two of my extra mutants survive the fourteen** — point 8's "same name, different bytes" and point 11's "handed in but still running" — both holes in the checks, not in the code, which I read (§3).
5. **My own probes:** nine cases retired per case, signed `frank`, in the TSV; six cases kept and their fixture corrected to record the branch first, as point 14 requires; the CEO-descoped case survives the fix and is now red for its true reason (§4).
6. **Claims 1–5 ruled**, each by measurement (§6). The 59 mutations audited: all edit code, none the harness; 19 of 21 RECORDED citations resolve to the incident text I read, 2 lean partly on Sage's audits I did not read (§5).

What certifies it: the four items of §2, each with its fix named. None needs a design decision. Round 8 (install and measure on `main`) should not start on this branch until they are in, or it measures a guard with four open doors.

---

## 1. The headline, reproduced

| what | command (from `/Users/alex/ab/richos-wt/frank-fable-c8`, sandboxed) | its own verdict lines, verbatim | log |
|---|---|---|---|
| the fourteen, no mutants | `RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh` @ `44a7d5d4`, dirty 0 | `CHECKS RUN: 15  RED: 0` · `FOURTEEN: 14 green, 0 red · self-check: green` · `exit: 0` — **113 `ok`, 0 `FAIL`**; C0 6, C1 5, C2 8, C3 9, C4 5, C5 14, C6 3, C7 9, C8 7, C9 5, C10 6, C11 7, C12 11, C13 6, C14 12 | `scratchpad/c8/fourteen-nomut.txt` |
| the round-7 harness against the round-6 library and guard (`fa65987e`'s `workspaces.py` and `guard-worktree-removal.sh` copied into a sandbox copy of this engine; sha256 of both verified in the log) | `scratchpad/c8/on-base.sh` | `CHECKS RUN: 15  RED: 4` · `FOURTEEN: 10 green, 4 red · self-check: green` · `exit: 1` — reds C14.1, C14.9, C14.11; C2.8; C8.6, C8.5, C8.7; C13.2, C13.4 with `TELL THE CEO: deleting zach-opus-cz has failed 71 times … branch codex/other is codex/; never touched (point 2)` (74 by C13.4) | `scratchpad/c8/on-base.txt` |
| unit tests | `python3 -B -W ignore engine/scripts/lib/workspaces.test.py` @ `897ba549` (my branch; the engine is byte-identical to `44a7d5d4`, my two commits touch `docs/verification/` only) | `=== workspaces spec tests: 59 run, 0 failed ===` · `exit: 0` | `scratchpad/c8/unit.txt` |
| the fourteen with its 59 mutants | `bash engine/scripts/workspace-spec-fourteen.test.sh` @ `44a7d5d4`, dirty 0 | `=== mutation: all 59 properties proven load-bearing ===` · `CHECKS RUN: 15  RED: 0` · `MUTATION HARNESS: exit 0 (every property proven load-bearing)` · `FOURTEEN: 14 green, 0 red · self-check: green` · `exit: 0` — **59 `PASS`, 0 `FAIL`: 21 `R-`, 38 `S-`** (`grep -c '^  PASS  R-'` → 21, `'^  PASS  S-'` → 38); 113 `ok` in the un-mutated pass. Started 22:22Z, finished ~23:58Z: the machine was running other agents' mutation suites at the same time (load average 160–180, 13 mutation sandboxes), so the wall time is not comparable to the engineer's 12m15s. | `scratchpad/c8/fourteen-mut.txt` |
| my three probes, directly, sandboxed | `python3 -B <probe> engine/scripts/lib/workspaces.py` | §4 | `scratchpad/c8/probe-*.txt` |
| the probe runner on my branch, sandbox store, `dev/workspace-spec` recorded there by my wrapper | `bash engine/scripts/workspaces.sh integration --repo . --branch dev/workspace-spec --why … && python3 engine/scripts/workspace-probes.py --tree-only` @ `897ba549` | `probes discovered: 11` · my three files **UNRUNNABLE** (`the retirement of case 'floor-timing' names the right author ('frank') and is NOT attributable to that author. A3: the commit that wrote it (897ba5499a7b) has not landed on dev/workspace-spec`) · 2 GREEN (mine) · 2 RETIRED · 2 RED (Sage's, his to retire) · 1 GREEN (the engineer's seven cases) · 1 UNRUNNABLE (the engineer's, until his retirement lands) · `A PRIOR PROBE IS RED. THIS BLOCKS.` · `exit: 1` | `scratchpad/c8/probes-runner-my-branch.txt` |

Not run by me: the e2e suite, the Bash guard suite and its 19 mutants, the runner's own 43+17, and the unit mutants (44/45). The engineer's logs for those are committed at `docs/verification/round7-fixes-2026-09-12-logs/m3-*.txt`; I read them and did not re-derive them, and nothing in my verdict rests on them.

---

## 2. Greens I broke — what an agent or a broken build can still do

Every command below was fed to the real hook script as the platform would, with a sandbox store in which `dev/work` was RECORDED for a throwaway repository (`scratchpad/c8/guard-try.sh`, `guard-try-2.sh`; outputs in `guard-try.txt`, `guard-try-2.txt`). `rc=2` is the guard refusing; `rc=0` is the guard letting it through.

### 2.1 Point 14 — an agent's call can still MOVE the recorded integration branch (C14.11 asks four verbs; git has more)

```
  rc=2  [agent]  git -C $REPO branch -f dev/work HEAD                 (C14.11, holds)
  rc=2  [agent]  git -C $REPO update-ref refs/heads/dev/work HEAD     (holds)
  rc=2  [agent]  git -C $REPO push . HEAD:refs/heads/dev/work         (holds)
  rc=2  [agent]  git -C $REPO branch -M dev/work gone                 (holds)
  rc=0  [agent]  git -C $REPO checkout -B dev/work HEAD~0             <- moves it
  rc=0  [agent]  git -C $REPO switch -C dev/work                      <- moves it
  rc=0  [agent]  git -C $REPO fetch . HEAD:dev/work                   <- moves it (fast-forward)
  rc=0  [agent]  git -C $REPO fetch . +HEAD:refs/heads/dev/work       <- moves it (forced)
```

`checkout -B` / `switch -C` reset the named branch to the given commit and check it out in the agent's own worktree; git only refuses when the branch is checked out elsewhere. In richos the recorded branch `dev/workspace-spec` is checked out nowhere (the main checkout is on `main`), so an agent can retarget where every in-flight agent's work lands with one command the guard does not see. This is the round-6 defeat RN2c (`certification-frank-round6` §4) one verb over. **Fix:** add `checkout -B`/`switch -C` naming a recorded branch, and `fetch` with a refspec whose destination is one, to the guard's move set — the same shape as the existing `push` clause. Then C14.11 gains those forms and a mutant each.

**The wrapper, and the library without its name.** Also `rc=0`: `bash wrapper.sh` where the wrapper contains the refused one-liner; `python3 -c "…spec_from_file_location('x','…/workspaces.py')…record_integration(…)"`. The guard is a text rule and this is the class every text guard in this engine has (`claude -w` in a script is the same). I do not count it against the round — it is not closable by a text guard — but I record that **the engineer's own `m3-run-suite.sh` is exactly this shape** (`workspaces.sh integration --repo . --branch dev/workspace-spec` inside a script run from his agent's Bash call), so the runner's witness is still whatever the party running it recorded. Measured on a scratch clone (`scratchpad/c8/runner-defeat.sh`, `runner-R4-*.txt`, `runner-R5-*.txt`): with `wip` recorded in the store the runner reads, or with `dev/workspace-spec` force-moved to the engineer's tip, Sage's two retirements read **RETIRED** and the engineer's retired probe reads **GREEN**, exit 1 only because other probes are red. The closure I proposed in round 6 — the runner printing the recorded tip beside `origin/<branch>` and abstaining on a non-operator store — is still the cheap one and was not built.

### 2.2 Point 2 — an agent's call can rewrite a `codex/` ref and commit inside a `codex/` workspace

```
  rc=2  [agent]  git -C $REPO branch -D codex/fix                                     (C2.2, holds)
  rc=2  [agent]  rm -rf $CX                                                           (holds)
  rc=0  [agent]  git -C $REPO branch -f codex/fix HEAD          <- rewrites the ref; the codex/ commits are unreachable
  rc=0  [agent]  git -C $REPO push . HEAD:codex/fix              <- same
  rc=0  [agent]  cd $CX && printf 'edit\n' >> README && git commit -qam 'agent edits codex work'
  rc=0  [agent]  git -C $CX commit --allow-empty -m 'inside codex'
```

The page: *"A `codex/` workspace or branch is never deleted without the CEO's express word. An agent never works inside a `codex/` workspace."* A force-move that orphans every commit on `codex/fix` is a deletion of the codex work in all but the verb, and the second sentence is broken outright at `rc=0`. The frozen check 2 — "No deletion path reaches a codex/ path or ref" — is green because its deleters are aimed by the fixture and its byte-identity hash (C2.6) is never asked after a move. **Fix:** the guard already computes `moves` for the recorded branch (`branch -f/-m/-M/-D`, `--force/--move/--delete`); apply the same set, plus `push`/`fetch` destinations, to `codex/` refs; refuse an agent's `git -C <codex workspace>` / `cd <codex workspace> &&` write. Then C2 gains "an agent aiming a MOVE at codex/ is refused" and its mutant. No mutant can show this today because there is no code to remove — it is an un-built clause, which is the worse kind.

### 2.3 Point 5 — two non-person turn openers count as "answering the CEO"

`_turn_started_by_person()` (`workspaces.py:2946`) excludes `<task-notification|teammate-message|system-reminder|local-command|command-name>`. Fed one-turn transcripts (`scratchpad/c8/ceo-turn.py`, output `ceo-turn.txt`):

```
<task-notification>                        -> person=False   (C5.4 asks this one)
<cross-session-message>                    -> person=True    <- another agent's message, delivered as a user turn
[SYSTEM NOTIFICATION - NOT USER INPUT]     -> person=True    <- the platform's background-task wrapper
```

Both strings are ones this session delivered to me today, verbatim. A turn that began with either can spend point 5's one allowance — "answering the CEO" — and end with finished work pending. **Fix:** two more prefixes in the regex, and a C5.4b for each with its mutant.

### 2.4 The unit-mutant survivor (claim 3) — a one-token declaration defect left in the headline

Property pinned, declaration wrong (§6 claim 3). It is one token in `workspaces.mutation.sh:188` and it leaves the CEO-facing line reading `44/45` for a defect that is not one. It should be fixed on the branch before round 8, not carried.

### What I tried that HELD

C14.9 (the one-liner recording), C14.11's four verbs, C2.2's deleters, C1.2/C1.3 raw `worktree add` (including `worktree add -B dev/work …`, refused as a raw add), the lead's own moves (`rc=0`, as they must be), an agent moving an unrecorded branch (`rc=0`, precision). The manifest closures: a text-visible probe deleted with its manifest line in one commit → **MISSING**; a `getattr` probe invisible to the text scan, listed and committed, then deleted with its line in one commit → **MISSING** (`listed in the manifest at 5035051c3b60 and absent at HEAD`). Round 6's RN2d and RN2e are both closed (`runner-R4-*.txt`, `runner-R5-*.txt`; my R1–R3 runs wrote nothing because `dev/workspace-spec` did not exist in the clone and the record was refused — their state is carried in R4/R5, which ran after all three commits).

---

## 3. Mutations beyond the 59 — two survive, one confirms the split, two are answered without a run

Each applied to a sandbox copy of this engine and run through the fourteen without mutants (`scratchpad/c8/xmut.sh`; logs under `scratchpad/c8/xmut/`). "Survives" = `FOURTEEN: 14 green, 0 red`.

| mutant | the sentence | what it does | result |
|---|---|---|---|
| **F-A `_same_file` always True** (`workspaces.py:1736`) | point 8: "A workspace with uncommitted or ignored files it needs is not landed … Deletion therefore never loses anything" | an ignored file BOTH checkouts have, with different bytes — `.env` after a rotated key, which `.worktreeinclude` seeds into every worktree — is called identical and the land deletes it | **SURVIVES: `14 green, 0 red`.** C8.3 and C8.6 ask only files the main checkout LACKS. The code compares size then sha1 (I read it); the check does not ask. Add C8.8: same name, different bytes, holds the land. |
| **F-F handed-in finishes before the run ends** (`finished_state`, the `handed_in` test hoisted above `end`) | point 11: "'Finished' means the agent's run has ended … An agent that ends AFTER handing in its work is finished" | an agent that sent TaskCompleted and is still running is finished: refused every tool mid-run, its workspace landable while it writes | **SURVIVES: `14 green, 0 red`.** C11.7 asserts locked-out AFTER the end; nothing asserts live BETWEEN hand-in and end. The code is right (`handed_in` is read only under `if end:`); the check does not ask. Add C11.8. |
| F-Z the self-check forced red (`C0.3` expects 2 worktrees, in a copy of the harness) | round 7 brief §7: the CEO's number and C0 apart | is the split real? | **Real:** `FAIL C0.3` · `CHECKS RUN: 15  RED: 1` · `FOURTEEN: 14 green, 0 red · self-check: red` · `exit: 1`. The CEO's number is untouched by C0 and the exit code still carries it, which is right — a dirty sandbox is an unreliable measurement, not a red sentence. |
| the SessionStart auto-land disabled only at session start | point 5: "A session that starts with such work does that first" | | not run: `lifecycle()` calls `pending(sid, entity, scan=True)` with `auto=True` at SessionStart (read at `workspaces.py:3131–3137`), and the next gate (spawn guard, Stop gate) lands it on the same turn anyway, so the mutation has no observable effect on the page's terms — noted, not counted |
| `_delete` proceeds despite surviving processes | point 9 | | not run: `stop_processes` escalates to SIGKILL, so a survivor is not constructible in a fixture; unreachable rather than unasked |

**Order dependence, stated once.** The fourteen share one sandbox and one store, so a check cannot be run in isolation and one check's fixture can color another's: on the base, C2.8's `zach-opus-cz` produced C13's two reds (§1). The engineer's §12 says so. A C13 sub-assertion that greps for its OWN agent's name in the tell would make check 13 answer for point 13 alone; not added by anyone yet.

**One arithmetic hardening.** `FOURTEEN: $((FOURTEEN_RUN - FOURTEEN_RED)) green` — nothing pins `FOURTEEN_RUN` to 14. A harness that lost a `begin`/`verdict` block would print `13 green, 0 red` and exit 0. One line: `[ "$FOURTEEN_RUN" -eq 14 ]` in the exit condition.

---

## 4. My own probes — ruling per case, and the retirements

The point-14 spawn refusal turned my three listed files RED on the real manifest, every red case failing at the same line: `SpecError: no branch is recorded … so the spawn of … is refused`. That line says the FIXTURE stopped, not what the case asserts, so I read every case body before ruling (`certification-frank-recorded-attribution-2026-09-12-probe.py`, `certification-frank-window-and-target-2026-09-12-probe.py`, its `c4-control-no-refused-call.py`), then ran them all directly (`scratchpad/c8/probe-recorded-attribution.txt`, `probe-window-and-target.txt`, `probe-c4-control.txt`).

**Two kinds of red, and only one is obsolescence.** A case whose assertion IS the late-record heal ("spawn with nothing recorded, record afterwards, the land succeeds") cannot exist under point 14 at the spawn: obsolete. A case that merely SPAWNED with nothing recorded because the fixture never bothered — and asserts something point 14 never touched — is fixture-broken and still valid. The engineer's §6 reads all eight as the first kind. Six of my fourteen cases are the second kind.

### Retired, per case, signed `frank` (nine lines, commit `897ba549`)

| file | case | why (the TSV line carries the full text) |
|---|---|---|
| recorded-attribution | `floor-trap` | registered with nothing recorded, Rich records afterwards, asserts the land succeeds — the heal I ruled a guess in round 6 §5; the floor it targeted was deleted before round 6; the kept property (work merged onto its RECORDED dev branch lands) is green at `floor-control` and C14.3 |
| recorded-attribution | `no-floor-self-heals` | its one assertion is the heal itself; the one nothing-bound record that can still exist (an unregistered workspace) is refused until a sweep binds it (`test_point_14_a_record_bound_to_nothing_is_refused_never_guessed`, measured red under the mutant in §6 claim 3) |
| recorded-attribution | `floor-timing` | located WHERE the deleted floor read the branch; no floor, no reading; ruled obsolete in my runner-round certification §3 and unwritable then because retirement was per file |
| window-and-target, and its c4-control | `late-record-stray`, `late-record-side`, `late-record-rename` (×2 files) | spawn with nothing recorded, create the ref, record afterwards: the scenario point 14 refuses at the spawn; the shapes are asserted green with the record first by `record-first-control` (same file), C10.5–C10.6, and the three `serial-*` controls below |

The runner accepts `frank` as the author of the c4-control (its author is read from its docstring, `author_of()` second rule, since its basename carries no `certification-frank-`), and refuses all nine on **A3 until Rich lands this branch** — the runner working as designed, and the reason my three files read UNRUNNABLE rather than RED on my branch.

### NOT retired — still valid — and what it now costs

| case | why it stands | its state on the round-7 library |
|---|---|---|
| `floor-control` | records before the spawn; the positive control | HOLDS |
| `record-first-control`, `leaked-window-widens`, `leaked-window-evicts` | untouched by point 14 | HOLD (3/3 of the window file once the three retirements land) |
| `serial-stray`, `serial-side`, `serial-rename` | **I reverse my runner-round ruling "obsolete as written".** Its ground was that their coverage lived in the `late-record-*` cases — which are now themselves obsolete — and **the rename shape is asserted nowhere else in this tree** (0 hits for `branch -m`/`renamed` in the unit, e2e, fourteen and the engineer's seven-case probe). So they stay, with their fixture fixed (below) | HOLD 3/3 |
| `rich-at-my-tip` | the engineer's declared indistinguishable case, measured: the land refuses while `rich/rescue` is unmerged and the discard records the tip it deletes. Point 14 does not touch it | HOLDS |
| `outside-stray`, `outside-side` | **the CEO-descoped case.** A ref created by a backgrounded process after its own PostToolUse is created outside every window. My ruling "descoped is not obsolete" **survives the point-14 fix untouched**: the fix is about the record, this is about the window, and the record is now present. It does NOT make them retirable: retiring on obsolescence would be false, and retiring on his descoping needs his word, which I do not have | **BROKEN for their true reason:** `created_branches []`, `land: landed`, `branches after the land ['main','spare']` / `['main','sidework']`, `pending []`. `outside-side` used to read HOLDS only because the record-less land refused — a green for the wrong reason, now honestly red |

**The fixture fix (commit `24ffb2d0`).** A `before_session` hook, `_record_main`, records `main` before the session is recorded for the six cases that are not ABOUT the record; case bodies unchanged; `floor-trap`/`floor-control` record (or deliberately do not) inside their own bodies and are left as written. Result on `44a7d5d4`'s library: `5/10 cases hold; BROKEN: outside-stray, outside-side, floor-trap, no-floor-self-heals, floor-timing` — the three floor cases retired above, the two descoped cases red for their reason (`scratchpad/c8/probe-recorded-attribution-fixed.txt`).

**What it costs, plainly.** Once Rich lands this branch, `window-and-target` and its `c4-control` go GREEN. `recorded-attribution` stays **RED and blocking** on `outside-stray` and `outside-side` — a measured hole of the build that the CEO put out of scope — and the runner exits 1 on every round until either the window mechanism is extended to refs that appear between calls (Sage and I both measured the background overhang) or the CEO says in words that the case is not to be asked, which a retirement line could then quote. That is his decision, not mine, and it belongs on his list as a decision: **fix the descoped hole, or retire it on his word.**

---

## 5. The 59 mutations, audited

**5.1 Shape.** `engine/scripts/workspace-spec-fourteen.mutation.sh`: `grep -c '^mutant R-'` → 21, `'^mutant S-'` → 38, `'^mutant '` → 59. Targets: `$W` (`workspaces.py`), `$G` (the Bash guard), `$C` (`create-teammate-worktree.sh`), `$U` (`unlanded-branches.py`), `$Q` (`guard-unresolved-claims.py`) — **all code; none targets `workspace-spec-fourteen.test.sh` or any test file** (the class I caught in an earlier round is absent). Every `want` names a sub-assertion with a trailing space or a two-digit id (`grep -E '^mutant [^ ]+ "C[0-9]+ "'` → 0 bare checks), so a check red before the mutation cannot prove a mutant. The loop (`mutation-harness.sh`): the sandbox copy is mutated by `mutate.py`, which **exits 3 on an absent target** and the harness prints `FAIL — the mutation did not apply`; a suite that still exits 0 is `FAIL`; a red suite without `FAIL  <want>` is `FAIL … the red is unrelated`. All three failure paths are real, so a `PASS` means the named line went red under that edit.

**5.2 RECORDED citations, checked against the text.** The mutants cite `lifecycle-failure-record-2026-09-12.md addendum §A2/§A3/§A4`; the richos-hq record has no addendum — **the addendum is a file of this tree**, `docs/verification/lifecycle-failure-record-2026-09-12-addendum.md` (§A2 twenty-two `cc/` branches with no deletion event; §A3 974 finished rows / 973 ids; §A4 two `.richos-retired` quarantines at 16:12Z/16:13Z), so the citation resolves once one knows where to look; the mutant reasons should name the file. Resolved to the cited text I read: R-p03 ×3 (09-10 §3.4 "ownership row with no agent id", §3.1 "Nothing made removing a finished one happen", §2.11; A2), R-p04 ×2 (09-12 §2c `git branch --contains 6fd5aef8`; A4), R-p05 ×2 (09-10 §3.1 "de-duplicated"; 09-12 §5 Type D), R-p06 (09-10 §3.4 "sealed manifest is taken at spawn"), R-p07 ×2 (A2; 09-10 §2.2; my F1), R-p08 ×2 (09-10 §3b.2; `inflight-ack.sh` header; my §2.1), R-p09 ×2 (09-10 line 251 "Thirteen agents … restarted after their terminal record, from 0.3 seconds"; 09-11 S4; femcboost CLAUDE.md "zombie residue, 2026-07-18"; my brief-audit P11), R-p10 ×2 (A4; 09-10 §3.4 15,882 rows; my attribution §3 B1 and F19), R-p11 (09-10 §3.5 "per-run identifier"; A3), R-p13 (09-10 §2.17 "virtual machine holding files open"; my brief-audit P5), R-p14-spawn (my round-6 §5). **Two lean partly on Sage's audits, which I did not read:** R-p12 (`brief-audit-sage-round6 §4.3`; its other half, 09-10 §2.5 `pgrep`, resolves) and R-p14-land-assumes-main (`brief-audit-sage-round6 §4.6`; its other half, 09-12 §2c, resolves). Points 1 and 2 carry no R- mutant and the file says why; I found no mechanical incident for either in the three records or the addendum either.

**5.3 SPEC-DERIVED.** Each is a negation of a sentence I can point to on the page. Eight are attributed to my own findings (F2, F4, F10, F20, F26, F30, RN2b, RN2c) and each is the mutation I described.

**5.4 Reproduction of 59/59 — done.** `bash engine/scripts/workspace-spec-fourteen.test.sh` @ `44a7d5d4`, started 22:22Z, `scratchpad/c8/fourteen-mut.txt`: `=== mutation: all 59 properties proven load-bearing ===`, 59 `PASS` / 0 `FAIL`, 21 `R-` and 38 `S-` by `grep -c`, and the headline unchanged by the harness (`FOURTEEN: 14 green, 0 red · self-check: green`, `exit: 0`). Every one of the engineer's 59 `PASS` lines has its twin in my log. The engineer's run took 12m15s wall at 8-wide; mine ran on a machine at load 160–180 carrying thirteen other mutation sandboxes and took about 95 minutes, which says nothing about the harness.

**5.5 The self-check split** is real in code and in measurement: `verdict()` increments `FOURTEEN_RUN` only when `$CUR != C0` and routes a red C0 to `SELF_RED`; the headline prints the two apart; forced red (F-Z, §3) prints `FOURTEEN: 14 green, 0 red · self-check: red` and exits 1.

---

## 6. The five claims

**Claim 1 — "RED: 2 was right but short by F20; three defects, four red checks; is a 71-times retry a point-13 defect?"** Reproduced independently: `FOURTEEN: 10 green, 4 red` on the round-6 code, and the tell reads `failed 71 times` at C13.2 (74 at C13.4). **Ruling: the engineer is right on the count, and I was short by my own F20.** In round 6 I proved the base library HAS the codex guard and filed F20 as an invisible mutation; I did not ask what the base did after refusing. It returned `False` from `delete_branch` — a FAILED deletion — so `_delete` scheduled a retry, `RETRY_BASE=0` retried at every hook event, and at the fifth it told the CEO. That is one defect at the point-2/point-13 boundary: a refusal recorded as a failure. **The 71-times retry is that defect's symptom, not a fourth defect — but it does break a point-13 sentence:** *"The CEO hears about it only if it keeps failing"* — he heard about something that never failed and never could. So the honest CEO-facing statement for the base is **three defects touching four sentences (14, 8, 2/7, 13)**, and `delete_branch` returning `None` — "refused by the page, not a failure to retry" — is the right shape of fix (read at `workspaces.py:2759` and `_delete` 2613–2629).

**Claim 2 — "no code path for point 7's continuation" refuted.** Verified in the base source: `git show fa65987e:engine/scripts/lib/workspaces.py` has `for c in continues:` at line 1011 and `def _on_start(rec)` at 1194; `git diff fa65987e 44a7d5d4 -- workspaces.py | grep -E '^[-+].*(continues|_on_start)'` → empty, no hunk touches them; `_on_start` deletes the old agent's workspaces with `branches=False` and `_chain` walks `continues` at the land. My on-base run: `ok C7.8`, `ok C7.9` against the round-6 library. **A missing check, not an unimplemented sentence.** (The brief cites the line as `workspaces.py:1075`; that is a line of the round-7 file — 1011 in the base, 1075 after the insertions above it. Same statement.)

**Claim 3 — the unit survivor.** Measured (`scratchpad/c8/claim3.txt`): unmutated, both candidate tests pass; with `if work is None and chain:` → `if False:` applied to a sandbox copy, the DECLARED witness `test_point_14_the_integration_branch_is_recorded_never_inferred` still passes (`1 run, 0 failed`) and `test_point_14_a_record_bound_to_nothing_is_refused_never_guessed` fails (`AssertionError: 'bound to no body of work' not found in "… no branch is recorded …"` — the fallback reading, exactly). **The property is pinned; the mutant names the wrong witness.** "Report, don't fix" was defensible for a measurement-only pass whose rule was "no code change", but it leaves a false `44/45` in the CEO's line; it is one token and should go in before round 8 (§2.4).

**Claim 4 — the runner.** Round 6's two closures hold: **MISSING** for a text-visible probe deleted with its manifest line in one commit, and **MISSING** for a `getattr` probe listed and then deleted with its line (`listed in the manifest at 5035051c3b60 and absent at HEAD`). The two defeats by the party under test hold **at the guard, for the one-liner** (C14.9/C14.11 `rc=2`) and **not at the runner**: `wip` recorded in the store the runner reads → RETIRED/GREEN; `git branch -f dev/workspace-spec HEAD` → RETIRED/GREEN (§2.1). And the guard has four unenumerated move verbs (§2.1). The engineer's own honest wrapper is the shape of the bypass.

**Claim 5 — `agent-liveness.sh` reads a terminal agent ALIVE.** Read at the source, identical in the installed engine and this tree (`cmp` → identical): the module's own header states the bound — the lock's pid is the SESSION's pid, "A worktree whose agent finished but which has not yet been reaped still reads ALIVE" — and then calls the lock *"AUTHORITATIVE. The only source that decides."* Both are true of different questions: the lock decides "is the session that took this lock still running", never "is this agent finished". **Not the spec's problem** (the page: "No question of whether an agent is still alive … No liveness guessing of any kind"), **not this build's** (the spec build reads neither the lock's pid nor the ledger — its three `locked` hits are the parser of `git worktree list --porcelain`; it finishes on the recorded end-of-run signal, C11.6). **It is the engine's**, in one specific way: femcboost's CLAUDE.md tells Rich to run this tool before saying an agent is finished, and inside a living session its ALIVE cannot answer that. The word "AUTHORITATIVE" should say what it is authoritative FOR, and the instruction should point at the spec store's `finished_state()` once round 8 installs it. A wording and instruction change on `main`, not code in this round.

---

## 7. Census — before the first command, after the last

`~/.claude/state/workspace-retirement` is 10 GB and 16,626 entries (11,286 files), so the full per-file sha256 takes minutes; I took it anyway, both times, by the engineer's method so the digests are comparable, plus a name/size/mtime listing before, and the full content hash of the 12 KB `workspaces` directory.

| | before (22:18:54Z) | after (22:51:16Z, after my last store-relevant command) |
|---|---|---|
| `~/.claude/state/workspaces` — sha256 over sorted per-file sha256 | `8ce85db91270cb1234f325aad8ee9780c948b82fdcbc784c9a1c65099d0daf47` (4 files) | `8ce85db91270cb1234f325aad8ee9780c948b82fdcbc784c9a1c65099d0daf47` (4 files) |
| `~/.claude/state/workspace-retirement` — same method | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` (11,286 files) | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` (11,286 files) |
| `retirements.jsonl` lines | 10,706 | 10,706 |

Command, both times: `for f in ~/.claude/state/workspaces ~/.claude/state/workspace-retirement; do (cd "$f" && find . -type f | sort | xargs shasum -a 256 | shasum -a 256); done` (per-file lists in `scratchpad/census-before-*.txt` and `scratchpad/census-after-*-full.txt`). **No change: the round did not touch the operator's ledgers.** Both digests equal the engineer's before-and-after digests (`8ce85db9…`, `f5685892…`): his round and mine started from, and left, the same operator state. Nothing I ran points at either directory: every harness redirects its store, my wrapper redirects on top, and my scratch runs use `RICHOS_WORKSPACES_DIR` under the scratchpad.

One correction of my own reading, so it does not get repeated: at the start I saw `locks/`, `preserved/` and `retirements.jsonl` carrying mtimes of 17:12–17:13 local and took that for live writes by another agent's suite. Those are the 16:12Z/16:13Z quarantine events of the addendum's §A4, hours before I started. The identical digests are the proof; the mtimes were never evidence of anything current.

---

## 8. What I ran, with exit codes

| command | exit | log |
|---|---|---|
| `inflight-ack.sh --sha 44a7d5d4… --impact none` | 0 | ledger row |
| census (both methods), before | 0 | `scratchpad/census-before-*.txt`, `tasks/bcjpagr2y.output` |
| `run.sh fourteen-nomut fourteen` | 0 | `scratchpad/c8/fourteen-nomut.txt` |
| `run.sh fourteen-mut fourteen-mut` | 0 (59/59 proven, headline unchanged) | `scratchpad/c8/fourteen-mut.txt` |
| `on-base.sh` (round-7 harness, round-6 library+guard) | 1 (as expected: 4 red) | `scratchpad/c8/on-base.txt` |
| `run.sh unit unit` | 0 | `scratchpad/c8/unit.txt` |
| my three probes, direct, unfixed fixture | 1, 1, 1 | `scratchpad/c8/probe-recorded-attribution.txt`, `probe-window-and-target.txt`, `probe-c4-control.txt` |
| my recorded-attribution probe, fixed fixture | 1 (5/10; the two descoped + three retired) | `scratchpad/c8/probe-recorded-attribution-fixed.txt` |
| `guard-try.sh`, `guard-try-2.sh` | 0 (rc per command inside) | `scratchpad/c8/guard-try.txt`, `guard-try-2.txt` |
| `runner-defeat.sh` (scratch clone; R1–R3 record refused, R4/R5 ran) | 0 (runner exits 1 inside) | `scratchpad/c8/runner-R4-*.txt`, `runner-R5-*.txt` |
| `xmut.sh F-A …`, `xmut.sh F-F …` | 0 (`14 green, 0 red` — survived) | `scratchpad/c8/xmut/F-A-*.txt`, `F-F-*.txt` |
| `xmut.sh F-Z …` (C0 forced red) | 1 (`self-check: red`) | `scratchpad/c8/xmut/F-Z-*.txt` |
| `claim3.sh` | 0 (the pinning test fails under the mutant, as printed) | `scratchpad/c8/claim3.txt` |
| `ceo-turn.py` | 0 | `scratchpad/c8/ceo-turn.txt` |
| `run.sh probes-runner-my-branch probes-runner` @ `897ba549` | 1 (Sage's two red; mine UNRUNNABLE until landed) | `scratchpad/c8/probes-runner-my-branch.txt` |
| census, after (full per-file sha256, both directories) | 0 — identical to before | `scratchpad/census-after-*-full.txt`, `tasks/b4y4kzu53.output` |

Not run: the e2e suite, the guard suite and its mutants, the runner's own suite, the unit mutants, the full engine sweep (expected, per the brief).

## 9. What I did not do

Did not read Sage's certifications, audits or probes (his TSV lines excepted, as stated). Did not install, merge, push, or touch any main checkout or `codex/` ref. Did not change any engine file: my two commits are `docs/verification/` only (a probe fixture, the TSV). Did not answer the kill-path question or the point-5 sentence pair — both the CEO's. Did not read Sage's two RED probes to say why they are red; the runner names them and they are his to retire.
