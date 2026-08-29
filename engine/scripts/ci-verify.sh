#!/usr/bin/env bash
#
# ci-verify.sh — the engine's full self-verification, as ONE command.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# The engine ships a GitHub Actions workflow that verifies it on every push.
# That workflow has to exist in TWO places at once and they must never drift:
#
#   engine/.github/workflows/engine-self-verify.yml   the ADOPTER's template.
#       An adopter copies the engine's contents to their repository ROOT, so
#       this lands at THEIR root and its paths are root-relative.
#
#   .github/workflows/engine-self-verify.yml          THIS repository's own.
#       Here the engine lives in a SUBDIRECTORY (engine/), because this repo
#       also carries the product that runs the engine by reference. Actions
#       discovers workflows only at the repository root, so the root copy is
#       the one that actually fires, and it runs with working-directory: engine.
#
# Two YAML files that each spell out the same six verification steps is a
# typed inventory in a different costume — the exact object `run-all-tests.sh`
# refuses to keep, one level further out. So they do not spell out the steps.
# Both call THIS script, and it is the only place the steps are written down.
# Change what CI verifies here, once, and both callers change with it.
#
# It is also runnable by hand, which is the point: "what does CI do?" has a
# one-line answer an engineer can execute locally before pushing.
#
#     engine/scripts/ci-verify.sh
#
# ===========================================================================
# WHAT IT RUNS, IN ORDER
# ===========================================================================
#   1. PRECONDITIONS — tool versions, and a git identity (see below).
#   2. bash -n on every shipped shell script. Fast fail on a syntax error
#      before anything slower runs.
#   3. scripts/run-all-tests.sh — EVERY test suite, discovered from disk.
#      Not a glob, not a list. See that runner's header for the argument.
#   4. scripts/hooks/install.sh — mints the gitignored .sha256 sidecars the
#      probe compares against. A fresh clone has none, so this is not an
#      optional convenience step: without it the probe fails on layers B, C,
#      K, O, P, Q, R and S for the sole reason that a fresh clone is fresh.
#   5. scripts/hooks/contract-integrity-probe.sh — the SEATED layer set (in
#      CI the engine is its own subject). The BY-REFERENCE layers, BR1-BR10,
#      cannot run here: they need a second repository that has adopted this
#      engine AND an operator-local ~/.claude plugin registration, and both
#      are properties of a workstation, not of a repository. They are covered
#      instead by scripts/hooks/by-reference.test.sh, which step 3 discovers
#      and which builds that two-root topology synthetically. Named, not
#      skipped: see docs/ci-portability-notes.md.
#   6. scripts/demo.sh — the buyer-facing 60-second proof. Step 3 already runs
#      demo.test.sh (which invokes the demo twice), but the demo is the thing
#      a prospect runs first and it broke silently for hours on 2026-08-29, so
#      its 7/7 line gets its own visible step in the log.
#
# ===========================================================================
# THE GIT-IDENTITY PRECONDITION — checked, never quietly supplied
# ===========================================================================
# Several suites build throwaway git repositories and commit into them. They
# deliberately do NOT set a local identity (see the comment in
# scripts/lib/resolve-roots.test.sh): the fixtures inherit whatever identity
# the machine has, because a machine-wide pre-commit identity guard requires a
# real one. Every developer workstation has one. A CI runner has NONE.
#
# Measured on the engine's first-ever Linux run (2026-08-29): with no identity,
# `git commit` in a fixture exits 128, the fixture ends up with no branch, and
# suites fail with messages about worktree normalisation and reap scope that
# point nowhere near the actual cause. The probe's Layer Q was worse — it
# degraded to "FUNCTIONAL CANARY DID NOT RUN", which is honest but means the
# reaper's behaviour goes unverified in a run that otherwise looks complete.
#
# So this script REFUSES to start without one, and names the two lines that fix
# it. It does not set the identity itself: silently rewriting a developer's
# global git config is not a verification script's business, and a CI runner's
# workflow is the correct, visible, ephemeral place to declare it.
#
# ===========================================================================
# Exit codes
#   0  every step passed
#   1  a verification step failed (the step is named)
#   2  a precondition is missing (git identity, or not an engine checkout)
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ENGINE_ROOT" || { echo "ERROR: ci-verify.sh: cannot cd to engine root $ENGINE_ROOT" >&2; exit 2; }

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'

