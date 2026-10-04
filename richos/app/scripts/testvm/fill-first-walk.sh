#!/bin/bash
# fill-first-walk.sh — the fill-first check on the real app, in one guest run.
#
#   run-walk.py --bundle <RichOS.app.zip> --home <empty dir> --engine <engine.tar.gz> \
#     --report <json> -- fill-first-walk.sh <out-dir>
#
# run-walk.py passes the VM name first, and quits the app, stops the guest and deletes the
# clone when this returns (CEO §54). FIXTURE-DRIVEN: fake-claude-fill-first.pl answers every
# call the app makes to `claude`, with per-account figures from files this script writes, so
# no real Claude account is read, signed in or switched. It captures, in <out-dir>:
#   1  the quota panel with Account 1 as today
#   2a Add account's label field; 2b-folder-created.txt the new account folder and list
#   2c the two account rows
#   3  the Pause / Switch setting on Switch
#   4  the panel after Account 1's five-hour window reads 95%: the account in use moved
#   5  the one-line switch notice in the conversation
#   6  a turn after the switch; calls.log shows which folder each `claude` ran under
# Plan: richos-hq docs/plans/2026-10-04-multi-subscription-fill-first.md §15.
set -u
VM="$1"
S="${2:?usage: fill-first-walk.sh <vm> <out-dir>}"
T="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$S"
note() { echo "[walk] $(date -u +%H:%M:%SZ) $*" | tee -a "$S/walk.log"; }
wait_for() {
  for _ in $(seq 1 30); do
    "$T/ax.sh" "$VM" find --title "$1" --first >/dev/null 2>&1 && return 0
    sleep 2
  done
  note "never appeared: $1"
  return 1
}

"$T/guest.sh" "$VM" 'mkdir -p /Users/admin/fill-first'
"$T/guest.sh" "$VM" --push "$T/fake-claude-fill-first.pl" /Users/admin/fill-first/claude
"$T/guest.sh" "$VM" 'chmod 755 /Users/admin/fill-first/claude; printf "{\"five\":40,\"weekly\":30}" > /Users/admin/fill-first/usage-1.json'
python3 - "$VM" "$T" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from relaunch import relaunch
print(relaunch(sys.argv[1], environment={'RICHOS_CLAUDE_BIN': '/Users/admin/fill-first/claude'}))
PY

wait_for 'Not now' || true
"$T/ax.sh" "$VM" click --title 'Not now' --first || true
wait_for 'Add this company' || true
sleep 2
for attempt in 1 2 3; do
  "$T/ax.sh" "$VM" type 'Northwind Traders' --role AXTextField --first --replace || true
  sleep 1
  "$T/ax.sh" "$VM" click --title 'Add this company' || true
  sleep 6
  "$T/ax.sh" "$VM" find --title 'Add this company' --first >/dev/null 2>&1 || break
  note "company not added yet (attempt $attempt)"
done

note "technical view on"
"$T/ax.sh" "$VM" click --title 'Settings' --role AXPopUpButton || true
sleep 2
"$T/ax.sh" "$VM" click --at 1492,284 || true
sleep 2
"$T/ax.sh" "$VM" click --title 'Turn it on' || true
sleep 2

note "open the quota panel"
"$T/ax.sh" "$VM" click --at 1330,327 || true
sleep 5
"$T/shot.sh" "$VM" "$S/1-panel-account-1-as-today.png"

note "Add account: label Work"
"$T/ax.sh" "$VM" click --title 'Add account' || true
sleep 2
"$T/ax.sh" "$VM" 'tell application "System Events" to keystroke "Work"' || true
sleep 1
"$T/shot.sh" "$VM" "$S/2a-add-account-form.png"
"$T/ax.sh" "$VM" click --title 'Add and sign in' || true
sleep 4
# shellcheck disable=SC2016  # the $(...) is meant to expand in the guest's shell, not here
DATA=$("$T/guest.sh" "$VM" 'dirname "$(find /Users/admin/testvm -type d -name claude-accounts 2>/dev/null | head -1)"')
note "app data: $DATA"
"$T/guest.sh" "$VM" "ls -la \"$DATA/claude-accounts\" \"$DATA/claude-accounts/2\"; cat \"$DATA/claude-accounts.json\"" > "$S/2b-folder-created.txt" 2>&1
sleep 6
"$T/ax.sh" "$VM" click --title 'Refresh' --first || true
sleep 6
"$T/shot.sh" "$VM" "$S/2c-two-accounts.png"

note "the setting: Switch to the next account"
"$T/ax.sh" "$VM" click --title 'Switch to the next account' || true
sleep 3
"$T/shot.sh" "$VM" "$S/3-setting-switch.png"

note "fixture: Account 1 five-hour window at 95%"
"$T/guest.sh" "$VM" 'printf "{\"five\":95,\"weekly\":30}" > /Users/admin/fill-first/usage-1.json'
sleep 6
"$T/ax.sh" "$VM" click --title 'Refresh' --first || true
sleep 8
"$T/shot.sh" "$VM" "$S/4-panel-after-switch.png"
"$T/guest.sh" "$VM" "cat \"$DATA/claude-accounts.json\"" > "$S/4-accounts-after-switch.txt" 2>&1

note "close the panel; the one-line notice in the conversation"
"$T/ax.sh" "$VM" --key 53 || true
sleep 3
"$T/shot.sh" "$VM" "$S/5-conversation-notice.png"

note "a turn after the switch"
"$T/ax.sh" "$VM" type 'Which account answers this?' --role AXTextArea --first --replace || true
"$T/ax.sh" "$VM" click --title 'Send' --first || true
sleep 15
"$T/shot.sh" "$VM" "$S/6-turn-after-switch.png"
"$T/guest.sh" "$VM" 'cat /Users/admin/fill-first/calls.log' > "$S/calls.log" 2>&1
note "done"
exit 0
