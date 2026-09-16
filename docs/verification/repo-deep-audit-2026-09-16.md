# Deep repository audit, 2026-09-16

Follow-up: [repairs and complete recheck](repo-deep-audit-fixes-2026-09-16.md).

Audited revision: `ef2f0c87f808951e1fd2da3802accb2c17ebc4c2` on `main`.

Three actionable defects were reproduced: two P1 storage/scope problems and one
P2 worker-lifecycle problem. The six findings from the earlier post-refactor
audit remain fixed. No product implementation was changed.

The audit covered the current checkout, with particular attention to the newly
delivered Loro and ECS components and the desktop worker, permission, recovery
and integration paths. These are defects in the audited revision, not a claim
that each was introduced by moving directories.

## 1. P1: Correcting a company record moves its replacement into global memory

Primary source: [writer.js:306](../../richos/engine/loro/writer/writer.js#L306).
App caller: [correction.rs:239](../../richos/app/crates/richos-core/src/correction.rs#L239).

`supersedeRecord()` forwards the caller's options to `appendRecord()` without
inheriting the original record's company partition. An omitted partition defaults
to `ceo`. The desktop's `ProposedWrite::Supersede` has no partition field and its
CLI arguments cannot supply one, so this is the normal desktop correction path
for company records.

The replacement loses its company attribution and becomes eligible for other
companies' context slices. The app's additional company check cannot catch this:
`Slice::foreign_lane()` explicitly permits records with `company: null` as global
CEO context.

**Reproduction:** Create Alpha and Beta partitions. Append an org-shared Alpha
contract record, then supersede it using the same arguments the desktop emits.
The replacement is `rec:ceo/records/contract-corrected`, with `company: null`.
A Beta-only context query that returned no items before the correction now
returns the Alpha replacement. Both the writer and compiler are the real CLI
entry points. All content is synthetic.

**Fix:** Preserve the original partition by default when superseding. Treat an
explicit move as a separate operation. Cover company, CEO and unfiled records
through the actual desktop writer path, then compile another company's context
to prove that the correction did not broaden its visibility.

## 2. P1: Loro writes follow linked children outside the validated corpus

Primary source: [writer.js:74](../../richos/engine/loro/writer/writer.js#L74).
Output operation: [writer.js:170](../../richos/engine/loro/writer/writer.js#L170).

The CLI rejects a corpus root physically inside the public product checkout.
However, the writer's `assertInside()` only compares lexical paths. The later
`mkdirSync()` and `writeFileSync()` follow links below that accepted root.

**Reproduction:** Provision an external corpus and link its `ceo/records`
directory to the `docs` directory of a disposable synthetic product tree.
`loro-write append --corpus <external-corpus>` succeeds and writes the synthetic
private memory into the product's `docs` directory. Selecting that destination
directly as the corpus is refused, proving that the child link bypasses the
existing boundary.

**Impact:** Private memory can enter a checkout intended for publication. The
reproduction demonstrates local file placement, not a remote exploit or an
actual publication of private content.

**Fix:** Validate the physical destination at every writer boundary, including
existing ancestors and leaf files. Refuse redirected paths and hard-linked
outputs consistently across append, correct, supersede and company creation.
Add linked-child and linked-leaf tests to the CLI suite; root-only checks do not
cover this case.

## 3. P2: An unreadable worker journal bypasses the end-of-turn process fence

Primary source: [native.rs:1935](../../richos/app/crates/richos-core/src/native.rs#L1935).
Reader: [app_workers.rs:15](../../richos/app/crates/richos-core/src/app_workers.rs#L15).

The worker reader returns `unattributed: AppEvidenceUnavailable` with zero
counts when the callback journal is missing, unreadable or malformed. At turn
end, `NativeCognition::prompt()` checks only `liveness_unknown > 0`. It therefore
treats the unreadable state as if no unsettled workers were observed and skips
the process teardown that an intact open-worker record triggers.

**Reproduction:** Drive the real `NativeCognition::prompt()` method using a
synthetic provider process and a callback journal containing `SubagentStart`
without `SubagentStop`. With an intact journal, the call reports unsettled work
and stops the provider. Append a partial JSON record to the same fixture and the
call returns `Ok("end_turn")` while its provider process is still alive:

```text
intact:  liveness_unknown=1, unattributed=None, provider_alive=false
damaged: liveness_unknown=0, unattributed=AppEvidenceUnavailable, provider_alive=true
```

The probe uses a synthetic start observation, not a real external worker. It
proves the production turn-end branch and process behavior without making a
live provider call. The same unavailable result also covers a concurrent read
of a partially appended callback line.

**Fix:** Require an attributed, successfully read worker view before accepting
settlement. On an unavailable view, stop the owned process group and retain
receipts for reconciliation. Test malformed, missing and unreadable evidence
alongside a valid journal with zero workers. Coordinate readers and appenders
so a partial read cannot look like successful settlement.

## Verification

Fresh checks ran against a source archive pinned to the audited commit, with
separate build directories and synthetic state. The audit probes were also
rerun successfully from a second fresh archive using the delivered reproducer.

| Check | Result |
| --- | --- |
| Rust core, including integration tests and doctests | 1,028 passed, 4 ignored |
| Tauri desktop shell | 98 passed |
| Rust voice | 225 passed, 4 ignored |
| User updater | 37 unit tests and 1 integration test passed |
| Service | 365 passed |
| Workspace | 91 passed on environment-corrected retry |
| Browser extension | 66 passed |
| ECS | 18 passed |
| Desktop work adapter with real synthetic Git worktrees | 13 passed |
| Hook evidence projection | 7 passed |
| Provider supervisor | 1 passed |
| Loro | 205 passed plus relocation checks |
| Delivered-runtime verifier | 7 passed |
| WebKit permissions, repositories, provider authentication and saved work | 9 checks passed across 4 suites |
| Previous audit's six repaired behaviors | Reproducer passed |
| Product source syntax | 117 Python, 360 shell and 179 JavaScript files passed |

The initial Workspace run passed 87 tests and failed four assertions about
which refusal message is returned. The source archive was outside the user's
home, so token paths were refused as outside home before the product-boundary
message expected by those tests. The unchanged suite passed all 91 tests after
the relevant source was copied beneath a disposable home. No assertion or
product code was changed. Both runs remain recorded.

The broad suites passing does not negate the findings: the additional probes
demonstrate cases those suites do not cover.

## Evidence and reproduction

- [Loro results](repo-deep-audit-2026-09-16/loro-results.log)
- [Native process-fence results](repo-deep-audit-2026-09-16/audit-native-results.log)
- [Check counts and raw-log hashes](repo-deep-audit-2026-09-16/checks.json)
- [Reproduction driver](repo-deep-audit-2026-09-16/reproduce.py)
- [Loro probes](repo-deep-audit-2026-09-16/loro-probes.mjs)
- [Native test probe](repo-deep-audit-2026-09-16/native-probe.rs)

From the repository root:

```sh
python3 docs/verification/repo-deep-audit-2026-09-16/reproduce.py
```

This archives the exact audited commit into a new temporary directory, runs the
Loro probes and injects the native test only into that disposable copy. Node,
Cargo and the applicable Rust dependencies are required. The script asserts
the defective behavior; its success reproduces the findings and must not be
treated as a repaired-product regression gate. Convert its assertions when
implementing fixes.

Raw suite logs are retained under `/tmp/richos-deep-audit-p8mhq6`. They are local
temporary evidence and may be removed by normal system cleanup.

## Other worktrees and limits

The other Codex worktrees did not change the source under review. Their
unmerged work is outside this audit. Worktrees normally isolate files and
indexes but still share Git objects and refs, machine resources and any
externally configured app state. The pinned archives and isolated fixtures
avoided those shared-state effects for this audit. `main` still pointed to the
audited commit at the final check.

This was a source audit and targeted validation, not a certification of every
execution path. The full engine mutation inventory, full browser inventory,
packaging/signing suites, installed-app acceptance, live accounts and Windows
capture were not rerun. No real provider assignment was dispatched. The
previous report's Linux `glib` advisory was not independently refreshed or
resolved here.

Existing `.DS_Store` files were left alone. Only this report and its evidence
were added to the working checkout. No fixes, commits, merges or pushes were
performed.
