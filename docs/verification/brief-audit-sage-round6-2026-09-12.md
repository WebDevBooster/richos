BRIEF NOT READY

# Brief audit — round 6, "every one of the CEO's fourteen points gets an observable check"

**Brief audited:** `/Users/alex/ab/richos-hq/docs/plans/round6-brief-fourteen-points-2026-09-12.md` @ `095ab795`
(`git -C /Users/alex/ab/richos-hq log -1 --format=%H -- docs/plans/round6-brief-fourteen-points-2026-09-12.md`
→ `095ab7950634fe91e3fd3128ae0b7b87d82d9ac3`).
**Spec:** `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md` (109 lines, fourteen numbered points).
**Reviewer:** sage-fable-b1, worktree `/Users/alex/ab/richos-wt/sage-fable-b1`, branch `cc/sage-fable-b1`, cut from
`main` @ `dcabcbd99056928a9872cd94c1f3a385f8b21069`.
**Nothing installed, nothing merged, nothing pushed.** Every command below was run from this worktree, from a
`git archive` copy of `dev/workspace-spec @ c5bce604` in the session scratchpad, or read-only against
`~/.claude/state`. The two workspace stores hash identically before and after (section 11).

## 0. The verdict in one paragraph

The brief holds property 1 (fourteen items, nothing invented) and fails properties 2 and 3. But the reason it is
not ready is larger than either: **it measures two different trees and three different stores without naming
any of them, and the scoreboard it asserts is a scoreboard of the installed `main` engine, which the branch the
round is cut from deletes wholesale.** Points 3, 6, 12 and 14 are read off a store (`~/.claude/state/workspaces/`)
that only `dev/workspace-spec` writes and that was installed for 31 minutes last night; its emptiness since is
"not installed", not "registration is not happening". Points 4, 10 and 13 are read off tools
(`reconcile-terminal-worktrees.py`, `remove-agent-worktree.sh`, `workspace-retire.py`) that do not exist on
`c5bce604`. And four of the five "never measured" points have committed, green, sandboxed checks on `c5bce604`
that the brief's author did not run — I ran them: **58/58 unit, 47/47 end to end.** Section 8 carries the
corrected brief material under the heading Rich asked for.

---

## 1. Property 1 — the item count is FOURTEEN

**HOLDS.**

```
$ python3 verbatim.py          # scratchpad script; extracts every "### N. *"…"*" heading
numbered ### items in brief: 14 ['1', '2', … '14']
all ### headings in brief: 14
H1/H2 headings: [title, 'What this round is…', 'Why this scope…', 'The acceptance bar…',
                 'How state was measured…', 'THE FOURTEEN', 'Scoreboard…', 'What is NOT in this round']
```

Every `###` heading is one of his numbered points, in order, none repeated, none added. The two non-point
sections ("How state was measured", "What is NOT in this round") are not items and do not claim to be. No
"item 4" of this morning's kind is present.

