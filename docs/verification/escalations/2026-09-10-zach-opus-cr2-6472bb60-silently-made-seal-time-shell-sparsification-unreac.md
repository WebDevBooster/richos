# Escalation: 6472bb60 made seal-time shell sparsification REACHED-AND-REFUSED for every spawn, and its refusal is not even counted

> **Title corrected after raising.** The ledger row reads "unreachable"; that
> noun is wrong and the correction is below under "Correction". The mechanism
> described in "What was already tried" was and remains accurate.

- id: `esc-20260910T010004Z-33acc248`
- raised: 2026-09-10T01:00:04Z
- from: zach-opus-cr2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-cr2` (branch `zach-opus-cr2`)
- head: `7d0c838f128ea01c1eb0069ffd8cdfb45a9317f9`
- state: **proceeding**
- for: lead

## The question

Was retiring automatic shell sparsification intended, or should sparsification and Claude-owned native cleanup coexist? I am updating the suite to assert the documented refusal; say the word and it becomes a code fix instead.

## What was already tried

Verified by execution, not inference: worktree-transactions.py:477 (_verify_native_member) is the ONLY producer of a native transaction member in production and it stamps cleanup_owner unconditionally; shell-worktree-sparse.py eligible() refuses any member with cleanup_owner. So every real native+external seal now refuses. Sparse suite: 21/21 at 6472bb60^ (16d36b26), 15 passed / 6 FAILED at HEAD and identically at 2afb9703^ (b2603388), so all 6 belong to 6472bb60. The commit updated five sibling suites and not this one. Secondary defect: eligible() returns before persist(), so no sparse block is written at all and metrics shells_sparsified / shells_sparse_refused / shell_bytes_freed are now permanently 0 - the refusal is invisible, which is exactly what suite case S18 was written to prevent. Files: engine/scripts/lib/shell-worktree-sparse.py, engine/scripts/lib/shell-worktree-sparse.test.sh, engine/scripts/lib/worktree-transactions.py:477

## Proceeding meanwhile

Terminalize suite is fixed and committed (42/42, mutation 13/13). Proceeding on the documented reading - engine/docs/automatic-workspace-cleanup.md in 6472bb60 states 'Seal-time sparsification also skips these platform-owned checkouts' - so I am treating the code as correct and the suite as stale, and recording the refusal so the counter stops lying.

## Correction (same session, before completing the task)

The lead challenged the noun "unreachable" and proposed a mechanism. Both
halves were checked by execution rather than argued.

**The lead is right about the noun.** The call site is live: `try_seal` reaches
`_sparsify_shell` at `worktree-transactions.py:540`, inside `if sealed:`, and
`maybe_sparsify` runs. Nothing is unreachable. The accurate claim is
**reached and refused for every native+external spawn**, which is a different
defect from "never called" and the record should say which.

**The lead's proposed mechanism is not the one that fires.** The suggestion was
that `_consume_pending_terminal` hands `eligible()` an already-terminal
transaction. That is a real disqualifying condition in the docstring, but it is
not what happens for an ordinary spawn. A sandbox driving the exact production
sequence `intent -> bind -> start -> seal` with no terminal event reports:

    sealed              : True
    kind                : native+external
    terminal at seal    : None
    native member keys  : ['branch', 'class', 'cleanup_owner', 'cleanup_policy',
                           'head_at_seal', 'path', 'repo', 'state']
    eligible() index    : None
    eligible() REASON   : 'native checkout is managed by Claude Code'
    sparse block written: None
    native tree present : True

`terminal at seal` is `None`, so the already-terminal clause is not reached. The
refusal is the `cleanup_owner` clause added by 6472bb60. The already-terminal
path is real but narrow — it is the S17 case, a terminal event arriving before
the manifest seals.

## The two defects, stated separately

The lead's framing is adopted because it is the more useful one:

1. **The feature is off.** Every native+external seal is refused on
   `cleanup_owner`. `_verify_native_member` (`worktree-transactions.py:477`) is
   the only producer of a native member in production and stamps that key
   unconditionally, so the refusal is universal, not situational.
2. **The counter cannot show that it is off, and this is the defect that let
   the first survive three days.** `metrics()` at
   `worktree-transactions.py:1591-1601` only increments `shells_sparsified` or
   `shells_sparse_refused` for a member carrying a `sparse` block.
   `maybe_sparsify` returned early on `i is None` without ever calling
   `persist`, so no block was written and all three counters read 0 — a reading
   indistinguishable from a sparsifier that was never wired in at all.

Defect 2 is fixed in this branch: the platform-owned refusal is now recorded
once on the native member, so `--status` counts it. Defect 1 is the open
question above and is deliberately NOT decided here.

**No correctness is at risk.** Sparsification is advisory by its own contract
("THIS FUNCTION IS ADVISORY AND MUST NEVER COST A SEAL"; "Nothing about the
lifecycle depends on it"). The cost is disk: the shell this was built to shrink
was a measured 266 MB, and every native+external spawn now keeps it whole.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T010004Z-33acc248`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T010004Z-33acc248 --disposition "<what you decided or did>"
