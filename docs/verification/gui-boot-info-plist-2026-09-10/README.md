# The boot check had been booting nothing for nine days — 2026-09-10

`app/scripts/gui-boot.test.sh` is the check that makes a dead RichOS launch unshippable. It
had been dead itself since `01e9b8d8` (2026-09-08), and the thing that kept that invisible
was a declared CI host gap that was true the whole time.

Everything below was measured on this machine on 2026-09-10. Every claim carries the command
that produced it and the file it produced.

## 1. The defect

`01e9b8d8` put `update_startup::prepare` at the top of `main()`. It resolves the bundle root
around the executable and reads `Contents/Info.plist`
(`app/crates/richos-user-update/src/lib.rs:570-575`). The boot fixture had never written one
— `gui-launch.sh` copied the binary into `RichOS.app/Contents/MacOS/` and stopped there — so
from that commit onward every boot in the suite ended on its first line:

    [richos] application startup: No such file or directory (os error 2)

Last change to the fixture: `f079cae1`, and `git merge-base --is-ancestor f079cae1 01e9b8d8`
exits 0 — the fixture was already in its final shape when the requirement landed. The
breakage is the product moving, not the harness changing.

## 2. What was actually red, which is not what it looked like

`raw/A-before-suite-red-on-a-complete-host.log`, run on `7272ecf8`:

    === gui-boot.test.sh: 3 FAILED, 18 passed ===

B1 and B2 were the red ones. **Six of the eighteen passes were false.** B3-B8 exist to prove
that the detector for one seam is alive on this run — and each of them "passed" by observing
the same dead line the healthy boot produced:

    PASS  B3 the engine pointer is removed -> caught
             UNACCOUNTED  [richos] application startup: No such file or directory (os error 2)
    PASS  B4 the corpus pointer is removed -> caught
             UNACCOUNTED  [richos] application startup: No such file or directory (os error 2)

...identically for B5, B6, B7 and B8. A machine that never boots is indistinguishable from a
machine with its engine pointer removed. Only `B6a`, which demands one specific sentence,
noticed.

After the fix (`raw/B-after-suite-green-on-a-complete-host.log`) each cites its own seam:

    PASS  B3 ...  UNACCOUNTED  [richos] engine directory: NOT FOUND — 5 place(s) tried
    PASS  B4 ...  UNACCOUNTED  [richos] loro Tier C: no corpus configured
    PASS  B6 ...  UNACCOUNTED  [richos] first-run setup: Claude Code is NOT installed

## 3. Two conditions, not one

**The Info.plist.** `gui_bundle` now lays out a real bundle. The identifier and version in it
are asked OF THE BINARY through the installer's own `--richos-internal-update-identity` probe
(`update_startup.rs:14-27`) — measured `com.richos.app 1.0.3`. A typed number would not do:
`prepare` compares the plist version against the compiled one and treats a difference as a
CHANGED application, which on a machine with no publication receipt refuses to start at all.

**A home that was not canonical.** `mktemp -d` hands back `/var/folders/…`; `/var` is a
symlink to `/private/var`, so the scratch home did not equal its own `canonicalize()`, and
`richos_user_update::root` (`lib.rs:135-142`) refuses such a home:

    [richos] application startup: Could not establish application update exclusion:
             home is not a canonical directory

A real home IS canonical — `/Users/alex` is its own realpath — so this was a condition no
launch the suite claims to reproduce has ever had. `pwd -P` removes it.

`healthy-boot.log` is the transcript the suite's own `healthy_log()` fixture was retaken
from. Two lines had drifted: the `activation:` line lost its
`carries no readable CFBundleIdentifier` clause (that condition now holds), and the
`RICHOS_SERVICE_BIN` line had grown a clause since it was last captured.

## 4. Proof that the restored cases can still go red

**`raw/C-forced-break-no-info-plist.log`** — the 2026-09-08 defect put back:

    FAIL  C1 the harness builds a real .app
    FAIL  C2 the Info.plist carries every key the product's own updater reads
              missing from gui_bundle_plist: CFBundleIdentifier CFBundleShortVersionString
    FAIL  C3 ... FAIL  C4 ...
    === gui-boot.test.sh: 4 FAILED, 8 passed ===

**`raw/D-forced-break-wrong-bundle-version.log`** — a bundle that is structurally perfect and
declares `9.9.9`. This is the one that matters for "B1/B2 decide on their own", because
C1-C4 stay GREEN and the boot half goes red anyway:

    PASS  C1  PASS  C2  PASS  C3  PASS  C4
    FAIL  C5 the binary reports 'com.richos.app 1.0.3' and the plist says '9.9.9'
    FAIL  B1 [richos] application startup: Changed application has no publication receipt.
    FAIL  B1a  FAIL  B2
    === gui-boot.test.sh: 5 FAILED, 22 passed ===

