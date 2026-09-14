#!/usr/bin/env bash
#
# brief-scope.mutation.sh — every refusal in brief-scope.py, watched going red.
#
# A green suite is evidence of nothing until it has been watched failing for its
# own reason. Each mutant below removes ONE clause in a throwaway copy of the
# engine and names the suite case that must go red for it.
#
# THE ONE THAT MATTERS IS M1. It removes the SPEC-SATISFIED refusal and asserts
# that S20 — THE REAL ROUND-9 BRIEF, anchored to point 2, with point 2 recorded
# green — goes red. That is the whole claim of this mechanism stated as a
# falsifiable property: without this clause, the round the CEO had to stop by
# hand is dispatched.
#
# Invoked from brief-scope.test.sh, so the runner that discovers *.test.sh runs
# it too. A harness nobody runs proves nothing about anything.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$HERE/.." && pwd)"
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "brief-scope: every refusal proven load-bearing" "scripts/brief-scope.test.sh"

mutant spec-satisfied-removed S20 scripts/brief-scope.py \
    'raise Refusal(code, lines)' \
    'pass' \
    "without the green-point refusal, the real round-9 brief anchored to point 2 is dispatched"

mutant no-anchor-removed S19 scripts/brief-scope.py \
    'if not decl["serves"]:' \
    'if False:' \
    "without the anchor requirement, a brief that names no point of the spec is dispatched"

mutant regression-clause-removed S12 scripts/brief-scope.py \
    'if regressed:' \
    'if False:' \
    "without the regression clause, a round that took a green point red is followed by another"

mutant convergence-clause-removed S13 scripts/brief-scope.py \
    'if counts[-1] > 0 and not all(a > b for a, b in zip(counts, counts[1:])):' \
    'if False:' \
    "without the convergence clause, a series whose red count never falls runs forever"

mutant stale-verdict-accepted S11 scripts/brief-scope.py \
    'if tip and verdict.get("base") and verdict["base"] != tip:' \
    'if False:' \
    "without the freshness clause, a round is dispatched against what USED to be red"

mutant spec-drift-accepted S10 scripts/brief-scope.py \
    'if live != spec.get("sha256"):' \
    'if False:' \
    "without the spec-identity clause, an anchor points at a sentence the CEO has since rewritten"

mutant fenced-anchors-counted S9 scripts/brief-scope.py \
    'if fenced:{NL}            continue' \
    'if False:{NL}            continue' \
    "without the fenced-block rule, a brief inherits the anchors of a brief it quotes"

mutation_end
