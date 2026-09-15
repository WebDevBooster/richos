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

# --- §6, WHO CHOOSES THE MECHANISM -----------------------------------------
# M8 IS §6'S CLAIM AS A FALSIFIABLE PROPERTY, and it is the counterpart of M1:
# remove the undeclared-design refusal and S31 — THE REAL ROUND-9 BRIEF, anchored
# to point 2, with point 2 red in two consecutive verdicts — is dispatched
# carrying an adversarial reviewer's own prescription, exactly as it was.

mutant design-undeclared-accepted S31 scripts/brief-scope.py \
    'if undeclared:' \
    'if False:' \
    "without the disposition requirement, the round-9 brief's prescribed design is dispatched"

mutant design-disposition-unchecked S25 scripts/brief-scope.py \
    'if bad_disp:' \
    'if False:' \
    "without the disposition check, any prose on a design: line counts as a declaration"

# The retry rule is the TRIGGER, so removing it must not merely change a message:
# with every red point treated as first-time-red, nothing is ever on retry and the
# whole of §6 stops firing.
mutant retry-never-detected S22 scripts/brief-scope.py \
    'return set(int(k) for k, v in now.items() if v == "red" and was.get(k) == "red")' \
    'return set()' \
    "without the red-then-red rule, no point is ever on retry and §6 never fires"

# And the BOUNDARY is load-bearing in the other direction: if a first-time-red
# point were treated as a retry, §6 would demand a disposition from every brief
# that ever opens work on a point, which is the false-positive class that kills a
# guard. S28 is the case that pins it.
mutant retry-over-triggers S28 scripts/brief-scope.py \
    'if hist[-1].get("base") == current_base:{NL}        return hist[-2] if len(hist) >= 2 else None' \
    'if False:{NL}        return hist[-2] if len(hist) >= 2 else None' \
    "treating the current verdict as its own predecessor makes every red point a retry"

mutation_end
