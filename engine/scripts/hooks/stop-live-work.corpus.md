# The TaskStop corpus — what a gate on this tool would actually have refused

The measurement behind `guard-stop-live-work.sh`, run before the decision to
make it blocking rather than interrupting. The method is the one the
concealment clause used: find every real call of the tool on this machine,
classify each one, and state the rate. That clause became blocking only after
being run against 1,871 real prompts and refusing exactly one.

## Method

Scanned **every** `*.jsonl` under `~/.claude/projects` — **2,499 transcript
files** — for assistant records containing a `tool_use` block whose `name` is
`TaskStop`. Not a `grep` for the string: the string also appears in hook
fixtures, corpus files and this engine's own test harnesses, and counting
those would have inflated the corpus with calls nobody ever made.

```
python3 <scratch>/census.py     # -> 100 real calls, 17 sessions
```

- **100 real `TaskStop` calls**
- **17 sessions**, `2026-08-08` through `2026-09-10`
- **99** from an orchestrator, **1** from a subagent
- `tool_input` shape: `{"task_id": "<name-or-agent-id>"}` in **100 of 100**.
  One key. No reason field, no note field, nothing an ack could ride in.

## First finding: the naive liveness proxy is wrong, and it matters

The obvious way to ask "was the target still running?" is to look for the
`tool_result` of the `Agent` call that spawned it. That proxy says **89 of 100
targets had already finished**, and it is **wrong**.

In team mode the `Agent` tool_result returns *immediately*, carrying the new
agent's id — the agent then runs on. Measured on today's own session: the
spawn of `echo-opus-hw2` is at transcript line 3588 and its `tool_result` at
line 3595, seven lines and a few seconds later. That agent was still running
three hours later when it was killed.

This is recorded because it is exactly the shape of mistake this whole guard
exists to prevent: a fast, plausible-looking derivation, believed without
being checked. **The authoritative liveness signal is the worktree lock**, and
`scripts/lib/agent-liveness.py` is the only thing that reads it.

## Second finding: what the traffic actually is

Re-classified against the signal that IS visible in a transcript — did the
teammate's own completion/handoff message arrive before the stop?

| | |
|---:|---|
| **32** | a teammate completion arrived immediately before the stop |
| **68** | no completion detected before the stop |

The 68 is an **over-count** and is not the live-kill count. Reading them by
hand shows the detector missing completions that arrived in other envelopes
(`<agent-message from=…>`, `<teammate-message … summary=…>` without an
`idle_notification` token). The dominant pattern in that bucket is unmistakable
in the orchestrator's own words beside the call:

> *"Landing it and retiring the agent:"*
> *"three Norm agents from the title work are still registered, landed hours ago. Same cleanup:"*
> *"Retiring the finished agent before starting the next, per the rule:"*

**The dominant legitimate use of `TaskStop` is retiring a teammate that has
already handed off.** Every one of those reaches authority A — the target is
not alive, so the guard never speaks. This is the single most important number
in the file, because it is what decides that a blocking gate does not become a
gate that is habitually waived.

## Third finding: clause B fires on his orders and on nothing else

The shipped predicate (`scripts/lib/stop-live-work.py`, `authorizes_stop`) was
replayed over all 100 calls, against the transcript **prefix as the hook would
have seen it** — every record written before the assistant message carrying the
call.

**6 of 100** are authorized by the CEO's own words. All six, in full:

| when | what he wrote |
|---|---|
| 2026-08-25 09:00 | `Stop.` |
| 2026-08-25 09:19 | `Stop.` |
| 2026-08-25 09:33 | `stop` |
| 2026-08-25 10:06 | `Stop.` |
| 2026-08-28 16:09 | `actually, wait stop it` |
| 2026-09-02 23:05 | `Stop building guards now.` |

**94 of 100** are not. Including, at the top of that list:

> 2026-09-10 09:10:45 · `echo-opus-hw2`
> 2026-09-10 09:10:47 · `zach-opus-dor1`
> *"the currently running agents **might** need to be paused **if** we get
> close to hitting the quota before it resets."*

