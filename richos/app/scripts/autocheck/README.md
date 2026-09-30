# Automatic checks at commit and at land

Git runs these itself. Nobody runs them by hand and nobody has to be told to (CEO ruling §97,
2026-09-29, after nightly `20260929T063824Z-b27b6279` was refused on
`clippy::let_underscore_must_use: 782 > 777`, a growth no one had checked before it reached main).

| When | On | What runs | A failure |
| --- | --- | --- | --- |
| `git commit` | every branch but `main`, in every worktree | `lint.sh --changed --strict`: the lint ratchets for what differs from `HEAD` (static and load rules; Clippy for a Rust set whose inputs changed), and no count may grow, whatever room a ceiling has | refuses the commit, with the lint's reason |
| `git commit` | every branch but `main`, in every worktree | a branch-changed file that a reviewed check pins by SHA-256 in `docs/development/verification-input-qualifications.json` must have its pin renewed in the same change (the merge would refuse it with `UnqualifiedReader`); read only when a changed path is named there | refuses the commit, naming the file, the unit and the fix |
| `git merge` into a branch | every branch but `main` | `lint.sh --changed` (ceilings; what main brings was held to its land) | refuses the merge |
| `git merge` into `main`, a commit on `main` | the main checkout | the suites that own the changed files (`proof-for.sh --gate`), run by `proof-run.py`, plus `lint.sh --changed` when the land changes something under `richos/app` and that selection does not already include `lint.test.sh`; each check capped at 600 s, the gate at 900 s | a failing check refuses the merge before main moves; nothing else does |
| `git push` of `main` | wherever main is pushed from | the same land checks (the lint as `--all`: HEAD is already the land), only when main's tip has no land receipt (a fast-forward, a cherry-pick, a `--no-verify` merge) | refuses the push |

No formatter runs: the repository does not enforce one.

**A branch commit is checked on the bytes it commits.** Until 2026-09-30 the commit check
linted the working tree and approved the staged copy, so a bad staged edit whose unstaged
replacement passed was committed with no record, and a clean staged edit was refused over
unstaged work it did not hold (hunt part 2, finding 10). Now, when anything under
`richos/app` is staged, the unstaged difference is saved as a binary patch and untracked
files are moved into `<worktree git dir>/richos-autocheck-aside/` for the length of the
check, so the working tree is exactly what is being committed (the index git hands the
hook, including the temporary one of `git commit <path>` and `-a`); afterwards both are put
back. This is the design of pre-commit's `staged_files_only`. Ignored files are never moved.
If a check is killed while work is set aside, or it cannot be put back, it stays in that
directory, whose `README.txt` says how to restore it, and every later commit check refuses
until it is gone.

**Putting work back never overwrites a later save** (recheck N01, 2026-09-30). Editing goes
on while a commit is checked. A tracked file written during the check, by the check or by
an editor, is left exactly as found and named, unless the set-aside edits also touch it.
In that case the newer bytes are first moved to `changed-during-check/` in the same
directory, your edit from before the check is put back, and the commit is refused so you
can compare the two and keep what you want. Until 2026-09-30 that collision reset the whole
working tree to the index, which erased saves in files the edits never touched.

**The one escape is `--no-verify`.** Git cannot be stopped from honoring it, so it is recorded:
a commit whose tree the commit check never passed, or a main that moved to a tree with no land
receipt, raises an escalation in the lead's ledger (`richos/engine/scripts/escalate.sh`, read
at every session start and turn end) and is appended to
`<git-common-dir>/richos-autocheck/bypass.log`. A rebase, cherry-pick or revert on a branch
replays commits and is not recorded; its land runs the full checks.

## A changed reader the engine's input selector pins

