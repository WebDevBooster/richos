# The background job dies at turn end — what it actually was

**2026-09-18, echo-opus-settle1.** Candidate .10 (`v1.2.0-nightly.20260918.5`, source
`3633ea76`) failed Ray's walk twice with the same card and an untouched fixture repository.
Escalation `esc-20260918T190301Z-eefbb58b`. This is what the evidence said, in the order it
said it, including the two things this slice got wrong on the way.

Everything below is re-runnable. Where a run is quoted, the command is
`examples/work_lease_roundtrip ENGINE ENGINE/runtime SECONDS`, which drives the production
`spawn_work` constructor, a real provider and a synthetic fixture repository.

## 1. The card, and which of its three readings fired

`native.rs`'s turn-end settlement check refused on
`!is_attributed() || active > 0 || liveness_unknown > 0`, killed the owning child and
returned the Protocol error the CEO read. Nothing recorded which condition was true.

From the app's own callback journal for Ray's work-lease session
`0320b4d4-95f4-4a25-8d2b-950bcaa2d728` (18 rows), and reproduced by the diagnostic this
slice adds:

```
unattributed=None  active=0  liveness_unknown=1  open=[(a8be1462f8bb88ad4, "unknown")]
```

`active` was structurally 0 — `app_workers::status` only ever read `SubagentStart` and
`SubagentStop`, so every open run came back `liveness_unknown` whatever was known about it.

**The brief's premise was wrong in a way worth recording.** It read the failure as the front
desk's turn ending before a background job. It is not the front desk's turn: the failing
turn is the WORK lease's, and the back end's turn IS the job (`work_host.rs`'s `run_one`).
The check fires at `native.rs`'s `Cognition::prompt`, and `work_host.rs:1953`'s
`[richos] work: reported to him as …` is what puts it on his screen.

## 2. Why the worker was open at turn end

Ray's journal, rows 15–18:

```
15 PreToolUse  Agent   tool_input   "run_in_background": true
16 SubagentStart       richos-app-engine:worker  agent_id a277e633d501dceb3
17 PostToolUse Agent   tool_response {"isAsync": true, "status": "async_launched", …}
18 Stop
```

No `SubagentStop` in any of that state root's 18 evidence sessions. `prepare`
(`mega-lander/app.py`) stamps `run_in_background: True` on every payload it hands the back
end, so `Agent` returns the instant the worker starts and the turn ends with it running.

**RED, reproduced on the shipped candidate's own engine** (sha256 `5696e5e01960`, extracted
from `richos-engine-1.2.0.tar.gz` in the release directory):

```
t+  43.085s  Failed :: Worker settlement could not be verified at turn end. …
FIXTURE AFTER head=24e4f5d6 (unchanged)   notes.txt = "hello\n"
```

Ray measured ~39 s and the same untouched fixture, so this is his failure, not a lookalike.

## 3. The thing this slice tried first, and the evidence that killed it

Four parts of the flow need the worker to END inside the turn — `DESKTOP.md` step 4,
`refresh()`'s `run-ended`, `prepare(role="reviewer")`, and `observe()`'s reviewer verdict off
`SubagentStop` — so the first fix made the dispatch synchronous (`run_in_background: False`).
It is wrong, and two independent things say so:

- **`guard-worktree-isolation.sh` clause 7b** refuses a file-capable spawn with
  `run_in_background: false` outright. Replayed offline against the captured payload:
  *"spawn it as a background teammate … so the orchestrator can land it when it finishes."*
- **The engine's own agent-id binding depends on the async ordering.** `workspaces.py`'s
  `bind_agent` — the only thing that joins the platform's agent id to the app receipt that
  `worker_context` looks the worker up in — runs at `PostToolUse[Agent]`. Synchronously that
  does not fire until the worker has already finished. Measured: the worker started and had
  every one of its own tool calls refused with *"worker identity has not joined its app
  receipt; no tool action is allowed yet"*, then handed back four times having done nothing.

So the payload is asynchronous because nothing else works. That is now written beside the
line and pinned by a named test, so the next reader changes the host instead.

## 4. The instruction that named a tool which does not exist

`DESKTOP.md` step 4 told the back end to *"wait for the actual worker through TaskOutput with
`block: true`"*. **`TaskOutput` is not in a work lease's tool inventory.** Read off the
child's own `system/init` frame on 2026-09-18 — 30 tools:

