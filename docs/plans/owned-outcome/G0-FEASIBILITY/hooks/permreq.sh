#!/usr/bin/env bash
# permreq.sh <ledger> <sleep-seconds> <mode: deny|fail>
# PermissionRequest hook: records the payload, sleeps, then denies (or fails with exit 1).
LEDGER="$1"; SL="${2:-0}"; MODE="${3:-deny}"
IN="$(cat)"
TS=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '{"ts_ms":%s,"payload":%s}\n' "$TS" "${IN:-null}" >> "$LEDGER"
sleep "$SL"
if [ "$MODE" = "fail" ]; then echo "permreq deliberate failure" >&2; exit 1; fi
printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"G0 probe: denied by PermissionRequest hook"}}}\n'
exit 0
