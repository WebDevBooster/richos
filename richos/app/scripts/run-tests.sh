#!/usr/bin/env bash
#
# run-tests.sh — every *.test.sh under app/scripts, discovered from disk.
#
# WHY THE INVENTORY IS NOT TYPED. This repository has now shipped the same defect
# five times: a hand-written list of things to check that drifted from the things
# that existed, under a reassuring fraction. "13/13 guards", "18/18 suites", an
# install.sh whose HOOK_FILES had drifted from its registration, a `run.js` that
# reported "all 4 suites passed" while running none of `steering.js`'s 24 checks.
# `engine/scripts/run-all-tests.sh` and `app/ui/tests/run.js` both ended up here.
# So: add a suite next to this file and it runs. There is no second place to edit.
#
# ZERO SUITES IS EXIT 2, not "all 0 suites passed". An empty inventory reporting
# green is how an unreachable workflow looked healthy for months.
#
# macOS ONLY, and it says so rather than skipping. Every suite under this directory
# is about codesign, keychains and TCC. On Linux they would not fail; they would be
# meaningless, and a green run of meaningless suites is worse than no run.
#
# =======================================================================================
# EXIT 2 FROM A SUITE MEANS "THIS HOST CANNOT ANSWER", AND IT USED TO BE READ AS "FAILED"
# =======================================================================================
#
# `gui-boot.test.sh` has said, in its own words, since it was written:
#
#     That is a fact about THIS MACHINE, not a verdict about the code.
#     ... exit 2
#
# and this harness had no notion of such a host, so it counted that suite as a failure.
# Loro is delivered by the public engine. Missing GUI capabilities can still
# be declared as host gaps; a missing public component is a product failure.
#
# THE DANGEROUS VERSION OF THIS FIX IS THE OBVIOUS ONE — treat exit 2 as a skip and move
# on. That is how a suite stops running and nobody finds out, which is the defect this
# repository has now paid for five times and the exact reason the workflow's author
# refused to patch it in a hurry. So the allowance is not "exit 2 is fine". It is:
#
#   * a gap is only tolerated if the CALLER DECLARED IT, by suite name, WITH A REASON —
#     a bare name declares nothing, exactly as `gui-boot.test.sh`'s own A4 case requires
#     of the gaps it accounts for;
#   * a suite that gaps WITHOUT a declaration is red — so a NEW suite that starts
#     reporting "this host cannot answer" stops the build on the first run;
#   * a declaration whose suite DID answer is red — so an allowance cannot outlive the
#     condition it was written for and quietly hide a later gap;
#   * a gapping suite that FAILED A CASE is not gapping — see below;
#   * the summary line never says "all N suites passed" while a gap exists. It says how
#     many ran, how many could not, and which.
#
# =======================================================================================
# THE HOLE THE FOUR CONDITIONS ABOVE DID NOT COVER, FOUND 2026-09-10
# =======================================================================================
#
# Every one of them asks whether the DECLARATION is honest. None asks whether the SUITE
# still works. Those are different questions, and on 2026-09-10 the difference cost nine
# days: `gui-boot.test.sh` had been dead on every host since `01e9b8d8` (2026-09-08) —
# `update_startup::prepare` began reading an `Info.plist` the boot fixture had never
# written, so the app exited on its first line and B1/B2 went red while B3-B8 went green
# over the same dead boot. At that time the compiler was not publicly delivered.
# The declared host gap was the only thing standing between that death and
# somebody noticing, because the one machine that would have reported it is the operator's
# own, and CI — the machine that runs this every day — was reading a legitimate host gap.
#
#     "THIS HOST CANNOT ANSWER" AND "THIS SUITE CANNOT ANSWER ANYWHERE" ARE DIFFERENT
#     STATES, AND UNDER A DECLARATION THEY LOOKED IDENTICAL.
#
# So exit 2 is now read for what it claims. A gap is a claim about the HOST: it says this
# machine lacks something, not that anything is wrong. A suite that has already PRINTED A
# FAILED CASE has found something wrong, and a claim about the host cannot outrank it. Such
# a suite is counted as FAILED here no matter what any declaration says.
#
# It is enforced on the suite's own output rather than on its exit code, and that is
# deliberate: `gui-boot.test.sh` also refuses to exit 2 over a failure from the inside
# (`host_gap_exit`), but a suite that never adopts that discipline — or a new one written
# next year by somebody who never reads this file — must not be able to hide behind a
# declaration either. All nine suites in this directory print `  FAIL  <case>` from the
# same two-line `bad()` helper, so the marker is a repo-wide fact and not a convention this
# file hopes for.
#
# THE OTHER HALF OF THE REPAIR IS NOT HERE, and it belongs beside this note: a gapping
# suite must have something left to fail. `gui-boot.test.sh` now runs its C1-C5 cases —
# which hold its own fixture to what the product demands of a bundle — BEFORE its host
# gate, so the runner that can never boot anything still decides whether the thing it would
# have booted is still valid. A gap over a suite with no host-independent cases at all is
# still a gap over silence; that is a property of the suite, and each suite owns it.
#
# The failure modes therefore all point at RED, and the tolerated set can only ever get
# smaller without somebody editing a declaration. Drift makes the unaccounted list longer.
#
#   RUN_TESTS_DECLARED_GAPS="gui-boot.test.sh: <why this host cannot answer>"
#
# one declaration per line, `<suite>: <reason>`. Unset — the default, and what an operator
# on a complete machine gets — means no gap is tolerated at all.
#
# =======================================================================================
# THE SUITES RUN CONCURRENTLY, AND THE OUTPUT DOES NOT
# =======================================================================================
#
# MEASURED, 2026-09-19, run `20260919T180454Z-ac11d13e`: this harness was 522.4 s of a
# 950.2 s nightly build — 55.0% of everything, with fourteen independent suites run one
# after another. Three of them are 89% of that: `gui-boot.test.sh` 161.6 s,
# `make-release.test.sh` 157.5 s, `make-engine-asset.test.sh` 128.7 s. Nothing about any
# of them needed the other thirteen to have finished.
#
# INDEPENDENCE IS A PROPERTY THAT WAS CHECKED, NOT ASSUMED. What two suites could collide
# over, and what each one actually does:
#
#   scratch directories — every one of the fourteen makes its own `mktemp -d`, and none
#       writes to a fixed path under `$TMPDIR`. Verified by reading every `mktemp` call
#       site in this directory.
#   the operator's HOME — nothing writes under `$HOME`. `make-release.test.sh` READS
#       `$RICHOS_NAMED_PERSONS_FILE` (and supplies its own fixture list instead);
#       `signing-setup.test.sh` and `package-app.test.sh` READ the keychain inventory
#       through `security find-identity` and each has a case Z proving it left the real
#       keychain untouched. Concurrent readers of a keychain are safe; there are no
#       concurrent writers, because both suites shim `security` for every write.
#   TCP ports — exactly one suite binds one: `make-release.test.sh`, override
#       `RICHOS_RELEASE_TEST_PORT`. No second suite listens on anything, so no two of the
#       fourteen can collide. Two SIMULTANEOUS run-tests.sh runs on one host DID, for as
#       long as that port was a fixed 8975 — and this Mac holds a worktree per engineer
#       plus the nightly's own checkout, so two simultaneous runs is the normal state of
#       the machine rather than an edge case. Since 2026-09-20 the port is derived from
#       the checkout's path (`lib/worktree-resource.sh`): stable for one worktree,
#       distinct between siblings. The proof store below is derived the same way.
#   cargo target directories — `gui-boot.test.sh` and `updater-setup.test.sh` both build
#       under `app/src-tauri/target`; `voice-component.test.sh` builds under `app/target`
#       (a DETACHED nested workspace, app/Cargo.toml:5-8, so those are two different
#       directories). Cargo takes an exclusive file lock on a target directory and the
#       second builder WAITS rather than corrupting anything — so this is a throughput
#       question, never a correctness one. It is the reason the pool is bounded well below
#       fourteen: three suites that each fan out to every core do not get faster by being
#       started at the same instant.
#   the repository — no suite writes into the checkout. `make-engine-asset.test.sh` builds
#       the real archive into its own scratch directory; `nightly.py`'s own guard
#       (`git status --porcelain` after the build) would refuse the release if any of this
#       dirtied the tree.
#
# THE POOL SIZE IS MEASURED, AND THE OBVIOUS ANSWER IS WRONG. The first version of the
# default here computed `min(<logical cores>, <GiB of RAM>/4)` = 6 on this Mac, which is a
# perfectly reasonable derivation and 61 seconds slower than the truth. The curve, same
# tree, same twelve suites, same machine (Apple M4, 10 logical cores, 24 GiB), 2026-09-19:
#
#     pool  1  341 s      <- serial, the "before"
#     pool  2  223 s
#     pool  3  167 s      <- the optimum, and the default
#     pool  4  183 s
#     pool  6  228 s
#     pool 10  236 s
#
# MORE CONCURRENCY IS SLOWER PAST THREE, and the per-suite table says why: two suites
# dominate the run and contend with each other for disk and cores, so their own durations
# INFLATE as the pool grows — `make-release.test.sh` alone goes 131 s -> 167 s -> 228 s ->
# 236 s across that curve, and the wall clock is just whichever of the two finishes last.
# The pool's job is therefore to get the other ten suites out of the heavies' way, not to
# start everything at once. `RUN_TESTS_JOBS` or `--jobs N` overrides it.
#
# OUTPUT IS CAPTURED WHOLE AND PRINTED IN THE DISCOVERY ORDER — the same order, line for
# line, that a serial run produced. Fourteen concurrent writers to one terminal is an
# unreadable log, and an unreadable log is how a failure gets skimmed past. Each suite's
# output goes to its own file and is printed, entire, the moment every suite ahead of it
# has been printed. Nothing is summarized, elided or reordered.
#
# =======================================================================================
# THE TWO HEAVIEST SUITES ARE SKIPPED WHEN THEIR INPUTS HAVE NOT CHANGED
# =======================================================================================
#
# `RUN_TESTS_SKIP_UNCHANGED=1` (never the default, and never set for a `release`) lets
# `make-release.test.sh` and `make-engine-asset.test.sh` — 286 s between them, 30% of a
# whole build — be skipped when nothing they read has changed since the last run that
# proved them green ON THIS HOST.
#
# A SKIP THAT CANNOT NAME WHAT IT COMPARED IS THE DEFECT THIS FILE'S HEADER IS ABOUT. So:
#
#   * the digest is over the INPUTS the suite declares IN ITSELF, on a
#     `# run-tests: inputs <paths>` line — never a table in this file, for the same reason
#     the inventory is not typed. The declaration is a deliberate SUPERSET of what the
#     suite reads: a superset re-runs a suite that did not need re-running, which is the
#     harmless direction;
#     `# run-tests: covers <files>` separately claims exact-file behavior for
#     proof-for.sh, not this digest. Write `covers -` when there is no claim.
#   * it is `git ls-files -s` over those paths (git's own content hashes, exact and
#     instant) AND a `git status --porcelain --untracked-files=all` over the same paths
#     that must be EMPTY. A modified or untracked input is not hashed, it is a change, so
#     an edit nobody committed can never be skipped over;
#   * a suite with no enumerated inputs is never skippable. Adding a heavy suite gets you
#     a suite that runs every time, not a silent skip;
#   * the proof is per-suite, in `$RUN_TESTS_STATE` (default
#     `~/.richos-nightly/suite-proofs/<worktree-id>/`, one directory per checkout — see
#     `lib/worktree-resource.sh` for why nothing here keeps a fixed name), and names the
#     digest, the run id and the commit it was proven on. It is written only after the
#     suite ran and was GREEN;
#   * every skip is printed, named in the summary, and written into `--results-out`, from
#     where `nightly-local.py` puts it in the candidate's `build-info.json`. A candidate
#     can never quietly claim a suite it did not run.
#
# =======================================================================================
# `--no-host-screen`: A BUILD THAT PUTS NOTHING ON THE OPERATOR'S SCREEN
# =======================================================================================
#
# `gui-boot.test.sh` boots the real app, on the real screen, for ~162 s of every build.
# On a Mac somebody is working on, that is not a test, it is an interruption — the CEO's
# words, 2026-09-19: *"So, every engineer will keep opening the app making me unable to do
# anything here or WHAT???"*
#
# `--no-host-screen` (or `RUN_TESTS_NO_HOST_SCREEN=1`) promises that this run opens no
# window on this machine, and it enforces the promise rather than documenting it:
#
#   * A HOST-SCREEN SUITE IS ONE THAT SOURCES `lib/gui-launch.sh` — the one library in
#     this repository that boots the shipped binary — or that declares itself with
#     `# run-tests: host-screen`. Structural, not a guess: `gui-boot.test.sh` and
#     `front-door.test.sh` are what that finds today.
#   * With `RICHOS_GUI_HOST=<vm-name>`, such a suite is run in that guest instead, through
#     `scripts/testvm/run-suite.sh`. If the caller named a VM and no runner is there, the
#     run REFUSES. It never falls back to the host's screen, and it never quietly
#     downgrades a named VM to "not run" — a caller who asked for the proof gets the proof
#     or an error.
#   * Without one, the suite is recorded `NOT RUN (no screen)`, the candidate is still
#     built and still walkable, and `nightly-local.py publish` REFUSES that candidate
#     until `--gui-proof <path>` names a gui-boot result produced later against the same
#     commit. `--proof-out <path>` is how that file is made.
#   * A suite that could put a window on a screen and is neither classified nor declared
#     inert is caught by `run-tests.test.sh` case S3, which scans the REAL inventory. A
#     new suite that opens a window without saying so turns that case red on the day it
#     lands, rather than turning up on the operator's screen.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Standalone fixture copies have no engine; a complete checkout uses its shared budget.
WORKER_TOOL="$DIR/../../engine/scripts/lib/worker_tokens.py"
if [ -z "${RICHOS_WORKER_TOKENS:-}" ] && [ -f "$WORKER_TOOL" ]; then
  exec python3 "$WORKER_TOOL" machine -- bash "${BASH_SOURCE[0]}" "$@"
