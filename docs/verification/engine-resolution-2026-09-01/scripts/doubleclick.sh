#!/usr/bin/env bash
# The launch the CEO performs: LaunchServices, not a terminal. `open` hands the process to
# launchd exactly as Finder does — working directory `/`, launchd's environment, none of this
# shell's. Output is captured with open's own --stderr, because a GUI process's stderr goes
# nowhere by default and "I could not see the line" is not evidence either way.
set -uo pipefail
APP="${1:?usage: doubleclick.sh <path to RichOS.app> <label>}"
LABEL="${2:?}"
OUT="/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad/dclick-$LABEL.log"
: > "$OUT"

/usr/bin/open -n -g --stdout "$OUT" --stderr "$OUT" "$APP"
rc=$?
echo "open exit=$rc"

n=0
while [ $n -lt 40 ]; do
    grep -qE "compute lease attached|NO COMPUTE LEASE" "$OUT" 2>/dev/null && break
    n=$((n + 1))
    /bin/sleep 1
done

echo "--- captured after ${n}s ---"
cat "$OUT"
echo "--- cwd of the running process ---"
pid="$(/usr/bin/pgrep -n -f "$APP/Contents/MacOS/richos-tauri")"
if [ -n "$pid" ]; then
    /usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | /usr/bin/tail -1
    /bin/kill "$pid" 2>/dev/null
    echo "(killed pid $pid)"
else
    echo "(process not found — it had already exited)"
fi
