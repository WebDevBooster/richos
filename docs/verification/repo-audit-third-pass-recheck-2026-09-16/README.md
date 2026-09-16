# Third-pass fix verification evidence

See the [verification report](../repo-audit-third-pass-fixes-2026-09-16.md) for
results, revisions and exclusions.

- `local-checks.json`: completed local command outcomes, including failed attempts
  and successful reruns. Initial batch revisions denote batch launch, as explained
  in the report.
- `source-identities.json`: component tree comparisons against final product code.
- `reproductions.json` and `ledger-probe.log`: all four final audit regressions.
- `earlier-reproductions.json`: the five earlier audit probes, rerun after these fixes.
- `workspace-before.log`, `partial-cleanup-before.log`, `capture-names-before.log`
  and `log-utf8-before.log`: selected failing regression controls.
- `partial-cleanup-final.log` and `workspace-final-complete.log`: passing final
  lifecycle regressions and all 76 workspace tests.
- `restored-screenshots.json`: the 24 regenerated screenshots restored byte-for-byte.
- `workflow-states.json`: observed GitHub workflow state; no workflow was toggled.
- `engine-original-receipts/`: untouched receipts from the full 141-unit campaign.
  The original container unit failed because two mutation targets no longer matched.
- `engine-unchanged-receipts/` and `engine-unchanged-units.txt`: the original receipts
  and explicit inventory for the other 140 units, with official coverage output in
  `engine-unchanged-coverage.log`.
- `container-receipt.jsonl`, `container-units.txt` and `container-coverage.log`: the
  corrected container unit and its separate official coverage check.
- `engine-summary.json` and `engine-inventory.tsv`: run outcomes and the full inventory.
- `engine-receipt-verification.log`: the original full coverage check correctly
  rejects the failed container unit; that rejection is preserved.
- `container-original-failure.log` and `container-recheck.log`: original failure
  detail and the passing corrected rerun.
- `container-harness-change.json`: confirms that only the container mutation harness
  changed between the full campaign's revision and the subsequent merge.

The two passing coverage checks certify 140 unchanged units at `a6f1c1c1` and the
corrected container unit at `0f3d25bd`. They are separate checks of explicit sets,
not a claim that all 141 units passed at one revision. No receipt SHA or verdict
was rewritten. Copied console logs omit trailing whitespace; raw local logs remain
at the paths documented in the report. The runtime code is unchanged by the test-harness correction.

Run the four-finding verification from the repository root with cached Rust
dependencies, Python 3, Node and Git available:

```sh
PATH="$HOME/.cargo/bin:$PATH" python3 docs/verification/repo-audit-third-pass-2026-09-16/reproduce.py --expect-fixed
```

The script only uses disposable fixtures and synthetic input. The original audit's
`results.json` and `ledger-probe.log` still record the original defects.

## Principal commands

Paths below are relative to the repository root. Rust commands used the installed
toolchain in `$HOME/.cargo/bin`. The desktop and packaging runs shared the separate
`CARGO_TARGET_DIR=/tmp/richos-audit-tauri-target` build cache.

| Working directory | Command |
| --- | --- |
| `richos/app` | `cargo test --locked --offline --workspace -- --test-threads=1` |
| `richos/app/src-tauri` | `cargo test --locked` |
| `richos/app/crates/richos-user-update` | `cargo test --locked --offline -- --test-threads=1` |
| `richos/tools/richos-service` | `node test/run.js` and `node test/workspace.js` |
| `richos/tools/richos-service` | `node test/e2e.mjs` and `node test/host-e2e.mjs` |
| `richos/tools/richos-service` | `node test/coordination-e2e.mjs` and `node test/cross-surface-e2e.mjs` |
| `richos/tools/richos-service` in a disposable clone | `node test/mutation-audit.mjs` |
| `richos/tools/richos-service/companion-macos` | `swift test` |
| `richos/tools/richos-extension` | `node tests/run.js` |
| `richos/tools/richos-service/companion-windows` | `dotnet test tests/RichOSCompanionCore.Tests/RichOSCompanionCore.Tests.csproj` |
| `richos/tools/richos-service/companion-windows` | `dotnet build src/richos-companion/richos-companion.csproj --configuration Release` |
| Repository root | `bash richos/app/scripts/run-tests.sh` |
| `richos/app/ui/tests` | `node run.js` |
| `richos/engine` in each isolated clone | `bash scripts/ci-shard.sh --shard N/4 --receipt RECEIPT` for N = 1 through 4 |
| `richos/engine` in a separate clone | `bash scripts/ci-verify.sh --no-suites` |
| Repository root | `bash richos/engine/scripts/ci-shard.sh --verify-receipts RECEIPT_DIRECTORY` |
| Repository root | `bash richos/engine/scripts/publication-completeness.sh --root .` |

Syntax checks parsed tracked Python files with `ast.parse`, shell files with
`bash -n` and JavaScript files with `node --check`. The final modified reproducer
was additionally executed with `--expect-fixed`.
