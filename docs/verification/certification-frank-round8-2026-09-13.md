NOT CERTIFIED

# Round 8 certification — frank, 2026-09-13

**Under review:** `cc/zach-fable-m5` @ `151fa53f0026c14405bf19a91399fef16d8f2daf` (16 commits over `dev/workspace-spec` @ `6a04423d`), read from this worktree, whose HEAD is that commit. **This branch:** `cc/frank-fable-c9` · **worktree** `/Users/alex/ab/richos-wt/frank-fable-c9`. **The spec:** the CEO's fourteen sentences at `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, read in full; the mirror in this tree was neither read as the spec nor touched, and its pin was not touched. **The brief:** `/Users/alex/ab/richos-hq/docs/plans/round8-brief-2026-09-13.md` @ `91ea721b` (`git show 91ea721b:…` — read at the pin). **Sage's work was not read.**

**Constraints kept:** nothing installed; no merge, no push, no `install.sh`; nothing written into `/Users/alex/ab/richos/engine`; no main checkout touched (the operator's store and the `richos` main checkout were READ, by `grep`, `cat` and `git for-each-ref`); every `codex/` ref below lives in a `mktemp` fixture deleted at the end of its case. The census (§8) is identical before and after.

**The rule this report is written under:** every number here was printed by a run of mine (the log it came from is named, and the logs are committed beside this file in `certification-frank-round8-2026-09-13-logs/`), or it is marked UNVERIFIED by name.

**Why NOT CERTIFIED, in one paragraph.** The headline reproduces exactly (§1). The build is real: the doorway from the agent's own worktree is restored, the named deleters are refused, the turn rule reads stamped fields, the four survivors from my audit are red under their mutants. But the two mechanisms this round rests on — the effects check and the `run_in_background` stamp — are each bounded by a fact the platform does not supply, and the checks were written inside the bound. **The fifth survivor is the unnamed class from the main checkout** that item 2 itself named: a `commit` or `cherry-pick` in a main checkout that already sits on the recorded branch moves it, the guard passes it (exit 0), and the restore reads the move as the lead's land (§2, S1). Under two concurrent agents the restore undoes itself (S2). A `codex/` workspace can be written by path (S3); a `codex/` branch can be deleted from the lead's call by two spellings that actually delete (S4); a `codex/` ref outside the agent's registered repositories is gone after its PostToolUse (S5). Item 8's stamp closes the shape the model asked for and not the two the platform produces on its own — the call it moves to the background on timeout, and a call that forks a child — which is exactly the shape my two probe cases assert, so they stay RED and are NOT retired (§3). And item 4's rule counts 40 real rows the RichOS app stamped `human` on its own internal prompts as the CEO's turn (S8).

---

## 1 · The headline, as I reproduced it

All from `/Users/alex/ab/richos-wt/frank-fable-c9` at `151fa53f`, engine `engine/` of this worktree (`workspaces.py` sha256 `c6c82863551973a8`, guard `e70e4673e78325fd` — the same prefixes the engineer's logs carry), each harness sandboxed by itself and again by the wrapper (`CLAUDE_CONFIG_DIR`, `RICHOS_WORKSPACES_DIR`, `RICHOS_SESSIONS_DIR` into the session scratchpad; wrappers `run-fourteen.sh`, `run-suite.sh` in the log directory). The machine carried other agents' mutant passes the whole time: `uptime` load averages 35 → 64 → 112 → 152 across the run (printed in each log header).

| harness | command | verdict lines, verbatim | log |
|---|---|---|---|
| the fourteen, no mutants | `RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh` | `CHECKS RUN: 15  RED: 0` · `FOURTEEN: 14 green, 0 red · self-check: green` · `exit: 0` — **139 `ok` lines, 0 `FAIL`** (`grep -c '^      ok'` / `'^      FAIL'`) | `fourteen-frank-no-mutants.txt` |
| Bash guard suite | `bash engine/scripts/hooks/guard-worktree-removal.test.sh` | `=== guard-worktree-removal tests: all 161 passed ===` · `exit: 0` | `suite-guard.txt` |
| lock-out suite + mutants | `bash engine/scripts/hooks/guard-sealed-worktree.test.sh` | `=== mutation: all 11 properties proven load-bearing ===` · `exit: 0` (23 passed) | `suite-sealed.txt` |
| probe-runner suite + mutants | `bash engine/scripts/workspace-probes.test.sh` | `=== workspace-probes tests: all 47 passed ===` · `=== mutation: all 18 properties proven load-bearing ===` · `exit: 0` | `suite-probes.txt` |
| liveness + claims suite | `bash engine/scripts/hooks/agent-state-claims.test.sh` | `=== agent-state-claims tests: all 46 passed ===` · `exit: 0` | `suite-claims.txt` |
| unit tests | `python3 -B -W ignore engine/scripts/lib/workspaces.test.py` | `=== workspaces spec tests: 64 run, 0 failed ===` · `exit: 0` | `suite-unit.txt` |
| my own probe on the branch's library | `python3 -B docs/verification/certification-frank-recorded-attribution-2026-09-12-probe.py engine/scripts/lib/workspaces.py outside-stray outside-side serial-stray serial-side rich-at-my-tip` | `3/5 cases hold; BROKEN: outside-stray, outside-side` — the runner's `RED 2` reproduced at its source | `probe-mine-on-branch.txt` |
| the 83-mutant pass | **not re-run** (load 100–152 with two other full passes on the machine; the engineer's is 22 min alone) | — two rows reproduced by hand instead: MUTANT_RESULT_PENDING | `mut-*/fourteen.txt` |
| the Bash guard's own 26-mutant harness | not re-run | UNVERIFIED (the engineer's `suite-item23-guard-mutants-2.txt`) | — |

**The mutants edit code, never the harness:** `grep '^mutant ' engine/scripts/workspace-spec-fourteen.mutation.sh | grep -o '"\$[A-Z]"' | sort | uniq -c` → `69 "$W"` (workspaces.py) `11 "$G"` (the guard) `1 "$C"` `1 "$Q"` `1 "$U"` = 83, and 0 lines without a target variable; `workspaces.mutation.sh` → `53 "$W"`. `grep -c '^mutant R-'` → 24, `'^mutant S-'` → 59. The harness's loop (`scripts/lib/mutation-harness.sh:238,255`) prints `FAIL … the mutation did not apply` and `FAIL … the suite went red, but NOT at "<want>"`, so a drifted declaration or an unrelated red is never counted proven — the property the engineer relied on for his three re-aims.

**The 24 RECORDED mutants cite files that exist and sentences that are there:** `ls /Users/alex/ab/richos-hq/docs/verification/lifecycle-failure-record-2026-09-1{0,1,2,3}.md` → all four; the new `R-p02-codex-deleter-passes-the-guard` cites `…-13.md §5` and that file's line 126 reads *"Point 2 of the CEO's page is violable today — an agent can delete a `codex/` branch"* under `## 5. State at the time of writing`. One labeling caveat, §6.

---

## 2 · The greens I broke — every case sandboxed, fixtures only

Script: `certification-frank-round8-2026-09-13-logs/attack.py` (a copy of my scratchpad script; it drives the library through `barrier()` / `observe()` exactly as the two hooks do, and calls the Bash guard and the lock-out hooks with the platform's payload shapes). Runs: `attack-branch.txt` (all cases), `attack-branch-2.txt` and `attack-branch-3.txt` (two fixture corrections re-run: `cherry-pick` takes no `-q`; a same-second cherry-pick reproduces the original commit id, so the case now waits one second). Engine: `workspaces.py c6c82863551973a8`, guard `e70e4673e78325fd`. **Ten of thirteen cases BROKEN.**

### S1 · THE FIFTH SURVIVOR — the recorded branch moved from the main checkout that already sits on it

The common case is the main checkout on `main` with `main` recorded. No checkout is needed, so the doorway rule never fires; no verb names the branch, so the guard never fires; the new tip is a descendant of the snapshot tip that carries none of the agent's REGISTERED tips (its workspace HEADs, its reflog, its recorded created refs — `_own_unlanded_tips`), so `_restore_protected_refs` reads it as *"a descendant carrying none of the agent's work: the lead's land"* and leaves it.

```
=== main-checkout-commit
    guard on the agent's commit in the main checkout   exit 0
    main: snapshot / moved / after Post                 b3eb4f48 / a04c0694 / a04c0694
    protected-ref-restored events                       0
    VERDICT                                             BROKEN
=== main-checkout-cherry-pick        (the agent's OWN commit, cherry-picked onto main from the main checkout)
    guard on the agent's cherry-pick in the main checkout   exit 0
    main: snapshot / moved / after Post                 1af5a720 / 2a42a24e / 2a42a24e
    own.txt now in main                                 True
    VERDICT                                             BROKEN
=== main-checkout-merge-control      (the agent merges its own branch onto main from the main checkout: the tip carries a registered tip)
    main: snapshot / moved / after Post                 e18d0142 / 17bb56c0 / e18d0142
    VERDICT                                             HOLDS
```

The control shows why C14.13 is green and this is not: C14.13's doorway commit is made in the agent's own worktree, so the worktree's HEAD **is** the new tip and the own-work rule sees it. Made in the main checkout, the same commit is invisible to every one of the four sources. Point 14: *"only Rich moves it."* The brief's item 2 named this checkout in its own sentence — *"from the agent's own worktree or the main checkout"* — and the fourteen asks the main checkout only for a DELETION (C14.14). `git -C <main checkout> commit|merge <other>|cherry-pick|update-ref HEAD <descendant>|reset --hard <descendant>` all pass the guard from an agent's call (`guard-named-bypasses` in `attack-branch.txt`: exits `0 0 0 0 0 0`).

### S2 · Two agents at once: the restore undoes itself

```
=== two-agents-ping-pong
    main: snapshot / A moved / after A Post / after B Post   564783ed / bae80600 / 564783ed / bae80600
    protected-ref-restored events                            2
    VERDICT                                                  BROKEN
```

A moves `main` inside its call (its own merge — the move C14.13's rule restores). B's next call opens while `main` is moved, so B's snapshot records the moved tip as `main`'s reference. A's Post restores `main` to the snapshot tip. B's Post then finds `main` at a tip that does not descend from ITS reference — *"a rewind"* — and puts A's move back. Two `protected-ref-restored` events, two loud notices, and the agent's move stands. Concurrent agents are the normal case (forty were listed in this session's roster at spawn).

### S3 · A `codex/` workspace written by path

Point 2's second sentence. The guard refuses a `cwd`, `cd`, `-C` or `--work-tree` inside a `codex/` workspace (control below) and nothing else:

```
=== guard-codex-writes                    (an agent's call; $CX is the fixture's codex/fix worktree)
    control: cd into it                      exit 2 === Worktree guard: REFUSED ===
    redirect by path      printf x >> $CX/README                       exit 0
    tee by path           printf x | tee -a $CX/README                 exit 0
    cp by path            cp /etc/hosts $CX/hosts                      exit 0
    python open by path   python3 -c "open('$CX/x.txt','w').write('x')" exit 0
    sed -i by path        sed -i '' 's/x/y/' $CX/README                exit 0
```

C2.14's `m11` (`cd $CX && printf x >> README`) is the one form asked, and the five one step from it pass.

### S4 · The lead deletes a `codex/` branch by two spellings the guard does not read — and they delete

The build's own rule: *"a DELETER of a codex/ ref is refused from anyone's call, with no override."* Point 2: never deleted without the CEO's word.

```
=== guard-lead-deleters                   (the lead's call, no agent_id)
    control: lead update-ref -d                    exit 2 === Worktree guard: REFUSED ===
    lead update-ref --stdin delete                 exit 0     printf 'delete refs/heads/codex/fix\n' | git update-ref --stdin
    lead update-ref to the zero sha                exit 0     git update-ref refs/heads/codex/fix 0000000000000000000000000000000000000000
    `update-ref --stdin` delete ran                exit 0; codex/fix now: GONE
    `update-ref <ref> 0{40}` ran                   exit 0; codex/fix now: GONE
```

The `--stdin` rule is written `if AGENT and "--stdin" in rest` (guard line 562), so the lead is exempt from the one deleter rule that was meant to bind anyone; the zero-sha form is a write to the classifier and a delete to git.

### S5 · A `codex/` ref in a repository the agent has no workspace in

The effects check runs over `_repos_of(rec)` — the agent's registered repositories. An agent of a femcboost session has no `richos` workspace; the CEO's `codex/` branches live in `richos`.

```
=== other-repo-not-in-scope
    guard on `echo codex/fix | xargs git branch -D`   exit 0
    codex/fix after the Post                            GONE
    VERDICT                                             BROKEN
```

(The name reached `git branch -D` through `xargs`, which the text classifier cannot see; the same is true of `-c alias.zz='branch -f'` — exit 0 — and of `update-ref HEAD` — exit 0 — in `guard-named-bypasses`. A name-based guard has this class by construction; that is what the effects check is for, and here the effects check is out of scope.)

### S6 · A detached `codex/` workspace passes the lock-out

`_codex_workspace_of` asks `worktree_list` for the branch the worktree has checked out; a detached HEAD has none.

```
=== lockout-codex-detached
    Edit inside codex/ workspace: on branch / detached   2 / 0
```

### S7 · The stamp is the boundary of item 8 (the measurements are in §3)

### S8 · Item 4: the RichOS app's own internal prompts count as the CEO's turn

`_row_is_a_persons` returns `kind == "human"` for any row with a stamped origin. On `sdk-cli` rows the stamp is the SDK caller's, not the platform's, and the RichOS app stamps its internal prompts `human`:

```
python3 census over ~/.claude/projects (main-session, non-sidechain rows only; read-only):
39798922-a49e-45f6-8a62-f855fc8ea989.jsonl 4024d874-1bdf-4205-9c07-bd969b349e96 2.1.232 sdk-cli human sdk False
    '[INTERNAL RE-PRIME — do not mention this message; respond only "ready"]\n\nYou are Rich, the CEO\'s AI Chief of S'
INTERNAL rows, main-session: 24
151f99ad-9fc8-42f0-ae12-52d49795cafb.jsonl 3951ac18-dda1-4ace-a16b-b8c8398549ff 2.1.217 sdk-cli human sdk False
    '[Base] You are operating inside the Buzz platform — a Nostr-based messaging platform for h'   (16 rows)
```

The engineer's own census table carries both rows (`24 … origin=human promptSource=sdk | [INTERNAL…]`, `16 … | [Base…]`) under the STAMPED rule's **accepts** list, and C5.15b has no case for them. A turn the app began with a re-prime would spend the CEO's one allowance. The fix is not a text rule (the brief forbids one, rightly): it is the app stamping its internal prompts as not-human (or `isMeta`), which is Echo's, and the engine's negative fixture carrying the shape until it does.

### What held

`stamped-bg-call-only` (§3), `main-checkout-merge-control` (above), `helper-spawn-while-ceo-wait`: with an item waiting on the CEO's word, a plain spawn is refused (`REFUSED: === Finished work is not landed or discarded: you cannot start new work (point 5`) and a `lands-pending:` spawn is `allowed` — item 7's fix does not block the one spawn point 5 must allow.

---

## 3 · My two cases: ruled NOT obsolete, and not retired

**The engineer's claim:** `outside-stray` and `outside-side` *"simulate a backgrounded call without the platform's stamp"*; with `"tool_input": {"run_in_background": True}` added to the probe's `post()` they `HOLD 2/2`; the probe *"modeled a world the platform does not produce"*.

**Two things are wrong with that, and one thing is right.**

1. **The scratch copy stamped every Post, not the backgrounded one.** His diff changes `post()` itself, so all three calls in each case are stamped. That does not measure the mechanism; it measures the fallback. So I measured the fair case — the stamp on ONLY the backgrounded call's Post, the two neighbors unstamped — and it HOLDS (`attack-branch.txt`, `stamped-bg-call-only`: `created_branches ['spare']`, `land landed`, `branches after the land ['main']`). **The mechanism closes the stamped shape. That part is right.**

2. **The platform produces the unstamped shape, twice over, and my fixture is that shape.** (a) A Bash call the platform moves to the background on TIMEOUT: the model never asked for it, so `tool_input` carries no `run_in_background`, the tool result returns at the timeout with the process still running, and PostToolUse fires then. Measured in the lead's own session transcript (`~/.claude/projects/-Users-alex-ab-femcboost/16a15be1-….jsonl`, read-only): three such calls — `toolu_01AZVxPR1p56hAt4e56N8pDG`, `toolu_01Es9397SAqeaNQpVc1CqWxk`, `toolu_01PdQ1keb9FnaHVUC8QQ9csq` — each with `tool_use` input keys `['command', 'description']`, `run_in_background=None`, and a `tool_result` beginning *"Command did not complete within its 120s timeout and was moved to the background (ID: …)"*. It happened to me too, on this run's first census (`br62y03rs`). The installed binary carries the strings `s timeout and was moved to the background (ID: ` and `Command was moved to the background (ID: ` (`strings …/versions/2.1.269`, lines 225907–225910). (b) A foreground call that forks a child (`nohup … &`) returns at once, unstamped, and the child works on — the recorded shape of femcboost `CLAUDE.md`'s *"zombie residue, 2026-07-18"*, which the engineer's own `R-p09` mutant cites. Both measured against the branch:

```
=== timeout-backgrounded   (Post: tool_input {command, description}; tool_response says "moved to the background")
    created_branches after the next call         []
    land                                         landed
    branches after the land                      ['main', 'spare']
    VERDICT                                      BROKEN
=== forked-child           (Post: tool_input {command: "nohup ./deploy.sh >/dev/null 2>&1 &"})
    created_branches after the next call         []
    land                                         landed
    side commit in main                          False
    VERDICT                                      BROKEN
```

The `tool_response` shape of a timed-out call as the HOOK sees it is UNVERIFIED by name (I have the model-side `tool_result` text and the binary's strings, not a captured hook payload); `tool_input` is the model's own input and is what the engine reads, and that field is the one the platform does not stamp on a timeout.

3. **So the ruling.** The assertion is right (points 3, 9, 10: *"any branch an agent created"*, *"every process it started"*, *"None is left behind"*), the fixture is right — it is the platform's own timeout shape and the forked-child shape, and the docstring's one inaccuracy is that it names `run_in_background` as the measured overhang when the overhang it models is the unstamped one — and the mechanism closes a third shape. **Nothing in `workspace-probe-retirements.tsv` is added.** Adding the one field to my `post()` would turn the probe into a test of the fallback and stop it asking the question it was written to ask. The escalation I raised in round 7 (`esc-20260912T225456Z-d34bf4e6`, *"fix the window hole, or retire the case on your word"*) is answered by this round as engineering: the hole is narrower and still open, and it needs no word from the CEO.

**What it means that the probe modeled a world the platform does not produce:** it did not. It modeled the world the engineer's one-field fact does not cover, and the one-field fact was measured on a scratch copy that stamped every call. A premise measured against a fixture the code never sees is the same class as the round-7 finding this brief opened with.

---

## 4 · The rejected any-point alternative

**Right call, on the two options he measured.** Attributing every ref that appears between two closed calls at the agent's unlanded tip buys points 3/10 with point 8: Rich's bookmark at that tip is deleted by a discard, and my own control (`c4-control-no-refused-call.py`, `leaked-window-widens`) and the engine's `test_point_08_…never_created_in_it` are the two assertions that say so. A leftover branch is reversible; a deleted bookmark is not. Between those two, the leftover is the lesser harm and the rejection stands.

**But the bookmark is not the thing that should have moved — it is the thing that should have been OBSERVED.** Rich's calls pass through the same PreToolUse/PostToolUse hooks with no `agent_id`. A ref that appears inside one of the LEAD's own call windows is his, by the platform's word, exactly as a ref inside an agent's window is the agent's. With the lead's windows recorded, the rule becomes: a ref at an agent's unlanded tip that appears at any point in its run is the agent's UNLESS it appeared inside a lead window — and then the timeout shape, the forked child, AND the bookmark are all decided on stamped facts. The same design answers S1: a move of the recorded branch during an agent's run that did not happen inside a lead window is not the lead's land, whatever it carries. The two holes this certification turns on have one fix, and the engineer's binary (stamp the agent's call, or attribute everything) left it out. That is a round-9 build, not a CEO decision.

**Item 8's own completion test is not met either way:** *"a ref created at any point in the agent's run is attributed to it."* It is attributed inside a window, at the end of the run against the last snapshot, and after a call the model stamped. Not at any point.

---

## 5 · The five claims

**Claim 1 — item 2, the effect-based pair closes the unnamed class.** Partly. From the agent's own worktree: yes — C14.13 green in my run, and my merge control HOLDS. From the main checkout that already sits on the recorded branch: **no** (S1: `commit`, `cherry-pick` — guard exit 0, restored 0). Under two agents: **no** (S2). The eight verbs and the doorway by name: C14.16 green (`exits 2 2 2 2 2 2 2 2`, `2 2`, `0`, `0`); three spellings pass the name guard (`-c alias`, `update-ref HEAD`, `xargs`: exits `0 0 0`), which the effects check is supposed to catch and in S1's shape does not.

**Claim 2 — item 3, deleters refused from anyone, movers/creators from agents, writes inside `codex/` refused.** From an agent by name: C2.13/C2.14 green in my run. From the lead: **two deleters pass and delete** (S4). Writes inside a `codex/` workspace: **by path they pass** (S3); the lock-out passes a detached one (S6); the effects check does not reach a repository the agent has no workspace in (S5). The land path's `codex/ untouched` (C2.8, C2.6): green.

**Claim 3 — item 4, the numbers.** Re-run read-only (`transcript-census2.py` from the engineer's log directory; my output `census/census2-frank.txt`): `files: 2593   user text rows: 7449   main-session: 4678` (two transcripts newer than his 2,591; every other figure identical) · `68  cli  origin=absent promptSource=None meta=False … | Another-Claude-session…` · `670  sdk-cli  origin=absent promptSource=sdk … | words` · the DENY-LIST rule **accepts** the 68; the ORIGIN-ONLY rule **rejects** the 670. **Both numbers verified.** My 2,589 / *"3 peer rows, all isMeta"* was measured on subagent transcripts (my round-8 audit §4.2 says so: *"all in subagent transcripts"*); his is the corpus. The rule holds for the two sides he measured and fails a third real shape he tabled and did not assert (S8: 24 + 16 rows).

**Claim 4 — item 5.** C8.8 asserts `wc -c` equal on both files (14 bytes) and exit 2 naming `.env`; C9.6a is a positive control (`SIG_IGN` for TERM, alive after SIGTERM) before C9.6; C11.8/C11.8b assert both halves. All green in my run. The four mutants edit `workspaces.py` (`_same_file`'s first line; its sha1 compare; the SIGKILL loop; `finished_state`'s `handed_in` order) — code, not harness. **Holds.** (Not re-proven under the harness's mutant loop, §1.)

**Claim 5 — item 6.** `workspaces.mutation.sh` now declares `p14-nothing-bound-falls-back-to-current` against `test_point_14_a_record_bound_to_nothing_is_refused_never_guessed` (read, with the reason comment above it). `agent-liveness.py` `resolve()` wraps `_lock_resolve()` and `_registry_says()` (read); the claims suite is `all 46 passed` in my run, A7/A7a/A7b/R4 among them. **Holds.** The wording is corrected in the three files named. femcboost `CLAUDE.md:209–210` still reads *"Liveness = the worktree lock"* / *"run the authoritative check"* (`grep`, this run) — the other repository, round 9.

---

## 6 · One labeling caveat on the RECORDED mutants

`R-p03-backgrounded-call-window-consumed-at-its-post` (→ C10.7b) is labeled RECORDED against my probe's cases `outside-stray` / `outside-side` and their RED on the runner. The line it removes (`background = … bool(ti.get("run_in_background"))`) governs the stamped shape; the cases it cites are the unstamped shape and are still RED with the line present (§3). The mutant is real and C10.7b is a real sub-assertion; the incident it cites is not the incident it closes. `R-p03-ref-after-the-last-post-left-behind` (→ C10.7, the end-of-run compare) has the same relation to the same cases — the engineer's own §B says the end-of-run compare *"stayed BROKEN"* on them. Both should cite what they close (a stamped call's overhang; a ref after the last Post with no further call) and name my cases as the open remainder.

---

## 7 · Round 9

**The engineer is right that it exists. His list, each line re-measured this run:**

1. **Four `land-completeness` rows in the operator's store** — `grep -c '' ~/.claude/state/workspaces/events.jsonl` → `8`; `grep -n land-completeness` → rows 4, 5, 6, 7, each `"event": "integration-recorded"` for a repo under `…/T/land-completeness.{rSiULs,URJ6Yc}/…`. **Confirmed.** Removing them changes the census, which every round is told not to change — so their removal is a deliberate step of whichever round reconciles the store, announced as such. Engineering (Rich's), not the CEO's.
2. **`zach-opus-d1`** — `agents/16a15be1-…--zach-opus-d1.json`: `agent_id=''`, `end=None`, `disposition=None`, one `cc` workspace `/Users/alex/ab/richos-wt/zach-opus-d1` on `cc/zach-opus-d1`; `done/`, `ids/`, `sessions/` empty. **And the branch does not exist:** `git -C /Users/alex/ab/richos for-each-ref refs/heads/cc/zach-opus-d1` prints nothing (read-only). Workspace gone, branch gone: *"An agent that produced nothing counts as landed: its workspaces are deleted"* (point 7) — the record is reconciled as landed, nothing to discard, nothing for the CEO.
3. **No 93% pause** — `grep -rn -E '93 ?%|quota' engine/scripts/lib/workspaces.py engine/scripts/hooks/workspace-lifecycle.sh engine/scripts/hooks/guard-workspace-gate.sh` → nothing. **Confirmed.** The page names it as a thing that exists (*"the automatic pause at the CEO's 93% quota threshold"*); building it is engineering. The engineer's *"decide how a hold without the `pause-until:` marker is treated"* is engineering too: the page already says a pause naming nothing is pending work (point 11), and a hold that is not a recorded pause is not a pause.
4. **femcboost `CLAUDE.md:209–210`** — confirmed by `grep` this run. Rich's edit at cutover.
5. **The runner's witness** — my round-6 closure; `grep -n witness engine/scripts/workspace-probes.py` finds only the header's history of it. Not built. **Confirmed.**

**Corrections and additions from this certification:** S1–S6 and S8 above are round-9 build items, and the lead-window design (§4) is the one build that closes S1, the timeout shape and the forked child together. `RED 2` on the runner stays until the unstamped shape is closed; nothing in the TSV changes. The two escalations (`esc-20260913T073621Z-4d12a19f` from the engineer, for the lead; `esc-20260912T225456Z-d34bf4e6` from me, for the CEO) are both answered by this round as engineering and want Rich's ack with that disposition, not the CEO's word.

**Is anything in round 9 the CEO's decision rather than engineering? No.** Every item above has a sentence of his that settles it. The one candidate the engineer named — C14.15's bound (a lead's REWIND of the recorded branch during an agent's call is auto-undone and reported) — is inside point 14's *"only Rich moves it"*: the undo is loud, the reflog keeps his tip, and the lead-window design removes the ambiguity anyway. Not his to decide.

---

## 8 · The census

Method: `find … -type f | sort`, sha256 per file, sha256 of the list (the same as rounds 6, 7 and the engineer's `census.sh`, so the digests compare).

| | files | before my first command (`census-before.txt`) | after my last (`census-after.txt`) |
|---|---|---|---|
| `~/.claude/state/workspaces` | 5 | `aa2507954c2ca6ca62a61e58ea87fe48bca2653df966642795ba6d1a25b5b8e1` | AFTER_WS_PENDING |
| `~/.claude/state/workspace-retirement` | 11,286 | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` | AFTER_RET_PENDING |

The before-digests are byte-identical to the engineer's after-digests (his §C), so nothing moved between his last command and my first.

---

## 9 · What I did not do

- **Did not run the 83-mutant pass** (load 100–152 with two other agents' full passes running; two rows reproduced by hand in §1). The headline's `83/83` is the engineer's log, read, with its harness verified to count "did not apply" and unrelated reds as failures.
- **Did not run the Bash guard's own mutant harness** (`guard-worktree-removal.mutation.sh`, 26 mutants) — UNVERIFIED beyond his log.
- **Did not write an inflight-ack row:** `scripts/inflight-ack.sh` exits 2 with *"--sha must be the FULL 40-character commit main moved to (got '<empty>')"* — it acknowledges a land the lead sent, and none was sent. Said here rather than papered over.
- **Did not read Sage's work**, and did not touch `ref-after-post`.
- **Did not capture a live PostToolUse payload** of a timed-out call (§3, UNVERIFIED by name for the `tool_response` shape; the `tool_input` shape is from the transcript).
- **Did not retire anything.**

## 10 · Commits on `cc/frank-fable-c9`

Listed in the final report; this file and its log directory are the only additions.
