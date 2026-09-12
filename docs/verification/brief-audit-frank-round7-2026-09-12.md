BRIEF NOT READY

# Frank — audit of the round-7 brief (richos-hq `c99c62d6`)

**Subject:** the round-7 brief in the private richos-hq repository (its docs/plans, file round7-brief-2026-09-12.md, at richos-hq commit `c99c62d6`, 21:15:07 +0100). Not in this repository.
**Yardstick:** the CEO's fourteen sentences, read at richos-hq `docs/plans/worktree-spec-2026-09-11.md` (last touched at `c663a823`); the mirror here was not read as the spec and was not touched.
**Me:** frank-fable-b2 · worktree `/Users/alex/ab/richos-wt/frank-fable-b2` · branch `cc/frank-fable-b2`, cut at `316d44bc`. Nothing merged, pushed, installed or deployed; nothing written into `/Users/alex/ab/richos/engine` or any main checkout; both live stores byte-identical before and after (§7). Sage's work was not read (§4.4 reads two commit subjects from `git log --oneline`, nothing more).

## 0. The verdict in six lines

1. **The brief's biggest section is wrong at every load-bearing step, and the fix it prescribes would break point 9.** `WorkerRunEnded` is not a platform signal; it is the same `SubagentStop` payload, the same `agent_id`, written by the same hook eleven lines apart (`worker-ended-handoff.sh:89` and `:173`). The spec code at `316d44bc` reads neither log and already keys the end of run on the registered id (`record_end` → `_record_for_agent` → `None` for an unregistered id). C11.1 and C11.6 of the frozen fourteen assert exactly that. "Take the last" would make a finished agent writable again (§3.5).
2. **The signal does not cover kills.** Four of four teammates interrupted today (`zach-opus-f5`…`f8`) got no `SubagentStop` for their own id; 13 of 50 started ids across twelve earlier sessions never got one either. Point 11's own text already routes a no-signal ending to session end — so the sentence stands — but this session has run 24 hours, and that is the cost the CEO is not being told (§3.6, §3.8).
3. **My "2 of 21" and Rich's "24 of 24" are both true of the same ledger and answer different questions** (§1.1). Mine counted rows carrying the teammate's own registered id; his counted every row against a teammate. Mine was not wrong by an order of magnitude; it was under-stated, and the under-statement is mine to own.
4. **`RED: 2` holds on the frozen fourteen. The un-asked count does not: it is twelve, not seven** — ten proven by mutation (my seven plus three new: point 7's continuation, point 12's recorded end, point 5's outside-his-reach), plus point 8's nested-ignored shape (probe) and point 11's kill path (data; no code to mutate) (§2).
5. **The brief's base sentence is false.** `316d44bc` does not contain `cc/sage-fable-c7` (`61b0de69`): two commits are missing, and both branches edit the same region of `.richos/publication-completeness`, so the merge will conflict (§4.4).
6. **Four passages are Rich's, not the CEO's or either reviewer's**, and one contradicts the spec's closing paragraph (§4). **There is a round 8** (§5).

## 1. My own round-6 numbers, re-derived hostilely

### 1.1 "2 of 21" against "24 of 24" — one ledger, two questions

Reproduced from `~/.claude/state/worktree-ledger.jsonl`, rows dated 2026-09-12, at 20:33Z (`scratchpad/reproduce_numbers.py`):

```
ledger rows today: 1199 | finished rows today: 1112 | teammates registered today: 29
RICH  (rows attributed by the `teammate` field):  teammates with any finished row 26 | with >1: 26 | exactly one: 0
FRANK (rows whose agent_id == the teammate's registered id):
      teammates with a bound-id row 23 | it is the LAST row for 22 | not last for 1 (frank-opus-c4, one sub-run row 0.8 s after) | no bound-id row: 6
zach-opus-g3: 96 rows, first 12:14:00, last 13:27:38; bound-id rows: ['13:27:38']
```

Both reproduce. Rich's 24-of-24 (26 now, two agents later) is every `SubagentStop` the hook wrote against a teammate's worktree. Mine was the subset carrying the teammate's own id: one per run, at the end of the run. `zach-opus-g3`'s "first signal 73.6 minutes early" is its first sub-run row; its own id fired once, at 13:27:38, when it stopped. **My number was not wrong. My report was incomplete:** §2.5 said "sub-run finish" in passing and never stated that every teammate's worktree collects ~40 unrelated `finished` rows an hour, which is the number anyone reading the ledger naively would act on. That omission let the brief read "2 of 21" as "2 of 21 fired early", which I never measured and never claimed. The rule applies to me: **a reviewer's number is a claim with a date on it, and the claim needs its denominator written beside it.**

The six with no bound-id row: `zach-opus-f5`…`f8` (interrupted — §3.6) and the two live `-b2` reviewers (still running).

### 1.2 The point-8 probe — reproduces at `316d44bc`

`git diff --stat 00c2a075..316d44bc -- engine/scripts/lib/workspaces.py engine/scripts/hooks/ engine/scripts/workspace-spec-fourteen.test.sh engine/scripts/lib/workspaces.test.py` → empty. The library, hooks and harness are byte-identical to my round-6 base, so the probes transfer; I re-ran them anyway. `scratchpad/ignored-dir-b2.py` (LIB re-pointed at this worktree, output verbatim):

```
git status --ignored sees: !! .claude/ | !! .env | !! vendor/
uncommitted() -> dirty=[] ignored=['.env']
needed.txt inside ignored .claude/ reported: False
nested repo inside ignored vendor/ reported: False
.env (control) reported: True
_require_clean with .env matched: PASSED -> the land would proceed and delete .claude/notes/needed.txt and vendor/lib/.git
```

Hostile check of the probe itself: `land()` calls the same `_require_clean(r, "land …", ignored_ok, deadline)` at `workspaces.py:2338`; the deleter has no copy-aside step (`grep -n -i -E 'shutil\.copy|copytree|preserve|salvage'` → only comments). The brief's `1577–1578` citation is exact. **Stands.**

### 1.3 The seven forbidden mutations and the C4 quarantine — re-read from disk, F4 re-run

The round-6 results re-read from `scratchpad/mut/*/summary.txt` (written 20:51–20:56 by frank-fable-c7), not from my prose: F1, F2, F10, F19, F20, F26, F27 each `CHECKS RUN: 15  RED: 1` (C14 only); F4 `RED: 3` (C14, C13, C0 — C4 green); F5 `RED: 12`. Then re-run against this worktree's engine (`scratchpad/run-new-mutants.sh`, driver `mut-b2.sh`, sandboxed by the harness itself):

```
BASE-no-mutation:                  CHECKS RUN: 15  RED: 1   (C14)
F4-quarantine-elsewhere:           CHECKS RUN: 15  RED: 3   (C14, C13, C0 — C4 PASS)
```

**Stands.** C4's five sub-assertions are green against a land that moves the tree to `.parked-<name>` on `parked/<name>`; only C0.3/C0.4's worktree count sees it.

## 2. `RED: 2` — is it two, and how many clauses go un-asked

**On the frozen fourteen, two is the number.** I looked for a third red — a clause the CODE violates today — and did not find one: point 1's raw-add bypasses (python `subprocess`, a `git` alias) are reclaimed under the spec's own point-3 fallback, not refused, which I keep as a note; C2.6 and C4 are false greens of correct code; point 11's resume case is handled as point 9 says (§3.5); point 12's two-session clause has the check in code (`owner == me`) that F10 removes. C14.1 and C8 are the reds.

**The un-asked count is twelve, not seven.** The brief's item 4 lists my seven. Three more clauses of the CEO's sentences, each mutated out of `workspaces.py` and run through the fourteen against a `RED: 1` base:

| mutant | the sentence it breaks | fourteen say |
|---|---|---|
| F30 a continuing agent's start deletes nothing (`_on_start`: `for old_key in rec.get("continues") or []` → `for old_key in []`) | 7: *"the old workspaces are deleted when the new agent starts"* | **RED: 1 — invisible.** `grep -c -i continu` on the harness → 0 |
| F31 a recorded session end is ignored; only the pid path counts (`session_state`: `if rec and rec.get("ended_at")` → `if False`) | 12: *"A session has ended when it recorded its end or when its process no longer exists"* | **RED: 1 — invisible.** C12.1–C12.6 exercise the process path only |
| F32 a wait "outside his reach" with no TODO reference is accepted (`wait`: the `--todo` requirement → `if False`) | 5: *"waiting on something outside his reach … the latter goes on the CEO's TODO list"* | **RED: 1 — invisible.** `TODO` appears nowhere in the harness |

Plus two that no mutation can reach: point 8's nested-ignored shape (§1.2, a probe — the brief's item 2) and point 11's kill path (§3.6, data — nothing in the code to mutate because nothing in the platform fires). **Ten by mutation, two by probe and data: twelve.** The brief carries eight (seven plus point 8).

