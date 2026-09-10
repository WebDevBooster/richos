# Finish-row owner resolution — the evidence, 2026-09-10

The finish-row completion in `worktree-ledger.append()` was shipped, green, and
produced NOTHING for two days: it resolved `SubagentStop`'s `agent_id`, which is
a per-run identifier, and nothing is registered under one. The repair is one
sentence — **prefer the key that RESOLVES, not the key that is PRESENT** — and
the acceptance is deliberately not a function call, because a hand call with the
owning id is exactly what made the broken version look wired.

Files here: `run-live-proof.sh` (a real session, a real subagent, the registered
hook), `make-mutant-engine.sh` (the same run with the fix flipped back), and
`measure-completion-rate.py` (read-only, over the real ledger).

## 1. The real row, written by the registered hook at a real SubagentStop

`run-live-proof.sh` started a claude session in
`/Users/alex/ab/femcboost/.claude/worktrees/agent-a8b88e0ef2db330a5`, that
session launched a subagent, and the harness fired `SubagentStop` at
`worker-ended-handoff.sh` as it sits in the worktree. The payload — captured
verbatim by a second registered hook, so the per-run id is demonstrably the
platform's and not this script's:

    {"session_id":"6630c4ae-69c7-4d15-97f4-7b6f54ac8cf5",
     "cwd":"/Users/alex/ab/femcboost/.claude/worktrees/agent-a8b88e0ef2db330a5",
     "agent_id":"a038af2ce831bf9d1","agent_type":"pinger",
     "hook_event_name":"SubagentStop","stop_hook_active":false, ...}

The row that hook wrote, verbatim, at `2026-09-10T16:38:26.918177+00:00`:

    {"agent_id": "a038af2ce831bf9d1", "event": "finished",
     "owner_agent_id": "a8b88e0ef2db330a5",
     "session_id": "6630c4ae-69c7-4d15-97f4-7b6f54ac8cf5",
     "signal": "SubagentStop", "source": "worker-ended-handoff.sh",
     "task_id": "", "teammate": "zach-opus-key1",
     "ts": "2026-09-10T16:38:26.918177+00:00",
     "workspaces": ["/Users/alex/ab/femcboost/.claude/worktrees/agent-a8b88e0ef2db330a5",
                    "/Users/alex/ab/richos-wt/zach-opus-key1"],
     "worktree": "/Users/alex/ab/femcboost/.claude/worktrees/agent-a8b88e0ef2db330a5"}

Two folders, which is every folder that assignment holds — the native worktree
and the cross-repository one, the class of workspace no finish row had ever
named. `agent_id` is still the run's own id; `owner_agent_id` records the key
the completion used.

For contrast, from the same file: two rows the INSTALLED (unrepaired) hook wrote
for that same worktree minutes earlier, in the live session.

    {"agent_id": "a12761c7529f62322", ..., "teammate": "",
     "worktree": "/Users/alex/ab/femcboost/.claude/worktrees/agent-a8b88e0ef2db330a5"}
    {"agent_id": "a7d9b77a8cc96c9b7", ..., "teammate": "",
     "worktree": "/Users/alex/ab/femcboost/.claude/worktrees/agent-a8b88e0ef2db330a5"}

Three different `agent_id` values, one agent. That is the defect in three
adjacent lines.

## 2. The mutation — the same real run, with the fix flipped back

`make-mutant-engine.sh` restores `if not agent_id` (prefer-the-present) in a
throwaway engine copy. `run-live-proof.sh` against it, same harness, same real
subagent:

    {"agent_id": "ad7decdb51ecef649", "event": "finished",
     "session_id": "8d990c00-fb6a-4441-9359-71dafce1304b",
     "signal": "SubagentStop", "source": "worker-ended-handoff.sh",
     "task_id": "", "teammate": "",
     "ts": "2026-09-10T16:38:54.910024+00:00",
     "worktree": "/Users/alex/ab/femcboost/.claude/worktrees/agent-a8b88e0ef2db330a5"}

Blank teammate, no workspaces, no `owner_agent_id`. The condition is what
produces the row, not the code around it.

At unit grain the same property is proven by
`engine/scripts/lib/finish-row-completion.mutation.sh` (five mutants, each
turning a NAMED case red), invoked from the suite it mutates.

## 3. The rate, before and after

`measure-completion-rate.py`, read-only over the real ledger:

    every finish row ever written        15,929 | today     4 (0.03%) | after 2,990 (18.8%)
      inside an agent's own worktree     10,859 | today     4 (0.04%) | after 2,948 (27.1%)
      elsewhere (lead session, tests)     5,070 | today     0 (0.00%) | after    42 (0.8%)
      written 2026-09-10                  2,627 | today     4 (0.15%) | after 2,257 (85.9%)
        ... in an agent's own worktree    2,257 | today     4 (0.18%) | after 2,257 (100.0%)

The same holds for 2026-09-08 (407 of 407) and 2026-09-09 (283 of 283). For rows
written AFTER this change, the rate is **100% of rows written inside an agent's
own worktree**, and the historical 18.8% is dominated by sessions that predate
the registration record at all.

## 4. What this resolution still cannot identify

* **A row written outside an agent's worktree.** 5,070 of 15,929 — the lead
  session's own `SubagentStop`s, whose `cwd` is the repository root. There is no
  second key there and none is invented.
* **`TeammateIdle` and `TaskCompleted` rows.** 2,805 of them; not one resolves by
  either key, because those hooks fire in the lead's session with the lead's
  `cwd`. This fix does nothing for them, and nothing here should be read as
  though it did.
* **An agent nothing ever registered**, and an assignment given a folder after
  its manifest sealed — the resolution reads the record; it cannot repair it.
* **Which run of an agent this was.** `agent_id` is per-run and is preserved,
  but the ledger holds no run index, so "the third turn of zach-opus-key1" is
  not derivable from these rows.
* **Whether the agent is finished.** Still advisory, still never decisive: an
  agent that stops can be woken again, and reclamation stays anchored on the
  sealed transaction's terminal record.
