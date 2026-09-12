NOT CERTIFIED

# Certification, round 7 — Sage (sage-fable-c8), 2026-09-12

| | |
|---|---|
| **Certifying** | `cc/zach-fable-m3` @ `44a7d5d4939801698b7047e254a12e6ea4fd74ec` — six code commits (`eedfbc7d` … `3ff0cefd`, zach-fable-m2) plus the report commit (`44a7d5d4`, zach-fable-m3), over `dev/workspace-spec` @ `fa65987e`. `git merge-base main cc/zach-fable-m3` → `dcabcbd9`; `main` is `dcabcbd99056928a9872cd94c1f3a385f8b21069`. |
| **Where I stood** | worktree `/Users/alex/ab/richos-wt/sage-fable-c8`, branch `cc/sage-fable-c8`, cut at `44a7d5d4` (`git rev-parse HEAD` at start → the same forty characters). Every harness run in this record ran from THIS worktree's `engine/`, never the engineer's. |
| **Yardstick** | `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, sha256 `957d21a4e76262c28bb8b69cd37249cc87eea326e12c927c2997ad9887b10978`, read in full. The mirror in this tree hashes the same today and was neither read as the spec nor touched. |
| **Brief** | `/Users/alex/ab/richos-hq/docs/plans/round7-brief-2026-09-12.md` @ richos-hq `16f6cd25` (227 lines, read in full). I audited its predecessor and returned `BRIEF NOT READY`; this is the round built from that audit and Frank's. **I did not open any file of Frank's** — where a mutant's reason string cites one of his findings by number, I verified the mutant's mechanics and took the citation as the engineer's, not as something I checked. |
| **Constraints kept** | nothing installed, nothing merged, nothing pushed, no `install.sh`, nothing written into `/Users/alex/ab/richos/engine`, no main checkout touched, nothing `codex/` touched, Frank's work unread. Everything that needed a commit ran in a throwaway clone under the scratchpad against a sandbox store. `main` is `dcabcbd9` before and after. |

**The headline, as I reproduced it** (`bash engine/scripts/workspace-spec-fourteen.test.sh`, HEAD `44a7d5d4`, dirty 0, outer sandbox exported on top of the harness's own):

```
[59 mutant(s), 8 at a time, wall 23m24.7s, slowest 9m34.3s R-p10-cc-workspace-left-behind, 7.3x serial]
=== mutation: all 59 properties proven load-bearing ===
CHECKS RUN: 15  RED: 0
MUTATION HARNESS: exit 0 (every property proven load-bearing)
FOURTEEN: 14 green, 0 red · self-check: green
exit: 0
```

113 `ok` sub-assertions, 0 `FAIL`; 59 `PASS` mutants — 21 `R-`, 38 `S-` — 0 `FAIL`. The no-mutant run printed the same fourteen lines (`fourteen-no-mutants`, exit 0, 113 ok). **Every number the engineer's report carries that I re-ran, I got.**

---

## 0 · The verdict, and exactly what it rests on

**What holds — and I would sign each of these on its own:**

- The CEO's fourteen are green at `44a7d5d4`, from my own run, with 59/59 mutants proven. The three defects the round set out to fix — point 14 at the spawn and at the guard, point 8's ignored directory, and point 2's refusal recorded as a failure — are fixed, and I reproduced all four red checks on the round-6 code with the round-7 harness (§3).
- The 26 added sub-assertions implement the frozen text, under the frozen headings, and nothing was removed (§4).
- The mutation floor is honest: the two points with no recorded incident say so instead of passing vacuously, and the recorded citations I spot-checked resolve (§5).
- Both refutations of my round-7 audit findings stand, and I accept them (§2).
- My three probe cases are obsolete for the reason the fix is right, and they are retired per case in `docs/verification/workspace-probe-retirements.tsv`, committed at `1dc4fc9f` (§1). The runner refuses them on my branch (A3) and accepts them after a simulated land — measured both ways.

**What does not hold — the one reason for the first line:**

- **Brief item 6, the runner's manifest closure, has the hole it was written to close, by another route.** The closure reads *"an entry listed at ANY commit and holds nothing at HEAD is MISSING unless its author retired it"*, and "holds nothing" is implemented as *the path does not exist* (`workspace-probes.py:644`, `not exists_at(root, "HEAD", rel)`). So one docs-only commit by the party under test that **replaces a red probe's content with a three-line stub and drops its manifest line** leaves the runner at `probes DELETED from history and not retired: 0`, `NOT LISTED: 0`, the probe absent from the report, exit 0 (§6, attack 3b, output quoted). Deleting the file the same way is caught (attack 3a → `MISSING`, exit 1). This is the class I refused certification for at `17622403` — a probe made to disappear from the runner by one line nobody attributed — and the record accepted that refusal and built the manifest from it. I hold the same line here.

The fix is one condition, and it is an engine edit, so it is not mine to make (A2 would refuse my own retirement if I touched it): **an entry listed at any commit is MISSING when it is not listed at HEAD and not retired, whatever file happens to sit at its path.** The better shape, which also closes an edit I did not have to measure to see — an engineer changing a reviewer's assertion to `return True` — is to **run every listed probe at the content the recorded integration branch's tip has**, so that nothing on the branch under test changes what runs until Rich lands it; that is A3 applied to content. Either is a round-8 item of minutes, and everything else in this record is ruled so that round 8 stays one round.

**Expected and not held against the round:** the unit-mutant survivor (§7 — real, one token, the property is pinned); Frank's three probes red (his); the engineer's probe `UNRUNNABLE` until his retirements land; the full engine sweep not run.

---

## 1 · My three cases — ruled per case, retired per case

The point-14 fix refuses a spawn with nothing recorded (`register_spawn` → `_refuse_unrecorded`, `workspaces.py:1109–1127`; `register_cc` too, `:995–1001`). All three of my cases spawn with nothing recorded as their **first act** and assert something about the land afterwards. I ran each directly against the library at `44a7d5d4` (`run-probe-direct.sh`, sandboxed):

| case | what it asserted | what happens now | ruling |
|---|---|---|---|
| `certification-sage-runner-round-2026-09-12.probe.py` **R4** `record-heals` | nothing is inferred before the first spawn; the LAND refuses and names the command; recording `dev/work` afterwards makes the same land succeed | `EXCEPTION SpecError: no branch is recorded … the spawn of zach-opus-r4 is refused` — `held: 9/10; NOT HELD: R4 record-heals`, exit 1 | **Obsolete.** The "afterwards" is the heal I myself ruled a guess (certification-sage-round6 §2, S1–S4). Its live halves are asked elsewhere, each verified: refusal-names-the-command → C14.1 + `R-p14-spawn-not-refused-without-a-record`; nothing-frozen-onto-the-record → `test_point_14_the_integration_branch_is_recorded_never_inferred` under `p14-frozen-copy-restored`; the one record that can still be bound to nothing → `test_point_14_a_record_bound_to_nothing_is_refused_never_guessed`. With R4 excluded: `held: 9/9`, exit 0. |
| `certification-sage-window-and-target-2026-09-12.probe.py` **`escalation-stray`** | a ref created in an agent's own call while the repository has NO record is left behind after Rich records and lands (esc-20260912T112834Z-91a77eef) | `SpecError … the spawn of zach-opus-e1 is refused` — `held: 6/8` | **Obsolete.** No agent's call can be open while nothing is recorded. The live half — a ref created in the agent's own call is recorded against it and goes with the work — is C10.5–C10.6 (`R-p10-created-branch-left-behind`) and my R5/R6, green. |
| … **`escalation-stray-cc`** | the same, stray named `cc/…`: does the point-3 sweep find it | `SpecError … the spawn of zach-opus-e2 is refused` | **Obsolete**, same reason. Live half — an unregistered `cc/` branch is finished work of an ended session, listed by name — is C3.8–C3.9 (`R-p03-unregistered-branch-never-listed`), green. |

The other five cases of the window-and-target probe and the other nine of the runner-round probe **stand and keep running**; none is retired.

**One thing I had to do first, and it is a defect I found in my own probe, not the runner's:** the runner reads a probe's case names only from a literal `CASES = [...]` list or `SCENARIO ==` literals (`cases_of`, `workspace-probes.py:368`), and my runner-round probe carried its cases in a `RUNNERS` tuple list instead — `cases_of` returned `[]` for it (measured: `cases=[]`), so any per-case line for R4 would have been refused as *"names case 'R4', which this probe does not have"*, and the only retirement open to me would have been the whole file, throwing away nine green assertions for one exit code. Commit `ef194726` adds the literal list to my probe with an assertion that it equals `RUNNERS`' first tokens (`cases=['R1', …, 'R10']` after). It is my own file, docs-only, and it changes nothing the probe asserts.

**The retirement lines** are the last three of `docs/verification/workspace-probe-retirements.tsv`, four fields each, signed `sage`, commit `1dc4fc9f`. Their attribution is only real once Rich lands `cc/sage-fable-c8` onto `dev/workspace-spec` — the runner says exactly that today:

```
UNRUNNABLE certification-sage-runner-round-2026-09-12.probe.py
           the retirement of case 'R4' names the right author ('sage') and is NOT attributable
           to that author. A3: the commit that wrote it (1dc4fc9fdf12) has not landed on
           dev/workspace-spec, the branch recorded for this work (point 14).