"Nine is not the space" is right, and neither is twelve: I mutated the clauses I could name from the page in the time I had. The census method is in `scratchpad/census_clauses.py` — a grep of the harness for each clause's vocabulary, then a mutant for each zero — and round 7 should run it against every sentence, not stop at mine.

## 3. The signal — items 3, 4, 5 and 6 of the brief

### 3.1 `WorkerRunEnded` is not a platform event, and it is not a different signal

The platform's hook catalog, read from the installed binary (`/Users/alex/.local/share/claude/versions/2.1.270`, Claude Code 2.1.270), is exactly:

```
PreToolUse PostToolUse PostToolUseFailure PostToolBatch Notification UserPromptSubmit UserPromptExpansion
SessionStart SessionEnd Stop StopFailure SubagentStart SubagentStop PreCompact PostCompact PreModelSwitch
PostModelSwitch PermissionRequest PermissionDenied Setup TeammateIdle TaskCreated TaskCompleted Elicitation
ElicitationResult ConfigChange WorktreeCreate WorktreeRemove InstructionsLoaded CwdChanged FileChanged
DirectoryAdded MessageDisplay
```

`grep -a -c '"WorkerRunEnded"'` on the binary → 0. `engine/hooks/hooks.json` subscribes `SubagentStop` to two hooks: `workspace-lifecycle.sh` and `worker-ended-handoff.sh`. The second writes BOTH rows the brief contrasts, from ONE payload: line 89 `rec = {"event": "finished", "signal": "SubagentStop", "agent_id": agent_id, …}` into the ledger, and line 173 `"event": "WorkerRunEnded", … "agent_id": agent_id` into `worker-events.jsonl`. Same event, same id, same instant (g2: ledger `11:29:07.638`, worker-events `11:29:07.658`). **"The correct signal EXISTS and is already being written… it is simply not what `worker-ended-handoff.sh` writes the ledger from" is false: it is exactly what that hook writes the ledger from.** The 1,131-versus-29 contrast is a grouping artifact: every sub-run stop carries a fresh id, so grouping by id makes 1,100 singletons; grouping by worktree makes 40 rows per teammate. The bound-id rows are the same 29 rows either way.

