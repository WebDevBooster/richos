# The false-positive corpus for `guard-idle-land.sh`

A blocking guard that is wrong gets waived, and a guard that is waived habitually
is a formality with a hook attached. So the rate is measured, on real turns,
before the gate is trusted with `exit 2` — and the measurement is reproducible by
anyone who doubts it.

This is the SECOND measurement of this gate. The first one is in the hook header:
1,082 turns, 80 blocks, 14 read by hand. It was a good measurement of the wrong
predicate, and the thing it could not see is the reason for this file — the gate
it validated went on to block ONCE in 107 real landing turns, because a term
nobody had measured stood it down on 44 of them.

## The corpus

**Every turn in every orchestrator transcript on this machine.** Not a sample,
not a hand-picked set, and not turns written for this purpose.

| | |
|---|---|
| Source | `~/.claude/projects/{-Users-alex-ab-femcboost, -Users-alex-ab-richos, -Users-alex-ab-richos-hq}/*.jsonl` |
| Session files read | 18 |
| Turns replayed | **1,221** |
| Turns where the backlog record existed yet | 923 |
| Span | 2026-08-30 01:49 UTC → 2026-09-01 01:11 UTC |
| Measured | 2026-09-01, against the shipped `scripts/hooks/guard-idle-land.py` |

It is the right corpus for this question for one reason: it is what this
orchestrator actually did, including both of the nights the gate exists because
of. A corpus of invented turns would measure the author's imagination.

Scratchpad sessions are excluded deliberately. A throwaway session in a temp
directory is not a turn this gate governs, and including several hundred of them
would dilute the rate with traffic the predicate can never fire on.

## Regenerating it

Each turn is a `promptId` span. The Stop payload is rebuilt **as it stood at that
turn** — the transcript truncated where the next prompt begins — and the four
terms are read from the same functions the hook uses:

```
read_turn -> landing_ops -> confirm_landing      term 1a
             agent_finishes                      term 1b
             started_work                        term 2
             "AskUserQuestion" in tools / hold_signal   term 3
             parse_record(<the record AS IT STOOD>)     term 4
```

**Term 4 is supplied historically and that is not an optimization.** `main()`
resolves the backlog record from the repositories the turn landed in and reads
that file AS IT IS NOW. Today's record has zero unblocked rows, so a naive replay
returns `backlog-empty` for all 1,221 turns and measures nothing. The harness
therefore uses the newest commit of `RICH-TODOs.md` whose committer date precedes
the turn. The plumbing between the terms is covered by 57 suite cases; what needs
measuring is how often the PREDICATE fires on real traffic.

Two things cannot be reconstructed, and are named rather than hidden:

* **`background_tasks`** is run-time state a transcript does not record. Under the
  new predicate it no longer votes, so its absence changes no verdict — it only
  affects a count that is REPORTED inside the refusal. Under the OLD predicate it
  decided everything, which is exactly why the old measurement had to bracket it
  and why this one does not have to.
* **A push is confirmed by `HEAD == upstream`**, which is a fact about today. A
  merge is confirmed by ancestry, which was true then and is still true now. The
  first measurement of this gate ran under the same approximation.

## The funnel, all 1,221 turns

| | turns | |
|---|---|---|
| completed nothing this turn | 709 | silent, and correctly — the commonest turn there is |
| completed something, then STARTED something | 161 | silent, correctly |
| completed, started nothing, but ASKED THE CEO | 5 | silent — a suppressor that did not exist before |
| completed, started nothing, operator called a hold or was off duty | 3 | silent |
| the backlog record did not exist yet | 298 | not evaluable; `RICH-TODOs.md` is younger than the corpus |
| completed, started nothing, nothing owed, **backlog empty** | 20 | silent, correctly |
| **completed, started nothing, nothing owed, an unblocked row waiting** | **25** | **FIRES** |

