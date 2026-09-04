# BLOCKED — the fix is finished and proven, and the commit guard will not let it be committed

**Branch:** `zach-opus-p6` — worktree `/Users/alex/ab/richos-wt/zach-opus-p6`
**Raised:** 2026-09-04, still blocked at the time of my report.
**State of the work:** complete, verified from a sibling-free clone, fully
staged, **zero commits**. The block is at `git commit`, not at the work.

**I cannot commit this file either.** The guard refuses every `git commit` in
this worktree, so the durable half of the escalation contract is not available
to me here. This file exists on disk and is staged; it goes in with the first
commit that is allowed through.

## What I am blocked on

`scripts/hooks/guard-completeness-commits.sh` (PreToolUse, blocking, no override
by design) refuses every commit in this worktree.

It runs the checker from the **installed engine** —
`/Users/alex/ab/richos/engine/scripts/publication-completeness.py`, the
**pre-fix** copy. My change removes the `INSTANCE_MECHANISMS` entry from
`.richos/publication-completeness` and replaces it with an in-band
`instance-mechanism: <reason>` marker in the private file. The pre-fix checker
does not know that marker exists, sees an unexcused private mechanism, and
refuses:

```
 1. [MISPLACED] richos-hq/…/pubcheck.sh
    is an executable mechanism in the PRIVATE tree that reads the public
    contract `.publication-boundary`, `.publication-completeness`.
```

**The refusal is a false positive from version skew**: the enforcing engine is a
different copy from the engine under test. Run the checker THIS BRANCH SHIPS
over the same tree and it is green — here, and in a clone.

**It is structural, not incidental.** Any change to `publication-completeness.*`
that alters what the gate accepts cannot be committed from a worktree, because
the gate guarding the commit is the version being replaced. The next engineer to
touch this file hits the same wall.

## What I already tried

1. `RICHOS_ENGINE_ROOT=<this worktree>/engine git commit …` — the documented
   first-choice engine resolution. A PreToolUse hook does not inherit a tool
   call's inline environment; the refusal was byte-identical.
2. Looked for a sanctioned way through the guard. There is none, deliberately:
   *"There is no in-prompt override … an override token would rebuild exactly
   that."* I did not look for an unsanctioned one, and I have not used one.
3. Checked whether any tree state satisfies BOTH checkers at once. None does.
   The pre-fix checker excuses that private file **only** through an exact
   `INSTANCE_MECHANISMS="richos-hq/<interior path>"` string; the fixed checker
   refuses that key by name. Keeping the entry keeps the private repository's
   interior path published, which is the thing the brief requires removed.
4. Confirmed the block is the old checker plus the sibling, not my tree: the
   identical file set commits cleanly, and the gate is green, in a scratch
   repository that has no `richos-hq` sibling.
5. Re-attempted after `1dd74c8` and `544d2bc` landed, and after you committed
   the private-side marker as `richos-hq 0a85435`. Unchanged — the marker is
   correct and the installed checker still cannot read it.

## The smallest question that unblocks me

**Which of these?**

**(a) Update the installed engine's two checker files, then I commit normally.**
Copy `engine/scripts/publication-completeness.sh` and
`engine/scripts/publication-completeness.py` from this worktree into
`/Users/alex/ab/richos` and commit them there. The guard reads those files at
call time, so the block clears immediately and the whole change goes in on this
branch in one pass. Cost: two files land ahead of the merge. **Recommended** —
it is what landing does anyway, and you already made the matching richos-hq
commit.

**(b) I ship the transitional form instead.** Keep `INSTANCE_MECHANISMS` and its
`richos-hq/<interior path>` entry, and fix only the host-dependence by scoping an
entry's staleness to the private root it names. Commits under the old checker; a
fresh clone passes. Cost: the private repository's interior path stays published
on flip day, requirement 3 of my brief is unmet, and finishing it later hits this
same wall.

**(c) Retire the private script.** `pubcheck.sh` hard-codes
`/Users/alex/ab/richos-wt/norm-deletion-2026-08-29`, which no longer exists, so
it cannot run as written. Delete it from `richos-hq` and both checkers agree
there is nothing to excuse, and I commit immediately. Cost: it deletes a record
of a one-off verification that the exemption's own written reason says belongs
where it is. **Your call or the CEO's, never mine** — I have not touched it.

## What I am proceeding on meanwhile

Everything that does not depend on the answer is done, staged and verified:

- the marker support, the retired key, the declaration, `CHANGELOG.md`,
  `UPGRADING.md`, and a verification record with ten transcripts;
- `publication-completeness.test.sh` at **53/53**, six new cases;
- RED first against the pre-fix checker: **47/53**, the six new cases failing —
  one of them the fresh-clone defect reproduced as a unit test;
- three targeted mutations, each turning exactly one named case red;
- a real `git clone` of the exact tracked set (1341 paths, asserted equal) into a
  directory with no sibling: gate **exit 0**, suite **53/53**;
- a host-dependence sweep over six suites in both worlds: no verdict moves.

Nothing waits on me. The moment an option is chosen the commits go in.
