# NOT BLOCKED — one relay item, and a corrected premise

**Echo, 2026-08-30, branch `echo/between-turn-machinery-2026-08-30`.**

Nothing is blocked, no answer is needed, and no work is waiting on anyone. The task is
finished, committed, and green. This file exists for the one trigger in the escalation
note that *does* apply — *"a premise in your brief turns out to be wrong"* — and because
the correction needs a writer in a repository I am not allowed to write to, so it would
otherwise live only in a chat message.

## The corrected premise

My brief pointed at `open-items.md` row 3.1 and
`~/ab/richos-hq/docs/plans/richos-techy-mode-2026-08-26.md` §1.5, which names **two**
paths with nowhere to go. The brief was right to say "check the second one before you
build it". Verified at richos `e4fe1cd`:

1. **Gap #1 — between-turn updates unroutable: GENUINELY OPEN. Closed by this branch.**
   `dispatch` carried an explicit comment naming the hole.

2. **Gap #2 — re-prime machinery recorded and never rendered: ALREADY BUILT, before this
   branch.** The doc comment at `acp.rs:546` describes what the code actually does, not an
   intention. It is delivered in five places: `Cognition::reprime` takes the item sink;
   `prime_lease_if_needed`, `request_handoff_summary` and `rotate_lease` each stamp
   `internal: true` / `turn_id: None`; `MachineryJournal::project_thread{,_checked}`
   filters `internal`; `Timeline` refuses it and `Visibility::Internal` renders in no mode.
   I did not rebuild it. What was missing was a test that FAILS if it ever changes, and
   that is what I added (`reprime_machinery_is_recorded_and_can_never_reach_a_rendered_thread`,
   run red by deleting the `internal` clause at the timeline guard).

3. **§1.6 — "the seam change this forces": NO LONGER APPLIES AT ALL.** It was landed
   before this branch. `Cognition::prompt` already takes `on_item: &mut dyn FnMut(TurnItem)`.
   One deviation from §1.6's literal signature is already documented in `cognition.rs`:
   `TurnItem::Text` carries `seq`, because a bare `Text(&str)` would force the spine to
   count text itself, which is the second counter §1.4 G1 exists to forbid.

## What I need someone else to do (not urgent, not blocking)

`~/ab/richos-hq` is outside my worktree and I was told to write only inside it, so I did
not touch it. Two edits belong to whoever owns that repo:

- `open-items.md` row 3.1 — the §1.5 line should say gap #2 was closed 2026-08-28 and
  gap #1 by this branch.
- `richos-techy-mode-2026-08-26.md` §1.6 — strike as already landed, or mark it the way
  §1.1's verify-first caveat is marked ("DISCHARGED <date>, richos `<sha>`"), which is the
  convention that document already uses.

The findings themselves are durable on this branch regardless — they are in the four
commit messages, in `app/README.md`'s landed-work section, and in `STREAMING.md` rule 6.
This file is only so the two hq edits are not carried by the mailbox alone.