### 3.2 The spec code already keys on the registered id — and the fourteen already assert it

`workspace-lifecycle.sh` dispatches `SubagentStop` to `record_end(sid, payload.agent_id, "SubagentStop")` (`workspaces.py:2962–2963`). `record_end` → `_record_for_agent(session_id, agent_id)` → `key_for_id(agent_id)`; no registration, `return None` (`:1223–1228`, `:1214–1219`). `grep -n -E 'worker-events|WorkerRunEnded|worktree-ledger' workspaces.py workspace-lifecycle.sh` → nothing: **the spec code reads neither log.** And the frozen harness already says so: `C11.1 two SubagentStops carrying sub-run ids do not finish the teammate`, `C11.6 … its own SubagentStop carrying ITS id is the end-of-run signal`. My round-6 §2.5 opened with "C11.1 passes because `record_end` ignores an id it has no registration for." **"Round 7: read `WorkerRunEnded`-paired-with-`WorkerStarted`" prescribes, as new work, what the code does today and what check 11 measures.**

### 3.3 The sub-runs are not tool rounds; they are a clock

The brief: *"`SubagentStop` … fires every time a subagent yields a tool round."* Measured against my own worktree while I worked (`scratchpad/subrun_test.py`, and my transcript):

```
my tool calls so far: 62 — eleven of them inside 20:20:40–20:21:14
sub-run rows against my worktree: 28
gaps between consecutive rows (s): 123 34 34 33 33 34 33 34 63 63 34 33 35 93 35 33 31 31 33 31 33 31 34 34 33 31 32
```

