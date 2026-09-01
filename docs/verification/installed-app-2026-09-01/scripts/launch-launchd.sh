#!/usr/bin/env bash
# A faithful double-click: `open` FORWARDS the caller's environment, so the caller's
# environment is stripped to launchd's first. Verified with `ps eww` on the running process.
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
APP="/Users/alex/Applications/RichOS.app"
OUT="${1:?}"
: > "$OUT"
cd /
bash "$SP/launchd-env.sh" /usr/bin/open --stdout "$OUT" --stderr "$OUT" "$APP"
echo "open exit=$?"
n=0
while [ $n -lt 60 ]; do
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
echo "--- the environment the process actually received ---"
/bin/ps eww -p "$pid" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -E "^(PATH|HOME|USER|LORO_|RICHOS_|TERM_PROGRAM|CLAUDECODE)" | /usr/bin/sort
