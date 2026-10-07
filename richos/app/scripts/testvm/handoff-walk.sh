#!/bin/bash
# handoff-walk.sh — the weekly-switch handoff on the real app, fake Claude, in one guest run.
#
#   run-walk.py --bundle <RichOS.app.zip> --home <empty dir> --engine <engine.tar.gz> \
#     --report <json> -- handoff-walk.sh <out-dir> [two|single]
#
# Plan: richos-hq docs/plans/2026-10-07-weekly-switch-handoff.md §4 round 1.
#   two (default): Account 1 weekly 50, Account 2 weekly 20, RICHOS_TEST_WEEKLY_CUTOFF=1:51. A job
#     with helpers starts and is held open; Account 1's week is then written as 51.
#     PASS: the gate's order reached the helper (calls.log "gate walk-agent-1 exit 2"), the helper
#     ended (the fake's SubagentStop row in the lease's evidence journal), and the next back-end
#     turn ran under Account 2's folder carrying the handoff continuation. No work record says failed.
#   single: one account. The same, except the continuation waits (no turn after the order while
#     Account 1 is at 51) and goes on after the fake's reset (Account 1's week written as 10).
# Needs slices 1-3 of the plan on main (cut-off variable, the gate's order, the host's handoff
# continuation); before them it fails at the order, which is the point.
# run-walk.py passes the VM name first, and quits the app, stops the guest and deletes the clone
# when this returns (CEO §54). FIXTURE-DRIVEN: fake-claude-fill-first.pl answers every `claude`
# call and, while its `agents` file lists helpers, steps each helper through the lease's gate.
# In <out-dir>: 1-panel, 2-two-accounts (two only), 3-job-held, 4-after-order, 5-after-handoff
# (screenshots), calls.log, journal.txt (the lease's evidence journals), records.txt.
# EXIT STATUS: 1 when the setup fails or any capture or check fails (named at the end); 0 only
# when every capture was saved and every check read what it should.
set -u
VM="$1"
S="${2:?usage: handoff-walk.sh <vm> <out-dir> [two|single]}"
MODE="${3:-two}"
case "$MODE" in two|single) ;; *) echo "mode must be two or single" >&2; exit 2 ;; esac
T="$(cd "$(dirname "$0")" && pwd)"
G=/Users/admin/fill-first
mkdir -p "$S"
note() { echo "[walk] $(date -u +%H:%M:%SZ) $*" | tee -a "$S/walk.log"; }
FAILS=()
fail() { note "FAILED: $1"; FAILS+=("$1"); }
setup_failed() { note "FAILED: $1; nothing to walk"; exit 1; }
wait_for() {
  for _ in $(seq 1 30); do
    "$T/ax.sh" "$VM" find --title "$1" --first >/dev/null 2>&1 && return 0
    sleep 2
  done
  note "never appeared: $1"
  return 1
}
# Wait (at most 2 min) until the guest's calls.log has a line matching $1 (extended regex).
wait_calls() {
  for _ in $(seq 1 24); do
    "$T/guest.sh" "$VM" "grep -Eq '$1' $G/calls.log" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
refresh() { "$T/ax.sh" "$VM" click --title 'Refresh' --first || true; }

"$T/guest.sh" "$VM" "mkdir -p $G" || setup_failed "the fixture folder"
"$T/guest.sh" "$VM" --push "$T/fake-claude-fill-first.pl" $G/claude || setup_failed "pushing the fake claude"
"$T/guest.sh" "$VM" "chmod 755 $G/claude; printf '{\"five\":10,\"weekly\":50}' > $G/usage-1.json; touch $G/log-turns; printf 'Mark\n' > $G/agents; printf 'Handed over cleanly.' > $G/reply.txt" \
  || setup_failed "the first usage fixture"
python3 - "$VM" "$T" <<'PY' || setup_failed "relaunching the app with the fake claude and the cut-off"
import sys
sys.path.insert(0, sys.argv[2])
from relaunch import relaunch
print(relaunch(sys.argv[1], environment={'RICHOS_CLAUDE_BIN': '/Users/admin/fill-first/claude',
                                          'RICHOS_TEST_WEEKLY_CUTOFF': '1:51'}))
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
"$T/shot.sh" "$VM" "$S/1-panel.png" || fail "capture 1-panel"

# shellcheck disable=SC2016  # the $(...) is meant to expand in the guest's shell, not here
DATA=""
if [ "$MODE" = two ]; then
  note "Add account: label Work"
  "$T/ax.sh" "$VM" click --title 'Add account' || true
  sleep 2
  "$T/ax.sh" "$VM" 'tell application "System Events" to keystroke "Work"' || true
  sleep 1
  "$T/ax.sh" "$VM" click --title 'Add and sign in' || true
  sleep 4
  # shellcheck disable=SC2016
  DATA=$("$T/guest.sh" "$VM" 'dirname "$(find /Users/admin/testvm -type d -name claude-accounts 2>/dev/null | head -1)"')
  note "app data: $DATA"
  "$T/guest.sh" "$VM" "printf '{\"five\":10,\"weekly\":20}' > \"$DATA/claude-accounts/2/usage.json\"" \
    || fail "Account 2's usage fixture (weekly 20)"
  sleep 6
  refresh
  sleep 6
  "$T/shot.sh" "$VM" "$S/2-two-accounts.png" || fail "capture 2-two-accounts"
  "$T/ax.sh" "$VM" click --title 'Switch to the next account' || true
  sleep 3
else
  # shellcheck disable=SC2016
  DATA=$("$T/guest.sh" "$VM" 'dirname "$(find /Users/admin/testvm -type d -name engine-state 2>/dev/null | head -1)"')
  note "app data: $DATA"
fi

note "close the panel; start a job with one helper, held open"
"$T/ax.sh" "$VM" --key 53 || true
sleep 2
"$T/guest.sh" "$VM" "touch $G/slow" || fail "holding the turn open"
"$T/ax.sh" "$VM" type 'Start the Northwind job and keep Mark on it.' --role AXTextArea --first --replace || true
"$T/ax.sh" "$VM" click --title 'Send' --first || true
sleep 15
"$T/shot.sh" "$VM" "$S/3-job-held.png" || fail "capture 3-job-held"

note "fixture: Account 1's week reaches 51"
"$T/ax.sh" "$VM" click --at 1330,327 || true
sleep 3
"$T/guest.sh" "$VM" "printf '{\"five\":10,\"weekly\":51}' > $G/usage-1.json" \
  || fail "the 51% usage fixture (an order below would not be caused by it)"
sleep 6
refresh
sleep 8
"$T/ax.sh" "$VM" --key 53 || true

note "the order reaches the helper"
if wait_calls 'gate walk-agent-1 exit 2'; then
  note "ok: the gate refused the helper with the order"
else
  fail "the order never reached the helper (no 'gate walk-agent-1 exit 2' in calls.log)"
fi
"$T/shot.sh" "$VM" "$S/4-after-order.png" || fail "capture 4-after-order"
"$T/guest.sh" "$VM" "rm -f $G/slow" || fail "releasing the held turn"
sleep 10

if [ "$MODE" = single ]; then
  note "single account: the continuation waits"
  sleep 20
  "$T/guest.sh" "$VM" "cat $G/calls.log" > "$S/calls-waiting.log" 2>&1 || fail "calls.log while waiting"
  if awk '/gate walk-agent-1 exit 2/ {seen=1; next} seen && / turn / {bad=1} END {exit bad ? 0 : 1}' "$S/calls-waiting.log"; then
    fail "a turn ran after the order while the only account was at its point (the continuation did not wait)"
  else
    note "ok: no turn after the order while the account is at its point"
  fi
  note "the fake's reset: Account 1's week reads 10"
  "$T/guest.sh" "$VM" "printf '{\"five\":10,\"weekly\":10}' > $G/usage-1.json" || fail "the reset fixture"
  sleep 5
  refresh
fi

note "the next back-end turn carries the handoff continuation"
if [ "$MODE" = two ]; then
  WHERE='claude-accounts/2'
else
  WHERE='account-1'
fi
if wait_calls "$WHERE turn .*[Hh]andoff|$WHERE turn .*[Hh]anded"; then
  note "ok: a turn under $WHERE carries the handoff continuation"
else
  fail "no turn under $WHERE with the handoff continuation after the order"
fi
sleep 5
"$T/shot.sh" "$VM" "$S/5-after-handoff.png" || fail "capture 5-after-handoff"

"$T/guest.sh" "$VM" "cat $G/calls.log" > "$S/calls.log" 2>&1 || fail "calls.log"
"$T/guest.sh" "$VM" "for f in \"$DATA\"/engine-state/evidence/*/callbacks.jsonl; do echo \"== \$f\"; cat \"\$f\"; done" > "$S/journal.txt" 2>&1 \
  || fail "the evidence journals"
"$T/guest.sh" "$VM" "ls -R \"$DATA/engine-state/handoffs\" 2>&1; cat \"$DATA/claude-accounts.json\" 2>&1" > "$S/records.txt" 2>&1 \
  || fail "the app's records"

# The checks, on what was saved. The order came before the continuation, the helper ended, and
# the order of lines in calls.log is the order of events.
if awk '/gate walk-agent-1 exit 2/ {g=NR} / turn / && g && NR>g && $0 ~ WHERE {t=1} END {exit t ? 0 : 1}' WHERE="$WHERE" "$S/calls.log"; then
  note "ok: a turn under $WHERE follows the order"
else
  fail "calls.log has no turn under $WHERE after the order"
fi
if grep -q '"hook_event_name":"SubagentStop"' "$S/journal.txt" && grep -q 'walk-agent-1' "$S/journal.txt"; then
  note "ok: the helper ended (SubagentStop in the lease's journal)"
else
  fail "no SubagentStop for walk-agent-1 in the evidence journals"
fi
# Never said failed: a work record in the app's data that holds a failed state.
if "$T/guest.sh" "$VM" "grep -rliE '\"(state|status)\" *: *\"failed\"' \"$DATA\" --include=*.json 2>/dev/null | head -3" | grep -q .; then
  fail "a work record says failed"
else
  note "ok: no work record says failed"
fi
if [ "$MODE" = two ] && ! grep -q 'claude-accounts/2 ' "$S/calls.log"; then
  fail "Account 2's folder never ran a claude call"
fi

if [ "${#FAILS[@]}" -gt 0 ]; then
  note "done, with ${#FAILS[@]} failed step(s): $(printf '%s; ' "${FAILS[@]}")"
  exit 1
fi
note "done"
exit 0
