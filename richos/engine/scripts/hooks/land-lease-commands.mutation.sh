#!/usr/bin/env bash
#
# land-lease-commands.mutation.sh: PROVES guard-land-lease-commands.test.sh WOULD
# CATCH THE OPERATOR FENCE'S EARLY BASH CHECK GOING WRONG (spec r3 e7 item 1;
# Frank G1 points 2 and 3; the measured additions of reset and merge --abort).
# Each mutant removes ONE property from a throwaway copy of the engine and
# demands that the NAMED case go red. The loop is scripts/lib/mutation-harness.sh.
#
# Run directly: scripts/hooks/land-lease-commands.mutation.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the operator fence's early Bash check" "scripts/hooks/guard-land-lease-commands.test.sh"

L="scripts/lib/operator_fences.py"
H="scripts/hooks/guard-land-lease-commands.sh"

mutant prefilter-drops-commit "E1 " "$H" \
    '    *cherry-pick*|*revert*|*" am"*|*rebase*|*stash*|*commit*|*reset*|*--abort*|*--quit*) ;;' \
    '    *cherry-pick*) ;;' \
    "the hook would return before the check for a commit, the most common write into a shared checkout."
mutant holder-never-authorized "E2 " "$L" \
    '        ok, lease = authorized(Files(conf), chain)' \
    '        ok, lease = False, None' \
    "the lease holder's own land would be refused by its own early check."
mutant path-prefix-not-checkout "E3 " "$L" \
    '        if not paths or not paths["main"] or paths["gitdir"] != paths["common"]:' \
    '        if not paths or not paths["main"]:' \
    "G1 point 3: every commit a teammate makes in a femcboost native worktree would be refused."
mutant cd-not-tracked "E4 " "$L" \
    '        if words[0] == "cd":' \
    '        if False:' \
    "the habitual 'cd <main checkout> && git ...' would escape the check."
mutant reset-not-refused "E6 " "$L" \
    'TEXT_VERBS = ("cherry-pick", "revert", "am", "rebase", "stash", "commit", "reset", "merge")' \
    'TEXT_VERBS = ("cherry-pick", "revert", "am", "rebase", "stash", "commit", "merge")' \
    "measured: a refused reset --hard has already rewritten the shared tree, so only this check stops it."
mutant merge-abort-not-refused "E6 " "$L" \
    '        if sub == "merge" and not any(a in ("--abort", "--quit") for a in args):' \
    '        if sub == "merge":' \
    "measured: a refused merge --abort has already discarded the holder's staged resolution."
mutant switch-ignored "E8 " "$L" \
    '        if not fenced(conf):{NL}            continue{NL}        chain = ancestors() if chain is None else chain' \
    '        if conf is None:{NL}            continue{NL}        chain = ancestors() if chain is None else chain' \
    "G12: with the switch off the check would still refuse, changing his terminal before the fence is ever on."

mutation_end