A 31–35 s tick, with missed ticks at 63/93/123, through bursts of eleven calls and through long file reads with none. `zach-opus-g3`: 244 Bash calls in 73 minutes, 96 rows, 40 of them within 8 s after any Bash call — chance. Every sub-run row has `agent_type: ""`, no `WorkerStarted` (SubagentStart never fired for it), and an `agent_transcript_path` that does not exist (31 transcripts on disk = the 31 teammates). The binary says `Converting Stop hook to SubagentStop for <agent> (subagents trigger SubagentStop)` — the teammate-id stop is the teammate's own turn end, which is the platform's run end. **I could not identify the periodic emitter, and neither did the brief; "per-turn yield" is a second wrong label for it.** The honest rename is the signal's name and nothing interpretive: `subagent_stop`, with the registered-id match as a separate field.

### 3.4 One session is one sample — the other sessions

`worker-events.jsonl` across every team directory and the fallback file (`scratchpad` first script, 20:27Z):

```
session-16a15be1 (today): started ids 31 | ended=0: 6  ended=1: 24  ended>1: 1 | unstarted ended ids 1121, none with >1
fallback (12 sessions, 08-29..09-10): started ids 50 | ended=0: 13  ended=1: 30  ended>1: 7 (one is a test fixture)
   resumes seen: adcdfb44 Sta 07:58 Run 07:59 Sta 08:00 Run 08:01 · a338df2d three pairs · ac094ac4 Sta Run Sta Run Sta(no end) · a3d4f169 Sta Sta Run Sta Run
```

"Fires ONCE per worker" is one session's shape. Across the record: **6 of 49 real started ids end two or three times (every one a resume), and 13 of 50 never end.** `ac094ac4`'s last row is a bare `Started` — a resumed run that was then killed — which is the g2 anomaly and the kill gap in one id.

### 3.5 "Take the last" — the same bug wearing a different hat, and it breaks point 9

`zach-opus-g2`, both logs, verbatim order: `WorkerStarted 10:38:43` → `WorkerUpdated 11:28:45` (its "done" to main) → `WorkerRunEnded 11:29:07` → **`WorkerStarted 11:29:09`** → `WorkerRunEnded 11:29:53`. The second `WorkerStarted` is 1.4 s after the first end: a resume (the hook's own header, line 40, predicts it). There is no "last" while a message can restart the agent; a consumer waiting for "the last" waits forever, and one acting on "the last so far" acts at 11:29:07 anyway.

What the code does today: `record_start` does not clear `rec["end"]` (`:1156–1195`); `finished_state` returns finished the moment `end` is set and no pause precedes it (`:877–899`); the point-9 gate refuses the restarted run every tool. **That is the CEO's sentence, verbatim: "The platform restarts finished agents. A restarted agent is refused every tool."** The first teammate-id end IS the finish; the 11:29:09 run is the lock-out case. "Take the last" would clear the finish on restart and let a finished agent write — the one thing point 9 exists to forbid. (Consequence for femcboost: CLAUDE.md's *"resume ONCE to commit+verify+report"* is what the spec forbids; point 8 puts that commit in Rich's hands. That is a CLAUDE.md edit, not a spec one, and it is for the CEO's list because the file is his.)

### 3.6 Crashes, kills and limits — no signal, and the harness has an error string for it

The four teammates started today with no end row of any kind (`scratchpad/fate.py`):

```
zach-opus-f5  ledger: registered 2, finished 2 (sub-runs), prepared 1 · transcript last entry: user "[Request interrupted by user]"
zach-opus-f6  ledger: registered 2, prepared 1                       · "[Request interrupted by user for tool use]"
zach-opus-f7  ledger: registered 2, prepared 1                       · "[Request interrupted by user]"
zach-opus-f8  ledger: registered 2, prepared 1                       · "[Request interrupted by user]"
```

Zero `SubagentStop` for the teammate's own id, zero `TeammateIdle` (none fired for anyone today: 1,680 rows in the ledger, last 2026-09-11 11:09), zero `TaskCompleted`. The binary carries `[runAgent] SubagentStop on interrupted query failed:` — a path that TRIES to fire the hook on interruption and an error string for when it does not — and on this machine it reached the hook for none of the four. The record's own §3 says the CEO killed `f5` and `f6` himself. So the platform's signal covers the clean end of a run and nothing else: **not a kill, not a limit, not a crash.** "A signal that is reliable only for clean exits" is the signal there is.

