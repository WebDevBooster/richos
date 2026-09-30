#!/usr/bin/env bash
#
# login-alarm.test.sh — the "Login expired" alarm, against fixtures only.
#
# Every case runs in a scratch sandbox: fixture transcripts, a stand-in
# `security` that prints ATTRIBUTES from a file (and records its arguments, so
# L07 can prove -w and -g are never asked for), a recorder in place of
# osascript, and a sandbox escalation ledger. Nothing here can notify the CEO,
# read his keychain or write his ledger.
#
#   L01  a lead turn's "Login expired" row: ONE notification (title and /login),
#        ONE escalation (stopped, for ceo), an open episode
#   L02  more failures in the same episode (a teammate, the lead again): no
#        second notification, no second escalation, the failures are counted
#   L03  the credential is rewritten after the failure (his /login): the
#        escalation is acknowledged, the episode closes, nobody is notified
#   L04  a failure after the renewal is a NEW episode: a second alarm
#   L05  "Not logged in" (a sandbox with no credential store) never alarms
#   L06  a failure OLDER than the credential's last write (already renewed
#        while the alarm was not running) never alarms
#   L07  the credential is read as ATTRIBUTES only: `security` never gets -w or -g
#   L08  --report (the quota watcher) alarms with its own source named
#   L09  another API error (a rate limit) is not a login failure
#   L09b a turn that only TALKS about the incident (both strings, no error
#        field) is not a failure
#   L09c a transient "Authentication error" (Claude Code says retry) is not a
#        dead login
#   L10  a first scan never alarms on history (a failure an hour old)
#   L11  a notification that could not be posted is retried once, never looped
#   L12  the alarm line states how long after the failure it fired
#   L13  --print-plist and --install (sandboxed) schedule it every 30 s, at load
#
# The mutation harness, login-alarm.mutation.sh, runs from the bottom of this
# file, so the runner that discovers *.test.sh runs it too.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="$SCRIPT_DIR/login-alarm.sh"
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
[ -f "$A" ] || { echo "FATAL: missing $A" >&2; exit 1; }

# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"
SB="$(scratch_new login-alarm-test)" || { echo "FATAL: no scratch" >&2; exit 1; }
trap 'scratch_release "$SB" >/dev/null 2>&1 || true' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1 — $3"; fi; }

# --- isolation: every seam points into the sandbox ---------------------------
export LOGIN_ALARM_PROJECTS_DIR="$SB/projects"
export LOGIN_ALARM_STATE="$SB/state/login-alarm.json"
export LOGIN_ALARM_SECURITY="$SB/security"
export LOGIN_ALARM_NOTIFY_CMD="$SB/notify"
export RICHOS_ESCALATION_LEDGER="$SB/escalations.jsonl"
export RICHOS_LAUNCH_AGENTS_DIR="$SB/LaunchAgents"
unset LOGIN_ALARM_NOW

cat >"$SB/security" <<'SH'
#!/usr/bin/env bash
# Attributes only, the way the real one prints them without -w/-g. The mdat
# comes from a file; no file means no item.
printf '%s\n' "$*" >>"$(dirname "$0")/security.argv"
f="$(dirname "$0")/mdat"
[ -f "$f" ] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; }
m="$(cat "$f")"
printf 'keychain: "/Users/x/Library/Keychains/login.keychain-db"\nattributes:\n    "acct"<blob>="x"\n    "mdat"<timedate>=0x00  "%sZ\\000"\n    "svce"<blob>="Claude Code-credentials"\n' "$m"
SH
cat >"$SB/notify" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s|%s\n' "$1" "$2" >>"$d/notified"
rc="$(cat "$d/notify_rc" 2>/dev/null || echo 0)"
exit "$rc"
SH
chmod +x "$SB/security" "$SB/notify"

