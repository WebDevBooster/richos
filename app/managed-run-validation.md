# Owned-work revision validation

Measured on 2026-09-05 in the isolated `codex/durable-orchestration` worktree.
All commands run from the repository root. `cargo` below was the actual executable
`/Users/alex/.cargo/bin/cargo`. Browser suites used the installed Playwright through
`RICHOS_PLAYWRIGHT`. No production session or main checkout was changed.

| Command or trial | Observed result |
| --- | --- |
| `cargo test --manifest-path app/Cargo.toml -p richos-core` | 719 non-doc tests passed directly, zero failed. Two child-only fixtures ignored at the top level are exercised by parent tests. Five doctests passed. 721 is the non-doc source inventory, not the direct pass count. |
| Managed tests within that full run | 27 passed. Covers continuation beyond the autonomous attempt ceiling, independent acceptance, restart, pause, decision receipt idempotency, company scope, ledger vocabulary and managed child cleanup. |
| `cargo build --manifest-path app/src-tauri/Cargo.toml` | Debug desktop compiled successfully with the final scheduler and permission changes. |
| `python3 app/scripts/test-managed-run-mutations.py /Users/alex/.cargo/bin/cargo` | Eight of eight deliberate regressions were killed by their named tests. |
| Full UI runner | All 23 discovered suites ran, zero skipped. 446 checks observed. 22 suites passed initially; affordances failed on missing classifications and a stale state row. |
| `node app/ui/tests/affordances.js` after registry correction | Passed, exit 0. No affordance rule was weakened. |
| `node app/ui/tests/docs-claims.js` | Six checks passed with the 721 source count and updated event documentation. |
| `node app/ui/tests/runs.js` within the full UI run | 13 checks passed, including automatic retry, CEO decision display, type sizes and recovery controls. |
| Installed Claude, natural-language `richos-run handle` | Exit 0 and Completed after intake, file creation and independent read-only review. `hello.txt` contained exactly the requested 20 bytes, with no trailing newline. No manual setting edits or intervention. |
| Actual desktop restart harness | Passed against the final debug binary: acceptance, restart, false completion rejection, scoped output and completion-notice crash recovery. |
| Actual older ledger reader | A temporary executable built against the unchanged main checkout's older core read and rendered the new desktop ledger successfully, including exactly one CEO request and its completion notice. |

The desktop harness is reproducible:

```sh
cargo build --manifest-path app/src-tauri/Cargo.toml
python3 app/scripts/test-owned-work-desktop.py
python3 app/scripts/check-owned-ledger-compat.py /path/to/older/app/crates/richos-core /path/printed/by/harness/data/conversation-ledger.jsonl /path/to/cargo
```

It boots the real desktop with an isolated data directory and invokes its actual
message command. The first boot exits before inference. The second selects another
company while the original job runs. The fixture falsely says “All done” on its
first attempt without creating the deliverable. Assertions require two attempts,
the correct file, exactly one CEO request, a verified completion notice and no
output leaking into the selected company. A third boot tests the crash gap between
committing verified completion and publishing its conversation notice. It must
recover that notice without executing the job again.

## Failures, corrections and evidence boundaries

- The first core run rejected an added `libc` dependency under the existing privacy
  allowlist. The dependency was removed; process cleanup uses the system `kill`
  executable. The allowlist was not relaxed.
- A launch-policy test's source parser mistook prose for a function declaration and
  matched function-name prefixes. The parser was corrected without changing the
  banned launch behavior. Its 11 tests and the full core suite passed afterward.
- The docs-count checker found an earlier prose mention instead of its matched
  README command line. It now checks the exact matched line.
- Earlier native trials failed on commentary surrounding JSON, a transport timeout
  and a terminal stop reason of `tool_use` despite a valid structured result. Those
  trials were not counted as success. The inspector now consumes structured output
  and accepts that stop reason only when such output exists. The final complete
  natural-language trial passed.
- The desktop fixture initially matched task text in priming and then mishandled a
  protocol content array. Both failures were corrected before claiming continuation.
- The installed-native completion trial preceded the final background-task disable
  flags. Those flags are covered by subprocess assertions and the final desktop
  build; the native trial does not establish every provider version's enforcement.

The full UI run was not repeated after the isolated state-registry correction.
Its affected suite was rerun. Browser tests exercise the actual webview code with
mocked IPC. The desktop harness exercises actual IPC entry, persistence and native
transport with a controlled subprocess. The installed-native trial exercises a
real provider for one bounded file outcome. These are complementary evidence,
not proof of arbitrary business-task competence or exactly-once external effects.

Independent product/design review remains external to this implementation. No
release package, deployment, main-branch merge or live Claude team migration is
claimed. See [ORCHESTRATION-REVIEW.md](ORCHESTRATION-REVIEW.md) for the review brief
and [MANAGED-RUNS.md](MANAGED-RUNS.md) for the operational limits.
