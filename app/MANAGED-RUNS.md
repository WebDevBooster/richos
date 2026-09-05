# Owned work in RichOS

Tell Rich what needs doing in the conversation. The desktop persists the request
before inference, plans the work and runs it through independent outcome checks.
No JSON file, task breakdown or per-attempt approval is required.

Rich owns the request until its outcome is verified, the CEO explicitly ends it
or a genuine business decision prevents that task from proceeding. Operational
failures remain owned and retry with persisted backoff. They are not completion
and are not automatically presented as CEO decisions.

## Conversation and execution

Typed messages, voice input and steering enter the owned-request path. Intake
uses the conversation and relevant workspace documents to distinguish a request
for work from a question. It creates declarative tasks and acceptance criteria.
Generated criteria cannot install shell commands as verifiers.

The desktop scheduler starts at app launch and services saved requests and jobs.
It executes one worker attempt at a time across conversations. A job retains its
original company and conversation when the user selects another conversation.
A company without a project folder receives an app-owned workspace.

Each worker uses a fresh governed Claude session. Background tasks and experimental native teams are disabled inside that lease, so work cannot be handed off to an unowned background team. Foreground subagents may finish within their parent attempt. Output reaches the ordinary
conversation. Generated worker prompts are not attributed to the CEO. The run
journal, rather than a model's memory or turn-end event, owns unfinished work.

A separate inspector has Read, Glob and Grep tools, no shell or write tools and
no MCP tools. It reads the actual result and returns a structured verdict:

- Complete, with evidence for the acceptance criteria.
- Incomplete, with the missing work for the next attempt.
- A CEO decision, with the question, why CEO authority is needed, options and a
  recommendation.

Earlier passed tasks are checked against the final workspace before completion.
A file's existence or the worker's claim alone does not establish a business
outcome. Independent model review still requires judgment and is fallible.

## Permissions

Managed workers retain user, project and local settings, including configured
hooks and explicit restrictions. RichOS supplies `acceptEdits` and enables the
Bash sandbox with automatic approval of sandboxed commands. Filesystem isolation
is on, unsandboxed retries are off and unavailable sandbox support is an error.
Reads outside working directories are restricted.

The permission callback denies requests that still require approval. It tells
Rich to find a permitted alternative, rather than ask the CEO to edit settings.
This is not an unconditional approval callback. Existing settings still matter:
Claude merges some permission and sandbox arrays across settings sources. This
policy is not a separate VM or an adversarial isolation boundary.

The installed-provider trials and transport tests are described in
[the review brief](ORCHESTRATION-REVIEW.md). The background-task switch follows the documented [Claude environment contract](https://code.claude.com/docs/en/env-vars). Native Claude is an external runtime;
its supported sandbox platforms and policy behavior remain dependencies.

## Ownership, recovery and control

Requests are written through a synced temporary file and atomic rename. Stable
receipt IDs prevent a request being duplicated across spool recovery. Run
snapshots are synced before execution and verified transitions. An OS lock
prevents two controllers from owning the same journal.

Autonomous tasks retain ownership after the advanced-plan attempt ceiling.
Retries back off up to 512 seconds. An unavailable workspace is retried without
asking the CEO to repair a task plan. Restart recovers interrupted work and tells
the next worker to inspect existing effects before continuing. This is not an
exactly-once guarantee for arbitrary external services.

Explicit pause survives restart. The Work plan panel offers pause, resume and
end controls. Ending a run is recorded as cancellation, never completion.
Unreadable journals can be archived without destroying their bytes. A missing
workspace does not prevent inspection or ending an existing run.

CEO answers are retained verbatim and passed to both execution and verification.
An answer must first be classified as addressing the pending decision. Other
independent tasks can continue while a decision is pending.

The app must be running to execute. Closing the app preserves work for its next
launch; it does not install a background system service or arrange an OS login
launch. Managed Unix leases use a process group for ordinary child cleanup when
the lease is dropped. This does not provide an external-action transaction log
or containment of deliberately detached processes.

## Advanced terminal interface

The same core controller is available without the desktop:

```sh
cargo build --manifest-path app/Cargo.toml -p richos-core --bin richos-run
app/target/debug/richos-run handle /absolute/job.jsonl /absolute/workspace 'Handle this: finish the requested document.'
app/target/debug/richos-run status /absolute/job.jsonl
app/target/debug/richos-run pause /absolute/job.jsonl
app/target/debug/richos-run resume /absolute/job.jsonl
app/target/debug/richos-run drive /absolute/job.jsonl
app/target/debug/richos-run end /absolute/job.jsonl
```

`status` and `drive` return 0 only for completed work, 3 for unfinished work and
2 for errors. `create JOURNAL PLAN.json` remains available for explicit technical
plans. These can use executable acceptance commands and retain their finite
attempt budget and explicit recovery contract. Only trusted operators should
import executable checks. The conversation planner cannot generate them.

`inspect WORKSPACE PROMPT` is a diagnostic for the read-only structured inspector.
The desktop owns intake before planning; the terminal `handle` command currently
creates its run journal after intake has produced a plan.

## Compatibility and limits

The conversation ledger writes the existing `text` and `proactive` source values.
It does not introduce a `managed` value older RichOS readers cannot deserialize.
The newer reader also accepts the earlier experimental `managed` spelling.
Request and run journals live separately from the conversation ledger.

This implementation owns serial app workers. It neither adopts an existing
interactive Claude Code team nor supplies a parallel team scheduler. Available
files, services, credentials and configured tools bound what Rich can achieve.
A retry loop cannot manufacture missing authority, guarantee a model's judgment
or prove that an external side effect happened exactly once. Those limitations
must not be represented as verified completion.