One adjacent fact the round must know: the branch's own records say **thirteen**. Both files below live on
`dev/workspace-spec` @ `c5bce604` and are not in this tree: the registry library `workspaces.py` (under the
engine's `scripts/lib/`), line 4: *"(thirteen points)"*; and that branch's implementation record,
`workspace-spec-implementation-2026-09-11.md` (under its `docs/verification/`), heading: *"## The thirteen
points"*. Point 14 was added to the spec after that record was written (`0a915c2d`, `ecab4679`). The brief is right at fourteen; the
tree it builds on still counts to thirteen in two places, and a runner that reads either will judge the wrong
number.

## 2. Property 2 — every item quotes his sentence VERBATIM

**FAILS — two character-level defects, both in point 11, plus a pattern that invites the next paraphrase.**

Method: split each quotation on `…`, normalize whitespace and strip `**`, and require every fragment to be a
verbatim substring of that point's paragraph in the spec, in order.

```
POINT 11: FRAGMENT NOT VERBATIM IN ITS PARAGRAPH:
   "'Finished' means the agent's run has ended and Rich did not pause it"
POINT 11: FRAGMENT NOT VERBATIM IN ITS PARAGRAPH:
   'A pause names what ends it; a pause with nothing named counts as pending work under point 5.'
verbatim defects: 2
```

- **11a.** Spec: `"Finished" means …` (double quotes). Brief: `'Finished' means …` (single quotes). A character
  substitution, made so the quotation could sit inside `*"…"*`.
- **11b.** Spec: `A pause names what ends it (the quota reset, the CEO's answer); a pause with nothing named …`.
  Brief drops `(the quota reset, the CEO's answer)` **with no ellipsis**. A silent elision — his two worked
  examples of what ends a pause are gone from the sentence the check is written against.

Points 1, 2, 4, 10 and 13 are quoted in full and match exactly. Nine of fourteen are elided with `…`; each
surviving fragment is verbatim, but the ratio is the risk:

| point | quoted / total chars | what the elision removed |
|---|---|---|
| 3 | 329 / 567 | the sentence the check's fourth clause is written from ("A `cc/` or native workspace with no registration … is handled under point 5") |
| 5 | 194 / 1356 | both allowed exceptions and the turn-end rule — the check then paraphrases them |
| 7 | 271 / 732 | "an agent that produced nothing counts as landed" — the check then paraphrases it |
| 11 | 288 / 1072 | see 11b |
| 12 | 233 / 548 | "While two sessions run at once, each handles only the agents it started" |
| 14 | 397 / 1090 | the dev-branch mechanism — the reason point 14 exists |

Ruling: an ellipsis is honest when each fragment is exact, and these are (except 11). But the point of quoting
his sentence is that the CEO can spot-check the brief **without opening the spec**, and a 14% quotation of point 5
cannot be spot-checked that way. The better version (section 8) quotes every point in full; the spec is 109 lines
and the brief has the room.

## 3. Property 3 — every factual claim carries the command and its output

**FAILS.** The "How state was measured" block is the right shape and is the only place the shape appears.
Claims without a command, or with a command but no output, or with output but no tree:

| where | claim | what is missing |
|---|---|---|
| header | "Cut from `dev/workspace-spec` @ `c5bce604`" | true (`cat /Users/alex/ab/richos/.git/refs/heads/dev/workspace-spec` → `c5bce604b6cd…`), but **no command says which tree the five measurement commands ran in**. Three ran against `main`'s tools, two against `dev`'s store. |
| measured block | `ls -d /Users/alex/ab/*-wt/*/` → "… 11 directories, listed under point 1" | output replaced by a summary; and the glob cannot see `~/.codex/worktrees/…` (section 4.1) |
| point 1 | "Seven more are `codex/`" | no command; the same block's own reconciler line says `excluded=9` — the two numbers disagree inside one brief and nobody noticed |
| point 3 | "while at least four agents ran" | no command. The ledger says **24** (section 4.2) |
| point 4 | `remove-agent-worktree.sh` renames into `.richos-retired/`; `retire-branch` refuses `within-retention` then `branch-checked-out`; `sweep --execute` refuses `automatic-erasure-disabled` | no commands, no output; and all three tools are **deleted on `c5bce604`** (section 4.5) |
| point 4 | "Today Rich deleted three landed branches by hand" | no command, no artifact; unverifiable from anything on disk |
| point 9 | "the 2026-07-18 zombie-residue class … has a recorded failure to derive mutations from" | `grep -n '2026-07-18' richos-hq/docs/verification/lifecycle-failure-record-*.md` → **no match**. It is in femcboost `CLAUDE.md`, not in the record series the bar names |
| point 10 | "`ws-71d9662ef3071ece`, `ws-79d49f8b63928424` in `workspace-retire.py list`" | command named, output absent, store unnamed (it is a third store, `~/.claude/state/workspace-retirement/`) |
| point 12 | `ls ~/.claude/sessions/ \| wc -l` → **2** | output is real; the reading is not. The two entries are `24267.json` and `24267.…key` — **one** session, two files |
| point 13 | "come back from the automatic lane as `NOT-EXAMINED …`" | no command (it is in the `--preview` output the block already ran, but the brief does not say so) |
| point 14 | `guard-unresolved-claims.sh` asks `merge-base --is-ancestor <sha> main` | no command; true on `main` (`engine/scripts/hooks/guard-unresolved-claims.py:1433`), **already changed on `c5bce604`** (`f0ee9622`) |
| acceptance bar | `docs/verification/lifecycle-failure-record-*.md` | no repository named. They are in `richos-hq`; the engineer works in `richos`, where the path does not exist |

---

## 4. Every premise, re-derived

### 4.1 Point 1 — the four non-`cc/` worktrees

**Survives, with two corrections to the enumeration.**

```
$ python3 trees.py     # reads each tree's link file and the linked HEAD; no git command
claude-orchestration-kit-wt/zach-opus-dor1 | claude-orchestration-kit/…/worktrees/zach-opus-dor1 | ref: refs/heads/zach-opus-dor1 | locked= False
claude-orchestration-kit-wt/zach-opus-dor2 | … | ref: refs/heads/zach-opus-dor2 | locked= False
deeply-wt/zach-opus-dor1                   | deeply/…/worktrees/zach-opus-dor1  | ref: refs/heads/zach-opus-dor1 | locked= False
deeply-wt/zach-opus-dor2                   | … | ref: refs/heads/zach-opus-dor2 | locked= False
```

Real git worktrees, not `.claude/worktrees/agent-*`, on branches that are neither `cc/` nor `codex/`. The
verdict "FAILS" stands. Two corrections:

1. **`ls -d /Users/alex/ab/*-wt/*/` is not an enumeration of non-native workspaces.** `git worktree list` in
   femcboost shows two codex worktrees the glob cannot see:
   ```
   /Users/alex/.codex/worktrees/06e6/femcboost   db84346a2 [codex/structural-failure-report]
   /Users/alex/.codex/worktrees/67ec/femcboost   5586dada4 [codex/inherited-publication-failure-report]
   ```
   That is the whole 7-vs-9 discrepancy: 7 codex directories under `*-wt/` + 2 under `~/.codex/` = the
   reconciler's `excluded=9`. Point 1's check must enumerate from `git worktree list --porcelain` per
   repository, never from a directory pattern.
2. **The repositories are not enumerated either.** The dev store's `repos.json` names two:
   ```
   $ cat ~/.claude/state/workspaces/repos.json
   {"repos": ["/Users/alex/ab/richos", "/Users/alex/ab/femcboost"]}
   ```
   The four violations are in `claude-orchestration-kit` and `deeply`, which no store knows. "Every non-native
   workspace on this machine" needs a stated repository inventory or the check is only ever as wide as the last
   registration.

### 4.2 The store — one record, three empty directories: is Rich reading the wrong store?

**Yes. This is the load-bearing error, and points 3, 6 and 12 fall together, as the brief's spawn prompt feared.**

Three facts, each from one command:

```
$ grep -rl 'state/workspaces' engine/                     # on main @ dcabcbd9 (this worktree)
(exit 1 — zero files)
$ grep -rl 'state/workspaces' engine/                     # on dev @ c5bce604 (scratchpad archive)
engine/scripts/lib/workspaces.py  engine/scripts/workspaces-e2e.test.sh  engine/scripts/land-completeness.test.sh  … (10 files)
$ ls -la ~/.claude/richos-engine
~/.claude/richos-engine -> /Users/alex/ab/richos/engine
$ cat /Users/alex/ab/richos/.git/HEAD ; cat /Users/alex/ab/richos/.git/refs/heads/main
ref: refs/heads/main
dcabcbd99056928a9872cd94c1f3a385f8b21069
```

So the installed engine is `main`, and `main` never writes `~/.claude/state/workspaces/`. Only `dev` does. Then
why one record? The main checkout's reflog:

```
$ tail /Users/alex/ab/richos/.git/logs/HEAD      # epochs converted with date -u -r
2026-09-11T23:39:24Z  merge cc/zach-opus-page1              -> dcabcbd9
2026-09-11T23:49:36Z  reset: moving to origin/main          -> d39e49d9   (the spec build)
2026-09-11T23:49:40Z  commit: Main returns to the first build d39e49d9 …
2026-09-12T00:13:46Z  commit: Main returns to dcabcbd9's engine: the workspace spec must not be installed while sessions are running
2026-09-12T00:21:07Z  reset: moving to dcabcbd9
```

The spec build WAS the installed engine from 23:49:40Z to 00:21:07Z. The single record:

```
$ cat ~/.claude/state/workspaces/agents/16a15be1-…--zach-opus-d1.json
 "registered_at": "2026-09-11T23:57:34Z",  "source": "create-teammate-worktree",  "agent_id": "",  …
```

23:57:34Z is inside the window. `zach-opus-d1` was the only spawn during those 31 minutes; it is registered in
the dev store and in nothing else (`grep -c zach-opus-d1 ~/.claude/state/worktree-ledger.jsonl` → **0**).
Everything since went to the installed engine's store:

```
$ python3 - (histogram of ~/.claude/state/worktree-ledger.jsonl rows dated 2026-09-12)
today rows 984   [('finished', 912), ('registered', 48), ('prepared', 24)]
registered zach-opus-f4  /Users/alex/ab/femcboost/.claude/worktrees/agent-a788e07e3f5a0bdb8   2026-09-12T00:31:23Z
registered zach-opus-f4  /Users/alex/ab/richos-wt/zach-opus-f4                                2026-09-12T00:31:23Z
… (22 more agents, each with BOTH its native and its cc/ workspace, through frank-fable-b1 at 17:50:25Z)
```

**24 agents registered today, 48 rows, every agent with both workspaces — exactly point 10's pairing.**
"Registration is not happening" is false for the installed engine and vacuous for the uninstalled one.

The corrected premise: *there are two registration stores on this machine; each is written by whichever engine
is installed at the moment; the dev store has one record because the dev engine was installed for 31 minutes;
the round measures the dev store only in a sandbox (`RICHOS_WORKSPACES_DIR`) or after the install the record's
"Before this is installed" section describes.*

Two more things the brief did not see in that directory:

```
$ ls -la ~/.claude/state/workspaces
agents/  done/  events.jsonl  ids/  lock  refs/  repos.json  sessions/
$ cat ~/.claude/state/workspaces/events.jsonl | tail -4
{"event": "integration-recorded", "repo": "/private/var/folders/…/T/land-completeness.rSiULs/clean/repo", "why": "the land-completeness fixture", "work": "repo-001", "ts": "2026-09-12T12:44:07Z"}
… (four rows, two fixtures, all pointing at temp directories)
```

A test wrote into the operator's live store at 12:44Z today. The dev branch knows (`b208ec07` "No test writes to
the operator's real workspace registry"; its L20 case documents the four rows). The polluted `integration.json`
is gone; the four events remain. Which means **`integration.json ABSENT` has two explanations ahead of the
brief's** — nothing installed writes it, and the one file that did exist was fixture residue that was removed.

### 4.3 `reconcile-terminal-worktrees.py --preview` → `remove=0 … hold=49`

**Reproduces exactly, on `main`; says almost nothing about point 4; does not exist on `dev`.**

```
$ python3 engine/scripts/reconcile-terminal-worktrees.py --preview      # main @ dcabcbd9, help: "writes nothing"
=== preview: remove=0 branch-only=14 observe=0 hold=49 excluded=9 not-examined=2 ===
$ grep 'PREVIEW hold' preview.out | sed 's/.* — //' | cut -c1-60 | sort | uniq -c
  19  Current canonical main no longer contains the delivery. N of N commits on this branch are NOT on refs/heads/main
  26  removed workspace has no retained completion proof
   4  RETRY, not a verdict: process(es) 1483 (com.apple.Virtualization.VirtualMachine) are standing in the way
$ (for each hold path) [ -d "$p" ] && echo "$p"
/Users/alex/ab/claude-orchestration-kit-wt/zach-opus-dor1   /Users/alex/ab/deeply-wt/zach-opus-dor1
/Users/alex/ab/claude-orchestration-kit-wt/zach-opus-dor2   /Users/alex/ab/deeply-wt/zach-opus-dor2
$ grep 'PREVIEW hold' preview.out | grep -c '16a15be1/' ; …'b7869424/' ; …'d0eef867/'
23   18   8
```

So of 49 holds, **45 name paths that no longer exist on disk**. 19 are work that landed on `dev/workspace-spec`
and is judged against `main` — that is point 14 surfacing inside point 4's tool, not point 4. 26 are registry
rows for already-deleted workspaces the tool cannot close. The only four on disk are held by a VM process — a
retry case, which the tool correctly labels RETRY. And 26 of the 49 belong to sessions `b7869424` and `d0eef867`,
which have ended (`~/.claude/sessions/` holds only `24267.json`) — **that is a live, countable point-12 failure**
the brief filed under "incomplete".

Main's registries carry the same story at scale:

```
$ python3 engine/scripts/lib/workspace-retire.py list --repo <repo>     # read-only; store: ~/.claude/state/workspace-retirement/
femcboost records 125 (present,retired) -> {(False, False): 123, (True, False): 2}
richos    records 134 (present,retired) -> {(False, False): 120, (False, True): 12, (True, False): 2}
```

243 rows neither present nor retired. On disk, the actual residue is two quarantines plus the four `dor` trees.

### 4.4 Point 10 — both reviewers' native workspaces "still registered", `cc/` ones "removed"

**The verdict FAILS survives; the description is backwards on both halves.**

```
$ python3 engine/scripts/lib/workspace-retire.py list --repo /Users/alex/ab/femcboost | grep -B3 -A8 'ws-71d9662ef3071ece\|ws-79d49f8b63928424'
 "branches": ["worktree-agent-a5c9432829535a06b"], "id": "ws-71d9662ef3071ece", "path": ".../agent-a5c9432829535a06b", "present": false, "retired": false, "teammates": ["sage-opus-c6"]
 "branches": ["worktree-agent-ab392b5757d9188cc"], "id": "ws-79d49f8b63928424", "path": ".../agent-ab392b5757d9188cc", "present": false, "retired": false, "teammates": ["frank-opus-c6"]
$ git branch --list 'worktree-agent-a5c9432829535a06b' 'worktree-agent-ab392b5757d9188cc'     # femcboost
(nothing)
$ git branch --list 'cc/sage-opus-c6' 'cc/frank-opus-c6'                                        # richos
(nothing)
$ git worktree list                                                                             # richos
/Users/alex/ab/richos-wt/.richos-retired/frank-opus-c6.richos-retired-ws-e1cde08e09b169ca-20260912T161306.969904Z  37bb361c (detached HEAD)
/Users/alex/ab/richos-wt/.richos-retired/sage-opus-c6.richos-retired-ws-64577978b30eb0ad-20260912T161239.771266Z   a8fc4203 (detached HEAD)
$ grep 'sage-opus-c6\|frank-opus-c6' ~/.claude/state/workspace-retirement/retirements.jsonl | …
{'operation': 'retire', 'outcome': 'quarantined', 'reason_code': 'quarantined', 'ts': '2026-09-12T16:12:39Z'} ws-64577978b30eb0ad …/sage-opus-c6
{'operation': 'retire', 'outcome': 'quarantined', 'reason_code': 'quarantined', 'ts': '2026-09-12T16:13:07Z'} ws-e1cde08e09b169ca …/frank-opus-c6
```

The native halves are **fully gone from git** — directory and branch. "Still registered" means a row in
`main`'s retirement registry that was never closed. The `cc/` halves are what is actually left behind: two
quarantined directories, each still a registered git worktree at a detached HEAD, holding commits that ARE on
`dev/workspace-spec`. Point 10 fails because of the `cc/` residue and the stale rows, not because native
workspaces persisted.

### 4.5 Points 4, 10, 13 are measured on tools the round's base deletes

```
$ git merge-base dcabcbd9 c5bce604 → dcabcbd9 ;  rev-list --count dcabcbd9..c5bce604 → 106 ;  c5bce604..dcabcbd9 → 0
$ git diff --name-status dcabcbd9 c5bce604 -- engine/scripts | grep -E '^D' | grep -Ei 'reconcile|retire|remove-agent|reap'
D  engine/scripts/hooks/session-start-reap-worktrees.sh
D  engine/scripts/lib/workspace-retire.py            (+ its review, recheck, safety and test files)
D  engine/scripts/reap-stale-worktrees.sh
D  engine/scripts/reconcile-terminal-worktrees.py
D  engine/scripts/remove-agent-worktree.sh
A  engine/scripts/lib/workspaces.py  A engine/scripts/workspaces.sh  A engine/scripts/hooks/workspace-lifecycle.sh  A engine/scripts/hooks/guard-workspace-gate.sh
```

`dev/workspace-spec` is a strict descendant of `main` (106 ahead, 0 behind) whose commit `ca4ba9f8` is titled
"Remove every workspace deleter the spec does not have". The quarantine, the 14-day retention, the
`automatic-erasure-disabled` refusal and the `NOT-EXAMINED` lane are all `main`. An engineer opening
`c5bce604` to fix point 4 will find none of them.

### 4.6 `integration.json` ABSENT and the `main` consumer

```
$ ls ~/.claude/state/workspaces/integration.json → ABSENT (confirmed)
$ grep -n 'is-ancestor' engine/scripts/hooks/guard-unresolved-claims.py        # main
1433:  out.append("      git -C %s merge-base --is-ancestor %s main" % (repo, sha))      # and line 1426: "NOT an ancestor of main/master"
$ grep -rn 'is-ancestor' dev/engine/scripts --include='*.py' --include='*.sh' | grep -v test | grep main
lib/completion-proof.py:298   main=direct(repo,proof['integration_ref'])    ← resolved from the RECORD
lib/land-completeness.py:220  _merge_status(repo, branch, main)              ← main from integration_branch(repo), which abstains: "no default of 'main' and never was one"
```

True of the installed engine — it did refuse a true land onto `dev/workspace-spec`. Already changed on the
round's base (`f0ee9622` "Every consumer asks the library; none keeps its own answer"). The brief presents a
`main` fact as the state of the round.

### 4.7 The "at least four agents" and the "2" sessions

- Agents: **24** (section 4.2). Not wrong, six times understated, and the understatement hides that every one of
  the 24 registered both workspaces at spawn.
- Sessions: `ls ~/.claude/sessions/` → `24267.json` and `24267.<sha>.key`. One session. Its record carries
  `"procStart": "Fri Sep 11 22:25:13 2026"` — a process identity, which is exactly what point 12 asks for, and
  what the dev record for `zach-opus-d1` pins (`"session_identity": {"pid": 24267, "pid_start": "Fri Sep 11
  22:25:13 2026"}`). The "two stores disagree" finding is a `wc -l` read as a count of sessions.

---

## 5. The scoreboard, disputed

Brief: **failing 1, 3, 4, 10, 13, 14 — incomplete 2, 6, 12 — never measured 5, 7, 8, 9, 11.**

| point | brief | ruling | proof |
|---|---|---|---|
| 1 | FAILS | **FAILS** — verdict stands; enumeration method wrong | 4.1 |
| 2 | partial | partial — the exclusion cited is `main`'s reconciler; `dev` has `CODEX_PREFIX` + 10 unit references + 1 mutant, unmeasured by the brief | 6 |
| 3 | FAILS "registration not happening" | **DISPUTED** — installed engine registered 24/24 today; dev store empty because dev is not installed. What does fail: the one dev record has `"agent_id": ""` and `ids/` is empty — the record's §3.4 "row with no agent id" recurring in the new store, and a real point-3 mutation | 4.2 |
| 4 | FAILS, hold=49 | **FAILS on `main`, in a different way** — 2 quarantines + 243 unclosed rows; hold=49 is 45 ghosts + 4 retries. On `dev`: E1.7–E1.9, E2.4, E3.3 green | 4.3, 6 |
| 5 | never measured | **DISPUTED** — E1.5, E1.6, E4.2, E4.4, E6.3, E6.4 green on dev; 7 unit references | 6 |
| 6 | partial | partial → **measured on dev**: E1 is a real native workspace (`worktree add … -b worktree-agent-<id>`), landed and gone | 6 |
| 7 | never measured | **DISPUTED** — E2.3–E2.6 (discard with reason recorded) green; `ceo_ordered` read from a `ceo-ordered:` prompt line, discard needs `--ceo-word` or `--not-ceo-ordered` | 6, 7 |
| 8 | never measured | **DISPUTED** — E4.6 "an uncommitted file refuses the land", E6.3 green | 6 |
| 9 | never measured | **DISPUTED** — E1.4, E1.10, E4.3 green | 6 |
| 10 | FAILS, native still registered | **FAILS, description backwards** | 4.4 |
| 11 | never measured | **the one true "never measured"** — no e2e case; 12 unit references to pause, 1 mutant. And a live measurement exists: 954 `finished` rows today for 24 agents, 953 distinct per-run ids, 0 carrying a branch | 6 |
| 12 | incomplete | **FAILS, measurably, on `main`** — 26 holds from two ended sessions; on dev E1.1, E4.x green | 4.3 |
| 13 | FAILS | **DISPUTED** — the cited residue is quarantine (point 4/7), not a failed deletion; the tool's actual held-file case (VM pid 1483) IS labeled RETRY. On dev: retry schedule exists (60 s base, doubling, 1 h cap, CEO told after 5), 5 unit references, no e2e | 4.3, 6 |
| 14 | FAILS | **FAILS on `main`; changed on `dev`** — E0.1 green; 4 unit references; the record's `integration.json` was once fixture residue | 4.6 |

**Corrected scoreboard** (the branch the round is cut from, `c5bce604`, sandboxed, my run):
every point has at least one committed green check; **end-to-end coverage is missing for 2, 11, 13**; the
mutants are spec-derived, none record-derived; and the on-machine failures (1, 4, 10, 12) are facts about the
installed `main` engine that only an install of the branch can act on.

## 6. "NOT MEASURED" that was one command away

All four commands below are on `c5bce604`, self-sandboxing (`mkdtemp`; `HOME` and `CLAUDE_CONFIG_DIR` redirected;
`RICHOS_WORKSPACES_DIR` unset inside), and I ran them from the scratchpad archive:

```
$ python3 engine/scripts/lib/workspaces.test.py
Ran 58 tests in 25.606s   OK   === workspaces spec tests: 58 run, 0 failed ===
$ grep -o 'point 1[0-4]\|point [1-9]\b' lib/workspaces.test.py | sort | uniq -c
 1 point 1   3 point 3   5 point 4   7 point 5   1 point 7   4 point 8   1 point 9   3 point 10   1 point 12   4 point 14
$ bash engine/scripts/workspaces-e2e.test.sh
workspaces-e2e: 47 passed, 0 failed
  E1.4 finished: the lock-out refuses every tool, Read included (point 9)
  E1.5 the Stop gate refuses the end of the turn while it is pending (point 5)
  E1.6 the spawn guard refuses new work while it is pending (point 5)
  E1.10 restarted after its workspace is gone: still refused (point 9)
  E2.3 discarded with its reason recorded  / E2.6 the reason is in the record            (point 7)
  E4.2 the next session is told first (point 5) / E4.3 cannot outlive the session (points 9, 12)
  E4.6 an uncommitted file refuses the land (point 8)
  E6.3 the land is held by the work it left on a side branch, by name (points 5, 8)
$ for k in codex native pause retry; do grep -ci $k unit / e2e / mutation; done
codex unit=10 e2e=0 mutation=4   native unit=13 e2e=2 mutation=5   pause unit=12 e2e=0 mutation=3   retry unit=5 e2e=0 mutation=1
```

And the point-11 measurement that needed no branch at all:

```
$ python3 - (ledger rows dated 2026-09-12 with event == finished)
finished rows today: 954   naming no teammate: 79   carrying a branch: 0   distinct agent_id: 953
```

The platform's end-of-run signal IS recorded — about forty times per agent, under per-run ids, naming no work.
That is `lifecycle-failure-record-2026-09-10.md` §3.4/§3.5 happening today, and it is the recorded incident
point 11's mutation should be derived from.

## 7. Scope, the mutation bar, and what is unobservable as written

### 7.1 Scope — excluding the runner leaves a hole

The brief's own first sentence: *"all fourteen are asked by one command."* That command is
`workspace-probes.py`. Its defects are exactly the ways a question stops being asked or gets a false answer:
A3's witness is a branch name anyone can cut (a red probe becomes RETIRED, exit 0); MISSING is suppressed by a
working-tree file (a deleted probe is not reported); `getattr` discovery makes a probe invisible (undiscovered
is worse than red — the runner's own words); the `PASS/PASS` headline reads a partial run as clean. A round that
proves fourteen checks through an instrument that can be silenced from inside the work under test proves
nothing the CEO can spot-check. **The runner's honesty is a precondition of the round, not scaffolding beside
it.** What belongs in scope: the runner's own suite (`4c70bfc2` gave it one) must go red under each of the four
documented silencing routes before any point's verdict is read from it. That is one item, bounded, and it is
the item both reviewers refused round 5 over.

### 7.2 The mutation bar — reachable, with one floor and one address

The source exists and is rich enough: `richos-hq/docs/verification/lifecycle-failure-record-2026-09-{10,11,12}.md`
(386 + 88 + 146 lines). Machine-observable incidents that map to points:

| point | recorded incident | where |
|---|---|---|
| 3 | "`create-teammate-worktree.sh` writes an ownership row with no agent id" — reproduced today in the dev store (`"agent_id": ""`, `ids/` empty) | 09-10 §3.4; `~/.claude/state/workspaces/agents/*zach-opus-d1.json` |
| 4 | "Nothing made removing a finished one happen" | 09-10 §3.1 |
| 5 | six finished branches outside main, then five, turn ended anyway | 09-10 §3.1, §2.11 |
| 7 | "I destroyed running work on an inference"; "I deleted a record whose content was a refutation" | 09-10 §2.2, §2.16 |
| 8 | gitignored acks deleted with an unchanged worktree (echo-opus-529, 2026-09-05) | `inflight-ack.sh` header |
| 9 | thirteen agents restarted after their terminal record, 0.3 s to 8 h later | 09-10 §3b.1 |
| 10 | "Zero of 15,882 finish rows have ever named a cross-repository workspace" | 09-10 §3.4 |
| 11 | finish event identifies no work; platform vocabulary is `WorkerRunEnded/WorkerStarted/WorkerUpdated` | 09-10 §3.4, §3b.1; today's 954 rows |
| 12 | 26 holds from two ended sessions, still held | `--preview` today |
| 13 | four trees held by VM pid 1483 | `--preview` today |
| 14 | a true land onto `dev/workspace-spec` refused by a `main` check; 19 holds "NOT on refs/heads/main" | 09-12; `--preview` today |
| 1, 2, 6 | no machine-state incident in the record (the `dor` trees are a live one for point 1) | — |

So the bar "no mutation derived from the record survives" is reachable — but as written it is satisfied
trivially by any point with zero derived mutations. It needs a floor: **every point carries at least one
record-derived mutation, or the brief states "no recorded incident for point N" and declares that point's
mutation as constructed.** And it needs the address: the record series is in `richos-hq`, the mutations live in
`richos`; each mutation names its incident by file and section. The existing 20 mutants on `c5bce604` remove one
spec rule each — spec-derived, which is the "imagined" class the CEO's ruling retires as the sole proof.

### 7.3 Unobservable as written — none needs the CEO; two need a stated decision; one needs his calendar

- **Point 5, "answering the CEO"** — observable: the dev gate reads it as "the turn began with his message"
  (`guard-workspace-gate.sh` line 15) and allows it once. Engineer's decision, already made.
- **Point 7, "work the CEO ordered"** — observable: recorded at spawn from a `ceo-ordered:` prompt line; a
  discard without `--ceo-word` or `--not-ceo-ordered` is refused. The default when the line is absent
  (`null` today) must be stated — refuse-until-told is the safe reading. Engineer's decision.
- **Point 13, "only if it keeps failing"** — observable: `RETRY_TELL_CEO_AFTER = 5`, base 60 s doubling, cap 1 h.
  Engineer's decision, already made, should be in the brief.
- **Point 3 / the install** — the one thing outside the engineer's reach. The dev record's "Before this is
  installed": the first session on the new engine applies point 3 to everything already on disk, and *"a
  workspace of an agent still running in an old-engine session is indistinguishable from one left behind"*, so
  the branch is landed and `install.sh` run only while no session and no agent is running. Every on-machine
  failure in this brief (1, 4, 10, 12) is a `main` failure that the round cannot fix without that install. The
  brief says "Nothing installed" and never says when that changes. **That is a CEO scheduling decision, and it
  should be on his TODO list now, not discovered when the engineer's fixes cannot be shown on the machine.**

---

## 8. THE BETTER VERSION

Material Rich can lift into the corrected brief. Every number below is one I produced above with the command
beside it.

### 8.1 Corrected "How state was measured" block

```
# Which tree: the installed engine is main @ dcabcbd9 (~/.claude/richos-engine -> /Users/alex/ab/richos/engine, HEAD main).
# The round's base is dev/workspace-spec @ c5bce604, a strict descendant (106 ahead, 0 behind) that DELETES
# reconcile-terminal-worktrees.py, remove-agent-worktree.sh, workspace-retire.py and the reapers.
# Which store: main writes ~/.claude/state/worktree-ledger.jsonl and ~/.claude/state/workspace-retirement/;
# dev writes ~/.claude/state/workspaces/. Never compare across them.

$ git -C /Users/alex/ab/femcboost worktree list --porcelain | grep -c '^worktree '   # per repo, never a glob
$ git -C /Users/alex/ab/richos    worktree list --porcelain | grep -c '^worktree '
$ (same for claude-orchestration-kit, deeply, richos-hq)                                → non-native, non-cc, non-codex: 4 (the dor trees)
$ python3 - ledger histogram (rows dated today)                                        → registered 48 = 24 agents x 2 workspaces
$ python3 engine/scripts/reconcile-terminal-worktrees.py --preview   # main only     → hold=49: 19 "NOT on main", 26 ghosts, 4 RETRY; 45 not on disk
$ python3 engine/scripts/lib/workspace-retire.py list --repo <each>  # main only     → 243 rows present=false retired=false
$ ls ~/.claude/sessions/                                                               → one session (24267.json + .key), procStart recorded
$ cat ~/.claude/state/workspaces/repos.json                                            → 2 repos known; the 4 violations are in 2 others
$ (sandboxed, on c5bce604)  python3 lib/workspaces.test.py → 58/58 ;  bash workspaces-e2e.test.sh → 47/47
```

### 8.2 Corrected premises, one line each

1. Non-`cc/` non-native workspaces: 4, in `claude-orchestration-kit` and `deeply`; codex: 9 (7 under `*-wt/`, 2 under `~/.codex/`).
2. Registration: 24/24 agents today, both workspaces each, in the installed engine's ledger; the dev store holds the one agent spawned during the 31-minute install window.
3. `hold=49`: 45 registry ghosts + 4 held-by-process retries; residue on disk = 2 quarantines + 4 `dor` trees.
4. Point 10 residue = the `cc/` quarantines and stale retirement rows; the native workspaces and all four branches are gone.
5. `integration.json` absent because nothing installed writes it; the four `integration-recorded` events in `events.jsonl` are fixture residue from 12:44Z.
6. `guard-unresolved-claims` assumes `main` on `main`; on `c5bce604` every remaining `is-ancestor` consumer resolves the target from the record or abstains.
7. Sessions: one recorded, with process identity.
8. The 2026-07-18 incident is in femcboost `CLAUDE.md`, not in the record series; cite it there.

### 8.3 Corrected scoreboard (section 5) and the round's shape

Replace the three-bucket scoreboard with two columns per point: **on the machine (main, installed)** and
**on the base (c5bce604, sandboxed)**. On the machine: 1, 4, 10, 12 fail measurably, 14 fails by the refused
land, 3/6 are fine (the ledger registers both workspaces), 13 is not shown to fail. On the base: every point has
a green check; 2, 11, 13 lack an end-to-end case; no mutation is record-derived.

The round I would run instead of "fourteen checks, fix what fails":

1. **Runner first.** `workspace-probes.py`'s own suite goes red under the four silencing routes. One item.
2. **Three missing e2e cases** — 2 (an agent spawned against `codex/` work gets a `cc/` copy; a land path cannot
   reach `codex/`), 11 (pause recorded with what ends it; a nameless pause is pending; a `WorkerRunEnded` after a
   pause still finishes), 13 (a deletion blocked by a held file is retried on schedule and the CEO is told after
   the fifth failure).
3. **One record-derived mutation per point**, table 7.2, each carrying file + section + date; the point-11 one is
   "a finish signal that identifies no work", which today's ledger reproduces.
4. **Fix the thirteen-to-fourteen drift** in `workspaces.py` and the implementation record.
5. **Put the install on the CEO's list** with its precondition (no session, no agent) — because until it runs,
   every on-machine failure in this brief stays exactly where it is.

### 8.4 The bar, restated

*Every point carries at least one mutation derived from a named incident in
`richos-hq/docs/verification/lifecycle-failure-record-*.md`, this session's ledger, or `--preview`'s output, and
none of those mutations survives. A point with no recorded incident says so and names its constructed mutation
as constructed.* That is reachable today for eleven points and honest about the other three.

---

## 9. Ruling on the three properties and the brief

| property | verdict |
|---|---|
| 1. fourteen items, none invented | HOLDS |
| 2. verbatim | FAILS — 11a (quote marks), 11b (silent elision); nine elisions |
| 3. command + output for every claim | FAILS — table in section 3; no tree, no store, three stores conflated |
| scoreboard | 9 of 14 verdicts disputed (3, 4-as-described, 5, 7, 8, 9, 10-as-described, 12, 13) |
| scope | hole — the runner is the instrument |
| bar | reachable with a floor and an address |
| unobservable | none needs the CEO's ruling; the install date needs his calendar |

**BRIEF NOT READY.**

## 10. What I did not do

I did not read Frank's work. I did not run `install.sh`, merge, push, write into `/Users/alex/ab/richos/engine`
or touch the main checkout of any repository. I did not run the dev mutation harness (20 mutants x 58 tests; it
is spec-derived and not the question). I could not run `scripts/preflight.sh` or `scripts/lint-banned.sh` on
this deliverable from the richos worktree — they are femcboost scripts and richos has no `scripts/` directory.

## 11. The stores are unchanged

`snap.py` walks `~/.claude/state/workspaces` and `~/.claude/state/workspace-retirement` (16,635 entries) and
hashes every path and file body. (The ledger is excluded on purpose: hooks append `finished` rows to it
continuously — 912 today — through no action of mine.)

```
before anything ran:                       entries 16635 sha256 e0840d0354cd93a7af896a2e38d09d5f23dc25b33a4ee0b0feeb627ba7458574
after --preview and two `list` runs:       entries 16635 sha256 e0840d0354cd93a7af896a2e38d09d5f23dc25b33a4ee0b0feeb627ba7458574
after the unit suite and the e2e suite:    entries 16635 sha256 e0840d0354cd93a7af896a2e38d09d5f23dc25b33a4ee0b0feeb627ba7458574
```