fi

JOBS=""
ONLY=""
PROOF_OUT=""
RESULTS_OUT=""
NO_HOST_SCREEN="${RUN_TESTS_NO_HOST_SCREEN:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs)            JOBS="${2:-}"; shift 2 ;;
    --only)            ONLY="$ONLY ${2:-}"; shift 2 ;;
    --no-host-screen)  NO_HOST_SCREEN=1; shift ;;
    --proof-out)       PROOF_OUT="${2:-}"; shift 2 ;;
    --results-out)     RESULTS_OUT="${2:-}"; shift 2 ;;
    *)
      echo "run-tests.sh: unknown argument '$1'." >&2
      echo "              [--jobs N] [--only <suite>]... [--no-host-screen]" >&2
      echo "              [--proof-out <path>] [--results-out <path>]" >&2
      exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "run-tests.sh: these suites exercise codesign, the keychain and TCC — macOS only." >&2
  echo "              (uname -s reports $(uname -s).) Refusing to report a result." >&2
  exit 3
fi

ALL=()
while IFS= read -r t; do [ -n "$t" ] && ALL+=("$t"); done <<EOF
$(find "$DIR" -maxdepth 1 -type f -name '*.test.sh' | LC_ALL=C sort)
EOF

if [ "${#ALL[@]}" -eq 0 ]; then
  echo "run-tests.sh: found NO *.test.sh under $DIR — refusing to report green over an empty inventory." >&2
  exit 2
