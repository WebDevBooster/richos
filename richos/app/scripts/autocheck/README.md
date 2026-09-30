# Automatic checks at commit and at land

Git runs these itself. Nobody runs them by hand and nobody has to be told to (CEO ruling §97,
2026-09-29, after nightly `20260929T063824Z-b27b6279` was refused on
`clippy::let_underscore_must_use: 782 > 777`, a growth no one had checked before it reached main).

| When | On | What runs | A failure |
| --- | --- | --- | --- |
| `git commit` | every branch but `main`, in every worktree | `lint.sh --changed --strict`: the lint ratchets for what differs from `HEAD` (static and load rules; Clippy for a Rust set whose inputs changed), and no count may grow, whatever room a ceiling has | refuses the commit, with the lint's reason |
| `git commit` | every branch but `main`, in every worktree | a branch-changed file that a reviewed check pins by SHA-256 in `docs/development/verification-input-qualifications.json` must have its pin renewed in the same change (the merge would refuse it with `UnqualifiedReader`); read only when a changed path is named there | refuses the commit, naming the file, the unit and the fix |
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

## NOT RUN is not a pass

A check `proof-run.py` could not run is reported as its own state, `not-run`, with a reason:
`no-screen` (a suite that boots the app on a screen, under `--no-host-screen` with no test-VM
guest named), `host-gap` (a declared host gap), `unchanged-inputs` (a suite skipped by
`RUN_TESTS_SKIP_UNCHANGED`) or `suite-skipped` (a UI suite run directly whose evidence ledger
records only a skip, such as `realbytes.js` with no `cargo`). Until 2026-09-29 `front-door` and
`gui-boot` were recorded as `passed` in exactly that case, and until 2026-09-30 so was a
skipped UI suite.

**The land's decision: a `no-screen` NOT RUN does not refuse the land; every other NOT RUN
does.** Why:

- A land may never put anything on this Mac's screen (CEO ruling §65; `--no-host-screen` is
  how every land runs), so a screen suite can never run in one here. Refusing would make every
  land that touches the app's screen inputs impossible, and the only way through would be
  `--no-verify`, which skips every other check too.
- It is still not a pass, and nothing records it as one: the verdict line says
  `ALLOWED WITH N CHECK(S) NOT RUN, WHICH IS NOT A PASS` and names each one, the land receipt
  lists them under `not_run`, and `nightly-local.py publish` refuses a build of that commit
  until a gui-boot proof taken against it exists (`--gui-proof`). The screen proof is made
  where a screen may be used, the test VM, before anything is published.
- With `RICHOS_GUI_HOST` naming a guest, the same suites run in the guest and are real passes
  or failures; nothing here changes that.
- A `host-gap`, `unchanged-inputs` or `suite-skipped` NOT RUN is a suite that did not answer for this change
  on a host that could have run it, so it refuses. The land check removes
  `RUN_TESTS_SKIP_UNCHANGED` from its environment: a land runs every suite it selected.

## A check's inputs are not another check's outputs

`proof-run.py` fingerprints each qualified check's declared inputs before the run and again
after it; a difference makes a pass `invalid`. In the refused land of 6ef73abf,
`no-foreign-app-data` (inputs include `richos/app/crates`) passed 3 of 3 and was invalidated
because the lint check beside it ran Clippy on `crates/richos-user-update`, whose Cargo target
directory is inside that root. A build cache is output: a directory git ignores, with nothing
tracked in it, carrying the standard `CACHEDIR.TAG` (Cargo writes one into every target
directory) is not part of any check's input identity (`lib/proof_evidence.py`,
`build_cache`). The UI suites' own per-run output directories (`ui/tests/.shots`, `receipts`,
`.vouch`) are output by the same rule, named in `DECLARED_OUTPUT_DIRECTORIES` because their
node writers do not tag them: the push of c7491c34 was refused when `.shots` changed under
`no-foreign-app-data`. Everything else is bound exactly as before. When a pass is still invalidated,
the note names the changed paths and every check that had started by then, instead of only
"execution inputs changed".

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
