#!/usr/bin/env bash
#
# workspace-shapes.mutation.sh — PROVES the allow-list suite CAN FAIL, one
# property at a time. Invoked by workspace-shapes.test.sh; the loop is
# scripts/lib/mutation-harness.sh.
#
# The three properties below are the ones that decide something. The
# classifier's individual shape tests are not mutated one by one: each is a
# single `startswith` whose positive case is in the suite, and a mutant per
# prefix would be a harness proving that string comparison works.
#
# NOT COVERED, stated rather than implied: the `not-ours` fallthrough. There is
# no code to remove — it is the absence of a match — and its positive case is
# S04 and S13. A mutant would have to ADD a rule, which tests a design that
# does not exist.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "workspace-shapes (the declared allow-list)" "scripts/lib/workspace-shapes.test.sh"

S="scripts/lib/workspace-shapes.py"
C="scripts/lib/workspace-scope.py"

mutant codex-not-classified "S06" "$S" \
    "    if \".codex\" in parts:{NL}        return True, \"the path lies under a .codex directory\"" \
    "    if False:{NL}        return True, \"the path lies under a .codex directory\"" \
    "the two codex worktrees under ~/.codex/ would classify as something else (S06 is the case that owns the PATH shape; S05 owns the branch shape), and the CEO's ruling of 2026-09-10 would be enforced by omission rather than by name -- which ceo-decisions.md section 31 explicitly says is not enough."

mutant declaration-ignored "S07" "$S" \
    "    return [s for s in config_value(\"OWNED_WORKSPACE_SHAPES\", DEFAULT_SHAPES, repo).split(){NL}            if s in OWNED_KINDS]" \
    "    return list(OWNED_KINDS)" \
    "the allow-list would stop being DATA: an entity could no longer narrow it, and retiring the legacy convention would need a code change instead of one word in a config file."

mutant report-guesses-instead-of-asking "S11" "$C" \
    "                verdict, why_adopt = _adoption_verdict(path)" \
    "                verdict, why_adopt = True, 'mutant: assumed adoptable'" \
    "the report would ANNOUNCE that an unrecorded workspace is ready when the sanctioned claim path refuses it -- a status invented by the reporter, which is how a reader stops being able to trust any row."

mutation_end