fi

# `--only` names suites by basename. A name that matches nothing is REFUSED rather than
# silently dropped: "I asked for a suite and got a green run of nothing" is the same
# failure this file's header is about.
SUITES=()
if [ -n "$ONLY" ]; then
  for want in $ONLY; do
    found=""
    for t in "${ALL[@]}"; do
      if [ "$(basename "$t")" = "$want" ]; then SUITES+=("$t"); found=1; break; fi
    done
    if [ -z "$found" ]; then
      echo "run-tests.sh: --only $want names no suite under $DIR." >&2
      exit 2
    fi
  done
else
  SUITES=("${ALL[@]}")
fi

# The declarations, read once, before anything runs — a malformed one should stop the run
# rather than be discovered after fifteen minutes of runner time.
DECLARED_SUITE=()
DECLARED_WHY=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  d_suite="${line%%:*}"
  d_why="${line#*:}"
  # Trim, without an external process.
  d_suite="${d_suite#"${d_suite%%[![:space:]]*}"}"; d_suite="${d_suite%"${d_suite##*[![:space:]]}"}"
  d_why="${d_why#"${d_why%%[![:space:]]*}"}";       d_why="${d_why%"${d_why##*[![:space:]]}"}"
  if [ "$d_suite" = "$line" ] || [ -z "$d_why" ]; then
    echo "run-tests.sh: RUN_TESTS_DECLARED_GAPS names '$d_suite' with no reason after a colon." >&2
    echo "              A bare name declares nothing. Write '<suite>: <why this host cannot answer>'." >&2
    exit 2
  fi
  DECLARED_SUITE+=("$d_suite")
  DECLARED_WHY+=("$d_why")
done <<EOF
${RUN_TESTS_DECLARED_GAPS:-}
EOF

# ---------------------------------------------------------------------------------------
# The pool size. See the header: the memory bound and the core bound, smaller wins.
# ---------------------------------------------------------------------------------------
if [ -z "$JOBS" ]; then
  JOBS="${RUN_TESTS_JOBS:-}"
fi
if [ -z "$JOBS" ]; then
  # MEASURED, not derived. The first version of this line computed
  # `min(cores, GiB/4)` = 6 on this Mac and was WRONG BY 61 SECONDS; see the header for
  # the curve. A third of the cores, floored at two, is the shape the measurement has:
  # enough slots to keep the light suites off the two heavy ones, not enough to make the
  # heavy ones fight. On this Mac (10 logical cores) that is 3, which is the measured
  # optimum; the memory bound is kept as a second ceiling for a host with many cores and
  # little RAM, where three concurrent cargo builds would swap.
  _cores="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
  _gib=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 ))
  JOBS=$(( _cores / 3 ))
  [ "$JOBS" -ge 2 ] || JOBS=2
  _memcap=$(( _gib / 4 ))
  [ "$_memcap" -ge 1 ] || _memcap=1
  [ "$JOBS" -le "$_memcap" ] || JOBS="$_memcap"
