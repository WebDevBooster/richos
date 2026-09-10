#!/usr/bin/env bash
# md-filter.sh <ledger> <mode: ok|fail|hang>
# MessageDisplay filter: records every delta; in ok mode replaces any delta containing "?" with a withheld marker.
LEDGER="$1"; MODE="${2:-ok}"
IN="$(cat)"
TS=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '{"ts_ms":%s,"payload":%s}\n' "$TS" "${IN:-null}" >> "$LEDGER"
case "$MODE" in
  fail) echo "md-filter deliberate failure" >&2; exit 1 ;;
  hang) sleep 20; exit 0 ;;
esac
python3 - "$IN" <<'PY'
import json,sys
p=json.loads(sys.argv[1]); d=p.get("delta","")
if "?" in d:
    out={"hookSpecificOutput":{"hookEventName":"MessageDisplay","displayContent":"[ROUTINE QUESTION WITHHELD BY G0 FILTER]\n"}}
    print(json.dumps(out))
PY
exit 0