step() { printf '\n%s=== [%s/%s] %s ===%s\n' "$C_BOLD" "$1" "$TOTAL_STEPS" "$2" "$C_RESET"; }
die()  { printf '\n%s✗ ci-verify: %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; exit "${2:-1}"; }

TOTAL_STEPS=6

# --- 1. Preconditions ------------------------------------------------------
step 1 "preconditions (tool versions + git identity)"
bash --version | head -1
git --version
python3 --version || die "python3 is required — every hook that parses JSON or hashes a file falls back to it." 2
[ -f "$ENGINE_ROOT/VERSION" ] && [ -d "$ENGINE_ROOT/scripts/hooks" ] \
    || die "not an engine checkout (no VERSION + scripts/hooks/ at $ENGINE_ROOT)." 2

# Ask from a directory that is NOT a git repository, so a repo-local identity
# cannot mask a missing global one: the fixtures these suites build live in
# $TMPDIR, outside every checkout, and see only the global/system config.
IDENT_PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-verify-ident.XXXXXX")"
GIT_USER_NAME="$(git -C "$IDENT_PROBE_DIR" config user.name 2>/dev/null || true)"
GIT_USER_EMAIL="$(git -C "$IDENT_PROBE_DIR" config user.email 2>/dev/null || true)"
rmdir "$IDENT_PROBE_DIR" 2>/dev/null || true
if [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_USER_EMAIL" ]; then
    printf '%s\n' "" >&2
    printf '%s✗ ci-verify: no git identity is visible outside a repository.%s\n' "$C_RED" "$C_RESET" >&2
    cat >&2 <<'EOF'
  Several suites build throwaway git repositories in $TMPDIR and commit into
  them. Those fixtures deliberately inherit the ambient identity rather than
  setting a fake local one. With no identity, `git commit` exits 128, the
  fixture never gets a branch, and the resulting failures point nowhere near
  the real cause — and the integrity probe's Layer Q silently downgrades to
  "FUNCTIONAL CANARY DID NOT RUN", so the worktree reaper goes unverified in a
  run that otherwise looks complete.

  Declare one before running (on a CI runner this belongs in the workflow):

      git config --global user.name  "CI"
      git config --global user.email "ci@example.invalid"
EOF
    exit 2
fi
echo "git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>"

# --- 2. bash -n ------------------------------------------------------------
step 2 "bash -n every shipped shell script"
SYNTAX_FAIL=0
CHECKED=0
while IFS= read -r -d '' f; do
    CHECKED=$((CHECKED + 1))
    if ! bash -n "$f"; then
        echo "SYNTAX ERROR: $f" >&2
        SYNTAX_FAIL=1
    fi
done < <(find scripts reference -name '*.sh' -print0 2>/dev/null)
[ "$CHECKED" -gt 0 ] || die "bash -n found NO shell scripts under scripts/ or reference/ — discovery is broken, refusing to report a clean syntax check over nothing." 2
[ "$SYNTAX_FAIL" -eq 0 ] || die "bash -n: one or more scripts failed to parse."
printf '%s✓%s bash -n: %s script(s) OK\n' "$C_GREEN" "$C_RESET" "$CHECKED"

# --- 3. Every test suite ---------------------------------------------------
step 3 "every engine test suite (scripts/run-all-tests.sh)"
scripts/run-all-tests.sh || die "run-all-tests.sh failed — see the named suite(s) above."

# --- 4. install.sh ---------------------------------------------------------
step 4 "mint sidecars + migrate stale settings.json (scripts/hooks/install.sh)"
scripts/hooks/install.sh || die "install.sh failed."

# --- 5. Integrity probe ----------------------------------------------------
step 5 "integrity probe (scripts/hooks/contract-integrity-probe.sh)"
scripts/hooks/contract-integrity-probe.sh || die "contract-integrity-probe.sh failed — see the named layer(s) above."

# --- 6. The 60-second proof ------------------------------------------------
# The demo derives its own fraction, so exit 0 alone would also be reported by
# a demo that quietly lost two beats and passed the remaining five. Pin the
# COUNT as well: if a beat is added or removed on purpose, this line is the
# deliberate edit that says so.
step 6 "the 60-second proof (scripts/demo.sh) — assert 7/7 beats"
DEMO_LOG="$(mktemp "${TMPDIR:-/tmp}/ci-verify-demo.XXXXXX")"
scripts/demo.sh 2>&1 | tee "$DEMO_LOG"
DEMO_RC="${PIPESTATUS[0]}"
if [ "$DEMO_RC" -ne 0 ]; then
    rm -f "$DEMO_LOG"
    die "demo.sh exited $DEMO_RC."
fi
if ! grep -qE '7/7 beats passed' "$DEMO_LOG"; then
    rm -f "$DEMO_LOG"
    die "demo.sh exited 0 but did not report '7/7 beats passed' — the beat COUNT changed. If that was deliberate, update the expected count in scripts/ci-verify.sh."
fi
rm -f "$DEMO_LOG"

printf '\n%s✓ ci-verify: all %s steps passed.%s\n' "$C_GREEN" "$TOTAL_STEPS" "$C_RESET"
exit 0
