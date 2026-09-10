#!/usr/bin/env bash
#
# THE DEGREE IS CHOSEN FROM A MEASUREMENT, not from the core count.
#
# A mutant is a whole shell suite: process spawning, git, python3 and a recursive
# sandbox copy. It neither saturates one core nor scales linearly with them, so
# the useful degree is an empirical question on a 10-core box, and the answer is
# what the default and its cap are set from.
set -u
ENG=/Users/alex/ab/richos-wt/zach-opus-mu2/engine
H="${1:-scripts/hooks/guard-model-ceiling.mutation.sh}"
. "$ENG/scripts/lib/stopwatch.sh"
sw_init

echo "=== degree sweep: $H on $(sysctl -n hw.ncpu) cores ==="
printf '%-8s %12s %10s %10s\n' JOBS WALL SPEEDUP RC
base=0
for j in 1 2 4 6 8 10 12; do
    t0="$(sw_now_ms)"
    RICHOS_MUTANT_JOBS="$j" /bin/bash "$ENG/$H" >/dev/null 2>&1
    rc=$?
    ms=$(( $(sw_now_ms) - t0 ))
    [ "$j" = 1 ] && base="$ms"
    sp="-"
    [ "$ms" -gt 0 ] && [ "$base" -gt 0 ] && sp="$(( base / ms )).$(( (base * 10 / ms) % 10 ))x"
    printf '%-8s %12s %10s %10s\n' "$j" "$(sw_fmt "$ms")" "$sp" "$rc"
done
echo "SWEEP-COMPLETE"
