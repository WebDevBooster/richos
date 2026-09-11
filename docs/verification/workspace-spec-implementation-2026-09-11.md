# Workspace spec — implementation record, 2026-09-11

**The only reference:** `docs/plans/worktree-spec-2026-09-11.md` (sha256 prefix `b3fd6cd33b8c1135`),
committed untouched as the first commit of this branch. Implemented by zach-opus-spec2 on branch
`cc/zach-opus-spec2`, base `dcabcbd9`.

*Status: in progress. This record is written early and completed as the work lands; the
sections marked PENDING are filled before the branch is handed over.*

## The mechanism, in one paragraph

One registry, `engine/scripts/lib/workspaces.py`, outside every repository and session
(`$CLAUDE_CONFIG_DIR/state/workspaces`, else `~/.claude/state/workspaces`). It is written by the
two events the page names and by the platform's own signals, and read by the two point-5 gates and
the lock-out. `engine/scripts/workspaces.sh` is the one command Rich runs (`status`, `land`,
`discard`, `pause`, `resume`, `stop`, `wait`, `retry`). Land and discard — and their automatic
retry — are the only code in the engine that deletes a workspace or an agent's branch.

## The thirteen points

PENDING — commit and proving command per point.

## Old deleters, and what became of each

PENDING.

## Where the page had to be read

PENDING.

## Line counts

PENDING.
