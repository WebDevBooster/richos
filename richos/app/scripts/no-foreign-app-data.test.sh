#!/usr/bin/env bash
#
# no-foreign-app-data.test.sh: THE APP NEVER READS ANOTHER APP'S DATA.
#
# The product rule, CEO 2026-09-25: a regular RichOS user is never asked "RichOS would
# like to access data from other apps". macOS shows that prompt when a process reads
# another app's sandboxed data, or walks a folder that holds it (the home folder, its
# Library). Anything RichOS.app starts is attributed to RichOS, so the rule covers the app
# and every helper it runs. On this Mac the same prompt appeared as "python3.14" because
# the engine's disk watchdog walked that data (private record:
# richos-hq/docs/verification/2026-09-25-app-data-prompts/README.md). The engine holds
# itself to the rule in richos/engine/scripts/no-foreign-app-data.test.sh. This suite holds
# the app's shipped source, its build and QA scripts, and richos/tools to it, with the
# same checker, so there is one rule and not two.
#
#   A1  the shipped app source (src-tauri, crates, ui) reads no other app's data
#   A2  the app's scripts and richos/tools read none either (test suites excluded: they
#       build their fakes in sandboxes)
#   A3  POSITIVE PROBE: a copy of the app's own startup-log path, retargeted into another
#       app's container folder, is REFUSED, and the real path beside it is not
#
# run-tests: inputs richos/app/scripts/no-foreign-app-data.test.sh richos/engine/scripts/lib/foreign_app_data.py richos/app/src-tauri richos/app/crates richos/app/ui richos/app/scripts richos/tools
# run-tests: covers -
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$DIR/.." && pwd)"
RICHOS="$(cd "$APP/.." && pwd)"
CHECK="$RICHOS/engine/scripts/lib/foreign_app_data.py"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

[ -f "$CHECK" ] || { echo "no-foreign-app-data.test.sh: no $CHECK, refusing to report a result." >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/no-foreign-app-data-app.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

echo "=== no-foreign-app-data (app) ==="

out="$(python3 "$CHECK" scan --exclude-tests "$APP/src-tauri/src" "$APP/crates" "$APP/ui" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "A1  the shipped app source reads no other app's data"
else
    bad "A1  the shipped app source would prompt for other apps' data (rc=$rc)" "$(printf '%s' "$out" | head -5)"
fi

out="$(python3 "$CHECK" scan --exclude-tests "$APP/scripts" "$RICHOS/tools" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "A2  the app's scripts and richos/tools read no other app's data"
else
    bad "A2  a script would prompt for other apps' data (rc=$rc)" "$(printf '%s' "$out" | head -5)"
fi

mkdir -p "$WORK/bad" "$WORK/good"
# startup_alert.rs builds ~/Library/Logs/RichOS/startup.log exactly like this.
printf '%s\n' '        Some(home) => home.join("Library").join("Logs").join("RichOS").join("startup.log"),' >"$WORK/good/startup_alert.rs"
printf '%s\n' '        Some(home) => home.join("Library").join("Containers").join("com.apple.mail"),' >"$WORK/bad/startup_alert.rs"  # foreign-app-data-exempt: the planted defect this case must see
python3 "$CHECK" scan "$WORK/bad" >/dev/null 2>&1; rc_bad=$?
python3 "$CHECK" scan "$WORK/good" >/dev/null 2>&1; rc_good=$?
if [ "$rc_bad" -eq 1 ] && [ "$rc_good" -eq 0 ]; then
    ok "A3  POSITIVE PROBE: a path into another app's container is refused; the app's own log path is not"
else
    bad "A3  the checker cannot tell the two apart (container rc=$rc_bad, own log rc=$rc_good)"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
