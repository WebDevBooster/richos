# Remaining requirements and improvements outside this change

Record suggestions here without silently adding them to the implementation scope.
The remaining requirements below are not optional improvements and are not claims
of implemented behavior. [REVISION-5.md](REVISION-5.md) defines the current
correction boundary; historical results remain in their numbered reports.

## Observed remaining requirements

Remaining requirement for the literal zero-routine-question promise: native
ordinary reply prose is not behind the `AskUserQuestion` boundary. The final R2
trial emitted a routine permission question in prose, then recovered and completed
without an answer. A fix must control the relevant interaction boundary while
preserving Rich's conversation, legitimate decisions and working-state feedback.
A display-only text replacement does not change the model's instructions or work
ownership and must not be confused with solving the underlying behavior. This is
an observed remaining gap, not an optional cosmetic improvement.

The exact-operation permission grant bridge was implemented in revision 4.
See [PERMISSIONS-4.md](PERMISSIONS-4.md) and [RESULTS-4.md](RESULTS-4.md) for its
approve-once/reject commands, persisted grants, revocation and measured limits.
It is no longer listed as missing implementation.

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
  The integration was initially measured on Claude Code 2.1.263 and R5 was
  measured on 2.1.266; installation does not currently reject older or incompatible
  versions.
- Remove the existing missing-skills diagnostic from intentionally tool-limited
  auditor leases without hiding a real worker setup failure.
- Stronger machine-verifiable execution attestation beyond observed tool results.
  The historical R1 trial inferred execution from `__pycache__`. R2 now captures
  real leader and child calls/results and rejects an actual saved missing-check
  result, but the reviewer still interprets those receipts with a model. External
  acceptance checks must never substitute for execution required of the worker.
- Transfer native obligations and source authority into RichOS through an explicit
  ownership handoff. Same-workspace native fresh-session recovery is implemented
  in revision 5; migration between native Claude and RichOS remains separate work.
  Do not equate those two boundaries or start competing leaders implicitly.
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

## Discovered during revision 4, outside its scope

- A future native provider contract could attest that an AskUserQuestion answer came
  from a real human input event. Current successful tool-result metadata is
  insufficient because hooks can programmatically supply answers. Until then,
  native business decisions use a normal typed reply as authority; RichOS retains
  its own trusted decision commands. Do not infer provenance from successful tools.
- A future provider API for a strictly restricted turn on an existing conversation
  lease could recover a missing Rich disposition without the private registrar.
  Current callback denial alone cannot restrict tools that native rules already
  auto-approve. Missing receipts therefore use the tool-free registrar exception.
- Add a cheap runner capability/version handshake to the portable installer so it
  can reject an old executable before adoption. R4 acceptance builds and fingerprints
  the tested executable explicitly; a general installer handshake is separate work.
- Replace the legacy string-prefix review/control interface with a typed result
  across hosts in a future compatibility change. R4 closes the observed marker
  injection paths and tests the current boundary; adding new untrusted string
  producers must continue to use that boundary until the interface is replaced.
- Restrict managed inspectors' runtime explanations to directly observed facts.
  The corrected desktop trial completed without extra decisions, but an inspector
  speculated that the engine was stood down and the worker repeated that explanation.
  This did not grant tools or stall the task. Native permission review already
  returns host-authored dispositions; improving all managed diagnostic prose is
  separate from the source, continuation and permission mechanisms in this revision.
- Make the native tool-ID observer read transcript tails incrementally while
  preserving source provenance across compaction. It currently refreshes the
  leader's source and receipt view on each observed tool. No live acceptance stall
  was attributed to this, so performance work on large sessions is deferred.

## Discovered during revision 5, outside its scope

- Reduce redundant review delegation. In the fresh restart trial the lead and an
  intermediate coordinator each dispatched a reviewer. Both returned, but the
  duplicate work added cost without being required by the original assignment.
  Do not expand the CEO's engineer-plus-review instruction into a mandatory extra
  review layer merely because delegation is available.
- A successful tool receipt establishes execution, not meaningful progress.
  Repeatedly spawning new workers that do no useful work needs separate semantic
  progress detection. Completion checkpoints must retain their exact receipt
  linkage and consumed state; they cannot honestly promise a universal fixed
  model-call ceiling against newly executed no-op work.
- Reduce paid outcome inspections while a tracked worker is still active. The R5
  trials spent several inspections confirming that a running worker had not
  delivered yet. Any cheaper waiting path must retain a watchdog for lost or hung
  work and must not infer completion from a native terminal event.
