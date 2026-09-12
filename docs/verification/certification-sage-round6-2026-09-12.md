CERTIFIED

# Certification — round 6 measurement, `cc/zach-fable-m1` @ `00c2a075`

**Certifier:** sage-fable-c7 · worktree `/Users/alex/ab/richos-wt/sage-fable-c7` · branch `cc/sage-fable-c7`, cut at `00c2a075c9b351d71934bc680280bf07cd718f67` (five commits over `dev/workspace-spec` @ `c5bce604`).
**The spec:** richos-hq `docs/plans/worktree-spec-2026-09-11.md` @ `c663a823`, read there. **The brief:** the round-6 brief, `round6-brief-fourteen-points-2026-09-12.md` @ `75316840`, in the private richos-hq record (its plans directory; not in this repository).
**Not read:** Frank's work (`certification-frank-*`, `brief-audit-frank-*`). Where a mutant cites Frank as a co-citation, the ruling below rests on the other citation alone.
**Constraints kept:** nothing merged, pushed or installed; nothing written into `/Users/alex/ab/richos/engine`, `/Users/alex/ab/richos`, or `/Users/alex/ab/richos-hq`; every run sandboxed (`HOME`/`CLAUDE_CONFIG_DIR` redirected, or `RICHOS_WORKSPACES_DIR` pointed at a `mktemp` store); the operator's stores read only (§7).

**What this certifies:** the round MEASURED honestly. The headline reproduces; the harness implements the frozen text; the mutation floor is met; the runner's three scoped changes hold against both routes I found last round. **Round 7's scope, from this certification: C14.1 (the check is right, §2), plus one open route into the runner's new witness (§5, A3) that the brief did not name and I did.**

## 1. The headline, as I reproduced it

```
$ bash engine/scripts/workspace-probes.test.sh                      # sandboxed inside; on cc/sage-fable-c7 = 00c2a075
=== workspace-probes tests: all 40 passed ===   === mutation: all 16 properties proven load-bearing ===   exit 0

$ bash engine/scripts/workspace-spec-fourteen.test.sh                # 19:41Z–19:57Z, with the mutation harness
  FAIL  C14  ... (1 sub-assertion(s) red)          <- C14.1 only:  "spawn rc=0 stderr="
  PASS  C1 C2 C3 C6 C4 C7 C8 C9 C10 C11 C5 C13 C12 C0
  [37 mutant(s), 8 at a time, wall 10m07.8s]
=== mutation: all 37 properties proven load-bearing ===
CHECKS RUN: 15  RED: 1
MUTATION HARNESS: exit 0 (every property proven load-bearing)
exit 1                                                                 (by design while C14.1 is red)
sub-assertions: 86 ok, 1 FAIL (C14.1); mutants PASS 37 FAIL 0 — R- 16, S- 21

$ python3 -B -W ignore engine/scripts/lib/workspaces.test.py          -> Ran 58 tests in 51.001s  OK   exit 0
$ bash engine/scripts/workspaces-e2e.test.sh                          -> workspaces-e2e: 47 passed, 0 failed   exit 0
```

Rich's pre-spawn numbers (14 PASS, 1 FAIL at C14.1; `events.jsonl` `4dfa7993…`, `repos.json` `d7d7ae5d…`) reproduce exactly. The engineer's own log (`round6-measurement-2026-09-12-logs/fourteen-checks-and-mutants.txt`) says the same.

## 2. C14.1 — the ruling that scopes round 7

**The frozen check is right. The base's choice is not defensible under the sentence.**

The CEO's sentence, point 14: *"The branch a body of work integrates on is RECORDED when that work starts, before its first agent is spawned. Nothing infers it and nothing guesses it — without that record there is no fact to test a land against, and 'landed' goes back to meaning whatever main happens to have."*

The base (`engine/scripts/lib/workspaces.py`): `register_spawn` (977) → `_add_workspace` (828) → `_bind_body_of_work` (843), which at 854 does `return  # nothing recorded yet: bound to nothing, heals later`; and `integration_target` at 2292–2293 does `if work is None: work = integration_record(repo)` — a nothing-bound agent is measured against whatever body of work is CURRENT at land time. The base's own unit test enshrines this reading: `workspaces.test.py:1220 test_point_14_the_integration_branch_is_recorded_never_inferred` unlinks `integration.json`, spawns, and asserts the spawn proceeds and only the LAND refuses ("THE REFUSAL HEALS").