### 3.7 The fault verdict — three parties, not one

- **Ours:** a durable ledger field named `finished` written from a signal that fires ~40 times an hour per teammate, three different signals (`SubagentStop` 16,106 rows, `TeammateIdle` 1,680, `TaskCompleted` 1,215) under that one word, and a hook header that already said "SubagentStop fires every turn" (line 62 — itself wrong: it is a clock, not turns). Real, and cosmetic to the spec code, which never reads it.
- **The platform's:** thirty-three hook events and not one for the end of an agent; `SubagentStop` skipped on interruption with its own failure string; `TeammateIdle` silent all day. "Genuinely blameless" is not the finding.
- **Nobody's:** the spec code at `316d44bc` reads the payload, matches the registered id, and treats a restart as point 9 says. It was not "reading the wrong one."

### 3.8 "Point 11 needs no change" — right, for reasons the brief does not have, with a cost it does not state

The sentence: *"An agent becomes finished when the platform's own end-of-run signal for it is recorded… Any ending that gives no such signal is handled at session end (point 12)."* The signal for a clean end exists and is recorded (§3.2). The no-signal endings — every kill, every limit, every crash — are routed by the CEO's own clause to session end. **The sentence stands as written.** What he is not being told: this session started 2026-09-11 22:25 and is still running; `f5`'s work (registered 01:49) would wait for that end, and the four native worktrees were removed by someone in the meantime with no ledger row saying by whom (the ledger has `registered`/`prepared`/`finished`/`terminated`, no removal event for them). If he wants a killed agent landed sooner than session end, that is a fifteenth sentence or an amendment to the eleventh — his word — and round 7 must not invent it. The one ending Rich himself performs, "stopped", already has its own recorded signal (`record_end(…, "stopped")`, `:1234–1237`) and is not affected.

### 3.9 The 00:39 attribution is not in the record

The brief twice ties the `finished` trap to the 00:39 incident ("exactly the shape of the 00:39 incident that killed two working agents", "it was sprung at 00:39 today"). The record (richos-hq `lifecycle-failure-record-2026-09-12.md` §4, lines 104–111) says what killed them: at 00:39:24 Rich merged `cc/zach-opus-page1` into `/Users/alex/ab/richos`, the live engine checkout, and *"the session ran the new registration-demanding lock-out under wiring that never writes a registration"*; `zach-opus-p2a` lost every writing tool mid-task and `zach-opus-d1` was refused from its first call. A lock-out demanding a registration that the hooks were not writing — nothing about a `finished` row. The brief's proof that the trap "was always going to be sprung" cites an incident the trap did not cause.

## 4. What in this brief is Rich's, not the CEO's or a reviewer's

1. **"Corroborating evidence already used elsewhere in this system: the native isolation worktree lock … and `agent-liveness.sh` … `ALIVE` / `NOT-ALIVE` / `INDETERMINATE`."** The spec's closing paragraph: *"No question of whether an agent is still alive. No 'in use markers'. No liveness guessing of any kind. If something is not in the fourteen points above, it is not part of the spec."* This sentence re-admits, as evidence, the two mechanisms the CEO struck. Neither reviewer wrote it.
2. **"`SubagentStop` fires every time a subagent yields a tool round" / "rename the ledger's `finished` to … a per-turn yield."** Rich's inference from row counts; refuted by cadence (§3.3). Not in my audit; the mechanism is unidentified.
3. **The 00:39 attribution** (§3.9). Not in the record it cites.
4. **The base sentence.** *"`cc/frank-fable-c7` @ `316d44bc` (which contains `cc/sage-fable-c7` and `cc/zach-fable-m1`)."* `git rev-parse`: `cc/sage-fable-c7` = `61b0de69`, `cc/zach-fable-m1` = `00c2a075`; `git log --oneline 316d44bc..61b0de69` → two commits (Sage's certification and Sage's exemption line — subjects only read). `316d44bc` contains `zach-fable-m1` and not `sage-fable-c7`; the diff `00c2a075..316d44bc` is my two files. Both reviewers edited `.richos/publication-completeness` in the same group (item 7 says so), so that merge conflicts. **Round 7's stated base does not carry one of the brief's two stated sources.**
5. **Item 3's "Do: refuse it in an agent's call the way `claude -w` is refused."** My §4 argued the opposite priority — *"a cheaper closure than a guard"*: the runner abstains on a non-operator store unless named, prints the recorded tip beside the remote's, diffs manifests across history. The brief keeps my two attacks and drops my three closures for a guard. If the guard is Sage's, it is Sage's to defend; if not, it is Rich's, and either way the runner closures are gone from the brief. Item 6 (the manifest hole) has no "Do" at all — my closure for it was "diff the manifest at HEAD against every commit in the last N".
6. Not Rich's, for the record: "FOURTEEN: N green, K red · self-check: green" is my §6; C4 by registry and ref list is my §2.2; the seven are my §3.