`richos/engine/scripts/lib/verification-dependencies.json` pins every reviewed reader by
SHA-256. A stale pin makes `verification_inputs.py` refuse every unit that reaches it
("changed reader requires input qualification"), and `verification-inputs.test.sh` fails. On
2026-09-30 that happened twice in one day on main (95 failures, then 108), each time summed
from branches whose own commits had passed. So every branch commit also runs
`dependency-pins.py` (the committed copy at `HEAD`, else `main`'s): over the branch's changed
files only, it compares each file the declaration pins (a node source, a hook-reader source, an
external reader in this repository, and any pin the branch typed by hand) with the bytes being
committed, and refuses a mismatch, naming the file, the row and the renewal command:

    python3 richos/app/scripts/autocheck/dependency-pins.py --renew <file> ...

Renew only after reading the file's added lines for a new configuration key, environment
variable or file it now reads, and declaring it in that row. `--all [--rev <commit>]` lists
every stale pin in the file. It parses the declaration only when a changed path is named in it,
and takes under a second on a branch that renewed 274 pins. `../dependency-pins.test.sh` proves
it with throwaway repositories and checks its digests against `verification_inputs.py`.

## The merge gate: small, capped, and blocking only on a failure (2026-09-30)

The CEO, after a day of 25-71 minute merge checks that failed on everything but the fixes:
*"That whole CI shitshow had the exact same end effect as what has been happening today"*.
T3 Code's release gating (adoption ledger §2.4) is the design copied: affected checks only,
every job capped at 10 minutes. A merge into main runs exactly:

1. **The lint on what changed**: `lint.sh --changed` against the main being landed onto,
   which the lint guarantees is never looser than `--all`. The push backstop keeps `--all`.
2. **The owning suites of the changed files**, from `proof-for.sh --gate`: a directory
   input (a suite that reads a whole tree) selects its suite only for a product path, so a
   change to scripts, the engine, the UI test harness or documents runs only the suites that
   cover or name its files. The merge of zach-opus-lander1 (three mega-lander files) ran
   make-engine-asset, gui-boot and proof-for for that reason; it no longer does.
3. **Caps**: `proof-run.py --cap 600` stops every check, engine units included, at ten
   minutes whatever a dated weight predicts, and `--run-cap` ends the run at what is left of
   the gate's 900 s; admission and the proof-run slot wait no longer than that either.

**Left to the nightly, by name**: suites that need a device this Mac has one of: the
iPhone simulator (native-ios-app, native-ios-share, native-ios-ui, mobile-ios) or a screen,
the host's or the test VM's guest (read off the suite as `proof-run.py` reads it). The
mutation passes of the workspace suites run only under `RICHOS_MUTATION_PASSES=1` (and the
fourteen-point suite's under `RICHOS_FOURTEEN_MUTANTS=1`), which the nightly's
`gates/workspace-mutants` sets (hunt part 4 finding 19).

**What blocks**: a check that failed (`failed`), an unchanged failure the runner refuses to
run again (`blocked`), and an `invalid` result for any reason except inputs that changed while
the gate ran (an invalid result can hide a failure, for example a UI suite whose ledger
records a failed check). `engine receipts` blocks only when every engine unit passed.
**Nothing else blocks**: a check over its cap, ended at the gate's cap, not admitted, stopped
by the verification controller, NOT RUN for any reason, or left to the nightly is named in
the verdict and written to the receipt's `not_run` with its reason. The nightly
(`nightly-local.py`) runs all of it and stays the release gate.

### Measuring the gate

`python3 richos/app/scripts/autocheck/autocheck.py measure`, run by hand in a checkout, runs
the land check of what is staged there against HEAD, exactly as a commit onto main does, and
writes no land receipt. To replay a land: detach, stage the land's change on top of a base
without it, run `measure`, then return to the branch.

Measured 2026-09-30 on cc/zach-opus-gate1 (07d289da8), replaying two of that day's lands:

| Land | Old gate that day | New gate |
| --- | --- | --- |
| zach-opus-lander1 (3 mega-lander files) | 11.4 min (21 checks) and 24.3 min (45 checks, iPhone suites, make-engine-asset, gui-boot), both refused | 2.9 min, 8 checks (6 engine units, receipts, the contamination row); refused: `verification-inputs.test.sh` (reader pins changed by an earlier land) and the change's own `app.test.sh` writing its HOME record |
| echo-opus-assign1 (4 richos-core files) | 4.0 min (21 checks) refused; a second try passed 10 min with the iPhone suites failing | 5.6 min cold (sccache bypassed, see the escalation of that day), 16 checks, front-door and gui-boot left to the nightly; refused: `operator-walk.test.sh` W5, whose snippet in operator_host.rs the change removed |

Both refusals are failures of checks the change owns; nothing was refused for a simulator, a
screen, a cap or admission.

## NOT RUN is not a pass

A check `proof-run.py` could not run is reported as its own state, `not-run`, with a reason:
`no-screen` (a suite that boots the app on a screen, under `--no-host-screen` with no test-VM
guest named), `host-gap` (a declared host gap), `unchanged-inputs` (a suite skipped by
`RUN_TESTS_SKIP_UNCHANGED`) or `suite-skipped` (a UI suite run directly whose evidence ledger
records only a skip, such as `realbytes.js` with no `cargo`). Until 2026-09-29 `front-door` and
`gui-boot` were recorded as `passed` in exactly that case, and until 2026-09-30 so was a
skipped UI suite.

**The land's decision (since 2026-09-30): no NOT RUN refuses the land; each is named.** Until
then a `host-gap`, `unchanged-inputs` or `suite-skipped` NOT RUN refused it, and only
`no-screen` was accepted, for the reasons below. A check that did not run is not a failure of
the change, and the merge gate blocks only on failures (above); the nightly answers for it.
The original reasoning for the screen case, which still holds:

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
- The land check still removes `RUN_TESTS_SKIP_UNCHANGED` from its environment: a land runs
  every suite it selected, so an `unchanged-inputs` NOT RUN does not happen there.

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
When the land changes something under `richos/app` and the selection does not include
`lint.test.sh`, the check adds `lint.sh --changed` (until 2026-09-30 `--all`, 58 s warm); a
land that changes nothing under `richos/app` (engine-only or documentation) adds nothing, as
the commit check does. The merge gate's own measured cost is in the land records of the
change that introduced it (cc/zach-opus-gate1).

## Merge retries and phone scope

Merge checks retain each proof attempt on the mounted external SSD under
`/Volumes/E1TB/state/richos/proof-runs/autocheck/`. An unchanged tree and selection
resume the frozen plan. A changed tree gets a fresh selection and offers the previous
attempt to the runner with `--reuse`. The runner validates inputs and evidence before
reusing a pass. Missing or corrupt retry records refuse the check. Resource refusals
remain NOT RUN and cannot satisfy a merge. Diagnosed behavioral retries still require
`RICHOS_AUTOCHECK_RETRY_REASON`; the hook supplies no automatic diagnosis and preserves
the runner's existing retry budget.

The three iPhone suites declare `select-inputs` for product dependencies separately
from their broader `inputs` used to validate saved evidence. Harness changes run the
fixture controls in `merge-check-scope.test.sh`. Actual Core, project, plist and app
inputs still select the phone checks for an engineer's own proof and the nightly; since
2026-09-30 a merge into main leaves the simulator suites to the nightly and names them (the
merge gate, above). Where they run, they queue on one simulator lane with a finite pool wait
bounded by the check's existing deadline.

`lib/ios_ui_scope.py` maps reviewed feature files to their affected XCTest families
and unit-test suites. Shared inputs, new feature files and unreviewed test inventories
use full coverage. When adding cases or changing feature dependencies, review this
map before refreshing its inventory fingerprint. A test-source change selects its
own cases. Simulator retries enumerate the required cases and re-read the retained
result bundles with matching source/tool/device/selection identity and build stamps.
Only failed or missing cases rerun, plus the existing unit-bundle attribution probe
when required. A completed device reuses its evidence without acquiring a simulator.
Failure bundles stay in the external cache and are copied into the proof report;
reports retain the distinction between newly executed and reused cases.