Two reasons the check, not the base, reads the sentence correctly:

1. **"Before its first agent is spawned" is an ordering, and only a refusal at the spawn makes it a guarantee.** A land-time refusal enforces "before its land" — a different sentence. Point 5 says of its own guarantee *"it holds whether or not Rich remembers"*; a record that Rich's habit supplies and the land catches is exactly a habit. Point 3 already gives the shape: *"If registration fails, the spawn does not happen."* The record is part of what a spawn needs.

2. **"Heals later" is a guess about WHICH body of work the agent belongs to — reproduced.** The base's own design binds agents to a work ID precisely so that *"a DIFFERENT body of work never [reaches an agent in flight]"* (`workspaces.py:2270–2280`). A nothing-bound agent defeats that: it is bound at land time to whatever was recorded LAST. Through the real hooks, in the harness's sandbox (`sage-c7/c14-scenario.out`, script = the harness preamble + my scenario):

```
S1 spawn zach-opus-g0 with NO record            -> rc=0, stderr empty; record integration_work=[]  (bound to nothing)
S2 record dev/first  (body ONE, entity-001)     -> rc=0            both recorded AFTER the spawn
   record dev/second (body TWO, entity-002)     -> rc=0
S3 g0's work fast-forwarded onto dev/first only; workspaces.sh land zach-opus-g0
   -> rc=2  "REFUSED — ... is not in dev/second ... Merge it onto the branch this work integrates on"
S4 the same tip also placed on dev/second; land  -> rc=0  "landed"; done/ kind=landed; workspace gone
```

The agent's land answer changed with a record made after its spawn, for a body of work it was never part of. That is "nothing guesses it" violated, and it is the mechanism behind C14.1, not a cosmetic difference in where the refusal sits.

**Round 7's scope for point 14, in the CEO's words:** *"RECORDED when that work starts, before its first agent is spawned"* — `register_spawn` refuses (exit 2) when the repository the agent will work in (the entity, and the repository named on `cross-repo-worktree:`) has no current body of work, and the refusal names `workspaces.sh integration --repo <repo> --branch <main|dev/...> --why '<this body of work>'` — which is what C14.1 already asserts. With that in place the land-time fallback at 2292–2293 has no honest caller: a nothing-bound chain can then only be a pre-existing registration, and for it the land should refuse naming the command, never read "current". `test_point_14_the_integration_branch_is_recorded_never_inferred` must be rewritten in its first half (spawn refused, not land); its second half — a `--correct` reaching an agent in flight through the work ID — is right and stays. C14.1 gets its mutant then.

## 3. Does the harness implement the FROZEN text, or something easier?

I diffed every sub-assertion of `engine/scripts/workspace-spec-fourteen.test.sh` against brief §4. **It implements the frozen text.** Each check's clauses map to named sub-assertions driven through the registered hooks (`guard-worktree-isolation.sh`, `guard-worktree-removal.sh`, `guard-sealed-worktree.sh`, `workspace-lifecycle.sh`, `guard-workspace-gate.sh`) with the platform's payload shapes; every positive control is present where a refusal is asserted (C1.4, C9.2, C10.1, C12.3). None of the fourteen was removed or reworded. The softenings I found, stated so round 7 does not inherit them as green:

| check | frozen clause | what the harness asks | verdict |
|---|---|---|---|
| C14 | "on `main` also `reconcile-terminal-worktrees.py` and `workspace-retire.py`" | not asked: not on the base (deleted at `ca4ba9f8`); said so in the report | honest omission; **must be asked when `main` is measured** |
| C5 | "the two allowances his sentence names" — allowance 1 is *answering the CEO OR obeying his stop order* | only "answering the CEO" is exercised (C5.2); the stop-order half is not | minor gap, name it in round 7's C5 |
| C3 | "a registration failure" | one failure mode: unreadable session identity (`RICHOS_SESSION_PID=999999`) | acceptable; it is a real failure, not a mock |
| C4.1 | "no prompt" | `! grep -q 'land' stop.err` — a weak predicate; the real evidence is exit 0 with the work gone (C4.2–C4.5) | acceptable |
| C12 | "the next session lands or discards … before any spawn" | the next session is TOLD first and every spawn is refused until Rich's `land` runs (C12.4–C12.6) | matches point 5's enforcement shape |
| C14.7 | "none asks `main`" | a text grep that `INTEGRATION_REFS` has zero code uses | a check on the text, backed by C14.5/C14.6 on behavior |

