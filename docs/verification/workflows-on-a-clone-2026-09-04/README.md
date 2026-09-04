# The five workflows, run outside the machine that wrote them

**Subject: `fc56c20`, plus the workflow changes this record ships with, on branch
`zach-opus-p10`.** Everything below was run. The transcripts in `raw/` are the runs.

Every workflow in `.github/workflows/` was switched off on 2026-09-01 over a billing
block, and `.github/workflows/README.md` recorded that they were *"never broken"* and that
going public would re-enable them *"unchanged"*. That was an inference, not a measurement —
a billing-blocked run produces no log to measure. This record replaces it with runs.

**All five were exercised as far as this machine reaches. Two of them were not fine.**

## The verdicts

| workflow | verdict | evidence | what only a runner can answer |
|---|---|---|---|
| `app-spine-ci` | **green** | `raw/spine.txt` — 696 tests over 30 binaries plus doctests, `--locked` accepted, 48 s | that it builds on Linux |
| `engine-self-verify` | **RED — 55 of 60 suites, and its timeout was impossible** | `raw/linux-engine.txt` — `ci-verify.sh` whole, exit 1, 65m40s | the x86 runner's speed against an arm64 container's |
| `ui-suite-ci` | **green, after one flake was found and fixed** | `raw/ui-suite.txt` — 20 suites, 400 checks, one allowed skip | that a fresh macOS runner image installs WebKit |
| `packaging-ci` | **RED — 3 of 7 suites on a runner** | `raw/packaging.txt`, `raw/gui-boot-real-home.txt` | nothing; one suite can never pass publicly |
| `windows-companion-ci` | **green as far as a Mac reaches** | `raw/windows-companion.txt` — restore, the `net8.0-windows` build and 26/26 core tests | the `doctor` smoke step, which needs Windows |

## How the clone was built, and the trap in building one

`zach-opus-p6` recorded the construction and its near-miss at
`docs/verification/publication-gate-host-independence-2026-09-04/`, and the near-miss is
the useful part: his first snapshot was built with `git add -A`, which respects
`.gitignore` and silently dropped a file that IS tracked, reddening three unrelated cases
for a reason that was about the proof rather than about the tree.

This record sidesteps that by not building a snapshot at all. It is a plain `git clone` of
the repository at `fc56c20` into a directory whose only entry is that clone, so the tracked
set is git's own answer rather than a reconstruction: **1360 paths in the clone, 1360 in the
source, asserted equal before anything ran.** `../richos-hq` does not resolve from it.

Two further separations, because a clone alone does not make a run host-independent:

- **A throwaway `$HOME`.** Every run below sets `HOME` to an empty scratch directory with
  nothing in it but the git identity a runner has to be given. That is what makes
  `os.homedir()` and `$HOME`-rooted lookups answer the way they answer on a runner rather
  than the way they answer here.
- **A `CARGO_HOME` holding what the runner image holds** for the packaging run: the
  toolchain and the registry cache, and no `cargo-tauri`. The `macos-latest` image manifest
  lists Cargo, Rust, Rustup, Clippy and Rustfmt, and no Tauri CLI.

For the engine, an `ubuntu:24.04` container — bash 5.2.21, git 2.43.0, python3 3.12.3 —
because that workflow's runner is Linux and this repository has been bitten by that
difference three times (`engine/docs/ci-portability-notes.md`).

### The container had to be corrected mid-proof, for the same class of reason

The first Linux pass ran as **root**, and `scripts/create-teammate-worktree.test.sh` case
C17 failed in it. C17 asserts a refusal when the ledger path cannot be written. As root,
`mkdir -p /nonexistent-dir` SUCCEEDS, so the path was writable, so no refusal came, so the
case failed — a verdict about the container, not about the tree. A GitHub `ubuntu-latest`
job runs as an unprivileged user. The pass was re-seated as `runner` (uid 1001) over a
fresh copy of the clone, and C17 passes. **The failing run is left described here rather
than deleted**, because "my proof was running as the wrong user" is the same shape of
defect as p6's `git add -A` and is worth more written down than tidied away.

## What could NOT be proven here, and must be watched on the first public run

Named so it is watched rather than discovered.

