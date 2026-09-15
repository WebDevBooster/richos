#!/usr/bin/env bash
#
# land-completeness.mutation.sh — PROVES THE REGISTRY-HYGIENE CASES CAN FAIL.
#
# L20 and L21 are the two cases in land-completeness.test.sh that are about the
# suite itself rather than about the code under test: no test may write to the
# state the operator's live sessions read. Both of them assert an ABSENCE — no
# fixture record in the real registry, no offending sibling suite — and an
# absence is what a predicate that never runs also produces. This engine has
# shipped that shape twice (a scanner reporting CLEAN over an empty corpus, a
# runner reporting all-passed over a suite it never invoked), so the cases are
# not worth their green ticks until each has been watched go red.
#
# The loop is scripts/lib/mutation-harness.sh. Run directly, or let
# land-completeness.test.sh run it, which it does.
#
# WHAT IS NOT MUTATED HERE, AND WHY IT IS SAID RATHER THAN LEFT TO BE NOTICED:
# L1..L16 are about lib/land-completeness.py and lib/land-residue-gate.py, which
# this file does not touch. They came with their own negative controls inside the
# suite (L13 is one, L23 is another), and a mutation harness over them is a
# round of its own rather than a line in this one.
#
# Run directly: scripts/land-completeness.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "land-completeness registry hygiene" "scripts/land-completeness.test.sh"

T="scripts/land-completeness.test.sh"

# --- 1. THE REGISTRY IS SANDBOXED -----------------------------------------
# The shipped defect exactly: the ledger was redirected and the registry was
# not, so every run wrote `"why": "the land-completeness fixture"` records into
# the operator's live ~/.claude/state/workspaces/integration.json.
# THE MUTANT AIMS THE REGISTRY OUT OF THE SANDBOX BUT NOT AT THE OPERATOR'S.
# _mutant_body runs the inner suite with the AMBIENT HOME, so a mutant that
# deleted the override outright would write the exact records this round removed
# into the live ~/.claude/state/workspaces/integration.json. A mutation harness
# that reproduces the defect for real is not a proof, it is a second incident.
mutant no-registry-sandbox "L20" "$T" \
    'export RICHOS_WORKSPACES_DIR="$SANDBOX/workspaces"' \
    'export RICHOS_WORKSPACES_DIR="${TMPDIR:-/tmp}/richos-mutant-registry-not-the-sandbox"' \
    "the suite would record outside its own sandbox -- which in the shipped form was the operator's real registry, pointing at temp directories its own EXIT trap deletes."

# --- 2. A MENTION IS NOT A REDIRECT ---------------------------------------
# The first draft of SANDBOXED was `"RICHOS_WORKSPACES_DIR" in text`, and the
# PROSE explaining a sibling suite's exemption — which named the variable and
# set nothing — exempted that suite. L23's `mentions-only` control is that
# exact shape.
mutant mention-is-a-redirect "L23" "$T" \
    '    r"\b(RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)="' \
    '    r"(RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)"' \
    "naming the variable in a comment would count as redirecting it, so a suite that writes to the operator's registry and merely talks about the override would be cleared."

# --- 3. A BARE MARKER EXEMPTS NOTHING -------------------------------------
# The same discipline the contrast floor and the dialect guard use. An exemption
# with no reason is a claim nobody can check.
mutant bare-marker-exempts "L23" "$T" \
    'DECLARED = re.compile(r"registry-write-exempt:[ \t]*(\S+(?:[ \t]+\S+){2,})")' \
    'DECLARED = re.compile(r"registry-write-exempt:")' \
    "a suite could exempt itself with a reasonless marker, which is how an exemption stops being a declaration and becomes an off switch."

# --- 4. THE SEARCH CAN ACTUALLY FIND RESIDUE ------------------------------
# L20's finding is an ABSENCE, and a search that cannot match anything also
# finds nothing. L22 plants exactly the residue that was found in the
# operator's registry and requires the same search to name it.
mutant residue-search-blind "L22" "$T" \
    '    grep -rl -- "$SANDBOX" "$1" 2>/dev/null || true' \
    '    return 0' \
    "L20 would report the operator's registry clean no matter what was written into it -- the absence of a finding made indistinguishable from the absence of a search."

mutation_end