reset_all() {
    rm -rf "$SB/projects" "$SB/state" "$SB/escalations.jsonl" "$SB/notified" "$SB/notify_rc" \
           "$SB/mdat" "$SB/security.argv"
    mkdir -p "$SB/projects/-Users-x-repo/sess/subagents" "$SB/state"
}
utc() { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%S.000Z",time.gmtime(float(sys.argv[1]))))' "$1"; }
mdat_at() { python3 -c 'import sys,time;print(time.strftime("%Y%m%d%H%M%S",time.gmtime(float(sys.argv[1]))))' "$1" >"$SB/mdat"; }
row() { # <file> <epoch> <text> [error]
    python3 - "$1" "$(utc "$2")" "$3" "${4:-authentication_failed}" <<'PY'
import json, sys
path, ts, text, err = sys.argv[1:5]
r = {"type": "assistant", "timestamp": ts, "isApiErrorMessage": True, "error": err,
     "message": {"model": "<synthetic>", "role": "assistant",
                 "content": [{"type": "text", "text": text}]}}
open(path, "a").write(json.dumps(r) + "\n")
import calendar, os, time
t = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
os.utime(path, (t, t))   # the file changed when its row was written, as in life
PY
}
filler() { # an ordinary transcript row, so a file is not only errors
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hi"}}\n' "$(utc "$2")" >>"$1"
}
tick() { OUT="$(LOGIN_ALARM_NOW="$1" bash "$A" "${@:2}" 2>&1)"; RC=$?; }
nnotified() { [ -f "$SB/notified" ] && wc -l <"$SB/notified" | tr -d ' ' || echo 0; }
nesc() { if [ -f "$SB/escalations.jsonl" ]; then grep -c '"event": "Escalation"' "$SB/escalations.jsonl"; else echo 0; fi; }
nack() { if [ -f "$SB/escalations.jsonl" ]; then grep -c '"event": "EscalationAck"' "$SB/escalations.jsonl"; else echo 0; fi; }
state_open() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("open" if d.get("open") else "closed")' "$LOGIN_ALARM_STATE" 2>/dev/null; }

LEAD="$SB/projects/-Users-x-repo/sess.jsonl"
MATE="$SB/projects/-Users-x-repo/sess/subagents/agent-a1.jsonl"
NOW="$(date +%s)"
EXPIRED="Login expired · Please run /login"

echo "=== login-alarm tests ==="

# --- L01 / L02 / L03 / L04: one episode, start to finish, then another -------
reset_all
mdat_at $((NOW - 7200))                   # the item was last written two hours ago
filler "$LEAD" $((NOW - 30))
row "$LEAD" $((NOW - 4)) "$EXPIRED"
tick "$NOW"
ESC1="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d.get("event")=="Escalation": print(d["id"]); print(d["state"]); print(d["for"]); print(d["teammate"])' "$SB/escalations.jsonl" 2>/dev/null | tr '\n' ' ')"
check "L01  a lead turn's 'Login expired': one notification naming /login, one escalation (stopped, for ceo), an open episode" \
    "$([ "$RC" -eq 0 ] && [ "$(nnotified)" = 1 ] && grep -q '^Claude login expired|.*Run /login' "$SB/notified" \
       && [ "$(nesc)" = 1 ] && printf '%s' "$ESC1" | grep -q ' stopped ceo login-alarm' \
       && [ "$(state_open)" = open ] && printf '%s' "$OUT" | grep -q '^LOGIN-EXPIRED at'; echo $?)" \
    "rc=$RC out=$OUT notified=$(cat "$SB/notified" 2>/dev/null) esc=$ESC1"

row "$MATE" $((NOW + 20)) "$EXPIRED"
row "$LEAD" $((NOW + 25)) "$EXPIRED"
tick $((NOW + 30))
tick $((NOW + 60))
check "L02  more failures in the same episode: no second notification, no second escalation, failures counted" \
    "$([ "$(nnotified)" = 1 ] && [ "$(nesc)" = 1 ] && printf '%s' "$OUT" | grep -q 'already alarmed.*3 failure(s)'; echo $?)" \
    "notified=$(nnotified) esc=$(nesc) out=$OUT"

mdat_at $((NOW + 300))                     # his /login
tick $((NOW + 330))
check "L03  the credential rewritten after the failure: escalation acknowledged, episode closed, nobody notified" \
    "$([ "$(nnotified)" = 1 ] && [ "$(nack)" = 1 ] && [ "$(state_open)" = closed ] \
       && printf '%s' "$OUT" | grep -q '^LOGIN-RENEWED'; echo $?)" \
    "notified=$(nnotified) acks=$(nack) state=$(state_open) out=$OUT"

row "$LEAD" $((NOW + 400)) "$EXPIRED"
tick $((NOW + 410))
check "L04  a failure after the renewal is a new episode: a second alarm" \
    "$([ "$(nnotified)" = 2 ] && [ "$(nesc)" = 2 ] && [ "$(state_open)" = open ]; echo $?)" \
    "notified=$(nnotified) esc=$(nesc) out=$OUT"

check "L07  the credential is read as attributes only: security never got -w or -g" \
    "$([ -s "$SB/security.argv" ] && ! grep -qE '(^| )-(w|g)( |$)' "$SB/security.argv" \
       && grep -q 'find-generic-password' "$SB/security.argv"; echo $?)" \
    "argv=$(cat "$SB/security.argv" 2>/dev/null)"

# --- L05: a sandbox's "Not logged in" -----------------------------------------
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 4)) "Not logged in · Please run /login"
tick "$NOW"
check "L05  'Not logged in' (no credential store at all) never alarms" \
    "$([ "$(nnotified)" = 0 ] && [ "$(nesc)" = 0 ]; echo $?)" "notified=$(nnotified) out=$OUT"

