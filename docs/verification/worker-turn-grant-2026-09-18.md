# The worker had its own copy of the project all along — what it did not have was permission

**2026-09-18, echo-opus-worktree1.** The settlement card that killed candidate .10's job is gone
(`ff821816`, echo-opus-settle1), and the job still did not land. The escalation that carried it
forward — `esc-20260918T203249Z-fee447b0` — said the worker had no target worktree. **It had one.**
This is what the runs' own files say, in the order they said it, including the premise this slice
was given and disproved.

Everything below is re-runnable:
`examples/work_lease_roundtrip ENGINE RUNTIME SECONDS`, real provider, real engine tree, synthetic
fixture repository, fresh temp state root. Two runs were spent, which is the whole budget this
slice was given.

Environment: macOS 24.6.0 arm64, `claude` 2.1.277 (`/Users/alex/.local/bin/claude`), engine tree
`richos/engine` at this branch, delivered runtime
`/Users/alex/ab/richos-rechecks/deep-20260916/runtime-archive/engine/runtime` (the only delivery on
this machine; read-only to the probe).

---

## 1. RED, reproduced on `ff821816`

```
t+   1.852s  Running :: The back end has started on it.     (run 2's numbers; run 1: t+2.259s)
t+  45.294s  Running :: A helper is doing the work.
t+ 150.987s  Failed  :: The work ran and nothing was landed.
FIXTURE AFTER  head=c38f3f27b2ccb991f88e06eec38f452b72cdaf51 (unchanged)  notes.txt = "hello\n"
```

Same shape as the escalation's: the helper runs, the job fails, the fixture is untouched, and
`engine-state/target-worktrees/<partition>/` is **empty**.

## 2. The three things the escalation's premise got wrong, each from a file in that run

**a. The target worktree WAS created, on the app path, where `app.py:424` says.**
`engine-state/workspaces/<partition>/events.jsonl`:

```
20:44:45  registered-cc  path=…/engine-state/target-worktrees/a94577be…/worker-sonnet-3805b8aa9321
                         repo=…/qa-fixture   branch=cc/worker-sonnet-3805b8aa9321
20:44:45  cc-created     (same path)
20:44:54  registered-spawn  tool_use_id=toolu_019WcY4SGybaPLbEsVSDF6RM
20:44:57  bound             agent_id=a354ca65fa33a0b31
```

It is on the dispatch payload's own `cross-repo-worktree:` line (`callbacks.jsonl` row 17), and the
back end's later `git -C <that path> status --short --branch` answered
`## cc/worker-sonnet-3805b8aa9321` (row 30). Three independent witnesses that the copy existed.

**b. It is empty when anyone looks because it was DELETED — after the fact, and correctly.**
Same log, 60 seconds later:

```
20:45:45  landed   auto=true  as_part_of=<its own key>
20:45:46  deleted  why=landed
```

An agent that produced nothing IS landed (worktree-spec point 7), so the automatic land was
arithmetically right. The disposal is a CONSEQUENCE of the defect, not the defect.

**c. The refusal sentence belongs to the retry, and was never the cause.** The receipt for the
second `prepare` (`continue_of` the first) carries
`problem: "I could not give this work its own separate copy of your project, so I did not start it.
Nothing was created."` — true of that retry, because the agent it named had just been disposed of
and was no longer pending. The first `prepare` was never refused at all: its receipt is
`status: run-ended` with a `workspace_ref`.

## 3. What actually stopped it, in the worker's own words

`callbacks.jsonl`, the red run:

```
17 PreToolUse  Agent      18 PostToolUse Agent → {"status":"async_launched","agentId":"a354ca65fa33a0b31"}
19 SubagentStart          20 Stop          ← the back end's turn ends, BY DESIGN
21 SubagentStop  a354ca65fa
     "Unable to complete or report via tools — the host's PreToolUse hook is blocking all
      tool actions this turn, including SubagentHandback itself, with: 'RichOS desktop
      engine: This app turn is stopped or is supplying context. New actions are
      unavailable.'"
```

`actions_allowed` is the **turn's** grant: `NativeCognition::prompt` opens it at turn start and
closes it at turn end, and `scripts/app-engine-hook.py`'s `PreToolUse` branch refuses **every** tool
call in the session while it is closed — a matcherless registration, deliberately broad, and right
for the lease. The worker is dispatched `run_in_background: true` (it has to be: clause 7b refuses a
synchronous file-capable spawn, and `bind_agent` runs at `PostToolUse[Agent]`), so it does **all** of
its work in exactly the window where that flag is false.

Between rows 19 and 21 the worker made **zero** journal entries, because the turn gate raises
*before* `evidence.capture` — a refused call leaves no trace at all. Its four later
`SubagentHandback` attempts (rows 25, 31, 41) do appear, because by then the continuation turn had
reopened the flag; those were refused by `guard-sealed-worktree.sh`, correctly, since the platform
had already recorded the run as finished.

## 4. The fix — `5138798e`

A worker's authority is its **receipt**, not the turn that happens to be running.

| event | what calls it | the turn's grant | the worker's |
|---|---|---|---|
| a turn ends | `prompt` → `ecs::set_actions_allowed(_, false)` | closed | **kept** |
| the CEO stops | `NativeCancelHandle::cancel` → `ActionGrant::set(false)` | closed | withdrawn |
| the assignment ends | `run_one` step 4 → `revoke_work_assignment` | closed | withdrawn |
| the app crashed | `recovery::close_orphan_grants` | closed | withdrawn |