The mutation harness names sub-assertions, never checks, and `lib/mutation-harness.sh` refuses a mutant three ways (did not apply / suite still green / red elsewhere), so no mutant passed vacuously — my run confirms 37/37 with that harness.

## 4. C0 and the mutation floor

**C0 (added) is legitimate and should not sit in the CEO-facing denominator.** It is the e2e suite's own E5.1–E5.4 hygiene block plus two store assertions: it proves the harness's sandbox ends clean, which is evidence the other fourteen were not measured on a half-broken fixture. It tests no sentence of the page. The brief permits adding a check, and a green addition cannot hide a red; but "CHECKS RUN: 15" counts a harness self-check among the CEO's fourteen. Recommendation, not a blocker: print `FOURTEEN: 13 green, 1 red · harness self-check: green`, and keep C0.

**The mutation floor is met.** 16 RECORDED, 21 SPEC-DERIVED, one per point at least, printed per point, and points 1 and 2 declare their record thin instead of passing quietly. I spot-checked EVERY RECORDED citation against the cited file and section, by line:

| mutant | citation | found at |
|---|---|---|
| R-p03-registration-without-identity | 09-10 §3.4 "ownership row with no agent id"; sage audit §4.2 `"agent_id": ""` | 09-10:204 (§3.4 = 194–209); audit `dd713206`:183 |
| R-p03-unregistered-never-listed | 09-10 §3.1 "Nothing made removing a finished one happen"; §2.11 | 09-10:173 (§3.1); §2.11 heading 106 |
| R-p04-branch-left-after-land | 09-12 §2c `git branch --contains 6fd5aef8`; addendum §A2 | 09-12:69 (§2c = 64–83); addendum A2 |
| R-p04-quarantine-instead-of-delete | addendum §A4; sage audit §4.4; (frank P7 not read) | audit:269–278 quarantines at 16:12Z/16:13Z |
| R-p05-turn-end-not-blocked | 09-10 §3.1 de-duplicated notice; §2.11 | 09-10:167–170 |
| R-p05-new-work-not-blocked | 09-12 §5 Type D "four more finished agents' worktrees" | 09-12:115 |
| R-p06-native-workspace-not-registered | 09-10 §3.4 "sealed manifest is taken at spawn" | 09-10:201 |
| R-p07-discard-records-no-reason | addendum §A2; 09-10 §2.2 "destroyed running work on an inference" | 09-10:52 |
| R-p08-ignored-needed-files-landed | 09-10 §3b.2 "ignored nested repository … deleted with no copy"; `inflight-ack.sh` header 2026-09-05 | 09-10:265; header read |
| R-p09-finished-agent-not-locked-out | 09-10 §3b.1 "Thirteen agents … restarted"; 09-11 §2 S4 | 09-10:251; 09-11:75 |
| R-p09-processes-not-stopped | femcboost CLAUDE.md "Corollary (zombie residue, 2026-07-18)"; (frank P11 not read) | CLAUDE.md, Git Worktree Isolation |
| R-p10-cc-workspace-left-behind | addendum §A4; 09-10 §3.4 "Zero of 15,882 finish rows" | 09-10:199 |
| R-p11-sub-run-end-finishes-the-teammate | 09-10 §3.5 "per-run identifier, not the owning agent … derives the owner from the folder path"; addendum §A3 | 09-10:213–215 |
| R-p12-ended-session-agents-not-finished | sage audit §4.3 26 holds, sessions b7869424/d0eef867; 09-10 §2.5 pgrep | audit:242; 09-10:72 |
| R-p13-failed-deletion-not-retried | 09-10 §2.17 "virtual machine holding files open"; (frank P5 not read) | 09-10:155 |
| R-p14-land-assumes-main | 09-12 §2c; sage audit §4.6 19 holds "NOT on refs/heads/main" | 09-12:69; audit:229, 239, 419 |

