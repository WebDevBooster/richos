#!/usr/bin/env bash
#
# reap-stale-worktrees.mutation.sh — PROVES reap-stale-worktrees.test.sh CAN
# FAIL, one property at a time. Invoked by that suite; the loop is
# scripts/lib/mutation-harness.sh. Case ids (W1 etc.) are the ones the suite
# prints on both its PASS and FAIL lines.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# The defect this harness guards is the defect the reaper HAD: a report that
# reads like success over work that never happened. `reaped=11 skipped=21
# errors=0` was printed by a run that removed nothing. A suite that asserts
# the new wording is worth exactly as much as the proof that it goes red when
# the wording comes back — otherwise it is one more green tick over something
# that never ran, which is the shape this whole project spent 2026-09-05
# finding ten instances of.
#
# ===========================================================================
# THE CONTROL RUNS FIRST, AND IT IS NOT A FORMALITY
# ===========================================================================
# On 2026-09-02 a harness scored 11 of 18 mutants "caught" because its
# sandboxes were missing a dependency: the thing under test REFUSED TO START,
# and that reads exactly like a guard catching a mutation. So the UNMUTATED
# sandbox runs the suite once and must be green before any mutant is built. A
# red control means the sandbox is deficient and every mutant below it would
# have scored for the wrong reason.
#
# ===========================================================================
# WHAT IS *NOT* MUTATED, NAMED RATHER THAN IMPLIED
# ===========================================================================
# Each suite run is ~72 seconds and every mutant pays one, so the count is a
# real cost on every engine self-test and the line had to be drawn somewhere.
# Drawn here, with the reason for each omission:
#
#   W2 (duplicate-registration) is NOT mutated. It already ships as a matched
#      pair — case 26 asserts the finding and case 26b asserts its ABSENCE in
#      an otherwise identical world — so a version of the gate that fires on
#      everything and a version that fires on nothing are both already red.
#      That is the property a mutant would have shown.
#   W4 (native-shell labeling) is NOT mutated. It is a REPORTING label wired
#      to nothing that decides, and its safety half — case 28b, a live agent's
#      shell surviving --execute — is carried by the locked-native gate, which
#      cases 2 and 24 already hold down. A label that vanished would cost a
#      reader information and could not cost anyone a worktree.
#
# Both are covered by the suite. Neither is covered by a mutant, and that
# distinction is the point of writing it down.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "reap-stale-worktrees" "scripts/reap-stale-worktrees.test.sh"

# --- CONTROL: the unmutated sandbox must be green -------------------------
CTRL_DIR="$(cd "$(mktemp -d -t reap-mutation-control.XXXXXX)" && pwd -P)"
if ! mutation_copy_engine "$CTRL_DIR" "$(cd "$SCRIPT_DIR/.." && pwd)"; then
    echo "  FAIL  control — the engine could not be copied; every mutant below would score for the wrong reason" >&2
    rm -rf "$CTRL_DIR"
    exit 1
fi
if ! RICHOS_MUTATION_INNER=1 bash "$CTRL_DIR/scripts/reap-stale-worktrees.test.sh" >"$CTRL_DIR/control.txt" 2>&1; then
    echo "  FAIL  control — the UNMUTATED sandbox is already red, so a mutant going red proves nothing:"
    grep '  FAIL' "$CTRL_DIR/control.txt" | sed 's/^/          /'
    rm -rf "$CTRL_DIR"
    exit 1
fi
echo "  PASS  control — the unmutated sandbox is green, so a mutant's red is the mutant's"
rm -rf "$CTRL_DIR"

F="scripts/reap-stale-worktrees.sh"

# THE ROW ITSELF. Put the past tense back in the DRY-RUN summary.
mutant dry-run-past-tense "W1" "$F" \
    'ACTION_FIELDS="removed=0 would-remove=$WOULD_COUNT"' \
    'ACTION_FIELDS="reaped=$WOULD_COUNT"' \
    "a session-start inventory would again report 'reaped=N' for a run that removed nothing, and the count of worktrees nobody will ever clean would read as a count of worktrees cleaned."

# The unmerged skip stops naming what is unlanded.
mutant unmerged-unnamed "W3" "$F" \
    'skip "$id" "unmerged(+$n)$_why — $(unmerged_subjects "$repo" "$target_ref" "$branch_name") — never swept; READ it before removing anything"' \
    'skip "$id" "unmerged(+$n)"' \
    "two teammates' committed escalations would go back to sitting under a bare 'unmerged(+1)', which is exactly how they sat unread for three days."

# The remover goes missing and removal carries on by a raw route.
mutant unsanctioned-fallback "W5" "$F" \
    '                _rm_rc=90' \
    '                git -C "$repo" worktree remove "$path" >/dev/null 2>&1 && _rm_rc=0 || _rm_rc=91' \
    "this script would delete worktrees on its OWN liveness answer again, with the shared resolver bypassed — the second implementation of 'alive' that goes stale unnoticed."

# The remover's refusal stops being recognized as a disagreement.
mutant refusal-not-recognized "W6" "$F" \
    'elif [ "$_rm_rc" -eq 3 ]; then' \
    'elif [ "$_rm_rc" -eq 333 ]; then' \
    "a refusal from the authoritative liveness check ('this agent is ALIVE') would be reported as an ordinary removal failure, so the one case where the two authorities contradict each other would read like a flaky git error."

mutation_end
