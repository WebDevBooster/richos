# Desktop work and authority contracts

The app's selected engine supplies a generic worker and reviewer, the work MCP
adapter and canonical Mega Lander controls. The provider starts in private app
coordination. Target repositories must be explicitly connected to the active
company. Company folder mappings alone confer no execution grant.

Workspace registries are partitioned by company and thread before provider
startup. Provider sessions share a partition only when they serve the same
thread. User instructions are attested from an exact ledger text digest; hidden
priming and provider-authored prompts never become user instructions.

## Dispatch and recovery

`richos_work.prepare` requires an open ECS obligation and the current visible
user turn. It records an intent before creating a target worktree through the
canonical spawn preparer. The exact returned Agent payload is submitted once.
A hook joins the receipt to the actual provider tool call, then canonical
lifecycle callbacks supply the real agent ID. An uncertain attempt is inspected,
not automatically dispatched again under its old key.

The worker receives a host-verified target. Direct writes outside that target,
including symlink escapes, are refused. Shell actions retain native permission
decisions; a path check is not represented as an OS sandbox. The profile excludes
terminal-wide Git configuration and uses a generic local RichOS commit identity.
It does not import an operator's terminal hooks, staff or private knowledge.

Receipt states distinguish preparing, prepared, dispatching, running, run-ended,
interrupted, unknown and integrated. A run ending does not establish success.
ECS observations use durable outboxes so a crash after the ECS commit but before
the local receipt can reconcile without a duplicate event.

## Continuation

A new worker can name `continue_of` after the original execution settles. The
adapter derives the base from the actual saved commit. Dirty files are retained
and refused before workspace creation; Rich must inspect and reconcile the
intended changes through the normal permission path. The adapter never resets,
discards or silently commits them. Canonical continuation records the original
session's exact workspace key and requires a fresh review of the revised result.

The delivered desktop execution contract joins the app's standing instruction.
Users describe their assignment; Rich owns internal obligation and receipt IDs.
Saved work summaries are available in the conversation, with observed run ends,
review verdicts and local integration kept distinct from whole-task completion.

## Review, integration and cleanup

A reviewer names a worker receipt. Its worktree is based on the worker's actual
clean commit. The host captures a typed verdict from that reviewer's observed
SubagentStop callback, including the exact commit and provider identity.

`richos_work.integrate` requires that passing verdict, unchanged worker/reviewer
commits and clean checkouts. It persists an integration intent before a local
fast-forward. It does not push, rebase, resolve conflicts or overwrite unrelated
edits. Recovery checks Git before retrying. Mega Lander owns cleanup, with partial
cleanup reported separately from a verified integration. An explicit retry uses
the canonical deletion path and rechecks eligibility; an earlier landing receipt
does not certify that resource deletion completed.

A verified work result is not completion of every condition in a broader
obligation. The adapter does not close the entire obligation automatically.
Completed work and authority receipts remain inspectable with `include_closed`.

## Lifecycle

The first desktop policy settles owned workers on Stop, scope change and quit.
A process supervisor also observes desktop parent death, so teardown does not
rely solely on Rust destructors running. Its live group leader reserves the
process identity until teardown. The supervisor does not restart work.

Workers must settle before the reasoning turn ends. If a provider returns while
workers remain open, the host stops its owned processes and retains workspaces
and receipts for reconciliation. No background-while-closed promise is made.
Recovery never converts interrupted execution into verified completion.

## Knowledge corrections

Operational changes use ECS checkpoint/update contracts. Knowledge changes use
the existing Loro proposal and confirmation desk. ECS never becomes a second
knowledge writer. It projects confirmed desk writer outcomes as verified
historical receipts, with scoped idempotent recovery. An unknown writer outcome
is held for reconciliation and cannot become an unanswered proposal on restart.
A bounded receipt summary accompanies rehydration; omitted receipts are available
through scoped inspection.

The native hook interface supports host context at tool boundaries. See the
[provider hooks reference](https://code.claude.com/docs/en/hooks). Actual behavior
is also exercised by the opt-in live desktop probe.
