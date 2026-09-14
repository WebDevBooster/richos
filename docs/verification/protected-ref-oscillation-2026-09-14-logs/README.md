# The engine moving `refs/heads/main` — reproduction, fix, and the evidence for both

The defect: `_restore_protected_refs` in `engine/scripts/lib/workspaces.py` moved
`refs/heads/main` in `/Users/alex/ab/richos` three times on 2026-09-13/14, twice
within twelve seconds in opposite directions, while a land was in progress.
Diagnosis: `docs/verification/ref-write-forensics-2026-09-14.md` (sage-opus-w1).
Fix: a move is reported and the ref is left alone; only a DELETION is put back,
by a create-only, attributed write.

## Re-running any of it

    python3 repro.py --lib ../../../engine/scripts/lib/workspaces.py [--mode destruction]
    python3 check-mutants.py <path to a richos worktree>

`repro.py` exits 0 when the engine left the ref where the lead put it, so
**before** the fix both modes exit 1 and **after** it both exit 0. Nothing
outside its own temporary directory is read or written.

## The files

| File | What it is |
|---|---|
| `01-before-the-fix-oscillation.txt` | Two agents, one land. The engine rewinds main, then a second agent puts it back: two empty-message reflog lines, and the two `why` strings come out byte-identical to the real events 4 and 5. Exit 1. |
| `02-before-the-fix-destruction.txt` | The same mechanism, different timing: the lead lands again between the two hooks and that merge is dropped from main. `the lead's last land still reachable: NO - HIS LAND IS GONE`. Exit 1. |
| `03-after-the-fix-oscillation.txt` | Main untouched, zero empty-message reflog lines, one `protected-ref-moved` event — and the second agent has nothing to report, because nobody moved anything. Exit 0. |
| `04-after-the-fix-destruction.txt` | Both of the lead's merges intact. Exit 0. |
| `05-the-new-tests-against-the-reverted-library.txt` | The four new/changed library tests run against `workspaces.py` with the fix reverted in a scratch copy: all four RED. The same 19 tests are green with it. |
| `06-the-new-mutants-each-turn-their-named-test-red.txt` | Each mutant added to the two mutation harnesses applies to the shipped source and turns its named test red. |
| `07-workspace-spec-fourteen-suite-after-the-fix.txt` | The whole certification suite after the fix: `CHECKS RUN: 15  RED: 0`. |
| `08-the-whole-library-suite-after-the-fix.txt` | Every point of the library's own suite, not only the two I touched: 68 run, 0 failed. |
| `repro.py`, `check-mutants.py` | The two scripts above. |

`07` was produced with `RICHOS_MUTATION_INNER=1`, which runs the checks and skips
the mutation harness — the harness runs the entire suite once per mutant and is
the lead's to run at land time, not an engineer's per-change cost.
