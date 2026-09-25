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
    '            if any(pg == pgid and pid in table and table[pid][2] == start' \
    '            if any(pg == pgid and pid in table' \
    "a group id recycled by an unrelated process would be adopted and SIGKILLed."
mutant same-group-counts-as-running "R6" "$S" \
    '                      if pgid != self.own_group and pid != self.provider and pid in table and table[pid][2] == start)' \
    '                      if pid != self.provider and pid in table and table[pid][2] == start)' \
    "G8: a language server or MCP server in the lead's own group would keep every lead from ever being idle."

mutation_end