Both refused. Two point seven seconds apart, which is why one ack cannot cover
a sweep.

## The false-positive rate, stated honestly

**Zero, on the measured corpus — and the reason is a design choice, not luck.**

A refusal requires **all three** of: the target is **provably ALIVE**; the CEO
did not order it; nothing was written down. On this corpus:

- Every stop of an already-finished teammate is allowed by authority A,
  silently, and that is the majority of the traffic.
- Every stop the CEO ordered is allowed by authority B, and the predicate
  finds all six of them and no seventh.
- Every stop whose target cannot be resolved is allowed by the
  INDETERMINATE arm, with a note.

Which leaves the refusals concentrated on the genuinely live kills. Reading
those by hand, they are exactly the class that should carry a written reason:

| | |
|---|---|
| `sage-opus-c1` | brief superseded mid-run, re-spawned with a corrected one |
| `ace-sonnet-toggle3` | a duplicate the orchestrator should not have spawned |
| `reed-sonnet-crmid1` | *"Stopping Reed before he builds to the wrong schema"* |
| `iris-opus-y1` | *"Stopping both agents now… Nothing runs until you've seen the brief."* |

Each of those is a real decision with a real reason, and in each the reason was
written out *in the turn's prose* — which the hook cannot see (measured; see
below). The ack asks for the same sentence in a place a machine can check. The
guard refuses none of them outright; it refuses them **unwritten**.

**This is why "false positive" is the wrong frame for the live-kill bucket.** A
refusal there is the guard doing its job, not misfiring. The FP question is
only about the other three buckets, and the liveness gate empties all three.

## What decided the SHAPE — measured, not assumed

A live one-shot session with a probe hook, 2026-09-10. At the moment a
`PreToolUse` hook fires:

| | |
|---|---|
| the transcript | **readable**, 23 lines |
| the user's message | **present**, line 11 |
| this turn's assistant text | **absent** — written at line 25, after the hook returned |
| the `tool_use` itself | **absent** — line 26 |
| payload keys | `cwd`, `hook_event_name`, `permission_mode`, `prompt_id`, `session_id`, `tool_input`, `tool_name`, `tool_use_id`, `transcript_path` |

So clause B ("did he actually say it?") is answerable, and no marker in the
orchestrator's own prose is readable at all. Combined with the one-key
`tool_input`, that is why the ack is a **command that writes a file** rather
than a marker line like every other ack in this engine.

## The cheaper truth the incident exposed

**A subagent cannot be paused. It can only be stopped, and stopping it throws
away everything it has not committed.**

So when the reason is budget, the action that costs nothing is to **stop
DISPATCHING** — never to destroy what is already running. Work in flight has
already been paid for; killing it refunds nothing and forfeits the result.

On 2026-09-10 that difference was the entire story:

- `zach-opus-dor1` lost almost nothing. It had committed as it went.
- `echo-opus-hw2` lost everything. No commits, clean worktree, whole session
  gone.

That is the commit-is-the-handoff rule paying out in the exact case it was
written for, and it is stated in the guard's refusal text, in
`scripts/stop-work-ack.sh`, and in `docs/failures-playbook.md`, because an
engineer meets each of those in a different situation.

## Reproducing this

The census, the classifier and the replay are throwaway scripts against
machine-local transcripts that are not in any repository, so they are not
committed. The three commands, in order:

1. walk `~/.claude/projects/**/*.jsonl`, keep records whose `message.content`
   holds a `tool_use` with `name == "TaskStop"` → 100 hits, 17 sessions
2. for each hit, slice the transcript to the lines **before** it and run
   `stop_live_work.last_user_message()` + `authorizes_stop()` on that slice
3. tally

Anything in this file that reads like a count was produced by (1)–(3) and can
be re-derived from them. Anything that reads like a judgment about a specific
kill was made by reading the orchestrator's own words beside that call.