fi
case "$JOBS" in
  ''|*[!0-9]*) echo "run-tests.sh: --jobs/RUN_TESTS_JOBS must be a positive integer, got '$JOBS'." >&2; exit 2 ;;
esac
[ "$JOBS" -ge 1 ] || JOBS=1

# ---------------------------------------------------------------------------------------
# Scratch, and the promise that nothing this run started outlives it (CEO ruling §54).
# ---------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX")" || {
  echo "run-tests.sh: cannot create a scratch directory." >&2; exit 2; }
PIDS=()

kill_tree() {  # every descendant first, then the process itself
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
}

cleanup() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && kill_tree "$pid"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# ---------------------------------------------------------------------------------------
# Classification: which suites put a window on a screen.
# ---------------------------------------------------------------------------------------
is_host_screen() {  # $1 = full path to a suite
  # IT MUST BE SOURCED, NOT MERELY MENTIONED, and the difference is not pedantry: the first
  # version of this line matched the library's NAME anywhere in the file, and on the first
  # full run it classified `run-tests.test.sh` as a suite that boots the app — because that
  # file's own S1 case writes a FIXTURE containing the string `. "$DIR/lib/gui-launch.sh"`.
  # The harness's own self-test was recorded NOT RUN (no screen), under a reason that reads
  # perfectly legitimately, which is exactly the shape of "a suite stopped running and
  # nobody found out" this file counts five instances of. Matching at COMMAND POSITION —
  # `.` or `source` as the first word of a line — separates sourcing the library from
  # writing its name inside a quoted string or a comment.
  grep -qE '^[[:space:]]*(\.|source)[[:space:]]+[^[:space:]]*lib/gui-launch\.sh' "$1" && return 0
  grep -q '^# run-tests: host-screen' "$1" && return 0
  return 1
}

# ---------------------------------------------------------------------------------------
# Skip-when-unchanged. The input sets are a deliberate SUPERSET; see the header.
# ---------------------------------------------------------------------------------------
SKIP_UNCHANGED="${RUN_TESTS_SKIP_UNCHANGED:-}"
RUN_ID="${RICHOS_NIGHTLY_RUN_ID:-manual}"
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
# ONE DIRECTORY PER CHECKOUT, derived from the checkout's path — never one shared store.
# A proof says "this suite was green over these inputs, in run <id>, at commit <sha>"; a
# store shared by every worktree on this Mac hands one checkout's proof to another, and a
# skip is the one outcome that must never rest on something this tree did not prove. The
# derivation is `lib/worktree-resource.sh`, which is the only place any shared name in this
# directory is derived. An explicit RUN_TESTS_STATE still wins outright.
#
# A MISSING LIBRARY REFUSES RATHER THAN FALLING BACK. The fallback would be a fixed path —
# exactly the shared store this replaces — and it would be taken silently, on a machine
# where nobody is looking. Every fixture that copies this harness copies the library with
# it, for the same reason.
if [ ! -f "$DIR/lib/worktree-resource.sh" ]; then
  echo "run-tests.sh: $DIR/lib/worktree-resource.sh is missing, and every shared name this" >&2
  echo "              harness uses is derived there, one per checkout. A fixed fallback" >&2
  echo "              would put two checkouts back on one directory without saying so." >&2
  exit 2
fi
. "$DIR/lib/worktree-resource.sh"
STATE="${RUN_TESTS_STATE:-$(worktree_dir "$(worktree_root "$DIR")" "$HOME/.richos-nightly/suite-proofs")}"
HEAD_SHA="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------------------
# A FAILING TEST IS NAMED, AND ITS RESULT FILES ARE KEPT (2026-09-25).
# ---------------------------------------------------------------------------------------
# A proof run's `native-android-app` said "133 tests completed, 1 failed" and named no test;
# the Gradle report that did was in the checkout's build cache, and `native-android-ui`, the
# next suite, replaced it with its own passing report before anyone read it. The failing test
# could not be named. So every suite gets a results folder of its OWN, exported to it as
# RICHOS_TEST_RESULTS_DIR: `bin/randroid test` and the iOS suites copy (or move) their per-test
# results there the moment a test run ends (lib/test_results.py). A suite that fails is named
# here with the tests that failed in it, read from those files, else from its log, else its own
# `  FAIL  ` lines; its folder is kept and its path printed. A suite that passes leaves nothing.
#
# Where: under RICHOS_TEST_RESULTS_ROOT when the caller names one (proof-run.py names a folder in
# the run's own log directory); otherwise in this run's scratch, and a FAILED suite's folder is
# then moved to a per-checkout store (RUN_TESTS_RESULTS_STATE overrides it), which keeps the last
# KEEP_FAILED_RESULTS and deletes older ones (CEO ruling §54: bounded by construction).
KEEPER="$DIR/lib/test_results.py"
if [ ! -f "$KEEPER" ]; then
  echo "run-tests.sh: $KEEPER is missing, and it is what names a failing test. Without it a" >&2
  echo "              failure would be reported as a count with no name, the defect it exists for." >&2
  exit 2
