# Revision 4: recorded authority and explicit handoff

This revision implements the design approved after the R3 review. Work stays on
`codex/owned-outcome-completion` in its separate worktree. This document describes
the correction and the fixed acceptance contract. Results and tested identities
belong in RESULTS-4.md. R3 failures and evidence remain historical records.

## Problem

A conversation ending is not a completed assignment. The earlier controller kept
work durable but native delegation still depended on a fresh semantic permission
review for every dispatch. That put provider latency and outages directly in the
path of already authorized work. Its source reader also treated some system
notifications as user authority. Separately, RichOS had no exact-operation approval
bridge and its private registrar classified every completed conversation turn.

## Implementation boundary

Rich keeps the normal text and voice conversation. During a CEO turn he records a
small disposition through `record_work_disposition`: work, amend, answer_decision,
cancel or discussion. The host binds the tool to the original ledger turn, entity,
workspace and a persisted nonce. Receipt persistence is independent of the
retention-limited machinery log. Hidden turns and workers have no source grant.

A recorded discussion closes intake without calling Sonnet. A work disposition
uses the existing tool-free Sonnet registrar to validate and record the original
scope once. The original request and constraints remain the execution contract.
A missing receipt, including an interrupted reply, remains durable intake and uses
the tool-free registrar as a recovery exception. It does not require the CEO to
resend the request. This exception is deliberate: the existing Rich lease cannot
mechanically restrict all automatically approved tools for a recovery-only turn.

The native adapter registers scopes on the first actual delegation after a new
verified human source revision. Subsequent dispatches select a host-assigned work
ID. The guard discards caller prose after that selector and replaces the entire
supplied prompt with the exact registered brief and
preserved source context. A selector is not authority to substitute different work.
Ordinary assistant traffic and repeated dispatches do not repeat registration.

The CEO's complete request supplies the desktop work scope. Rich's current reply
remains registration evidence in the original source record. It cannot add
deliverables merely by mentioning them. Prior conversation resolves references
such as "do that plan" while preserving prior CEO constraints. An unanswered
assistant offer remains context, not another assignment. Pending intake and
recovery use the same scope construction. Optional interview invitations do not
belong in a work acknowledgment or completion report.

Native source trust uses positive runtime metadata. Human typed rows require the
observed native human origin, typed prompt source and stable prompt identifiers.
Notifications and legacy unmarked rows remain observations. Mixed source rows
containing injected wrapper text are retained conservatively as context and cannot
supply citations. Changes to that context invalidate stale registration. This is
not protection against someone rewriting native transcript or host state files.

Reviewer decision prose is a proposal. A separate structured challenge must identify
a business tradeoff or missing business authority, cite the retained CEO source and
confirm that independent work on the task is finished. Operational limitations
return host-authored recovery instructions. Invalid source anchors do not become
CEO questions. A business decision never grants tools. The semantic classification
still depends on a model; source validation is not a proof of perfect judgment.

RichOS permission approvals have a separate command and durable operation record.
Each record binds run, task, plan revision, canonical workspace, tool, full input
and permission settings fingerprint. Approve once consumes the grant durably before
the callback allows execution. Changed arguments cannot reuse it. Pause, end and
scope changes expire unused grants. Restart cannot replay a consumed grant.
The worker first tries an already permitted alternative; incomplete work can then
surface the actual native permission operation. Independent tasks can continue.

