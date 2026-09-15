# Mega Lander

Mega Lander automates the workspace lifecycle for **cross-repo agent work**.
An agent can have a native workspace in the session's base repository and a
`cc/` workspace in another repository. Mega Lander tracks them as one agent's
work so finished branches, worktrees and processes do not accumulate across
repositories or survive forgotten sessions.

The governing rules remain [the workspace spec](../../../docs/plans/worktree-spec-2026-09-11.md).
The same registry also handles native-only agents and the base-repo
workspace of cross-repo agents.

## Directory map

| Path | Responsibility |
| --- | --- |
| `workspaces.py` | Registry, session and agent lifecycle, integration records, landing eligibility, deletion and retries |
| `workspaces.sh` | Command-line entry point for the registry |
| `create-teammate-worktree.sh` | Registers and creates a workspace in another repository, including `.worktreeinclude` seeding |
| `workspace-probes.py` | Runs committed regression probes against the registry |
| `tests/` | Spec tests, cross-repo lifecycle tests, probe-runner tests and mutation harnesses |

Claude adapters remain in [`../scripts/hooks/`](../scripts/hooks/):

- `workspace-lifecycle.sh` records platform events.
- `guard-workspace-gate.sh` enforces pending-work handling at turn end.
- `guard-worktree-isolation.sh` enforces registration and isolation at spawn.
- `guard-sealed-worktree.sh` locks out finished agents.
- `guard-resume-isolation.sh` checks resumption.
- `guard-worktree-removal.sh` guards direct workspace operations.
- `observe-created-refs.sh` attributes branches to agents.

[`../hooks/hooks.json`](../hooks/hooks.json) remains the hook registration surface.
Shared orchestration stays in `../scripts/spawn.sh` and `../scripts/lib/spawn.py`.
Completion checks, container management and other shared consumers use this
registry as their shared source of workspace state and landing eligibility.

## Lifecycle

1. Record the integration branch for each repository involved in the work.
2. Register the cross-repo workspace before creating it or spawning the agent.
3. Bind the platform agent and its native workspace to the same record.
4. Record completion, pause, resume or session ending from lifecycle facts.
5. Resolve finished work by landing or authorized discard, then remove all of
   that agent's workspaces and branches together. Stop its processes first and
   retry failed deletion automatically.

`land` checks that committed work is already merged into the recorded
integration branch. It does not perform the merge. Pending-work gates enforce
that the lead handles unfinished integration before starting new work.

## Commands

Run these from the engine directory:

```sh
mega-lander/workspaces.sh --help
mega-lander/workspaces.sh status
mega-lander/workspaces.sh integration --repo /path/to/repo --branch dev/example --why 'this body of work'
mega-lander/workspaces.sh land <agent>
mega-lander/workspaces.sh retry
```

The usual spawn entry point remains `scripts/spawn.sh`. It calls Mega Lander's
creator as part of preparing a cross-repo agent. The creator can also be run
directly: `mega-lander/create-teammate-worktree.sh <repo> <agent-name>`.

Existing command paths in `scripts/` forward here. The old
`scripts/lib/workspaces.py` import path also forwards here for external callers
and historical probes. These compatibility files contain no lifecycle policy.
Maintained engine consumers use the canonical feature paths.

## State and worktree locations

This source-code move does not migrate runtime state. The store remains at
`$RICHOS_WORKSPACES_DIR`, otherwise `$CLAUDE_CONFIG_DIR/state/workspaces`,
otherwise `~/.claude/state/workspaces`.

The store contains `sessions/`, `agents/`, `done/`, `ids/`, per-call snapshots
under `refs/`, `repos.json`, `integration.json`, `events.jsonl` and a mutation
lock. All repositories share that store.

Cross-repo worktrees default to a sibling `<repo>-wt/<agent-name>` directory
with branch `cc/<agent-name>`. Native worktrees remain under the base repository's
`.claude/worktrees/agent-<id>`. `codex/` protections are unchanged.

## Verification and installation

```sh
bash mega-lander/tests/workspaces.test.sh
bash mega-lander/tests/create-teammate-worktree.test.sh
bash mega-lander/tests/workspaces-e2e.test.sh
bash mega-lander/tests/workspace-spec-fourteen.test.sh
bash mega-lander/tests/workspace-stopped-ending.test.sh
bash mega-lander/tests/workspace-probes.test.sh
bash mega-lander/tests/relocation.test.sh
```

The core, creator, fourteen-point and probe suites retain their mutation
harnesses. CI discovers the moved shell suites recursively. Historical probes
remain in `docs/verification`; the runner accepts their old import paths and
can test commits from before the move with `--at`.

The existing hook installer hashes the canonical registry and command here.
Integrity layer Q checks those files and exercises the real lifecycle hooks.
Sandbox builders and hook dependency discovery include `mega-lander/`.
The installed engine pointer continues to point to the engine root.