Points 1 and 2 "no mechanical incident": confirmed — `grep -i codex` over the three records finds only Rich's over-wide briefs (09-11 G2/G3/G6) and "five `codex/`, untouched" (09-12:141); the four `zach-opus-dor*` trees are pre-spec and excluded by the CEO's own second sentence of point 1 (my audit §4.1). The addendum's A1 re-derived from the live `events.jsonl`: 7 rows, 4 `integration-recorded`, all for `…/T/land-completeness.*/…` repositories.

The 105 existing cases: the per-class counts (2,1,7,1,9,2,5,2+1,4,4,5,4,1,10 = 58) match `workspaces.test.py` class by class, and every E-case the table names asserts what the row says (E0.1–E6.7 read in `workspaces-e2e.test.sh`). One labeling note: four methods inside `Point14_IntegrationBranch` are named `test_point_03_*`/`test_point_08_*`; the table counts by class, which is what it says it does. The mapping is honest.

## 5. The runner — what I tried to break

Both of last round's routes are CLOSED, and the engineer's two claims about this machine hold. Fixture in the suite's own shape (`sage-c7/runner-attacks.sh`, sandbox store, output `runner-attacks.out`), plus the real tree:

```
A1  engineer retires bob on cc/engineer, then `git branch wip HEAD`         -> rc=1, "A3: ... has not landed on main"   CLOSED
A2  bob's own line landed on main by Rich, author's branch deleted          -> RETIRED bob, "landed on main @ ..."      CLOSED
A4  probe deleted AND its manifest line dropped in one commit               -> MISSING                                  CLOSED
A5  probe `git mv`-ed out of docs/verification/ and delisted                -> MISSING (DELETED at HEAD)                CLOSED
A6  manifest emptied, every probe file deleted, manifest still committed    -> 2 MISSING + 2 UNLISTED, rc=1             CLOSED
real tree, empty sandbox store    -> "integration branch: NOT RECORDED", both sage retirements UNRUNNABLE, command named
real tree, dev/workspace-spec recorded in a sandbox store -> 11 probes: 8 GREEN, 2 RETIRED (sage), 1 RED (frank -recorded-, expected), 1 DECLARED; exit 1
```

**A3 — OPEN, and not one the brief named: the party under test can write the witness.** The witness is now `integration_for(<repo>)`; nothing checks WHO recorded it. No hook refuses `workspaces.sh integration` from an agent (`grep -l integration engine/scripts/hooks/*` names no refusal in `guard-worktree-removal.sh`, `guard-sealed-worktree.sh` or `workspace-lifecycle.sh`), and `record_integration` accepts any existing branch that is not `cc/` or `worktree-agent-`:

```
engineer commits carol's retirement on cc/engineer; `git branch wip HEAD`
python3 engine/scripts/lib/workspaces.py integration --repo $R --branch wip --why "a new body of work, says the engineer"   -> rc=0
runner: integration branch: wip @ 6b44470c0f34 ... RETIRED certification-carol-probe.probe.py                                  <- accepted
same with `--correct` on the current body of work                                                                             -> RETIRED again
```

The CEO's sentence: *"RECORDED when that work starts … Nothing infers it and nothing guesses it"*; the brief §7: *"Only Rich writes that branch."* The record has no writer check, so the runner's witness is exactly as strong as the store's write access, which every agent's Bash has — and `--correct` by an agent moves every in-flight agent's land target in that repository, a wider effect than the runner. Round 7 item (the runner's scope, brief §7): the Bash guard refuses `workspaces.sh integration` / `workspaces.py integration` in an agent's call the way it refuses `claude -w` (C3.2), and the runner's suite gets the case. A direct write to the store's `integration.json` is the same trust boundary as any store file and is not closable by the runner.

Left as the engineer stated it: A2 is still not asked of a later-added `not-a-probe:` marker; under the new A3 that route needs Rich to land the commit.

## 6. Defects, each with the sentence and a reproduction

