#!/usr/bin/env bash
#
# stale-staging.mutation.sh — EVERY PROPERTY OF THE STAGING GATE, PROVEN BY
# REMOVING IT.
#
# stale-staging.test.sh is 38 green cases, and 38 green cases are evidence of
# nothing until somebody has watched each one go red for the RIGHT reason. This
# harness takes the shipped guard, removes one property at a time in a
# throwaway copy of the engine, and asserts that the suite fails AT THE NAMED
# CASE.
#
# THE TWO MUTANTS THAT MATTER MOST ARE THE SILENCES, NOT THE REFUSALS.
# `amendment-ignored` and `scope-half-dropped` each turn this guard into one
# that fires on landings it was never written for — which is not a missed
# defect, it is the guard's death: a blocking check with a large
# false-positive class gets waived on the day, and habitual waiving is how a
# guard dies. This engine recorded three instances of that in a single day.
# A harness that only proved the refusals would prove the half that cannot
# kill it.
#
# Invoked from stale-staging.test.sh, so the runner that discovers *.test.sh
# runs this too. A harness nobody runs proves nothing about anything.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

G="scripts/hooks/guard-stale-staging.sh"
R="scripts/staging-record.sh"

mutation_begin "THE STAGING-STALENESS GATE: every property, proven by removing it" \
               "scripts/hooks/stale-staging.test.sh"

# --- 1. THE REFUSAL ITSELF -------------------------------------------------
mutant refusal-does-not-block "2a" "$G" \
    '} >&2{NL}exit 2' \
    '} >&2{NL}exit 0' \
    "a dispatch that will take a QA verdict against a staging missing landed product commits would be allowed, which is the false verdict this whole file exists to prevent."

# --- 2. THE AMENDMENT — THE PROPERTY THAT KEEPS THE GUARD ALIVE ------------
# The pathspec is the whole of the 2026-09-02 ruling. Without it "staging is
# behind" and "staging is behind ON SOMETHING THAT SHIPPED" become one
# question, and a week of docs landings refuses every product dispatch.
mutant amendment-ignored "3b" "$G" \
    'UNDEPLOYED="$(git -C "$MAIN_ROOT" rev-list --count "${DEPLOYED}..${MAIN_TIP}" -- $STAGING_TREES 2>/dev/null || printf '"'"'ERR'"'"')"' \
    'UNDEPLOYED="$(git -C "$MAIN_ROOT" rev-list --count "${DEPLOYED}..${MAIN_TIP}" 2>/dev/null || printf '"'"'ERR'"'"')"' \
    "a land touching only docs/, scripts/, .claude/ or skills/ would be counted as deploy debt, so a staging 35 commits behind on documentation would refuse the next product dispatch. The founder's 2026-09-02 ruling is that nothing shipped and nothing is at risk there. This is the mutant that turns the guard into one that gets waived and then deleted."

# --- 3. NO DEBT MEANS SILENT, NOT 'QUIETLY TOLERATED' ----------------------
mutant no-debt-not-silent "3b" "$G" \
    '[ "$UNDEPLOYED" -gt 0 ] 2>/dev/null || exit 0' \
    '[ "$UNDEPLOYED" -ge 0 ] 2>/dev/null || exit 0' \
    "a current staging would be treated as a debt of zero commits and produce a refusal, so the guard would fire on every product dispatch forever."

# --- 4/5. SCOPE IS A CONJUNCTION, AND BOTH HALVES ARE LOAD-BEARING --------
# `avelor/` appears in a great deal of this project's prose — a row of the
# working record, a brief quoting that row, this very file. Prose is not a
# dispatch, and a path alone is not a reason to refuse one.
mutant scope-half-dropped "4b" "$G" \
    'printf '"'"'%s'"'"' "$PROMPT" | grep -qiE "$STAGING_TRIGGER_RE" || return 1' \
    'true' \
    "any dispatch merely MENTIONING a product path would be refused — reading the code, summarizing a directory, quoting a row of the record — and the guard would become a nuisance on exactly the tasks that are safe, which is how a guard gets routed around instead of used."

