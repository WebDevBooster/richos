# BLOCKED.md — a false premise in the brief, NOT a stall

**Status: proceeding.** Nothing in this task is waiting on an answer. This file
exists because my brief states a premise that is false, the CEO is owed the
correction, and the mailbox is lossy.

## The false premise

The brief says the rule "already exists in three places and none of them
holds", and names the third as
`engine/scripts/hooks/notice-unasked-deferral.sh` — "reports, never blocks."

There is a **fourth** place, and it is not a report:

    engine/scripts/hooks/guard-idle-land.sh  +  guard-idle-land.py
    BLOCKING Stop hook, landed 2026-08-30, registered on BOTH surfaces
    (hooks/hooks.json and .claude/settings.local.json), 886 lines of analyzer,
    637 lines of suite, measured over 1,082 real turns before it shipped.

Its header sentence is the brief's own specification, already written:
"Refuses to let a turn end when the session LANDED work and STARTED NOTHING."

So the CEO's fix was already built, two days ago, and it did not hold. That is
a more important fact than the brief's version of events, because it means the
answer is not "build a blocking gate" — it is "find out why the blocking gate
did not fire and close that."

## Why it did not fire — measured, not guessed

`.claude/state/idle-land-checks.jsonl` in `/Users/alex/ab/femcboost` is the
gate's own observation record. 107 landing turns across three sessions:

| verdict | turns |
|---|---|
| `dispatched` (correctly silent) | 60 |
| `background-running` (**stood down**) | 44 |
| `backlog-empty` (correctly silent) | 2 |
| `block` | **1** |

**41% of every landing turn was suppressed by term 4.** In the CEO's live
session (`374e6f14`) it is 12 of 20 — 60%.

Term 4 reads `background_tasks` from the Stop payload and stands the whole gate
down if ANY entry is running. Against the shipping binary (2.1.252), that field
is `taskRegistry.all()` filtered to `status in {running, pending}`, over these
types:

    local_agent -> subagent      in_process_teammate -> teammate
    local_bash  -> shell         monitor_mcp/ws      -> monitor
    local_workflow -> workflow   mcp_task, dream, auto_mode_scan, remote_agent

So a monitor, a leftover background shell, a dream, an auto-mode scan, or ANY
one of the ten-to-fifteen teammates this orchestrator keeps running at all times
disarms the gate completely. The gate is not enforcing a rule; it is enforcing
"unless anything at all is running", and something always is.

The brief's own case 3 is narrower than that suppressor, and the narrowing is
the whole fix: *"another teammate is still running **and the next step depends
on its result**."* Dependency is what the record's `Blocked by` column already
states. A row the record calls unblocked is, by construction, not waiting on the
running teammate.

## What I already tried

Nothing failed. The diagnosis above is the result of reading the gate, its
observation log, and the binary's own task-registry construction.

## The smallest question that would unblock me — and it is not blocking

Only this, and it is a preference, not a prerequisite: **would the CEO rather
see one gate or two?** I am extending `guard-idle-land` rather than adding a
second blocking Stop hook beside it, because two gates with overlapping
predicates would refuse the same turn twice with two different explanations,
and the second one would inherit the first one's registration, sandbox and
tripwire debt for no gain. If the answer is "two", the work splits cleanly and
costs about an hour.

## What I am proceeding on meanwhile

All of it. Extending `guard-idle-land` to the brief's specification:

1. widen the trigger from "landed" to "work was COMPLETED" — a confirmed land
   **or** an agent completion observed in this turn's own transcript window
   (`<task-notification>` + `<status>completed</status>` + `Agent "…" finished`,
   which is structured, host-written and turn-scoped by its own promptId);
2. replace the blanket `background_tasks` stand-down with the honest version —
   work STARTED this turn (an `Agent` call or a background task this turn)
   suppresses; work merely still running does not, and is named in the refusal;
3. add the three legitimate stops: an `AskUserQuestion` this turn, the
   operator's own hold (widened to "going to bed"), and the DECLARATION;
4. the declaration is `stop-declared: <case> — <reason>` in the final message,
   one of three named cases, a real sentence required, echoed to the operator by
   `systemMessage` and logged — a bare marker exempts nothing;
5. a refusal text that names what completed, what is unblocked and available,
   and the exact declaration line that would have permitted the stop.
