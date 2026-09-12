BRIEF NOT READY

# Brief audit, round 8 — Sage (sage-fable-b3), 2026-09-13

| | |
|---|---|
| **Brief** | `/Users/alex/ab/richos-hq/docs/plans/round8-brief-2026-09-13.md` @ richos-hq `c625742a` (132 lines, read in full). |
| **Spec** | `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md`, sha256 `957d21a4e76262c28bb8b69cd37249cc87eea326e12c927c2997ad9887b10978`, read in full. The mirror in this tree hashes the same and was neither read as the spec nor touched. |
| **Base** | `dev/workspace-spec` @ `a0c1e1bd3c17bc4957b0ea074684893227e05470` (`git rev-parse dev/workspace-spec`); `main` @ `dcabcbd9`. `git diff --stat 44a7d5d4..a0c1e1bd -- engine` is empty, so every engine measurement in my round-7 certification is a measurement of this base. |
| **Where I stood** | `/Users/alex/ab/richos-wt/sage-fable-b3`, branch `cc/sage-fable-b3`, cut at `a0c1e1bd`. Every command below ran from this worktree or from throwaway copies of its `engine/` under the scratchpad. |
| **Constraints kept** | nothing installed, merged, pushed; no `install.sh`; nothing written into `/Users/alex/ab/richos/engine`; no main checkout touched; the only `codex/` branch I created lives in a sandbox repository under the scratchpad (the five real `codex/` worktrees under `richos-wt/` were listed, never touched); Frank's files unopened (two `grep -c` counts on his certification, no content read, declared in §7). |

## 0 · The verdict, and exactly what it rests on

The brief is honest, the seven premises all reproduce, and item 1 is my finding intact. It is NOT READY for four reasons, each fixable in the brief's own text (§11 gives the text):

1. **Item 7 is a code defect, and the brief presents it as an assertion gap.** `workspaces.py:1609` reads `"blocks_new_work": kind != "ceo-discard"` — the round-7 paraphrase is in the library, not only in C5.13's comment. Measured: with one item waiting on the CEO's word, an unrelated spawn returns `rc=0` (§4). The brief's own line *"Nothing below is a regression … every item is a door the build has not closed yet"* would send the engineer to add the new-work sub-assertion, watch it go red on the current code, and read the brief as forbidding him to touch the code.
2. **The CEO's decision list is "empty" only with an item the brief does not carry.** The runner at this base prints `RED` for `certification-frank-recorded-attribution-2026-09-12-probe.py`, and the open escalation `esc-20260912T225456Z-d34bf4e6` (state `work-complete`, `--for ceo`, no `ack`) asks *"fix the window hole, or retire the case on your word?"*. The brief says the probe *"goes green when item 1's sibling fix lands"*; no item in the brief touches ref attribution, and Rich's own calls document (`rich-calls-with-proof-round7-2026-09-12.md:141`) says it *"stays red and blocking until the window hole is fixed or he retires it"*. The right resolution is engineering, not his word — but it has to be an item, and the ledger row has to be acked, or the round lands with `RED 1` and a bell still ringing for him (§8).
3. **Items 2 and 3 are shorter than what is already proven to pass**, and the short list is how a round 9 gets written. From an agent's call today: `git checkout dev/work`, `git switch dev/work`, `git branch -C cc/x dev/work`, `update-ref --stdin` all pass (§5, item 2); a registered agent's `Write`/`Edit` with a `file_path` inside a codex/ workspace and any Bash with `cwd` inside one pass the catch-all (§5, item 3). The brief names four verbs and "a commit".
4. **"Pin never touched" is Rich's, and it preserves a wrong record.** The implementation record's pin (`b3fd6cd33b8c1135`, `workspace-spec-implementation-2026-09-11.md:3`) matches neither the mirror nor the canonical page (both `957d21a4…`). The CEO said the mirror is never read as the spec; he said nothing about a pin (§7).

Everything else in the brief I re-derived and it holds. Round 8 with §11's text is the last BUILD round; what follows it is a certification pass and the cutover, and I say what is in each (§9).

---

## 1 · The quotation check — every quoted clause against the page

Method: each `*"…"*` passage and each `>` block in the brief, unwrapped (blockquote markers, line breaks, `**` emphasis removed from BOTH sides), searched as a substring of the page; then a byte-strict pass on the two long blocks with only line-wrapping and the spec's own `**` set aside.

