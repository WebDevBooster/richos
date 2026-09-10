#!/usr/bin/env bash
#
# THE ACCEPTANCE MEASUREMENT: per-section wall clock, BEFORE and AFTER, as a pair.
#
# The criterion is per SCOPED UNIT, not per full pass, because the binding
# constraint is the 600s per-check tool ceiling rather than total wall clock. A
# section that cannot finish inside the cap converts into a background run plus a
# poll loop plus a model turn per re-issue.
#
# BEFORE runs from a pristine clone at 437f0134 (the timing commit, no
# concurrency); AFTER runs from the worktree. The two run BACK TO BACK per
# section so a change in machine load moves both members of a pair together
# rather than one of them.
set -u
SC=/private/tmp/claude-501/-Users-alex-ab-femcboost/899d5bee-2ef7-4c2b-8478-3cde1a1aecdf/scratchpad
BEFORE_ENG="$SC/baseline/engine"
AFTER_ENG=/Users/alex/ab/richos-wt/zach-opus-mu2/engine
OUT="$SC/zach-section-results"
mkdir -p "$OUT"

. "$AFTER_ENG/scripts/lib/stopwatch.sh"
sw_init

SECTIONS="${*:-IL CL RI WTR WTI MF SA MC6 Q Qscope}"

printf '%-8s %12s %12s %8s  %s\n' SECTION BEFORE AFTER SPEEDUP VERDICT
printf '%-8s %12s %12s %8s  %s\n' ------- ------ ----- ------- -------
for s in $SECTIONS; do
    b0="$(sw_now_ms)"
    ( cd "$BEFORE_ENG" && /bin/bash scripts/hooks/contract-integrity.test.sh --only "$s" ) \
        >"$OUT/before.$s.log" 2>&1
    brc=$?
    bms=$(( $(sw_now_ms) - b0 ))

    a0="$(sw_now_ms)"
    ( cd "$AFTER_ENG" && /bin/bash scripts/hooks/contract-integrity.test.sh --only "$s" ) \
        >"$OUT/after.$s.log" 2>&1
    arc=$?
    ams=$(( $(sw_now_ms) - a0 ))

    # The cases each side named, so "same named cases" is checked and not assumed.
    grep -oE '^  (PASS|FAIL)  [^ ]+' "$OUT/before.$s.log" | sed 's/^  //' | LC_ALL=C sort >"$OUT/before.$s.cases"
    grep -oE '^  (PASS|FAIL)  [^ ]+' "$OUT/after.$s.log"  | sed 's/^  //' | LC_ALL=C sort >"$OUT/after.$s.cases"

    verdict=""
    [ "$brc" = "$arc" ] || verdict="$verdict RC:$brc->$arc"
    if ! diff -q "$OUT/before.$s.cases" "$OUT/after.$s.cases" >/dev/null; then
        verdict="$verdict CASES-DIFFER"
    fi
    [ "$arc" = 3 ] || verdict="$verdict NOT-EXIT-3"
    [ "$ams" -le 300000 ] || verdict="$verdict OVER-300s"
    [ -n "$verdict" ] || verdict="ok rc=$arc $(wc -l < "$OUT/after.$s.cases" | tr -d ' ') cases"

    sp="-"
    [ "$ams" -gt 0 ] && sp="$(( bms / ams )).$(( (bms * 10 / ams) % 10 ))x"
    printf '%-8s %12s %12s %8s  %s\n' "$s" "$(sw_fmt "$bms")" "$(sw_fmt "$ams")" "$sp" "$verdict"
done
echo "SECTIONS-COMPLETE"