```
AskUserQuestion Bash CronCreate CronDelete CronList DesignSync Edit EnterPlanMode
EnterWorktree ExitPlanMode ExitWorktree ListAgents Monitor NotebookEdit PushNotification
Read RemoteTrigger ReportFindings ScheduleWakeup SendMessage Skill Task TaskStop WebFetch
WebSearch Workflow Write + the five mcp__richos_work__*
```

No `TaskOutput`, no `BashOutput`. That is why it was never called in any run measured:

| run | lease tools | wait instruction | `TaskOutput` calls | outcome |
|---|---|---|---|---|
| candidate .10 (Ray) | deferred | `DESKTOP.md` step 4 | 0 | card at ~39 s |
| roundtrip, shipped engine | deferred | `DESKTOP.md` step 4 | 0 | card at 43.085 s |
| roundtrip, `ENABLE_TOOL_SEARCH=false` on the work lease | resident | `DESKTOP.md` step 4 | 0 | card at 46.754 s |
| roundtrip, resident + the wait written into the assignment brief | resident | brief + step 4 | 0 (fell back to polling with `ls`, gave up) | card at 53.903 s |

The tool-residency experiment in row 3 was **reverted**: its premise was that `TaskOutput`
had to be discovered first, and row 3 disproves that premise itself. `tool_residency_env`
is left exactly as `cc/echo-opus-toolsearch1` landed it.

## 5. What was changed

1. **`app_workers::status` reads the third row.** A `PostToolUse[Agent]` whose
   `tool_response.status` is `async_launched` names an `agentId`; an open run with that word
   beside it is `active`, one without is still `liveness_unknown`. Arithmetic over rows
   already in the file — no process probe, no mtime, nothing inferred from silence.
2. **The turn-end check refuses on `!is_attributed() || liveness_unknown > 0`.** An orphan is
   still stopped and still reported; a witnessed background run passes. It also logs which
   reading fired and the open agent ids.
3. **`run_one` step 3b: the host waits, then gives the turn back.** It waits for
   `SubagentStop` in the app's own journal — a CEO Stop, a quit, a lost lease or unreadable
   evidence all end the wait at once, and reaching the bound claims nothing — then hands the
   lease one more turn on the same seat and grant. `WORKER_WAIT_ROUNDS = 6`,
   `WORKER_WAIT_BUDGET = 20 min`, `WORKER_WAIT_POLL = 2 s`, each with its reason at the
   constant.
4. **A back end whose turn failed is retired.** `ensure_lease` short-circuits on
   `is_some()`, and several errors reaching `run_one`'s `Err` arm have already killed the
   child. That is Ray's attempt 2: *"The first attempt stopped before finishing did not
   start"* — `prompt` on a dead child returned before anything streamed, so `took_the_turn`
   was false. One work-lease evidence session exists for his two attempts, which is the same
   fact from the other side.
5. **`DESKTOP.md` step 4 and the assignment brief** now say the Agent call returns before the
   worker has done anything, that the back end has no tool that can wait for it, and that the
   app will bring it back.

## 6. GREEN, and exactly how far it goes

Same probe, fixed app, shipped engine plus the two corrected engine files:

```
17 PreToolUse  Agent      18 SubagentStart   19 PostToolUse Agent (async_launched)
20 Stop              <- the turn ends, and the child is NOT killed
21 SubagentStop     <- the positive signal the host waited for
22 UserPromptSubmit <- the continuation turn, same seat, same grant

t+  43.331s  Running :: A helper is doing the work.
t+ 131.992s  Failed  :: The work ran and nothing was landed.
```

The settlement card is gone, the helper survives the turn that started it, and the back end
is brought back to carry on. **The job still does not land**, and the remaining cause is a
different defect: in both end-to-end runs the worker produced no commit, `prepare` refused
the retry with *"I could not give this work its own separate copy of your project, so I did
not start it"*, and the run's `engine-state/target-worktrees/<partition>/` is empty — the
worker had no worktree to write in. Raised separately; nothing above depends on it.

## Suites

- `cargo test -q -p richos-core` — 1335 passed, 0 failed.
- `richos/engine/mega-lander/tests/app.test.sh` — 32 run, 0 failed; 16/16 mutants still
  load-bearing.
- Negative control on the lease-retirement fix: removing its five lines turns
  `a_work_turn_that_failed_retires_its_back_end_instead_of_handing_on_a_dead_one` red at
  *"the failed back end is still standing"*.