# --- L06: already renewed ----------------------------------------------------
reset_all
row "$LEAD" $((NOW - 120)) "$EXPIRED"
mdat_at $((NOW - 60))
tick "$NOW"
check "L06  a failure older than the credential's last write never alarms (already renewed)" \
    "$([ "$(nnotified)" = 0 ] && [ "$(nesc)" = 0 ] && printf '%s' "$OUT" | grep -q 'already renewed'; echo $?)" \
    "notified=$(nnotified) out=$OUT"

# --- L08: the quota watcher's report ------------------------------------------
reset_all
mdat_at $((NOW - 7200))
tick "$NOW" --report --source quota-watch --detail "get_usage: Login expired · Please run /login"
check "L08  --report alarms with its own source named" \
    "$([ "$(nnotified)" = 1 ] && [ "$(nesc)" = 1 ] && grep -q 'from quota-watch' "$SB/escalations.jsonl" \
       && printf '%s' "$OUT" | grep -q 'quota-watch'; echo $?)" "notified=$(nnotified) out=$OUT"

# --- L09: a rate limit -------------------------------------------------------
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 4)) "API Error: Rate limit reached" "rate_limit"
tick "$NOW"
check "L09  another API error (a rate limit) is not a login failure" \
    "$([ "$(nnotified)" = 0 ] && [ "$(nesc)" = 0 ]; echo $?)" "notified=$(nnotified) out=$OUT"

# An ordinary assistant turn that TALKS about the incident (this very work's
# transcripts do) carries both strings and no error field.
reset_all
mdat_at $((NOW - 7200))
python3 - "$LEAD" "$(utc $((NOW - 4)))" <<'PY'
import json, sys
r = {"type": "assistant", "timestamp": sys.argv[2],
     "message": {"role": "assistant", "content": [{"type": "text",
       "text": "Login expired, error authentication_failed at 09:26Z: here is why."}]}}
open(sys.argv[1], "a").write(json.dumps(r) + "\n")
PY
tick "$NOW"
check "L09b a turn that only TALKS about 'Login expired' / authentication_failed is not a failure" \
    "$([ "$(nnotified)" = 0 ] && [ "$(nesc)" = 0 ]; echo $?)" "notified=$(nnotified) out=$OUT"

# Claude Code's transient authentication error says to retry; it is not a dead login.
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 4)) "Authentication error · This may be a temporary network issue, please try again"
tick "$NOW"
check "L09c a transient 'Authentication error' (retry) is not a dead login" \
    "$([ "$(nnotified)" = 0 ] && [ "$(nesc)" = 0 ]; echo $?)" "notified=$(nnotified) out=$OUT"

# --- L10: history ------------------------------------------------------------
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 3600)) "$EXPIRED"
tick "$NOW"
check "L10  a first scan never alarms on history (a failure an hour old)" \
    "$([ "$(nnotified)" = 0 ] && [ "$(nesc)" = 0 ]; echo $?)" "notified=$(nnotified) out=$OUT"

