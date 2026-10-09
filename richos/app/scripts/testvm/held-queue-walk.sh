#!/bin/bash
# held-queue-walk.sh — the held queue on the real app, fake Claude, in one guest run.
#
#   run-walk.py --bundle <RichOS.app.zip> --home <empty dir> --engine <engine.tar.gz> \
#     --report <json> -- held-queue-walk.sh <out-dir>
#
# Plan: richos-hq docs/plans/2026-10-09-automatic-second-review-and-t3-ideas.md §4 row 5, and
# Sage's check of it §1.1: when nobody is signed in, the jobs queued on a conversation are HELD,
# not failed, and the host itself starts them when the sign-in comes back, first held job first,
# then the rest, with no model turn spent on it.
#
# The front desk writes TWO jobs down in one turn (the fake's `register` file, one job a line);
# the account is signed out for the back end (the fake's `signed-out` file: `auth status` says
# loggedIn false and every back-end turn is refused the way Claude Code 2.1.295 refuses one).
# PASS when:
#   1  exactly one back-end turn is refused, for the first job (calls.log "work-turn refused");
#   2  both work records say registered with the held sentence, and neither says failed;
#   3  the conversation shows the one held notice ("I haven't started …");
#   4  after `signed-out` is removed, the host's own look (every 120 s, work_host.rs
#      HOLD_CHECK_EVERY) starts the first job and then the second, in that order, with no
#      front-desk turn after the sign-in came back (calls.log "work-turn answered", "desk-turn");
#   5  no work record says failed, before or after.
#
# run-walk.py passes the VM name first, and quits the app, stops the guest and deletes the clone
# when this returns (CEO §54). In <out-dir>: 1-held.png, 2-resumed.png, 1-notice.json, calls.log,
# records-held.txt, records.txt, walk.log. EXIT STATUS: 1 when the setup fails or any capture or
# check fails (named at the end); 0 only when every capture was saved and every check passed.
set -u
VM="$1"
S="${2:?usage: held-queue-walk.sh <vm> <out-dir>}"
T="$(cd "$(dirname "$0")" && pwd)"
G=/Users/admin/fill-first
JOB1='Prepare the Northwind invoice summary.'
JOB2='Draft the Contoso welcome note.'
HELD='Waiting for you to sign in to Claude'
# Each job's back-end brief opens "… The assignment: <its words> Original request (verbatim): …"
# (work_host.rs brief_for). The verbatim request is his whole message, which names both jobs, so
# a turn is told apart by the words right after "The assignment:".
A1="The assignment: ${JOB1%.}"
A2="The assignment: ${JOB2%.}"
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
# Wait (at most $2 x 5 s, default 2 min) until the guest's calls.log has a line matching $1.
wait_calls() {
  for _ in $(seq 1 "${2:-24}"); do
    "$T/guest.sh" "$VM" "grep -Eq '$1' $G/calls.log" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
# The work records (engine-state/assignments, one JSON per job).
records() {
  "$T/guest.sh" "$VM" "find \"$DATA/engine-state/assignments\" -type f -name '*.json' 2>/dev/null | sort | while IFS= read -r f; do echo \"== \$f\"; cat \"\$f\"; echo; done; true" > "$1" 2>&1
}
collect() {
  "$T/guest.sh" "$VM" "cat $G/calls.log" > "$S/calls.log" 2>&1 || fail "calls.log"
  records "$S/records.txt" || fail "the app's records"
}
stop_early() {
  fail "$1; nothing after it can pass"
  collect
  note "done, with ${#FAILS[@]} failed step(s): $(printf '%s; ' "${FAILS[@]}")"
  exit 1
}
# One work record per job: its state and detail, by the job's own words in its title.
row_of() { awk -v job="$2" '/^== / {w = ($0 ~ /\/engine-state\/assignments\//); next} w && index($0, job)' "$1"; }

"$T/guest.sh" "$VM" "mkdir -p $G" || setup_failed "the fixture folder"
"$T/guest.sh" "$VM" --push "$T/fake-claude-fill-first.pl" $G/claude || setup_failed "pushing the fake claude"
"$T/guest.sh" "$VM" "chmod 755 $G/claude; printf '{\"five\":10,\"weekly\":20}' > $G/usage-1.json; touch $G/log-work-turns; printf '%s\n%s\n' '$JOB1' '$JOB2' > $G/register; printf 'Done.' > $G/reply.txt" \
  || setup_failed "the fixture files"
python3 - "$VM" "$T" <<'PY' || setup_failed "relaunching the app with the fake claude"
import sys
sys.path.insert(0, sys.argv[2])
from relaunch import relaunch
print(relaunch(sys.argv[1], environment={'RICHOS_CLAUDE_BIN': '/Users/admin/fill-first/claude'}))
PY

wait_for 'Not now' || true
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
# shellcheck disable=SC2016  # the $(...) is meant to expand in the guest's shell, not here
DATA=$("$T/guest.sh" "$VM" 'd="$(find /Users/admin/testvm -type d -name engine-state 2>/dev/null | head -1)"; [ -n "$d" ] && dirname "$d"')
[ -n "$DATA" ] || setup_failed "the app's data folder (no engine-state in the guest)"
note "app data: $DATA"

note "the sign-in runs out for the back end; ask for the two jobs"
"$T/guest.sh" "$VM" "touch $G/signed-out" || setup_failed "the signed-out fixture"
"$T/ax.sh" "$VM" type "$JOB1 And then: $JOB2" --role AXTextArea --first --replace || true
"$T/ax.sh" "$VM" click --title 'Send' --first || true
if wait_calls 'register ok'; then
  note "ok: the front desk wrote the jobs down"
else
  stop_early "the front desk never wrote the jobs down (no 'register ok' in calls.log)"
fi
if wait_calls 'work-turn refused'; then
  note "ok: the back end's first turn was refused (nobody signed in)"
else
  stop_early "no back-end turn was refused"
fi
# The host's look at the sign-in is every 120 s; 60 s here is inside the first one, so anything
# started meanwhile would be a defect, not a clearance.
sleep 60
"$T/shot.sh" "$VM" "$S/1-held.png" || fail "capture 1-held"
"$T/ax.sh" "$VM" find --value "I haven't started" --contains --json > "$S/1-notice.json" 2>/dev/null || true
records "$S/records-held.txt" || fail "the records while held"
"$T/guest.sh" "$VM" "cat $G/calls.log" > "$S/calls-held.log" 2>&1 || fail "calls.log while held"

registered=$(grep -c 'register ok' "$S/calls-held.log" || true)
if [ "$registered" = 2 ]; then note "ok: two jobs written down"; else fail "$registered jobs written down, not 2"; fi
refused=$(grep -c 'work-turn refused' "$S/calls-held.log" || true)
answered=$(grep -c 'work-turn answered' "$S/calls-held.log" || true)
if [ "$refused" = 1 ] && [ "$answered" = 0 ]; then
  note "ok: one attempt for the two jobs, nothing else started"
else
  fail "while held: $refused refused and $answered answered back-end turns, not 1 and 0"
fi
if grep 'work-turn refused' "$S/calls-held.log" | grep -qF "$A1"; then
  note "ok: the attempt was the first job"
else
  fail "the refused turn was not the first job's"
fi
for job in "$JOB1" "$JOB2"; do
  row=$(row_of "$S/records-held.txt" "$job")
  if printf '%s' "$row" | grep -q '"state":"registered"' && printf '%s' "$row" | grep -qF "$HELD"; then
    note "ok: held: $job"
  else
    fail "not held: $job ($(printf '%s' "$row" | grep -o '"state":"[a-z-]*"'))"
  fi
done
said=$(grep -c '"role"' "$S/1-notice.json" || true)
if [ "$said" = 1 ]; then note "ok: the held notice is shown once"; else fail "the held notice is shown $said times, not once"; fi

note "the sign-in comes back"
# shellcheck disable=SC2016
CLEARED=$("$T/guest.sh" "$VM" "rm -f $G/signed-out && date +%s")
[ -n "$CLEARED" ] || fail "removing the signed-out fixture"
if wait_calls "work-turn answered.*$A1" 48; then
  note "ok: the first held job started"
else
  stop_early "the first held job never started after the sign-in came back"
fi
if wait_calls "work-turn answered.*$A2" 24; then
  note "ok: the second held job started"
else
  fail "the second held job never started"
fi
sleep 20
"$T/shot.sh" "$VM" "$S/2-resumed.png" || fail "capture 2-resumed"
collect

first=$(grep -n "work-turn answered.*$A1" "$S/calls.log" | head -1 | cut -d: -f1)
second=$(grep -n "work-turn answered.*$A2" "$S/calls.log" | head -1 | cut -d: -f1)
if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
  note "ok: the first held job first, then the second"
else
  fail "the held jobs did not start in order (lines $first, $second)"
fi
started=$(awk -v t="$CLEARED" '$1 >= t && / work-turn answered / {print $1; exit}' "$S/calls.log")
[ -n "$started" ] && note "ok: the first job started $((started - CLEARED)) s after the sign-in came back"
if awk -v t="$CLEARED" '$1 >= t && / desk-turn / {bad=1} END {exit bad ? 0 : 1}' "$S/calls.log"; then
  fail "a front-desk turn ran after the sign-in came back (a model turn spent on the clearance)"
else
  note "ok: no front-desk turn after the sign-in came back"
fi
work_states() { awk '/^== / {w = ($0 ~ /\/engine-state\/assignments\//)} w' "$@" | grep -o '"state":"[a-z-]*"'; }
if work_states "$S/records-held.txt" "$S/records.txt" | grep -q '"state":"failed"'; then
  fail "a work record says failed"
else
  note "ok: no work record says failed (held: $(work_states "$S/records-held.txt" | tr '\n' ' '); now: $(work_states "$S/records.txt" | tr '\n' ' '))"
fi
for job in "$JOB1" "$JOB2"; do
  row_of "$S/records.txt" "$job" | grep -qF "$HELD" && fail "still held at the end: $job"
done

if [ "${#FAILS[@]}" -gt 0 ]; then
  note "done, with ${#FAILS[@]} failed step(s): $(printf '%s; ' "${FAILS[@]}")"
  exit 1
fi
note "done"
exit 0
