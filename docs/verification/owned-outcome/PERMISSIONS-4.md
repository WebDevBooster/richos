# Revision 4 managed permission bridge

This is the RichOS-managed worker correction. Native Claude's separate
PermissionRequest gate is described in NATIVE-PERMISSIONS-4.md. No installed
application or production permission setting was changed by this work.

## Authority and execution

The controller supplies the worker's run ID, task ID, plan revision, CEO decision/receipt hash, canonical
workspace and host journal path before the worker starts. The managed native
callback captures the actual tool name and full input object. Model prose, business
answers and permission suggestions do not create an approval.

An unapproved callback is refused for the current attempt. Rich can still finish
using a permitted alternative. Only an incomplete attempt exposes its captured
operation in the assignment panel. The panel displays the tool, workspace and
complete input, with separate `approve_once` and `reject` commands. A business
answer cannot answer this permission request. Rejecting an operation leaves the
assignment owned and available for a different approach.

The response is saved without interrupting independent managed work. At its next
boundary, or after restart, the controller reconciles the response and resumes the
selected task. Its next worker receives the exact operation details in host
permission evidence, so a new process can reproduce the approved input. The grant
matches every authority field and the complete input, not a command prefix.

Approvals are stored beside the run journal in a host-owned permission file. A
stable file lock serializes changes; a synced atomic replacement records consumption
before an allow response is returned to the worker. A crash after consumption may
leave an unknown external effect, but cannot replay the grant. The next attempt is
instructed to inspect existing effects. A still-unconsumed approval survives restart
within its original scope. Duplicate approval and consumption are refused.

Pause, cancellation and changed scope invalidate unused permission state. External
pause/end intent files are checked before consumption as well as controller state.
An inspector or registrar lease cannot receive an execution permission context.
Hidden context preparation denies tool requests before checking the grant store.

## Existing policy stays binding

Native Claude remains the full permission-rule interpreter. Its documented order
applies explicit denials before `canUseTool`. The host adds a settings fingerprint
and sandbox-escape check, then checks the current files again at the callback.
No callback falls back to unconditional `decide_permission` for managed work.

The host's additional denial check is deliberately conservative: a conditional
on-disk deny for a tool withholds that tool's *new* one-operation grants rather than
attempting a second shell/path matching engine. Native execution already permitted
by its own precise rules still proceeds normally. This is a compatibility limit,
not a claim that all conditional rules have been reimplemented. The mandatory
managed sandbox-disable rule is enforced directly on the input field and does not
blanket-disable ordinary Bash approvals.

Approval storage must be outside the worker workspace and outside system temp,
which sandboxed processes can normally write. The managed sandbox is mandatory;
unsandboxed execution and sandbox-disable requests stay refused. File/notebook
operations outside the canonical workspace cannot be approved through this bridge.
Retained sandbox write expansions and additional directories are checked for overlap
with the host store, including a home-directory or wildcard grant. An overlapping
configuration refuses new grants. These restrictions preserve the host store rather than granting a worker the
ability to rewrite its own approval. A CLI journal located in the workspace or
temp can still run existing permitted work but cannot issue new exact-operation
grants there.

## Deterministic verification

The following checks executed successfully during implementation:

- Sixteen `permission::tests` checks cover exact/repeated consumption, concurrent
  callbacks, restart, changed input/task/workspace/revision, malformed storage,
  settings changes, current hard denials, duplicate/forged approval, rejection,
  pause/end/scope change, changed CEO answers, overlapping filesystem expansions,
  typed controller responses and permitted alternatives.
- The native protocol fixture observed hidden-context refusal, one matching allow
  and a subsequent replay refusal on the managed callback wire.
- The existing 44 run controller tests passed after the permission integration.
- Six new `run-permissions.js` checks exercise the shipping shell's typed approval,
  rejection, identity routing, exact-operation display, stale request recovery,
  end command and narrow-screen reading flow.
- All 29 existing assignment-panel checks passed.
- `cargo check --manifest-path app/src-tauri/Cargo.toml` passed with the existing
  activation dead-code warnings.

The initial native test command used a wrong module filter and ran zero tests.
It was not counted as a pass. The corrected filter exposed an assertion expecting
`end_turn` where the managed client correctly reported `permission_denied`; the
assertion was fixed and the actual wire test passed.

The inspector-role isolation check passed. The composed RunController to
CognitionRunHost to native callback test passed: no file existed before approval,
the fake worker created it only after the matching allow and an independently
executed file check then passed. Its initial failure was a fixture using nonexistent
macOS `/usr/bin/test`; the controller correctly retained unfinished work. The
fixture now invokes `/bin/test`. Both actual Tauri command-helper tests passed,
covering approval reaching the callback and rejection requeueing work without a
grant. These are deterministic protocol fixtures, not paid-provider trials.

The no-company-notes-root regression also passed: a host-bound work disposition can
be saved without inventing interview destinations, while notes and decline calls
remain refused until real destinations exist.

Final focused logs are `/tmp/richos-r4-permission-tests.log`,
`/tmp/richos-r4-permission-host-test.log`,
`/tmp/richos-r4-permission-command-tests.log` and
`/tmp/richos-r4-disposition-no-root-test.log`. The root evidence index should retain
them with the final source identity. No real-provider
permission trial, installed desktop acceptance or literal zero-routine-question
claim follows from these deterministic checks alone.