Native permission rule matching remains the provider's responsibility. Its deny
rules run before the callback and remain binding. See the official
[permission evaluation contract](https://code.claude.com/docs/en/agent-sdk/permissions).
No Stop-hook blocking limit is assumed or claimed.

## Acceptance contract

Run each fixed corpus once for a given implementation. Retain failures. A changed
implementation may justify another run with both versions identified. Do not rerun
an unchanged semantic sample until it happens to pass.

- Native provenance: injected notifications, legacy rows, mixed wrappers and
  synthetic tool results cannot authorize work. Original prohibitions survive.
- Native registration: repeated dispatch and assistant chatter make no extra model
  calls; an unchanged source works from cache during a registrar outage. Changed
  or revoked source cannot use stale selectors. Changed prompts are replaced with
  the recorded scope. Nonzero runner exit and missing success receipt fail checks.
- RichOS handoff: discussion with a receipt makes zero registrar calls; work
  registers once; missing receipt recovers; restart does not duplicate a run;
  corrections and later discussion do not permanently fence unrelated work.
- Escalation: operational restrictions, raw decision JSON and fabricated citations
  cannot reach the business decision channel. Genuine source-bound decisions remain
  possible. Operational rejection must resume execution rather than loop in review.
- Permissions: exact approve-once, changed input/workspace/revision, stale settings,
  duplicate consumption, restart, inspector isolation, business-answer separation,
  pause/end and the actual autonomous desktop worker path.
- Composed execution: retain original requests, input events, runtime transcripts,
  source identities, permission receipts and delivered artifacts. Count routine
  questions in prose separately from structured questions. A required executed
  check needs an actual result, not an exit code without execution.

## Explicit limits

A new ambiguous human revision can revoke old authority. Until registration resolves
that revision, its potentially affected native scopes remain held. Existing scopes
under an unchanged revision do not need the registrar online. No honest implementation
can certify the effect of an uninterpreted new instruction such as cancellation.

A model can affirmatively misclassify work as discussion. The missing-receipt recovery
closes omissions and interrupted handoffs; it does not prove every semantic decision.
Native Claude can emit prose before a Stop hook runs. Zero routine questions must
therefore be measured on the actual conversation, not inferred from hook tests.

This branch is not automatically deployed or installed into running sessions.
Unrelated improvements belong in IMPROVEMENTS.md.

## Correction required by the first native execution trial

The first R4 native trial stopped on a routine read command's permission dialog
before it delegated anything. Its unchanged counterpart was not rerun. Native
permission recovery is therefore part of this revision's required completion:
refuse the first exact attempt so the leader or child can use an existing permitted
route. A repeated request does not automatically release a dialog. A separate
necessity check must bind the exact actor, operation and current verified source,
with actual failed-alternative receipts or an explicit source requirement for that
operation. Only then may the normal native permission UI decide. This gate never
returns an allow grant. Provider failure leaves owned recovery and diagnostics.
It does not invent native worker restrictions from an inspector's tool inventory.

This adds a rare necessity-review call for repeated permission requests. It does
not restore per-dispatch or per-conversation-turn classification. Explicit deny-only
configuration continues to deny new permissions. The `native` policy's R4 meaning
includes this recovery step before exposing a necessary native prompt.

## When the private reviewer runs

The reviewer defaults to Sonnet. The normal conversation still reaches Rich. The
following calls have different responsibilities and must not be described as one
model call on every turn:

| Boundary | Private model work |
| --- | --- |
| Rich records discussion | None for work registration |
| Rich records work or a correction | Register that source once |
| Rich omits a receipt or the reply is interrupted | Registrar recovery with persisted retries |
| Native delegation under unchanged recorded authority | No registration call; use the saved work ID |
| First native delegation after changed human authority | Register the new source revision |
| A worker or native leader claims it can stop | Inspect the owned outcome against retained authority and actual evidence |
| Inspection proposes a CEO decision | Separately challenge its source, necessity and dependency |
| Native retries a denied operation with necessity evidence | Review that exact operation before allowing the native permission dialog |

The controller and host records own continuation. A reviewer result can establish
the next action or a genuine decision boundary; it cannot fabricate CEO authority,
approve tools or count a quiet session as a delivered result.

## Review map

- `registration.rs`, `work_disposition.rs`, `spine.rs` and `owned_work.rs`: source
  intake, recorded handoff, corruption isolation and restart recovery.
- `dispatch.rs`, `owned-dispatch.py` and `owned-session.py`: verified native source,
  cached scopes, installed hook boundary and continuation of the same leader.
- `autonomy.rs` and the `richos-run` audit commands: outcome inspection, exact
  question binding, source challenge and control-marker isolation.
- `permission.rs`, `native.rs`, `run.rs`, `managed_runs.rs` and `runs.js`: managed
  permission persistence, one-use consumption and the actual desktop controls.
- `native_permission.rs` and [NATIVE-PERMISSIONS-4.md](NATIVE-PERMISSIONS-4.md):
  native permission necessity, source fencing and invocation lifecycle.

The [results](RESULTS-4.md) distinguish scripted protocol checks from real provider
trials. [PERMISSIONS-4.md](PERMISSIONS-4.md) records the managed bridge's storage and
compatibility limits. Review is against this implementation and its recorded
evidence, not against historical pass claims from earlier revisions.

## Activation after review

Use the merged stable checkout and its rebuilt executable, not this disposable
worktree as a permanent hook location. The desktop needs the updated application.
An adopted engine workspace needs the updated engine policy hooks as well as the
portable adapter. Installing an adapter does not replace an older engine guard
that still enforces the prepared-question quota.

The native permission recovery design is selected explicitly with:

```sh
python3 engine/scripts/install-owned-work.py /absolute/workspace /absolute/richos-run --permission-policy native
```

The installer otherwise preserves an existing explicit permission-policy value,
including `deny`. Refresh copied engine hooks using the ordinary engine migration
and integrity-sidecar process, then verify the installed source capture and native
wake path in the intended workspace. No activation command was run against a
production workspace during this implementation.
