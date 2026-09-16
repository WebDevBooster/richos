# Desktop work source verification, September 16 2026

This is intermediate source verification for the 1.2.0 plumbing branch. It is not
an installed acceptance receipt or a declaration that the release is ready.

On macOS 15.6 arm64 with Claude Code 2.1.273, the actual native desktop profile
completed a fictional worker, independent reviewer, local fast-forward and
canonical cleanup. The target main checkout remained unchanged until explicit
integration. Provider IDs, target file contents, committed bytes, review identity,
Git ancestry and workspace removal were checked. A second live run replaced the
reasoning process after the worker commit and recovered the pending work before
review and integration. User instruction attestation was checked against the
private ledger projection.

The opt-in source probe is
`richos/app/crates/richos-core/examples/work_roundtrip.rs`. It connects two fictional
repositories but currently executes the full workflow in one. Its permission
responder is an explicit synthetic fixture decision, not installed UI acceptance.

Relevant automated checks:

- 550 core library tests passed; one opt-in case remained ignored.
- 98 Tauri tests and six desktop profile tests passed.
- Eight dispatch/review/integration cases passed, including dirty checkout
  preservation and interruption after Git fast-forward.
- 18 ECS cases passed, including confirmed Loro receipt recovery without a
  second writer or duplicate receipt.
- Five desktop hook cases and seven evidence projection cases passed.
- A real OS parent-crash test stopped the fictional provider and descendant
  while leaving an unrelated process alive.
- Relocated delivered runtimes and nested Python execution retained the complete
  inventory. The Python launcher exports bytecode suppression to child processes.

Failures found and fixed during live work included a foreground/background
payload mismatch, confusion between native coordination and target worktrees,
inheritance of terminal-wide Git hooks and Python child imports rewriting packaged
bytecode. A failed probe was not counted as a passing capability.

Remaining release gates include the complete two-repository app UI journey,
explicit pause/resume and interrupted-work reconciliation, complete component
readiness, final immutable packaging and the clean OS account/VM acceptance
matrix. No private working context was migrated, live engine pointer activated,
public release published or remote CI enabled by these checks.
