BRIEF NOT READY

# Frank — audit of the round-8 brief (the private richos-hq repository, plans directory, `round8-brief-2026-09-13.md` @ `c625742a`)

**Branch:** `cc/frank-fable-b3` · **worktree** `/Users/alex/ab/richos-wt/frank-fable-b3` · cut from `dev/workspace-spec` @ `a0c1e1bd3c17bc4957b0ea074684893227e05470` (round 7 landed; my round-7 certification and nine retirements landed with it). **The spec:** the CEO's fourteen sentences in `richos-hq` `docs/plans/worktree-spec-2026-09-11.md` @ `c663a823`; the mirror in this tree was neither read as the spec nor touched. **Sage's work was not read.** **Nothing installed, nothing left this branch:** no merge, no push, no `install.sh`, nothing written into `/Users/alex/ab/richos/engine`, no main checkout touched, nothing real under `codex/` touched — every `codex/` ref below lives in a `mktemp` repository that is deleted at the end of its script. Every run is sandboxed (`HOME`, `CLAUDE_CONFIG_DIR`, `RICHOS_WORKSPACES_DIR`, `RICHOS_SESSIONS_DIR` all under the scratchpad or `mktemp`), and the census (§11) is identical before and after.

Every number below was printed by a command I ran at `a0c1e1bd`; the scripts and their logs are under `scratchpad/b3/` (session scratchpad, paths in §12). Where I could not measure, the word is **UNVERIFIED**.

---

## 0. The verdict in seven lines

1. **Not ready, and the largest reason is mine to own: item 3's premise is false.** *"The deleters hold — nothing deletes `codex/`, and that is proven"* transcribes my round-7 line "every deleter holds", and I had tried two deleters. Five more pass the guard from an agent's call **and delete a `codex/` branch** at `rc=0` (§3). Point 2's FIRST sentence is broken at the guard, not merely its second sentence un-built. The framing "un-built, not broken" must go.
2. **Item 2's count is wrong in both directions.** My "four" were three verbs in four spellings; the true set of verbs that NAME the recorded branch and move it is **eight**, and beyond them is a **doorway class** — a plain `git checkout <it>` passes, after which `commit`, `reset --hard`, `merge`, `rebase` and `--amend` move the branch without ever naming it (§2). Enumerating verbs cannot close this; the effects-level fix the build already has the halves of can (§13).
3. **Item 4 is a real hardening but a constructed hole, and the brief sells it as an observed one.** In 2,589 persisted transcripts on this machine, every `[SYSTEM NOTIFICATION - NOT USER INPUT]` row (59/59) and every peer-message row (3/3) carries `isMeta: true`, which the code already excludes. **The allow-list as the brief words it would reject the CEO's own turns** — measured, not constructed: 128 of 512 person rows (the RichOS `sdk-cli` entrypoint) carry no `origin.kind`, and one real turn opens with `[Image #5] …` (§4).
4. **Item 5: the third mutant exists and so does a fourth.** F-G (point 9: the SIGKILL escalation removed) and F-H (point 8: same size called identical) both survive `14 green, 0 red`; F-A and F-F reproduce at `a0c1e1bd`. F-H is also the design constraint the brief's C8.8 needs: the fixture's two `.env` files must be the **same size** or F-H survives the new check too (§5).
5. **Item 6 holds as written** — witness token reproduced, liveness quotation matches `agent-liveness.py:87` (§6). **Item 7's reading is right and I can add the sentence that settles it**, but "the engineer built C5.13 to assert neither" is wrong on the record: C5.13 asserts the turn-may-end half today and abstains only on new work. The Do has three parts, not two (§7).
6. **The CEO's decision list is not empty on the brief's own terms.** Two removals are right (the killed-agent question was answered by a sentence that was on the page 14 hours before the question was asked; item 7). The third — *"the descoped probe goes green when item 1's sibling fix lands"* — is unsupported: that probe is red on the WINDOW (a ref created by a background process after its own PostToolUse), item 1 is about the manifest, and no item in the brief touches the window. Either the brief gains an item 8 that closes the window, which empties the list honestly, or the decision goes back to him (§8).
7. **This is not the last round.** The round-7 brief defined round 8 as *"Install and measure on `main` … the ONLY round 8."* This brief is not that round, so that round now exists as round 9, and I can name five things it must carry, three of which nobody has written down yet (§10).

---

## 1. Every quotation, checked mechanically

`python3` over the brief and the page, whitespace-normalized, blockquote prefixes stripped (`scratchpad/b3`, commands in §12):

