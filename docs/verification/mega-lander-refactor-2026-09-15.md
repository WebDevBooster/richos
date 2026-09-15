# Mega Lander directory refactor

Date: 2026-09-15. Base: `59b492c3`. Branch: `codex/mega-lander-refactor`.

## Result

The cross-repo agent workspace feature now lives under
[`richos/engine/mega-lander`](../../richos/engine/mega-lander/README.md).
It keeps the native workspace in the base repository and the agent's workspaces
in other repositories under the same lifecycle and cleanup rules.

Moved:

- The workspace registry and operator command.
- The registered cross-repo workspace creator.
- The regression probe runner.
- The core, creator, cross-repo lifecycle, fourteen-point, stopped-ending and
  probe-runner suites, including their mutation harnesses.

Claude hooks remain adapters in `scripts/hooks`. Shared spawn orchestration,
completion checks and container management retain their existing boundaries.
Maintained consumers now use the feature's canonical paths. Existing command
and Python import paths forward to the new implementation for compatibility.

The registry's functions and classes compare identically to the base version
except for `stop_containers`, whose shared-library lookup now accounts for the
new directory. No workspace rule changed. State paths, integration records,
worktree paths and `codex/` protections remain unchanged.

Installation hashes the canonical files. Hook dependency discovery and partial
engine copies include the feature. CI discovers the moved suites and also
selects a feature's `tests/<name>.test.sh` when `<name>.py` or `<name>.sh` changes.
Generated hash sidecars remain ignored, as they were before the move.

## Verification

These are local working-tree results. The behavioral workspace suites ran with
`RICHOS_MUTATION_INNER=1`, separating their checks from the mutation harnesses
listed later.

| Suite | Result |
| --- | --- |
| Core workspace rules | 68 tests passed |
| Cross-repo workspace creator | 19 checks passed |
| End-to-end workspace lifecycle | 47 checks passed |
| Fourteen-point spec | 14 groups and final cleanup self-check passed |
| Stopped-agent endings | 5 groups passed |
| Probe runner | 46 checks passed |
| Relocation compatibility | 6 tests passed |
| Spawn orchestration | 32 checks passed |
| Spawn isolation guard | 168 checks passed |
| Workspace removal guard | 161 checks passed |
| Resume isolation guard | 58 checks passed |
| Finished-agent lockout | 23 checks passed |
| Container reaping | 19 tests passed |
| Landing completeness | 22 checks passed |
| CI landing guard | 18 checks passed |
| Unresolved-claim guard | 65 checks passed |
| Hook dependency discovery | 14 checks passed |
| CI suite inventory | 17 checks passed |
| CI affected-suite selection | 10 checks passed |
| Command guidance | 25 checks passed |
| Mutation sandbox harness | 24 checks passed |
| Workspace integrity sections Q and Qscope | 41 checks passed; expected scoped-success exit code 3 |
| Engine loaded from another repository | 53 checks passed |
| Protected-ref notices | 15 checks passed |
| Completion proof | 25 tests passed |

The six new relocation tests cover command forwarding with argument and exit-code
preservation, import compatibility, selecting a supplied library through a
historical in-tree probe, dependency discovery across the new directory,
CI selection of feature-local tests and probing a commit from before the move.

## Mutation verification

The relocated harnesses detected all 78 deliberately broken variants:

- Core registry: 56 of 56.
- Probe runner: 18 of 18.
- Workspace creator: 4 of 4.

The separate fourteen-point mutation harness, engine-wide test suite and remote
CI were not run. No release was published.
