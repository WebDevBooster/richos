# Repository audit, 2026-09-15

Audited commit: `37acdbd9`. Refactor baseline: `3bed39a1`.

This is the original audit snapshot. All five findings were subsequently fixed
and merged. See [the fixes and recheck report](repo-audit-fixes-2026-09-15.md)
for the changes and later verification.

## Findings

Five actionable findings: three relocation regressions and two pre-existing issues.
P1 means high priority, P2 means normal priority and P3 means lower priority.
No production code was changed by this audit.

### 1. P1: Hook-registration enforcement silently skips the relocated repository

Source: [guard-hook-registration-commits.sh](../../richos/engine/scripts/hooks/guard-hook-registration-commits.sh), lines 331-337.

The commit/push guard checks only the repository root and its direct `engine`
child for the engine markers. The product relocation moved those markers to
`richos/engine`. As a result, `HR_ADOPTED` remains zero and the guard returns
success without running the completeness checker. The checker itself was
updated for the new location, so the two entry points now disagree.

**Reproduction:** In a temporary Git repository containing the actual engine at
the new location, commit a baseline then stage a new Bash hook registration
without updating its companion inventories. Running the actual checker with
`--root <fixture> --baseline HEAD` exits 1 and identifies five missing places.
Passing a `git commit` payload for the same fixture to the actual guard exits 0
with no output. No commit is executed by the reproduction.

**Impact:** Incomplete hook registrations can be committed or pushed despite
the guard being installed. This regression was introduced by `59b492c3`.

**Fix:** Share engine discovery with the checker or include the grouped engine
location in the guard. Add a grouped-layout test that invokes the guard itself,
with both incomplete and complete registrations.

### 2. P1: Symlinks bypass the service's public-repository storage boundary

Source: [privacy.js](../../richos/tools/richos-service/lib/workspace/privacy.js), lines 40-43.
Callers: [config.js](../../richos/tools/richos-service/lib/config.js), lines 100-102 and 623-625.

The containment check uses `path.resolve`, which normalizes path text but does
not follow filesystem symlinks. An apparently external evidence directory can
therefore resolve into the public checkout. The same helper also protects the
file-backed token location.

**Reproduction:** Create a temporary symlink to the checkout. Set
`RICHOS_DROP_ZONE` and `RICHOS_WORKSPACE_ZONE` to new directories beneath that
symlink's `docs` directory. Both `dropZone()` and `workspaceZone()` accept their
values even though `fs.realpathSync` of their existing parent resolves to this
repository's `docs` directory. The reproduction performs no evidence writes.

**Impact:** A symlinked storage configuration can put recordings, transcripts or
Workspace evidence into a publicly shipped repository. This is pre-existing;
the refactor expanded the textual boundary but did not close this bypass.

**Fix:** Canonicalize both the protected root and the target's nearest existing
ancestor before checking containment, preserving the remaining path segments
for directories that have not been created yet. Test direct paths, symlinked
ancestors and legitimate external storage.

### 3. P2: The publication-completeness gate fails on a moved test citation

Source: [worktree-ownership-ledger.md](../../richos/engine/docs/worktree-ownership-ledger.md), line 265.

This document still cites the workspace-creation test under the old scripts
directory. The test now lives at
[mega-lander/tests/create-teammate-worktree.test.sh](../../richos/engine/mega-lander/tests/create-teammate-worktree.test.sh).

**Reproduction:**

```sh
bash richos/engine/scripts/publication-completeness.sh --root .
```

Result: exit 1 with one `CITATION` finding naming this document and test.

**Impact:** The actual public-tree gate is red even though the checker’s own
regression suite passes. This regression was introduced by `37acdbd9`.

**Fix:** Update the citation to the moved test and rerun the actual publication
check. No exemption is needed.

### 4. P2: The SessionStart suite is red because a registered hook is not covered

Source: [session-start-stdin.test.sh](../../richos/engine/scripts/hooks/session-start-stdin.test.sh), lines 364-394.
Registration: [hooks.json](../../richos/engine/hooks/hooks.json), line 72.