# --- L11: a notification that could not be posted ------------------------------
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 4)) "$EXPIRED"
echo 1 >"$SB/notify_rc"
tick "$NOW"
FIRST="$OUT"
echo 0 >"$SB/notify_rc"
tick $((NOW + 30)); tick $((NOW + 60)); tick $((NOW + 90))
check "L11  a notification that could not be posted is retried once, then never repeated" \
    "$([ "$(nnotified)" = 2 ] && [ "$(nesc)" = 1 ] && printf '%s' "$FIRST" | grep -q 'CEO notified=NO'; echo $?)" \
    "calls=$(nnotified) first=$FIRST"

# --- L12: the delay is stated ------------------------------------------------
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 7)) "$EXPIRED"
tick "$NOW"
check "L12  the alarm line states how long after the failure it fired" \
    "$(printf '%s' "$OUT" | grep -qE '7\.[0-9] s after the failure'; echo $?)" "out=$OUT"

# --- L14: an escalation write that failed is retried during the same outage ----
# (hunt part 5, P5-13) The notification went, the ledger did not: the next tick,
# with the ledger writable again, writes the ONE missing row, records its id in
# the episode, and does not notify a second time.
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 4)) "$EXPIRED"
mkdir -p "$SB/escalations.jsonl"           # a directory where the ledger file belongs: the write fails
tick "$NOW"
L14_FIRST="$OUT"; L14_ESC0="$(nesc)"
rmdir "$SB/escalations.jsonl"               # the store recovers during the same outage
tick $((NOW + 30))
tick $((NOW + 60))
L14_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["open"].get("escalation",""))' "$LOGIN_ALARM_STATE" 2>/dev/null)"
check "L14  a failed escalation write is retried once the ledger recovers: one row, its id recorded, no second notification" \
    "$(printf '%s' "$L14_FIRST" | grep -q 'COULD NOT WRITE THE ESCALATION LEDGER' && [ "$L14_ESC0" = 0 ] \
       && [ "$(nesc)" = 1 ] && [ -n "$L14_ID" ] && [ "$(nnotified)" = 1 ] && [ "$(state_open)" = open ]; echo $?)" \
    "first=$L14_FIRST esc0=$L14_ESC0 esc=$(nesc) id=$L14_ID notified=$(nnotified)"

# --- L15: a credential write older than the latest failure does not renew ------
# (hunt part 5, P5-14) Failures at T-4 and T+200; the credential was written at
# T+100, BETWEEN them. The later failure shows the write did not restore work,
# so when that failure leaves the scan window the episode stays open.
reset_all
mdat_at $((NOW - 7200))
row "$LEAD" $((NOW - 4)) "$EXPIRED"
tick "$NOW"
mdat_at $((NOW + 100))
row "$LEAD" $((NOW + 200)) "$EXPIRED"
tick $((NOW + 210))
tick $((NOW + 3000))
tick $((NOW + 5000))                        # the later failure is long out of the scan window
check "L15  a credential write older than the latest failure does not close the episode or acknowledge the escalation" \
    "$([ "$(state_open)" = open ] && [ "$(nack)" = 0 ] && ! printf '%s' "$OUT" | grep -q 'LOGIN-RENEWED'; echo $?)" \
    "state=$(state_open) acks=$(nack) out=$OUT"

# --- L13: the schedule --------------------------------------------------------
PL="$(bash "$A" --print-plist 2>&1)"
bash "$A" --install >/dev/null 2>&1; IRC=$?
check "L13  --print-plist and a sandboxed --install schedule it every 30 s and at load" \
    "$(printf '%s' "$PL" | grep -q '<key>StartInterval</key><integer>30</integer>' \
       && printf '%s' "$PL" | grep -q '<key>RunAtLoad</key><true/>' \
       && printf '%s' "$PL" | grep -q 'login-alarm.sh</string>' \
       && [ "$IRC" -eq 0 ] && [ -f "$SB/LaunchAgents/com.richos.login-alarm.plist" ] \
       && bash "$A" --installed; echo $?)" "irc=$IRC plist=$PL"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== login-alarm tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== login-alarm tests: all $PASS passed ==="

if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/login-alarm.mutation.sh" ]; then
    bash "$SCRIPT_DIR/login-alarm.mutation.sh" || exit 1
fi
exit 0
