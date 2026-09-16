# Voice consolidation verification

Date: 2026-09-16.

Base: `ef2f0c87f808951e1fd2da3802accb2c17ebc4c2`, the integrated 1.2.0 plumbing revision.
Implementation: the `codex/voice-consolidation` change containing this receipt.

## Result and ownership

`richos/engine/voice/` owns the two shared speech-model tables and the existing
JavaScript catalog, integrity and verified download modules. Its README maps the
wider subsystem, including the live Rust pipeline. The Rust crate stays at
`richos/app/crates/richos-voice` with unchanged package/workspace membership.

Maintained JavaScript consumers import the canonical component. The three former
service module paths are export-only compatibility entry points; imports through
both paths share exported object and function identities. The service hardware
reader and HUD installer use the canonical tables. The Rust readers embed them
from the new source paths at build time. Old raw JSON locations are removed.

The model tables, integrity implementation and fetch implementation are byte-for-byte
identical to the base. Catalog changes are limited to the pin-file location and its
path-bearing guidance. Native audio policy, model selection, download policy,
user state paths and toolchain lock/cache formats have not changed.

| Canonical metadata | SHA-256 |
|---|---|
| `richos/engine/voice/models/model-pins.json` | `38025c2d8350b1cb5d28d2829e41d7596d7bb5dcdada3991374eced2788f5363` |
| `richos/engine/voice/models/model-costs.json` | `788c7e7616173c978c0c61d463efcedfecbe10dc933932dd0862d98b9eb23e3e` |

Model-catalog and fetch cases moved from the service suite into the component.
Service model-resolution, toolchain and call-processing cases stay with the service.
All 344 statically named original transcription cases are retained exactly once;
the dynamically generated cases remain in the service and execute in its aggregate.
The shell parity case now belongs to consumer integration coverage.

## Executed local verification

Host: macOS 15.6 (24G84), arm64. Rust: 1.95.0. Baseline JavaScript checks used
Node 25.5.0; final service and mutation checks used the 1.2.0 runtime's Node 24.21.0.
That prepared runtime passed `verify-runtime.py` against the current public
`runtime-sources.json` recipe. No runtimes were activated on the user's system.

Baseline results: 365 transcription tests and 91 workspace tests passed; the Rust
suite passed 225 tests with four hardware cases ignored. The old mutation audit ran
only in a disposable temporary Git repository and detected all 56 mutations, with
41 of 41 audited assertions observed failing.

Final commands below are relative to the repository root unless another working
directory is given. Node and Cargo were placed on PATH for the applicable checks.

| Check | Result |
|---|---|
| `npm test` in `richos/tools/richos-service` | 35 component cases, 329 service cases, 3 JS/shell consumer cases and 91 workspace cases passed |
| `cargo test --locked -p richos-voice --manifest-path richos/app/Cargo.toml` | 206 unit tests, 15 composition tests and 4 voiced acceptance tests passed; 4 opt-in hardware tests ignored |
| `bash richos/app/scripts/voice-component.test.sh` | 4 full consumer cases, 4 relocation cases and 4 mutation-runner cases passed; copied Rust build and missing-metadata refusal passed |
| `node richos/tools/richos-service/test/mutation-audit.mjs` | All 47 component and 9 consumer mutations detected; 35/35 component and 6/6 consumer assertions observed failing |
| `bash richos/engine/scripts/ci-affected-units.test.sh` | 13 passed, including canonical model tables and indirect JS test support selecting the core suite |
| `bash richos/app/scripts/package-app.test.sh` | 25 passed |
| Local unit inventory and mutation inventory | 17 and 6 passed respectively |
| `RICHOS_RUNTIME_DIR=<verified-runtime> bash richos/app/scripts/make-engine-asset.test.sh` | 19 passed, including core execution from the extracted engine using its delivered Node runtime |

