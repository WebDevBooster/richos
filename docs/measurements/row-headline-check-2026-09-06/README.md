# What CHECK 3 costs, and whether it would have caught the thing — 2026-09-06

The row-headline warrant blocks landings. Two numbers decide whether a blocking
check survives contact with a working week, and neither of them is an opinion:

1. **Would it have fired at the landing that produced the defect?**
2. **How often does it fire when nothing is wrong?**

Both are re-derivable from this directory. The scripts read the predicate out of
the tree they are standing in, so running them inside a worktree measures that
worktree's code rather than whatever is on main.

```
python3 docs/measurements/row-headline-check-2026-09-06/replay.py
python3 docs/measurements/row-headline-check-2026-09-06/churn.py
```

Recorded output: `results/replay.txt`, `results/churn.txt`.

## 1. The replay — `results/replay.txt`

The defect: on 2026-09-06 `reed-opus-rc1` re-derived all 35 rows of
`richos-hq` `wiki/open-items.md` and found **16 overtaken**, of which **eleven
had a MATCHING blob pin**. CHECK 1 was green for every one of them.

Warrants were adopted mechanically on the record as it stood at `0dd172a` — the
commit before Reed's pass — and carried forward onto `a45aebd`, after it landed.

| | |
|---|---|
| governed non-terminal rows (of 35) | **26** |
| rows that land changed | **26** |
| rows CHECK 3 fired on | **26** |
| `fired == changed` | **True** |
| rows left untouched, all silent | **9** |
| fired rows carrying Reed's own `RE-DERIVED 2026-09-06` marker | **26 / 26** |

The last line is the false-positive answer and it is why it is measured this
way rather than counted by hand: **every row the check flagged is a row where a
person had just written down a conclusion about the headline and left the
headline standing.** There is no flag on this land that a reader would call
ceremony.

The stamped record checked against itself is CLEAN — the silent case, in the
same run, so "it fires" and "it fires on everything" are told apart.

## 2. Adoption day — `results/replay.txt`, pass A'

The record as it stands, with `ROW_HEADLINE_SECTIONS="3"` declared and no row
adopted:

```
HC  sections=3  required=0  rows=26  stated=0  verified=0  unverified=0
    stale=0  missing=26  broken=0  terminal=0
blocking violations: none
```

**Zero refusals, 26 rows named.** That is `ROW_HEADLINE_REQUIRED=0`, and it is
the reason adoption cannot break the day it happens: this record's own
mechanical sweep appends rows to it at a turn end and cannot state a warrant.
`ROW_HEADLINE_REQUIRED=1` turns the note into a refusal when the page is ready.

## 3. The ongoing cost — `results/churn.txt`

Every commit that has ever touched the record, 124 of them:

| | |
|---|---|
| landings that would have fired | **86** |
| row-firings in total | **157** |
| of which the prose changed (SUBSTANCE) | **137** |
| of which only an object id changed (PIN-ONLY) | **20** |
| **median rows per firing landing** | **1** |
| largest single landing | 26 (Reed's pass) |

**One row, on a landing that was already editing that row.** The commit
subjects in `results/churn.txt` are the evidence for that second clause —
*"Row 3.7 re-read"*, *"Row 3.20 re-stamped"*, *"Row 3.5 says what is true now"*.

The 20 PIN-ONLY firings are the arguable class and they are **included on
purpose**. Somebody re-stamping a pin has just been told the work moved, which
is the best moment there will ever be to ask whether the headline about that
work is still true. Reed's finding, in one line: **re-stamping is not
re-reading.**

## What these numbers do not settle

* Whether a headline is TRUE. Nothing that refuses to execute can answer that;
  `scripts/row-headline-verify.sh` re-runs the recorded commands, on demand,
  and is deliberately never a hook.
* Whether the recorded command is the right question to ask. `true` → `` would
  satisfy the grammar.
* Whether a human pastes the printed digest without re-reading the sentence.
  The same limit CHECK 1 has, and the same answer: there is no re-stamp
  command, the digest has to be retyped, and the refusal prints the command to
  re-run beside it.