`left-off-report.sh --event SessionStart` is registered but has no `say_hang`
invocation and is absent from the suite's covered set.

**Reproduction:**

```sh
RICHOS_MUTATION_INNER=1 bash richos/engine/scripts/hooks/session-start-stdin.test.sh
```

Result: exit 1, 12 passed and one failed. Case 9j reports:
`SessionStart scripts registered but never hang-checked: left-off-report.sh`.

**Impact:** The complete engine test inventory cannot pass as checked in.
This does not demonstrate that the hook hangs; it demonstrates missing required
coverage. Both the registration and omission exist at `3bed39a1`, before the
two directory refactors.

**Fix:** Exercise the hook with its actual `--event SessionStart` arguments
against open and closed stdin, then include it in the coverage set. Do not
merely add its name to the set without exercising it.

### 5. P3: Default HQ discovery in the privacy-list seed command is broken

Source: [named-persons.sh](../../richos/engine/scripts/named-persons.sh), line 106.

The default HQ path is derived by climbing a fixed number of directories from
the script. After grouping the product code, it points inside the product
checkout rather than at the sibling HQ repository.

**Reproduction:** A fixture with a grouped product checkout and a sibling HQ
containing a synthetic `ceo/entities.json` returns exit 2 for `--seed`, naming
the incorrect nested path. The same command with `--hq <actual-sibling>` returns
exit 0 and the expected synthetic proposal.

**Impact:** The documented default seed command no longer works. The explicit
`--hq` option is a workaround. This regression was introduced by `59b492c3`.

**Fix:** Derive the enclosing repository's main checkout through Git before
looking for its sibling. Test grouped layouts and linked worktrees.

## Additional known issue

The Windows capture companion still defaults to a working-directory-relative
recording location without the service's repository boundary checks. This can
write recordings into the checkout when launched there. The issue is already
acknowledged in the [Windows README](../../richos/tools/richos-service/companion-windows/README.md),
lines 125-133, and remains present in `Program.cs::ResolveZone`. It is not a new
finding or a refactor regression. Windows execution was not available in this audit.

## Verification

- Core Rust: 982 ordinary tests and five documentation tests passed; four ignored.
- Voice Rust: 225 passed; four ignored.
- Desktop Rust: 98 passed using a fresh Cargo target directory.
- macOS companion: 37 passed.
- Service: 332 transcription/service checks and 68 Workspace checks passed.
- Browser extension: 66 passed.
- Engine: 31 selected shell suites ran; 30 passed and the SessionStart suite
  failed as described above. Behavioral suites used `RICHOS_MUTATION_INNER=1`;
  this is not a claim that all mutation campaigns ran.
- Packaging: engine asset 18, release 11, app packaging 25, frontend payload 10,
  updater setup 33 and packaging runner nine checks passed.
- All 494 tracked shell files passed `bash -n`; all 378 tracked Python files parsed.
- The real publication check failed with the single citation finding above.
- Browser UI: 30 suites passed with 547 observed checks. The main runner exited
  1 because `realbytes.js` skipped when its Rust helper hit stale build paths.
  Rerunning that suite with the fresh Cargo target passed all seven checks.
  All 31 suites were therefore exercised successfully across those runs; the
  original full-run evidence gate remains a failed run, not a clean pass.
- Restored all 24 tracked screenshots regenerated by browser tests. The only
  audit-created source-tree change is this report.

### Local build-cache migration

The existing Tauri target directory contains generated permission-file paths
from before the move. An initial desktop build failed trying to read the old
location. The updater suite also failed nine checks because its Rust helpers
could not build. Both passed with `CARGO_TARGET_DIR=/tmp/richos-audit-tauri-target`.
This is stale local build output, not a demonstrated source compilation defect.

## Scope and limits

The audit traced both relocation diffs and their callers, reviewed storage and
installation boundaries, exercised isolated failure cases and ran the checks
above. It did not run the multi-hour full engine suite, every mutation campaign,
Windows execution, live account integrations or a signed production release.
The intentional CI pause was not changed or treated as a defect. Existing
ignored tests remain gaps rather than passes.
