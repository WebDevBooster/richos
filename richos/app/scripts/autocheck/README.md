# Automatic checks at commit and at land

Git runs these itself. Nobody runs them by hand and nobody has to be told to (CEO ruling §97,
2026-09-29, after nightly `20260929T063824Z-b27b6279` was refused on
`clippy::let_underscore_must_use: 782 > 777`, a growth no one had checked before it reached main).

| When | On | What runs | A failure |
| --- | --- | --- | --- |
| `git commit` | every branch but `main`, in every worktree | `lint.sh --changed --strict`: the lint ratchets for what differs from `HEAD` (static and load rules; Clippy for a Rust set whose inputs changed), and no count may grow, whatever room a ceiling has | refuses the commit, with the lint's reason |
| `git merge` into a branch | every branch but `main` | `lint.sh --changed` (ceilings; what main brings was held to its land) | refuses the merge |
| `git merge` into `main`, a commit on `main` | the main checkout | the suites `proof-for.sh` assigns to the change, run by `proof-run.py`, plus `lint.sh --all` when that selection does not already include `lint.test.sh` | refuses the merge before main moves |
| `git push` of `main` | wherever main is pushed from | the same land checks, only when main's tip has no land receipt (a fast-forward, a cherry-pick, a `--no-verify` merge) | refuses the push |

No formatter runs: the repository does not enforce one.

**The one escape is `--no-verify`.** Git cannot be stopped from honoring it, so it is recorded:
a commit whose tree the commit check never passed, or a main that moved to a tree with no land
receipt, raises an escalation in the lead's ledger (`richos/engine/scripts/escalate.sh`, read
at every session start and turn end) and is appended to
`<git-common-dir>/richos-autocheck/bypass.log`. A rebase, cherry-pick or revert on a branch
replays commits and is not recorded; its land runs the full checks.

## Pieces

- `autocheck.py`: the checks, one file, standard library only. Its header is the reference.
- `shim.sh`: copied into `<git-common-dir>/hooks/` as `pre-commit`, `pre-merge-commit`,
  `post-commit`, `post-merge` and `pre-push`. It runs the committed `autocheck.py` from git's
  object store: HEAD's, else main's, else the incoming branch's (the land that introduces it).
  With none of them, it does nothing.
- `install.sh [--check|--uninstall] [<repo>]`: installs the shim and proves git will call it.
  On this Mac `core.hooksPath` points at a global dispatcher that chains to the repository's
  own hooks; `--check` reports a hook that would never run. It never replaces a hook it did
  not write. Every linked worktree shares one hooks directory, so one install covers the main
  checkout, `~/ab/richos-wt/*`, native worktrees, Codex's and the nightly's.
- `../autocheck.test.sh`: throwaway repositories with stand-in tools; every row of the table
  above, refused and accepted.

Receipts: a passed commit check leaves the tree it checked in the worktree's git directory for
`post-commit` to compare; a passed land check leaves
`<git-common-dir>/richos-autocheck/land/<tree>`. Both are written by the checks and read only
to tell a skipped check from a passed one.

## Cost

Measured on this Mac on 2026-09-29, on the commits and the land check that built this:

| Change | What the commit check runs | Measured |
| --- | --- | --- |
| nothing under `richos/app` (docs, the record) | nothing | 0.0 s in the check |
| scripts, tests, declarations | `--changed --strict` static and load rules over the changed files | 0.2 to 2.5 s |
| a Rust test (the refused `let _ = tx.send(())`) | the above plus the Clippy fast set, warm | 5.3 s for the whole `git commit` |
| the lint itself or its baselines | the full static pass and the fast set | 41 s |

Before this, the same checks cost 35 to 49 s for the static pass and 49 s for a warm Clippy
fast set on every run: `richos-voice`'s build script watched `~/ab/richos-wt`, whose mtime
moves whenever any worktree is created, and recompiled the crate each time (fixed alongside).

The land check costs what `proof-for.sh` assigns to the change, which is what a land was
supposed to run anyway, plus about 4 s of its own (selection and receipt). Measured: a land of
one changed script (5 checks, including `lint.test.sh` and `make-engine-asset.test.sh`) took
128 s end to end in a fresh clone, 112 s of it the lint suite compiling Rust at a new path.
When the selection does not include `lint.test.sh` (an engine-only or documentation land), the
check adds `lint.sh --all`: 58 s warm (`lint.test.sh` as a whole, which a land of anything
under `richos/app` selects, measured 81 s).
