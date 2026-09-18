# The front-door suite must not fail the build it cannot run in

Written by Echo, 2026-09-18, beside
[`2026-09-18-front-door-what-the-harness-was-measuring-instead.md`](2026-09-18-front-door-what-the-harness-was-measuring-instead.md),
which is the record of the suite this one is about.

**What stopped.** The nightly build of candidate .10 could not be made. `front-door.test.sh`
landed on main earlier the same day (`4eeb5143`), `run-tests.sh` discovered it from disk, ran it
with no arguments, and the suite answered the only way it then could — exit 64, "REFUSED:
`--bundle` must name a RichOS.app …". The runner reads 64 as a failed suite, so the whole gate
stage went red and `nightly-local.py` stopped:

```
~/.richos-nightly/logs/20260918T171138Z-c26afbc2.log:1752   REFUSED: --bundle must name a RichOS.app …
~/.richos-nightly/logs/20260918T171138Z-c26afbc2.log:2571   === app/scripts: 1 of 13 suite(s) FAILED: front-door.test.sh ===
                                                            nightly: bash failed (exit 1); see the run log
```

Nothing was wrong with the product, and nothing was wrong with the suite. A build host has no
app to drive. That is a state the harness already has a word for, and the suite was not using it.

---

## What changed, in three sentences

1. `front-door.test.sh` now reports **exit 2 — "this host cannot answer"** when the invocation
   named neither `--bundle` nor `--release`, decided before anything is created, launched or
   synthesized. Exit **64** is unchanged for a bundle that *was* named and is wrong.
2. `nightly-local.py` **declares that gap by name, with a reason**, at the one step that needs
   it — the mechanism `run-tests.sh` already required and `packaging-ci.yml` already used for
   `gui-boot.test.sh`. Exit 2 is not treated as a skip anywhere, and no second inventory exists.
3. `packaging-ci.yml` gets the same declaration, because it is the other caller of the runner and
   a public runner is the one host that can never answer this suite.

**Why 2 and 64 are different answers.** A gap is a claim about the HOST: *this machine lacks
something, nothing is wrong*. An argument that names a thing which is not a RichOS.app is an
answer about the argument, and no declaration may tolerate it. Collapsing the two would have made
`--bundle /some/typo` tolerable inside a build, which is precisely the shape of defect the runner's
header spends seventy lines refusing.

---

## The four measurements

All on this Mac, 2026-09-18, on `cc/echo-opus-suitegap1` rebased onto main `571c08b6`. The
runner was given the environment the nightly's gate stage gives it
(`nightly-local.py` `local_environment()`/`runtime()`): explicit `PATH`, `RICHOS_RUNTIME_DIR`
pointing at the verified runtime build, no credentials.

### 1. The suite alone

```
$ bash scripts/front-door.test.sh                        -> exit 2   (9 lines, no process)
$ bash scripts/front-door.test.sh --bundle /tmp/nope.app -> exit 64
$ pgrep -fl richos-tauri                                 -> nothing, after both
```

The gapping run prints no `  FAIL  ` line, so `run-tests.sh`'s rule that a failed case outranks a
gap (`run-tests.sh:156-163`) still reads this as a gap rather than as cover.

### 2. Undeclared, the runner is RED — and the gap is the only thing it is red about

```
$ env -u RUN_TESTS_DECLARED_GAPS bash scripts/run-tests.sh      (17:30:18Z -> 17:38:00Z, 462 s)
exit 2
=== app/scripts: 1 suite(s) reported that this host cannot answer, and nobody declared them: front-door.test.sh ===
```

### 3. Declared, the runner is GREEN and says how big its own hole is

```
$ RUN_TESTS_DECLARED_GAPS="<the string nightly-local.py states>" bash scripts/run-tests.sh
                                                                (17:38:00Z -> 17:44:52Z, 412 s)
exit 0
=== app/scripts: 12 of 13 suites passed — 214 checks — 1 could not run on this host: front-door.test.sh ===
    front-door.test.sh: this suite drives the SHIPPED window — it needs a built RichOS.app, which
    THIS build has not produced yet at the gate stage, and a person's unlocked screen to put it on …
```

