#!/bin/bash
set -uo pipefail
SP="$1"
for CH in me others; do node "$SP/tools/score.mjs" ship $CH > "$SP/results/log_score_ship_$CH.txt" 2>&1; echo "score ship $CH done"; done
for CH in me others; do node "$SP/tools/control.mjs" ship $CH 8 > "$SP/results/log_control_ship_$CH.txt" 2>&1; echo "control ship $CH done"; done
node "$SP/tools/tts-measure.mjs" > "$SP/results/log_tts.txt" 2>&1; echo "tts done"
for CH in me others; do node "$SP/tools/score.mjs" bare $CH > "$SP/results/log_score_bare_$CH.txt" 2>&1; echo "score bare $CH done"; done
echo ALL-SCORED
