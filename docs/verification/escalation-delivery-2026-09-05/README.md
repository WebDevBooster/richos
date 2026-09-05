# Escalation delivery — row `e1`, verified 2026-09-05

**The claim under test is not "a record was written". That was the old mechanism, and it
worked perfectly.** On 2026-09-02 two teammates wrote a correct `BLOCKED.md`, committed it,
and the files sat unread until a worktree cleanup found them on 2026-09-04. Any check that
asserted "the escalation file exists" would have been green through the whole incident.

So everything below asserts ARRIVAL, and the two hardest cases reproduce the incident rather
than the happy path.

## What was built

| Piece | Path |
|---|---|
| The predicate — ledger, states, ages, rendering | `engine/scripts/lib/escalations.py` |
| Shell wiring, one predicate for three consumers | `engine/scripts/lib/escalations.sh` |
| The teammate's one call, and the lead's reader | `engine/scripts/escalate.sh` |
| Turn-end surfacing | `engine/scripts/hooks/notice-escalations.sh` |
| Session-start surfacing | `engine/scripts/hooks/session-start-escalations.sh` |
| The doctrine every teammate definition carries | `engine/reference/escalation-protocol-seam.md` |
| Its installer | `engine/scripts/install-escalation-protocol.sh` |
| Suites | `engine/scripts/hooks/escalations.test.sh` (55), `engine/scripts/install-escalation-protocol.test.sh` (25) |

The ledger is `~/.claude/state/escalations.jsonl` — outside every repository, every worktree
and every session, the same substrate the worktree ownership ledger already uses.

## The live demonstration

Raw transcript: `raw/live-demonstration.txt`. Re-runnable: `./demonstrate.sh`.

It was run with the escalation raised from a **richos worktree** and both hooks run under
`RICHOS_ENTITY_ROOT=/Users/alex/ab/femcboost` — a femcboost-seated session reading an
escalation raised in a richos worktree, which is the normal shape of this operation and the
case a repository-scoped notice would have hidden.

**1 — the escalation arrives with nothing merged.** The branch tip at the time was
`3c32f5f`; `git merge-base --is-ancestor 3c32f5f <richos main HEAD>` exited **1**, so the
branch was demonstrably NOT merged. The femcboost-seated `SessionStart` hook nevertheless
delivered, to the model's context, the teammate's own question verbatim, its `state`, its
audience, what it had tried and what it was proceeding on — and to the operator, a one-line
`systemMessage`. The turn-end hook delivered the same condition in one line.

**2 — an unacknowledged escalation makes noise, and the noise grows.** Same session, already
announced once, no acknowledgement:

| age | what the operator sees |
|---|---|
| 0m | announced (first observation) |
| 90m | announced again — `1h old` |
| 25h | announced again — `1d old` |
| 75h | announced again — `3d old` |

and a **new session** is told from scratch whatever it has already heard. That last row is the
one that matters: the 2026-09-02 escalations were lost because the session that could have
surfaced them ended. A second turn at an unchanged age is correctly SILENT — the loudness is a
transition, not a nag, because a line repeated under every turn is a line the eye is trained to
skip.

**3 — it closes only on an acknowledgement.** `escalate.sh ack <id> --disposition "..."`
appends a row (nothing is ever deleted), the ledger goes to zero outstanding, and both hooks
go silent — the Stop hook first saying "clear again", because the operator was told the story
started and is owed its end. A disposition shorter than 30 characters is refused; an id nobody
raised is refused.

## The suites

`raw/escalations.test.txt` — 59 cases, all green. The load-bearing ones:

- **Case 3** deletes the teammate's worktree entirely, with its branch never merged, and the
  escalation still lists in full. Delivery does not depend on a merge, or on the worktree
  outliving the teammate.
- **Case 12** is the NEGATIVE CONTROL. The predicate is replaced by one that reports `clear`
  over a live escalation — the historical defect rebuilt on purpose — and both hooks go
  silent; restoring the real predicate makes the same fixture speak again. Without this,
  cases 2, 4 and 7 would be proving nothing.