fi
RESULTS_ROOT="${RICHOS_TEST_RESULTS_ROOT:-}"
RESULTS_KEEP=""
KEEP_FAILED_RESULTS=10
if [ -z "$RESULTS_ROOT" ]; then
  RESULTS_ROOT="$WORK/results"
  if [ -n "${RUN_TESTS_RESULTS_STATE:-}" ]; then
    RESULTS_KEEP="$RUN_TESTS_RESULTS_STATE"
  elif [ -d /Volumes/E1TB ] && [ "$(stat -f %d /Volumes/E1TB)" != "$(stat -f %d /Volumes)" ]; then
    RESULTS_KEEP="$(worktree_dir "$(worktree_root "$DIR")" /Volumes/E1TB/state/richos/test-results)"
  else
    RESULTS_KEEP="$(worktree_dir "$(worktree_root "$DIR")" "$HOME/.richos-nightly/test-results")"
  fi
fi
FAILING=()

results_dir() { printf '%s/%s\n' "$RESULTS_ROOT" "${REL[$1]%.test.sh}"; }  # $1 = suite index

# The failing tests of suite $1, one line each: from its result files, else its log, else the
# suite's own `  FAIL  ` lines. Its results folder is kept (and moved to the store when this
# run's root is scratch); FAILING[$1] remembers the names for the summary and --results-out.
name_failures() {
  local idx="$1" rel="${REL[$1]}" dir found dest old n count
  dir="$(results_dir "$idx")"
  local paths=()
  [ -d "$dir" ] && paths+=("$dir")
  found="$(python3 "$KEEPER" names --log "$WORK/$idx.out" ${paths[@]+"${paths[@]}"} 2>&1 \
           | sed -n 's/^  FAILED TEST  //p')"
  if [ -z "$found" ]; then
    found="$(sed -n 's/^  FAIL  //p' "$WORK/$idx.out" 2>/dev/null | head -20)"
  fi
  FAILING[idx]="$found"
  if [ -n "$found" ]; then
    echo "    failed in $rel:"
    printf '%s\n' "$found" | sed 's/^/      /'
  else
    echo "    $rel failed and named nothing: no result file, no test log line and no FAIL line of its own"
  fi
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    if [ -n "$RESULTS_KEEP" ]; then
      dest="$RESULTS_KEEP/$(date -u +%Y%m%dT%H%M%SZ)-${rel%.test.sh}-$$"
      if mkdir -p "$RESULTS_KEEP" && mv "$dir" "$dest"; then
        echo "    per-test results kept at $dest"
        # Bounded: the newest KEEP_FAILED_RESULTS folders of this checkout, nothing older. The
        # names start with a UTC time, so the glob's sorted order is oldest first.
        old=("$RESULTS_KEEP"/*)
        n=0
        count="${#old[@]}"
        while [ "$n" -lt $((count - KEEP_FAILED_RESULTS)) ]; do
          rm -rf "${old[$n]}"
          n=$((n + 1))
        done
      else
        echo "    run-tests.sh: could NOT keep the per-test results at $dest; they are lost with $dir"
      fi
    else
      echo "    per-test results kept at $dir"
    fi
  fi
}

suite_inputs() {  # $1 = full path to a suite; prints repo-relative paths, or exits 1
  # READ OUT OF THE SUITE, never from a table here. A second place to edit is the defect this
  # file's header counts five instances of, and the suite is the only thing that knows what
  # it reads. A suite with no `# run-tests: inputs` line declares nothing and is therefore
  # never skippable — which is the safe default for every suite written from now on.
  local decl
  decl="$(sed -n 's/^# run-tests: inputs[[:space:]][[:space:]]*//p' "$1" | head -1)"
  [ -n "$decl" ] || return 1
  printf '%s\n' "$decl"
}

suite_input_digest() {  # $1 = full path to a suite; prints a sha256, or exits 1
  local paths dirty
  # A land omits A8. The nightly must execute it even if the same source passed a land
  # or an earlier nightly; a source-only receipt cannot prove that gate ran this time.
  case "$(basename "$1"):${RICHOS_NATIVE_IOS_APP_A8:-0}" in
    native-ios-app.test.sh:1) return 1 ;;
  esac
  paths="$(suite_inputs "$1")" || return 1
  [ -n "$ROOT" ] || return 1
  dirty="$(git -C "$ROOT" status --porcelain --untracked-files=all -- $paths 2>/dev/null)" || return 1
  [ -z "$dirty" ] || return 1
  {
    git -C "$ROOT" ls-files -s -- $paths 2>/dev/null || return 1
    # Not in git, and both suites run against it: the pinned runtime the engine asset
    # embeds and `make-engine-asset.test.sh`'s L19 executes. Included for both, because a
    # superset re-runs a suite that did not need it and that is the harmless direction.
    if [ -n "${RICHOS_RUNTIME_DIR:-}" ] && [ -f "$RICHOS_RUNTIME_DIR/delivery.json" ]; then
      /usr/bin/shasum -a 256 "$RICHOS_RUNTIME_DIR/delivery.json" | awk '{print "runtime " $1}'
    else
      echo "runtime none"
    fi
  } | /usr/bin/shasum -a 256 | awk '{print $1}'
}

proof_path() { printf '%s/%s.proof\n' "$STATE" "$1"; }

proven_run_for() {  # $1 = suite basename, $2 = digest; prints the run id if it matches
  local p; p="$(proof_path "$1")"
  [ -f "$p" ] || return 1
  grep -Fxq "inputs=$2" "$p" || return 1
  sed -n 's/^run=//p' "$p" | head -1
}

