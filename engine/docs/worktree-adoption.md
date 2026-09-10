# Worktree adoption — what may claim a worktree that no terminal transaction claimed

Written 2026-09-06. Companion to `workspace-retirement-safety.md`, which it is
argued against below rather than around.

## The gap, measured

Two mechanisms exist on this machine and they do not meet.

`reap-stale-worktrees.sh` can IDENTIFY a worktree that should go. It is DRY-RUN
by construction and removes nothing: re-arming it would restore the
sweep-decides-liveness design the CEO ended on 2026-09-03, after nine rounds of
it failed in nine shapes, the last by removing a live agent's worktree.

`reconcile-terminal-worktrees.py` can ACT, and owns only what a terminal
TRANSACTION claimed — a spawn the engine observed, terminalized by a platform
event about a specific agent id.

Between them sits every worktree spawned before the transaction store existed,
or by a route that wrote no terminal event. Nothing automatic came for those.

Re-derived 2026-09-06, on the engine as it stood BEFORE this change, with
`engine/scripts/reap-stale-worktrees.sh /Users/alex/ab/femcboost --discover`
(the coverage line's fields have grown since; this is the baseline it is
measured against):

```
=== summary (DRY-RUN): removed=0 would-remove=3 skipped=37 errors=0 residue=0
    orphan-processes=0 branches-swept=181 branches-skipped=0 ===
=== coverage (DRY-RUN): repos=25 reap-eligible=4 report-only=21 unreachable=0
    worktrees=40 native=11 shells=5 hand-rolled=29 undecidable=0 unresolved=0
    indeterminate=0 operator=10 ===
=== verdict: PENDING — ... would-remove=3 worktree(s) passed every gate and
    NOTHING removed them. ... no automatic mechanism will ever take them. An
    operator removes them by hand. ===
```

The three:

```
/Users/alex/ab/femcboost/.claude/worktrees/agent-a2b51c2b8f6924483
/Users/alex/ab/femcboost/.claude/worktrees/agent-a2c0e6ec671b8414f
/Users/alex/ab/richos-hq-wt/reed-fable-wl1
```

**"An operator removes them by hand, forever" is the defect, not a caveat about
it.** It is the same shape as a check reporting green over something that never
ran: a report whose only remedy is a person, on a machine whose whole premise is
that nothing load-bearing waits for one.

## What adoption is

`engine/scripts/lib/worktree-adoption.py` creates a sealed, terminal
transaction over one exact worktree and hands it to the existing reconciler. The
reconciler's adoption pass (`adoption_pass()`) runs it on the launchd schedule
that already exists.

An adoption is never disguised as a spawn: `kind: "adopted"`, `sealed_by:
"adoption"`, `ingress: "Adoption"`, and the agent id is
`adopted-<sha1(path)[:16]>` — deterministic per path, so a second pass adopts
nothing twice, and visibly not a platform agent id, so nobody reading the
record later mistakes an inferred claim for an observed one. The real owner's
agent ids, teammate name and the authorizing evidence are recorded as fields.

## What happens to an adopted tree — rewritten 2026-09-10 (round 10)

**This section used to argue that adoption could not be made to delete,
because the pipeline it handed to ends in a hard-coded refusal
(`unregister_member -> BlockedFailure("automatic erasure is disabled")`).
That was true, and it was the defect, not a safety property**: an adopted tree
was renamed into a quarantine, archived at full size into
`~/.claude/state/worktree-captures/` and kept. Adoption ADDED disk and
reclaimed none (`worktree-reclaim-round-10-2026-09-10.md`, P4).

An adopted member now carries `cleanup_policy: integrated-daily` and takes the
same lane as every worker's own members (`terminal-daily-cleanup.md`). The
tree stays at its path, owned and untouched, until the reconciler proves it:
tracked bytes byte-identical to a commit `main` contains, an exact unlocked
registration, no untracked file, no process standing in it, no competing
reservation. Ignored files disposable by the committed policy go with the
tree; every other ignored file is archived and verified first. Then a
non-force `git worktree remove` and a compare-and-set branch delete. A dirty,
unmerged, locked or contested tree is HELD with the reason on the member —
never quarantined, never erased.

