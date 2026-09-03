# BLOCKED (partial) — the moved private content cannot be COMMITTED to `../richos-hq`

**Reed, 2026-09-03/04, worktree `/Users/alex/ab/richos-wt/reed-opus-pub1`, branch `reed-opus-pub1`.**

**My own pass is proceeding.** Everything that does not depend on this is being done. This file
exists because content the CEO ordered MOVED to the private record is written to disk there and
**cannot be committed**, and an uncommitted file in a shared main checkout is exactly the kind of
thing that vanishes.

## What I am blocked on

`git commit` in `/Users/alex/ab/richos-hq` is refused by `guard-row-currency-commits.sh` for a
reason that has nothing to do with my change:

```
BLOCK  item 3.20 — ROW-STALE
       `femcboost/CLAUDE.md` is stamped @`623ddc012f0e` and is now 1fbe703f6253.
PASTE  item 3.20 should now carry:
       **State:** `OPEN` - `femcboost/CLAUDE.md`@`1fbe703f6253`
```

Row 3.20 lives in `richos-hq/wiki/open-items.md`. It is about the stale-staging protection being
prose. Its warrant pins the WHOLE of `femcboost/CLAUDE.md`, so any edit to that file invalidates it
— and the row's own text already records this happening **five times in one day**, calling it
*"noise the guard is paying for"* and naming the repair (pin the paragraph, not the file). This is
the sixth.

## What I already tried

- Committing the three private-record files as one atomic commit — refused, exit non-zero, nothing
  written. Reproduced once; I did not retry blind.
- Read row 3.20 in full and confirmed its SUBSTANCE is untouched: `femcboost/CLAUDE.md` moved again
  for the model COST-ceiling ruling (`b141a509f`), the deploy-always paragraph and the unbuilt
  staging guard are exactly as the row describes.
- **I did NOT re-stamp it.** It is another team's governance row, the guard's own message says
  *"there is deliberately no command that re-stamps a row for you"*, and a stranger re-stamping a
  row he does not own is the defect the guard exists to stop wearing a fix's clothes.

## The smallest question that would unblock me

**Who re-stamps row 3.20 — Rich at the land, or the row's owner?** Nothing else is needed. The
substance is verified unchanged; only the warrant SHA has to move.

## What is on disk right now, and how to land it in one command

The three files are **written and staged** in `/Users/alex/ab/richos-hq` (`git status` there shows
them staged, working tree otherwise as I found it):

- `wiki/publication-boundary-incidents.md` (new) — the dated incident narratives moved out of
  `richos/.publication-boundary`, `engine/scripts/lib/publication-boundary.sh` and
  `engine/CHANGELOG.md`.
- `wiki/open-source-strategy.md` — the amended documentation doctrine (prose, not machinery).
- `wiki/enforcement-and-failures.md` — a one-line pointer to the new page.

After row 3.20 carries its new warrant, one `git commit` in `richos-hq` lands all three. The commit
message I intended is quoted in full in my publication-readiness brief, which lands in this
worktree's `docs/briefs/` at the end of this pass.

**Until that commit exists, the public repo's pointers point at a page that is on disk and not in
git.** That is the one thing about this that is worse than it looks.

## What I am proceeding on meanwhile

The whole rest of the pass: categories 1, 3 and 4 across the tree, the fixes in the `richos`
worktree (which commits normally — this guard only fires in `richos-hq`), and the brief.