record_proof() {  # $1 = suite basename, $2 = digest
  mkdir -p "$STATE" 2>/dev/null || return 0
  {
    echo "suite=$1"
    echo "inputs=$2"
    echo "run=$RUN_ID"
    echo "commit=$HEAD_SHA"
    echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$(proof_path "$1")" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------
# Plan every suite BEFORE anything starts, so a refusal costs no runner time.
# ---------------------------------------------------------------------------------------
N=${#SUITES[@]}
REL=(); STATE_OF=(); NOTE=(); DIGEST=(); RUNNER=()
i=0
while [ "$i" -lt "$N" ]; do
  t="${SUITES[$i]}"
  rel="${t#"$DIR"/}"
  REL[$i]="$rel"
  STATE_OF[$i]="run"
  NOTE[$i]=""
  DIGEST[$i]=""
  RUNNER[$i]="host"
  if is_host_screen "$t"; then
    if [ -n "$NO_HOST_SCREEN" ]; then
      if [ -n "${RICHOS_GUI_HOST:-}" ]; then
        if [ -x "$DIR/testvm/run-suite.sh" ]; then
          RUNNER[$i]="vm:${RICHOS_GUI_HOST}"
        else
          echo "run-tests.sh: RICHOS_GUI_HOST names '${RICHOS_GUI_HOST}', and there is no" >&2
          echo "              $DIR/testvm/run-suite.sh to run $rel in it." >&2
          echo "              A caller who named a guest asked for the proof. This run will not" >&2
          echo "              fall back to the operator's screen and will not pretend the suite" >&2
          echo "              was skipped on purpose. Provision the guest, or unset" >&2
          echo "              RICHOS_GUI_HOST to record the suite as NOT RUN." >&2
          exit 2
        fi
      else
        STATE_OF[$i]="notrun"
        NOTE[$i]="no screen this run may use; --no-host-screen is in effect and RICHOS_GUI_HOST is unset"
      fi
    fi
  fi
  if [ "${STATE_OF[$i]}" = "run" ] && [ -n "$SKIP_UNCHANGED" ]; then
    if d="$(suite_input_digest "$t")" && [ -n "$d" ]; then
      DIGEST[$i]="$d"
      if r="$(proven_run_for "$rel" "$d")" && [ -n "$r" ]; then
        STATE_OF[$i]="skipped"
        NOTE[$i]="inputs unchanged since run $r (sha256 $d)"
      fi
    fi
  fi
  i=$((i + 1))
done

echo "${#ALL[@]} suite(s) discovered under $DIR"
[ "$N" -eq "${#ALL[@]}" ] || echo "  --only: running $N of them"
echo "  pool: $JOBS concurrent (override with --jobs N or RUN_TESTS_JOBS)"
if [ "${#DECLARED_SUITE[@]}" -gt 0 ]; then
  for i in "${!DECLARED_SUITE[@]}"; do
    echo "  declared host gap: ${DECLARED_SUITE[$i]} — ${DECLARED_WHY[$i]}"
  done
fi
i=0
while [ "$i" -lt "$N" ]; do
  case "${STATE_OF[$i]}" in
    notrun)  echo "  NOT RUN (no screen): ${REL[$i]} — ${NOTE[$i]}" ;;
    skipped) echo "  SKIPPED: ${REL[$i]} — ${NOTE[$i]}" ;;
  esac
  case "${RUNNER[$i]}" in
    vm:*) echo "  in a guest: ${REL[$i]} — ${RUNNER[$i]#vm:}" ;;
  esac
  i=$((i + 1))
done
echo ""

# ---------------------------------------------------------------------------------------
# The pool. bash 3.2 is what /usr/bin/env bash resolves to on this Mac (3.2.57) — there is
# no `wait -n`, so the pool is polled rather than event-driven. 5 Hz over a run measured in
# minutes costs nothing and needs no bash 4.
# ---------------------------------------------------------------------------------------
launch() {
  # Two statements, not one `local idx=... t=${SUITES[$idx]}`: bash expands every word of a
  # command before running it, so `$idx` would still be unset inside the same `local`.
  local idx="$1"
  local t="${SUITES[$idx]}"
  local lease=()
  # This suite's own results folder; created by whoever writes into it, never shared.
  local results; results="$(results_dir "$idx")"
  if [ -n "${RICHOS_WORKER_TOKENS:-}" ]; then
    lease=(python3 "${RICHOS_WORKER_TOKENS_TOOL:-$WORKER_TOOL}" run "$RICHOS_WORKER_TOKENS"
           --free "$WORK/suite-free.lock" --)
  fi
  case "${RUNNER[$idx]}" in
    vm:*)
      # A guest cannot write this host's results folder: no RICHOS_TEST_RESULTS_DIR there.
      ( ${lease[@]+"${lease[@]}"} "$DIR/testvm/run-suite.sh" "${RUNNER[$idx]#vm:}" "$t" > "$WORK/$idx.out" 2>&1
        c=$?; date +%s > "$WORK/$idx.end"; echo $c > "$WORK/$idx.rc" ) &
      ;;
    *)
      # The finish time is stamped by the child, never by the printer: output is drained in
      # discovery order, so a fast suite can sit finished for minutes waiting for a slow one
      # ahead of it, and timing it at print would charge it that wait.
      ( RICHOS_TEST_RESULTS_DIR="$results" ${lease[@]+"${lease[@]}"} bash "$t" > "$WORK/$idx.out" 2>&1
        c=$?; date +%s > "$WORK/$idx.end"; echo $c > "$WORK/$idx.rc" ) &
      ;;
  esac
  PIDS[$idx]=$!
  STARTED[$idx]="$(date +%s)"
}

running_count() {
  local n=0 k=0
  while [ "$k" -lt "$N" ]; do
    if [ -n "${PIDS[$k]:-}" ] && [ ! -f "$WORK/$k.rc" ]; then n=$((n + 1)); fi
    k=$((k + 1))
  done
  echo "$n"
}

FAILED=()
GAPPED=()
NOTRUN=()
SKIPPED=()
TOTAL_CHECKS=0
STARTED=()
ELAPSED=()