**Adoption itself still deletes nothing**, and the claim gate below is
unchanged: T1 or T2 authorizes, T3 never does, absence is never evidence, and
a live owner vetoes before any tier. The lane's refusals are the lane's; this
design consults none of them, and every one of them is proven load-bearing by
`scripts/daily-workspace-cleanup.mutation.sh`.

**It is also not "another unchecked override flag".** `ADOPTION_ENABLED` in
`orchestration.config` is an OFF switch: setting it makes the engine do less.
There is no setting anywhere that makes adoption skip a gate, accept weaker
evidence, or erase anything.

## Evidence tiers — what may authorize a claim

A terminal ingress is authorized by a platform event about a specific agent id.
Nothing that reads a filesystem reproduces that, so adoption is authorized only
by evidence of the same KIND: positive, durable, and about an identity rather
than about a path being quiet.

| Tier | Evidence | Authorizes |
|---|---|---|
| T1 | The transaction store marks this agent id terminal — the platform's own event, already on record | yes |
| T2 | A durable ledger record binds this exact path to a session id whose recorded pid+start is `gone` or `reused` in the process table | yes |
| T3 | A persisted `terminated` witness for the exact path ("native isolation worktree registered and unlocked") | **never** |

**T2 is the load-bearing one and it is stronger than it looks.** Every agent of
a session is a thread of one `claude` process, and the ownership ledger records
that process's pid and start time at spawn. When that pid+start is gone from the
table, the CEO's rule that an agent "is forbidden to return" is enforced by the
operating system rather than by a hook. `process_status()` is read from
`worktree-ledger.py` — the same function `judge()` clause 3 uses — so there is
one implementation of this question, not two.

**T3 never authorizes, and that is the line between this design and the nine
that failed.** T3 is an observation a SWEEP made about a lock. "The sweep decided
the agent was gone" is precisely the design the CEO ended. T3 is quoted beside a
refusal as corroboration and does nothing else. On this machine all three
would-remove worktrees carry a T3 witness AND independent T2 evidence; only the
T2 evidence is what authorizes them.

**The live-owner veto runs before any tier.** A worktree path is a reusable key:
a name is freed when a tree is removed and a later session can be given the same
one. If the record binds a path to two sessions, one long dead and one still
running, finding the dead one first and stopping there is a verdict about the
wrong owner — the exact reusable-key failure `worktree-ledger.py` was rewritten
to end. So every session bound to the path is resolved first, and one living
owner refuses the claim whatever else is on record.

**Absence is never evidence.** No tier is satisfied by a missing record, a
missing lock, a quiet directory or an old timestamp.

## The nine gates

All must hold. Every refusal names its gate.

| Gate | Refuses |
|---|---|
| `exists` | the path is not a directory |
| `linked-worktree` | not the top level of a LINKED worktree (a main checkout, a subdirectory, a plain directory) |
| `not-a-container` | another worktree lies underneath it |
| `unclaimed` | a transaction already names the path or its quarantine |
| `unlocked` | git lists the worktree as locked |
| `owner-terminated` | no T1 or T2 evidence, or a live owner |
| `merged` | detached HEAD, missing branch, or commits the repository's HEAD branch does not have |
| `clean` | `git status --porcelain` is non-empty, tracked OR untracked |
| `no-live-process` | a process references the path, or the process table is unreadable |

## What this design would have done on 2026-09-05

The safety document records it:

> The original remover accepted an unknown owner and an unregistered path, then
> recursively deleted the path. The malformed caller supplied the container of
> all worktrees.

Given `/Users/alex/ab/richos-wt` — the container of every richos worktree —
adoption refuses it **four separate times**:

1. **`linked-worktree`.** A container is not a worktree top level. Measured
   today against the live machine: `REFUSED linked-worktree /Users/alex/ab/richos-wt
   is not the top level of a git worktree (git says the top level is '<none>')`.
2. **`not-a-container`**, if it somehow were a worktree. This gate exists only
   for this question and carries two independent probes: the candidate's own
   repository's worktree list sees a workspace registered under it, and a
   shallow listing sees a `gitdir: .../worktrees/` pointer in a subdirectory
   belonging to any other repository, registered or not.
   `worktree-adoption.test.sh` A24/A25 build one fixture for each. Their joint
   limit — a worktree of a different repository nested two or more levels down
   — is declared at `_nested_worktree_pointers`, alongside why widening either
   probe is refused: every gate is O(1) in git calls because `evaluate()` runs
   inside a session-start inventory.
