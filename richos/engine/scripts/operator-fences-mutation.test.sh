#!/usr/bin/env bash
#
# operator-fences-mutation.test.sh: runs scripts/operator-fences.mutation.sh, the
# fence suite's mutation harness (30 mutants over the fence, the lease, merge
# ownership, the launcher, the recorder, the installer, land_lock() and the
# restore intent), as a unit of its own.
#
# WHY A SEPARATE UNIT, when most suites run their harness at their own end: a
# ci-shard unit's deadline is max(900 s, 3 x its measured weight), capped at
# 3600 s (scripts/ci-shard.sh, deadline_for). The fence suite alone measures about
# 320 s under both gits; with its harness appended it ran past its 900 s deadline
# in the proof selection of 2026-09-25 and was killed with no verdict. Two units,
# each weighed in scripts/lib/ci-unit-weights.tsv, get two deadlines that fit
# them, and a harness verdict is never lost to the suite's clock.
#
# Usage: scripts/operator-fences-mutation.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${RICHOS_MUTATION_INNER:-}" ]; then
    echo "operator-fences-mutation: skipped inside a mutant's run (RICHOS_MUTATION_INNER)"
    exit 0
fi
if bash "$SCRIPT_DIR/operator-fences.mutation.sh"; then
    printf '  PASS  M. every rule of operator-fences.test.sh has been watched fail\n'
    exit 0
fi
printf '  FAIL  M. the mutation harness found a property operator-fences.test.sh does not actually prove\n'
exit 1
