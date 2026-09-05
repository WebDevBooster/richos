#!/usr/bin/env bash
# Ticks once a second for 40s. The LAST tick recorded says when the platform
# stopped it. Reads NOTHING from stdin, so this measures the registered
# `timeout`, never an unclosed-stdin block.
LOG="$(dirname "${BASH_SOURCE[0]}")/ticks.log"
: > "$LOG"
START=$(python3 -c 'import time;print(time.time())')
echo "START $START pid=$$" >> "$LOG"
for i in $(seq 1 40); do
    sleep 1
    echo "TICK $i elapsed=$(python3 -c "import time;print(round(time.time()-$START,2))")" >> "$LOG"
done
echo "COMPLETED" >> "$LOG"
exit 0
