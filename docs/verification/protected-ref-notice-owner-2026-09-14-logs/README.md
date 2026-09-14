# Who reads the protected-ref notice — the answer, and the evidence for it

On 2026-09-14 (`b68a61be`) the engine's protected-ref check stopped moving a ref
back and started only reporting. The engineer who made that trade raised the gap
himself: *"who reads that notice is not mine to decide."*

**Nobody did.** That is the finding, established from the code before anything
was designed.

## What the check did with its finding BEFORE this change

Three sinks, and not one of them puts anything in front of a person:

| Sink | Written at | Who reads it |
|---|---|---|
| a `protected-ref-moved` row in the workspace store's `events.jsonl` | `engine/scripts/lib/workspaces.py:2512` | **nobody** — no hook, no script and no gate in the engine reads that event class (`01-before-and-after.txt`, section 3, greps the tree) |
| a row on the agent's own record | `engine/scripts/lib/workspaces.py:2526-2534` | nothing surfaces it |
| `=== PROTECTED REF MOVED: … ===` | `engine/scripts/hooks/observe-created-refs.sh:130` | the **stderr of a PostToolUse hook that exits 0**. The engine's own measured channel table (`engine/scripts/lib/stop-hook-notice.sh`, lines 20-35, Claude Code 2.1.251) records that combination as transcript-visible and **operator-invisible**. It is also printed into the session of the agent that made the move — the one party who cannot decide whether the move was allowed. |

So the automatic action had been replaced by a notice with no reader, which is
the shape the CEO named: a safety mechanism dying quietly.

## What now owns it

`engine/scripts/hooks/notice-protected-ref-moves.sh` — a **non-blocking Stop
hook**, on `systemMessage`, the one channel measured to reach the operator. The
lead is the owner because the branch is one only the lead may move (worktree
spec, point 14).

It does **not** re-announce the check's inference. It asks one mechanical
question, later, at rest:

> **Is the tip the branch held when the agent's call started still on the
> branch?**

* reachable -> **HEALED**, silent. The lead's ordinary land, the doorway merge
  that was later landed, a deletion re-created: every benign shape collapses
  here. It is also what all three real 2026-09-13/14 incidents look like today,
  because a human recovered them — so on this machine the hook is silent, and
  that is the correct answer rather than a missing one.
* not reachable -> **OPEN**. Commits that were on a protected branch are not on
  it any more. No threshold, no heuristic, no false-positive class.
* unaskable (repository, branch or object gone) -> **UNDECIDABLE**, announced
  exactly as loudly as OPEN.

**Why the check itself cannot ask this:** it runs at a PostToolUse, mid-land,
holding one agent's minutes-stale snapshot. At that instant "main moved" and
"commits were lost" are indistinguishable — the two modes of the oscillation
reproduction have identical shapes and opposite consequences. At rest they are
two facts and one `is-ancestor` separates them.

**What happens if nobody reads it:** it gets louder, not quieter. The state key
carries an age bucket per finding (1 h / 24 h / 72 h) and the announcement
recurs hourly while it stands, so it cannot go silent for a working day. The
de-duplication ledger is per session, so a move made while the lead was away is
on his screen at the end of his first turn of the next session.

**What closes it:** the tree healing itself (no one has to do anything), or a
person settling it on purpose —
`protected-ref-moves.py review --repo … --branch … --tip … --why "<reason>"`,
which appends one `protected-ref-move-reviewed` row to the SAME event log
through `workspaces.py`'s own `event()`. `--why` is required and may not be
blank: a settlement with no reason is a mute button.

**No blocking refusal, no config key, no escape hatch.** The check stopped
writing because its inference was wrong; a blocking version of the same
inference would be the same defect with a heavier instrument. Losing a commit on
purpose is something the lead does, so the answer is his and not a hook's.

## Re-running any of it

    docs/verification/protected-ref-notice-owner-2026-09-14-logs/demo.sh
    docs/verification/protected-ref-notice-owner-2026-09-14-logs/check-reverted.sh
    engine/scripts/hooks/protected-ref-moves.test.sh

Neither script reads or writes the operator's real state: both redirect the
workspace store with `RICHOS_WORKSPACES_DIR` and work in their own temporary
directory.

## The files

| File | What it is |
|---|---|
| `01-before-and-after.txt` | The same finding put to two worlds. **All 18 pre-existing registered Stop hooks were driven against it and 0 mentioned it** — that is the "revert it and the notice is invisible" proof, swept rather than argued. Then the new hook, same finding, same payload, and the sentence a person actually sees, verbatim. |
| `02-the-new-cases-against-the-reverted-engine.txt` | Three reverts in scratch mirrors, each turning its NAMED case red: the predicate deleted (P01), the notice put back on stderr at exit 0 (P01), the UTC age conversion reverted under a forced `TZ=Europe/London` (P14). The unmutated mirror is 15/15 green in the same harness. |
| `demo.sh`, `check-reverted.sh` | The two scripts above. |

## One defect this work found in itself

The first run of `demo.sh` reported a row written seconds earlier as **"1 h
ago"**. `time.mktime(...) - time.timezone` takes the *standard* offset rather
than the one in force, so under summer time every finding was aged an hour — and
the age is the rung the notice escalates on, not decoration. Fixed with
`calendar.timegm`; case **P14** holds it, and `check-reverted.sh` R3 forces
`TZ=Europe/London` so that control does not depend on the reader's own clock.

## What a land still has to do

`install.sh` mints the `.sha256` sidecars and they are gitignored, so the new
hook is not enforcing until it is rerun after the merge. `contract-integrity.test.sh`
section `base` covers exactly that and was green here (`2.post-install-probe-rc-0`,
`SC1.every-registered-hook-starts-in-a-sandbox`). Hooks snapshot at session
start: this hook is inert until the next session.
