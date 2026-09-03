#!/usr/bin/env bash
#
# guard-model-ceiling.mutation.sh — PROVES THE COST-CEILING SUITE CAN FAIL.
#
# 58 green ticks are evidence of nothing until somebody has watched them turn
# red for the right reason, and this guard is unusually exposed to the trap:
# most of its contract is of the form "it allowed the spawn and said nothing",
# which is exactly what a hook that never ran also does. This engine has twice
# shipped a green check over a dead script for precisely that reason.
#
# So: take the SHIPPED source, remove ONE property at a time in a throwaway copy
# of the engine, and assert that (1) the suite fails, (2) the SPECIFIC named
# case fails, and (3) the mutation actually applied. The loop is
# scripts/lib/mutation-harness.sh; this file is the list of properties.
#
# Two of the mutants below are aimed at files that are NOT this guard —
# scripts/lib/resolve-model.sh (the shared resolver) and the suite's own agent
# fixture — because a guard that "reads the resolved model" and a guard that
# reads `tool_input.model` look identical from the outside until one of them is
# wrong.
#
# Invoked by guard-model-ceiling.test.sh, so the runner that discovers *.test.sh
# runs it too. A harness nobody runs proves nothing about anything.
# Run directly: scripts/hooks/guard-model-ceiling.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "guard-model-ceiling (the cost ceiling)" "scripts/hooks/guard-model-ceiling.test.sh"

G="scripts/hooks/guard-model-ceiling.sh"
T="scripts/hooks/guard-model-ceiling.test.sh"
R="scripts/lib/resolve-model.sh"

# 1. THE COMPARISON ITSELF. Without it the guard is a hook that reads a config
#    file and lets everything through — the shape a dead defense wears.
mutant ceiling-never-fires "above the ceiling by explicit override" "$G" \
    '[ "$RESOLVED_RANK" -lt "$CEILING_RANK" ] || exit 0' \
    'exit 0' \
    "Every spawn above the ceiling would be allowed, silently, by a guard that is wired, hashed and executable."

# 2. THE DIRECTION OF THE COMPARISON. Rank 1 is the HIGHEST tier, so a lower
#    number is a more expensive seat. Getting this backwards is the 2026-09-02
#    incident in a different file.
mutant comparison-inverted "above the ceiling by explicit override" "$G" \
    '[ "$RESOLVED_RANK" -lt "$CEILING_RANK" ] || exit 0' \
    '[ "$RESOLVED_RANK" -gt "$CEILING_RANK" ] || exit 0' \
    "The ceiling would refuse everything BELOW it and wave the expensive tier through — a guard enforcing the opposite of the ruling."

# 3. SILENCE AT AND BELOW THE CEILING. A guard that comments on the normal case
#    is a nag, and a nag is how a guard becomes something to disable.
mutant nag-on-the-normal-case "at the ceiling" "$G" \
    '[ "$RESOLVED_RANK" -lt "$CEILING_RANK" ] || exit 0' \
    'if [ "$RESOLVED_RANK" -ge "$CEILING_RANK" ]; then announce_off "at or below the ceiling"; exit 0; fi' \
    "Every ordinary spawn would carry a notice about a rule it already satisfies."

# 4. THE RESOLVED MODEL, NOT THE PAYLOAD STRING. The founder's instruction was
#    about the pick; a definition whose OWN default is above the ceiling is the
#    same pick with no `model:` line in sight.
mutant reads-the-payload-not-the-model "above the ceiling by the DEFINITION" "$G" \
    'RESOLVED="$(resolve_expected_model "$MODEL_OVERRIDE" "$SUBAGENT_TYPE")"' \
    'RESOLVED="$MODEL_OVERRIDE"' \
    "A teammate whose definition defaults to the top tier would spawn there forever, unremarked."

# 5. THE SHARED RESOLVER IS DOING THE WORK. Mutating a file this guard does not
#    contain must still turn this suite red, or the guard is not using it.
mutant shared-resolver-not-consulted "a verbose model id normalizes" "$R" \
    'case "$lo" in *"$m"*)' \
    'case "$lo" in "$m")' \
    "A verbose model id would rank nowhere, the guard would fail open, and the most literal way to name the expensive model would be the way past the ceiling."

# 6. THE CEILING COMES FROM THE DECLARATION. A hardcoded alias is the guard the
#    2026-09-02 postmortem forbids: it cannot be re-derived, only re-edited.
mutant ceiling-hardcoded "ceiling declared LOWER" "$G" \
    'CEILING="${MODEL_CEILING:-}"' \
    'CEILING="fable"' \
    "The declaration would be decoration; changing MODEL_CEILING would change nothing, and a model added above the top would need a code edit."

# 7. THE ACK MUST BE A REASON. A bare marker is what a reflex types.
mutant bare-ack-accepted "a BARE model-ceiling-ack" "$G" \
    'if [ -z "$ACK_WHY" ]; then' \
    'if true; then' \
    "A bare 'model-ceiling-ack:' would clear the ceiling, and the hatch would become a keystroke."

