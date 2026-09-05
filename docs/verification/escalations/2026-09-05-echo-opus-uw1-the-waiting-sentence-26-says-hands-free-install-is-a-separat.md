# Escalation: The waiting sentence: §26 says hands-free install is a separate design session, my brief says tell him it will install when work finishes

- id: `esc-20260905T121920Z-2a0319b8`
- raised: 2026-09-05T12:19:20Z
- from: echo-opus-uw1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-uw1` (branch `echo-opus-uw1`)
- head: `11ea8caf34f4a4ef14b9ab00eb57b99949e64732`
- state: **proceeding**
- for: ceo

## The question

When an update is found WHILE work is running and he never pressed anything, should RichOS install it by itself at the work boundary (mode 1, which ceo-decisions.md §26 rules is 'a design session of its own'), or say it will offer again once work has finished?

## What was already tried

Read ceo-decisions.md §26 in full. It rules mode 1 (install with no click) as unbuilt and deferred, and updates.js:~330 carries that ruling verbatim in the shipped source. Today's row-u1 decision ('offer to wait and install when all work is finished') was asked about what happens WHEN HE PRESSES INSTALL mid-turn, so it honors a press rather than authorizing an install he never asked for. The extension (hide the button while busy) means he cannot press it while busy, so the two cases separate cleanly.

## Proceeding meanwhile

Building both sentences truthfully rather than picking one: if he DID press (the race window between the paint and the command), the row says it is waiting and WILL install when work finishes, with a cancel control. If he never pressed, the row says an update is ready, that RichOS will not install it while his work is running, and that the button returns when everything has finished. Neither sentence promises something the mechanism does not do. If the CEO wants true hands-free install at the boundary it is a one-line change to the armed-action path, not a redesign.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T121920Z-2a0319b8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T121920Z-2a0319b8 --disposition "<what you decided or did>"

## Answered, same session — and the answer changed what shipped

The lead replied before any of this was written into a file, in these words:
*"You were right to raise it and my brief was wrong. Do not build both sentences
— build the one that is true today. I told you the row 'must promise it will
install when work finishes.' That is mode 1's promise, and §26 records that mode
1 does not exist."*

So the "proceeding meanwhile" plan above is NOT what shipped, and the difference
is worth recording rather than tidying away.

**What was discarded.** The two-sentence design — one for a queued install, one
for an unpressed one — together with the whole queued-action mechanism it needed:
a `waiting` state, an armed deferral that fires at the work boundary, a watcher
that installs when the gate clears, and a cancel control for the queued action.
None of it was written; the answer arrived while the gate itself was still being
built, so the cost was a design that was thought through and not a diff that was
thrown away.

**What shipped instead.** One sentence, mode-proof by construction: *"I'll wait
until everything has finished — nothing will be interrupted."* It does not
promise the control returns and it does not promise RichOS installs by itself;
each of those is true of exactly one of the two update modes, so the sentence
survives mode 1 landing without becoming a lie in either direction. `install()`
and `update_relaunch()` REFUSE while work is live rather than queueing, so
nothing is ever installed that he did not press.

**And a requirement dissolved rather than being met.** The brief asked that a
queued update be cancellable, because *"a queued update he can no longer cancel
is a worse trap than the one being fixed."* With nothing ever queued there is
nothing to cancel — the requirement is satisfied structurally rather than by a
button, which is the stronger form of the same guarantee. It is recorded here
because a reviewer looking for a cancel control will not find one, and the
absence is the answer rather than an omission.

**The mutation that proves it.** Mutation 24 in `app/ui/tests/updates.js`'s
ledger replaces the shipped sentences with *"RichOS will install it when your
work is finished"* — the exact wording the original brief asked for — and it
reddens check 15. The lie the brief would have shipped is now a check.