mutant scope-path-dropped "4a" "$G" \
    'printf '"'"'%s'"'"' "$PROMPT" | grep -qE "$SCOPE_RE" || return 1' \
    'true' \
    "every dispatch carrying any work verb would be refused while product debt existed, including the ones that have nothing to do with the product, so one undeployed commit would wedge the whole session."

# --- 6. THE ADOPTION SWITCH ------------------------------------------------
mutant adoption-switch-ignored "1d" "$G" \
    '[ -n "$(printf '"'"'%s'"'"' "$STAGING_TREES" | tr -d '"'"'[:space:]'"'"')" ] || exit 0' \
    'true' \
    "a repository that declared no staging at all would be carried past the switch and into the unevaluated-payload notice, so it would be ANNOUNCED at on a malformed call and would accumulate .claude/state/unevaluated-payloads.log — state written into a repository that never adopted this contract. Measured rather than assumed: no well-formed dispatch changes verdict under this mutation, because an empty tree list degenerates the scope regex to something that matches nothing. Silence alone would not have caught it."

# --- 7/8. THE ESCAPE HATCH IS A DECLARATION, NOT A TOKEN ------------------
mutant ack-bare-marker-exempts "5a" "$G" \
    'ACK_WHY="no '"'"'stale-staging-ack: <reason>'"'"' line is present in the prompt."' \
    'ACK_WHY=""' \
    "a prompt carrying no acknowledgement at all would be treated as acknowledged, so the guard would refuse nothing while looking switched on."

mutant ack-length-floor-gone "5b" "$G" \
    '[ "${#ACK_REASON}" -lt 30 ]' \
    '[ "${#ACK_REASON}" -lt 0 ]' \
    "a one-word token would waive the gate, which is the reflex the reason exists to interrupt. A bare marker must exempt nothing."

# --- 9. A FAILED DEPLOY AND A CURRENT STAGING MUST NEVER MATCH ------------
mutant failed-deploy-reads-as-success "6d" "$G" \
    'if [ -n "$outcome" ] && [ "$outcome" != "success" ]; then' \
    'if false; then' \
    "a record left by a deploy that FAILED would be read as what staging is running, so the one case the record exists to distinguish — 'ran and failed' versus 'current' — would produce the same verdict. That is the green-tick-over-a-scanner-that-never-ran shape this engine keeps finding in itself."

# --- 10. THE MISSING RECORD IS ANNOUNCED, NOT SWALLOWED -------------------
mutant missing-record-silent "6b" "$G" \
    'announce_off "STALE-STAGING GUARD CANNOT DECIDE: ${WHY}. This dispatch (${NAME:-<unset>}) names a product tree and a run against it, so a QA verdict from it could be about a stale staging. Have the deploy call scripts/staging-record.sh, then declare STAGING_RECORD_REQUIRED=1 in ${CONFIG} to make this a refusal."' \
    'true' \
    "a repository with no deploy record would pass every product dispatch in total silence, so an absent gate and a clean run would look identical — which is the defect this engine has now recorded four times in one day."

# --- 11. THE ESCALATION KEY MUST HAVE TEETH -------------------------------
mutant record-required-toothless "6c" "$G" \
    'if [ "$STAGING_RECORD_REQUIRED" = "1" ]; then' \
    'if false; then' \
    "STAGING_RECORD_REQUIRED would be a setting that reads as switched on and refuses nothing, which is the same failure as a green tick over a scanner that never ran."

# --- 12. THE RECORDER REFUSES A TYPED SHA ---------------------------------
# The founder's own rule: a SHA is read from `git rev-parse`, never typed. A
# recorder that accepted anything would let a typo become "what staging has".
mutant recorder-accepts-anything "7c" "$R" \
    "grep -qE '^[0-9a-f]{7,40}\$'" \
    "grep -qE '^.*\$'" \
    "any string would be written into the record as the deployed commit, and the guard would then report that commit as missing from the repository forever — a permanent 'cannot decide' minted by a typo."

mutation_end
