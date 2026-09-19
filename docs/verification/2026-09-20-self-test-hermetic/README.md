# The self-test that was green by hand and red in the build

Measured 2026-09-19/20 on the release Mac (Apple M4, 10 logical cores, 24 GiB, macOS 15.6),
against `main` at `62e5affd408937e601b84ff200a657b6ab266eb1` and the branch
`cc/zach-opus-buildtime3`.

The CEO, 2026-09-19 22:50Z:

> HOW MUCH FUCKING LONGER DO I HAVE TO FUCKING WAIT TO GET ALL THAT RETARDED FUCKSHIT GET
> FIXED PERMANENTLY????

Permanently means the self-test runs the same way everywhere, or it says why it cannot.

## What happened

`nightly-local.py build --no-host-screen`, run `20260919T222911Z-1dc9c794`, failed in
`gates/script-suites`:

```
=== run-tests.test.sh: 1 FAILED, 25 passed ===
  FAIL  H2 a declared gap with a reason is green
         the summary does not say how many ran: === app/scripts: 2 of 3 suites passed — 5 checks — 1 could not run on this host: gap.test.sh ===     gap.test.sh: no widget on this host
```

The same file, run by hand from the same commit minutes later: `all 26 passed`.

**The failure message quotes the answer it says is missing.** `2 of 3 suites passed` is in
the text the case printed while reporting that the text does not say how many ran. The
harness had done the right thing; the *assertion* reported otherwise. Confirmed byte for
byte: a local H2 run's last two lines are identical to the build's, including both em
dashes.

## The two things that made the verdict depend on who started the run

### One — the fixture inherited the caller's environment

Inside a build, `run-tests.test.sh` is itself a suite run BY `run-tests.sh`, so every
`run-tests.sh` copy it runs in its scratch box inherited whatever the outer run exported.

Measured on pristine `62e5affd`, one variable at a time, nothing else changed:

| exported | result |
|---|---|
| (baseline) | exit 0, 0 FAIL |
| `RUN_TESTS_NO_HOST_SCREEN=1` | **exit 1, 2 FAIL — S2, S4** |
| `RICHOS_GUI_HOST=richos-test-1` | exit 0, 0 FAIL |
| `RUN_TESTS_SKIP_UNCHANGED=1` | exit 0, 0 FAIL |
| `RUN_TESTS_JOBS=1` | exit 0, 0 FAIL |
| `RUN_TESTS_STATE=<the shared store>` | exit 0, 0 FAIL |
| `RUN_TESTS_DECLARED_GAPS=<the build's>` | exit 0, 0 FAIL |

`RUN_TESTS_NO_HOST_SCREEN` is the documented env form of the flag every build now passes.
Red on a tree where nothing is wrong — `environment-leak-red-then-green.log`:

```
=== PRISTINE run-tests.test.sh at 62e5affd, under the build's environment:
      FAIL  S2 without the flag nothing changes
      FAIL  S4 a host-screen suite that RAN writes a proof
    === run-tests.test.sh: 2 FAILED, 24 passed ===   exit=1
=== FIXED run-tests.test.sh on this branch, same environment:
    === run-tests tests: all 28 passed ===           exit=0
```

Every fixture now runs under `env -i` with an explicit list, through one `harness()`.

### Two — an assertion could report "no match" for text that was there

Every check in the file read `printf '%s' "$OUT" | grep -Fq NEEDLE`, under `pipefail`.
`grep -q` exits the instant it matches, so the writer on the left can be killed by SIGPIPE
AFTER the match was found; the pipeline reports failure and `!` reads it as absence.

Measured, same Mac, same shell:

| payload | iterations | false "no match" |
|---|---|---|
| needle on the LAST line, 1.4 KB (H2's exact bytes) | 400 | 0 |
| the same, under 12 CPU spinners | 4,000 | 0 |
| needle on the FIRST line, 400 KB | 400 | **400** (status 141) |
| S6's scanner over `gui-boot.test.sh` (84 KB, early match) | 200 | **14** |

The last row is the serious one: that pipeline decides which real suites get scanned at
all, so 7% of runs silently dropped the one suite that puts the app on the operator's
screen out of the scan. The same idiom sat in `run-tests.sh` itself, in the check that
stops a suite which FAILED a case from being filed as a tolerated host gap.

All of them are here-strings now: no second process, no pipe, and a grep ERROR (exit 2 and
up) is never reported as "the harness did not print it".

## What is NOT claimed

**The original H2 failure was not reproduced.** Three configurations, all green:

- `run-tests.test.sh` alone under the build's exact environment, driven through
  `nightly-local.py`'s own `Runner`, `TimestampedLog` and flags;
- all 14 suites pooled, same driver, same environment — `12 of 14 suites passed — 201
  checks — 2 NOT RUN (no screen)`;
- 4,400 hammered iterations of H2's exact captured bytes, idle and under saturation.

What is established is that the verdict came from the assertion's plumbing rather than from
what the harness did — the build's own output for that case is byte-identical to a passing
run's — and that the plumbing can no longer produce it. Both causes were removed; neither
was a guess about the other.

## The updater test, asked and answered

The brief asked whether `cargo test -p richos-user-update` takes a machine-global lock that
another checkout's test run could hold. **It does not, and here is what it was.**

- The session lock is `<home>/Applications/.richos-updater/session.lock`, and every test's
  `home()` is its own `tempfile::tempdir()`. Nothing is machine-global.
- Alone: 39 passed.
- **Two copies of the same compiled test binary at once, 8 test threads each: A green, B
  red** (`updater-two-concurrent-runs-B.log`) —
  `tests::installs_as_actual_owner_and_replays_exact_receipt`, `WouldBlock: "another RichOS
  session is running"`. A third observation, inside a gates run,
  `harmless_deny_acl_works_but_write_grant_refuses`; Rich's own,
  `collector_vetoes_shared_session_and_loaded_backup_and_cleans_partial_allocation`. A
  different test each time.
- **The same two concurrent processes with `--test-threads 1`: both green.**

So the failure needs several test threads INSIDE one process, and the second process only
supplies load. That points at the fork window in `probe()`
(`richos/app/crates/richos-user-update/src/lib.rs`): a child inherits every descriptor until
its `pre_exec` marks them close-on-exec, so a probe forked by one thread can hold another
thread's `session.lock` open, and `Lock::acquire_startup` gives up after 5 s. Load widens
that window. It is product code and not this brief's to change — raised separately rather
than patched here.

## Files

| | |
|---|---|
| `environment-leak-red-then-green.log` | the pristine file and the fixed one, same hostile environment |
| `updater-two-concurrent-runs-B.log` | the losing half of two concurrent updater runs |
| `gates-script-suites-after.log` | all 14 suites through `nightly-local.py`'s gates path, on this branch |