- **Nothing here ran on a GitHub runner.** No workflow in this repository may be described
  as CI-verified until a run of that workflow is green on a SHA somebody can name. That
  sentence is in four of the five files already and it is not weakened by anything below.
- **`app-spine-ci` has never compiled `richos-core` on Linux.** The clone proves it does not
  depend on the author's machine; the runner's question is untouched.
- **`ui-suite-ci` depends on a fresh `macos-latest` image** installing WebKit through `npm
  ci`'s postinstall into an empty cache. That was reproduced with a throwaway `$HOME`, which
  is close, and it is not the same as a fresh runner image. It also depends on whether that
  image's `cargo` lets `realbytes.js` take its 1.3 GB `src-tauri` build inside 45 minutes
  rather than the skip it is allowed; the run here took the skip, because the emulated PATH
  had no cargo.
- **`windows-companion-ci`'s last step runs the built executable**, and only Windows can. It
  was checked to be the only such step: restore, build and test all pass off Windows, and
  `dotnet richos-companion.dll doctor` on macOS aborts with a `FileLoadException`, which is
  the correct refusal.
- **The engine timeout is measured on Linux and scaled for the runner.** 65m40s on a 10-CPU
  arm64 container; `ubuntu-latest` is a 4-vCPU x86 VM. 150 is chosen for that gap and should
  be re-promised against the first real run.
- **`ui-suite-ci` is load-sensitive and one flake has been removed, not all of them.** A
  runner is a shared VM. A second red on a timing-shaped assertion should be reproduced
  under load before it is believed, and reproduced again before it is dismissed.

## What this proves, and what it does not

It proves the tree does not depend on the author's machine: not on the private `richos-hq`
sibling, not on his `$HOME`, not on anything installed there that a runner lacks.

**It does not prove any of these workflows work on a GitHub runner**, and no workflow here
may be described as CI-verified until a run of that workflow is green on a SHA somebody can
name. The section above names, one at a time, what each of them still owes a real runner.

## The engine timeout, which was the one number this had to produce

`timeout-minutes: 45` was set when `run-all-tests.sh` was 24 suites taking about seven
minutes on the dev Mac. It is 60 suites now, and `contract-integrity.test.sh` alone was
measured at 2977.9 s — 49.6 minutes — in
`docs/measurements/integrity-suite-cost-2026-09-04/`. **The job could not have finished
inside 45 minutes on any host.** The `--only` scoping that landed the same day made a
DEVELOPER's run fast; `run-all-tests.sh` invokes every suite with no arguments, so CI has
always paid the full pass and still does.

Measured here by running `scripts/ci-verify.sh` whole, on Linux, from the fresh clone —
the same command the workflow's last step runs, with no arguments. **Twice, on purpose:**

| | |
|---|---|
| loaded host (load average 9-58 on ten cores) | 4149 s (69.2 min) |
| quiet host (load average ~3) | **3940 s (65m40s)** |

**The two agree to 5%, and that is the useful part.** A suite whose cost is mutation
harnesses running one after another barely notices a busy machine, because it is not
competing for cores — it is spending its time in a single serial chain of process spawns. So
65m40s is not a lucky reading; it is what this job costs.

Where it goes: `guard-sealed-worktree.test.sh` is the largest single suite at roughly half an
hour, and `contract-integrity.test.sh` is 18 minutes. Between them, most of the run.

**Set to 150** — 2.3x the measured pass. The headroom is for the one thing nobody here can
measure: this ran on a 10-CPU arm64 container and `ubuntu-latest` is a 4-vCPU x86 VM, on a
serial spawn-bound suite that is therefore bound by single-core speed rather than by cores.
Actions is free on a public repository, so a generous ceiling costs nothing and a tight one
kills a green run at 95%. **Tighten it against the first real run** — a timeout is a promise
about the slowest acceptable run and should be re-promised against evidence.

One number worth keeping for whoever optimizes next: contract-integrity is **18.2 min on
Linux against 49.6 min on macOS**. The suite is spawn-bound and Linux spawns faster. A cost
measured on the dev Mac is not the cost CI pays, in either direction.

## The five red suites, and the reason the list was taken twice

