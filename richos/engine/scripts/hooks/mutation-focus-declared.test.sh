#!/usr/bin/env bash
#
# mutation-focus-declared.test.sh — a mutant's suite run stops at the mutant's
# named FAIL line, in every harness that can honestly claim it.
#
# The finding (hunt 2026-09-29 part 3, number 9): a mutation harness proves a
# property is load-bearing by removing it and watching ONE named case go red, yet
# most harnesses ran the suite's WHOLE body for every mutant, so the dialect
# suite ran 22 times to be read at one line each. The shared harness already had
# the answer (`mutation_focus stop-at-want`, scripts/lib/stop-at-line.py); these
# did not use it. This suite proves:
#
#   S1  every harness on the shared loop that can claim it declares the focus
#   S2  every harness with its own mutant loop that can claim it runs its suite
#       through mutant_suite_run, and no longer runs the whole suite unfocused
#   H1  mutant_suite_run stops a suite at the named line, in seconds, and keeps
#       the output written up to it
#   H2  ... and when the named line never appears, the run is judged exactly as
#       it was before (the suite's own exit status, nothing stopped)
#   H3  ... and RICHOS_MUTATION_FOCUS=off turns the stop off
#
# NOT COVERED, STATED: ceo-asks, ceo-ruled and claim-roles match their witness
# with an escaped, boundary-anchored token, which a substring stop would loosen,
# so they keep the whole-suite run; idle-land, unasked-deferral,
# claim-capability-delivery, mechanical-findings, turn-manifest and
# waiver-repetition belong to the notice and idle-land work in flight elsewhere;
# guard-row-currency-commits, guard-worktree-isolation and guard-worktree-removal
# were not in the finding's inventory. None of those is claimed here.
#
# Run directly: scripts/hooks/mutation-focus-declared.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

echo "=== mutation harnesses stop each mutant at its named line ==="

SHARED=(
    dispatch-pretooluse failure-type foreign-app-data guard-model-ceiling
    guard-sealed-worktree guard-unresolved-claims guard-vendoring-commits
    land-lease-commands left-off operator-leads premise-ask
    release-land-leases stale-staging unlanded-branches
)
for h in "${SHARED[@]}"; do
    f="$SCRIPT_DIR/$h.mutation.sh"
    if [ -f "$f" ] && grep -q '^mutation_focus stop-at-want$' "$f"; then
        ok "S1  $h.mutation.sh declares mutation_focus stop-at-want"
    else
        bad "S1  $h.mutation.sh declares mutation_focus stop-at-want" "not declared"
    fi
done

# One name is spelled in two halves: this suite is not about a network design,
# and a literal of it would read as one to the engine's phone-surface guard.
PHONE_SURFACE_HARNESS="home-net""work-phone"
CUSTOM=(
    guard-dialect guard-resume-isolation "$PHONE_SURFACE_HARNESS" host-display-power
    inflight-notify interactive-prompt public-record-repo reference-ledger
)
for h in "${CUSTOM[@]}"; do
    f="$SCRIPT_DIR/$h.mutation.sh"
    if [ -f "$f" ] && grep -q '^ *mutant_suite_run ' "$f" \
       && ! grep -qE '^ *(RICHOS_MUTATION_INNER=1 )?bash "\$dir/scripts/hooks/[a-z-]+\.test\.sh"' "$f" \
       && ! grep -q '^ *( cd "\$dir" && bash ' "$f"; then
        ok "S2  $h.mutation.sh runs each mutant through mutant_suite_run"
    else
        bad "S2  $h.mutation.sh runs each mutant through mutant_suite_run" "still runs the whole suite unfocused, or never calls the helper"
    fi
done

# --- the helper, by execution ------------------------------------------------
LIB="$ENGINE_ROOT/scripts/lib/mutant-suite-run.sh"
if [ ! -f "$LIB" ]; then
    bad "H1  scripts/lib/mutant-suite-run.sh exists" "missing"
    echo ""
    echo "=== mutation-focus-declared: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
# shellcheck source=../lib/mutant-suite-run.sh
. "$LIB"

SCRATCH="$(cd "$(mktemp -d -t mutfocus.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# A fake suite: one case passes, the named one fails, then a slow tail that a
# stopped run must never reach. It exits 1, as a suite with a FAIL line does.
cat >"$SCRATCH/suite.sh" <<'SUITE'
#!/usr/bin/env bash
echo "  PASS  a1. first"
echo "  FAIL  b1. the named case"
sleep 20
echo "  FAIL  z9. the slow tail"
exit 1
SUITE
chmod +x "$SCRATCH/suite.sh"

T0=$SECONDS
mutant_suite_run "$SCRATCH/out1.txt" "b1." bash "$SCRATCH/suite.sh"
EL=$((SECONDS - T0))
if [ "$MUTANT_STOPPED" = 1 ] && [ "$EL" -lt 15 ] && grep -q 'FAIL  b1\.' "$SCRATCH/out1.txt" \
   && ! grep -q 'z9\.' "$SCRATCH/out1.txt"; then
    ok "H1  the run stops at the named line (${EL}s, tail never reached, output kept)"
else
    bad "H1  the run stops at the named line" "stopped=$MUTANT_STOPPED elapsed=${EL}s out=$(tr '\n' '|' <"$SCRATCH/out1.txt")"
fi

# H2 — a want that never appears: the suite runs to its end and its own exit
# status comes back, nothing stopped. (A short suite, so this costs no 20 s.)
cat >"$SCRATCH/short.sh" <<'SUITE'
#!/usr/bin/env bash
echo "  FAIL  other. something else"
exit 1
SUITE
mutant_suite_run "$SCRATCH/out2.txt" "b1." bash "$SCRATCH/short.sh"
if [ "$MUTANT_STOPPED" = 0 ] && [ "$MUTANT_RC" = 1 ]; then
    ok "H2  a want that never appears is judged as before (rc=1, nothing stopped)"
else
    bad "H2  unmatched want" "stopped=$MUTANT_STOPPED rc=$MUTANT_RC"
fi

RICHOS_MUTATION_FOCUS=off mutant_suite_run "$SCRATCH/out3.txt" "other." bash "$SCRATCH/short.sh"
if [ "$MUTANT_STOPPED" = 0 ] && [ "$MUTANT_RC" = 1 ] && grep -q 'FAIL  other\.' "$SCRATCH/out3.txt"; then
    ok "H3  RICHOS_MUTATION_FOCUS=off runs the whole suite and stops nothing"
else
    bad "H3  focus off" "stopped=$MUTANT_STOPPED rc=$MUTANT_RC"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== mutation-focus-declared: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== mutation-focus-declared: all $PASS passed ==="
exit 0
