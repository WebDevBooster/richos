# Worker lifecycle events — the stream, and what it refuses to say

The engine emits an append-only worker-lifecycle stream so a consumer (today:
the RichOS desktop app's worker drill-down) can show delegated AI workers
without inventing anything.

```
~/.claude/teams/session-<first8>/worker-events.jsonl
fallback: ~/.claude/worker-events.jsonl
```

One JSON object per line, appended, never rewritten. Same shape and same
fail-open contract as the two older handoff logs beside it
(`idle-events.jsonl`, `task-events.jsonl`).

## Why this exists

Before this stream the engine emitted exactly two worker signals: a task
**completed** and a teammate went **idle**. A worker's creation was observed —
`PreToolUse[Agent]` runs at the moment a spawn is requested — and then thrown
away into a plain-text name ledger. So no consumer could answer "how many
workers are running right now" from a signal, only from a guess, and the app's
`worker_status.rs` correctly reported `active: 0` rather than guess.

The design brief's rule is the one this stream is built to satisfy:

> **If the source signal does not exist, build the signal first or show
> unknown.**

So: four emitters, each on a hook event that genuinely witnesses the thing it
records, and a written-down refusal for everything else.

## The per-state table

The design names seven worker states. Here is what actually witnesses each one.

| State | Source signal | Verdict |
|---|---|---|
| **created** | `PostToolUse[Agent]`, when the tool result carries the harness's async-launch acknowledgement and an extractable `agentId`. | **Observable.** `worker-created-handoff.sh` |
| **started** | `SubagentStart` — fires from inside the worker's own run and carries `agent_id` + `agent_type`. | **Observable.** `worker-started-handoff.sh` |
| **updated** | `PostToolUse[SendMessage]`, when the payload carries `agent_id` (i.e. a worker sent it, not the lead). | **Observable.** `worker-updated-handoff.sh` |
| **waiting** | — | **Not observable as `waiting`.** See below. |
| **completed** | `TaskCompleted` → `task-events.jsonl` (pre-existing). | **Observable, elsewhere.** Task-grain, not worker-grain. |
| **interrupted** | — | **Not observable.** See below. |
| **failed** | — | **Not observable.** See below. |
| *(extra)* **run_ended** | `SubagentStop` — the worker's run stopped; the payload says nothing about why. | **Observable.** `worker-ended-handoff.sh` |

### waiting — why not `TeammateIdle`

`TeammateIdle` is documented by the platform and logged to `idle-events.jsonl`
by `teammate-idle-handoff.sh`. It is tempting to render it as "Waiting",
because an idle teammate is by definition not executing.

It is not emitted as `waiting` because **by the CEO's rule an agent that goes
idle is finished forever** — idle IS done, and there is no "will resume when
spoken to" state to render. The reason it is not yet a *terminal ingress* for
the worktree lifecycle is different and narrower: **its payload has never been
observed live on this machine** (on 2026-09-03 every one of the 1,171 rows in
the idle log was a test fixture with an empty `session_id`), so no field of it
is proven to join to the spawn-side ownership id, and the terminal-authority
specification (the private femcboost planning record
*worktree-terminal-authority-fix-recommendation-2026-09-03*, section 3; not
part of the published engine) forbids granting an unmeasured event
destructive authority. The
idle hook now records each payload's top-level key names and its identity,
type and task fields — never a message value — so the first live firing is the
fixture that decides it. If a field proves exact, the event is registered
through the same compare-and-set claim as the other ingresses; until then the
reconciler's native-disappearance backstop covers native workers.

What a consumer may honestly do with `TeammateIdle`: treat it as a terminal
signal for the worker, exactly like `run_ended`. What it must not do: render a
*reason*.

### interrupted — why nothing witnesses it

The only candidate is a `shutdown_request` message to the worker, seen at the
lead's `SendMessage`. That is an **instruction**, not an observation: it is
issued before anything happens and the worker may finish normally, ignore it,
or never receive it. Recording an instruction as a state is the same class of
error as recording `PreToolUse[Agent]` as a creation.

`SubagentStop` does fire when an interrupted worker stops — but its payload
carries no interrupt flag, so it cannot tell an interruption from an ordinary
finish. That is why the event it produces is `run_ended` and nothing more.

### failed — why nothing witnesses it

No hook payload in the worker path carries a success/failure verdict.
`SubagentStop` has `stop_hook_active`, a transcript path, and the last
assistant message; none of those is an outcome. Classifying a failure from the
last message would be text-scraping a guess and presenting it as a state.

If a failure signal is wanted, it has to be **built**, not inferred — e.g. a
worker-visible completion protocol that records an explicit outcome, or a task
store that records a terminal status other than completed. Until then, a worker
that failed appears in this stream as `run_ended`, which is true.

### run_ended — the honest superset

`run_ended` is deliberately outside the seven-state vocabulary. It means: *this
run is over, and the reason is not observable here.* It is the honest superset
of completed, interrupted and failed. A consumer may safely stop rendering the
worker as working; it must not render a reason it was never told.

`run_ended` is also **not** "this worker is gone forever" — a background
teammate can be woken again, producing another `started` / `run_ended` pair for
the same `agent_id`. The stream is a sequence, not a set of flags.

## Deriving an active count honestly

```
active = workers with a created/started and no LATER terminal event
terminal event = run_ended  (or TeammateIdle from idle-events.jsonl)
```

That is arithmetic over observed events, not a heuristic — every term is a
signal the harness actually emitted. Two constraints on the consumer:

1. **Scope to the session.** The log lives in the session's team directory, so
   a new session starts empty. Do not carry a previous session's `created`
   forward.
2. **Check the host is still alive.** Each record carries `host_pid` (the CLI
   process) when the harness exports it. If the CLI died mid-run, its workers
   died with it and their `created` records were never closed out. Test the pid;
   do not apply a timeout, which would be a guess wearing a number.

If neither can be established, the honest render is `unknown`, not a count.

## What never enters this log

- **Message bodies.** `worker-updated-handoff.sh` records the SendMessage
  `summary` (truncated) and a character count. Never the message. An evidence
  log that quietly accumulates model output is a privacy defect waiting to
  happen.
- **Spawn prompts.** Arbitrary operator text; not logged.
- **Last assistant messages.** A transcript *path* is recorded; the text is not.

## Guarantees

- **A hook never fails a tool call.** Every emitter exits 0 on any parse or IO
  error, matching the two older handoff hooks.
- **A blocked spawn produces nothing.** All four emitters sit on `PostToolUse`
  or on an event that only fires inside a running worker. `PreToolUse` blocks
  before `PostToolUse` runs, and a failed tool call routes to
  `PostToolUseFailure`, which nothing here is registered on.
- **An unattributable event produces nothing.** No `agent_id`, no line. There is
  no cwd-sniffing fallback: a misattributed update is worse than a missing one.
- **Name-reuse blocking is untouched.** `spawned-names.log` and
  `guard-worktree-isolation.sh` are not read or written by any emitter;
  `worker-lifecycle.test.sh` re-proves the reuse block end to end.

## Registration

Registered once each, on both surfaces (`hooks/hooks.json` for the
plugin-loaded engine, `.claude/settings.local.json` for a seated one), and
declared in `contract-integrity-probe.sh`'s `BR_EXPECTED` so BR2/BR4 audit
them like any other managed hook.

| Hook | Event |
|---|---|
| `worker-created-handoff.sh` | `PostToolUse` (matcher `Agent`) |
| `worker-updated-handoff.sh` | `PostToolUse` (matcher `SendMessage`) |
| `worker-started-handoff.sh` | `SubagentStart` |
| `worker-ended-handoff.sh` | `SubagentStop` |

Hooks are snapshotted at session start, so a newly registered emitter produces
its first event in the NEXT session, never the one that added it.