| brief line | quoted text | source | result |
|---|---|---|---|
| 53–55 | *"A `codex/` workspace or branch is never deleted … Landing never deletes anything `codex/`."* | spec 11–13 | **BYTE-EXACT** (the page bolds its first sentence; the brief does not — markup, not words) |
| 78 | *"Deletion therefore never loses anything that was meant to land."* | spec 57–58 | **exact** |
| 80 | *"An agent that ends after handing in its work is finished even if a pause was sent."* | spec 79 | **exact** |
| 104–108 | *"…If the only way to end a piece of pending work … New work stays blocked either way."* | spec 34–39 | **BYTE-EXACT** (straight apostrophes both sides) |
| 110 | **"Blocks nothing else"** | spec 36 | **one character**: the page has `blocks` (mid-sentence); the brief capitalizes it to open a sentence. Harmless; lowercase it and it is exact. |
| 111 | **"New work stays blocked either way"** | spec 39 | **exact** |
| 99 | *"a CEO-wait item blocking new work"* | round-7 brief, line 90: **A CEO-wait item blocking new work** | **exact** (Rich's words, correctly attributed to Rich) |
| 33 | **"holds nothing"** | not the page — `workspace-probes.py:598` docstring / my certification §0 | correctly not presented as the CEO's |
| 93 | *"AUTHORITATIVE. The only source that decides"* | `engine/scripts/lib/agent-liveness.py:87`, verbatim | correctly labeled as the engine's wording |

**One paraphrase is carried where the rule at line 25 says only the sentence may be:** item 4's *"The one allowance point 5 grants a reply to the CEO"*. The page's sentence is *"Two things are always allowed, and only these two: answering the CEO or obeying his stop order (the reply names the pending work, which is handled right after); and work whose only purpose is getting the pending work landed"*. Two allowances, and the first has a stop-order half — which matters for item 4, because a `cross-session-message` saying "stop" must not count as his stop order either. §11 quotes it.

The commands: `python3` over both files (the normalizing pass and the byte-strict pass), outputs `MATCH`/`BYTE-EXACT` as tabled; the two runs are in my transcript and reproduce from the two paths above.

---

## 2 · Item 1 — is it my finding intact, and is the fix the right one?

**Intact.** My certification §0/§6 (`dc53d0ae`): *"holds nothing" implemented as the path does not exist (`workspace-probes.py:644`, `not exists_at(root, "HEAD", rel)`)*; a docs-only commit that replaces a red probe with a stub AND drops its manifest line → `DELETED 0`, `NOT LISTED 0`, absent from the report, exit 0; deleting the file the same way → `MISSING`, exit 1. The brief's item 1 says exactly that. (`:644` is the condition, `:645` the append — same site; `sed -n '640,647p' engine/scripts/workspace-probes.py` shows both.)

**The fix as the brief words it is weaker than mine, in one word.** The brief: *"listed at any commit and not ASSERTING at HEAD → MISSING unless retired"*. Mine: *"listed at any commit and not LISTED at HEAD → MISSING unless retired, whatever file happens to sit at its path."* "Asserting" has no mechanical reading — an engineer will implement it as `is_workspaces_probe(text)` or "has a `CASES` list", and a stub that keeps its `CASES` list and returns green "asserts" by that test. "Listed at HEAD" is read from the manifest, which the attacker has to edit to escape RED (a gutted probe that is still listed is `UNRUNNABLE` and blocks — my attack 3c). The rule closes the class by the one observable the attacker cannot avoid producing.

**Does it keep the deletion case caught?** Yes, all four cells:

| | still listed at HEAD | delisted at HEAD |
|---|---|---|
| **file deleted** | path absent → MISSING (today) | not listed → MISSING (new rule) — and path absent → MISSING (today) |
| **file gutted** | UNRUNNABLE / RED → blocks (today, 3c) | not listed → MISSING (**new rule — the hole**) |

**The brief's second option** — run every listed probe at the recorded integration branch's content — is the better shape and closes the case neither rule sees: an engineer editing a reviewer's assertion to `return True` on his own branch. §11 states the manifest rule as the minimum with its observable, and the content-at-recorded-branch as the preferred shape, so the engineer cannot pick "asserting".

---

## 3 · Item 7 — the reading is right, and I was wrong in round 7 to send it to the CEO

The two sentences govern different objects, and the page says which:

- *"that one item then waits on him, is on his TODO list, and blocks nothing else"* — the subject is **that one item**; what it does not block is what the next sentence enumerates: **the turn** (*"Rich may end his turn when every pending item is … waiting on something outside his reach (the CEO's word …)"*) and, by allowance 2, **the landing of the other pending items**.
- *"New work stays blocked either way"* — the subject is **new work**, and *"either way"* ranges over the two cases the preceding sentence just listed: waiting on something Rich started, or waiting on something outside his reach — the CEO's word included.

Read together: with only a CEO-word item pending, Rich may end his turn, other items still land, and nothing new starts until the CEO answers. That is a heavy consequence — a week of his silence is a week of no new work — but it is **his sentence**, adjacent to the other, in the same paragraph, and the specific sentence about new work governs the general "nothing else". There is no contradiction to settle and nothing for him to decide. In round 7 I turned Rich's inversion into "the CEO must say which sentence governs" instead of reading the paragraph to its end; that was my error, and the brief is right to retire it.

**But the build did not "assert neither" — it implemented the inversion.** Three measurements at `a0c1e1bd`:

1. C5.13 as it stands (`workspace-spec-fourteen.test.sh:792`) asserts `rc1=0 && rc2=0 && grep zach-opus-cw stop.out` — the wait is recorded, **the turn may end**, the item is named. It asserts one half and is silent on new work. "Asserts neither" is true only of the new-work question; §11 words it precisely.
2. `engine/scripts/lib/workspaces.py:1609`:
   ```
   "blocks_new_work": kind != "ceo-discard",
   "blocks_turn_end": kind not in ("ceo-discard", "started", "outside"),
   ```
   A `ceo-discard` wait is the ONE kind exempted from blocking new work. That is *"a CEO-wait item blocking new work"* treated as forbidden — the round-7 brief's line 90, in code.
3. A probe copy of the harness (`eng-probe`, the harness with two lines added after C5.13's fixture, nothing else changed; `RICHOS_FOURTEEN_SKIP_MUTANTS=1`):
   ```
   PROBE-ITEM7 new-work spawn during CEO-wait rc=0 ::
   PROBE-ITEM7 other item lands while CEO-wait pending: allowance-2 spawn rc=0 stop rc=0 o1_done=yes cw_done=no ::
   CHECKS RUN: 15  RED: 0 / FOURTEEN: 14 green, 0 red · self-check: green / exit: 0
   ```
   Unrelated new work **spawns** (`rc=0`) while `zach-opus-cw` waits on the CEO's word. Compare C5.12 on the same base: an outside-reach wait refuses the same spawn (`rw4=2`). The other-items half holds (`o1` lands, `cw` stays pending, the turn ends).

**So item 7 is: one token at `:1609` (`"blocks_new_work": True`), the C5.13 new-work sub-assertion (spawn refused, naming the item), and two mutants** — one restoring `kind != "ceo-discard"` (turns the new sub-assertion red), one making `blocks_turn_end` true for `ceo-discard` (turns the existing turn half red). The brief's "Do" is right about the assertions and silent about the code, and its headline says nothing here is a regression. It is — a round-7 mis-build from Rich's paraphrase.

---

## 4 · Every premise re-derived — items 2, 3, 5, 6

Sandbox: a throwaway `entity` and `devrepo` (the harness's own `new_repo`), `HOME`/`CLAUDE_CONFIG_DIR` redirected, a session started through `workspace-lifecycle.sh`, `dev/work` recorded for `devrepo` by the lead's own `workspaces.sh integration` call, and a sandbox worktree on `codex/fix` **of the sandbox repository**. Payloads fed to the REAL `guard-worktree-removal.sh` at `a0c1e1bd`, with and without `agent_id`, exactly as the harness's `agent_bash_guard`/`bash_guard` do. Script: scratchpad `r8-guard.sh`; output `r8/guard.out`.

### Item 2 — reproduced, and the list is short

```
=== ITEM 2: point-14 guard, RECORDED branch dev/work ===
AGENT  rc=0  git checkout -B dev/work
AGENT  rc=0  git switch -C dev/work
AGENT  rc=0  git fetch . HEAD:dev/work
AGENT  rc=0  git fetch . +HEAD:refs/heads/dev/work
AGENT  rc=0  git checkout dev/work                                   <- not in the brief
AGENT  rc=0  git switch dev/work                                     <- not in the brief
AGENT  rc=0  git branch -C cc/x dev/work                             <- not in the brief
AGENT  rc=0  printf 'update refs/heads/dev/work HEAD\n' | git update-ref --stdin   <- not in the brief
--- the four already-checked verbs (controls) ---
AGENT  rc=2  git branch -f dev/work HEAD        (REFUSED … RECORDED integration branch, from an agent's call … point 14)
AGENT  rc=2  git update-ref refs/heads/dev/work HEAD
AGENT  rc=2  git push . HEAD:dev/work
AGENT  rc=2  git branch -D dev/work
--- the lead's own calls (positive controls) ---
LEAD   rc=0  git checkout -B dev/work / git fetch . HEAD:dev/work / git branch -f dev/work HEAD
--- precision: an agent on a branch nobody recorded ---
AGENT  rc=0  git checkout -B side/scratch / git fetch . HEAD:side/scratch
```

The four the brief names pass, the four already-checked hold, the lead passes, precision holds. The four I marked are the ones my round-7 §6 listed as *"cheap widenings for round 8, in the order an honest agent would stumble into them"* — bare `checkout`/`switch` of the recorded branch is **how a merge into it actually happens** (`git checkout dev/work && git merge cc/…` is two verbs the guard sees separately, and the second is not a write to a ref name). §11 carries all eight, plus `symbolic-ref HEAD refs/heads/<it>`, which I measured passing in round 7 on the same bytes.

### Item 3 — reproduced, and "a commit" is the narrowest of the writes

```
=== ITEM 3: point 2, the WRITE side (sandbox codex/fix only) ===
AGENT  rc=0  git branch -f codex/fix HEAD
AGENT  rc=0  git push . HEAD:codex/fix
AGENT  rc=0  git update-ref refs/heads/codex/fix HEAD
AGENT  rc=0  git checkout -B codex/fix
AGENT  rc=0  git branch codex/new HEAD                (creating a codex/ ref)
AGENT  rc=0  git fetch . HEAD:codex/fix
AGENT  rc=0  git commit ... (cwd = sandbox codex/ workspace)
AGENT  rc=0  shell redirect write (cwd = sandbox codex/ workspace)
--- the deleters (must hold) ---
AGENT  rc=2  git branch -D codex/fix                  (… codex/ is never touched — point 2)
AGENT  rc=2  git worktree remove <sandbox codex-wt>   (a codex/ workspace … point 2)
AGENT  rc=2  rm -rf <sandbox codex-wt>
LEAD   rc=2  git branch -D codex/fix
--- the lead's writes (positive controls) ---
LEAD   rc=0  git branch -f codex/fix HEAD
```

And at the tool level, with a REGISTERED agent (spawn guard `rc=0`, native workspace, `SubagentStart` + Agent `PostToolUse` through the lifecycle hook; script `r8-guard2.sh`, output `r8/guard2.out`), through the catch-all `guard-sealed-worktree.sh` — the only hook that sees `Write`/`Edit`:

```
AGENT  rc=0  control: Edit inside its OWN native workspace
AGENT  rc=0  Write, file_path inside the sandbox codex/ workspace, cwd there
AGENT  rc=0  Edit, file_path inside the sandbox codex/ workspace, cwd its own
AGENT  rc=0  Bash with cwd = the sandbox codex/ workspace (catch-all only)
```

Every deleter holds (agent and lead), every write passes (agent), the lead's write passes. The brief's premise is exact. Its observable — *"an agent's write to any `codex/` ref or inside any `codex/` workspace is refused by name"* — is right, but `guard-worktree-removal.sh` is registered on `PreToolUse[Bash]` only (`hooks.json`), so an engineer who closes the git verbs there has closed nothing against `Edit`. §11 names the tool-level writes and the hook that must see them.

### Item 5 — both mutants survive the fourteen, reproduced

Four copies of `engine/` under the scratchpad (`r8-prep.py`): `clean` (unchanged), `mutA` (`_same_file` → `return True`, `workspaces.py:1736`), `mutB` (`if rec.get("handed_in"): return True, False, …` inserted BEFORE `end = rec.get("end")` in `finished_state`, `:947`), each run with `RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash …/workspace-spec-fourteen.test.sh`:

| copy | `CHECKS RUN` | `FOURTEEN` | `ok` lines | exit |
|---|---|---|---|---|
| clean | `15  RED: 0` | `14 green, 0 red · self-check: green` | 113 | 0 |
| mutA `_same_file` always True | `15  RED: 0` | `14 green, 0 red · self-check: green` | 113 | 0 |
| mutB handed-in finishes before the run ends | `15  RED: 0` | `14 green, 0 red · self-check: green` | 113 | 0 |

Why each is invisible, from the harness text: C8's `.env` reaches the main checkout by `cp "$NPU/.env" "$ENT/.env"` (`:574`), so the two files compared are always identical bytes — a same-name-different-bytes `.env` is never built; and `task_completed` is called exactly once in the harness (`:709`, C11.7), immediately followed by `subagent_stop`, so nothing ever asks the barrier or the gate about an agent that handed in and is **still running**. Both are the code being right and the checks not asking — the brief's framing is exact. The mutants' text for the harness's list is in §11.

### Item 6 — both halves confirmed by reading

- `engine/scripts/lib/workspaces.mutation.sh:188` declares `p14-nothing-bound-falls-back-to-current` with witness `"test_point_14_the_integration_branch_is_recorded_never_inferred"`; `workspaces.test.py:1303` is `test_point_14_a_record_bound_to_nothing_is_refused_never_guessed`. Both exist (`grep -n`). My round-7 §7/§10 measured the red landing at `:1303` under that mutant (`44/45`). One wording: the brief calls the `44/45` *"false"*. It is the **true** count under a wrong witness; what must not be carried is a round-8 report that treats it as acceptable. §11 says that.
- `engine/scripts/lib/agent-liveness.py:87`: `worktree-lock   AUTHORITATIVE. The only source that decides.` — present, verbatim. `hooks/guard-agent-state-claims.py:130` loads `agent-liveness.py`, so "the claim guard reads `finished_state`" is a real change of reader. My round-7 §8 ruling stands: neither spec nor build; a label that over-claims and a consumer answering a retired question. Note the third consumer is in the OTHER repository: femcboost `CLAUDE.md`, *"Liveness = the worktree lock"* — Rich's docs edit at cutover, not this engineer's (§9).

---

## 5 · Item 4 — the ruling on the allow-list

**Ruling: an allow-list, read from the row's own marker, never from the text; and yes — a deny-list of tags is always one platform shape away from this hole, and this machine already shows it.**

The evidence is the platform's own transcripts (read-only scan of the six newest `~/.claude/projects/-Users-alex-ab-femcboost/*.jsonl`, scripts `r8-transcripts2.py`/`r8-transcripts3.py`; `type == "user"` rows, tool results excluded):

| what began the turn | `origin` | `promptSource` | `isMeta` | text starts with |
|---|---|---|---|---|
| the CEO typing (312 rows) | `{"kind":"human"}` | `typed` | absent | his words |
| the CEO, queued while a turn ran (5) / accepted a suggestion (3) | `{"kind":"human"}` | `queued` / `suggestion_accepted` | absent | his words |
| a task notification (107) | `{"kind":"task-notification"}` | `system` | absent | `<task-notification>` |
| a teammate's message to the lead (18) | `{"kind":"peer","from":…,"body":…}` | `system` | **true** | `Another Claude session sent a message:\n<agent-message from="…">` |
| hook feedback (117) | absent | absent | **true** | `Stop hook feedback:` |
| SDK-driven prompts, `entrypoint: sdk-cli` (49) | absent | `sdk` | absent | a brief |
| `/login`, `/exit`, caveats (15) | absent | absent | mixed | `<command-name>`, `<local-command-stdout>`, `<local-command-caveat>` |

Present on every platform version in the corpus (2.1.266, .267, .268, .269): a human-typed row **always** carries `origin.kind == "human"`; nothing else ever does.

Three facts decide it:

1. **The deny-list at `workspaces.py:2975` already misses two live shapes on this machine.** The 18 teammate messages begin with `Another Claude session sent a message:` and `<agent-message …>`; the list has `teammate-message`. Those rows are excluded today only because `_turn_started_by_person` skips `isMeta` rows — a row-level marker, not the tag list. The engine's other list (`stop-live-work.py:148–161`) has fourteen entries including `<agent-message`, `<cross-session-message` and the `Another Claude session` prefix; the workspaces list has five. Two lists for one question, drifting, is the shape of the hole.
2. **A positive marker exists and the platform writes it.** `origin.kind == "human"` is the platform saying "a person typed this". Reading it is asking the platform the question, which is the discipline point 11 and point 12 already impose (*"the platform's own end-of-run signal"*, *"read from the operating system, never guessed"*).
3. **The failure direction is right.** An allow-list refuses the allowance on any shape it has not seen — a future `[SYSTEM NOTIFICATION - NOT USER INPUT]`, a new tag, a row with no `origin` at all. Refusing the allowance means Rich cannot end his turn while finished work is unlanded — which is point 5's default. A deny-list fails the other way: a shape it has not seen spends the CEO's allowance.

**The rule for the engineer (§11):** a turn "began with a message from a person" iff the row is `type == "user"`, not `isMeta`, carries `origin.kind == "human"`, and its content is text that is not a tool result. Rows with no `origin` key are not a person's turn. No tag list. The two shapes the brief names (`cross-session-message`, `[SYSTEM NOTIFICATION - NOT USER INPUT]`) become fixtures that must consume no allowance, alongside `agent-message`, `task-notification` and the `isMeta` hook-feedback row; the positive control is a row with `origin.kind == "human"`. And the stop-order half of allowance 1 is bound by the same test — a "stop" from a peer row is not his stop order.

---

## 6 · Anything of Rich's rather than the CEO's

| where | what | ruling |
|---|---|---|
| line 8 | *"pin never touched"* | **Rich's.** The CEO's rule is that the mirror is never read as the spec. The pin at `docs/verification/workspace-spec-implementation-2026-09-11.md:3` is `b3fd6cd33b8c1135`; the mirror and the page both hash `957d21a4…` (`shasum -a 256` on both, this session). Carrying "pin never touched" forward makes a wrong record permanent. The instruction that is the CEO's: the mirror stays byte-identical to the page (verified by hash), and the record that names it names the hash it has. |
| line 67–68 | *"The one allowance point 5 grants a reply to the CEO"* | **Rich's paraphrase** of a two-allowance sentence with a stop-order half. Replace with the sentence (§1). |
| line 22 | *"Nothing below is a regression"* | **Wrong for item 7** — `:1609` is a round-7 mis-build. Not a spec addition, but a premise an engineer will build on. |
| line 101 | *"the engineer then built C5.13 to assert neither"* | Imprecise: C5.13 asserts the turn half. Not Rich's rule, a wording. |
| line 90 | *"the false `44/45`"* | The count is true; the witness is wrong. Wording. |
| line 83 | *"The fourteen headings stay frozen"* | Process rule from the round-6 brief, Rich's, consistent with the CEO's page ("nothing added to it"). Fine. |
| item 7's reading | | **The CEO's**, and right (§3). |
| items 1–6 | | Findings, all traceable to a sentence of the page (points 14, 2, 5, 8, 11, and the runner's own rule). Items 4 and 5 appear in Rich's calls document as "verified by Rich"; `grep -c` on Frank's certification (no content read) gives `cross-session-message: 1`, `_same_file: 1`, `checkout -B: 3`, `switch -C: 3`, `codex/fix: 4`, so the brief's provenance line holds at string level. |

Nothing in the brief adds a requirement to the CEO's fourteen. The one thing that would have been added — his deciding point 5 — has been correctly removed.

---

## 7 · Is the CEO's decision list truly empty?

**Yes — but not for the reason the brief gives for one of the three, and one ledger row still says otherwise.**

| item the brief removes | brief's reason | my check |
|---|---|---|
| the killed-agent path | *"answered by his own point 11"* | **Holds.** *"Any ending that gives no such signal is handled at session end (point 12)"* is on the page and has been since `1ae0c081` (2026-09-11, before round 7). My round-7 §9 listed this as his question when the page already answered it; the brief corrects me. |
| the point-5 "contradiction" | Rich's paraphrase | **Holds** (§3). |
| the descoped probe | *"goes green when item 1's sibling fix lands"* | **Does not hold as stated.** Runner at `a0c1e1bd`, copied store (`r8-runner.sh`): `GREEN` ×8, `RETIRED` ×2, `RED` ×1 = `certification-frank-recorded-attribution-2026-09-12-probe.py`, exit 1 — the brief's headline numbers, reproduced. The escalation's own question (ledger row, not Frank's file): a ref created by a backgrounded process **after its own PostToolUse** is attributed to nobody. `record_end` (`workspaces.py:1300–1324`) calls `observe_created_refs(rec, all_open=True)`, which observes only windows still OPEN; with the last window consumed at its PostToolUse, `priors` is empty and nothing is compared (`_take_snapshots`, `:2039`). Nothing in items 1–7 touches this. |

**The descoped probe is not his decision either — it is engineering, and it is missing from the brief.** The page already governs it: point 3 (*"any branch an agent created"*) and point 9 (*"every process it started is stopped before its workspaces are deleted"*). The fix: at the end signal, after the open windows are consumed, diff the agent's repositories once more against `latest.json` (the last snapshot it took, `_latest_path`, `:1941`), and attribute what appeared — not `codex/`, not registered to another agent — to this agent; the bound the code already states applies (an over-attributed ref is measured at land time, where one already in the integration branch simply passes). Then the probe reads GREEN on the real manifest without anyone's word, Rich acks `esc-20260912T225456Z-d34bf4e6` with that disposition (`escalate.sh ack <id> --disposition …` — the row has no ack today, `escalate.sh show`), and the list is empty in the ledger as well as in the brief. §11 carries it as item 8.

**One decision exists downstream and should be prepared now, not discovered:** lifting *"nothing installed"*. He set that constraint on every round; the page says the dev branch reaches main *"when the work is certified and ready"*. Landing `dev/workspace-spec` to `main` and running `install.sh` on his machine is his word to give, once both reviewers certify. It is not a round-8 decision. It is the only one left.

---

## 8 · Is this the last round?

**Round 8 is the last BUILD round if it carries §11's text; as written it is not, because items 2, 3 and 7 each leave a proven-open door for round 9 to find.** After round 8:

1. **A certification pass** (both reviewers, same discipline) — a review, not a build. If §11's observables are met it ends CERTIFIED.
2. **The cutover** — Rich's, with the one CEO decision above: `dev/workspace-spec` → `main`, `install.sh`, the first live session under the new engine. That session's point-3/5/12 sweep meets the real machine, and the real machine today is (`git worktree list` from this worktree): two `.richos-retired/` quarantine trees at `37bb361c` and `a8fc4203`, detached reviewer trees (`frank-fable-b1`, `-b2`, `-c7`, …), two live `cc/` reviewer branches (mine and Frank's b3), five `codex/` trees (untouched by point 2, listed by name), and every row of the old `worktree-ledger.jsonl`. Each is finished work of an ended session and will be landed or discarded — and a discard of CEO-ordered work asks him (point 7).
3. **Two docs edits in the other repository**, Rich's, at cutover: femcboost `CLAUDE.md` *"Liveness = the worktree lock"* (item 6's third consumer) and the pin line.

**What would make round 9 a build round, and how to keep it from being one:** the sweep behaving differently on the real state than in the sandbox. That is cheap to know before cutover — one read-only rehearsal in round 8 (my recommendation, not a requirement of the page): the engineer runs the sweep's listing against a COPY of the real store and the real `git worktree list`, writes nothing, and reports what the first live session would land, discard, or ask about, by name. If that list is what Rich expects, round 9 does not exist.

---

## 9 · Census

Method: `find <dir> -type f | LC_ALL=C sort | while read f; do shasum -a 256 "$f"; done | shasum -a 256` — the same as rounds 6 and 7 so the records compare.

| | files | before my first command | after my last measurement (23:32:36Z) |
|---|---|---|---|
| `~/.claude/state/workspaces` | 5 | `aa2507954c2ca6ca62a61e58ea87fe48bca2653df966642795ba6d1a25b5b8e1` | `aa2507954c2ca6ca62a61e58ea87fe48bca2653df966642795ba6d1a25b5b8e1` |
| `~/.claude/state/workspace-retirement` | 11,286 | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` | `f56858924c3fa6014acc96affa7e77eacb7d393ec95bca113c13dc23823c27f6` |

Per-file lists diffed: `IDENTICAL` both. (The workspaces store had 4 files at my round-7 census and has 5 now — `refs/` appeared on 2026-09-12 13:44 between the rounds, before my first command; unchanged across this audit.) The runner ran against a COPY of the store (`RICHOS_WORKSPACES_DIR=<scratchpad>/r8/store-copy`), never the real one.

---

## 10 · What I ran, with exit codes

All from `/Users/alex/ab/richos-wt/sage-fable-b3` at `a0c1e1bd`, or from copies of its `engine/` under `<scratchpad>/r8/`. Scripts and outputs are beside each other there (`r8-guard.sh`/`guard.out`, `r8-guard2.sh`/`guard2.out`, `r8-prep.py` + `run-all.sh`/`fourteen-{clean,mutA,mutB,probe}.out`, `r8-runner.sh`/`runner.out`, `r8-transcripts{,2,3}.py`).

| what | command | verdict lines | exit |
|---|---|---|---|
| in-flight ack | `inflight-ack.sh --sha a0c1e1bd… --impact none` | `ack recorded: ~/.claude/state/inflight-acks.jsonl` | 0 |
| quotation check, normalizing + byte-strict | `python3` over the two files | §1 | 0 |
| guard, items 2 and 3, Bash level | `bash r8-guard.sh` | §4 | — |
| guard, item 3, tool level, registered agent | `bash r8-guard2.sh` | §4 | — |
| the fourteen, clean copy | `RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash eng-clean/scripts/workspace-spec-fourteen.test.sh` | `CHECKS RUN: 15  RED: 0` · `FOURTEEN: 14 green, 0 red · self-check: green` · 113 ok | 0 |
| the fourteen, mutant A / mutant B | same, `eng-mutA` / `eng-mutB` | identical headlines, 113 ok each — **both survive** | 0 / 0 |
| the fourteen, item-7 probe | same, `eng-probe` | `PROBE-ITEM7 new-work spawn during CEO-wait rc=0`; other item lands, turn ends | 0 |
| probe runner on the base | `RICHOS_WORKSPACES_DIR=<copy> python3 engine/scripts/workspace-probes.py --tree-only` | `GREEN` ×8, `RETIRED` ×2, `RED` ×1 (frank recorded-attribution), `DECLARED` ×1 | 1 |
| transcript scans, read-only | `python3 r8-transcripts{,2,3}.py` | §5 | 0 |
| escalation row | `escalate.sh show esc-20260912T225456Z-d34bf4e6`; `grep` on the ledger | `state: work-complete`, `for: ceo`, no ack | 0 |
| engine diff between rounds | `git diff --stat 44a7d5d4..a0c1e1bd -- engine` | empty | 0 |
| tips and worktrees | `git rev-parse --short main` / `dev/workspace-spec`; `git worktree list` | `dcabcbd9` / `a0c1e1bd`; §8 | 0 |
| census ×2 | §9 | identical | 0 |

**Not run:** the mutation harnesses (the two new mutants are measured by survival under the fourteen, which is the claim), the unit harness (round-7 §10 stands, same bytes), the full engine sweep.

---

## 11 · THE BETTER VERSION

Text Rich can lift. Everything the brief already has and I have not mentioned stays as it is; these replace or add.

---

**Replace line 8 with:**

The copy in `richos` is a mirror: never read as the spec, never edited. It is byte-identical to the page today (both `957d21a4…`) and stays so; the implementation record's pin line names the hash the mirror actually has — a docs-only line, corrected at the land.

**Replace line 22's last two sentences with:**

Six of the seven items are doors the build has not closed. **Item 7 is a door round 7 opened:** `workspaces.py:1609` implements Rich's inverted paraphrase, and its fix is one token plus the assertions. Item 8 is the escalation both reviewers' round closed on, resolved as engineering.

**Item 1 — replace the "Do" with:**

**Do (minimum):** an entry that was listed in the manifest at ANY commit and is NOT listed at HEAD is MISSING unless its author retired it — decided from the manifest alone, whatever file sits at the path. **Do (preferred, closes `return True` edits as well):** run every listed probe at the content the recorded integration branch's tip has, so nothing on the branch under test changes what runs until Rich lands it. Either way "asserting" is not a test; "listed" is. **Observable:** (a) a one-commit gut-and-delist reports `MISSING … listed in the manifest at <commit> and not listed at HEAD`, exit non-zero; (b) delete-and-delist still reports MISSING, exit non-zero; (c) gut-and-keep-listed still blocks (UNRUNNABLE/RED); (d) a per-case retirement signed by the author, landed on the recorded branch, still reads RETIRED; (e) a rename is a retirement plus a new listing, never silent.

**Item 2 — replace with:**

From an **agent's** call, all of these pass today against a RECORDED integration branch (`r8/guard.out`, `rc=0` each): `git checkout -B <it>`, `git switch -C <it>`, `git fetch . HEAD:<it>`, `git fetch . +HEAD:refs/heads/<it>`, **`git checkout <it>`, `git switch <it>`** (a merge into it is `checkout` then `merge` — two verbs the guard sees apart), **`git branch -C <x> <it>`**, **`git update-ref --stdin`** with `update refs/heads/<it>`, and `git symbolic-ref HEAD refs/heads/<it>`. The four verbs the guard already asks about hold (`rc=2`).
**Observable:** each of the nine is refused from an agent's call, naming point 14; each passes from the lead's; an agent's same verb on a branch nobody recorded passes; the existing four still hold. This is a tripwire over command text, like every guard in this engine — say so in the guard's header, and stop widening after this list.

**Item 3 — replace the second paragraph and the observable with:**

From an agent's call every WRITE passes today (`r8/guard.out`, `r8/guard2.out`): `git branch -f codex/<x> HEAD`, `git push . HEAD:codex/<x>`, `git update-ref refs/heads/codex/<x> HEAD`, `git checkout -B codex/<x>`, `git branch codex/<new> HEAD` (creation), `git fetch . HEAD:codex/<x>`; any Bash whose `cwd` is inside a codex/ workspace (a commit, a shell redirect); and — through the catch-all, the only hook that sees them — `Write`/`Edit`/`MultiEdit`/`NotebookEdit` whose `file_path` is inside a codex/ workspace, with the agent registered. Every deleter holds, agent and lead.
**Observable:** an agent's Bash naming a `codex/` ref as a write destination, or run with `cwd` inside a codex/ workspace, is refused by `guard-worktree-removal.sh` naming point 2; an agent's `Write`/`Edit`/`MultiEdit`/`NotebookEdit` with a `file_path` inside a codex/ workspace is refused by `guard-sealed-worktree.sh` naming point 2 (`workspace_kind` of the path's worktree top-level is `codex`); the lead's writes pass; a registered agent's `Edit` inside its OWN workspace passes (control); nothing `codex/` is ever deleted (the existing C2 sub-assertions stay green).

**Item 4 — replace with:**

`workspaces.py:2975` decides "a person's turn" by a deny-list of five tag names in the TEXT. On this machine's own transcripts (six newest, 2.1.266–2.1.269) that list already misses the shape teammate messages take today — `Another Claude session sent a message:` / `<agent-message …>`; those rows are excluded only because they happen to be `isMeta`. The engine's other list for the same question (`stop-live-work.py:148`) has fourteen entries. The page: *"Two things are always allowed, and only these two: answering the CEO or obeying his stop order (the reply names the pending work, which is handled right after); and work whose only purpose is getting the pending work landed."*
**Do:** an ALLOW-list read from the row: the turn began with a person iff the row is `type == "user"`, not `isMeta`, `origin.kind == "human"`, and its content is text, not a tool result. A row with no `origin` key is not a person's turn. No tag list. The same test binds the stop-order half.
**Observable:** turns begun by `origin.kind` of `task-notification` and `peer`, by a `[SYSTEM NOTIFICATION - NOT USER INPUT]` row, by a `<cross-session-message>` row, and by an `isMeta` hook-feedback row consume no allowance (five fixtures); a turn begun by a row with `origin.kind == "human"` and `promptSource` `typed` or `queued` does (positive controls); one mutant per fixture class.

**Item 5 — keep, and add the two mutants' text for the harness's list:**

`S-p08-same-name-different-bytes-lost`: `def _same_file(a, b):{NL}    try:` → `def _same_file(a, b):{NL}    return True{NL}    try:` — SPEC-DERIVED (point 8 negated): a `.env` the main checkout has with different bytes is deleted by a land that reports success. New sub-assertion under C8: the main checkout holds `.env` with OTHER bytes; the land is refused naming `.env`; after Rich keeps the workspace's copy the land proceeds and the bytes are the workspace's.
`S-p11-handed-in-finishes-before-the-run-ends`: insert `if rec.get("handed_in"):{NL}        return True, False, "handed in"` before `end = rec.get("end")` — SPEC-DERIVED (point 11 negated, *"'Finished' means the agent's run has ended"*): an agent is locked out and landable mid-run. New sub-assertion under C11: after `TaskCompleted` and BEFORE its `SubagentStop`, the barrier allows its `Edit` (`rc=0`) and the Stop gate does not list it as pending; after `SubagentStop` both flip (C11.7 as today).

**Item 6 — replace "the false `44/45`" with:** the `44/45` is the true count under a wrong witness and must not be carried into round 8's report as acceptable; after the one-token repoint the unit harness reads `45/45` or the report says why not.

**Item 7 — replace the "Do" with:**

**The code carries the inversion:** `workspaces.py:1609`, `"blocks_new_work": kind != "ceo-discard"` — measured: with one item waiting on his word, an unrelated spawn returns `rc=0`, while an outside-reach wait refuses it (C5.12). **Do:** `"blocks_new_work": True` (`blocks_turn_end` unchanged); C5.13 asserts BOTH — with `zach-opus-cw` waiting on his word, the turn may end (`rc=0`, as today), another finished item still lands, AND an unrelated spawn is refused naming `zach-opus-cw`; two mutants — `S-p05-ceo-wait-unblocks-new-work` restores `kind != "ceo-discard"`, `S-p05-ceo-wait-blocks-the-turn` adds `"ceo-discard"` to the turn-end block. Delete the harness header's sentence *"One clause is deliberately NOT asserted either way …"* and C5.13's comment; the page settles it.

**Add item 8:**

## 8 · A ref created after the agent's last PostToolUse is attributed to nobody

The one open escalation of round 7 (`esc-20260912T225456Z-d34bf4e6`, `--for ceo`, unacked), and the one `RED` on the real manifest today (`certification-frank-recorded-attribution-2026-09-12-probe.py`). `record_end` (`workspaces.py:1300–1324`) observes only windows still OPEN at the end signal; a ref created by the agent's own backgrounded process after its last PostToolUse consumed the window is compared against nothing and left behind. The page already governs it: *"any branch an agent created"* (point 3) and *"every process it started is stopped before its workspaces are deleted"* (point 9). Not the CEO's decision.
**Do:** at the end signal, after the open windows are consumed, diff the agent's repositories once more against its last snapshot (`latest.json`) and attribute what appeared (not `codex/`, not registered to another agent) to this agent; the code's own stated bound stands (an over-attributed ref that is already in the integration branch passes at land time). **Observable:** a ref created by a backgrounded process between the agent's last PostToolUse and its end signal goes with its work at the land and is refused by name if it reached no integration branch; the recorded-attribution probe reads GREEN on the real manifest, run by the lead after the land; Rich acks the escalation with this disposition. Mutant: remove the end-signal diff; the new sub-assertion under C3 (or C10) goes red.

**Add under "The bar, unchanged":**

Report the runner on the real manifest after the land: `RED 0, UNRUNNABLE 0, MISSING 0` or the round is not done.

**Add under "Standing constraints":**

An agent writing the store directly (`python3 -c … exec_module … record_integration`, `printf > integration.json`) passes every guard, because nothing on this machine separates an agent's process from Rich's. That is the accepted bound of a one-user machine; it is recorded here so it is not filed again. `HISTORY_LIMIT = 400` in the runner is a silent ceiling; print a line when it is reached.

**Replace "THE CEO'S DECISION LIST FOR THIS ROUND IS EMPTY" paragraph with:**

**THE CEO'S DECISION LIST FOR THIS ROUND IS EMPTY.** Three things were on it and none belongs there: the killed-agent path is answered by his own point 11 (*"Any ending that gives no such signal is handled at session end"*); the point-5 "contradiction" was Rich's paraphrase, not his page (item 7); and the descoped probe is a window hole the page already governs, fixed as item 8 and its escalation acked with that disposition. **The one decision left in this program comes after certification, not in this round:** lifting *"nothing installed"* — landing `dev/workspace-spec` to `main` and running `install.sh` on his machine once both reviewers certify. It is prepared now so it is asked once.

---

## 12 · Commits on `cc/sage-fable-b3`

1. this record (docs-only; `git diff --stat a0c1e1bd..HEAD -- engine` is empty).