The full consumer check calls `Costs::load` and `pinned_sha256` from the actual
compiled Rust crate through its `model_metadata` example. It compares common
cost fields and hashes with JavaScript and compares shell pin output with the
catalog. It does not assert that live and batch model selection should be identical.

The source-build case copies only both Cargo workspace crates, their manifests/lock
and canonical metadata into a path containing spaces. It builds and runs the Rust
probe with no tools directory, then removes the copied pin file and observes a
compilation failure naming that file. This tests the real include dependency.

The engine-only copy runs its core suite without app/tools siblings. Separate copied
consumer checks include the existing service/extension/HUD dependency closure.
They run from an unrelated working directory. Removing pins or costs fails in the
real consumer even with the original checkout still available. The HUD pin command
also runs with only system shell utilities on PATH.

## Mutation audit and migration findings

The previous audit restored only `richos/tools/`; repointing mutations to engine
files would have left those mutations behind. The replacement snapshots source
into temporary storage, performs the intact positive control and recreates the
trial from that snapshot before each mutation. It records a snapshot hash and
never resets the caller's checkout. Tests cover missing anchors, surviving
mutations, import crashes, a broken positive control and interruption during a
mutation, with caller sentinel edits preserved.

During implementation, the first service test extraction placed an import before
the script's shebang; the syntax failure was corrected. Two existing service
privacy fixtures initially omitted the newly required component subtree; both
now copy that dependency and exercise their original storage-boundary assertions.
The first aggregate mutation attempt correctly refused these failing positive
controls. The final aggregate audit passed after those corrections.

An initial packaging reproducibility run overlapped a test-file formatting edit
and produced differing archives. The complete 19-case packaging suite passed
when rerun with frozen source. The engine component listing was then updated
to include Voice alongside the other four components; no implementation changed.

## Delivery and limits

The existing engine packaging uses its tracked source inventory and keeps the
`engine/` archive root. A new packaging case executes the extracted component using
the delivered Node runtime. Source packaging and local affected-file selection
include the new component. Stored workflow path filters include voice inputs;
no remote workflow was enabled or dispatched.

An app binary keeps its compiled metadata. Service processes use their matched
release assets, without resolving a mutable global engine pointer. This move does
not provide a new standalone service distribution or make a tools-only copy valid.
The [delivery contract](../../richos/engine/voice/contracts/delivery.md) lists the
required layout.

No release was published, no live installation was changed and no personal context
was migrated. Clean installed-app voice acceptance, physical microphone/speaker
regression and update/rollback acceptance were not run for this consolidation.
Those remain required before claiming a newly delivered voice release. The source
move introduces no new speech capability or automatic model installation.

## Integration with September 16 main

Merged public main `2d0f3d935301a956a5d3dcf7c170f5960976278b` into the voice
implementation `5809c537` as `117bf4b6`. The only conflict was two appended
sections in the app README; both sections were retained. The voice component,
service, HUD and Rust voice source were unchanged by this merge.

Rechecked the combined tree locally on the same macOS host with Node 24.21.0
and Rust 1.95.0:

| Check | Result |
|---|---|
| Service `npm test` | 35 component, 329 service, 3 JS/shell consumer and 91 workspace cases passed |
| Rust voice suite | 225 passed; 4 opt-in hardware tests ignored |
| `voice-component.test.sh` | 12 consumer/relocation/runner cases and both Rust source-build checks passed |
| `nightly.test.sh` and `nightly-local.test.sh` | 19 and 11 tests passed |
| `make-release.test.sh` | 11 passed |
| `ci-affected-units.test.sh` | 13 passed |
| `make-engine-asset.test.sh` with the verified 1.2.0 runtime | 19 passed, including reproducibility and extracted voice execution |
| `git diff --check origin/main..HEAD` | Passed |

The earlier 56-mutation result still applies to the unchanged voice source.
The nightly suites exercised local fixtures; no release was published. The
installed-app and physical-device acceptance limits above still apply.