| quotation in the brief | source | result |
|---|---|---|
| point 2, three sentences (item 3) | spec | **MATCH** — the only difference is the page's own `**` bold markup after the first sentence |
| *"Deletion therefore never loses anything that was meant to land."* (item 5) | spec point 8 | MATCH |
| *"An agent that ends after handing in its work is finished even if a pause was sent."* (item 5) | spec point 11 | MATCH |
| the point-5 paragraph from *"If the only way…"* to *"…either way."* (item 7) | spec point 5 | MATCH |
| *"New work stays blocked either way"* | spec point 5 | MATCH |
| **"Blocks nothing else"** (item 7, bolded fragment) | spec point 5 | the page reads `blocks nothing else` — capitalized in the brief. Meaning intact; by the brief's own rule ("quoted in full or not at all") write it lowercase |
| *"AUTHORITATIVE. The only source that decides"* (item 6) | `engine/scripts/lib/agent-liveness.py:87` | MATCH (`worktree-lock   AUTHORITATIVE. The only source that decides.`); `engine/scripts/agent-liveness.sh` is byte-identical to the installed one (`cmp` → identical) |
| *"a CEO-wait item blocking new work"* (item 7) | `round7-brief-2026-09-12.md:90` and `:213` | MATCH |
| `workspaces.py:2975` "filters a fixed tag list" | `sed -n 2975p` | MATCH — that line is the regex; the function opens at 2946 |
| `workspace-probes.py:645` `not exists_at(root, "HEAD", rel)` | `sed -n 645p` | MATCH |
| `workspaces.mutation.sh:188` | file is `engine/scripts/lib/workspaces.mutation.sh`, line 188 is the mutant | MATCH; path lacks `lib/` |

No paraphrase of the page survives in the brief. The two premises that are wrong (§2, §3) are wrong as **measurements**, not as quotations — they are my round-7 numbers transcribed faithfully.

---

## 2. Item 2 re-derived — "one git verb short" is not the shape of the hole

`scratchpad/b3/guard-try-3.sh` and `guard-try-4.sh`: each command is fed to `engine/scripts/hooks/guard-worktree-removal.sh` (sha256 `ca339e45…`, lib `7f0ee227…`, worktree `a0c1e1bd`) as an **agent's** Bash call with `dev/work` RECORDED in a sandbox store, and — new this round — **if the guard allows it, the command is executed** and the branch tip compared before and after. In round 7 I reported `rc=0` as "moves it" without executing; this time every "MOVED" line is a measured tip change.

**Verbs that NAME the recorded branch, pass the guard (`rc=0`) and move it (tip changed):**

```
  branch -C side dev/work                       MOVED   (-C/--copy: not in the guard's [fmMdD] set)
  push . HEAD:heads/dev/work                    MOVED   (dst spelled heads/…, guard compares only b and refs/heads/b)
  fetch . HEAD:dev/work                         MOVED
  fetch . +HEAD:refs/heads/dev/work             MOVED
  fetch . +side:dev/work                        MOVED
  pull . +side:dev/work                         MOVED   (pull takes fetch refspecs)
  checkout -B dev/work HEAD  /  checkout -B dev/work        MOVED
  switch -C dev/work  /  switch --force-create dev/work     MOVED
  symbolic-ref refs/heads/dev/work refs/heads/side          MOVED   (the branch becomes a symref)
  send-pack . HEAD:refs/heads/dev/work          MOVED   (the plumbing under push)
```

That is **eight verbs** (`branch -C`, `push` with an alternate destination spelling, `fetch`, `pull`, `checkout -B`, `switch -C`, `symbolic-ref`, `send-pack`), not four spellings of three. **Held (`rc=2`):** `branch -f/--force/-M`, `branch --copy --force` (the `--force` token is caught, `-C` alone is not), `update-ref` (both forms), `push` in its four other spellings, `push --delete`, `worktree add -B`.

**The doorway class, which no verb list can close.** The recorded branch is checked out nowhere in `richos` (the main checkout is on `main`), so a plain checkout of it succeeds anywhere:

```
  git -C $REPO checkout dev/work                                  rc=0  ran, unchanged
  git -C $REPO checkout dev/work && git commit --allow-empty -qm x   rc=0  MOVED
  git -C $REPO checkout dev/work && git reset -q --hard main         rc=0  MOVED
  git -C $REPO checkout dev/work && git merge -q --ff main           rc=0  MOVED
  git -C $REPO checkout dev/work && git rebase -q main               rc=0  MOVED
  git -C $REPO checkout dev/work && git commit --amend …             rc=0  MOVED
  git -C $AWT  checkout dev/work && git commit --allow-empty -qm x   rc=0  MOVED   (from the agent's OWN worktree)
```

`commit`, `reset`, `merge`, `rebase` and `--amend` never name the branch, so the guard's `recorded_integration_branches()` match has nothing to match. Two notes for the fix: a plain `git -C /Users/alex/ab/richos checkout dev/workspace-spec` from an agent also **moves the main checkout's HEAD off `main`**, which the IDE-visibility rule forbids independently; and the first of those seven lines is the one clause that closes the whole class — refuse an agent's plain `checkout`/`switch` of a recorded branch.

