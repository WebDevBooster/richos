#!/bin/bash
# handoff-walk.sh — the weekly-switch handoff on the real app, fake Claude, in one guest run.
#
#   run-walk.py --bundle <RichOS.app.zip> --home <empty dir> --engine <engine.tar.gz> \
#     --report <json> -- handoff-walk.sh <out-dir> [two|single]
#
# Plan: richos-hq docs/plans/2026-10-07-weekly-switch-handoff.md §4 round 1.
#   two (default): Account 1 weekly 50, Account 2 weekly 20, RICHOS_TEST_WEEKLY_CUTOFF=1:51. The
#     front desk writes a job down; the back end launches one helper, which keeps stepping
#     through the app's gate after the back end's turn ends. Account 1's week is then written as 51.
#     PASS: the gate's order reached the helper (calls.log "gate work-agent-1 exit 2 order"), the helper
#     ended (its SubagentStop row in the back end's evidence journal), and the next back-end turn
#     ran under Account 2's folder carrying the handoff continuation. No work record says failed.
#   single: one account. The same, except the continuation waits (no back-end turn after the order
#     while Account 1 is at 51) and goes on after the fake's reset (Account 1's week written as 10).
#
# WHY THE JOB IS THE BACK END'S (round 1, 2026-10-07). The handoff continuation is the work host's
# (work_host.rs continuation_after_a_helper_ended), so the helper has to be a back-end helper of a
# job the front desk wrote down. The first version put the helper on the front desk's own lease,
# where the order reaches it but no continuation ever can (walk walk-1db6a7b8afee). The fake now
# writes the job down through the app's own register (`register`) and launches the helper on the
# back end (`work-agents`); fake-claude-fill-first.pl's header says how.
#
# run-walk.py passes the VM name first, and quits the app, stops the guest and deletes the clone
# when this returns (CEO §54). In <out-dir>: 1-panel, 2-two-accounts (two only), 3-job-running,
# 4-after-order, 5-after-handoff (screenshots), calls.log, journal.txt (the evidence journals),
# records-after-order.txt and records.txt (the work records, the handoff markers, the accounts).
# EXIT STATUS: 1 when the setup fails or any capture or check fails (named at the end); 0 only
# when every capture was saved and every check read what it should.
set -u
VM="$1"
S="${2:?usage: handoff-walk.sh <vm> <out-dir> [two|single]}"
MODE="${3:-two}"
case "$MODE" in two|single) ;; *) echo "mode must be two or single" >&2; exit 2 ;; esac
T="$(cd "$(dirname "$0")" && pwd)"
G=/Users/admin/fill-first
JOB='Start the Northwind job and keep Mark on it.'
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
# Wait (at most $2 x 5 s, default 2 min) until the guest's calls.log has a line matching $1
# (extended regex).
wait_calls() {
  for _ in $(seq 1 "${2:-24}"); do
    "$T/guest.sh" "$VM" "grep -Eq '$1' $G/calls.log" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
# The quota panel is the Settings menu's "Claude Code quota" row (settings-button.js
# set-quota-open). The first time the menu is still open from the technical view; after that it
# is opened again (a coordinate click after the panel was closed hit nothing: walk
# walk-1fa6eaae9f14 wrote 51 and no quota check followed, so the order never came).
# The Settings button sometimes offers only AXShowMenu (walk walk-b2f694786f61, the reset step:
# "noaction"), so a refused press is retried as a click on its center (pos 1485,111 size 40).
panel() {
  local try
  for try in 1 2; do
    if ! "$T/ax.sh" "$VM" click --id set-quota-open >/dev/null 2>&1; then
      "$T/ax.sh" "$VM" --key 53 >/dev/null 2>&1 || true
      sleep 1
      "$T/ax.sh" "$VM" click --title 'Settings' --role AXPopUpButton || "$T/ax.sh" "$VM" click --at 1505,131 || true
      sleep 2
      "$T/ax.sh" "$VM" click --id set-quota-open || true
    fi
    sleep 3
    "$T/ax.sh" "$VM" find --id quota-refresh >/dev/null 2>&1 && return 0
    note "the quota panel did not open (try $try)"
  done
  "$T/shot.sh" "$VM" "$S/panel-not-open-$(date -u +%H%M%S).png" || true
  return 1
}
close_panel() { "$T/ax.sh" "$VM" --key 53 || true; sleep 2; }
refresh() { "$T/ax.sh" "$VM" click --id quota-refresh || true; }
# The work records (engine-state/assignments, one JSON per job: state and detail), the gate's
# handoff markers (engine-state/handoffs) and the accounts file.
records() {
  "$T/guest.sh" "$VM" "find \"$DATA/engine-state/assignments\" \"$DATA/engine-state/handoffs\" -type f -name '*.json' 2>/dev/null | sort | while IFS= read -r f; do echo \"== \$f\"; cat \"\$f\"; echo; done; echo '== claude-quota.json'; cat \"$DATA/engine-state/claude-quota.json\" 2>&1; echo; echo '== claude-accounts.json'; cat \"$DATA/claude-accounts.json\" 2>&1; true" > "$1" 2>&1
}
# Everything the checks read, saved into <out-dir>.
collect() {
  "$T/guest.sh" "$VM" "cat $G/calls.log" > "$S/calls.log" 2>&1 || fail "calls.log"
  "$T/guest.sh" "$VM" "find \"$DATA/engine-state/evidence\" -type f -name callbacks.jsonl 2>/dev/null | sort | while IFS= read -r f; do echo \"== \$f\"; cat \"\$f\"; done" > "$S/journal.txt" 2>&1 \
    || fail "the evidence journals"
  records "$S/records.txt" || fail "the app's records"
}
# A step everything after it depends on failed: save what there is and end now, rather than
# hold the guest through waits that cannot pass (walk walk-4ec19e8a365e held it 11 more minutes).
stop_early() {
  fail "$1; nothing after it can pass"
  collect
  note "done, with ${#FAILS[@]} failed step(s): $(printf '%s; ' "${FAILS[@]}")"
  exit 1
}

"$T/guest.sh" "$VM" "mkdir -p $G" || setup_failed "the fixture folder"
"$T/guest.sh" "$VM" --push "$T/fake-claude-fill-first.pl" $G/claude || setup_failed "pushing the fake claude"
"$T/guest.sh" "$VM" "chmod 755 $G/claude; printf '{\"five\":10,\"weekly\":50}' > $G/usage-1.json; touch $G/log-turns; printf 'Mark\n' > $G/work-agents; printf '%s\n' '$JOB' > $G/register; printf 'Handed over cleanly.' > $G/reply.txt" \
  || setup_failed "the first usage fixture"
python3 - "$VM" "$T" <<'PY' || setup_failed "relaunching the app with the fake claude and the cut-off"
import sys
sys.path.insert(0, sys.argv[2])
from relaunch import relaunch
print(relaunch(sys.argv[1], environment={'RICHOS_CLAUDE_BIN': '/Users/admin/fill-first/claude',
                                          'RICHOS_TEST_WEEKLY_CUTOFF': '1:51'}))
PY

wait_for 'Not now' || true
# Since the setup essentials (e0a346d76) a guest without the video tools first gets the setup
# sheet ("There's one thing I need on this Mac"), and then the memory question: each says Not
# now (main.js, WHAT A FIRST RUN ASKS). One press answered only the first, and the memory
# question blocked every later step (walk walk-7de64f57aafc, candidate 43).
first_run_not_now() {
  for _ in 1 2 3; do
    "$T/ax.sh" "$VM" find --title 'Add this company' --first >/dev/null 2>&1 && return 0
    "$T/ax.sh" "$VM" click --title 'Not now' --first >/dev/null 2>&1 || true
    sleep 4
  done
}
first_run_not_now
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
panel
sleep 2
"$T/shot.sh" "$VM" "$S/1-panel.png" || fail "capture 1-panel"

# shellcheck disable=SC2016  # the $(...) is meant to expand in the guest's shell, not here
DATA=$("$T/guest.sh" "$VM" 'd="$(find /Users/admin/testvm -type d -name engine-state 2>/dev/null | head -1)"; [ -n "$d" ] && dirname "$d"')
[ -n "$DATA" ] || setup_failed "the app's data folder (no engine-state in the guest)"
note "app data: $DATA"
if [ "$MODE" = two ]; then
  # The panel's own controls, by their DOM ids (ui/quota.js): the button reads "+ Add account",
  # so the title 'Add account' matched nothing (walk walk-1db6a7b8afee).
  note "Add account: Home now, Work new"
  "$T/ax.sh" "$VM" click --id quota-account-start || true
  sleep 2
  "$T/ax.sh" "$VM" type 'Home' --id quota-account-current --replace || true
  "$T/ax.sh" "$VM" type 'Work' --id quota-account-label --replace || true
  "$T/ax.sh" "$VM" click --id quota-account-add || true
  added=""
  for _ in $(seq 1 15); do
    "$T/guest.sh" "$VM" "test -d \"$DATA/claude-accounts/2\"" >/dev/null 2>&1 && { added=1; break; }
    sleep 2
  done
  [ -n "$added" ] || setup_failed "the second account (no $DATA/claude-accounts/2)"
  "$T/guest.sh" "$VM" "printf '{\"five\":10,\"weekly\":20}' > \"$DATA/claude-accounts/2/usage.json\"" \
    || fail "Account 2's usage fixture (weekly 20)"
  sleep 4
  refresh
  sleep 6
  "$T/shot.sh" "$VM" "$S/2-two-accounts.png" || fail "capture 2-two-accounts"
fi

note "close the panel; ask for the job"
close_panel
"$T/ax.sh" "$VM" type "$JOB" --role AXTextArea --first --replace || true
"$T/ax.sh" "$VM" click --title 'Send' --first || true
if wait_calls 'register ok'; then
  note "ok: the front desk wrote the job down"
else
  stop_early "the front desk never wrote the job down (no 'register ok' in calls.log)"
fi
# Any step before the cut-off: the gate itself admits it, and the hook behind the gate may still
# refuse the fake's stand-in command (its words are on the line). Neither is the order.
if wait_calls 'gate work-agent-1 exit'; then
  note "ok: the back end's helper is running and stepping through the gate"
else
  stop_early "the back end's helper never stepped through the gate"
fi
if "$T/guest.sh" "$VM" "grep -q 'gate work-agent-1 exit 2 order' $G/calls.log" >/dev/null 2>&1; then
  fail "the helper was ordered before the cut-off was reached"
fi
"$T/shot.sh" "$VM" "$S/3-job-running.png" || fail "capture 3-job-running"

note "fixture: Account 1's week reaches 51"
"$T/guest.sh" "$VM" "printf '{\"five\":10,\"weekly\":51}' > $G/usage-1.json" \
  || fail "the 51% usage fixture (an order below would not be caused by it)"
panel
refresh
sleep 8
close_panel

note "the order reaches the helper"
if wait_calls 'gate work-agent-1 exit 2 order'; then
  note "ok: the gate refused the helper with the order"
else
  stop_early "the order never reached the helper (no 'gate work-agent-1 exit 2 order' in calls.log)"
fi
"$T/shot.sh" "$VM" "$S/4-after-order.png" || fail "capture 4-after-order"
records "$S/records-after-order.txt" || fail "the records after the order"
sleep 10

if [ "$MODE" = single ]; then
  note "single account: the continuation waits"
  sleep 30
  "$T/guest.sh" "$VM" "cat $G/calls.log" > "$S/calls-waiting.log" 2>&1 || fail "calls.log while waiting"
  if awk '/gate work-agent-1 exit 2 order/ {seen=1; next} seen && / turn / {bad=1} END {exit bad ? 0 : 1}' "$S/calls-waiting.log"; then
    fail "a turn ran after the order while the only account was at its point (the continuation did not wait)"
  else
    note "ok: no turn after the order while the account is at its point"
  fi
  note "the fake's reset: Account 1's week reads 10"
  "$T/guest.sh" "$VM" "printf '{\"five\":10,\"weekly\":10}' > $G/usage-1.json" || fail "the reset fixture"
  panel
  refresh
  sleep 6
  close_panel
fi

note "the next back-end turn carries the handoff continuation"
if [ "$MODE" = two ]; then
  WHERE='claude-accounts/2'
else
  # Account 1's lease names its folder too ($HOME/.claude in the guest; walk-1db6a7b8afee's
  # calls.log), so "account-1" (no folder at all) is kept only as the fake's fallback.
  WHERE='(account-1|/[.]claude)'
fi
# The continuation (work_host.rs HANDOFF_CONTINUATION_HEAD) opens "Helpers you started were
# stopped because the Claude account they ran on is being left" and names `RichOS handoff:`.
if wait_calls "$WHERE turn Helpers you started were stopped.*RichOS handoff:" 72; then
  note "ok: a turn under $WHERE carries the handoff continuation"
else
  fail "no turn under $WHERE with the handoff continuation after the order"
fi
sleep 5
"$T/shot.sh" "$VM" "$S/5-after-handoff.png" || fail "capture 5-after-handoff"

collect

# The checks, on what was saved. The order of lines in calls.log is the order of events.
if awk '/gate work-agent-1 exit 2 order/ {g=NR} / turn Helpers you started were stopped/ && g && NR>g && $0 ~ WHERE {t=1} END {exit t ? 0 : 1}' WHERE="$WHERE" "$S/calls.log"; then
  note "ok: the handoff turn under $WHERE follows the order"
else
  fail "calls.log has no handoff turn under $WHERE after the order"
fi
if grep '"hook_event_name":"SubagentStop"' "$S/journal.txt" | grep -q '"agent_id":"work-agent-1"'; then
  note "ok: the helper ended (SubagentStop for work-agent-1 in the back end's journal)"
else
  fail "no SubagentStop for work-agent-1 in the evidence journals"
fi
if grep -A1 'handoffs/work-agent-1.json' "$S/records.txt" | grep -q '"continued_at"'; then
  note "ok: the gate's handoff marker for work-agent-1 was used by the continuation"
else
  fail "no used handoff marker for work-agent-1 (engine-state/handoffs)"
fi
# Never said failed: a work record (engine-state/assignments/<partition>/<id>.json, compact JSON,
# assignment.rs AssignmentState kebab-case) whose state is failed, at the order or now.
# Only the work records' blocks are read: claude-quota.json has "state" fields of its own.
work_states() { awk '/^== / {w = ($0 ~ /\/engine-state\/assignments\//)} w' "$@" | grep -o '"state":"[a-z-]*"'; }
if ! grep -q '^== .*/engine-state/assignments/' "$S/records.txt"; then
  fail "no work record was written (the job never reached the register)"
elif work_states "$S/records-after-order.txt" "$S/records.txt" | grep -q '"state":"failed"'; then
  fail "a work record says failed"
else
  note "ok: no work record says failed (at the order: $(work_states "$S/records-after-order.txt" | tr '\n' ' '); now: $(work_states "$S/records.txt" | tr '\n' ' '))"
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
