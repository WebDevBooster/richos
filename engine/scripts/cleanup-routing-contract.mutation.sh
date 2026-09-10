#!/usr/bin/env bash
#
# cleanup-routing-contract.mutation.sh — PROVES cleanup-routing-contract.test.sh
# CAN FAIL, one property at a time. Invoked by that suite; see
# scripts/lib/mutation-harness.sh for the loop. Case ids (C6 etc.) are the ones
# the suite prints on both its PASS and FAIL lines.
#
# The property under test in all of these is one sentence: a routing key cannot
# be added quietly. Each mutant removes one of the things that make that true,
# and the suite has to notice.
#
# WHY THE HISTORY OVERRIDE IS EXPORTED BELOW. The harness runs the suite from a
# sandbox COPY of the engine, which is not a git repository, so the two replays
# (C2-C5) would go red for want of history on every mutant — every mutant would
# score PROVEN and none of them would have proven anything. The override hands
# the suite the real repository to read history OUT OF while it reads code out
# of the mutated sandbox, which is exactly the split these cases need.
#
# WHAT IS DELIBERATELY NOT MUTATED, and why, because a harness that quietly
# omits a case is the same failure as a suite that quietly stops asserting:
#
#   C1 (the live tree holds) has no mutant of its own. Every mutant that makes
#   the check over-eager fails C1 too, so it is exercised constantly; a mutant
#   naming it would prove only that a broken check breaks.
#
#   C11b (a missing signature is exit 2) shares its clause shape with C11 and
#   is proven by the same class of edit. One of the pair is mutated.
#
#   C10 (a routing key in prose is not a routing key) is mutated by REGRESSING
#   THE EXTRACTOR TO A GREP rather than by deleting a clause, because C10 is a
#   property of the extraction being an AST walk and there is no single clause
#   whose removal produces it. That mutant is the actual regression the case
#   exists to prevent: somebody replaces the walk with a regex because the
#   regex is shorter.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"

RICHOS_ROUTING_HISTORY_REPO="${RICHOS_ROUTING_HISTORY_REPO:-$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || true)}"
export RICHOS_ROUTING_HISTORY_REPO

mutation_begin "cleanup-routing contract (a routing key cannot be added quietly)" \
    "scripts/cleanup-routing-contract.test.sh"

F="scripts/cleanup-routing-contract.py"

mutant signature-diff-ignored "C2" "$F" \
    '    if real_moved:' \
    '    if False:' \
    "the causing commit would pass. 2afb9703 would add cleanup_policy to terminalize() and nothing would say so — which is the three days this check exists to prevent, restored exactly."

mutant suites-not-listed "C4" "$F" \
    '    stem = pathlib.Path(module).stem{NL}    out = []' \
    '    stem = pathlib.Path(module).stem{NL}    return []{NL}    out = []' \
    "the failure would name the key and not a single place that has to agree with it, so the engineer would be told a signature moved and left to find the suites themselves — which is the search the message exists to replace."

mutant converter-coverage-ignored "C6" "$F" \
    '            if not missing:{NL}                continue' \
    '            if True:{NL}                continue' \
    "a converter that strips one routing key of two would be accepted, and every case below it would go on asserting a route its own fixture had stopped selecting."

mutant partial-declaration-unchecked "C7b" "$F" \
    '                if keys == stripped and reason:{NL}                    continue' \
    '                if True:{NL}                    continue' \
    "a 'historical-fixture-partial:' marker would be a permanent pass rather than a claim: pasted once, it would keep exempting a converter long after it stopped describing it — the bare-marker exemption this project has already ruled out twice."

mutant blind-spots-not-locked "C8" "$F" \
    '    if canary_moved:' \
    '    if False:' \
    "a routing decision moved into a shape the walk cannot read would empty R1 silently: the check would stay green over a signature it could no longer derive, which is worse than no check because it reports."

mutant unclassified-key-accepted "C9" "$F" \
    '    if unclassified:{NL}        failures.append(' \
    '    if False:{NL}        failures.append(' \
    "a new routing key would enter the lock as '?' and stay there, so the one decision this check exists to force — is a historical fixture allowed to carry this key — would never be asked."

mutant extractor-regressed-to-grep "C10" "$F" \
    '        for fn, key, shape, _line in visitor.rows:{NL}            rows.add((rel, fn, key, shape))' \
    '        for fn, key, shape, _line in visitor.rows:{NL}            rows.add((rel, fn, key, shape)){NL}        for _hit in re.finditer(r"cleanup_[a-z_]+", path.read_text()):{NL}            rows.add((rel, "<grep>", _hit.group(0), "grep"))' \
    "the extractor would match the key in comments, docstrings and string literals, and the signature would churn on every paragraph somebody wrote about routing. A lock that moves when prose moves is a lock that gets re-recorded without being read."

mutant structural-keys-demanded-of-converters "C5" "$F" \
    '    route_keys = {k for k, c in classes.items() if c == "route"}' \
    '    route_keys = {k for k, c in classes.items() if c in ("route", "structural")}' \
    "R2 would demand that historical converters strip 'class', 'state' and 'path' too — corrupting the record rather than ageing it — and would report every converter in the tree, which is how a gate earns the reflex to waive it."

mutant unreadable-root-reported-as-pass "C11" "$F" \
    '                         "contract over a tree it cannot read.\n" % engine_root){NL}        return 2' \
    '                         "contract over a tree it cannot read.\n" % engine_root){NL}        return 0' \
    "a tree the check could not read at all would score green, which is the precise reading a CI job would report as 'contract holds'."

mutation_end
