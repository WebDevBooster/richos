#!/usr/bin/env bash
#
# provider-supervisor.mutation.sh: PROVES provider-supervisor.test.py WOULD CATCH
# THE OPERATOR-MODE REAPING GOING WRONG (spec r3 (q) item 2, F5; Frank G8, G9).
# Each mutant removes ONE property from a throwaway copy of the engine and
# demands that the NAMED case go red. The loop is scripts/lib/mutation-harness.sh.
#
# NO MUTANT for "the group kill" alone: in the fixture every descendant is
# recorded within a second, so the per-pid pass kills them even with no group
# kill, and such a mutant could not fail. The group kill exists for a child
# reparented to launchd BEFORE a snapshot saw it; the mutant below removes the
# whole kill pass instead, which the suite does catch.
#
# Run directly: scripts/lib/provider-supervisor.mutation.sh

# THE MERGE GATE LEAVES THIS PASS TO THE NIGHTLY (richos/app/scripts/autocheck/README.md): the
# gate runs the suite with RICHOS_MUTATION_PASSES=0; nightly-engine.py runs every pass.
if [ "${RICHOS_MUTATION_PASSES:-}" = 0 ]; then echo "NOT RUN: $(basename "$0"), a mutation pass (RICHOS_MUTATION_PASSES=0, the merge gate; the nightly runs it)"; exit 0; fi

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "provider supervisor: --reap-descendants" "scripts/lib/provider-supervisor.test.sh"

S="scripts/provider-supervisor.py"

mutant nothing-is-killed "R1" "$S" \
    '        for kind, ident in targets:' \
    '        for kind, ident in []:' \
    "F5: a tool shell, its background command and its children would outlive the lead."
mutant sigterm-ignored "R2" "$S" \
    '    signal.signal(signal.SIGTERM, lambda *_a: terminate.append(True))' \
    '    signal.signal(signal.SIGTERM, signal.SIG_IGN)' \
    "the host's quit path sends SIGTERM; ignored, a quit would leave the whole tree running."
mutant provider-exit-not-reaped "R4" "$S" \
    '            if ended:{NL}                running = False' \
    '            if False:{NL}                running = False' \
    "G9: a lead that exits by itself would leave its tool shells, since neither trigger fires."
mutant recycled-group-adopted "R7" "$S" \
    '        members = {pg for pid, (start, pg) in self.procs.items() if pid in table and table[pid][2] == start}' \
    '        members = {pg for pid, (start, pg) in self.procs.items() if pid in table}' \
    "a group id recycled by an unrelated process would be adopted and SIGKILLed."
# The product reap (richos-hq docs/plans/2026-09-27-product-reap-gap-design.md, C3, C4, C7).
mutant grace-ignored "R10" "$S" \
    '                SETTINGS.grace = max(0.0, float(value))' \
    '                float(value)' \
    "C3: the product's zero grace would become the operator's 5 s, past the host's 2 s bound."
mutant options-not-stripped "R11" "$S" \
    '        return operator_main(parent, argv)' \
    '        return operator_main(parent, argv[:1] + sys.argv[1:len(sys.argv) - len(argv)] + argv[1:])' \
    "C7: the supervisor's own options would reach claude's argv, and N1's clause 1 would be false."
mutant pruning-removed "R12" "$S" \
    '        self.prune(table, ours)' \
    '        pass' \
    "C4: a long-lived lease's record would grow with every command it ever ran, once a second."
mutant same-group-counts-as-running "R6" "$S" \
    '                      if pgid != self.own_group and pid != self.provider and pid in table and table[pid][2] == start)' \
    '                      if pid != self.provider and pid in table and table[pid][2] == start)' \
    "G8: a language server or MCP server in the lead's own group would keep every lead from ever being idle."

mutation_end