`ci-verify.sh`, run whole and unmodified on the quiet Linux host: **exit 1, 55 of 60 suites.**

**The first red list was taken under load and could not be trusted.** A machine carrying
eleven agents at a load average up to 58 cannot tell a defect from a flake, and it proved it:
`reconcile-terminal-worktrees.test.sh` failed on a loaded Mac and passed 57/57 on a quiet
one, and `install-reconciler-schedule.test.sh` passed on macOS at both loads. So the whole
thing was re-run quiet before any of it was written down. Two suites changed classification
between the passes. These five survived both:

| suite | Linux | macOS | so it is |
|---|---|---|---|
| `contract-integrity.test.sh` | red | — | its own cases 54 and IN2, both below |
| `guard-worktree-isolation.test.sh` | red | red | a defect — its clause-7 mutation harness reports 3 of 7 properties not proven load-bearing, identically on both hosts |
| `provision-claude-md.test.sh` | red | red | a defect — 18 cases on Linux, the whole provisioning block |
| `reconcile-terminal-worktrees.test.sh` | red | green when quiet | red on the platform CI uses, and unstable even in its redness: C16 under load, C14 on the quiet pass |
| `install-reconciler-schedule.test.sh` | red | **green** | a divergence — S17-S20 shim `launchctl` and assert launchd behavior on a host with no launchd |

**None of these is caused by going public.** Two are red on the machine the engine is
developed on and a third is red on the platform CI uses. The flip does not create them; it
publishes them, on every commit, because that job had `on: push` with no path filter. Hence
the disabling, and hence the one-line statement in the file of what puts the triggers back.

The divergence is honest redness rather than a trip-wire. Section 7 of
`install-reconciler-schedule.test.sh` already carries a `uname -s` gate for its
live-installation cases; S17-S20 do not.

What S17-S20 should assert off Darwin is a question about what `install.sh` ought to DO
there, which belongs to whoever owns the reconciler schedule rather than to this branch.

### One defect that was Linux's, and is fixed

`contract-integrity.test.sh` used `sed -i ''` at four sites — the BSD in-place idiom. GNU
sed reads the empty string as the SCRIPT and the real script as a FILENAME, so under `set -e`
the suite ran 139 cases and **aborted, exit 2, with the MT and MC sections never reached**:
the model-capability-order and cost-ceiling layers, the engine's newest hard gates, unrun on
the only platform CI uses. All four arrived after the engine's one previous Linux run on
2026-08-29, when there were 24 suites.

Replaced with a `_sed_inplace` helper that edits through a temp file and writes back with
`cat >` rather than `mv`, so the target keeps its inode and mode — these files live in
sandboxes the suite hashes. MT (9 cases) and MC (9 cases) run and pass on both hosts after
it. `engine/docs/ci-portability-notes.md` records it as the fourth instance of the class,
beside `mktemp -t` and `BASH_CMDS`, with the lesson those two did not carry: **a portability
sweep is a property of a moment, not of a repository.**

### And two reds that are not defects, distinguished rather than lumped in

Both in `raw/red-suites-sorted.txt`.

`CL1.claim-gate-suite-passes` failed in one Linux pass and passed in the next, while
`guard-unresolved-claims.test.sh` passes standalone in 3 s. That is the load-related flake
the cost measurement already documents.

`IN2.inflight-notify-mutations` failed in **both** Linux passes, so it was not dismissed as
a flake — it was run standalone on each host instead. **macOS: 27/27 mutants killed. Linux:
26 killed, one SURVIVED — `abspath-not-realpath`.** That property can only be proven
load-bearing on a host where an absolute path and a resolved path differ, and on macOS they
do, because `/tmp` is a symlink to `/private/tmp`. On Linux `/tmp` is real, the mutant
changes nothing observable, and it survives. It is the same hazard
`engine/docs/ci-portability-notes.md` already lists for the `/var` → `/private/var`
physicalization, seen from the other side. Closing it means giving the fixture a symlinked
path so the distinction exists on Linux too, which is a change to that harness.

## The merge was rehearsed, because two green branches are not a green merge