```

and, in a clone where the lead merges my branch onto `dev/workspace-spec` (`verify-retirements.sh` step B):

```
GREEN      certification-sage-runner-round-2026-09-12.probe.py        23.5s
           ran 9 of 10 case(s); the rest are retired per case. case 'R4' retired by sage [1dc4fc9fdf12, landed on dev/workspace-spec @ 1dc4fc9fdf12] …
GREEN      certification-sage-window-and-target-2026-09-12.probe.py   12.6s
           ran 6 of 8 case(s); the rest are retired per case. …
```

With that land simulated, the FULL real manifest from `dev/workspace-spec` (step C) is red on exactly three files — Frank's `recorded-attribution`, `window-and-target`, and its `c4-control-no-refused-call.py` — and green or retired on everything else, the engineer's included.

---

## 2 · The two refutations — both accepted

**1. "Point 7's continuation clause has no code path in the library at all" — refuted, and I accept it.** At the base (`git show fa65987e:engine/scripts/lib/workspaces.py`): line 993 parses `continues:` prompt lines; 1011–1017 refuses a `continues:` naming no pending finished agent and requires the old tree clean; 1051 binds the keys onto the record; 1152 and 1190 call `_on_start`; 1194–1207 is `_on_start`, which marks the old agent `continued` and `_delete`s its live workspaces with `branches=False`. At `44a7d5d4` the same function sits at 1271–1284 and `sed -n 1194,1207p base | sha256` = `sed -n 1271,1284p tip | sha256` = `9f3fa004…` — byte-identical. My round-7 grep asked for a flag or a phrase (`--continue`, `continue from`, `takes over`) and the mechanism is a prompt line; `grep -c continu` is 73 at the base. A zero-hit grep for a shape I assumed was not evidence of absence, and I should have read `register_spawn` rather than searched it. What round 6 lacked was the check, and round 7 added it: C7.8 and C7.9 are green **on the base code** in my on-base run (§3), which is the measurement that settles it.

**2. "Three reds on the frozen fourteen" — my count does not stand, and the engineer's reading is right.** My third red was the continuation clause, refuted above. The round-7 harness against the round-6 library and guard (sha256 of both verified in the log, `2a2b86d9…` / `03109245…` both sides) prints:

```
FAIL C14.1  FAIL C14.9  FAIL C14.11        — point 14 at the spawn and at the guard
FAIL C2.8                                  — a codex/ refusal recorded as a FAILED deletion
FAIL C8.6  FAIL C8.5  FAIL C8.7            — an ignored directory skipped by name (one defect)
FAIL C13.2  FAIL C13.4                     — "TELL THE CEO: deleting zach-opus-cz has failed 71 times"
CHECKS RUN: 15  RED: 4
FOURTEEN: 10 green, 4 red · self-check: green
```

C13's two reds are C2.8's fixture spilling into check 13's turn-end output — `zach-opus-cz` is C2.8's agent — so it is the C2.8 defect seen from point 13's side, not a fourth. **Three defects, four red checks.** Frank's two (C14, C8) plus the one he filed as an invisible mutation rather than a red (his F20, which I know only from the mutant's reason string and the engineer's report). The engineer's "Frank was short by his own F20" is a fair reading of the measurement; whether it is a fair reading of Frank's file is not mine to say.

---

## 3 · Per point — verdict at `44a7d5d4`, on the round-6 code, mutants, and my ruling

All from my own runs (`fourteen-with-mutants`, `fourteen-no-mutants`, `fourteen-on-base`). "R"/"S" counts are the `PASS` lines of my mutant run, matched to the declarations in `workspace-spec-fourteen.mutation.sh`.

| pt | check | tip | base | R | S | ruling |
|---|---|---|---|---|---|---|
| 1 | C1 non-`cc/` non-native workspace refused | 5/5 | pass | 0 | 2 | holds; no recorded incident, said so (§5) |
| 2 | C2 no deleter reaches `codex/`; **C2.8** a deleter aimed at a `codex/` ref on a record refuses it and the discard completes | 8/8 | **FAIL C2.8** | 0 | 3 | holds. The fix (`delete_branch` → `(None, why)` for `codex/`; `_delete` records `codex/ untouched` and drops the ref from the record) reads point 2 as an answer, not a failure — the right reading, and it is what stops point 13 from telling the CEO about a deletion that could never succeed |
| 3 | C3 registration failure = no spawn; `claude -w` refused; **C3.8–9** an unregistered `cc/` BRANCH with no workspace is in point 5's list and is discarded | 9/9 | pass | 3 | 2 | holds |
| 4 | C4 after a land nothing survives; **C4.4** now diffs git's ref list and worktree registry of BOTH repositories before/after | 5/5 | pass | 2 | 2 | holds. C4.4 is the one sub-assertion whose TEXT changed (the harness header's "none reworded" is true of the headings, not of this line) — the change is the brief's, and the old grep-two-names could not see a parked tree |
| 5 | C5 finished-and-unlanded blocks; the two allowances; **C5.10** the stop-order half (my round-6 finding, restored); **C5.11–12** outside-reach needs a TODO reference, then the turn may end and new work stays blocked; **C5.13** a CEO-word wait: the turn may end, new work deliberately NOT asserted | 14/14 | pass | 2 | 6 | holds. C5.13's abstention is correct: the page says "blocks nothing else" and "New work stays blocked either way" three sentences apart, and encoding either would be deciding for him |
| 6 | C6 native pair under points 3, 4 | 3/3 | pass | 1 | 1 | holds |
| 7 | C7 every ending landed or discarded; **C7.6** no reason → refused; **C7.7** neither `--ceo-word` nor `--not-ceo-ordered` → refused; **C7.8–9** continuation: old workspace deleted at the new start, old branch kept, old work landed with the new | 9/9 | pass (C7.8–9 included) | 2 | 5 | holds; C7.8–9 green on the base is what refutes my third red |
| 8 | C8 nothing uncommitted or needed-ignored lands; **C8.6–7** an ignored directory the main checkout also has is compared by content — a needed file and a nested repository's commit under `.claude/` hold the land and are named, and after Rich keeps them nothing is lost | 7/7 | **FAIL C8.6, C8.5, C8.7** | 2 | 1 | holds. `_ignored_dir_diff` walks the directory, `.git` objects included, bounded by the gate's deadline; a walk that overruns raises `Deadline` and the item stays pending rather than landing — fail closed, the right side. Point 8's second sentence (Rich commits what it left) is driven as fixture at harness line 570 |
| 9 | C9 restarted finished agent gets no tool; processes stopped before deletion | 5/5 | pass | 2 | 0 | holds; both clauses have incidents, so both mutants are R |
| 10 | C10 both workspaces and both branches as one; **C10.5–6** a branch created in the agent's own call is recorded against it and goes with the work | 6/6 | pass | 2 | 1 | holds |
| 11 | C11 a sub-run's stop does not finish the teammate; pauses; **C11.7** handed-in-then-ended is finished even if a pause was sent | 7/7 | pass | 1 | 3 | holds |
| 12 | C12 session recorded at start; end from process start-time; **C12.7–8** two live sessions each handle their own; **C12.9–11** a RECORDED end is an end even with the process alive | 11/11 | pass | 1 | 4 | holds |
| 13 | C13 retried without involvement; CEO told after 5 | 6/6 | **FAIL C13.2, C13.4** (C2.8's fixture) | 1 | 1 | holds at the tip. The engineer's own note is right: C13 greps the turn-end output for any `TELL THE CEO`, so another check's fixture can turn it red; a sub-assertion naming C13's own agent would make check 13 answer for point 13 alone. Round 8, small |
| 14 | C14 recorded before the first spawn or refused naming the command (C14.1); every consumer asks the record; **C14.8** a `cc/` branch refused as target; **C14.9–10** an agent's call recording it refused, the lead's passes; **C14.11–12** an agent's `branch -f`/`update-ref`/`push`/`-D` on a recorded branch refused, on an unrecorded one not | 12/12 | **FAIL C14.1, C14.9, C14.11** | 2 | 7 | holds as written. C14.9/11 prove the guard refuses the literal commands; they do not, and do not claim to, prove an agent cannot record or move the branch some other way (§6) |
| 0 | C0 the sandbox ends clean | 6/6 | pass | — | — | not one of his fourteen; printed apart, as the brief asked |

---

## 4 · The frozen fourteen: did the harness implement the frozen text?

I diffed `engine/scripts/workspace-spec-fourteen.test.sh` between `fa65987e` and `3ff0cefd` (418 lines). No `begin Cn` heading changed; no sub-assertion was removed; one sub-assertion's text changed (C4.4, above). The 26 added labels are C2.8, C3.8, C3.9, C5.10–C5.13, C7.6–C7.9, C8.6, C8.7, C10.5, C10.6, C11.7, C12.7–C12.11, C14.8–C14.12 — 26, the engineer's count. Against the brief:

| brief | sub-assertion(s) | my check |
|---|---|---|
| §1 refuse the SPAWN | C14.1 (round 6's text, unchanged — it was red on the base because it was already right) | ✓ |
| §2 point 8 by content, the incident's shape | C8.6, C8.7 | ✓ — a needed file AND a nested repository with a commit nobody else has, under `.claude/` |
| §3 who records it | C14.9, C14.10, C14.11, C14.12 | ✓ for the literal forms; see §6 |
| §4.1 discard without a reason | C7.6 | ✓ |
| §4.2 attestation dropped | C7.7 | ✓ |
| §4.3 a session claiming a live session's agents | C12.7, C12.8 | ✓ — two live sessions, positive control present |
| §4.4 created branches ignored | C10.5, C10.6, C3.8, C3.9 | ✓ |
| §4.5 library's `codex/` guard removed | C2.8 | ✓ — a deleter is aimed at `codex/other` on a record |
| §4.6 handed-in-then-ended | C11.7 | ✓ |
| §4.7 CEO-wait item and new work — **transcribed backwards** in the brief | C5.13 asserts neither reading | ✓ the right call |
| §4.8 continuation | C7.8, C7.9 | ✓ |
| §4.9 recorded session end ignored | C12.9, C12.10, C12.11 | ✓ |
| §4.10 outside-reach wait with no TODO | C5.11, C5.12 | ✓ |
| §4.11 ignored directory | C8.6 (+ mutant `R-p08-ignored-directory-skipped-by-name` restores the round-6 code) | ✓ |
| §4.12 killed mid-session | no code; recorded as the CEO's question (report §8) | ✓ |
| stop-order half (my round-6 finding) | C5.10 | ✓ |
| §4 "run the census over every sentence" | C14.8 (*"Finished work never waits on the agent's own branch"*) is what it found | partial — see below |
| §5 C4 asks the registry and ref list | C4.4 | ✓ |
| §6 manifest read at every commit | `deleted_probes`, `:630–645` | implemented for deletion; **not closed for a gutted file** (§6) |
| §7 headline apart; citation rephrased and exemption deleted | `FOURTEEN:` line; `bf4646a8` | ✓ — the header of the frozen record was rephrased, the measurement under it untouched |

**Every sub-assertion is driven through the registered hooks** (`guard-worktree-isolation.sh`, `guard-worktree-removal.sh`, `guard-sealed-worktree.sh`, `observe-created-refs.sh`, `workspace-lifecycle.sh`, `guard-workspace-gate.sh`) with the platform's payload shapes, the same discipline as round 6; positive controls are present where a refusal is asserted (C14.10, C14.12, C12.8).

**My own census, vocabulary against the harness.** Two clauses still have no sub-assertion by name, and neither blocks: point 11's *"including the automatic pause at the CEO's 93% quota threshold"* (zero hits for `93`/`quota`; C11.3–C11.5 ask pauses generically, and the quota pause is one instance of a pause with what ends it named — acceptable, but a one-line fixture naming `pause-until: the quota reset` would make the instance visible); and point 14's *"The dev branch reaches main when the work is certified and ready"* (a process sentence, not measurable in a harness). "No agent stays paused forever" is asked through C11.5 (a nameless pause is pending) and C11.6 (stopped → finished). I found nothing implemented easier than the sentence.

---

## 5 · The mutation floor

**Points 1 and 2 with no RECORDED mutant — honest.** I grepped the three lifecycle records myself: `codex/` appears 0 times in the 09-10 record, 5 in 09-11 (all about briefs and the wording of the rule: G2, G3, G6, R10), 4 in 09-12 (*"closed as a topic"*, *"untouched"*) — no deletion, no write, no incident. The pre-spec `zach-opus-dor1` in 09-10 is an agent name from before point 1 existed. A vacuous R- mutant for either point would have been the lie; saying "none" is not.

**Spot-checks of RECORDED citations, each resolved to a line (Frank's files excluded by instruction):**

| mutant | cites | found |
|---|---|---|
| `R-p03-registration-without-identity` | 09-10 §3.4 "ownership row with no agent id"; brief-audit-sage-round6 §4.2 | 09-10:204; my audit, `agent_id ""` |
| `R-p03-unregistered-never-listed` | 09-10 §3.1/§2.11 "Nothing made removing a finished one happen"; five finished branches | 09-10:173, :106 |
| `R-p04-branch-left-after-land` | 09-12 §2c `git branch --contains 6fd5aef8` → three `cc/` branches | 09-12:69–70 |
| `R-p05-turn-end-not-blocked` | 09-10 §3.1 "de-duplicated … went quiet" | 09-10:170 |
| `R-p06-native-workspace-not-registered` | 09-10 §3.4 "sealed manifest … unreclaimable for the life of a session" | 09-10:201–202 |
| `R-p08-ignored-needed-files-landed` | 09-10 §3b.2 nested repository deleted with no copy; `inflight-ack.sh` header, echo-opus-529 | 09-10:265; `inflight-ack.sh:37` |
| `R-p09-finished-agent-not-locked-out` | 09-10 §3b.1 "Thirteen agents … restarted"; 09-11 §2 S4 the fourteenth | 09-10:251; 09-11:75 |
| `R-p09-processes-not-stopped` | femcboost CLAUDE.md "zombie residue, 2026-07-18" | present (1 hit) |
| `R-p10-cc-workspace-left-behind` | 09-10 §3.4 "Zero of 15,882 finish rows" | 09-10:199 |
| `R-p11-sub-run-end-finishes-the-teammate` | 09-10 §3.5 "per-run identifier, not the owning agent" | 09-10:213 |
| `R-p12-ended-session-agents-not-finished` | brief-audit-sage-round6 §4.3 "26 of the 49 holds"; 09-10 §2.5 `pgrep` cannot see subagents | my audit:242; 09-10:72 |
| `R-p13-failed-deletion-not-retried` | 09-10 §2.17 "virtual machine holding files open" | 09-10:155–156 |
| `R-p14-spawn-not-refused-without-a-record` | certification-sage-round6 §2 S1–S4 | mine:49–54 |
| `R-p14-land-assumes-main` | brief-audit-sage-round6 §4.6 "19 holds NOT on refs/heads/main" | my audit:229, :239 |

The "09-12 addendum §A2/§A3/§A4" cited by `R-p04-quarantine…`, `R-p07-…`, `R-p10-…`, `R-p11-…` is `docs/verification/lifecycle-failure-record-2026-09-12-addendum.md` in THIS tree (`c13f8f06`), not a section of the richos-hq record; the quarantine it names is still on disk (`git worktree list` shows both `.richos-retired/` entries at `37bb361c` and `a8fc4203`). The S- mutants that name Frank's constructions (F4, F10, F20, F26, F30, RN2b/c) I verified as mutants — each turns its named sub-assertion red and nothing else — without reading what he wrote.

---

## 6 · The runner — what I managed to break, and what held

All in a clone of my worktree under the scratchpad (`attack.sh`, `attack2.sh`, `verify-retirements.sh`; outputs beside them), sandbox store with `dev/workspace-spec` recorded by the lead's own command, `--tree-only`.

**Held:**

| attack | result |
|---|---|
| retirement line uncommitted | `UNRUNNABLE … A1: it is not in any commit reachable from HEAD` |
| retirement line committed on my branch, not landed | `UNRUNNABLE … A3: the commit that wrote it (…) has not landed on dev/workspace-spec` |
| **landing-and-deleting** (my round-6 defeat): the lead merges the reviewer branch onto the recorded branch, deletes the reviewer branch, tree at the recorded branch | `GREEN … retired by sage [a64cd2ec3c3b, landed on dev/workspace-spec @ …]` — **closed**: the witness is the recorded branch's tip, not a branch name |
| a probe deleted TOGETHER WITH its manifest line, one commit (3a) | `probes DELETED from history and not retired: 1`, `MISSING …`, exit 1 — **closed** |
| a probe gutted in place, manifest line KEPT (3c) | `UNRUNNABLE` (no readable cases, output unparseable), `A PRIOR PROBE IS RED. THIS BLOCKS.` — blocks |
| the guard, literal forms in an agent's call: `workspaces.sh integration … --branch wip`, `git branch -f <recorded> HEAD`, `git update-ref refs/heads/<recorded> HEAD`, `git push . HEAD:<recorded>`, `git branch -D <recorded>`, `git worktree add <path> <recorded>` | all `exit=2`, `=== Worktree guard: REFUSED ===` naming point 14 |
| the guard, positive controls: the lead's own recording call and `git branch -f` | `exit=0` |
| the guard, precision: an agent's `git branch -f side/scratch HEAD` on an unrecorded branch | `exit=0` |

**Broken — blocking (the first line of this record):**

| attack | result |
|---|---|
| **3b — a probe GUTTED in place (a three-line non-probe stub at the same path) and its manifest line dropped, one docs-only commit** | `probes DELETED from history and not retired: 0`, `committed probes NOT LISTED in the manifest: 0`, the probe absent from the report, **exit 0** |

`deleted_probes` asks `exists_at(root, "HEAD", rel)` for every entry the manifest ever listed; a stub at the path answers yes. The text backstop does not fire because the stub is not a probe, and the deletion scan does not fire because nothing was deleted. The closure the brief ordered — *"a line removed in the same commit as its probe is still asked for"* — was implemented for the deletion it named and not for the replacement that has the same effect. Minimum fix: an entry listed at any commit and **not listed at HEAD** is MISSING unless retired, regardless of the path's contents. Better: run each listed probe at the recorded integration branch's content (§0).

**Broken — a bound of the engine, reported, not blocking:**

| attack, in an agent's call through the guard | result |
|---|---|
| `W=…/workspaces.sh; $W integration --repo … --branch wip --why …` | `exit=0` |
| `python3 -c '…exec_module…; m.record_integration(repo, "wip", …)'` | `exit=0` |
| `printf '{}' > $RICHOS_WORKSPACES_DIR/integration.json` | `exit=0` |
| `git fetch . HEAD:dev/workspace-spec` / `git fetch . +HEAD:refs/heads/dev/workspace-spec` | `exit=0` |
| `git branch -C cc/sage-fable-c8 dev/workspace-spec` (copy-force over the recorded branch) | `exit=0` |
| `printf 'update refs/heads/dev/workspace-spec HEAD\n' \| git update-ref --stdin` | `exit=0` |
| `git checkout dev/workspace-spec && git merge cc/…`, `git switch dev/workspace-spec`, `git symbolic-ref HEAD refs/heads/dev/workspace-spec` | `exit=0` |
| and then, with `wip` recorded or the recorded branch moved to my tip **outside any hook**, the runner on my unlanded retirement | `GREEN … landed on wip @ a64cd2ec3c3b` / `GREEN … landed on dev/workspace-spec @ a64cd2ec3c3b` |

So A3 is exactly as strong as guard rule 6, and rule 6 is a regular expression over the command text — the same class as the `claude -w` rule the brief asked it to match, and every other guard in this engine. The runner itself trusts the store (`integration_witness` → `integration_for`), which is right by point 14's own words: the record IS the fact. **The residual is that nothing on this machine separates an agent's process from Rich's** — one user, one `~/.claude/state` — so a guard here is a tripwire against an honest command, never a wall against an adversary, and the brief's "the way `claude -w` is refused" is met at that level. Cheap widenings for round 8, in the order an honest agent would stumble into them: `checkout`/`switch` of a recorded branch (that is how a merge into it actually happens), `fetch` with a destination refspec, `branch -C`, `update-ref --stdin`. The runner could also print WHO recorded the witness (the record carries the session id) so a reader sees an agent's session there.

`HISTORY_LIMIT = 400` bounds both the manifest-history scan and the introducing-commit search; the manifest has 1 commit and the retirements file 3 today, so the headroom is not a concern this year, but it is a silent ceiling and should say so when reached.

---

## 7 · The one-token survivor — "report, don't fix" was right for that engineer, and the property is pinned; the fix must land with this round

`workspaces.mutation.sh:188` declares `p14-nothing-bound-falls-back-to-current` with witness `test_point_14_the_integration_branch_is_recorded_never_inferred`. The mutant restores round 6's fallback (`if work is None and chain:` → `if False:`) in `integration_target`. Under it the suite goes red at `test_point_14_a_record_bound_to_nothing_is_refused_never_guessed` (`workspaces.test.py:1303`), which builds the one record that can be bound to nothing — an orphan `cc/` worktree the point-3 sweep finds — records `main` afterwards, merges, and asserts the land STILL refuses with `bound to no body of work` rather than reading the now-current record. **That is the property, that test pins it, and the mutant did make it red.** The harness's rule (`mutation-harness.sh:255`, `grep -q "FAIL  $want"`) then counts the mutant as unproven because the red is not at the declared name. Every agent in the declared test is bound at its spawn, so it can never reach the mutated branch; it is the wrong witness by one token, in the same commit (`eedfbc7d`) that added the right test.

- **Right call for zach-fable-m3:** his brief was report-only, and "do not change the test to make the mutant fail" applies with equal force to changing the mutant to make the count clean.
- **Not right to leave beyond this round:** the orphan-binding property has **no proven mutant anywhere** until the witness is repointed — the fourteen pin the spawn refusal (`R-p14-spawn-not-refused-without-a-record` → C14.1) but have no sub-assertion for a record bound to nothing. One token: `"test_point_14_a_record_bound_to_nothing_is_refused_never_guessed"` at line 188. Rich can make that edit himself at the land (a trivial-file change, and it is a mutant declaration, not a test), or round 8 does.

My own unit-mutant run: see §10 (the row is filled from the run, not from the report).

---

## 8 · `agent-liveness.sh` reads a terminal agent as ALIVE — a defect of neither the spec nor this build; a stale label in the engine

Reproduced read-only (`~/.claude/richos-engine/scripts/agent-liveness.sh`, no argument):

```
ALIVE  ad778ffcd3c8b4ea2   (zach-fable-m2, terminal: its own-id SubagentStop rows exist)
  evidence: … locked=True, pid=24267(alive=True), pid shared with 2 other lock(s) — it is the SESSION pid, not a per-agent pid