## 5. Is there a round 8

**Yes, and it is honest to say so now.** Three reasons, in order of what it costs to be wrong about:

1. **Round 7 as briefed would be certified by the same two reviewers, and a brief with §3–§4's defects produces a build with them.** A round that implements "take the last" ships a point-9 violation; a round that implements "read `WorkerRunEnded` paired with `WorkerStarted`" re-implements `record_end` against a second log; either is a red in round 7's certification. A corrected round 7 (THE BETTER VERSION below) removes that reason.
2. **The kill path is a CEO decision, not an engineering item.** Whether "handled at session end" is acceptable when a session runs 24 hours is his call (§3.8). If his answer is "no", it is a sentence on his page and then a round to implement it. If "yes", it is one line in the record and no round.
3. **Twelve un-asked clauses is what I reached, not the census.** §2's method run over all fourteen sentences will find more; each one found after round 7 lands is a round-8 item by the freeze rule (sub-assertions are added, headings are not reworded).

So: **round 7 corrected is the last engineering round on the fourteen as written**, if and only if the CEO answers (2) "yes" and the full clause census is part of round 7's own scope rather than a later discovery. Otherwise round 8 exists, and its content is already known: the kill path and the census remainder.

## 6. Standing constraints

Nothing merged, pushed, installed or deployed. Nothing written into `/Users/alex/ab/richos/engine`, `/Users/alex/ab/richos`, `/Users/alex/ab/richos-hq` or any main checkout. Nothing `codex/` touched. No fix to any red. No edit to `workspaces.py`, the hooks, the harness, any probe or retirement. Sage's audit and certification not read (two `git log --oneline` subjects seen, §4.4). Mutants ran on copies of this worktree's `engine/` under the scratchpad, sandboxed by the harness (`HOME`, `CLAUDE_CONFIG_DIR` redirected). The full engine sweep not run.

## 7. Census — before the first command, after the last

```
before  20:18Z   ~/.claude/state/workspaces            07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9  (4 files)
                 ~/.claude/state/workspace-retirement  67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1  (11286 files)
after   20:38:47Z ~/.claude/state/workspaces           07ae3d7f12e894230f1eb9f7018019cad40a1923c029b627191324095c96fcf9  IDENTICAL
                 ~/.claude/state/workspace-retirement  67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1  IDENTICAL
```

Method: sha256 of every file, listed sorted, hashed again. Identical to my round-6 census and the engineer's. `~/.claude/state/worktree-ledger.jsonl` grew (19,762 → 19,846 rows) by the running engine's `SubagentStop` hook writing sub-run rows for every live agent including me — through no command of mine; it is not one of the two named directories. The only commands after the after-census are the write of this file and its commit.

## 8. What I ran, with exit codes