**Controls, as they must be:** the lead's `branch -f dev/work HEAD` and `checkout -B dev/work HEAD` → `rc=0`; an agent's `branch -f side HEAD~1` and `checkout -B side HEAD` on an unrecorded branch → `rc=0` (precision); `log --oneline -1` → `rc=0`. The two non-git rows (`printf` / `cp` into `.git/refs/heads/`) were inconclusive in my fixture (the sha I wrote was the branch's own tip) — I do not count them; that class was conceded in round 7 as unclosable by a text guard and is exactly why §13 proposes an effects-level check.

**Corrected wording for the brief's heading:** not "one git verb short" — *"the guard matches verbs that NAME the recorded branch; eight verbs that name it are unmatched, and a plain checkout opens a class that names nothing."*

---

## 3. Item 3 re-derived — a deleter is broken; the clause is not merely un-built

`scratchpad/b3/guard-try-4.sh`, with a fixture that cannot lie (round 7's could: `codex/fix` shared `main`'s tip and was checked out, so several writers were no-ops or stopped by git's own checked-out protection rather than by the guard). Here `codex/bare` is a `codex/` branch with **no** workspace and `codex/fix` is checked out in `$T/codex-wt`, both one commit behind `main`. Agent's call throughout; every `rc=0` row was executed.

**DELETERS of `codex/bare` — point 2's first sentence, *"never deleted without the CEO's express word"*:**

```
  git branch -D codex/bare                         rc=2  refused         (C2.2 holds)
  git branch -d codex/bare                         rc=2  refused
  git update-ref -d refs/heads/codex/bare          rc=0  DELETED  (a8c6056 -> gone)
  git push --delete . codex/bare                   rc=0  DELETED
  git push . :codex/bare                           rc=0  DELETED
  git push . :refs/heads/codex/bare                rc=0  DELETED
  git branch -M codex/bare not-codex-any-more      rc=0  DELETED  (renamed out of codex/: the ref is gone)
```

**Five deleters pass and delete.** The guard's `update-ref` and `push` clauses exist only for RECORDED branches (`guard-worktree-removal.sh:449–464`); its `branch` clause matches `-d/-D/--delete` against `codex/` but the `-M` rename clause matches only recorded branches. `push --delete` on the checked-out `codex/fix` is stopped by git's `receive.denyDeleteCurrent`, not by the guard — which is why round 7's two-verb test read "holds".

**MOVERS of `codex/bare` (a force-move orphans every commit on the branch — deletion in all but the verb):** `branch -f`, `branch -C`, `update-ref`, `push +`, `fetch +`, `checkout -B`, `switch -C`, `symbolic-ref`, and the doorway (`checkout codex/bare && commit`) — **all nine `rc=0` and all nine MOVED** (`a8c6056 -> 63769dc`, or `-> ac7afaa` for the commit).

**WORKING INSIDE the `codex/` workspace:** `git -C $CX commit --allow-empty` → `rc=0`, MOVED `codex/fix`; `cd $CX && printf … >> README && git commit -qam …` → `rc=0`, MOVED. (The `merge`/`reset`/`rebase` rows inside `$CX` read "unchanged" because my restore step reset the ref under the worktree between rows; the two commits already prove the sentence is open.) The Edit/Write hook (`guard-sealed-worktree.sh`) refused an Edit inside `$CX` — but with *"no registration"*, and it refused the agent's own worktree for the same reason; my sandbox never registered the agent, so that row is **inconclusive about `codex/`** and not counted.

**Ruling on the framing.** The brief says *"An un-built clause, not a broken one."* That was my sentence in round 7 and it was built on two deleters. With five deleters through, the first sentence of point 2 — the one with a mechanical incident behind it (`richos-hq/RICH-TODOs.md:148`: *"reads off disk is what killed the two agents. `codex/` is closed as a topic."*) — is **broken at the guard**, and the second sentence (*"never works inside"*) is un-built. Both. The observable in the brief is right; the label is wrong, and the label decides whether the harness must carry a RECORDED mutant for it (it must: the incident exists).

---

## 4. Item 4 re-derived — the hole is constructed, and the proposed allow-list rejects the CEO

**4.1 The function, reproduced** (`scratchpad/c8/ceo-turn.py` against this tree's `workspaces.py`):

```
<task-notification>                        -> person=False
<teammate-message> / <system-reminder> / <local-command-stdout>   -> person=False
<cross-session-message>                    -> person=True
[SYSTEM NOTIFICATION - NOT USER INPUT]     -> person=True
[Request interrupted by user]              -> person=True
```

Identical to round 7. **But that is the regex fed a string; the Stop gate reads a transcript** (`workspaces.py:3053`, `_turn_started_by_person(transcript_path)`), and the transcript stamps rows.

**4.2 What the persisted transcripts actually hold** (`scratchpad/b3/transcript-shapes-{2,3,5}.txt`; all `~/.claude/projects/**/*.jsonl`, 2,589 files, read-only):

- `[SYSTEM NOTIFICATION - NOT USER INPUT]` as the first text of a user row: **59 rows, all in subagent transcripts, all `isMeta: true`.** Zero in a main-session transcript. `_turn_started_by_person` skips `isMeta` rows (line 2962), so **no persisted instance of this shape ever reaches the regex.**
- `<cross-session-message`: **zero user rows begin with it anywhere.** The 986 "hits" are the SendMessage tool description inside `deferred_tools_record` attachment rows. A peer's message is persisted as a user row with `origin: {"kind": "peer", "from": "zach-opus-ci2", …, "body": "…"}` and **`isMeta: true`** (3/3 observed) — again excluded before the regex runs.
- So both shapes in item 4 are **SPEC-DERIVED / constructed**, not RECORDED. The brief's sentence *"The one allowance point 5 grants a reply to the CEO can therefore be spent by something the CEO never sent"* is **UNVERIFIED against every transcript on this machine and contradicted by the 62 rows that exist.** My round-7 §2.3 said "both strings are ones this session delivered to me today" — delivered to a subagent's context, where the rows are `isMeta`. That was my error of scope.

The hardening is still worth doing — a deny-list of five tags reads any unknown non-meta shape as a person, and the platform will add shapes — but the brief must label it constructed, and the observable's second half ("and by the `[SYSTEM NOTIFICATION …]` shape") should say the fixture row carries no `isMeta`, because a realistic one would be skipped for a different reason and the check would pass for the wrong reason.

**4.3 The allow-list, attacked with data.** The brief: *"Prefer an allow-list of what a person's turn looks like."* Two allow-lists a reasonable engineer would write, and what each rejects:

| allow-list | rejects | measured |
|---|---|---|
| **textual** — "a person's text starts with a letter / not `<` or `[`" | the CEO's own turn `[Image #5] you should be able to fetch it somewhere/somehow. My point is: the currently running agents might n…` (a pasted screenshot, then his words; `isMeta` absent) | 1 real row; 8 rows carry `imagePasteIds` |
| **stamped** — `origin.kind == "human"` | **every CEO turn through the RichOS app**: `entrypoint: sdk-cli`, `promptSource: sdk`, `origin` absent | **128 of 512** person rows |

The fields that DO separate a person's row from a platform row, over 512 person / 151 notification / 165 meta rows: person rows have `isMeta` absent (512/512), `queueSkipAttachments` absent (512/512), `promptSource ∈ {typed, sdk, queued}` (503/512; 6 absent, older rows), `origin` either `{kind: human}` (378) or absent (134). Notification rows have `origin.kind == task-notification` (151/151), `queueSkipAttachments: true` (151/151), `promptSource: system` (147/151). Peer rows have `isMeta: true` and `origin.kind == peer`.

**Ruling:** an allow-list is right **only if it is keyed on stamped fields with both sides measured against the corpus** — accept when `isMeta`, `isCompactSummary` and `queueSkipAttachments` are all absent AND `origin.kind` is `human` or absent AND `promptSource` is not `system`; and the fixture must be built from **real rows lifted from a transcript**, not from a tag typed into a JSON literal. A textual allow-list is a mistake the data already shows. This should be one sentence in the brief, because the engineer will otherwise write the textual one — it is the obvious one.

---

## 5. Item 5 — the two survivors reproduced, a third found, and a fourth that constrains the fix

`scratchpad/b3/xmut-b3.sh` (same contract as the harness's `mutate.py`: first occurrence, `{NL}` = newline, target must exist), each on a fresh copy of this tree's engine, the fourteen without mutants, own outer sandbox per run. "Survives" = `CHECKS RUN: 15  RED: 0 · FOURTEEN: 14 green, 0 red · self-check: green · exit: 0`.

| mutant | edit (diff in the log) | page sentence | result at `a0c1e1bd` |
|---|---|---|---|
| **F-A** | `_same_file` → `return True` (line 1737) | point 8 | **SURVIVES** — reproduced |
| **F-F** | `finished_state`: `handed_in` tested before `end` (lines 947–948) | point 11 | **SURVIVES** — reproduced |
| **F-G** (new) | `stop_processes`: `for p in alive:` → `for p in []:` (line 2874) — **the SIGKILL escalation removed** | point 9: *"every process it started is stopped before its workspaces are deleted"* | **SURVIVES.** C9.2–C9.4 use a `sleep` that dies on SIGTERM; nothing asks about a process that ignores TERM. Add C9.6: a holder started with `trap '' TERM` is dead after the land, and `processes-stopped` records no survivor |
| **F-H** (new) | `_same_file`: the sha1 comparison → `return True` after the size test (lines 1740–1741) — **same size means identical** | point 8 | **SURVIVES.** Same class as F-A, and it is the constraint on the brief's fix: **C8.8's two `.env` files must be the same size with different bytes** (a rotated key of equal length is the realistic case), or C8.8 turns F-A red and leaves F-H green |

Logs: `scratchpad/b3/xmut/F-{A,F,G,H}-*.txt`. Not run: the 59-mutant harness (95 minutes at this machine's load in round 7; I reproduced 59/59 then and nothing in this tree's mutation file changed since `44a7d5d4` — `git diff 44a7d5d4 a0c1e1bd --stat -- engine/` touches only `workspace-probe-retirements.tsv` and docs, UNVERIFIED by me this round beyond that diff).

**Corrected count for the brief:** "Two mutants survive" → **four**, two of them one class. The Do gains C9.6 and the same-size constraint on C8.8.

---

## 6. Item 6 — holds

**The token.** `scratchpad/b3/claim3-b3.sh` at `a0c1e1bd`: both witnesses pass unmutated (`2 run, 0 failed`); with `if work is None and chain:` → `if False:`, the DECLARED witness `test_point_14_the_integration_branch_is_recorded_never_inferred` still passes (`1 run, 0 failed`) and `test_point_14_a_record_bound_to_nothing_is_refused_never_guessed` fails (`AssertionError: 'bound to no body of work' not found in "… no branch is recorded …"`). Line 188 of `engine/scripts/lib/workspaces.mutation.sh` names the wrong witness; the property is pinned. The brief is right, including "the false `44/45` must not be carried" — the engineer's own §5 says the same (`round7-fixes-2026-09-12.md:90`).

**The liveness wording.** Quotation matches (§1). The ruling — the lock decides whether the SESSION that took it is running, never whether an agent is finished — is what I found in round 7 (claim 5) and it stands. One addition the brief leaves out: the instruction that sends Rich to this tool is in **femcboost's `CLAUDE.md`** ("Never state an agent's state from the roster — run `agent-liveness.sh`"), outside the engine and outside this round; correcting the engine's header without that line leaves Rich reading ALIVE for a finished agent from a file the round never touched. That belongs to round 9 (§10).

---

## 7. Item 7 — the reading is right, the record of C5.13 is wrong, the Do is three parts

**The reading.** The brief says the two sentences govern different objects. I can add the fact that settles it without interpretation: the last sentence's own parenthesis names this exact case — *"waiting on something outside his reach (**the CEO's word**, a service that is down); the latter goes on the CEO's TODO list. New work stays blocked either way."* The page anticipated an item waiting on the CEO's word and said, of that case, that new work stays blocked. So *"blocks nothing else"* cannot mean new work without making the next sentence false in the case it names; it means the things a pending item otherwise blocks under **"Enforced"** — the turn's end and Rich's handling of the other pending items. **No contradiction; not a decision; the reviewer who converted it into one was wrong, and so was the brief that first inverted it.**

**The record.** *"the engineer then built C5.13 to assert neither"* — no. `workspace-spec-fourteen.test.sh:792`: `C5.13 a discard that needs his word, asked and recorded with its TODO reference ($rc1): that item waits on him and the turn may end ($rc2)`. It asserts the turn half. Its comment (lines 45–47 and 787–790) abstains **only** on new work. The engineer's own words (`round7-fixes-2026-09-12.md:166`): *"C5.13 asserts what both sentences allow."*

**The Do, corrected.** C5.13 stays; add C5.14 (new work refused while the item waits on his word — the C5.12 shape with `--ceo`) and C5.15 (a SECOND pending item, landable, lands while the first waits on him — "blocks nothing else" made observable), each with a mutant. Spawn refusal for a `--ceo`-waiting item is already the code's behavior (`workspaces.py:1061–1074` blocks on any pending item regardless of `waiting.kind`), so C5.14 is a missing assertion, not a build — say so, or the engineer will look for code to write.

---

## 8. "THE CEO'S DECISION LIST FOR THIS ROUND IS EMPTY" — two removals right, one unsupported

| removed item | the brief's reason | ruling |
|---|---|---|
| the killed-agent path | "answered by his own point 11" | **RIGHT.** The question (*"Is 'handled at session end' acceptable for a killed agent?"*, round-7 brief line 190, committed `16f6cd25` at 2026-09-12 21:55) was answered by *"Any ending that gives no such signal is handled at session end (point 12)"*, on the page since `abd9cf84` at 2026-09-12 08:07 — fourteen hours before it was asked (`git log -S'handled at session end'`). Asking him to confirm his own sentence is the "search the record before asking" failure |
| the "contradiction" in point 5 | "Rich's paraphrase, not his page" | **RIGHT** (§7) |
| the descoped probe | "goes green when item 1's sibling fix lands" | **UNSUPPORTED, and on my record wrong.** The red is `certification-frank-recorded-attribution-2026-09-12-probe.py` cases `outside-stray` / `outside-side` (my round-7 §4): a ref created by a **background process after its own PostToolUse** is outside every attribution window — `created_branches []`, the land succeeds, the ref is left behind. Item 1 is the manifest-gutting rule; nothing in items 1–7 touches the window (`snapshot_refs` 2009 / `observe_created_refs` 2235). **The brief does not name the sibling fix.** The CEO put this case out of a *round's* scope (my runner-round §, "The CEO put it out of this round's scope"), never out of the spec; point 3's *"any branch an agent created counts as finished work"* is the sentence it tests |

**So the list is empty only if the brief gains an item 8** — close the window: at end-of-run (and at each window close), a ref that appeared since the agent's **latest** snapshot and whose tip carries the agent's own unlanded work (the criterion `observe_created_refs` already uses) is attributed to it; the two cases go green for their true reason; the runner exits 0 with no retirement. That is engineering, not a decision. Without item 8 the choice — fix the hole now, or retire the case on his word — is his, and removing it from his list denies him a decision I told him in round 7 was his.

---

## 9. What is Rich's rather than the CEO's

1. **"The deleters hold … proven"** — mine, transcribed; false (§3). Not the CEO's.
2. **"An un-built clause, not a broken one"** — mine, transcribed; wrong label (§3).
3. **"goes green when item 1's sibling fix lands"** — Rich's inference, unsupported (§8).
4. **"built C5.13 to assert neither"** — Rich's paraphrase of the engineer's *"asserts what both sentences allow"* (§7).
5. **"Prefer an allow-list…"** — an engineering direction, fine to give, but it is Rich's (via my round-7 hint) and as worded it produces a false negative the data already shows (§4.3). Keep it, key it on stamped fields.
6. **"Nothing below is a regression"** — true as far as the fourteen go; but the operator store the base will read is already not what the brief thinks it is (§10, item 9.2), which is not a regression either — it is a fact the brief does not know.
7. **"`workspaces.mutation.sh:188`"** — path lacks `lib/`; trivial.

Nothing in the brief adds a requirement the page does not carry. The four defects above are all **measurement** errors: three of them mine from round 7, faithfully carried. *A reviewer's number is a claim with a date on it* — this document is the re-derivation, and its own numbers carry their commands in §12.

---

## 10. Is this the last round? No — round 9 exists, and here is what is in it

The round-7 brief (`16f6cd25`, "Round 8 exists, and it is one round"): *"Install and measure on `main` with nothing running. Point 14's `main`-only consumers cannot be measured on the base, so they are unmeasurable until then. Folding the extra mutations and the third red into round 7 keeps that the ONLY round 8."* This brief is a fix round on `dev/workspace-spec`; nothing in it installs. So the install-and-measure round is now **round 9 at the earliest**, and the CEO — who has asked five times — should hear that the count moved and why (two reviewers refused round 7 on doors that did not exist on paper before).

**Round 9's contents, from what I measured this round and nobody has written down:**

1. **Install on `main`** (`install.sh`, sidecars, the probe's BR layers) and measure the fourteen, the 59+ mutants and the runner against the **installed** engine with nothing running — the round-7 brief's own definition.
2. **First contact with the real store, which is already dirty.** `~/.claude/state/workspaces/events.jsonl` holds **four rows written by a test fixture** (`"why": "the land-completeness fixture"`, repos under `/private/var/folders/…/T/land-completeness.*`, 2026-09-12T12:44Z) — some harness ran against the operator's store, which is the thing the census rule exists to catch, and it happened before round 7's census was taken (both my round-7 digests already contained them). And `agents/16a15be1…--zach-opus-d1.json` is a registration with `"end": null`, workspaces `deleted_at: null`, whose worktree `/Users/alex/ab/richos-wt/zach-opus-d1` **no longer exists** and whose session is this one. On install, point 12 will make it finished at this session's end and the next session must land or discard it "before anything else" — a record bound to nothing on disk. Round 9 starts by reconciling that store, and the fixture leak needs its harness named.
3. **The pause is a marker Rich must remember.** A pause is recorded only by a `SendMessage` carrying `pause-until:` or by `workspaces.sh pause` (`workspaces.py:48`, `3162–3175`). A "commit and hold" without the marker records nothing, and the agent's next end-of-run reads finished → landed and locked out, so the hold can never resume. Point 11 says *"Rich records every pause when he sends it"* and names *"the automatic pause at the CEO's 93% quota threshold"*; **no mechanism in the engine references that threshold** (`grep -rn '93\|quota'` → only prose in two guards). Whether a hold message without the marker is refused, or auto-recorded, is engineering; that it is currently a habit is the shape point 5 was written to forbid.
4. **femcboost's `CLAUDE.md` still sends Rich to `agent-liveness.sh`** to decide "finished" (§6). Item 6 corrects the engine's header; the instruction that reads it lives in another repository.
5. **The runner's witness** — my round-6 closure (print the recorded tip beside `origin/<branch>`, abstain on a non-operator store) was not built in round 7 and is not in this brief; the engineer's own honest wrapper is the shape of the bypass (round-7 §2.1). Measurable only once installed.

If round 8 lands its eight items and both reviewers certify, round 9 is the install round and, on this record, the last — unless the installed measurement finds what the base cannot show. That is the true answer to "how much longer": **two rounds, not one, and the second is the one that was promised as the only one.**

---

## 11. Census — before the first command, after the last

Method: sorted per-file sha256 of every file, then sha256 of that list (`scratchpad/census-before.txt`, `census-after.txt`); `workspace-retirement` is 11,286 files, so the loop takes minutes and I ran it both times.

| | before (2026-09-12T23:16:38Z, after the ack and before any other command) | after (2026-09-12T23:36:17Z) |
|---|---|---|
| `~/.claude/state/workspaces` | `fa74f1e6812e6776c2335ae1cbc032817f6e143328ba31dd602e92f93d2c5bd4` (5 files) | `fa74f1e6812e6776c2335ae1cbc032817f6e143328ba31dd602e92f93d2c5bd4` (5 files) |
| `~/.claude/state/workspace-retirement` | `67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1` (11,286 files) | `67a8504ac1cd16e167a5b2bf63e925f5c0147b5be3b4ec08d92b221f018118f1` (11,286 files) |

`diff` → IDENTICAL. **Not equal to round 7's digests** (`8ce85db9…`, 4 files; `f5685892…`): between my round-7 after-census (22:51Z) and this round, `integration.json` was created (Rich recording `dev/workspace-spec` as `richos-001` at 22:57:06Z — correct, point 14) and `retirements.jsonl` changed under round 7's landing. The inflight ack (`~/.claude/state/inflight-acks.jsonl`) is outside both directories.

---

## 12. What I ran, with exit codes

| command (from `/Users/alex/ab/richos-wt/frank-fable-b3` unless noted) | exit | log |
|---|---|---|
| `inflight-ack.sh --sha a0c1e1bd… --impact none --paths none --repo /Users/alex/ab/richos` | 0 | ledger row |
| census, before | 0 | `scratchpad/census-before.txt` |
| `bash scratchpad/b3/guard-try-3.sh` (recorded-branch verb space + doorway, executed) | 0 | `scratchpad/b3/guard-try-3.txt` |
| `bash scratchpad/b3/guard-try-4.sh` (codex/ deleters, movers, inside-workspace, executed) | 0 | `scratchpad/b3/guard-try-4.txt` |
| `python3 scratchpad/c8/ceo-turn.py engine/scripts/lib/workspaces.py` | 0 | `scratchpad/b3/ceo-turn-b3.txt` |
| transcript censuses (read-only over `~/.claude/projects`) | 0 | `scratchpad/b3/transcript-shapes-{1..5}.txt` |
| `bash scratchpad/b3/xmut-b3.sh F-A … / F-F … / F-G … / F-H …` | 0 each (each `FOURTEEN: 14 green, 0 red`, i.e. the mutant survived) | `scratchpad/b3/xmut/*.txt` |
| `bash scratchpad/b3/claim3-b3.sh` | 0 (declared witness passes mutated; the other fails) | `scratchpad/b3/claim3-b3.txt` |
| quotation checks (`python3`, `richos-hq`) | 0 | §1 |
| `git log -S'handled at session end' -- docs/plans/worktree-spec-2026-09-11.md` (`richos-hq`) | 0 → `abd9cf84 2026-09-12 08:07:22 +0100` | §8 |
| census, after | 0, IDENTICAL | `scratchpad/census-after.txt` |

Nothing here ran the 59-mutant harness, the e2e suite, the guard suite or the runner; the round-7 numbers the brief carries for those (113 / 59 / 21 / 38 / `GREEN 8, RETIRED 2, RED 1`) are the ones I reproduced or read in round 7 and are not re-derived here.

---

## 13. THE BETTER VERSION

Text Rich can lift. Replaces the brief's items 2, 3, 4, 5, 7, the decision-list paragraph, and adds items 8 and the round-9 line. Items 1 and 6 stand as written (item 6: add the femcboost `CLAUDE.md` pointer to round 9).

> ## 2 · The point-14 guard matches verbs that NAME the recorded branch — eight that name it are unmatched, and a plain checkout opens a class that names nothing
>
> Frank's, executed this time, not only fed to the guard (`brief-audit-frank-round8-2026-09-13.md` §2). From an **agent's** call against a RECORDED branch, each of these passes (`rc=0`) **and moves the branch**: `branch -C <x> <it>`, `push . HEAD:heads/<it>`, `fetch . <x>:<it>` (and `+…`), `pull . +<x>:<it>`, `checkout -B <it>`, `switch -C <it>` / `--force-create`, `symbolic-ref refs/heads/<it> …`, `send-pack . HEAD:refs/heads/<it>`. And a plain `git checkout <it>` / `switch <it>` passes, after which `commit`, `reset --hard`, `merge`, `rebase` and `commit --amend` move it without naming it — from the agent's own worktree or, worse, from the main checkout, which also takes the main checkout off `main`.
>
> **Do:** (a) refuse an agent's plain `checkout`/`switch` of any recorded branch — that one clause closes the doorway class; (b) add the eight named forms, matching any destination spelling that resolves to the branch (`<it>`, `heads/<it>`, `refs/heads/<it>`); (c) **the effects check**: the build already snapshots refs at an agent's PreToolUse and observes at PostToolUse (point 3's window) — at the PostToolUse half, if any RECORDED branch's tip differs from the snapshot in an agent's call, restore it from the snapshot and report the call by name. (c) is what makes (a) and (b) not a losing game against git's verb list and closes the non-git writes too. **Observable:** every form above is refused or reverted from an agent's call and allowed from the lead's; an agent's move of an unrecorded branch still passes.
>
> ## 3 · Point 2 is BROKEN on the delete side and un-built on the write side
>
> > *"A `codex/` workspace or branch is never deleted without the CEO's express word. An agent never works inside a `codex/` workspace; it works from a copy in its own `cc/` workspace. Landing never deletes anything `codex/`."*
>
> Frank's, executed (§3). Round 7 said "every deleter holds" on the strength of two deleters. **Five more pass from an agent's call and delete a `codex/` branch:** `update-ref -d refs/heads/codex/<x>`, `push --delete . codex/<x>`, `push . :codex/<x>`, `push . :refs/heads/codex/<x>`, `branch -M codex/<x> <not-codex>`. Only `branch -d/-D`, `worktree remove` and `rm -r` are refused. Nine movers (`branch -f/-C`, `update-ref`, `push +`, `fetch +`, `checkout -B`, `switch -C`, `symbolic-ref`, checkout-then-commit) rewrite a `codex/` ref, and a commit inside a `codex/` workspace lands on its branch. The incident behind the first sentence is recorded (`RICH-TODOs.md:148`), so this item carries a RECORDED mutant, not only SPEC-DERIVED ones.
>
> **Do:** every deleter and mover the guard knows for recorded branches applies to `codex/` refs, plus the five above; an agent's `git -C <codex workspace>` / `cd <codex workspace> &&` with any writing subcommand is refused by name; and the same effects check as item 2(c): a `codex/` ref that is gone or moved after an agent's call is restored from the snapshot (its objects survive) and reported. **Observable:** each of the five deleters and nine movers is refused or reverted; the lead's are not; `codex/` is byte-identical after the whole set (C2.6's hash, asked AFTER these, not only after the fixture's deleters).
>
> ## 4 · A shape that is not a person can start a turn that counts as the CEO — constructed, and the fix is a stamped-field rule
>
> `workspaces.py:2975` deny-lists five tags; any other non-meta user row reads as a person. **This is SPEC-DERIVED, not RECORDED:** in 2,589 persisted transcripts every `[SYSTEM NOTIFICATION - NOT USER INPUT]` row (59) and every peer-message row (3) carries `isMeta: true`, which the code already skips; no user row begins with `<cross-session-message` (§4.2). The hole is the next shape the platform adds.
>
> **Do:** replace the tag list with a rule on the fields the platform stamps, measured on this machine's corpus (§4.3): a person's row has no `isMeta`, no `isCompactSummary`, no `queueSkipAttachments`, `promptSource` not `system`, and `origin.kind` either `human` or absent. **Two false negatives the obvious allow-lists produce, both real rows:** a textual rule rejects the CEO's `[Image #5] …` turn; `origin.kind == "human"` alone rejects **128 of 512** of his turns (the RichOS `sdk-cli` entrypoint carries no `origin`). **Observable:** a fixture built from real rows lifted from a transcript — one `human`-origin turn, one `sdk-cli` turn with no `origin`, one `[Image …]` turn all count as the CEO; a `task-notification` row, a peer row, a constructed non-meta `<cross-session-message>` row and a constructed non-meta `[SYSTEM NOTIFICATION …]` row do not; the two constructed rows are labeled constructed in the check's name.
>
> ## 5 · Four mutants survive the fourteen — the code is right, the checks miss it
>
> - **`_same_file` forced always-True** (F-A) and **the sha1 comparison removed so same size means identical** (F-H): a `.env` with the same name and different bytes is deleted by a land that reports success. Point 8. **Do:** C8.8 — same name, **same size**, different bytes, holds the land (the size constraint is what makes F-H red too).
> - **handed-in-finishes-before-the-run-ends** (F-F): locked out and landable mid-run. Point 11. **Do:** C11.8 — between TaskCompleted and its own SubagentStop the agent may still write and nothing is pending.
> - **the SIGKILL escalation removed** (F-G, `stop_processes` line 2874): a process that ignores TERM survives the land. Point 9: *"every process it started is stopped before its workspaces are deleted."* **Do:** C9.6 — a holder started with `trap '' TERM` is dead after the land and `processes-stopped` records no survivor.
>
> All four added to the harness's list. The fourteen headings stay frozen.
>
> ## 7 · Point 5 has no contradiction — assert all three parts
>
> [the paragraph quoted in full, as now] … The page settles it in its own parenthesis: the case that waits on *"the CEO's word"* is named in the sentence that says *"New work stays blocked either way."* So *"blocks nothing else"* is the turn and the other pending items; *"new work stays blocked"* is new work. **C5.13 already asserts the turn half** (line 792) and abstains only on new work. **Do:** keep C5.13; add C5.14 (new work refused while the item waits on his word — the C5.12 shape with `--ceo`; the code already refuses, this is a missing assertion) and C5.15 (a second, landable pending item lands while the first waits on him), each with a mutant.
>
> ## 8 · A ref created outside every window is left behind — the one red probe, closed rather than retired
>
> `certification-frank-recorded-attribution-2026-09-12-probe.py` cases `outside-stray` / `outside-side` are red because a ref created by a background process after its own PostToolUse is attributed to nobody (`created_branches []`) and survives the land. Point 3: *"any branch an agent created … counts as finished work."* **Do:** at each window close and at end of run, a ref that appeared since the agent's latest snapshot and carries the agent's unlanded work (the criterion `observe_created_refs` already applies) is attributed to it. **Observable:** both cases HOLD; the runner reads `GREEN 9, RETIRED 2, RED 0` and exits 0; no retirement line is written.
>
> **THE CEO'S DECISION LIST FOR THIS ROUND IS EMPTY** — because item 8 closes the hole he was going to be asked about, the killed-agent question was answered by a sentence on his page fourteen hours before it was asked, and point 5's "contradiction" was a paraphrase (item 7).
>
> **This is not the last round.** Round 7's brief promised round 8 as the install-and-measure round; this is a fix round, so the install round is round 9, and it carries: the install and measurement on `main`; reconciling the operator store, which already holds four fixture-written rows and a registration whose worktree is gone; making a pause a recorded fact rather than a marker Rich must remember (no mechanism implements the 93% pause the page names); the femcboost `CLAUDE.md` line that still sends Rich to `agent-liveness.sh` for "finished"; and the runner's witness. Two rounds, then done — if round 8 certifies.
