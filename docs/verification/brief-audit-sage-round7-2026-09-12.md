BRIEF NOT READY

# Brief audit — round 7, `round7-brief-2026-09-12.md` @ `c99c62d6` (richos-hq, private record)

**Auditor:** sage-fable-b2 · worktree `/Users/alex/ab/richos-wt/sage-fable-b2` · branch `cc/sage-fable-b2`, cut at `316d44bcb7c47a68e2d79b038eceef9c99374e9c` (the brief's base).
**The spec:** richos-hq `docs/plans/worktree-spec-2026-09-11.md` @ `c663a823`, read there. The mirror in this repository was not read as the spec and was not touched.
**Not read:** Frank's work (`certification-frank-*`, `brief-audit-frank-*`). Where the brief attributes an item to Frank, I re-derived the item from the code and the machine, never from his file. The transcription check below is therefore one-sided: I can say whether MY findings survived; I cannot say whether his did.
**Constraints kept:** nothing merged, pushed or installed; nothing written into `/Users/alex/ab/richos/engine`, `/Users/alex/ab/richos`, or `/Users/alex/ab/richos-hq`; every probe sandboxed (`mktemp` repositories, `RICHOS_WORKSPACES_DIR` pointed at a scratch store); the operator's stores read only (§9). No `codex/` anything.

**Why NOT READY, in one paragraph.** The brief's base does not contain the certification it says it transcribes (§1). Its largest section — the one it marks FOR THE CEO — measured a legacy advisory ledger that the spec build never reads, attributes today's 00:39 kill to that ledger when Rich's own failure record attributes it to a mid-session install, and its "Do" would rewire the spec build to a different event stream and encode a "take the last" rule that contradicts point 9 (§5). Item 4's "seven" is at least nine, one of the seven is transcribed the wrong way round against the page, and one clause of the page is not a mutation at all but an unimplemented sentence — a third red (§3, §4). The brief cites the worktree lock and `agent-liveness.sh` as corroboration, which the page's closing paragraph forbids (§7). The items that are right — 1, 2, 3, 5, 6, 7 — are right, and §10 carries the text that keeps them and fixes the rest.

## 1. Is the transcription faithful? Partly — and the base premise is false

**The base does not contain my certification.** The brief: *"Base: `cc/frank-fable-c7` @ `316d44bc` (which contains `cc/sage-fable-c7` and `cc/zach-fable-m1`)."*

```
$ git log --all --oneline -- 'docs/verification/certification-sage-round6*'
61b0de69 Certification, round 6: CERTIFIED — ...
$ git branch -a --contains 61b0de69
+ cc/sage-fable-c7
$ git merge-base --is-ancestor cc/sage-fable-c7 HEAD ; echo $?      -> 1   (NOT an ancestor)
$ git merge-base --is-ancestor cc/zach-fable-m1 HEAD ; echo $?      -> 0
$ git log --oneline -3 HEAD            316d44bc (Frank) -> 00c2a075 (zach) -> c13f8f06
$ git log --oneline -3 cc/sage-fable-c7 61b0de69 (Sage) -> e8c3aa5c -> 00c2a075
```

`316d44bc` is Frank's one commit on top of zach's tip; my branch is a sibling forked from the same `00c2a075`. An engineer who checks out the stated base will not find `certification-sage-round6-2026-09-12.md` at all. Fix: land BOTH review branches on `dev/workspace-spec` first (they touch different files except `.richos/publication-completeness`, which both edited — item 7 already deletes that line) and base round 7 on the result.

**My two findings, checked line by line against the brief:**

| my round-6 finding | brief item | faithful? |
|---|---|---|
| §2 C14.1: the check is right, "heals later" is inference; refuse at `register_spawn`, name the command; 2292–2293 has no honest caller; test 1220 first half rewritten, `--correct` half stays | item 1 | **Yes**, with one drop: my scope named BOTH repositories a cross-repo agent works in (the entity and the one on `cross-repo-worktree:`); the brief says "the repository". A cross-repo spawn must refuse when EITHER has no current body of work. |
| §5 A3: nothing checks WHO records the integration branch; refuse `workspaces.sh integration` in an agent's Bash the way `claude -w` is refused; a direct write to the store's `integration.json` is the store's trust boundary and is not closable by the runner | item 3 | **Yes** on the defeat and the fix. **Softened by omission:** the boundary sentence is gone, so round 7 can report item 3 CLOSED while a direct `integration.json` write remains open. Say it. |
| §3 table: C5 asks only "answering the CEO"; the stop-order half of allowance 1 is not exercised | — | **Dropped.** It belongs in item 4 (see §3). |
| §3 table: C14 must also ask `reconcile-terminal-worktrees.py` and `workspace-retire.py` when `main` is measured | — | **Dropped.** It is not a round-7 code item, but it is the reason a round 8 exists (§8). |
| §4: print the CEO-facing number and the self-check separately | item 7 | Yes. |
| §6.3: a `cc/` workspace registered and never spawned into is not finished until its session ends; noted for the page's author | — | Dropped. Fine — it is a page observation, not a round-7 item — but it sits oddly beside a brief that tells the CEO point 11 "needs no change" without having listed the one point-11 observation a reviewer actually made. |

**Items I did not author, re-derived here rather than read:** item 2 (§2), item 5 (`quarantine_dirs()` at harness line 165 is `find -iname '*retired*' -o -iname '*quarantin*'` — two names; verified), item 6 (§2), item 4 (§3).

## 2. `RED: 2` — right as a claim about the sentences, wrong as a claim about the harness; and it is at least 3

**The harness as it stands prints `RED: 1`.** Nothing in the base makes it print 2. `RED: 2` is a statement that the CEO's point 8 is violated by the code, which the frozen check C8 does not ask. The brief should say that, because an engineer who runs the suite on the base and sees `RED: 1` will conclude the brief is wrong.

**Point 8's hole is real; I reproduced it without Frank's probe** (`p8/probe.py`, scratch, against `engine/scripts/lib/workspaces.py` on the base): a main checkout with `.claude/` and `vendor/` present by name; a `cc/` workspace whose `.claude/notes/needed.txt` and `vendor/lib` (a nested repository with one unlanded commit) exist only there; `.env` as the file control.

```
git status --ignored in the workspace:      !! .claude/   !! .env   !! vendor/
uncommitted() ->  dirty=[]  ignored=['.env']
VERDICT: HOLE — not reported, would be deleted: ['.claude/notes/needed.txt', 'vendor/lib (nested repo, 1 unlanded commit)']
```

The cited lines are exact: `workspaces.py:1577–1578` is `if other and os.path.isdir(mine) and os.path.isdir(other): continue`. One correction to the brief's prose: *"every `cc/` workspace on this machine carries `.claude/`"* — `ls -d /Users/alex/ab/richos-wt/*/.claude` → 7 of 12; all three main checkouts do. "The ordinary case" is true; "every" is not.

**Item 6 is also real, and its exact shape matters for the fix.** `deleted_probes()` (`workspace-probes.py:598–629`) has two routes: git history filtered by `is_workspaces_probe(text)` at `commit^`, and the manifest AT HEAD. A LISTED probe whose text the recognizer cannot see (the reason listing exists — W15) that is deleted together with its manifest line escapes both. My fixture (`i6/run.sh`, runner and library copied into a `mktemp` repository, `--list`):

```
HOLE:    delete file AND its manifest line in one commit   -> rc=0   probes DELETED from history and not retired: 0
CONTROL: delete the file only, line kept                    -> rc=1   MISSING docs/verification/certification-erin-invisible.probe.py
```

This does not contradict my certified A4 (which was text-visible; my certification said "MISSING for a text-visible probe" in so many words). The fix is one route, not a redesign: the history walk must also read the manifest at `commit^` — a path listed there, absent at HEAD, not retired → MISSING.

**The third red, hiding the way point 8 hid — a clause no check asks and no code implements.** Point 7: *"Unfinished work can also be finished: a new agent continues from its branch, the old workspaces are deleted when the new agent starts, and its work counts as landed when the new agent's does."*

```
$ grep -n -i -E 'continu(e|es|ation) from|def continue_|--continue|new agent continues|takes over' engine/scripts/lib/workspaces.py   -> (nothing)
$ grep -n -i continu engine/scripts/workspace-spec-fourteen.test.sh                                                                    -> (nothing)
```

Frozen predicate 7 (round-6 brief §4) never asked it, the 86 sub-assertions never ask it, and the library has no path for it: a spawn cannot name the agent it continues, so the old workspaces are not deleted at the new spawn and the old work's disposition is never linked to the new agent's land. This is not a mutation that leaves the count unchanged (item 4's class); it is a sentence with no implementation. **Corrected count, as a claim about the sentences: 11 green, 3 red (C14.1, C8-directory, C7-continuation).** The harness prints `RED: 1` until C8 and C7 gain the sub-assertions.

**A fourth candidate I rule a page-level limit, not a red — but it is for the CEO, which the brief's "for the CEO" section is not.** Point 9: *"every process it started is stopped."* `processes_in()` (`workspaces.py:2660–2672`) finds processes whose cwd is inside a workspace or whose args name it. Every child an agent starts has the host `claude` as its parent — shared by every agent in the session — so "it started" is not attributable from the OS; cwd and args are the only evidence. A child that changes directory away and does not name the path survives the land by construction. Frozen predicate 9 already asked the adjacent question ("a process started inside the workspace"). Round 7 should declare this in the measurement, in one line, so the CEO knows his sentence is enforced as "every process running in or naming its workspaces" and can say whether that is enough. Not a code item.

## 3. Item 4's "seven" — the real number is at least nine, one is transcribed backwards, and the framing is a reworded freeze

I mapped every clause of the fourteen sentences against the 86 sub-assertions (`grep -n '^sub "'`, labels in scratch) and against the library.

**The seven, checked:**

| # | brief | my check |
|---|---|---|
| F1 | discard without a reason (7) | Real. `workspaces.py:3078` `x.add_argument("--why", default="its work is no longer wanted")` — a discard with no reason records a default string; C7.2 always supplies one. |
| F2 | CEO-order attestation dropped (7) | Plausible from C7.4/C7.5's shape (they assert refusal with the attestation present, never that the attestation is required at spawn). Not run. |
| F3 | a session claiming a live session's agents (12) | Real. `_claimable()` at 1427–1445 implements it; no C12 sub-assertion asks it. |
| F4 | created branches ignored (3, 10) | Real. `snapshot_refs()` exists (2747, "any branch an agent created"); C10.3 asks only the two registered branches. |
| F5 | the library's `codex/` guard removed (2) | Plausible; C2.2 asks the Bash guard. Note the failure record §8.3: *"`codex/` is closed as a topic. The existing handling stays exactly as it is."* A sub-assertion changes no handling; say so in the brief so nobody reads item 4.5 as reopening it. |
| F6 | handed-in-then-ended (11) | Real. `finished_state()` at 894 has `handed_in`; `record_handed_in` runs on `TaskCompleted` (2965); no C11 sub-assertion asks it. |
| F7 | "a CEO-wait item blocking new work" (5) | **Transcribed the wrong way round, or ambiguous past use.** See below. |

**F7 against the page.** Point 5 says of a CEO-word discard: *"that one item then waits on him, is on his TODO list, and blocks nothing else"* — and three sentences later: *"Rich may end his turn when every pending item is either waiting on something he has already started … or waiting on something outside his reach (the CEO's word, a service that is down) … New work stays blocked either way."* The coherent reading of the three sentences together (the "Enforced" sentence blocks new work AND the turn end; the relaxation frees the turn end when everything waits; new work never) is that a CEO-wait item DOES block new work and "blocks nothing else" means it blocks neither the turn end nor the handling of other items. The brief's one-line F7 makes "a CEO-wait item blocking new work" a FORBIDDEN mutation — the opposite. I cannot tell whether that is Frank's reading or the transcription's. Either way round 7 must not encode a sub-assertion for F7 from this line. Quote the two sentences in the brief; if Rich reads them as the brief does, that is a one-line question for the CEO, and it is a real one, unlike the one the brief carries.

**Two more mutations the seven miss (implemented, unasked):**

8. **An item waiting on something outside Rich's reach with no CEO-TODO entry** — point 5: *"the latter goes on the CEO's TODO list."* `wait()` at 1327–1343 raises `SpecError` when kind is `outside`/`ceo-discard` and `--todo` is empty. Drop the raise: no sub-assertion moves.
9. **A session's recorded end ignored** — point 12: *"A session has ended when it recorded its end or when its process no longer exists."* `record_session_end()` at 487–504 writes `ended_at` and `session_state` reads it; C12.4 asks only the process route. Ignore `ended_at`: no sub-assertion moves.

**One more that is inside frozen predicate 5 and was in my certification:** the stop-order half of allowance 1 (*"answering the CEO or obeying his stop order"*). `guard-workspace-gate.sh:15` treats both as "the turn began with a message from the CEO"; C5.2 exercises only the answer. A sub-assertion, not a red.

**And the continuation clause (§2) is not a mutation — it is red.**

**So the real number:** seven listed, minus F7 until its sentence is settled, plus 8 and 9, plus the stop-order sub-assertion = **nine mutations that leave the count unchanged** on the base, plus one unimplemented sentence.

**"Sub-assertions under the SAME frozen headings" is a reworded freeze, and it should say so.** Round 6 froze fourteen pass predicates (round-6 brief §4: *"Each is the pass predicate for the CEO's sentence of the same number"*), and my certification checked the harness against THAT text. F1, F2, F5 and the stop-order half are inside their frozen predicates — the harness under-implements them, and adding sub-assertions is honest. F3, F4, F6, F7, 8 and 9 are clauses the frozen predicates 3, 5, 10, 11 and 12 never contained. Adding them changes what those five checks ask; a check that was green under its frozen predicate turns red under an amended one. That is the right thing to do — the predicates were Rich's derivation, not the CEO's sentences — but "the headings stay frozen, this does not reword them" hides it. Honest form: *"Round 7 amends five of the fourteen frozen predicates (3, 5, 10, 11, 12) to carry clauses of his sentences they omitted; the measurement names each amendment beside its check."*

## 4. The end-of-run signal — the pairing rule is right, "once per worker" is false, and "take the last" is the bug it replaces

**What the two events are.** `WorkerStarted` is written by `worker-started-handoff.sh` on `SubagentStart` (line 3, 125–127); `WorkerRunEnded` by `worker-ended-handoff.sh` on `SubagentStop` (117, 173, 177). Both key on the payload's `agent_id`. The ledger's `finished` row is written by the SAME hook from the SAME `SubagentStop` payload (line 89) — so "the engine is receiving a different signal" is not what differs. What differs is the KEY: the ledger attributes a row to a teammate by worktree path (`owner_agent_id`), the event log by the payload's id.

**Across every session on this machine** (`we.py`, scratch; four files: three `~/.claude/teams/session-*/worker-events.jsonl` and the fallback `~/.claude/worker-events.jsonl`, which mixes several sessions including sandboxed test runs):

```
TOTAL started ids across files: 83   with >1 WorkerRunEnded: 8   with 0: 19
  session-16a15be1  started 31  started&ended 25  >1: 1 (zach-opus-g2, 2)   0: 6 (live now, incl. this agent)
  ~/.claude/worker-events.jsonl  started 50  started&ended 37  >1: 7 (two with THREE)   0: 13
```

So "`WorkerRunEnded` fires ONCE per worker" is one session's shape. Machine-wide, 8 of 83 started ids have more than one, and every one of the eight has the same timeline: an end BEFORE the start, then an end after it (`we2.py`):

```
zach-opus-g2  started 11:29:09.058   ended 11:29:07.658, 11:29:53.764
a338df2ddf    started 08:17:55.352   ended 08:16:21.578, 08:16:51.351, 08:19:00.740
a31cc4500d    started 10:35:01.272   ended 10:32:17.918, 10:33:04.474, 10:35:37.847
```

**g2's own transcript names the shape.** Line 1007: its final hand-in. Line 1008: `SubagentStop` under its own id (11:29:07). Line 1009: Rich's mid-task message (*"SCOPE ADDITION on the CEO's explicit order"*). Line 1010: `SubagentStart` — and `record-subagent-start.sh` prints `RESTART AFTER TERMINAL: agent ac1ed926cc7928ccf has a terminal record`. Then a second run, ended 11:29:53.

**Ruling.** `WorkerRunEnded` is once per RUN, not once per worker; a worker runs again when the platform restarts it, which is point 9's sentence (*"The platform restarts finished agents."*). Under point 11, g2 was FINISHED at 11:29:07: its run had ended and no pause had been recorded. The 11:29:09 start is a restart of a finished agent, which point 9 says is refused every tool. **"Take the last" is therefore wrong on the CEO's own page**, and it has the shape the brief says it avoids: there is no "last" at any moment a reaper acts — the rule turns a recorded fact into a guess about the future. The correct rule, and it is what `finished_state()` (`workspaces.py:877–899`) already does: the platform's end-of-run signal carrying the REGISTERED agent's own id ends its run; the agent is finished unless a pause was recorded before that end (point 11); `stopped` and `handed_in` finish it regardless; a later start for the same id is a restart, locked out (point 9, C9.1). Nothing takes a "last".

**The pairing rule holds where it matters** — every registered teammate today has a `WorkerStarted`, and the own-id end lands at the real end for 22 of 23 (`x.py`; g3: sub-run rows from 12:14:00, own-id end 13:27:38, the ledger's last row 13:27:38):

```
registered teammate ids today: 29   with WorkerStarted: 29   with own-id WorkerRunEnded: 23
WITHOUT own-id WorkerRunEnded: zach-opus-f5 f6 f7 f8 (killed by the CEO seconds after start — no signal), sage-fable-b2, frank-fable-b2 (live)
```

The four killed agents got no signal, which the page already handles: *"Any ending that gives no such signal is handled at session end (point 12)."* No rule change is needed for them.

**What the 1,100 other ids are is NOT established, and the brief's sentence about them is a guess.** *"`SubagentStop` … fires every time a subagent yields a tool round"* — the own-id data says `SubagentStop` fires once per run for the teammate. The other ids carry a transcript path that does not exist (62 transcripts on disk for 1,145 ended ids), the teammate's cwd, and no `agent_type`. They are transient helper subagents run inside the teammate's worktree. The ledger's per-path attribution of their stops is my round-6 mutant R-p11 ("sub-run end finishes the teammate"), which the spec build already refuses: `record_end()` looks the id up (`_record_for_agent`, 1226) and a sub-run id has no record — C11.1 asks exactly this. Round 7 should not characterize what the platform does per turn; it should say what was measured.

## 5. "Point 11 needs no change" — right, for the opposite reason; and the fault verdict is misattributed

**The brief measured the wrong record.** `~/.claude/state/worktree-ledger.jsonl` is the pre-spec advisory ledger. The spec build reads none of it:

```
$ grep -n -E 'worktree-ledger|worktree_ledger' engine/scripts/lib/workspaces.py     -> (nothing)
$ grep -rln 'worktree-ledger' engine/scripts | grep -v '\.test\.'                     -> land-completeness, inflight, unlanded-branches, ci-*, the four handoff hooks — none of them the spec build
```

The spec build's point-11 record is its own store, written from the same `SubagentStop` under the registered id (§4). So the sentence *"There is no such signal in what is being recorded"* is true of a record nobody in the spec build consults and false of the one it does. The numbers the brief quotes reproduce on the ledger (1,108 `finished` rows today at my read, 28 names, every name with more than one; g3 96 rows over 73.6 min, m1 56 over 60.9, g1 59 over 52.4, g2 68 over 50.7, g4 81 over 48.5 — `led.py`), and they measure the ledger's attribution, not point 11.

**The 00:39 incident was not this.** The brief, twice: *"exactly the shape of the 00:39 incident that killed two working agents"*; *"it was sprung at 00:39 today."* Rich's own record, `lifecycle-failure-record-2026-09-12.md` §4 (richos-hq, private record): *"At 00:39:24 Rich merged `cc/zach-opus-page1` into `/Users/alex/ab/richos` — the checkout this session runs its engine from — while the session and an agent were live. Hook wiring snapshots at session start; hook scripts are read live off disk. From that second the session ran the new registration-demanding lock-out under wiring that never writes a registration. `zach-opus-p2a` lost every writing tool mid-task. `zach-opus-d1` was refused from its first call."* That is point 9's lock-out applied to agents whose spawns predate registration — a mid-session install — not anything acting on a `finished` row. The brief rewrites the cause of today's worst incident.

**The three comment lines are real and say what the brief says** — `~/.claude/richos-engine/scripts/hooks/worker-ended-handoff.sh` line 3 *"LOG-ONLY; never blocks."*, line 57 *"an ADVISORY per-agent finish signal"*, line 62 *"SubagentStop fires every turn"* (the branch copy differs from the installed one only at line 136, a comment). **The conclusion drawn from them does not follow.** The same block, line 63: *"The reaper prints these beside its verdict and never decides on them."* The author knew AND made nothing decide on it. A misnamed advisory field is ours to rename — that much of the verdict stands — but it was not "a trap that was always going to be sprung", and it was not sprung. Line 62's "every turn" is also contradicted by today's own-id data (once per run); the comment is stale, not prophetic.

**Ruling on the sentence.** Point 11 needs no change. Not because "the engine was reading the wrong event" — the spec build reads the right one — but because the platform's end-of-run signal exists, arrives under the registered id at the real end, and the library's `finished_state()` already reads it the way the sentence says. What round 7 owes point 11 is small: rename the legacy ledger's `finished` to what it is (a per-run yield under a path) so nobody measures it as point 11 again, and add F6's sub-assertion. What round 7 must NOT do is the brief's "Do": *"read `WorkerRunEnded`-paired-with-`WorkerStarted`"* would rewire the spec build to the legacy event stream that lives in a session directory (or a fallback file that mixes sessions), and *"taken as the last one"* encodes a guess (§4).

## 6. Is anything in the brief Rich's rather than the CEO's?

1. **The worktree lock and `agent-liveness.sh` as "corroborating evidence" for point 11.** The page's closing paragraph: *"No question of whether an agent is still alive. No 'in use markers'. No liveness guessing of any kind. If something is not in the fourteen points above, it is not part of the spec."* Both citations are liveness. Strike them; an engineer who reads them will build on them.
2. **The point-11 section's causal story and its "Do"** (§5). Neither audit is its source; the brief's own header says Frank's number was 2 of 21 and Rich measured the rest. It is Rich's, and it is the section marked FOR THE CEO.
3. **The report format `FOURTEEN: N green, K red · self-check: green`** is my recommendation (§4 of my certification), not a sentence of his. Harmless; label it.
4. **Item 7's `CITATION_EXEMPT` cleanup** is repository hygiene, not spec. Keep it; label it.
5. **The "seven"'s framing as leaving the frozen headings untouched** (§3) is Rich's wording over a real change to five frozen predicates.

Nothing else in items 1–7 is outside his fourteen sentences.

## 7. Is the round finishable — is there a round 8?

**Yes, there is a round 8, and part of it can be pulled into round 7 now.**

- **Round 8, unavoidable: install and measure on `main`.** The CEO ruled tonight (`lifecycle-failure-record-2026-09-12.md` §8.2) that nothing is installed. Point 14's consumers on `main` — `reconcile-terminal-worktrees.py`, `workspace-retire.py` — are not on the base (deleted at `ca4ba9f8`) and are named in frozen predicate 14. The spec is implemented when the fourteen are measured green on the checkout a live session reads, with nothing running. That round has no name yet. Name it.
- **Pull into round 7 so it is not a round 8 of its own:** the continuation clause (§2, red 3); mutations 8 and 9 and the stop-order sub-assertion (§3); F7 only after its sentence is settled; the point-9 declaration (§2, last paragraph).
- **A page question for the CEO, one line each, that the brief should carry instead of the point-11 section:** (a) F7's two sentences of point 5; (b) point 9's "every process it started" is enforceable only as "every process running in or naming its workspaces" — is that enough.

If round 7 does everything in the brief as written, his spec is not implemented: three sentences remain unasked or unimplemented, one item is encoded backwards, and the point-11 work moves the build in the wrong direction.

## 8. What I ran, with exit codes

| command | exit |
|---|---|
| census (before), sha256 of every file under both stores, sorted, then sha256 of the listing | 0 |
| `~/.claude/richos-engine/scripts/inflight-ack.sh --sha 316d44bc… --impact none` | 0 |
| `git log --all -- 'docs/verification/certification-sage-round6*'`; `git branch -a --contains 61b0de69`; `git merge-base --is-ancestor` (×2) | 0 / 1, 0 |
| `we.py` — pairing across all four `worker-events.jsonl` files | 0 |
| `we2.py` — timestamps of every multi-ended started id; raw row shapes | 0 |
| `led.py` — ledger `finished` rows today per name, g2's timeline | 0 |
| `x.py` — registered ids today vs `WorkerStarted` and own-id `WorkerRunEnded` | 0 |
| `p8/probe.py` — point 8 against `uncommitted()` on the base (sandbox repository) | 0 (HOLE reported) |
| `i6/run.sh` — item 6 against the runner (sandbox repository, runner and library copied in, `--list`) | 0 (hole rc=0, control rc=1) |
| census (after) | 0 |

Scratch (session scratchpad, not committed): `we.py`, `we2.py`, `led.py`, `x.py`, `subs.txt`, `p8/probe.py`, `i6/run.sh`, `census-list.txt`, `census-after-list.txt`.

## 9. Census — before my first command, after my last

```
BEFORE  workspaces            4 files   07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9
        workspace-retirement  11286     67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1
AFTER   2026-09-12T20:39:18Z
        workspaces            4 files   07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9
        workspace-retirement  11286     67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1
        workspaces/events.jsonl 4dfa7993994ddf3db700924b70d49af4da765d7f58cd7812cffd6a3410a50bb3
        workspaces/repos.json   d7d7ae5d5a3ddce7717ab0058179e31a4c15c00bc4d961e589736c9af8490356
IDENTICAL. The only commands after the after-census are the write of this file and its git add/commit inside this worktree.
```

`retirements.jsonl` showed mtime 17:13 at my first read and the same at my last; the running engine appends to it through nobody's action, and it did not during this review.

## 10. THE BETTER VERSION — text Rich can lift

Replace the brief's header, "The number, corrected", items 3, 4 and 6, and the whole point-11 section with the following. Items 1, 2, 5 and 7 stand as written, with the two one-line additions marked.

---

**Base:** land `cc/sage-fable-c7` @ `61b0de69` and `cc/frank-fable-c7` @ `316d44bc` onto `dev/workspace-spec` first (both fork from `cc/zach-fable-m1` @ `00c2a075`; they touch different files except `.richos/publication-completeness`, whose exemption line item 7 deletes). Round 7 bases on the result. Nothing merged to `main`; nothing written outside the sandbox.

**The number, corrected.** The harness on the base prints `CHECKS RUN: 15  RED: 1`, and that is what it will print until checks 8 and 7 gain the sub-assertions below. Measured against his sentences, the fourteen are **11 green, 3 red**: C14.1 (item 1), point 8's ignored directory (item 2), and point 7's continuation clause (item 4, red 3). The report prints the CEO-facing number and the self-check apart: `FOURTEEN: N green, K red · self-check: green` (a reviewer's format, not his sentence).

**Item 1 — add:** a cross-repository spawn refuses when EITHER repository it will work in (the entity, and the one named on `cross-repo-worktree:`) has no current body of work.

**Item 3 — add:** the Bash guard is the closure; a direct write to the store's `integration.json` is the store's trust boundary and stays open by design. Say so in the measurement rather than reporting item 3 closed.

**Item 4 — the frozen predicates under-ask the page. Nine mutations leave the count unchanged; one sentence has no implementation.**

Round 6 froze fourteen pass predicates (its §4). This round amends five of them — 3, 5, 10, 11, 12 — to carry clauses of his sentences they omitted, and adds sub-assertions inside 2 and 7 that the harness under-implemented. The measurement names each amendment beside its check. The nine (a mutant per row; each is red after this round):

1. Discard without a reason — point 7 *"with the reason recorded"* (`workspaces.py:3078` supplies a default string today).
2. The CEO-order attestation dropped — point 7 *"never discarded without his word"*.
3. A session claiming a live session's agents — point 12 *"each handles only the agents it started"* (`_claimable`, 1427).
4. A branch the agent created left behind — points 3 and 10 (`snapshot_refs`, 2747).
5. The library's own `codex/` refusal removed — point 2. (A sub-assertion only; the handling is closed as a topic and does not change.)
6. Handed-in-then-ended — point 11 *"finished even if a pause was sent"* (`finished_state`, 894).
7. A pending item waiting outside Rich's reach with no CEO-TODO entry — point 5 *"the latter goes on the CEO's TODO list"* (`wait`, 1333).
8. A session's recorded end ignored — point 12 *"when it recorded its end"* (`record_session_end`, 487).
9. Allowance 1's second half — point 5 *"or obeying his stop order"*, unexercised by C5.2.

**Held back until the CEO answers one line:** "a CEO-wait item and new work". Point 5 says the item *"blocks nothing else"* and, three sentences on, *"New work stays blocked either way."* No sub-assertion for this until he says which governs; the question is in the CEO-TODOs.

**Red 3 — point 7's continuation, unimplemented:** *"a new agent continues from its branch, the old workspaces are deleted when the new agent starts, and its work counts as landed when the new agent's does."* No code path lets a spawn name the agent it continues. Add it to `register_spawn` (`--continues <agent>`): the old agent's workspaces are deleted at the new spawn, its record's disposition is linked to the new agent's land, and C7 gains the sub-assertion.

**Item 6, exact shape:** a LISTED probe the text rule cannot see, deleted together with its manifest line in one commit, leaves no trace (`deleted_probes`, `workspace-probes.py:598–629`: history is filtered by `is_workspaces_probe`, the manifest is read only at HEAD). Fix the history route: a path listed in the manifest at `commit^`, absent at HEAD and not retired, is MISSING. A text-visible probe deleted the same way is already MISSING (Sage A4) and stays so.

**Point 9, declared, not coded:** *"every process it started"* is enforced as every process whose cwd is inside, or whose arguments name, one of its workspaces (`processes_in`, 2660). Every child of every agent shares the host `claude` process as parent, so the OS cannot attribute a child to an agent; a child that changes directory away and does not name the path survives. The measurement says this in one line under C9. Whether that is enough is his call, on the CEO-TODOs.

---

**POINT 11 — THE SIGNAL EXISTS, THE BUILD READS IT, AND THE LEGACY LEDGER IS NOT IT**

Frank's "2 of 21" and the 24-of-24 measurement behind it are of `~/.claude/state/worktree-ledger.jsonl`, the pre-spec advisory ledger. Its `finished` rows are `SubagentStop` payloads attributed to a teammate BY WORKTREE PATH: g2's 68 rows carry 67 different `agent_id`s — transient helper subagents run inside its worktree — and only the last carries g2's own id. The spec build reads none of that file (`grep worktree-ledger engine/scripts/lib/workspaces.py` → nothing).

The platform's end-of-run signal is `SubagentStop` carrying the REGISTERED agent's own id (`worker-events.jsonl` names it `WorkerRunEnded`; `WorkerStarted` is `SubagentStart`). Today every one of the 29 registered teammates has a `SubagentStart` under its id, and for 22 of the 23 that ended, the own-id `SubagentStop` is the last thing in its run (g3: helper stops from 12:14:00, own-id stop 13:27:38). The library already keys on it: `record_end` looks the id up (`workspaces.py:1226`), a helper id has no record and finishes nobody (C11.1), and `finished_state` (877–899) applies the sentence exactly — ended and not paused is finished; `stopped` and `handed_in` finish regardless.

**Once per RUN, never "the last".** Machine-wide, 8 of 83 started ids carry more than one end, every one with the same timeline: an own-id stop, then a `SubagentStart` for the same id, then another stop. g2 is one of them — its transcript shows the hand-in (line 1007), the stop (1008), Rich's mid-task message (1009) and `record-subagent-start.sh` printing `RESTART AFTER TERMINAL` (1010). Under point 11 g2 was finished at 11:29:07; under point 9 the 11:29:09 start is a restart of a finished agent, refused every tool (C9.1). Nothing takes a "last" row; the first own-id end with no recorded pause before it is the end. Agents killed before any stop (`zach-opus-f5`–`f8` today) give no signal and are handled at session end (point 12), as the sentence says.

**Point 11's sentence needs no change,** and neither does the build's reading of it.

**Whose fault: ours, and small.** `worker-ended-handoff.sh` writes an advisory field named `finished` for a per-run stop attributed by path; its own comment (line 63) says the reaper "never decides on them", and nothing does. Round 7 renames the field so it is never again measured as point 11, and adds mutation 6. The 00:39 kill was not this: per `lifecycle-failure-record-2026-09-12.md` §4 it was the mid-session merge of `cc/zach-opus-page1` into the live engine checkout, which ran a registration-demanding lock-out under wiring that never registers. The worktree lock and `agent-liveness.sh` are not evidence for anything on his page — its closing paragraph excludes liveness — and are not cited.

---

**Round 8, named now:** install on the checkout a live session reads, with nothing running, and measure the fourteen on `main` — including point 14's `main`-only consumers `reconcile-terminal-worktrees.py` and `workspace-retire.py`. The spec is implemented when that measurement is green.
