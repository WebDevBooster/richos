#!/usr/bin/env bash
# record.sh <ledger> <exit-code> [stdout-payload-file] [sleep-seconds]
# Appends {ts_ms, payload} to the ledger, optionally sleeps, optionally prints a JSON payload, exits with the given code.
LEDGER="$1"; RC="${2:-0}"; OUTFILE="${3:-}"; SLEEP="${4:-0}"
IN="$(cat)"
TS=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '{"ts_ms":%s,"payload":%s}\n' "$TS" "${IN:-null}" >> "$LEDGER"
if [ "$SLEEP" != "0" ]; then sleep "$SLEEP"; fi
if [ -n "$OUTFILE" ] && [ -f "$OUTFILE" ]; then cat "$OUTFILE"; fi
exit "$RC"
