CERTIFIED

# Frank — certification of the branch-attribution fix

**Commit certified:** `e8524b6bb5607b77c93d13e297410756b0aa93ef` ("A branch is the agent's because it
is in the agent's own workspace"), one commit over `e41e00f9`, branch `cc/zach-opus-f9`.
**Reviewed from:** `/Users/alex/ab/richos-wt/frank-opus-c2`, branch `cc/frank-opus-c2`, HEAD
`e8524b6bb5607b77c93d13e297410756b0aa93ef`.
**Yardstick:** `docs/plans/worktree-spec-2026-09-11.md`, unchanged on this branch, and nothing else.
**Scope:** this one commit, and whether it broke anything that was working. Fixes 1, 3 and 4 are closed
from last round and are not re-opened here.

Nothing was installed, merged, pushed or deployed. Every run is sandboxed by the shipped suite's own
`Env`, which redirects `HOME` and `CLAUDE_CONFIG_DIR` into a temporary tree; I additionally redirected
`TMPDIR` and `RICHOS_WORKSPACES_DIR` into scratch. The operator's real registry
`~/.claude/state/workspaces` was measured before and after: **4 files, digest
`e6db23a5fae4cd8915f04bde0bdc9870736b393c`, unchanged, newest mtime 00:58 — hours before the first run
at 07:08.** The sandbox `RICHOS_WORKSPACES_DIR` ended empty (0 files), so nothing tried to write a
registry anywhere at all.

---

## 1. The verdict on the one fix: it does what it says

**My own probe, unmodified**, restored byte-for-byte from `cc/frank-opus-c1` (blob
`f0bc36d1196e87e06f210d62b06a86da9f7666e0`, sha256
`06e167573a80ef3485f9be54164a8b5ce83cc9637f3e595fd119d865760454a1`; `git hash-object` on the working
copy returns the same blob id).

```
$ python3 docs/verification/certification-frank-four-fixes-2026-09-12-probe.py
test_a1_another_agents_branch_is_attributed_to_this_one ... ok
test_a2_land_of_A_is_held_hostage_by_the_other_agents_branch ... ok
test_a3_a_branch_the_lead_cuts_in_the_main_checkout_is_the_agents ... ok
test_a4_discard_of_A_deletes_the_other_agents_branch ... ok
----------------------------------------------------------------------
Ran 4 tests in 2.907s

OK

A.created_branches = []
B's own branches    = ['cc/zach-opus-b1', 'worktree-agent-azachopusb10000']
land(A) -> {'landed': True}
branches after discard(A): ['cc/zach-opus-b4', 'main']
```

**I confirm the claim in the brief: `Ran 4 tests … OK` on this SHA.** One honesty note about that
evidence: the probe calls `unittest.main(exit=False)`, so its **process exit code is 0 whatever
happens** — the verdict is the `OK`/`FAILED` line, never the exit status. I say so because an exit code
quoted as a pass here would be a green over nothing.

And the same probe, unmodified, against a copy of the **parent** `e41e00f9` (the two library files
extracted with `git show` into a scratch tree of the same shape):

```
$ python3 docs/verification/certification-frank-four-fixes-2026-09-12-probe.py     # at e41e00f9
Ran 4 tests in 2.566s
FAILED (failures=4)
```

4-of-4 red at the parent, 4-of-4 green here. The fix is the cause; nothing else in the tree moved.

**The shipped suite** at this SHA: `Ran 45 tests … OK`, and at the parent `Ran 42 tests … OK`. The
three added are `test_point_03_another_live_agents_branch_is_never_attributed`,
`test_point_03_a_branch_rich_cuts_in_the_main_checkout_is_never_the_agents`,
`test_point_03_two_agents_in_one_repository_both_land_their_own_refs`. **No test was removed** (`comm`
of the two name lists is empty in the removed direction).

**The mutation harness** proves those tests can fail for the right reason: 26 mutants, all PASS,
including the new `p03-branch-attributed-repository-wide`, which restores the repository-wide read and
turns `test_point_03_another_live_agents_branch_is_never_attributed` red. Exit 0.

---

## 2. The central question: is the stray-branch trade inside his page?

**It is outside it. Plainly.**

Point 10 says: *"every workspace and branch it has is deleted, as one. **None is left behind.**"*
Point 3 says a *"**any branch an agent created**"* counts as finished work and is handled under point 5.
Neither sentence carries a condition about the branch's name, and **there is no branch-naming rule
anywhere on his page.**

The code's own comment justifies the stray with *"a stray that is not the system's concern (point 1)"*.
Point 1 does not say that. His words are: *"Every non-native Claude workspace is named `cc/`. Among
non-native workspaces, only `cc/` ones are the system's concern."* That is a rule about **workspaces**.
Reading it onto **branches** is an extension of his page, and extending the page is his to do, not the
engineer's and not mine.

So the trade is real, it is outside the page as written, and the honest form of it is a question for
the CEO rather than a defect that stops this commit — for the reason in §3.

**What the trade actually costs, measured rather than assumed** (§4, case B1 and case B3): a branch
that is not checked out **at a sampling instant** is invisible to attribution. The engineer declared
one shape of that (`git branch <name>`, never checked out). The mechanism is wider than the declaration:
a branch that was created, committed on, and left inside a single tool call is equally invisible,
because possession is **sampled at tool calls, not watched continuously**. That widening is undeclared,
and it is the most important thing in this report.

**And the exposure is bounded by NAME, not by harm.** A stray called `cc/…` (or `worktree-agent-…`) is
picked up by `scan_unregistered` and listed as pending work, even carrying a commit of its own — I
measured that (case B2). Anything named otherwise is seen by nothing: not attribution, not the scan,
not the pending list.

---

## 3. Why this is CERTIFIED rather than refused

Applying his own two rules, in order.

**Rule 1 — quote the sentence.** I can. Cases B1 and B3 break *"None is left behind"* (point 10),
*"any branch an agent created"* (point 3), and *"Rich lands 100% of everything after the agent is
finished — guaranteed … Every time, all of it, no exceptions, no deferral"* (point 5).

**Rule 2 — an observed instance, or a load that exists on this machine.** For the trigger of B1 and B3
— an agent creating an extra branch inside its own workspace — **I looked for one and there is none on
this machine**:

| measurement | command | result |
|---|---|---|
| in-workspace checkouts, richos | `grep -c "checkout: moving from" /Users/alex/ab/richos/.git/worktrees/*/logs/HEAD` | **0 in all 8** worktrees |
| in-workspace checkouts, femcboost | same, femcboost | 1 each in 2 of 5 — **both `codex/`**, which point 2 excludes by construction |
| stray branches now present | `find …/.git/refs/heads -type f`, both repos | none outside `cc/`, `codex/`, `worktree-agent-`, `main` |
| shipped code that creates a branch without checking it out | `grep -rn 'git … branch <name>' engine skills` | only test fixtures, all in throwaway sandbox repos at paths no registration records |

So B1 and B3 are **recorded, not refused on** — exactly the disposition the last round's 40,000-file
`node_modules` finding got, and for the same reason.

**And the comparison that settles it.** Refusing this commit does not leave the page better served: at
the parent, the *same* sentences were broken in the **destructive** direction — another live agent's
branch attributed, its owner's land refused and its branch deleted on discard — and that one **does**
have an observed instance, reproduced 4-of-4 on this machine. This commit trades a breach that destroys
work for a breach that leaves an unnamed ref sitting in a repository. Both are outside his page. Only
one of them loses anything.

**What I am not doing:** deciding for him whether *"None is left behind"* should acquire an exception.
That sentence is his. The build now needs it to mean something narrower than it says.

---

## 4. What I ran, and what each case did

My own adversarial probe for this commit is committed beside this file:
`docs/verification/certification-frank-attribution-2026-09-12-probe.py`. Each case is written so a
**failure is one of his sentences not being true of the build**, and each was run against **both** this
SHA and a copy of the parent, so a difference is attributable to this commit and nothing else.

| case | what it does | at `e8524b6b` | at `e41e00f9` | reading |
|---|---|---|---|---|
| **B1** | `git branch spare-work` inside the workspace (never checked out), then land | **left behind**, and the pending list is `[]` | deleted with the agent | **regression** — the declared cost |
| **B2** | same, but named `cc/…` and carrying a commit | listed: `['orphan-cc-zach-opus-n2-spare']` | land refused (attributed, not in main) | the **bound**: `cc/` names are caught by the scan |
| **B3** | `checkout -b side-work`, commit, `checkout` back — all in **one** tool call, then land | `land -> {'landed': True}`, branches `['main', 'side-work']`, pending `[]`, commit `ad2a894…` in no landed branch | land **refused**, naming `side-work` — so Rich sees it and can land it | **regression, and undeclared** |
| **B4** | the agent **checks out** a pre-existing unattached `cc/` branch carrying work, then is discarded | that branch is **deleted** (`['main']`), tip `06fb9f8…` | also deleted (by co-occurrence) | **not** a regression — narrowed, not closed |
| **B5** | same, then the agent's own work is landed | land **REFUSED**: *"cc/zach-opus-old (a23151cac657) is not in … Merge it, then land it; or discard it"* | refused the same way | **not** a regression — narrowed, not closed |
| **B6** | the agent renames its own branch in its workspace | goes with it; land clean | same | the fix holds under a rename |
| **B7** | a branch the scan has already listed, then a new spawn | spawn **refused**: *"Finished work is not landed or discarded: you cannot start new work (point 5)"* | same | a **real** bound on B4/B5 |

Two things worth being explicit about, because they cut against my own case:

- **B4 and B5 are not this commit's doing.** They fail at the parent too. What this commit changed is
  the route in: co-occurrence in time became possession at a checkout. The engineer named that route
  himself in the code, and his stated bound — a land refuses while such a branch carries anything not
  in main — **is real and I reproduced it** (B5). The bound is also the failure: it is point 5's
  guarantee that is doing the refusing, and the item then sits until Rich either merges a branch he
  never meant to land or discards and destroys it (B4). That pair is the residue of the original
  defect, narrowed, not closed. The load for it exists on this machine **right now**:
  `/Users/alex/ab/richos` holds `cc/zach-opus-f4` and `cc/zach-opus-f9`, neither an ancestor of `main`
  (`git merge-base --is-ancestor` → rc 1 for both), attached to no workspace, in the same repository
  where two review agents hold live worktrees. What is missing is any instance of an agent checking one
  out — 0 of 8, above.
- **B7 closed a case I expected to find open.** I went looking for "the system's own pending item is
  destroyed by another agent's discard" and the point-5 spawn gate refuses the spawn outright. I report
  that as a strength of the build, not as a near miss.

### Commands and exit codes

| # | command (from `/Users/alex/ab/richos-wt/frank-opus-c2`) | exit | verdict line |
|---|---|---|---|
| 1 | `python3 docs/verification/certification-frank-four-fixes-2026-09-12-probe.py` | 0 (meaningless, see §1) | `Ran 4 tests … OK` |
| 2 | same probe against the extracted `e41e00f9` library | 0 (meaningless) | `FAILED (failures=4)` |
| 3 | `python3 engine/scripts/lib/workspaces.test.py` | 0 | `Ran 45 tests … OK` / `45 run, 0 failed` |
| 4 | same suite against the extracted `e41e00f9` library | 0 | `Ran 42 tests … OK` / `42 run, 0 failed` |
| 5 | `bash engine/scripts/lib/workspaces.mutation.sh` | 0 | `mutation: all 26 properties proven load-bearing` (wall 1m43.1s) |
| 6 | `python3 docs/verification/certification-frank-attribution-2026-09-12-probe.py` | 0 (meaningless) | `FAILED (failures=4)` — B1, B3, B4, B5 |
| 7 | same probe against the extracted `e41e00f9` library | 0 (meaningless) | `FAILED (failures=2, errors=2)` — B1/B6/B7 green, B2/B3 error, B4/B5 fail |
| 8 | registry digest before/after (`find … -exec shasum`) | 0 | `e6db23a5fae4…` both times, 4 files |

Every one of those runs is committed verbatim beside this file, in
`docs/verification/certification-frank-attribution-2026-09-12-logs/`, so nothing quoted above rests on
a scratch directory that will be gone by the time anybody reads it.

---

## 5. Beyond the page

Not defects. No sentence of his is broken by any of these, and none of them is a reason to refuse
anything. They are here because he should have them.

1. **Attribution is now sampled, and sampling has a rate.** One `git worktree list` per repository per
   tool call decides what an agent owns. Anything whose whole life sits between two samples is
   invisible. That is a property of the design, not a bug in it, and it is why B1 and B3 are the same
   finding wearing two costumes.
2. **The stray that is left is a ref, not lost data.** B3's commit `ad2a894…` is still in the
   repository, on a branch nobody will delete. The cost is an unswept repository and a silent "landed",
   not destroyed work. The opposite direction (B4) does delete — and records the tip in the discard's
   `tips`, so even that is recoverable until git collects it.
3. **The comments in this commit are unusually honest and that is worth saying out loud.** The code
   names the cost, names what it counts without proving authorship, and names why it errs in the
   direction it errs. Two rounds ago I was reading justifications; this one reads like a record. It is
   also what made this review fast: every claim in the docstring was findable and testable, and the one
   place the docstring overreached (point 1 covering branches) was visible precisely because it was
   written down.
4. **Historical branch names.** `~/.claude/state/worktree-ledger.jsonl` (18,886 rows) carries 82
   distinct branch names outside `cc/`, `codex/`, `worktree-agent-` and `main` — `zach-opus-dor2`,
   `sage-fable-r1` and so on, the pre-`cc/` convention. They are workspace branches from before the
   naming rule, not in-workspace strays, so they say nothing about B1. They do say that "every branch
   an agent has is `cc/`-named" is a young fact on this machine, not an old one.

---

*Frank, 2026-09-12. Certified against `docs/plans/worktree-spec-2026-09-11.md` and nothing else.
I did not read Sage's work.*
