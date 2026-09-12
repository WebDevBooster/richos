CERTIFIED

# Certification — branch attribution by possession

- **Commit certified:** `e8524b6bb5607b77c93d13e297410756b0aa93ef` on `cc/zach-opus-f9`
  ("A branch is the agent's because it is in the agent's own workspace"), one commit over
  `e41e00f9`, three files, all under `engine/scripts/lib/`.
- **Reviewer:** Sage, independently. I did not read Frank's review or his worktree.
- **Yardstick:** `docs/plans/worktree-spec-2026-09-11.md`, byte-identical at this SHA
  (the commit touches `workspaces.py`, `workspaces.test.py`, `workspaces.mutation.sh` and nothing else).
- **Nothing was installed, merged, pushed or deployed.** Every probe ran with `HOME`,
  `CLAUDE_CONFIG_DIR`, `TMPDIR` and `RICHOS_WORKSPACES_DIR` redirected into scratch. The real
  registry at `~/.claude/state/workspaces` is byte-identical before and after this review
  (`diff` of a `shasum` listing, exit 0; directory mtime unchanged at `1789171093`).
- **My reproduction script**, referenced throughout, is committed beside this file:
  `docs/verification/certification-sage-attribution-2026-09-12.probe.py`. It imports no engine
  test file; it drives `workspaces.py` through the same entry points the hooks use, and takes the
  path of the `workspaces.py` under test as its first argument, so the same scenario can be run
  against `e41e00f9` and against this SHA.

---

## 1. The fix does what the commit says it does

**Scenario (the ordinary order):** agent A is spawned with a `cc/` workspace in one repository
and a native workspace in another, makes a tool call, and is *still working* when agent B is
spawned into the same two repositories. B commits real work. A finishes.

```
python3 -B probe.py <workspaces.py> two-agents-staggered
```

**At the parent `e41e00f9` (exit 0) — the defect, reproduced by my own script:**

```
A.created_branches   [[.../other, "cc/mark-opus-b1"], [.../entity, "worktree-agent-amarkopusb10000"]]
B.created_branches   []
land(A) RAISED       SpecError: zach-opus-a1 is not landed yet: cc/mark-opus-b1 (074ea44be517)
                     is not in .../other at 0d5396dbeda4. Merge it, then land it; or discard it (point 7).
discard(A).tips      [".../entity:worktree-agent-amarkopusb10000", ".../entity:worktree-agent-azachopusa10000",
                      ".../other:cc/mark-opus-b1", ".../other:cc/zach-opus-a1"]
```

A's record holds **both of B's branches**. A's land is refused because B's work is not in main —
point 5's guarantee broken for A — and the discard names B's branches among the tips it deletes.
In this run B's branches survived only because `delete_branch` refuses a ref that is still checked
out somewhere; that protection lasts exactly as long as B's workspace does.

**At `e8524b6b` (exit 0):**

```
A.created_branches           []
B.created_branches           []
A.created_branches at end    []
land(A)                      {"landed": true}
discard(A).tips              []
other branches after         ["cc/mark-opus-b1", "main"]
B branch tip survived        true
B native branch survived     true
B workspace still there      true
```

Nothing of B's is attributed at A's tool calls or at A's end-of-run signal; A lands; B is intact.
**The fix holds.**

**The load for this defect is live on this machine right now**, which is why it matters more than
anything below:

```
$ git -C /Users/alex/ab/richos worktree list
/Users/alex/ab/richos                       dcabcbd9 [main]
...
/Users/alex/ab/richos-wt/frank-opus-c2      e8524b6b [cc/frank-opus-c2]
/Users/alex/ab/richos-wt/sage-opus-c2       e8524b6b [cc/sage-opus-c2]
/Users/alex/ab/richos-wt/zach-opus-spec2    d39e49d9 [cc/zach-opus-spec2]

$ git worktree list            # from my femcboost workspace
/Users/alex/ab/femcboost                                            3afae3d6e [main]
/Users/alex/ab/femcboost/.claude/worktrees/agent-a6397310d1b7bd4a3  3afae3d6e [worktree-agent-a6397310d1b7bd4a3] locked
/Users/alex/ab/femcboost/.claude/worktrees/agent-ac1f913e9dfea15ef  3afae3d6e [worktree-agent-ac1f913e9dfea15ef] locked
```