`ecs::ToolScope` gains `background_work_allowed`, written true in exactly one place
(`bind_work_assignment`'s standing §5.4 grant) and absent-means-false everywhere else;
`ecs::revoke` clears both flags in one write. `app-engine-hook.py` admits a `PreToolUse` carrying an
`agent_id` under that standing grant — **to the worker's own gates, not past them**:
`guard-sealed-worktree.sh`, `validate_shell_target` and `worker_context` all still run, and
`worker_context` refuses any agent id that does not join exactly one live receipt of this session
and this binding, refuses the CEO-scoped `mcp__richos_*` tools outright, and fences every write
inside the registered target worktree. No guard was weakened and the audience declaration is
untouched.

Probed both ways: reverting the hook's condition fails the new hook test on the defect's own
sentence; removing the `Continuity`/`revoke` arm fails the new Rust test with
`a stop left the helper still able to act  left: (false, true)`.

## 5. GREEN, and exactly how far it goes

Same probe, same engine tree, with the fix. The whole of this section was impossible before it.

```
t+   1.852s  Running :: The back end has started on it.
t+  50.247s  Running :: A helper is doing the work.
t+ 280.641s  Failed  :: The work ran and nothing was landed.
```

`callbacks.jsonl`, the green run — the rows that never existed before:

```
20 Stop                    ← the turn that dispatched the worker ends
21 PreToolUse  Bash  af1d4979a9   ← THE WORKER'S OWN CALL, AFTER THAT TURN, ADMITTED
22 PostToolUse Bash  af1d4979a9
34 PreToolUse  Edit  af1d4979a9   notes.txt in its registered target worktree
35 PostToolUse Edit  af1d4979a9
50 PreToolUse  SubagentHandback   51 PostToolUse → {"success":true,"message":"Report delivered to your caller."}
```

- The worker **committed**: `cc/worker-sonnet-11aaf7fa02a8  8ddc3f4  Add a line to notes.txt`.
- A **reviewer** was prepared and dispatched (rows 61–64) — the pending gate's `lands-pending:`
  exemption held — read the commit byte for byte, and **passed** it (row 90):
  *"all five acceptance conditions … parent = main tip, stat shows only notes.txt +1/-0, byte-exact
  resulting content, clean worktree with HEAD exactly at the reviewed commit"*.
- Both receipts end `run-ended`, neither disposed, the reviewed commit intact on its branch.

**The job still does not land, and the remaining cause is a different defect.** Raised as
`esc-20260918T211207Z-52acb812`; nothing in §4 depends on it.

The host's second continuation turn (`callbacks.jsonl` row 95) returned **1.847 s** after the
reviewer's `SubagentStop`, with **zero** tool calls — measured, not inferred: assignment
`updated_at_ms` 1789765580151 minus the reviewer record's `end.at` 1789765578.304184. Nothing can
prepare, review or integrate in 1.8 s.

Why, from the code and the journal together:

- **The platform injects its own turns into this lease.** Of the six `UserPromptSubmit` rows, three
  are the host's (row 2, the brief; rows 58 and 95, `WORKER_ENDED_CONTINUATION`) and three are the
  platform's — rows 52 and 92 (`<agent-message from="…"> [Subagent hand-back]`) and row 55
  (`<task-notification>`). Six turns started, four `Stop` rows: the two turns with no `Stop` are 55
  and 95, each one adjacent to a host prompt.
- **`NativeClient::prompt` cannot tell whose turn answered it** (`native.rs:2395-2425`): it parks a
  sender in `current_prompt` and returns on the next `result` frame. There is no correlation between
  the message it sent and the frame it returns on, so a `result` belonging to an injected turn
  already in flight is delivered to the host's own call.

So after the review passed, the back end never got a turn in which to call `integrate`, and the
assignment was reported failed with a passing review sitting on the worker's branch. Which seat
takes that, and whether a third real-provider run may be spent proving the land end to end, is the
escalation's question.

## 6. Suites

- `cargo test -q -p richos-core` — **1336 passed, 0 failed, 1 ignored**, summed across all 21 test
  binaries (`1335` at `ff821816` per the settlement record; this slice adds one).
- `richos/engine/scripts/test-app-engine-hook.py` — 6 run, 0 failed (5 before this slice).
- `richos/engine/mega-lander/tests/app.test.sh` — 32 run, 0 failed; 16/16 mutants still
  load-bearing.
- `richos/engine/scripts/lib/spawn-guard-audience.test.sh` — 45 cases, 0 failures.
- `richos/engine/scripts/spawn.test.sh` — 58 passed, 0 failed, 0 skipped.

## 7. Hygiene

No RichOS app instance was launched: this is a headless crate probe, not a walk
(`pgrep -fl richos-tauri` returns nothing). No `say`, no `afplay`, no audio of any kind. CI is
paused and nothing here is CI.

`$TMPDIR`'s `richos-*` entries: **0 before this slice**, both probe fixtures retained on purpose
(`RICHOS_PROBE_KEEP_FIXTURE=1`) so this record could be written from them, then deleted by hand —
**0 after**, verified with `ls -d "$TMPDIR"richos-*`.
