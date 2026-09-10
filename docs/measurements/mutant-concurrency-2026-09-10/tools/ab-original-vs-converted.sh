#!/usr/bin/env bash
#
# ORIGINAL vs CONVERTED, without polluting either engine.
#
# THE FIRST VERSION OF THIS SCRIPT WROTE THE ORIGINAL HARNESS BACK INTO
# scripts/hooks/ UNDER A TEMPORARY NAME, so its `$SCRIPT_DIR/../..` would resolve.
# That injected a file into the engine under test, and waiver-repetition.mutation.sh
# NOTICED: its control sandbox went red at "17. an unadopted repository gets no
# notice at all", the harness aborted with "the CONTROL sandbox is already red",
# and the A/B reported the ORIGINAL failing and the CONVERTED passing. The
# conversion was innocent; the measurement instrument was the defect.
#
# So the original side now runs from a PRISTINE CLONE of the branch point, which
# contains no extra file and no conversion, and the converted side runs from the
# worktree. Neither engine is modified by the comparison.
set -u
WT=/Users/alex/ab/richos-wt/zach-opus-mu2
PRISTINE=/private/tmp/claude-501/-Users-alex-ab-femcboost/899d5bee-2ef7-4c2b-8478-3cde1a1aecdf/scratchpad/baseline
REL="$1"
JOBS="${2:-8}"
OUT="$(mktemp -d -t zachab.XXXXXX)"

if [ ! -f "$PRISTINE/engine/$REL" ]; then
    echo "### $REL"; echo "  NO PRISTINE COPY at $PRISTINE/engine/$REL"; exit 1
fi

/bin/bash "$PRISTINE/engine/$REL" >"$OUT/orig.txt" 2>&1
rc1=$?
RICHOS_MUTANT_JOBS="$JOBS" /bin/bash "$WT/engine/$REL" >"$OUT/new.txt" 2>&1
rc2=$?

# Only the appended [duration], the pool's summary line, and the two informational
# lines added on purpose may differ.
norm() {
    sed -E 's/  \[[0-9]+\.[0-9]+s\]$//; s/  \[[0-9]+m[0-9.]+s\]$//' "$1" \
        | grep -vE '^  \[[0-9]+ mutant\(s\)' \
        | grep -vE '^reference sandbox guard never written to|^sandbox guard restored byte-for-byte'
}
norm "$OUT/orig.txt" >"$OUT/orig.norm"
norm "$OUT/new.txt"  >"$OUT/new.norm"

echo "### $REL"
echo "  original(pristine) rc=$rc1    converted(x$JOBS) rc=$rc2"
grep -E '^  \[[0-9]+ mutant\(s\)' "$OUT/new.txt" | sed 's/^/    /'
bad=0
[ "$rc1" = "$rc2" ] || { echo "  *** EXIT CODE DIFFERS: $rc1 vs $rc2"; bad=1; }
if diff -q "$OUT/orig.norm" "$OUT/new.norm" >/dev/null; then
    echo "  VERDICTS IDENTICAL ($(grep -cE '^(  PASS|  FAIL|PROVEN|UNPROVEN)' "$OUT/orig.norm") verdict line(s))"
else
    echo "  *** VERDICTS DIFFER:"
    diff "$OUT/orig.norm" "$OUT/new.norm" | head -40 | sed 's/^/      /'
    echo "  logs: $OUT"
    bad=1
fi
[ "$bad" -eq 0 ] || exit 1
rm -rf "$OUT"