# 8. THE REFLEX LIST. An assertion of merit says nothing about one-offness.
mutant reflex-list-inert "reflex reason refused" "$G" \
    'elif hits and len(residue) < MIN_CONTENT:' \
    'elif False:' \
    "'It is the most capable model' would be an accepted justification for spending twice as much."

# 9. THE DOMINANCE CARVE-OUT — the other half, and the one that keeps this from
#    being a word filter. A real sentence containing 'quality' must survive.
mutant reflex-list-too-eager "a real reason that happens to contain a listed word" "$G" \
    'elif hits and len(residue) < MIN_CONTENT:' \
    'elif hits:' \
    "The founder's own worked example — super-premium design, quality bar — would be refused for containing a word."

# 10. THE UNDECLARED CEILING IS ANNOUNCED. A repository running with no ceiling
#     and a guard in the chain looking like protection is this engine's oldest
#     failure, wearing a checkmark.
mutant undeclared-ceiling-silent "no MODEL_CEILING declared" "$G" \
    '    announce_off "MODEL COST CEILING IS NOT DECLARED in ${CONFIG}' \
    '    : "MODEL COST CEILING IS NOT DECLARED in ${CONFIG}' \
    "A fresh adopter would run unprotected and never be told; the guard would report 'on' by existing."

# 11. FAIL OPEN, NOT CLOSED, ON ITS OWN PLUMBING. A guard that wedges every
#     dispatch over an unrankable alias is a guard that gets switched off.
mutant unrankable-model-refused "an unrankable RESOLVED model" "$G" \
    '    announce_off "MODEL COST CEILING IS OFF for this spawn: '"'"'${NAME:-<unset>}'"'"'' \
    '    exit 2
    announce_off "MODEL COST CEILING IS OFF for this spawn: '"'"'${NAME:-<unset>}'"'"'' \
    "An alias the declaration does not rank would block the spawn instead of being reported — 'I cannot tell' turned into 'forbidden'."

# 12. FAIL OPEN WHEN THE SHARED RESOLVER IS ABSENT. The isolation guard refuses
#     on the same file; this one must not, or a broken install stops all work.
mutant missing-resolver-refused "resolve-model.sh missing" "$G" \
    '    announce_off "MODEL COST CEILING IS OFF: scripts/lib/resolve-model.sh is missing' \
    '    exit 2
    announce_off "MODEL COST CEILING IS OFF: scripts/lib/resolve-model.sh is missing' \
    "A missing library would block every spawn in the session rather than announcing that the ceiling is unenforced."

# 13. UNDETERMINABLE IS NOT A PICK. model:"inherit" and host built-ins boot on
#     the session's model; there is nothing to judge and nothing to announce.
mutant undeterminable-announced 'model:"inherit" is not a pick' "$G" \
    '[ -n "$RESOLVED" ] || exit 0' \
    ': "$RESOLVED"' \
    "Every spawn of a host built-in would carry a notice, which is the noise that gets a guard removed."

# 14. THE REFUSAL CARRIES THE RULE. The founder asked for the note to REACH the
#     orchestrator; a refusal that points at a file is one he will read past.
mutant refusal-drops-the-examples "the refusal carries worked example 2" "$G" \
    '    echo "    - unique or super-premium front-end design"' \
    '    echo "    - (see the ruling)"' \
    "The refusal would say no without saying what the exception is FOR, which is the half that makes reconsidering possible."

# 15. THE RECONSIDER PATH NAMES THE RENAME. Dropping to the ceiling without
#     renaming produces an untruthful <model> token and a second refusal from a
#     different guard — the loop that makes an operator route around both.
mutant refusal-drops-the-rename "the refusal names the rename the drop forces" "$G" \
    '    RENAME="${NAME_ROLE}-${CEILING}-${NAME_ID}"' \
    '    RENAME="the same name"' \
    "The operator would drop the model, keep the name, and be refused again by the spawn guard for a reason this refusal could have prevented."

# 16. THE LOG. An accepted waiver that leaves no record is an exception nobody
#     can count, and a habit of waiving is exactly what has to stay visible.
mutant log-drops-the-model "an accepted ack is logged" "$G" \
    'model=%s\ttier=%s\tceiling=%s' \
    'tier=%s\tceiling=%s' \
    "The log would record that a waiver happened but not what it bought, so a pattern of top-tier spawns would be invisible in it."

# 17. THE FIXTURE'S OWN HONESTY. If the definition-default fixture did not
#     actually default above the ceiling, case (b) would pass for free.
mutant fixture-default-is-honest "above the ceiling by the DEFINITION" "$T" \
    'name: mctop\nmodel: fable' \
    'name: mctop\nmodel: opus' \
    "The definition-default case would be testing an at-ceiling teammate and passing without exercising the path it names."

mutation_end
