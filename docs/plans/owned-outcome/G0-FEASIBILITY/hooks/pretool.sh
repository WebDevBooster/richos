#!/usr/bin/env bash
# pretool.sh <ledger> <decision: deny|allow|fail|none> [sleep-seconds]
# PreToolUse hook: records the payload and returns the requested decision.
LEDGER="$1"; DEC="${2:-none}"; SL="${3:-0}"
IN="$(cat)"
TS=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '{"ts_ms":%s,"payload":%s}\n' "$TS" "${IN:-null}" >> "$LEDGER"
sleep "$SL"
case "$DEC" in
  deny)  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"G0 probe: routine question refused by PreToolUse; decide it yourself and continue"}}\n' ;;
  allow) printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"G0 probe: hook allow"}}\n' ;;
  fail)  echo "pretool deliberate failure" >&2; exit 1 ;;
esac
exit 0