`zach-opus-p8` and this branch both edit `engine/scripts/hooks/contract-integrity.test.sh` —
p8 grew the sandbox's registered-hook manifest, this branch added `_sed_inplace` and four
call sites. p8 reports 165/165 on its branch; this record reports its own Linux pass.
**Neither number describes the merged file.**

Rehearsed in a scratch clone, left uncommitted on purpose: no conflict, both changes present,
`bash -n` clean, and 54 cases green across every section either side touches — `manifest`
(10), `base` (11), `config` (14), `MT` (9), `MC` (9), `MC6` (1), each scoped run exiting 3 as
designed. `raw/merge-rehearsal.txt`. What it does not claim: it is not the full 165-case pass.
It is the intersection of the two changes, which is the question a merge raises.

## A finding that was fixed while this was being written, and is kept beside itself

`gui-boot.test.sh` case B2 was red at `fc56c20` on the machine that has everything — 17
passed, B2 failed, 154 s. The entity-registry land had added seven `[richos]` boot lines and
no accounting rule for any of them, and B2's whole design is that such a line turns it red
without anyone having remembered to extend it. It had been called environmental twice that
day; it was not. It was left with the author of those lines rather than guessed at, because
classifying a boot line means saying what it MEANS and a wrong classification is how a check
silently stops checking.

**Re-checked at `3de8e1f`: all 20 passed, exit 0, 62 s.** Both runs are in
`raw/gui-boot-real-home.txt`. The red one is kept: a finding that has been fixed should say
so beside itself rather than be quietly dropped.

## Everything found red

1. **`packaging-ci`, 3 of 7 suites on a runner.** `gui-boot.test.sh` needs the loro
   compiler, which is not tracked in this repository and lives in the private record
   repository, so no public runner can ever satisfy it; `updater-setup.test.sh` and
   `package-app.test.sh` case B2 both need the Tauri CLI, which the runner image does not
   ship. The workflow is disabled in the file, with the measurement and the conditions for
   re-enabling it in its own header.
2. **`engine-self-verify`: `ci-verify.sh` exits 1, 55 of 60 suites.** Five red, enumerated
   with their evidence in the section above. Not caused by going public.
3. **`gui-boot.test.sh` case B2 — found red, since fixed.** Red at `fc56c20` with the
   operator's real `$HOME`; green at `3de8e1f`. Both runs in `raw/gui-boot-real-home.txt`.
4. **A flake in `ui-suite-ci`, found before a runner found it.** `splash.js` check 23 failed
   twice in five runs with the check and the splash byte-identical throughout, the dark
   reading the same byte both times and the light reading not the same as itself. It had
   classified the strap's edge as a still element while sampling a fixed 30%-70% band of a
   bar whose fill is inside it — where the two samples either side of it are deliberately
   offset away from that leading edge. Reclassified, with the arithmetic, at `MOVING` in
   `app/ui/tests/splash.js`; six runs green after. No contrast floor changed: the edge is
   still asserted at 3:1 against the ground in both themes.
5. **`engine-self-verify`'s 45-minute timeout.** It was set when the suite it runs took
   about seven minutes. That suite is now dominated by one member measured at 49.6 minutes
   on macOS, so the timeout could not have been met on any host. Now 150, from a measured
   69-minute Linux pass.
6. **`contract-integrity.test.sh`'s `sed -i ''`**, which aborted the suite outright on Linux
   with the MT and MC sections never reached. Fixed; see the section above.
7. **Stale prose that a visitor would have read as fact**, each corrected where it stood:
   `.github/workflows/README.md` said nothing about the workflows needed to change;
   `packaging-ci.yml` said `package-app.sh` refuses on placeholder icons, which the icon
   verifier now passes; `windows-companion-ci.yml` said nothing on a Mac could compile the
   companion, which a Mac then did; `app/README.md` said there were three workflows and
   that the browser suites had no runner.
8. **Named, not fixed, because it is outside this branch's scope:** `app/README.md`'s icon
   section still says `icon.icns` and `icon.ico` do not exist and the app has no icon at any
   size. `app/scripts/lib/app_icons.py verify` passes against real artifacts, and the
   2026-09-04 pre-publication audit lists the same contradiction. That belongs with whoever
   holds the artwork item.