Two reviewers, two `cc/` workspaces in one repository and two live native workspaces in another —
the exact shape the parent commit misattributes.

### Nothing that was working broke

Every suite that consumes `workspaces.py`, run sandboxed at this SHA, all exit 0:

| Suite | Result |
|---|---|
| `scripts/lib/workspaces.test.sh` | 45 run, 0 failed; **26 mutants proven load-bearing** |
| `scripts/workspaces-e2e.test.sh` | 39 passed, 0 failed |
| `scripts/hooks/guard-worktree-isolation.test.sh` | 165 passed |
| `scripts/hooks/guard-worktree-removal.test.sh` | 94 passed |
| `scripts/hooks/guard-sealed-worktree.test.sh` | 10 mutants proven |
| `scripts/hooks/guard-resume-isolation.test.sh` | 58 passed |
| `scripts/hooks/detect-nonnative-worktree.test.sh` | 44 passed |
| `scripts/create-teammate-worktree.test.sh` | 4 mutants proven |
| `scripts/lib/finish-row-completion.test.sh` | 6 mutants proven |
| `scripts/hooks/lifecycle-payload-transport.test.py` | 13 tests, OK |

The commit leaves no dangling code: `_branch_snapshot_path`, `_repos_of` and the `close=` argument
are gone from the file and referenced nowhere else in the engine (grep across `engine/`, no hits).
The amended point-10 test asserts the new cost in the open (`assertIn("plain-branch", …)`) rather
than quietly dropping the assertion.

---

## 2. The ruling you asked for: the stray-branch trade against point 10

**Plainly: the trade is OUTSIDE your page.**

Point 10 says *"every workspace and branch it has is deleted, as one. None is left behind."*
Point 3 says *"any branch an agent created, counts as finished work of an ended session and is
handled under point 5."* A branch made with `git branch <name>` inside the workspace is a branch
the agent created, and at this SHA it is left behind. Measured, not argued:

```
python3 -B probe.py <workspaces.py> stray-plain-branch          # both exit 0
# agent runs, inside its own cc/ workspace:  git branch spare ; git branch cc/zach-opus-a1-side

parent e41e00f9   other branches after land   ["main"]                                    # both deleted
e8524b6b          other branches after land   ["cc/zach-opus-a1-side", "main", "spare"]   # both left
```