The declaration used is read out of `nightly-local.py` itself (`DECLARED_GAPS`), not retyped, so
this proof cannot drift from the value the build passes.

### 4. Declared AND answering is RED — measured with the real suite, not a stand-in

`run-tests.sh` hands its suites no arguments, so the real `app/scripts` directory can never make
`front-door.test.sh` answer. The case was therefore run in a sandbox holding the REAL
`run-tests.sh` and a `front-door.test.sh` that execs the REAL suite with a real release:

```
$ RUN_TESTS_DECLARED_GAPS="<same string>" bash <box>/run-tests.sh
--- front-door.test.sh
        bundle 1.2.0-nightly.20260918.3, built from 794eac7f3dfbab75567f3aa6cf723da289a7ea99
  PASS  C0  the bundle boots and puts exactly one window on screen  (pid 49301)
  …
  PASS  C4  Escape closed the settings menu  (Techy Mode 95x20 -> absent)
  PASS  Z   pid 49301 is gone; nothing this run started is still running
  7 passed, 0 failed
exit 2
=== app/scripts: a host gap is declared for front-door.test.sh, and that suite answered on this host ===
```

The same case with a stub in place of the suite gives the same refusal, which is the runner's rule
rather than the suite's. The app instance this put on screen is gone: the suite's own case Z names
pid **49301** and `pgrep -fl richos-tauri` returned nothing afterwards (CEO §54 addendum 4).

---

## Three things that are true and are not improvements

**A gap over this suite is a gap over silence, and that is a property of the suite.**
`run-tests.sh`'s header is explicit that a gapping suite ought to have host-independent cases left
to fail — `gui-boot.test.sh` runs its C1-C5 before its host gate for exactly that reason. Every
case in `front-door.test.sh` needs a window. So under this declaration the suite contributes
NOTHING to a build. That is said in its header rather than papered over; it is a by-hand and
walk-time instrument, and it never was a build-time check.

**The "an allowance cannot outlive its reason" protection does not bite here.** That rule fires
when a declared suite starts answering. Since the runner passes no arguments, this suite can never
answer inside a build for any reason — so the declaration is permanent by construction, and
measurement 4 had to be built out-of-band to exercise the rule at all. Anyone tempted to rely on
staleness-detection for this entry should read that sentence twice.

**Running the runner by hand needs `RICHOS_RUNTIME_DIR`.** The first pass of measurement 2, at
17:28Z, reported `make-engine-asset tests: 4 FAILED, 15 passed` — L12/L13/L14 with *"REFUSING —
engine 1.2.0 requires `--runtime-dir` with a verified runtime build"* and L19 *"no delivered
Node"*. That is the operator's environment, not a defect: the nightly sets
`RICHOS_RUNTIME_DIR` from its verified runtime cache before the gates, and with it set all four
pass. Every number above was taken with it set.

---

## What this slice does NOT include

* **The nightly build itself.** `nightly-local.py` builds ORIGIN/main and only origin/main —
  `checkout()` is `git fetch origin main` then `git rev-parse FETCH_HEAD` (`:209-210`), and the CLI
  has no ref argument (`:442-448`). So the build cannot be run from this branch; it is Rich's to
  run once these commits are on main. The three other commands of the gate stage were run on this
  branch in the same environment, so that the stage which failed is green here end to end:

  ```
  cargo test --locked --manifest-path richos/app/Cargo.toml -p richos-core        exit 0  (1314 tests)
  cargo test --locked --manifest-path richos/app/crates/richos-user-update/…      exit 0  (41 tests)
  bash richos/engine/scripts/named-persons.sh --tree --repo <this worktree>       exit 0
  bash richos/app/scripts/run-tests.sh  (declared)                                exit 0  (214 checks)
  ```
* **The suite's own checks**, which were settled earlier today in the record next to this one.
* **User-facing text or color**, so the WCAG AA floor has nothing to bind in this slice: every
  string added here is terminal output from a build harness, in the caller's own terminal palette.