- **Case 9** proves a raise that could not be written EXITS NON-ZERO and says
  `HAS NOT BEEN DELIVERED` in those words. A raise that silently no-ops would rebuild the
  whole defect quietly.
- **Case 11** proves a `stopped` escalation and a `work-complete` one read differently. A
  mechanism that framed every escalation as a failure would teach teammates not to raise them,
  and both originals were `work-complete` and said so explicitly.
- **Case 15** proves the repository root is never touched, and that a repository with no
  `docs/` gets the ledger row, no file, and an explanation — because creating `docs/` would
  add a tenth root entry, which `ceo-decisions.md` §27 forbids.
- **Case 16** is a SOURCE mutation, not a fixture one. `AGE_BUCKETS` is collapsed to a single
  bucket — which is exactly the mechanism this would have been if the notice de-duplicated on
  the id alone — and the escalation then ages a full DAY in silence: the 2026-09-02 incident
  reproduced inside the suite. Restoring the shipped source makes the same ledger, in the same
  session, speak. It is deliberately NOT a `*.mutation.sh`: eight of this engine's thirteen
  mutation harnesses were run by nothing at all, and a proof nobody executes is a paragraph.

`raw/install-escalation-protocol.test.txt` — 25 cases, all green, including dean.md's SECOND
seam (the definition template every new hire is built from) and the survival of the
`ACK-PROTOCOL-SEAM` block sitting immediately after the replaced span.

## Registration

Both hooks are wired on both surfaces (`engine/hooks/hooks.json` for the by-reference plugin
route femcboost loads, `engine/.claude/settings.local.json` for a seated session) and named in
every inventory: `contract-integrity-probe.sh` Layer R and BR2, and
`engine-status.test.sh`'s acknowledged set. Verified: **BR2 green at 56 managed guards**
registered exactly once on the right event, BR4 green, `engine-status.test.sh` 16/16.

Layer R's byte-identical root-resolution bootstrap holds in both new hooks, checked with Layer
R's own extraction and normalization.

## Two suites are red, and NEITHER is from this branch

Named here so the lander does not spend the land bisecting for them. Both were
reproduced by running the identical suite from the unmodified main checkout at
`/Users/alex/ab/richos/engine`, and this branch touches neither subject.

| red case | where | reproduced on main? |
|---|---|---|
| `9b session-start-reap-worktrees.sh BLOCKED on stdin` | `root-contract.test.sh` | yes — same single failure |
| `C16 states=removed removed` | `reconcile-terminal-worktrees.test.sh`, and through it `contract-integrity.test.sh` case `54.reconciler-suite-passes` | yes — 1 failed, 75 passed |

The first is a real defect of the shape this engine cares about: a SessionStart
hook that blocks on an inherited, never-closed stdin would hang a session start,
which is the 92-second hang `root-contract.test.sh` case 9 was written from.

## What is NOT done here, and is Rich's at the land — IN THIS ORDER

The order is load-bearing, not a preference.

1. **Merge this branch into `richos` main.** The teammate-facing path in the doctrine is
   `~/.claude/richos-engine/scripts/escalate.sh`, and that pointer resolves to
   `/Users/alex/ab/richos/engine` — the main checkout, not this branch. Until the merge, the
   command the definitions would name does not exist on disk.

2. **Then** `scripts/install-escalation-protocol.sh --repo /Users/alex/ab/femcboost` — the
   write into the teammate definitions. Verified read-only with `--check`: **26 seams across
   25 files**, dean.md carrying two (its own copy and the definition template every new hire
   is built from). Until it is run, every teammate still boots with the instruction to write
   `BLOCKED.md`, and the channel is built but unused. Doing it BEFORE step 1 would install a
   doctrine naming a script that is not there yet.

3. **A fresh session.** Hooks are snapshotted at session start, so both halves are INERT in
   the session that lands them. Neither assumes otherwise.

Until all three, the honest status is: the channel exists, is tested, and nothing is using it.