1. **C14.1 (red, expected; ruled in §2):** *"RECORDED … before its first agent is spawned. Nothing infers it and nothing guesses it."* Reproduction: `fourteen-repro.txt` line 2 (`spawn rc=0 stderr=`), and `c14-scenario.out` S1–S4 above for the guess.
2. **Runner A3 (open, new):** *"Nothing infers it and nothing guesses it"* + brief §7 *"Only Rich writes that branch."* Reproduction: `runner-attacks.out` §A3, commands above.
3. **Observed, not a check (the engineer's C1.5, confirmed):** a `cc/` workspace registered by `create-teammate-worktree.sh` and never spawned into is not finished (point 11), so point 5 never lists it until its session ends (point 12) or Rich stops it. The page answers it at session end; noted for the page's author, not round 7.

## 7. Census — before my first command, after my last

Method: `sage-c7/census.sh` — sha256 of every file under both stores, sorted, then the sha256 of that listing. The engineer's `census.sh` hashes the same two trees (plus the ledger, which the brief's constraint to me does not name and which the running engine appends to through nobody's action — his §A5).

```
BEFORE  2026-09-12T19:39:52Z  listing sha256 a19e1a5baab7f3bf9ddd9661e9d7a434d0e08294192ee3dd3f16f163fd59ab90  (11,292 files)
        workspaces/events.jsonl 4dfa7993994ddf3db700924b70d49af4da765d7f58cd7812cffd6a3410a50bb3
        workspaces/repos.json   d7d7ae5d5a3ddce7717ab0058179e31a4c15c00bc4d961e589736c9af8490356
        workspace-retirement/retirements.jsonl 0efc0afb47cca4e6d6a2ca5b39253b8d52b4e002a3b9b4a95bde0f1bbaa56c92
AFTER   2026-09-12T19:55:46Z  listing sha256 a19e1a5baab7f3bf9ddd9661e9d7a434d0e08294192ee3dd3f16f163fd59ab90  (11,292 files)
        workspaces/events.jsonl 4dfa7993994ddf3db700924b70d49af4da765d7f58cd7812cffd6a3410a50bb3
        workspaces/repos.json   d7d7ae5d5a3ddce7717ab0058179e31a4c15c00bc4d961e589736c9af8490356
        workspace-retirement/retirements.jsonl 0efc0afb47cca4e6d6a2ca5b39253b8d52b4e002a3b9b4a95bde0f1bbaa56c92
$ diff census-before.txt census-after.txt | grep -c '^[<>]'   -> 0
IDENTICAL: both stores byte-identical across every command of this certification (the only commands after
the after-census are the write of this file and its git add/commit inside this worktree).
```

## 8. What I ran, with exit codes

| command | exit |
|---|---|
| `~/.claude/richos-engine/scripts/inflight-ack.sh --sha 00c2a075… --impact none` | 0 |
| `census.sh` (before) | 0 |
| `bash engine/scripts/workspace-spec-fourteen.test.sh` (with mutants; 15 checks, 37 mutants) | 1 (C14.1 red, by design) |
| `bash c14-full.sh` (harness preamble + two-bodies-of-work scenario) | 0 (S1 spawn 0, S3 land 2, S4 land 0) |
| `bash runner-attacks.sh` (A0–A6) | 0 (verdicts inline) |
| `bash runner-real.sh` (real tree; empty store, then dev/workspace-spec recorded, sandbox stores) | 0 ((a) rc 1 NOT RECORDED; (b) rc 1, Frank's `-recorded-` red) |
| `bash engine/scripts/workspace-probes.test.sh` (40 cases + 16 mutants) | 0 |
| `python3 -B -W ignore engine/scripts/lib/workspaces.test.py` (58) | 0 |
| `bash engine/scripts/workspaces-e2e.test.sh` (47) | 0 |
| `census.sh` (after) | 0 |

Scratch outputs (session scratchpad, not committed): `sage-c7/{fourteen-repro.txt,c14-scenario.out,runner-attacks.out,runner-real.out,runner-suite.out,unit.out,e2e.out,census-before.txt,census-after.txt}`.

## 9. Not done, deliberately

No merge, push, `install.sh`, or write outside this worktree. Frank's probes were executed by the runner (they are in the manifest) but not read. The full engine sweep and `contract-integrity.test.sh` not run (a land does). `scripts/lint-banned.sh` and `scripts/preflight.sh` are femcboost's and do not exist in this repository. No fix to anything red: C14.1 stands, `workspaces.py` line 4 still says "thirteen", Frank's `-recorded-` probe is its author's.
