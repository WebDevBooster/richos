#!/usr/bin/env bash
#
# unlanded-branches.mutation.sh — PROVES THE UNLANDED-WORK SUITE CAN FAIL.
#
# Twenty-nine green ticks are evidence of nothing until somebody has watched
# them go red for the right reason. This suite is especially exposed to that,
# because MOST OF WHAT IT ASSERTS IS SILENCE — eight of its cases pass by
# observing that a hook said nothing, and a hook that is broken says nothing
# too. A suite made largely of silent cases will pass over a predicate that
# never runs at all.
#
# So: take the shipped source, remove ONE property at a time in a throwaway copy
# of the engine, and assert that
#   1. unlanded-branches.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied.
#
# The loop is scripts/lib/mutation-harness.sh. Run directly, or let
# unlanded-branches.test.sh run it, which it does.
#
# ===========================================================================
# ONE PROPERTY HAS NO SINGLE-MUTANT PROOF, AND IT IS NAMED RATHER THAN GLOSSED
# ===========================================================================
# Case U03 -- "a branch main already contains is not a finding" -- is protected
# TWICE over, independently: `for-each-ref --no-merged=<trunk>` never lists it,
# and `rev-list --count <b> --not <trunk>` returns 0 for it if it ever were
# listed. Remove either one alone and U03 still passes, correctly, because the
# other still holds. There is therefore no single-property mutation that turns
# U2 red, and writing one that removes both at once would be testing an edit
# rather than a property. The redundancy is deliberate and the gap in this
# harness is its consequence; U06 covers the count filter on its own, since only
# the count filter can see a branch that landed upstream.
#
# Run directly: scripts/hooks/unlanded-branches.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "unlanded work" "scripts/hooks/unlanded-branches.test.sh"

S="scripts/lib/unlanded-branches.py"
H="scripts/hooks/notice-unlanded-branches.sh"
C="scripts/hooks/guard-unresolved-claims.py"

# --- 1. LIVENESS FROM THE WORKTREE LOCK -----------------------------------
# Without it, every running teammate's branch is a finding, and the notice
# names six or seven branches through the middle of every session. That is not
# a louder guard, it is a muted one a day later.
mutant no-worktree-lock "U11" "$S" \
    '            if wt_locked:' \
    '            if False:' \
    "a branch a live agent is working on would be reported as stranded, which is the noise that gets a notice ignored."

# --- 2. LIVENESS ACROSS REPOSITORIES --------------------------------------
# A hand-rolled cross-repository worktree takes NO git lock of its own, so its
# owner's liveness is only readable from the native isolation worktree over in
# the session's repository. This is the common case: 48 of 53 worktrees on this
# machine were hand-rolled when it was last measured.
mutant no-native-lock "U08" "$S" \
    '                    if native_locks.get((sid, teammate)):' \
    '                    if False:' \
    "a live teammate working cross-repository would be reported as stranded on every turn, because the tree it stands in carries no evidence about its own owner."

# --- 3. THE REMOTE TRUNK IS EXCLUDED TOO ----------------------------------
# The shape a stale local main produces: work landed and was pushed, local main
# is behind its upstream, and `main..branch` still shows commits.
mutant no-remote-exclusion "U06" "$S" \
    '    exclude = [trunk] + (["origin/" + trunk] if has_remote else [])' \
    '    exclude = [trunk]' \
    "a branch that landed and was pushed would be reported as unlanded whenever the local trunk sat behind its upstream."

# --- 4. THE REPOSITORY SET COMES FROM THE SESSION -------------------------
# Measured on this machine: the seat is femcboost and every teammate works in
# richos. A seat-only sweep is a sweep of the repository where nothing happens.
mutant no-ledger-discovery "U01" "$S" \
    '    if session_id:' \
    '    if False:' \
    "only the seat repository would be swept, and the cross-repository branches -- which is where the work actually is -- would be invisible."

# --- 5. THE NOTICE ACTUALLY SAYS IT ---------------------------------------
mutant notice-says-nothing "U10" "$H" \
    'stop_notice_abnormal "unlanded:$KEY" "$SUMMARY $HOOK_TAG"' \
    'stop_notice_normal "$SUMMARY $HOOK_TAG"' \
    "the whole point: finished work outside main must end the turn with something on screen."

# --- 6. THE CLAIM CLASS READS POLARITY ------------------------------------
# The defect that produced g11/g12/g13 in miniature: a sentence saying the
# opposite is reported for agreeing with the repository.
mutant claim-ignores-polarity "C06" "$C" \
    '               if pol == "positive"]' \
    '               if pol or True]' \
    "a reply correctly saying nothing has landed yet would be reported for saying so -- the gate contradicting accuracy, which is the one thing it must never do."

# --- 7. QUOTATIONS ARE MASKED ---------------------------------------------
# Worth 13 points of measured precision on its own: the orchestrator quotes
# this very failure constantly, and an unmasked matcher reads every quotation
# as a fresh claim.
mutant claim-reads-quotations "C07" "$C" \
    '        probe = COMPLETE_QUOTED.sub(lambda m: " " * (m.end() - m.start()), s)' \
    '        probe = s' \
    "quoting the sentence that caused the incident would be treated as making the claim again, which is 13 points of precision and the whole reason this signal is worth reading."

# --- 8. AN UNEVALUATED CHECK SAYS SO --------------------------------------
mutant unevaluated-is-silent "C08" "$C" \
    '            complete_unevaluated = why' \
    '            complete_unevaluated = ""' \
    "a completeness claim made while the check that could contradict it did not run would pass in the SAME silence a clean repository produces -- the absence of a finding made indistinguishable from the absence of a check."

# --- 9. THE ONE LINE THAT LEAVES THE TRANSCRIPT ---------------------------
# stderr is filed into the transcript and shown to the operator nowhere. A
# report he cannot see is not a report.
mutant no-operator-channel "C02" "$C" \
    '    sys.stdout.write(json.dumps({"suppressOutput": True,{NL}                                 "systemMessage": text}) + "\n")' \
    '    return None' \
    "the finding would go to stderr only, where stop-hook-notice.sh measured that the operator sees it nowhere -- the report exists and reaches nobody."

mutation_end
