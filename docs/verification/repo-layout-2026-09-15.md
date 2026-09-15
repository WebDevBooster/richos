# Product directory relocation

The implementation started on `codex/repo-layout` at
`3bed39a143150172a341b11fd617e6ba8decc7b5`, verified equal to both local `main`
and freshly fetched `origin/main`. No changes from the discarded attempt were reused.

`app/`, `engine/` and `tools/` now live inside `richos/`. Repository metadata,
publication declarations, documentation and the root license remain outside it.
The marketplace points to `./richos/engine`. Packaged engine archives still contain
`engine/`, so the installed archive contract has not changed.

The source relocation also updates workflow paths, Dependabot directories, build
scripts, source discovery, fixture paths, documentation links and provenance paths.
Privacy checks protect the entire outer checkout, including `docs/` and `.richos/`.
Existing CI pause settings are unchanged.

## Verification

Checks ran against the relocated working tree based on the commit above. Browser
receipts therefore identify that base commit, not the later relocation commit.

| Check | Result |
| --- | --- |
| Tracked file preservation | All 6,095 existing files at their expected destinations |
| Licenses, lockfiles, vendored content and hook registrations | 147 files byte-identical |
| Previously valid Markdown links | 337 preserved |
| Shell syntax and whitespace | All tracked shell scripts pass `bash -n`; `git diff --check` passes |
| Core Rust tests | 982 ordinary passes, 4 existing ignored tests; 5 documentation passes |
| Voice Rust tests | 225 passes, 4 existing ignored tests |
| Desktop shell tests | 98 passes |
| Browser tests | All 31 suites, 554 checks, no skips; all four shard receipts reconciled |
| Service and workspace privacy | 332 service passes and 68 workspace passes |
| macOS companion | 37 passes, including grouped-checkout privacy regression |
| Browser extension | 66 passes |
| Engine asset, app packaging and release tests | 18, 25 and 11 passes respectively |
| Frontend payload, updater and packaging runner | Passed; updater 33, runner 9 passes |
| Real engine archive | Reproducibility check passes; 702 tracked files plus two license additions, no untracked members |
| Publication completeness and dependency licenses | Both pass against the relocated tree |
| Engine affected-unit selection, hardware detection and engine location | 10, 15 and 20 passes respectively |
| Hook registration completeness suite | 33 passes |
| Workspace probe runner | 47 passes and 18 mutation controls |
| Publication completeness suite | 53 passes |
| Vendoring guard | 60 passes and 20 mutation controls |
| Session evidence | Regression suite and all 8 mutation controls pass |

The first voice run failed its live macOS synthesis speed threshold at real-time
factor 0.509 while other builds were running. The complete voice suite passed on
rerun without changing source or relaxing the threshold.

Windows source discovery was updated but Windows execution was not verified on
this Mac; the .NET CLI is unavailable. The full multi-hour engine suite was not
run. The engine checks above target the relocated paths and their consumers.
No release was published and no signing identity or dependency version was changed.