Note B3-B8 pass again here. The false-green is reproducible on demand, which is why C1-C5
exist rather than a note asking people to look at B3-B8 more carefully.

## 5. The concealment, reproduced and then closed

The runner condition was reproduced on this machine by pointing `HOME` at an empty directory
(the only thing `gui_compiler_source` reads besides `$RICHOS_LORO_SOURCE`) with cargo kept on
PATH, and running `run-tests.sh` under the declaration `packaging-ci.yml:166` carries
verbatim.

| | suite | run-tests.sh | exit |
|---|---|---|---|
| **BEFORE** — dead suite, honest gap (`raw/E-…`) | exit 2 | `8 of 9 suites passed — 149 checks — 1 could not run on this host` | **0, green** |
| **AFTER** — dead suite, same gap (`raw/F-…`) | exit 1 | `1 of 9 suite(s) FAILED: gui-boot.test.sh` | **1, red** |
| **AFTER** — healthy suite, honest gap (`raw/G-…`) | exit 2 | `8 of 9 suites passed — 151 checks — 1 could not run on this host` | **0, green** |

Row 1 is the nine days, reproduced: a suite that could not answer ANYWHERE, reported under a
declaration that was only ever a claim about the HOST. Row 3 is the control — the allowance
still works, and is worth two more checks than before because C1-C4 answer on a runner.

**The rule.** A gap is a claim about the host. A run that has already failed a case has found
something WRONG, and that outranks it. `gui-boot.test.sh` enforces it from the inside
(`host_gap_exit`); `run-tests.sh` enforces it from the outside on every suite, keyed on the
`  FAIL  ` line all nine suites print from the same `bad()` helper — so a suite that never
adopts the discipline cannot hide behind a declaration either. `H8`/`H9` in
`run-tests.test.sh` execute both halves of that on every run.

Rejected, and why, is in `b279e6e1`'s commit message: a receipt keyed to a last-answering run
(the harness never changed — the product did), a decided-check count (the dead suite decided
eight cases before its gate), and a third exit code (the same signal spelled twice).

## 6. The audit of the other declared gaps

Count of other declared host gaps in this repository: **ZERO**.

`grep -rn RUN_TESTS_DECLARED_GAPS .` returns three files: `run-tests.sh` (the definition),
`run-tests.test.sh` (its own scratch fixtures) and `.github/workflows/packaging-ci.yml:166`,
which declares exactly one suite — `gui-boot.test.sh`, the one repaired here. There is no
second declaration to audit.

Three adjacent things were checked and are not instances:

* **Suites that can exit 2 at all.** Only `gui-boot.test.sh` and `make-engine-asset.test.sh`.
  The latter's three exits are at lines 80-83, before its first case at line 145, so it has
  no verdict to conceal — and `run-tests.sh`'s new rule would catch it if it ever grew one.
  The remaining seven have no exit-2 site.
* **`gui-boot.test.sh`'s own line-level `gap()` declarations.** One: `RICHOS_SERVICE_BIN`. It
  is live rather than covering anything — the boot still prints the line it declares, visible
  in `healthy-boot.log` and printed with its reason in every run.
* **`app/ui/tests/contrast.js`'s "seven declared gaps"** are a different mechanism entirely
  (panels declared unwalked in `contrast-debt.json`) and already carry a both-directions
  staleness check of their own. Read only; not touched — another agent owns that file.

## 7. Runs

    bash app/scripts/gui-boot.test.sh   -> === gui-boot.test.sh: all 27 passed ===          exit 0
    bash app/scripts/run-tests.test.sh  -> === run-tests tests: all 9 passed ===            exit 0
    bash app/scripts/run-tests.sh       -> === app/scripts: all 9 suites passed — 178 checks === exit 0

`raw/J-…` is the same suite green on a local test-merge with main at `d5b718ae`, which landed
`startup_alert` while this work was in flight. That commit is why `B1a` is worth more than it
looks: `startup_alert` arms a NATIVE ALERT only when `activation::decide` returns `Regular`,
and giving the harness bundle an Info.plist makes activation's condition B hold where it used
to fail. Parent-pid is now the only condition keeping every boot this suite starts off the
screen — it cannot hold here (`gui_boot` runs the app as `( … ) &` under the suite's own
shell), and `B1a` asserts the accessory decision on every run rather than assuming it.

**No GUI bundle was launched interactively at any point.** `/usr/bin/open` is not used by
this harness by design; all 7 launches per run are accessory child processes with no Dock
icon, no window on screen and no focus taken, and `Z` reports 0 survivors on every run above.
