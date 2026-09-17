# Escalation: Both numbers in the brief's Done-when read differently after this lands, and one of them cannot go green by design

- id: `esc-20260917T161346Z-4b04912f`
- raised: 2026-09-17T16:13:46Z
- from: norm-opus-seat1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-seat1` (branch `cc/norm-opus-seat1`)
- head: `28e3f18f1c611350c44385a511375e9251e26352`
- state: **work-complete**
- for: lead

## The question

Confirm the acceptance reading: probe A line B green + 219/285 pins, or is a literal PROBE B section green still expected?

## What was already tried

Ran the review-4 probes before and after; ran the spec's pin checker at 5e7a632e (285/285) and at this branch tip (219/285), classified every red.

## Proceeding meanwhile

Work is complete and committed on the branch; nothing is blocked.

## The evidence

### 1. "probe B green" — the brief's own quotation resolves it, and the other reading cannot be satisfied

The brief quotes the failing line it wants turned green as:

```
B  the assignment REPORTS: work-seat `observe` -> RevisionConflict: active context
   revision conflict: expected 1, actual 4
```

That line is **PROBE A, line B**. It is now green:

```
== PROBE A: the seat holds, and then the assignment cannot report ==
A  the seat's own fence still passes (5.8c, TRUE)          -> True
B  the assignment REPORTS: work-seat `observe`             -> {'event_id': 'evt_a41d…', 'sequence': 21, 'duplicate': False}
C  a second report, same seat                              -> {'event_id': 'evt_68bc…', 'sequence': 22, 'duplicate': False}
```

The section HEADED `PROBE B` is still red, and it cannot be made green without
contradicting the spec. It does not call the adapter at all: it calls
`EventStore.append` directly with no `person_id`, reproducing by hand what
`adapters/app.py:160` used to do. It can only turn green if `EventStore.append`'s
default person stops being `PERSON_ID` — and §5.8b pins that line as
**Unchanged**, on purpose: *"it is the reason both rows above were invisible"*.

The defect that probe B demonstrates IS fixed, at the adapter, and is pinned by a
test carrying both arms: `a_work_seat_can_still_REPORT_after_three_ceo_turns`
asserts that the same `continuity.item_closed` append raises
`expected 1, actual 4` without the seat and succeeds with it.

### 2. The pin checker is 219/285 at this tip, and 66 of the 75 reds are line movement

```
$ python3 docs/plans/background-work-spec-2026-09-17-pins.py 5e7a632e
285/285 pins green at 5e7a632e

$ python3 docs/plans/background-work-spec-2026-09-17-pins.py 28e3f18f
219/285 pins green at 28e3f18f
```

Every failing row is in one of the five files this change edits:

| file | FAIL rows |
|---|---|
| `richos/engine/mega-lander/app.py` | 21 |
| `richos/engine/ecs/adapters/app.py` | 17 |
| `richos/engine/ecs/core/ecs_core.py` | 17 |
| `richos/engine/ecs/core/ecs_inspect.py` | 7 |
| 4 COUNT rows | 4 |

The checker's own docstring says this is its designed output, not a regression:
*"running it at a NEWER commit prints exactly the 'which pins have moved' table"*,
and two of the four COUNT rows are the ones it says *"are SUPPOSED to go red the
day 5.8b lands"* (`adapters/app.py:159-164` and `:183-188` asserting NO
`person_id`). The other two count rows moved for the same reason the content rows
did: `current_context(` 9 → 12 and `store.append(` 3 → 4 in the adapter.

Nine further rows would have gone red for no reason but a paragraph's position —
`docs/architecture/desktop-work.md` pins nine lines, all above where the new
seat paragraph first sat. The paragraph now sits at the end of `## Lifecycle`,
which is where recovery already lives and is the better home for it anyway, and
all nine are green again.

**So the number to expect at the land is 219/285, and the pin file is a currency
proof for the SPEC against its basis rather than an acceptance gate for the build
the spec describes.** If it is wanted green at the tip, the row ranges have to be
re-derived against the post-change source — a different piece of work, and one
that should not be done by whoever moved the lines.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T161346Z-4b04912f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T161346Z-4b04912f --disposition "<what you decided or did>"
