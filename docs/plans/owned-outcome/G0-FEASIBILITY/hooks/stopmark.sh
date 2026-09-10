#!/usr/bin/env bash
# stopmark.sh <ledger> <markerdir> [exit-code] — records the Stop payload, touches a numbered marker file, exits with code.
LEDGER="$1"; MD="$2"; RC="${3:-0}"; mkdir -p "$MD"
IN="$(cat)"
TS=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '{"ts_ms":%s,"payload":%s}\n' "$TS" "${IN:-null}" >> "$LEDGER"
N=$(ls "$MD" | wc -l | tr -d ' ')
: > "$MD/stop-$((N+1))"
if [ "$RC" = "2" ]; then echo "G0 probe Stop hook: block #$((N+1)) — keep going, reply with the single word CONTINUED" >&2; fi
exit "$RC"