**2.0% of all turns. 2.7% of the 923 evaluable ones. 56% of the 45 turns that
reached term 4** — which is the number that matters, because those 45 are the
turns that completed work and started nothing, and the CEO's complaint is that
they happen constantly.

## The 25, adjudicated by hand — every one of them

A fire is a FALSE POSITIVE only if stopping was right AND none of the three
declared cases could honestly have been written. On that test:

| | fires | what they were |
|---|---|---|
| **the target failure itself** | **15** | landed or a teammate finished, a report was written, nothing started, unblocked rows sitting in the record. Four of them close with "Eight agents running", "Seven agents running", "Six agents running" — the disarm doing its work in plain sight. One is a deferral announced rather than chosen: *"it goes with the next real land… that's a sequencing call I'm making."* |
| legitimate stop, `ceo-owns-it` | 5 | the turn's deliverable WAS a question or a handoff to him: six design variants with "name what you want kept", two 15-minute rulings with "nothing else is startable without that ruling", a restart pointer ending "restart whenever you're ready". Every one asked in PROSE. Had the question gone through `AskUserQuestion`, term 3 would have suppressed them silently — and the CEO-ask gate already requires exactly that. |
| legitimate stop, `waiting-on-teammate` | 5 | a named collision or dependency: *"a second agent there today would buy a guaranteed merge conflict"*, *"`echo-opus-toolstatus1` is running that measurement now"*. All five name the teammate in the reply, so the declared sentence is a paste, not an invention. |
| **no honest route existed** | **0** | — |

**So: 15 of 25 fires are the failure the CEO has been reporting for months, 10
are legitimate stops that cost one declared sentence, and there is no shape in
this corpus that the gate refuses with nowhere to go.**

### The number to argue with, stated as the objection

40% of fires would be waived by a declaration, and habitual waiving is how a
defense decays into a formality. Three things bound it, and they are the reason
this ships blocking rather than reporting:

1. **Half of that 40% disappears on a tool call.** The five `ceo-owns-it` fires
   are turns that put a question to him without using `AskUserQuestion`. That is
   already an engine requirement, enforced elsewhere; when it is met, these
   turns never reach the verdict.
2. **A declaration is not free.** It names one of three cases and gives a reason,
   in the reply the CEO reads, echoed to him by `systemMessage` with "DECLARED
   AND NOT VERIFIED" attached. Every one of the ten is countable in
   `idle-land-checks.jsonl`, so "he is declaring every turn" is a measurable
   claim rather than a suspicion.
3. **The cost of a fire is one turn, structurally.** `stop_hook_active` is true
   on the re-fire and the gate stands itself down, so it can refuse a given turn
   AT MOST ONCE. The worst case is not a wedged session; it is one more turn, in
   which the answer is either to dispatch the row or to say why not.

### The shape this measurement CANNOT rate, said plainly

**A finish-only turn.** Only 1 of the 25 fires had no land in it, which looks
like the second trigger barely matters. It is an artifact of the corpus, not a
property of the trigger: the `<task-notification>` has to fall inside the turn's
own promptId window, and in these sessions a completion is usually answered in
the same turn as a land. The trigger is asserted structurally instead, by cases
AA through AA5 in the suite, and its narrowings are each proven load-bearing by a
mutation. The honest statement is that this corpus does not contain enough
finish-only turns to rate it, rather than that it rated well.

## What the old predicate scored on the same machine

Not reconstructed — READ OFF THE PRODUCTION LOG the gate wrote while it was live,
one line per landing turn, 107 turns across three sessions:

| verdict | turns |
|---|---|
| `dispatched` — correctly silent | 60 |
| `background-running` — **STOOD DOWN** | 44 |
| `backlog-empty` — correctly silent | 2 |
| `block` | **1** |

That is the measurement that matters most in this file, because it is not a
replay of anything: it is what the shipped gate actually decided, at Stop time,
with the real payload in front of it. **41% of every landing turn was waved
through by a term nobody had measured**, and in the operator's live session it
was 12 of 20.