print_result() {
  local idx="$1"
  local rel="${REL[$idx]}"
  local out code n
  echo "--- $rel"
  case "${STATE_OF[$idx]}" in
    notrun)
      echo "    NOT RUN (no screen): ${NOTE[$idx]}"
      echo "    This candidate carries no gui-boot result. \`nightly-local.py publish\` will"
      echo "    refuse it until --gui-proof names one taken against the same commit."
      NOTRUN+=("$rel")
      ELAPSED[$idx]=0
      echo ""
      return ;;
    skipped)
      echo "    SKIPPED: ${NOTE[$idx]}"
      SKIPPED+=("$rel")
      ELAPSED[$idx]=0
      echo ""
      return ;;
  esac
  out="$(cat "$WORK/$idx.out" 2>/dev/null)"
  code="$(cat "$WORK/$idx.rc" 2>/dev/null || echo 1)"
  ELAPSED[$idx]=$(( $(cat "$WORK/$idx.end" 2>/dev/null || date +%s) - ${STARTED[$idx]:-0} ))
  printf '%s\n' "$out"
  # Each suite ends with "all N passed" or "N FAILED, M passed"; the count is read
  # off the suite's own output rather than asserted here, for the same reason the
  # inventory is not typed.
  n="$(printf '%s' "$out" | sed -n 's/.*all \([0-9]*\) passed ===.*/\1/p' | tail -1)"
  [ -n "$n" ] && TOTAL_CHECKS=$((TOTAL_CHECKS + n))
  if [ -n "$PROOF_OUT" ] && is_host_screen "${SUITES[$idx]}"; then
    {
      echo "richos-gui-proof 1"
      echo "suite=$rel"
      echo "commit=$HEAD_SHA"
      echo "where=${RUNNER[$idx]}"
      echo "result=$( [ "$code" = 0 ] && echo pass || echo "fail:$code" )"
      echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "--- output ---"
      printf '%s\n' "$out"
    } > "$PROOF_OUT" 2>/dev/null \
      || echo "    run-tests.sh: could not write the gui proof to $PROOF_OUT"
    echo "    gui proof written to $PROOF_OUT"
  fi
  # A HERE-STRING, NEVER A PIPE INTO `grep -q`. This file runs under `pipefail`, and
  # `grep -q` exits the instant it matches — so with a pipe, the writer on the left can be
  # killed by SIGPIPE AFTER the match, the pipeline reports 141, and this test reads FALSE
  # over output that DID contain a failed case. Measured on this Mac, 2026-09-20, on this
  # exact idiom: 400 of 400 iterations reported "no match" for a 400 KB payload whose first
  # line was the needle, and 14 of 200 for `gui-boot.test.sh` through the scanner in
  # `run-tests.test.sh` case S6. Here that false reading would file a suite that FAILED a
  # case as a tolerated host gap — the concealment this harness exists to refuse.
  if [ "$code" -eq 2 ] && grep -q '^  FAIL  ' <<<"$out"; then
    # A GAP IS A CLAIM ABOUT THE HOST, AND THIS SUITE ALREADY FOUND SOMETHING WRONG.
    # See the header. Counted as a failure, which no declaration tolerates.
    echo "    run-tests.sh: $rel exited 2 (\"this host cannot answer\") after failing a case of its own."
    echo "    A gap says this machine lacks something. A failed case says something is WRONG, and that"
    echo "    outranks it — this is counted as a FAILURE, and no declaration can tolerate it."
    printf '%s\n' "$out" | grep '^  FAIL  ' | sed 's/^/    /'
    FAILED+=("$rel")
    name_failures "$idx"
  elif [ "$code" -eq 2 ]; then
    GAPPED+=("$rel")
    rm -rf "$(results_dir "$idx")"
  elif [ "$code" -ne 0 ]; then
    FAILED+=("$rel")
    name_failures "$idx"
  else
    [ -n "${DIGEST[$idx]}" ] && record_proof "$rel" "${DIGEST[$idx]}"
    rm -rf "$(results_dir "$idx")"
  fi
  echo ""
}

RUN_STARTED="$(date +%s)"
next=0
printed=0
while [ "$printed" -lt "$N" ]; do
  while [ "$next" -lt "$N" ]; do
    if [ "${STATE_OF[$next]}" != "run" ]; then
      PIDS[$next]=""
      : > "$WORK/$next.rc"
      next=$((next + 1))
      continue
    fi
    [ "$(running_count)" -lt "$JOBS" ] || break
    launch "$next"
    next=$((next + 1))
  done
  progressed=""
  while [ "$printed" -lt "$next" ] && [ -f "$WORK/$printed.rc" ]; do
    print_result "$printed"
    printed=$((printed + 1))
    progressed=1
  done
  [ "$printed" -lt "$N" ] && [ -z "$progressed" ] && sleep 0.2
done
wait 2>/dev/null || true
RUN_ELAPSED=$(( $(date +%s) - RUN_STARTED ))

# ---------------------------------------------------------------------------------------
# What ran, how long each one took. Serial or not, this is the table that says where the
# time went — and with a pool it is the only way to see it at all.
# ---------------------------------------------------------------------------------------
echo "per-suite wall clock (pool of $JOBS, $RUN_ELAPSED s total):"
i=0
while [ "$i" -lt "$N" ]; do
  case "${STATE_OF[$i]}" in
    run)     printf '  %-32s %5ss\n' "${REL[$i]}" "${ELAPSED[$i]:-0}" ;;
    skipped) printf '  %-32s %5s  (skipped, inputs unchanged)\n' "${REL[$i]}" "-" ;;
    notrun)  printf '  %-32s %5s  (not run, no screen)\n' "${REL[$i]}" "-" ;;
  esac
  i=$((i + 1))
done
echo ""

