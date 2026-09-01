#!/usr/bin/env bash
# Same LaunchServices launch as doubleclick.sh, with one environment variable added, so the
# "the engine directory genuinely is not there" case can be produced on a machine where it IS.
set -uo pipefail
APP="${1:?}"
LABEL="${2:?}"
VAR="${3:?}"
OUT="/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad/dclick-$LABEL.log"
: > "$OUT"

/usr/bin/open -n -g --env "$VAR" --stdout "$OUT" --stderr "$OUT" "$APP"
echo "open exit=$?"

n=0
while [ $n -lt 40 ]; do
    grep -qE "compute lease attached|NO COMPUTE LEASE" "$OUT" 2>/dev/null && break
    n=$((n + 1))
    /bin/sleep 1
done

echo "--- captured after ${n}s ---"
cat "$OUT"
pid="$(/usr/bin/pgrep -n -f "$APP/Contents/MacOS/richos-tauri")"
[ -n "$pid" ] && /bin/kill "$pid" 2>/dev/null && echo "(killed pid $pid)"
exit 0
