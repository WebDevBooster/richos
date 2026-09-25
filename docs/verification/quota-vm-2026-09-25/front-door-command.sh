#!/bin/bash
set -euo pipefail
cd /Users/admin/quota-proof/source
. richos/app/scripts/lib/gui-launch.sh
exe=/Users/admin/quota-proof/cache/debug/richos-tauri
identity="$(gui_identity "$exe")"
gui_bundle /Users/admin/quota-proof/RichOS.app "$exe" "${identity%% *}" "${identity##* }"
/usr/libexec/PlistBuddy -c "Add :RichOSSourceCommit string $(git rev-parse HEAD)" /Users/admin/quota-proof/RichOS.app/Contents/Info.plist
set +e
TMPDIR=/Users/admin/quota-proof/tmp bash richos/app/scripts/front-door.test.sh --bundle /Users/admin/quota-proof/RichOS.app --evidence /Users/admin/quota-proof/logs/front-door-evidence > /Users/admin/quota-proof/logs/front-door.log 2>&1
result=$?
printf '%s\n' "$result" > /Users/admin/quota-proof/logs/front-door.exit
tail -40 /Users/admin/quota-proof/logs/front-door.log
exit "$result"
