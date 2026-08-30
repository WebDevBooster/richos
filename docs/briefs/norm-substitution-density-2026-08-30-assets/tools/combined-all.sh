#!/bin/bash
set -uo pipefail
SP="$1"
for RUN in ship bare; do for CH in me others; do
  node "$SP/tools/combined.mjs" $RUN $CH > "$SP/results/log_combined_${RUN}_${CH}.txt" 2>&1
  echo "combined $RUN $CH done"
done; done
echo COMBINED-DONE