3. **`owner-terminated`.** No ownership record names a container, and absence of
   a record is never a claim. A registration naming it would still not help,
   because gates 1 and 2 fire first — A21 proves exactly that.
4. **The lane itself.** Even a claim that passed all nine gates would hand
   the path to the daily lane, which removes only the exact registered
   worktree the transaction names, through non-force `git worktree remove`,
   after its own proof that the tree is clean and integrated. There is no
   code path from an adoption to a recursive delete of anything.

The failure that day was a single refusal standing between a malformed argument
and a recursive delete. The answer is not a better single refusal.

## Fail-closed hermetic rooting

Adoption reads the ownership ledger and writes the transaction store. A
sandboxed suite that redirected one and not the other would read the operator's
REAL worktrees and rename a live engineer's tree into a temporary directory.

So `adopt()` refuses unless both stores are at their default paths (production)
or both are away from them (a sandbox). The question is asked of the RESOLVED
PATHS rather than of whether an environment variable is set, so a caller passing
`--ledger` that names the default file has overridden nothing. `evaluate()` is
read-only and is allowed in any rooting.

This is what makes the reconciler's adoption pass safe to add to a scheduled job
that other suites exercise: `reconcile-terminal-worktrees.test.sh` sets
`RICHOS_WORKTREE_TX_DIR` and not `RICHOS_WORKTREE_LEDGER`, so the pass refuses
before evaluating a single candidate and costs that suite nothing.

## What is still PENDING, and why it is not a coverage hole

With adoption in place, the same command on the same machine now prints:

```
DRY-RUN REAP agent-a2b51c2b8f6924483 adoptable(T2) — reconcile-terminal-worktrees.py's
    adoption pass claims this one on its next run; no operator action
DRY-RUN REAP agent-a2c0e6ec671b8414f adoptable(T2) — ...
DRY-RUN REAP reed-fable-wl1 adoptable(T2) — ...
=== verdict: PENDING — quarantined=10 ...; would-remove=3 worktree(s) passed every
    gate and this inventory removed none — it is DRY-RUN by construction. ALL 3 ARE
    ADOPTABLE: reconcile-terminal-worktrees.py's adoption pass claims them on its
    next scheduled run and takes each through backup ref, quarantine, capture and
    verification, so NO OPERATOR ACTION is needed to move them out of this line.
    What that pass deliberately does NOT do is erase
    (docs/workspace-retirement-safety.md), so they will reappear as quarantined=
    above and stay there until an enforced access boundary exists — retention by
    ruling, not a coverage hole ===
```

**Nothing has been adopted on this machine.** The three are reported adoptable
by a read-only evaluation; the claim itself is a mutation of shared state and
belongs to the land, not to the branch that wrote it. The end-to-end claim —
backup ref, rename to quarantine, files preserved, second pass refused — is
exercised in the hermetic sandbox by `worktree-adoption.test.sh` A50–A58.

The verdict as a whole stays `PENDING`, and it must. Adopted worktrees reappear
as `quarantined=N`, because the reconciler retains every quarantine by the
ruling in `workspace-retirement-safety.md`. **That is retention by ruling, not a
gap between two tools.** The residual manual step is the one that document
deliberately keeps: reclaiming the disk requires the enforced access boundary it
describes, and until that exists an operator recovers or erases a quarantine
deliberately, with `workspace-retire.py restore`.

The difference is the whole point. Before: an operator had to DECIDE, per
worktree, with no archive, and nothing would ever prompt them. After: every
adoptable tree is captured, verified and named in one place, and what waits for
a person is a single documented decision about disk rather than a hunt.

## Verification

- `engine/scripts/lib/worktree-adoption.test.sh` — 38 cases, 2m24s including
  its harness. Organized by refusal, with an accepting twin beside each one so a
  resolver that refused everything cannot pass.
- `engine/scripts/lib/worktree-adoption.mutation.sh` — 13 mutants, one per
  refusal, each proven to turn its named case red.
- `engine/scripts/reap-stale-worktrees.test.sh` — cases 13b–13g cover the
  record-driven residue pass, its negative control, transaction-owned
  exclusion, transaction-sourced shell labeling, and both halves of the
  adoptability annotation.