| command | exit / result |
|---|---|
| census before (20:18Z) | 0 |
| `inflight-ack.sh --sha dcabcbd9… --impact none` | 0 — ledger row written |
| `python3` over `engine/hooks/hooks.json` | 0 — event subscriptions (§3.1) |
| `grep -a -c` of 13 event names in the Claude Code 2.1.270 binary; `grep -a -o '"PreToolUse","PostToolUse"…'` | 0 — 33-event catalog; `WorkerRunEnded` 0 |
| `scratchpad/map_session.py` | 0 — 31 started ids → names; 6 with no end |
| `scratchpad/g2_and_shapes.py` | 0 — g2's five rows; sub-run row shape; ledger keys |
| `scratchpad/subrun_test.py`, own-transcript correlation | 0 — §3.3 |
| `scratchpad/reproduce_numbers.py` | 0 — §1.1 |
| `scratchpad/fate.py` | 0 — §3.6, §3.4 |
| `scratchpad/census_clauses.py` | 0 — §2 |
| `scratchpad/ignored-dir-b2.py` | 0 — §1.2 |
| `scratchpad/run-new-mutants.sh` (BASE, F4, F30, F31, F32; 5 × the fourteen, inner mutants skipped) | BASE `RED: 1`; F4 `RED: 3` (C4 PASS); F30/F31/F32 `RED: 1` |
| `git -C … rev-parse` / `log --oneline 316d44bc..61b0de69` / `diff --stat 00c2a075..316d44bc` | 0 — §4.4, §1.2 |
| binary grep, `LC_ALL=C`, for `interrupted query` / `subagents trigger SubagentStop` | 0 — §3.3, §3.6 |
| census after (20:38:47Z) | 0 — identical |

---

# THE BETTER VERSION

Replacement text for the brief, in place of the sections named. Everything not named stands as Rich transcribed it. Item numbers are the brief's.

### Base (replace the first paragraph)

**Base:** `cc/frank-fable-c7` @ `316d44bc` (Frank's certification over `cc/zach-fable-m1` @ `00c2a075`) **merged with** `cc/sage-fable-c7` @ `61b0de69` (Sage's certification over the same base). The two branches conflict in `.richos/publication-completeness` — both added an exemption for the engineer's round-6 record; resolve by keeping ONE line and then doing item 7. Land the merge on `dev/workspace-spec` first. **Nothing merged to `main`; nothing written outside the sandbox.**

### 4 · The frozen fourteen UNDER-ASK the page — twelve clauses, ten of them proven by mutation

Each of these breaks a clause of the CEO's sentences and leaves the count where it was (`RED: 1` base, the harness's own sandbox; drivers in Frank's round-6 and round-7 audits). The fourteen headings stay frozen; each adds sub-assertions under its heading.

1. **Discard without a reason** — point 7: *"with the reason recorded"*. (F1)
2. **The CEO-order attestation dropped** — point 7: *"never discarded without his word."* (F2)
3. **A session claiming a live session's agents** — point 12: *"each handles only the agents it started"*. (F10)
4. **Created branches ignored** — points 3 and 10. (F19)
5. **The library's `codex/` guard removed** — point 2. (F20) Check 2 must aim a deleter at a `codex/` ref on an agent's record and watch it refuse.
6. **Handed-in-then-ended** — point 11: *"finished even if a pause was sent."* (F26)
7. **A CEO-wait item blocking new work** — point 5: *"blocks nothing else."* (F27)
8. **A continuing agent's start deletes nothing** — point 7: *"the old workspaces are deleted when the new agent starts."* (F30) No check exercises `continues`.
9. **A recorded session end ignored** — point 12: *"has ended when it recorded its end."* (F31) Check 12 exercises only the process path.
10. **A wait outside his reach with no TODO reference** — point 5: *"the latter goes on the CEO's TODO list."* (F32)
11. **An ignored directory skipped by name** — point 8 (item 2 above; a probe, not a mutant).
12. **An agent killed mid-session** — point 11's no-signal path (item 8 below; data, no code to mutate).

**Do:** a sub-assertion under the owning heading for each of 1–11 so its mutant turns the check red, and the mutant itself added to the harness's list so it stays proven. **Then run the census over every sentence** (`census_clauses.py`'s method: the harness grepped for each clause's vocabulary; a zero gets a mutant) and add what it finds. The twelve are what one reviewer reached, not the space.

### THE BIGGEST FINDING — replace the whole section with this

## POINT 11: THE SIGNAL EXISTS FOR CLEAN ENDS, THE CODE ALREADY READS IT, AND NOTHING COVERS A KILL

