#!/usr/bin/env bash
# Every adopted harness must init BEFORE its first submit and drain AFTER its
# last one. A submit after the drain would go into a pool nobody reads: the
# mutant runs, costs its full suite, and its verdict is discarded.
set -u
ENG=/Users/alex/ab/richos-wt/zach-opus-mu2/engine
cd "$ENG" || exit 2
bad=0
for f in $(find . -name '*.mutation.sh' | LC_ALL=C sort); do
    grep -q 'mut_pool_drain\|mutation_end' "$f" || continue
    init=$(grep -n '^mut_pool_init' "$f" | head -1 | cut -d: -f1)
    drain=$(grep -nE '^mut_pool_drain|^\s*mut_pool_drain' "$f" | head -1 | cut -d: -f1)
    firstsub=$(grep -nE '^mutant\s+\S|^mut_pool_submit |^\s+mut_pool_submit ' "$f" | head -1 | cut -d: -f1)
    lastsub=$(grep -nE '^mutant\s+\S|^mut_pool_submit |^\s+mut_pool_submit ' "$f" | tail -1 | cut -d: -f1)
    # Library-loop harnesses drain inside mutation_end, which is in the lib.
    if [ -z "${drain:-}" ]; then
        if grep -q 'mutation_end' "$f"; then
            drain=$(grep -n 'mutation_end' "$f" | tail -1 | cut -d: -f1)
        else
            printf 'NO-DRAIN      %s\n' "${f#./}"; bad=$((bad+1)); continue
        fi
    fi
    if [ -z "${firstsub:-}" ]; then
        printf 'NO-SUBMITS    %s\n' "${f#./}"; bad=$((bad+1)); continue
    fi
    if [ -n "${init:-}" ] && [ "$init" -gt "$firstsub" ]; then
        printf 'INIT-AFTER-SUBMIT  %s (init@%s firstsub@%s)\n' "${f#./}" "$init" "$firstsub"; bad=$((bad+1))
    fi
    if [ "$drain" -lt "$lastsub" ]; then
        printf 'DRAIN-BEFORE-LAST-SUBMIT  %s (drain@%s lastsub@%s)\n' "${f#./}" "$drain" "$lastsub"
        bad=$((bad+1))
    fi
done
printf 'ordering: %d harness(es) wrong\n' "$bad"