ALIVE  aa6d115c8c73723d9   (me)
  why: isolation worktree … is LOCKED and the locking pid 24267 is running
```

The installed module and this branch's copy are byte-identical (`bca660bf…`). Its own header (lines 55–75) states the bound: *"The pid is the HOST SESSION's pid, and it is THE SAME for every agent of that session … A worktree whose agent finished but which has not yet been reaped still reads ALIVE."* So the lock is authoritative for one question — *is the session that took this lock still running* — and the line *"worktree-lock — AUTHORITATIVE. The only source that decides"* over-claims only if read as answering *is this agent alive*, which the module itself says it cannot.

**Ruling.** The CEO's page removes the question: *"No question of whether an agent is still alive. No liveness guessing of any kind."* The spec build reads neither the lock nor the ledger; an agent is FINISHED when its recorded end-of-run signal exists (point 11, C11.6) or its session has ended (point 12). For zach-fable-m2 the registry's answer is *finished* and the lock's is *the session is up* — both true, and only the first is the spec's question. So: not a spec defect (the spec deliberately has no liveness); not a defect of this round (it touched none of it); a consumer in the engine — `agent-liveness.sh`, `guard-agent-state-claims.py`, and femcboost's CLAUDE.md rule *"Liveness = the worktree lock"* — still answering a question the page retired, under a label that reads stronger than its own header. Round 8 or after: the claim guard reads `finished_state` from the workspace registry for "finished", and the lock's verdict is renamed to what it proves (`SESSION-ALIVE`). Not blocking; it never was part of this build.

---

## 9 · Carried forward, not this round's

- **The pin.** `docs/verification/workspace-spec-implementation-2026-09-11.md:3` still pins the mirror at `b3fd6cd33b8c1135`; the mirror and the canonical page both hash `957d21a4…` today (`adf26205` re-synced the mirror, not the pin). Untouched by round 7, as required; still wrong; docs-only, one line, whoever owns that record.
- **The kill-path question** (a killed agent gives no signal; waits for session end) and **point 5's sentence pair** are the CEO's, and the round correctly encodes nothing for either.
- **C13's fixture contamination** and **the 93% pause instance** (§3, §4): small, round 8.

---

## 10 · What I ran, with exit codes

Every run from `/Users/alex/ab/richos-wt/sage-fable-c8` at `44a7d5d4` (the certification commits `ef194726`, `1dc4fc9f` change nothing under `engine/`), with `CLAUDE_CONFIG_DIR`, `RICHOS_WORKSPACES_DIR`, `RICHOS_SESSIONS_DIR` exported into the scratchpad on top of each harness's own sandbox. Wrappers and outputs: `/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/c8/`.

| what | command | its own verdict lines | exit |
|---|---|---|---|
| the fourteen, no mutants | `RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh` | `CHECKS RUN: 15  RED: 0` · `FOURTEEN: 14 green, 0 red · self-check: green` · 113 ok, 0 FAIL | 0 |
| the fourteen, 59 mutants | `bash engine/scripts/workspace-spec-fourteen.test.sh` | `=== mutation: all 59 properties proven load-bearing ===` · 21 R + 38 S PASS · `FOURTEEN: 14 green, 0 red · self-check: green` | 0 |
| round-7 harness on round-6 code | `run-on-base.sh` (sandbox copy of this engine; `workspaces.py` and `guard-worktree-removal.sh` from `fa65987e`, sha256 `2a2b86d9…`/`03109245…` verified) | `CHECKS RUN: 15  RED: 4` · `FOURTEEN: 10 green, 4 red · self-check: green` · FAIL C14.1/9/11, C2.8, C8.5/6/7, C13.2/4 | 1 |
| unit mutation harness | `bash engine/scripts/lib/workspaces.test.sh` | `[45 mutant(s), 8 at a time, wall 8m45.2s …]` · `=== mutation: 1 property(ies) NOT proven load-bearing, 44 proven ===` · `FAIL p14-nothing-bound-falls-back-to-current — the suite went red, but NOT at "test_point_14_the_integration_branch_is_recorded_never_inferred"` · `FAIL test_point_14_a_record_bound_to_nothing_is_refused_never_guessed` — the engineer's line, reproduced | 1 |
| my runner-round probe, all cases | `python3 -B docs/verification/certification-sage-runner-round-2026-09-12.probe.py <lib>` | `held: 9/10; NOT HELD: R4 record-heals` (`SpecError … the spawn of zach-opus-r4 is refused`) | 1 |
| the same, R4 excluded | `… <lib> R1 R2 R3 R5 R6 R7 R8 R9 R10` | `held: 9/9` | 0 |
| my window-and-target probe, all cases | `python3 -B docs/verification/certification-sage-window-and-target-2026-09-12.probe.py <lib>` | `held: 6/8; NOT HELD: escalation-stray, escalation-stray-cc` | 1 |
| runner, my branch, retirements committed, unlanded | `workspace-probes.py --tree-only --only certification-sage-runner-round --only certification-sage-window-and-target` | both `UNRUNNABLE … A3: … (1dc4fc9fdf12) has not landed on dev/workspace-spec` | 1 |
| runner, clone, after the lead's merge onto `dev/workspace-spec` | same, tree at `dev/workspace-spec` @ `1dc4fc9f` | `GREEN … ran 9 of 10` · `GREEN … ran 6 of 8` · `every discovered probe ran, and every one of them is green.` | 0 |
| runner, clone, FULL manifest after that merge | `workspace-probes.py --tree-only` | RED ×3 (Frank's), RETIRED ×2, GREEN ×6, DECLARED ×1 | 1 |
| runner attacks 3a/3b/3c, W1–W6, guard rule 6 | `attack.sh`, `attack2.sh` | §6 | as listed |
| `cases_of` on my two probes | python, importing the runner | `[]` before `ef194726`; `['R1', …, 'R10']` after; window-and-target 8 cases | 0 |
| liveness sweep, read-only | `~/.claude/richos-engine/scripts/agent-liveness.sh` | §8 | — |
| in-flight ack | `inflight-ack.sh --sha 44a7d5d4… --impact none` | row written | 0 |

**Not run:** the e2e suite, the removal-guard suite and its mutants, the probe-runner's own suite — the engineer's logs for each are committed and my findings did not turn on them; the full engine sweep (expected, per the brief).

## 11 · Census

Method: `find <dir> -type f | LC_ALL=C sort | while read f; do shasum -a 256 "$f"; done | shasum -a 256` (per-file digests over the sorted list, then one digest over that list) — the engineer's method, so the two records compare.

| | files | before my first command (22:18:18Z) | after my last (22:53:14Z) |
|---|---|---|---|
| `~/.claude/state/workspaces` | 4 | `8ce85db91270cb1234f325aad8ee9780c948b82fdcbc784c9a1c65099d0daf47` | `8ce85db91270cb1234f325aad8ee9780c948b82fdcbc784c9a1c65099d0daf47` |
| `~/.claude/state/workspace-retirement` | 11,286 | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` |

The before digests are the engineer's before-and-after digests exactly (his §1), so the operator's ledgers were unchanged across his round and mine.

## 12 · Commits on `cc/sage-fable-c8`, oldest first

1. `ef194726` — my runner-round probe carries the literal `CASES` list the runner reads (docs-only, my own file).
2. `1dc4fc9f` — the three per-case retirements, signed `sage` (docs-only).
3. this record.

Nothing under `engine/` is touched by any of them; `git diff --stat 44a7d5d4..HEAD -- engine` is empty.