if [ -n "$RESULTS_OUT" ]; then
  json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  {
    printf '{\n'
    printf '  "jobs": %s,\n' "$JOBS"
    printf '  "seconds": %s,\n' "$RUN_ELAPSED"
    printf '  "run_id": "%s",\n' "$(json_escape "$RUN_ID")"
    printf '  "commit": "%s",\n' "$(json_escape "$HEAD_SHA")"
    printf '  "suites": [\n'
    i=0
    while [ "$i" -lt "$N" ]; do
      state="${STATE_OF[$i]}"
      if [ "$state" = "run" ]; then
        code="$(cat "$WORK/$i.rc" 2>/dev/null || echo 1)"
        if [ "$code" = 0 ]; then state="passed"
        elif [ "$code" = 2 ]; then state="gap"
        else state="failed"; fi
        for f in ${FAILED[@]+"${FAILED[@]}"}; do [ "$f" = "${REL[$i]}" ] && state="failed"; done
      fi
      printf '    {"name": "%s", "state": "%s", "seconds": %s, "where": "%s"' \
        "$(json_escape "${REL[$i]}")" "$state" "${ELAPSED[$i]:-0}" "$(json_escape "${RUNNER[$i]}")"
      [ -n "${DIGEST[$i]}" ] && printf ', "inputs_sha256": "%s"' "${DIGEST[$i]}"
      if [ -n "${FAILING[$i]:-}" ]; then
        printf ', "failing_tests": ['
        sep=""
        while IFS= read -r f; do
          printf '%s"%s"' "$sep" "$(json_escape "$f")"; sep=", "
        done <<<"${FAILING[$i]}"
        printf ']'
      fi
      if [ "${STATE_OF[$i]}" = "skipped" ] || [ "${STATE_OF[$i]}" = "notrun" ]; then
        printf ', "reason": "%s"' "$(json_escape "${NOTE[$i]}")"
      fi
      i=$((i + 1))
      [ "$i" -lt "$N" ] && printf '},\n' || printf '}\n'
    done
    printf '  ]\n}\n'
  } > "$RESULTS_OUT"
fi

# A real failure outranks everything: report it and stop, so a gap can never be the
# headline over a suite that ran and lost.
if [ "${#FAILED[@]}" -gt 0 ]; then
  # Beside each failed suite, what failed in it, so the last lines of a long log name it.
  i=0
  while [ "$i" -lt "$N" ]; do
    if [ -n "${FAILING[$i]:-}" ]; then
      while IFS= read -r f; do echo "  ${REL[$i]}: $f"; done <<<"${FAILING[$i]}"
    fi
    i=$((i + 1))
  done
  echo "=== app/scripts: ${#FAILED[@]} of ${#SUITES[@]} suite(s) FAILED: ${FAILED[*]} ==="
  exit 1
fi

# An undeclared gap. This is the case that must never pass, because it is the shape of a
# suite that silently stopped running.
UNDECLARED=()
for g in "${GAPPED[@]:-}"; do
  [ -n "$g" ] || continue
  known=""
  for d in "${DECLARED_SUITE[@]:-}"; do [ "$d" = "$g" ] && known=1 && break; done
  [ -n "$known" ] || UNDECLARED+=("$g")
done
if [ "${#UNDECLARED[@]}" -gt 0 ]; then
  echo "=== app/scripts: ${#UNDECLARED[@]} suite(s) reported that this host cannot answer, and nobody declared them: ${UNDECLARED[*]} ==="
  echo "    Exit 2 from a suite is 'a fact about THIS MACHINE'. Undeclared, it is indistinguishable"
  echo "    from a suite that quietly stopped running, so it is refused rather than tolerated."
  echo "    Declare it — with a reason — in RUN_TESTS_DECLARED_GAPS, or fix the host."
  exit 2
fi

# A declaration that is no longer needed. Left alone it would sit there ready to swallow a
# future gap in the same suite for a reason that has nothing to do with the one written down.
#
# A suite that was NOT RUN or SKIPPED this run did not answer, so its declaration has not
# outlived anything — it was never given the chance to. Only a suite that RAN and answered
# makes a declaration stale.
# A declaration for a suite `--only` left out of THIS run is excused for the same reason:
# it was never asked to answer. A declaration naming a suite that is not in the inventory
# at all is still STALE — that one names nothing, which is the original case.
STALE=()
for d in "${DECLARED_SUITE[@]:-}"; do
  [ -n "$d" ] || continue
  excused=""
  in_inventory=""
  for a in "${ALL[@]}"; do [ "$(basename "$a")" = "$d" ] && in_inventory=1 && break; done
  if [ -n "$in_inventory" ]; then
    selected=""
    for r in ${REL[@]+"${REL[@]}"}; do [ "$r" = "$d" ] && selected=1 && break; done
    [ -n "$selected" ] || excused=1
    for g in ${GAPPED[@]+"${GAPPED[@]}"} ${NOTRUN[@]+"${NOTRUN[@]}"} ${SKIPPED[@]+"${SKIPPED[@]}"}; do
      [ "$g" = "$d" ] && excused=1 && break
    done
  fi
  [ -n "$excused" ] || STALE+=("$d")
done
if [ "${#STALE[@]}" -gt 0 ]; then
  echo "=== app/scripts: a host gap is declared for ${STALE[*]}, and that suite answered on this host ==="
  echo "    The allowance has outlived its reason. Remove the declaration; an allowance nobody needs"
  echo "    is an allowance waiting to hide something else."
  exit 2
fi

ASIDE=$(( ${#GAPPED[@]} + ${#NOTRUN[@]} + ${#SKIPPED[@]} ))
if [ "$ASIDE" -gt 0 ]; then
  RAN=$(( ${#SUITES[@]} - ASIDE ))
  LINE="=== app/scripts: $RAN of ${#SUITES[@]} suites passed — $TOTAL_CHECKS checks"
  [ "${#GAPPED[@]}" -gt 0 ]  && LINE="$LINE — ${#GAPPED[@]} could not run on this host: ${GAPPED[*]}"
  [ "${#NOTRUN[@]}" -gt 0 ]  && LINE="$LINE — ${#NOTRUN[@]} NOT RUN (no screen): ${NOTRUN[*]}"
  [ "${#SKIPPED[@]}" -gt 0 ] && LINE="$LINE — ${#SKIPPED[@]} skipped, inputs unchanged: ${SKIPPED[*]}"
  echo "$LINE ==="
  for i in "${!DECLARED_SUITE[@]}"; do
    echo "    ${DECLARED_SUITE[$i]}: ${DECLARED_WHY[$i]}"
  done
  i=0
  while [ "$i" -lt "$N" ]; do
    case "${STATE_OF[$i]}" in
      notrun|skipped) echo "    ${REL[$i]}: ${NOTE[$i]}" ;;
    esac
    i=$((i + 1))
  done
  exit 0
fi
echo "=== app/scripts: all ${#SUITES[@]} suites passed — $TOTAL_CHECKS checks ==="
