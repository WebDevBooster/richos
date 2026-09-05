# Owned work behind Rich

Talk to Rich normally. Typed input, voice and steering use his established
conversation. Rich registers accepted work with a durable execution engine;
questions are answered by Rich, not a separate classifier.

The engine retains the assignment until verified completion, explicit
cancellation or a CEO decision blocking the affected task. A turn ending is not
completion. Operational failures retain ownership and retry automatically.

## What happens

The conversation is persisted before inference. After Rich answers, a private
tool-free registration on a separate small-model session records the assignment or correction.
It never borrows Rich's conversation lease or blocks it. The host preserves the
full request and reply as the work contract and checks registration consistency.
The host saves it before execution. Private JSON is never shown or spoken.
New assignments first check existing effects, then execute only if more work is
needed. A separate read-only inspector checks the outcome after each attempt.

Workers use independent leases and do not hold the conversation lock. You can
ask questions elsewhere or correct the current assignment while it runs. Rich
registers revised scope and criteria; the host interrupts the worker and applies
the revision at its boundary. Existing results are checked again before more
work begins. An action already in flight cannot necessarily be undone.

Results return through Rich's normal streamed conversation and speech path.
CEO decisions require a concrete question, a reason CEO authority is needed,
options and a recommendation. Routine retries and implementation choices are
Rich's responsibility. Answers to actual decisions are kept verbatim.

## Recovery and control

Requests and job transitions are persisted. Restart resumes unfinished ownership.
Explicit pauses survive restart. Pause, resume and End remain available in the
assignment panel. End means cancellation, never completion. A missing workspace
can still be inspected and ended; corrupt journals can be archived intact.

A malformed or unavailable review retries the reviewer, not the executor. After
five unsuccessful execution or review cycles, Rich reports the situation and
his recovery approach. Recovery at that checkpoint waits one hour instead of
continually opening workers every few minutes. At ten cycles the task needs an
explicit decision about authorizing more compute, changing scope or ending it.
This persisted limit includes review-only failures and survives restart. It is a
cycle budget, not a dollar cap. Registration stops and reports after three failed
attempts. Work remains saved and unfinished; neither limit claims completion.

Unrelated assignments in one conversation have separate journals and can proceed
while another is paused or awaiting a decision. Select an assignment in the assignment
panel to inspect or control it.

The app must be open to run work. Closing it preserves work for the next launch;
no background OS service is installed. Workers are serial. Existing interactive
Claude Code teams are not adopted.

## Permissions

Managed workers retain user, project and local settings. RichOS enables local
edits and automatically permitted sandboxed shell work. The sandbox must be
available; unsandboxed escape requests and remaining permission callbacks are
denied. Configured restrictions and provider settings-merge behavior still apply.

Within the permitted workspace, edits can include deletion. There is no per-action
approval or automatic undo. The policy is not a VM, an external-action transaction
log or a guarantee of exactly-once effects. Native background tasks and experimental
teams are disabled inside managed leases; foreground subagents remain within
their parent's attempt. The provider's supported platforms remain a dependency.

A company without a selected project receives an app-owned execution directory.
Its configured roots are not rewritten by sending a message.

## Terminal and advanced plans

```sh
cargo build --manifest-path app/Cargo.toml -p richos-core --bin richos-run
app/target/debug/richos-run handle /absolute/job.jsonl /absolute/workspace 'Handle this: finish the requested document.'
app/target/debug/richos-run status /absolute/job.jsonl
app/target/debug/richos-run pause /absolute/job.jsonl
app/target/debug/richos-run resume /absolute/job.jsonl
app/target/debug/richos-run drive /absolute/job.jsonl
app/target/debug/richos-run end /absolute/job.jsonl
```

The terminal `handle` command uses a separate intake inspector because it has no
Rich conversation. Unlike the desktop, terminal intake is not persisted before
planning. `status` and `drive` return 0 for completed work, 3 for unfinished work
and 2 for errors.

Trusted operators can still import explicit command plans. Those plans may run
executable acceptance checks and retain finite attempt budgets and manual retry.
The conversation planner cannot install executable verifier commands.

The ledger writes the existing text, jam and proactive vocabulary. Request and
run journals are separate. See [ORCHESTRATION-REVIEW.md](ORCHESTRATION-REVIEW.md)
for architecture, audit response and known limits.

The assignment panel shows the selected work and the number of assignments that
need you. Its chooser puts pending decisions first. Duplicate titles include a
creation time and distinguishing reference. Pause and End remain outside the
optional history. End asks you to confirm which assignment you are ending.

Pending questions appear with working controls. Keep going authorizes only the
allowance displayed above it. Change instructions accepts your exact correction
and rechecks the revised outcome. Business questions offer their choices or a
written answer. These actions call the desktop controller directly and are saved
before work proceeds. You can also answer Rich in the conversation.

“Show me what happened” opens task details, completion checks and technical
history. Completion checks use the same readable type size as the rest of the
panel. A load failure offers Refresh first and preserves diagnostic details in
history. Setting an unreadable assignment aside requires confirmation.
