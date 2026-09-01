#!/usr/bin/env bash
# LaunchServices launch, exactly as a Finder double-click: cwd `/`, launchd's environment.
set -uo pipefail
APP="${1:?}"
OUT="${2:?}"
: > "$OUT"
/usr/bin/open -n --stdout "$OUT" --stderr "$OUT" "$APP"
echo "open exit=$?"
n=0
while [ $n -lt 40 ]; do
    grep -qE "compute lease attached|NO COMPUTE LEASE" "$OUT" 2>/dev/null && break
    n=$((n + 1)); /bin/sleep 1
done
/bin/sleep 4
echo "--- boot log (after ${n}s) ---"
cat "$OUT"
pid="$(/usr/bin/pgrep -n -f "$APP/Contents/MacOS/richos-tauri")"
echo "--- pid: $pid ---"
echo "--- working directory of the running process ---"
/usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | /usr/bin/tail -1