The engineer's argument is that a stray is "not the system's concern (point 1)". I do not accept
that reading: point 1 scopes **workspaces** by name (*"Every non-native Claude workspace is named
`cc/`"*), and point 3 scopes branches with the words *"any branch"*. Nothing on the page makes a
branch stop being the agent's because of what it is called.

**How large the deviation actually is, measured:** the point-3 sweep (`scan_unregistered`) still
catches an unattributed branch **if it is named `cc/…` or `worktree-agent-…`**, so that one is
handled under point 5 after the fact, just not as part of the agent's own land:

```
scan_unregistered keys   ["orphan--2e4edcf0658984ba"]
scan names               ["orphan-cc-zach-opus-a1-side"]      # recovered
                                                              # "spare" is not, and never will be
```

So the deviation from point 10 is real and narrow: a branch the agent created inside its workspace,
**named outside the `cc/` and `worktree-agent-` conventions**, and never checked out at the
workspace path, is left behind permanently and is invisible to the pending machinery.

**And the trade it buys is inside your page and destructive if it is not made.** What it replaces
breaks point 5 (*"Rich lands 100% of everything after the agent is finished — guaranteed"*) for the
innocent agent, and aims a `git branch -D` at that agent's branch under point 8
(*"Deletion therefore never loses anything that was meant to land"*). One deviation leaves a ref
sitting in a repository; the other refuses a land and points a forced delete at another agent's
work. They are not the same size.

**Why this ruling is not a refusal.** Your second rule is that a defect needs an observed instance
or a load that exists on this machine. There is none. Every branch in every repository agents work
in, today, conforms:

```
$ git -C /Users/alex/ab/richos   for-each-ref --format='%(refname:short)' refs/heads
  -> cc/frank-opus-c2, cc/sage-opus-c2, cc/zach-opus-spec2, worktree-agent-*, codex/* (5), main
$ git for-each-ref --format='%(refname:short)' refs/heads          # femcboost
  -> cc/*, worktree-agent-*, codex/* (3), main
$ git -C /Users/alex/ab/prospects for-each-ref --format='%(refname:short)' refs/heads
  -> master
```

Zero branches outside `cc/`, `worktree-agent-`, `codex/` and `main`/`master`. No engine script and
no repository script creates a branch inside a workspace (grep for `git branch `, `checkout -b`,
`switch -c` across `engine/scripts/` and femcboost `scripts/`, `skills/`: the only hits are guard
documentation and the lander deleting a branch). The stray requires an agent to type a command no
agent on this machine has typed. **Recorded, not refused on.**

---

## 3. Defects

**None meeting both of your rules** — a sentence of your page broken, and an observed instance or a
load that exists on this machine.

Two findings meet the first rule and fail the second. They are recorded here, in full, with
reproductions, and they are explicitly **not** a reason to refuse this commit.

### 3.1 Work committed on a side branch the agent switched away from is left behind, and nothing reports it

Your sentence, point 5: *"When an agent finishes, everything it produced is landed (or, where point
7 applies, discarded). Every time, all of it, no exceptions, no deferral."* Also point 10: *"None is
left behind."*

This is the sharper form of the declared cost, and the engineer's note does not name it: it is not
only `git branch <name>` that goes unattributed, but **any branch that is not checked out at the
workspace path at the moment of a tool call** — including one the agent created, committed real work
to, and switched away from.

```
python3 -B probe.py <workspaces.py> stray-switch-away
# inside its own workspace, in one tool call:
#   git checkout -b tmpwork ; <commit real work> ; git checkout cc/<agent>

parent e41e00f9   land(A) RAISED  SpecError: ... tmpwork (f3644e12d508) is not in ... (exit 1)
                  -> the land is held until Rich merges or discards it: point 5 protected it

e8524b6b (exit 0) A.created_branches        []
                  land(A)                   {"landed": true}
                  other branches after land ["main", "tmpwork"]
                  tmpwork commit in main    false
                  pending after land        []      <- scan=True; nobody will ever pick it up
```

The agent's committed work is neither landed nor discarded, the land reports success, and the
pending list is empty. Nothing is destroyed — the ref survives in the repository — but the
guarantee in point 5 does not hold for it.

**No load on this machine:** as measured above, no branch outside the conventions exists in any
repository agents work in, and nothing automated creates one.

### 3.2 A pre-existing branch the agent merely checks out becomes the agent's, and a discard deletes it

Your sentence, point 8: *"Deletion therefore never loses anything that was meant to land."*

This is new at this commit — the direction that destroys rather than the direction that litters. The
engineer names it in the docstring; I verified both ends of the bound he claims for it.

```
python3 -B probe.py <workspaces.py> preexisting-checked-out
# somebody else's branch human/keep, carrying a commit that is not in main,
# is checked out by the agent in its own workspace; the agent then finishes.

parent e41e00f9 (exit 0)   A.created_branches               []
                           other branches after discard     ["human/keep", "main"]
                           human/keep tip survived          true

e8524b6b (exit 0)          A.created_branches               [[.../other, "human/keep"]]
                           land(A) RAISED                   SpecError: ... human/keep ... is not in ...
                           discard tips                     [... ".../other:human/keep"]
                           other branches after discard     ["main"]
                           human/keep tip survived          FALSE      <- deleted by git branch -D
```

