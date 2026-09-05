# Managed-run revision validation

Measured on 2026-09-05 in the isolated `codex/durable-orchestration` worktree.
Commands below are from the repository root. Cargo was invoked with its resolved
executable path under the operator's Cargo installation; browser suites used the existing
Playwright installation through `RICHOS_PLAYWRIGHT`.

| Command | Observed result |
| --- | --- |
| `cargo test --manifest-path app/Cargo.toml -p richos-core --quiet` | 711 non-doc tests passed directly, 0 failed. Two additional fixtures are marked ignored in this top-level run and exercised by parent tests as child processes. Five doctests passed. |
| `cargo test --manifest-path app/Cargo.toml -p richos-core --test run_tests --quiet` | 19 passed, 0 failed, 0 ignored. Repeated after the final managed-priming permission change. |
| `cargo check --manifest-path app/src-tauri/Cargo.toml --quiet` | Exit 0, no compiler errors. |
| `python3 app/scripts/test-managed-run-mutations.py /path/to/cargo` | Eight of eight deliberate changes failed their named regression. |
| `node app/ui/tests/runs.js` | 11 checks passed, including computed type sizes and corrupt-journal recovery controls. |
| `node app/ui/tests/appearance.js` | 18 checks passed. |
| `node app/ui/tests/affordances.js` | Passed after registering the new archive refusal and its Stop control. |
| `node app/ui/tests/docs-claims.js` | Passed. Source inventory is explicitly distinguished from runtime test execution. |
| `git diff --check` | Passed. |

The two child-only tests are in `loro_gui_launch_tests.rs`. The original branch's
710 non-doc test declarations included those two fixtures; the original audit's
708 top-level passes excluded them. Both numbers referred to real but different
inventories. The revised README states the distinction rather than implying that
source regex matches are runtime passes.

The full core run preceded the final small change that propagates a permission
denial during managed worker priming. The 19-test managed suite and desktop
compile were then rerun with that change. The managed suite was rerun again
after moving workspace canonicalization ahead of child creation, so a failed
precondition cannot leave an unowned child. The complete browser suite was not
rerun during this revision; the affected suites above were run explicitly.

The model fixtures are controlled subprocesses. They establish our launch flags,
working directory, permission response, failure propagation and completion logic.
They do not establish behavior of every installed Claude version or configuration.
No production run, live team migration or hook deployment was performed.

The installed Claude executable's `--help` also listed `--setting-sources`,
`--permission-mode` and `--no-session-persistence`. That checks flag availability,
not full provider enforcement.
