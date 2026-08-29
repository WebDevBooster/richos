#!/bin/bash
#
# Turn the correction flywheel until it stops, and print the round-by-round table.
#
# Each round: the CEO corrects the first name he would see rendered wrong in each channel and
# nothing else; every ask that raises is confirmed; the learned vocabulary is applied to EVERY
# channel including the ones that taught it nothing. The next round starts from that output, which
# is what a real second look at a transcript would be. It terminates when a round finds nothing.
#
# usage:
#   rounds.sh <workDir> <libDir> <harnessToolsDir> [rounds]
#
#     workDir           holds corpus-built/ (the synthesized corpus) and runs/ (the decodes). The
#                       baseline decode must already be there under the tag `base` — produce it with
#                       the short-call harness's own tools/measure.mjs.
#     libDir            richos/tools/richos-service/lib
#     harnessToolsDir   the short-call WER harness's tools/ (for consistency.mjs and wer.mjs)
#     rounds            how many to attempt (default 4; on this corpus round 4 is already a no-op)
#
# Every sentence involved is invented — see the corpus's own note.
set -eu

WORK="${1:?usage: rounds.sh <workDir> <libDir> <harnessToolsDir> [rounds]}"
LIB="${2:?libDir required}"
HARNESS="${3:?harnessToolsDir required}"
N="${4:-4}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C="$WORK/corpus-built"
R="$WORK/runs"
[ -f "$R/results-base.json" ] || { echo "no baseline decode at $R/results-base.json — run the harness's measure.mjs with --tag base first" >&2; exit 2; }

export RICHOS_WER_TOOLS="$HARNESS"

prev=base
for n in $(seq 1 "$N"); do
  node "$HERE/flywheel.mjs" "$LIB" "$C" "$R" "$prev" large-v3-turbo 0 "r$n" > "$R/round-$n.log" 2>&1
  node "$HARNESS/consistency.mjs" "$C" "$R" "r$n" > /dev/null 2>&1
  prev="r$n"
done

consistency() { sed -n '5p' "$1" | awk '{print $4" of "$3" names spelled consistently"}'; }

echo "=================== NAME CONSISTENCY, ROUND BY ROUND ==================="
printf '%-40s %s\n' "round 0  (shipped -mc 0, no vocabulary)" "$(consistency "$R/consistency-base.txt")"
for n in $(seq 1 "$N"); do
  printf '%-40s %s\n' "round $n" "$(consistency "$R/consistency-r$n.txt")"
done

echo
echo "=================== WHAT EACH ROUND COST HIM, AND BOUGHT ==================="
printf '%-8s %-14s %-10s %s\n' round corrections learned WER
printf '%-8s %-14s %-10s %s\n' 0 - 0 "$(grep -o 'before [0-9.]*%' "$R/round-1.log" | head -1 | awk '{print $2}')"
for n in $(seq 1 "$N"); do
  a=$(grep -c 'ASKED ' "$R/round-$n.log" || true)
  l=$(grep -o 'LEARNED [0-9]*' "$R/round-$n.log" | awk '{print $2}')
  w=$(grep -o 'after [0-9.]*%' "$R/round-$n.log" | head -1 | awk '{print $2}')
  printf '%-8s %-14s %-10s %s\n' "$n" "$a" "$l" "$w"
done

echo
echo "=================== WHAT IS STILL INCONSISTENT ==================="
for n in $(seq 1 "$N"); do
  echo "round $n:"
  sed -n '7,20p' "$R/consistency-r$n.txt" | sed 's/^/  /'
done
