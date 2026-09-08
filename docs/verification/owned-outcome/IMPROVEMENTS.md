# Remaining requirements and improvements outside this change

Record suggestions here without silently adding them to the implementation scope.
The remaining requirements below are not optional improvements and are not claims
of implemented behavior. [REVISION-3.md](REVISION-3.md) freezes the current native
correction boundary; earlier evidence remains in [REVISION-2.md](REVISION-2.md).

## Observed remaining requirements

Remaining requirement for the literal zero-routine-question promise: native
ordinary reply prose is not behind the `AskUserQuestion` boundary. The final R2
trial emitted a routine permission question in prose, then recovered and completed
without an answer. A fix must control the relevant interaction boundary while
preserving Rich's conversation, legitimate decisions and working-state feedback.
A display-only text replacement does not change the model's instructions or work
ownership and must not be confused with solving the underlying behavior. This is
an observed remaining gap, not an optional cosmetic improvement.

RichOS-managed requests need an exact-operation permission grant bridge. Restoring
native permission passthrough does not provide one: the managed callback currently
denies additional requests, and a CEO business answer changes task state without
authorizing that callback. Reuse the existing RunDecision panel, revision/receipt
fences and onboarding's atomic host-owned scope-file pattern, but add typed
approve-once/reject actions and a persisted grant bound to the exact operation,
workspace, run/task and current scope. Plain business answers cannot mint grants.
The affected surfaces include core `native.rs`, `run_host.rs`, `run.rs`, the Tauri
owned-work and decision handlers, `run_view.rs` and `ui/runs.js`. Current explicit
denials and inspector isolation remain binding. See REVISION-3.md for crash,
replay and revocation requirements. This is substantial remaining implementation,
not an implemented native R3 correction or hidden scope expansion.

## Deferred lifecycle work and optional improvements

- Make the registrar's `independent` versus `authorized` subtype more consistent
  when it cites the original task instruction and no relevant dependency exists.
  R3's fixed corpus retains one such exact-kind failure. Its checked citation and
  allow disposition were valid, so this is not an observed operational hold.
- A separate OS service for execution while RichOS and Claude Code are both fully
  quit. This requires a product lifecycle and permission design; existing work
  remains durable for restart. Closing a process is distinct from a model ending
  a turn. Do not claim this branch installs such a service.
- Consolidate historical policy prose and duplicated notice hooks across the
  engine. Only the dispatch and continuation conflict is addressed here.
- Optimize large history indexing after correctness measurements establish a need.
- Add an installer compatibility preflight for Claude's native wake contract.
  The integration was measured on Claude Code 2.1.263; installation does not
  currently reject older or incompatible versions.
- Remove the existing missing-skills diagnostic from intentionally tool-limited
  auditor leases without hiding a real worker setup failure.
- Stronger machine-verifiable execution attestation beyond observed tool results.
  The historical R1 trial inferred execution from `__pycache__`. R2 now captures
  real leader and child calls/results and rejects an actual saved missing-check
  result, but the reviewer still interprets those receipts with a model. External
  acceptance checks must never substitute for execution required of the worker.
- Transfer native obligations and source authority to a new session or into
  RichOS through an explicit ownership handoff. Do not equate same-session resume
  with cross-session migration or start competing leaders implicitly.
- A structured decision/answer ledger with stable identifiers could let dispatch
  clearance cite actual answer receipts. Asked-question receipts and disappearing
  TODO items must never substitute for granted authority.
- The unmanaged-assignment gate should reject unknown options and clarify its
  minimum valid judge-ballot requirement after fabricated quotes are voided.
  `--help` unexpectedly started a default run during investigation; it was stopped
  before live work and is not a measured sample. The separate gate owner has
  already improved output isolation. This change uses explicit options and
  separate directories without changing the gate.
- Give workers clearer discovery of already permitted command shapes after a
  refusal. The native trial avoided parked dialogs but still attempted several
  denied spellings before finding an allowed route. This must not silently widen
  tool permissions or make the CEO choose routine implementation details.
- Reuse or pace identical proposed-question inspections while their source and
  evidence remain unchanged. These are separate paid model calls, outside the
  persisted outcome-audit burst; repeated denied proposals can still incur cost.