His claimed bound holds exactly as stated: a **land** refuses while such a branch carries anything
not already in main, and a **discard** records the tip it deletes in the disposition. So the loss is
confined to a discard, and it is recoverable from the recorded tip until git garbage-collects it.

**No load on this machine:** the only branches an agent could check out here are `codex/*` (refused
by `delete_branch`, point 2), `main` (refused while the main checkout holds it), another live
agent's `cc/` branch (git refuses a second checkout), or a finished agent's branch it was told to
continue from — which point 7 makes the new agent's work anyway.

---

## 4. Beyond the page

Not defects. For your call, not this verdict.

- **The stray sweep is scoped by branch NAME, not by the page.** `scan_unregistered` looks for
  `cc/…` and `worktree-agent-…` only. That is what makes finding 3.1 permanent rather than merely
  late, and it is the engine's convention, not a sentence of yours.
- **`main` is protected by a condition, not by a rule.** `delete_branch` refuses to delete the
  branch git lists for the main checkout. That protection is true while the main checkout has a
  branch checked out; it says nothing about a detached main checkout. Your standing "HEAD stays on
  main" rule is what keeps it true today.
- **Cost per tool call went up, immeasurably.** 20 barrier calls against a repository with 42
  worktrees: 0.248 s at this SHA versus 0.198 s at the parent — 12.4 ms versus 9.9 ms per call, for
  one `git worktree list` instead of one `for-each-ref`. The real repositories have 6 and 9
  worktrees. No budget on your page is at stake.
- **Attribution now means possession, and possession is not authorship.** That is the honest name
  for what this commit does, and the docstring says so. Both findings in section 3 are the same
  fact seen from its two sides; git keeps no record of where a ref was created.

---

## 5. What I ran

All from `/Users/alex/ab/richos-wt/sage-opus-c2`, all sandboxed, nothing installed.

| Command | Exit |
|---|---|
| `bash engine/scripts/lib/workspaces.test.sh` (sandboxed HOME/CLAUDE_CONFIG_DIR/TMPDIR/RICHOS_WORKSPACES_DIR) | 0 — 45 run, 0 failed; 26 mutants proven |
| `bash engine/scripts/workspaces-e2e.test.sh` | 0 — 39 passed |
| `bash engine/scripts/hooks/guard-worktree-isolation.test.sh` | 0 — 165 passed |
| `bash engine/scripts/hooks/guard-worktree-removal.test.sh` | 0 — 94 passed |
| `bash engine/scripts/hooks/guard-sealed-worktree.test.sh` | 0 — 10 mutants proven |
| `bash engine/scripts/hooks/guard-resume-isolation.test.sh` | 0 — 58 passed |
| `bash engine/scripts/hooks/detect-nonnative-worktree.test.sh` | 0 — 44 passed |
| `bash engine/scripts/create-teammate-worktree.test.sh` | 0 — 4 mutants proven |
| `bash engine/scripts/lib/finish-row-completion.test.sh` | 0 — 6 mutants proven |
| `python3 -B engine/scripts/hooks/lifecycle-payload-transport.test.py` | 0 — 13 tests OK |
| `probe.py <HEAD> two-agents-land` / `two-agents-staggered` | 0 / 0 |
| `probe.py <parent> two-agents-land` / `two-agents-staggered` | 0 / 0 |
| `probe.py <HEAD> stray-plain-branch` / `<parent> stray-plain-branch` | 0 / 0 |
| `probe.py <HEAD> stray-switch-away` | 0 |
| `probe.py <parent> stray-switch-away` | 1 (the land it refuses; that refusal is the finding in 3.1) |
| `probe.py <HEAD> preexisting-checked-out` / `<parent> preexisting-checked-out` | 0 / 0 |
| `probe.py <HEAD> rescue-after-end` | 0 — Rich's post-end rescue branch is not attributed and survives the land |
| `probe.py <HEAD> cost` / `<parent> cost` | 0 / 0 |
| `diff` of `shasum` listing of `~/.claude/state/workspaces`, before vs after | 0 — byte-identical, mtime unchanged |

— Sage, 2026-09-12