**What the ledger shows.** 24 of 24 teammates today have dozens of `finished` rows (Rich's count: every `SubagentStop` against a teammate's worktree, ~40 an hour). 23 of 29 have exactly one row carrying their own registered id, at the end of their run (Frank's count). Both are true; they answer different questions. The dozens are a periodic emitter — a 31–35 s tick, fresh id each time, no `SubagentStart`, no transcript, `agent_type` empty — **not** the teammate's turns and **not** its tool calls (measured: 62 calls, 28 rows, cadence independent). Its origin is unidentified.

**What the code does.** `workspace-lifecycle.sh` → `record_end(sid, payload.agent_id, "SubagentStop")` → `_record_for_agent` → `None` for an id with no registration. The sub-run rows never reach the record. The frozen harness asserts it: C11.1 (sub-run ids do not finish the teammate), C11.6 (its own id is the end-of-run signal). `workspaces.py` reads neither `worktree-ledger.jsonl` nor `worker-events.jsonl`. **No change to how the end of run is read.**

**What `WorkerRunEnded` is.** The same `SubagentStop` payload, written to `worker-events.jsonl` by the same hook (`worker-ended-handoff.sh:173`) that writes the ledger row (`:89`), with the same `agent_id`. It is not a platform event (the 2.1.270 catalog has 33; it is not one). Pairing it with `WorkerStarted` is the same filter `record_end` already applies. **Nothing in round 7 reads it.**

**Resumes.** `zach-opus-g2`: end `11:29:07`, `SubagentStart` again `11:29:09`, end `11:29:53`. The code keeps the first end (`record_start` never clears it) and refuses the restarted run every tool — point 9 verbatim. **Round 7 keeps that.** "The last end" is not a rule: there is no last while a message can restart the agent, and clearing the finish on restart is the write point 9 forbids. (For femcboost: CLAUDE.md's "resume ONCE to commit+verify+report" is the spec's forbidden case; point 8 gives that commit to Rich. On the CEO's list; his file.)

**Kills, limits, crashes.** `zach-opus-f5`…`f8`, all four interrupted today: no `SubagentStop` for their id, no `TeammateIdle`, no `TaskCompleted`. Across twelve earlier sessions, 13 of 50 started ids never got an end row. The harness has an error path for it (`[runAgent] SubagentStop on interrupted query failed:`). **The platform gives no signal for any ending but a clean one.** Point 11's own clause routes those to session end (point 12). **The sentence stands.** What it costs: this session has run 24 hours; a killed agent's work waits that long. **For the CEO, one question:** is "at session end" acceptable for a killed agent, or does he want a sentence for it? Round 7 implements neither answer; it records the question.

**The ledger's word.** `finished` is written for three signals (`SubagentStop` 16,106 rows, `TeammateIdle` 1,680, `TaskCompleted` 1,215). **Do:** the row carries the signal's own name as its event (`subagent_stop`, `teammate_idle`, `task_completed`) and a boolean `registered_id` (the payload id matches a registration). No consumer reads `finished`; the reaper prints these beside its verdict and never decides on them (the hook's line 63) — unchanged.

**Whose fault.** The ledger label and the hook header's "fires every turn": ours. No termination event in 33, `SubagentStop` skipped on interruption, `TeammateIdle` silent all day: the platform's. The spec code: not at fault; it was not reading the wrong signal. The 00:39 deaths were the registration-demanding lock-out under hooks that wrote no registration (record §4), not this.

### 3 · (append to the "Do")

**Do, also:** the runner abstains when its store is not the operator's (`RICHOS_WORKSPACES_DIR`/`CLAUDE_CONFIG_DIR` set and no explicit `--store <path>` echoed in the header); it prints the recorded branch's tip beside `git rev-parse origin/<branch>` on the one line a reviewer reads.

### 6 · (add the missing "Do")

**Do:** the runner diffs `docs/verification/workspace-probes.manifest` at HEAD against the manifest at each commit in the scanned range; a line that disappears without a retirement is `MISSING`.

### 8 · (new item) Point 11 — the no-signal ending, recorded for the CEO

Not an engineering item. Round 7 writes the facts above into the record and puts the one question on the CEO's list. No code implements an answer he has not given.

### Closing line (add)

**Round 8 exists if the CEO answers item 8 "no", or if the clause census in item 4 is left for later.** If he answers "yes" and the census is inside round 7, round 7 is the last engineering round on the fourteen as written.
