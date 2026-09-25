#!/usr/bin/env bash
#
# quota-watch.test.sh — THE 93% RULE'S WATCHER, PROVEN AT ITS EDGES AND END TO END.
#
# His words (ruling §87): "quota polling: every 5 minutes from now. And once it
# crosses the 93% threshold: PAUSE subagents. Then resume after quota rest."
#
#   Q01-Q03  the threshold edges: 92 is below (exit 0), 93 and 94 are at or
#            above (exit 1)
#   Q04-Q07  a missing payload, invalid JSON, no rate_limits.five_hour, and a
#            non-number used_percentage are UNKNOWN (exit 2), never "fine"
#   Q08      a STALE reading below the threshold is UNKNOWN (it proves nothing)
#   Q09      a STALE reading at or above the threshold is still at or above
#            (usage only grows inside one window)
#   Q10      a reading whose window has ended is UNKNOWN
#   Q11-Q13  the threshold is READ FROM orchestration.config: undeclared and
#            malformed are UNKNOWN, and a declared 50 moves the edge to 50
#   Q14      the reading's age and the reset time are printed
#   Q15      --status prints his words, the declared line and the live workers
#   W01      --watch wakes with QUOTA-THRESHOLD when the reading crosses, and
#            prints the pause message with its `pause-until:` line, the
#            minutes to reset and the live-worker count
#   W02      --watch wakes with WINDOW-RESET when the reset passes, with the
#            resume message and NO `pause-until:` line in it
#   W03      at or above the threshold with NOTHING working, --watch does not
#            fire: there is nothing to pause; and when the reset comes within
#            20 minutes with nobody held, there is no QUOTA-RELEASE either
#   W04      --watch --until-reset never fires the threshold, only the reset
#   W05      a reading older than one poll, with a worker running, wakes the
#            lead with QUOTA-STALE: not the current value, refresh it
#   Q16      by default "stale" is ONE poll: 400 s old is unknown, 200 s is not
#
# HIS UPDATE, 2026-09-25 (ruling §87): at or above the threshold, no pause when
# the reset is LESS than 20 minutes away; exactly 20 still pauses; a hold in
# place releases inside that window. And "Keep it consistent at 5 minutes":
#   Q17-Q19  19 minutes to the reset at 95%: no pause (exit 3); exactly 20
#            minutes: pause (exit 1); 21 minutes: pause (exit 1). The clock is
#            pinned, so each boundary is exact to the second
#   Q20      1199 s is inside the exception, 1 s is inside it, and 0 s is a
#            window that has ended (UNKNOWN), never "inside the exception"
#   Q21      a STALE reading at or above the threshold gets the exception too
#            (resets_at does not move inside a window): 19 min exit 3, 21 exit 1
#   Q22      below the threshold, and UNKNOWN, are untouched by the exception
#   Q23      one 5-minute poll at every usage level: 69% and 71% readings
#            400 s old are both UNKNOWN by default (no 30-minute tier)
#   Q24      --status names the update and prints "NO PAUSE" inside the window
#   W10      19 minutes to the reset with a worker running: no QUOTA-THRESHOLD
#   W11      21 minutes to the reset with a worker running: QUOTA-THRESHOLD
#   R01      2026-09-25's log replayed, with its real reset (03:40Z): the
#            payload sat at 56/71/89% and jumped to 100% while the lead was
#            idle; the watcher wakes the lead (QUOTA-REFRESH or QUOTA-STALE)
#            while it sits at 56%, and
#            QUOTA-THRESHOLD fires before 100%, about 90 minutes before the
#            reset, so the near-reset exception does not apply
#   R02      the same log with its reset moved to 02:20Z: the crossing falls
#            inside the last 20 minutes, and nobody is paused
#
# THE READING FROM CLAUDE CODE'S OWN get_usage (2026-09-25). The suite never
# starts the operator's `claude`: QUOTA_CLAUDE_BIN points at nothing, so every
# case above reads the status-line fallback, and the G cases point it at a
# fixture that speaks the control protocol:
#   G01      --once reads get_usage (95%), not the status-line file (50%), and
#            the fixture refuses any argument list but the control-only one
#   G02      the process it started is ENDED after the read, though the
#            fixture would linger 30 s; it asked initialize, then get_usage
#   G03-G06  refused, no subscription limits, never answering (bounded by the
#            deadline, and the hung process ended), unreadable, closed early:
#            each falls back to the status-line file and says why
#   G07      --watch takes a fresh get_usage at every poll, so a status-line
#            file ten minutes old wakes nobody
#   G08      get_usage failing: a stale status-line file still wakes the lead
#   R04      this morning's 91% (07:57Z) to 95% (08:07Z), lead idle: through
#            get_usage the pause fires before 08:07Z under 95%, no wake needed
#
# THE FALLBACK IS REFRESHED BEFORE IT TURNS ONE POLL OLD (the same morning:
# the pause fired at 95, not 93, because a 300 s poll first saw the file
# stale at its second poll, about 600 s after the render):
#   W12      below the threshold with a worker running, QUOTA-REFRESH comes
#            at the refresh point, while the reading is under one poll old
#   W13      at the refresh point with nothing working, nobody is woken
#   R03      the 07:57Z/08:07Z shape on the fallback: every wake is a REFRESH
#            under one poll old, and the pause fires before 08:07Z under 95%
#   W06      a stale reading with nothing running does NOT wake the lead
#   W07      no payload at all: --watch cannot watch, exit 2
#   W08      no threshold declared: --watch cannot watch, exit 2
#   W09      the default poll is his "every 5 minutes" (300 s), and a worker
#            set the registry cannot name still fires the threshold
#   E01-E06  END TO END through the real workspace registry and the real
#            resume guard — the 2026-09-18 failure, reproduced and fixed:
#              E01  at the threshold both running workers are named
#              E02  the printed pause message keeps its agent PAUSED through
#                   its own SubagentStop (mega-lander point 11)
#              E03  so the lead's wake message to it is ALLOWED
#              E04  the 2026-09-18 hold message (no pause-until: line) still
#                   leaves a FINISHED agent, and its wake is still REFUSED
#              E05  when the reset comes within 20 minutes, QUOTA-RELEASE names
#                   only the quota-paused agent, on time at the default
#                   300 s poll, and not a second before the boundary
#              E06  the printed release message resumes the SAME agent
#              E07  --until-reset also wakes at the release when one is held
#              E08  at the reset only the quota-paused agent is named to wake
#              E09  the printed resume message resumes it in the registry
#
# The mutation harness, quota-watch.mutation.sh, is run from the bottom of
# this file, so the runner that discovers *.test.sh runs it too.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/.." && pwd)"
Q="$SCRIPT_DIR/quota-watch.sh"
WS_PY="$ENGINE/mega-lander/workspaces.py"
GUARD="$SCRIPT_DIR/hooks/guard-resume-isolation.sh"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
[ -f "$Q" ] || { echo "FATAL: missing $Q" >&2; exit 1; }

# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"
SB="$(scratch_new quota-watch-test)" || { echo "FATAL: no scratch" >&2; exit 1; }

# This suite's own stand-in for the lead's session process. Its PID is captured
# here, at spawn, and it is the only process this suite ever signals besides
# the watchers it starts itself.
SLEEPER="$(sh -c 'sleep 900 >/dev/null 2>&1 & echo $!')"
WATCH_PID=""
cleanup() {
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    kill "$SLEEPER" 2>/dev/null
    # The fixture writes its own pid at start: those are this suite's processes.
    if [ -f "${FAKE:-/nonexistent}/pids" ]; then
        while read -r fp; do kill "$fp" 2>/dev/null; done <"$FAKE/pids"
    fi
    scratch_release "$SB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { # <id+label> <condition-exit> <detail>
    if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1 — $3"; fi
}

# --- isolation: nothing here reads the operator's payload, registry or sessions
unset CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT RICHOS_ENGINE_ROOT
export QUOTA_PAYLOAD="$SB/payload.json"
export RICHOS_ENTITY_ROOT="$SB/entity"
export RICHOS_WORKSPACES_DIR="$SB/ws"
export RICHOS_SESSIONS_DIR="$SB/platform-sessions"
export RICHOS_PROJECTS_DIR="$SB/projects"
export RICHOS_SESSION_PID="$SLEEPER"
export RESUME_GUARD_TEAMS_DIR="$SB/teams"
export QUOTA_WATCH_POLL_SECONDS=1
export QUOTA_WATCH_STALE_SECONDS=30
# NEVER the operator's real `claude`: by default get_usage has no binary and
# every case reads the status-line fallback, as before; the G cases point this
# at the fixture below, which answers the control protocol from files.
export QUOTA_CLAUDE_BIN="$SB/no-claude-here"
FAKE="$SB/fake"
SID="beadfeed-0000-4000-8000-00000000q001"
export RICHOS_SESSION_ID="$SID"
mkdir -p "$RICHOS_ENTITY_ROOT" "$RICHOS_WORKSPACES_DIR" "$RICHOS_SESSIONS_DIR" "$RICHOS_PROJECTS_DIR" "$RESUME_GUARD_TEAMS_DIR"

set_threshold() { # <raw-value or __none__>
    if [ "$1" = "__none__" ]; then
        printf 'PROTECTED_PATHS=""\n' >"$RICHOS_ENTITY_ROOT/orchestration.config"
    else
        printf 'PROTECTED_PATHS=""\nQUOTA_PAUSE_PERCENT=%s\n' "$1" >"$RICHOS_ENTITY_ROOT/orchestration.config"
    fi
}
write_payload() { # <used> <resets-in-seconds> <age-seconds>
    python3 - "$QUOTA_PAYLOAD" "$1" "$2" "$3" <<'PY'
import json, os, sys, time
path, used, rin, age = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
now = int(time.time())
used = json.loads(used)
with open(path + ".tmp", "w") as fh:
    json.dump({"session_id": "x", "rate_limits": {"five_hour": {"used_percentage": used, "resets_at": now + rin},
                                                   "seven_day": {"used_percentage": 1, "resets_at": now + 86400}}}, fh)
os.replace(path + ".tmp", path)
os.utime(path, (now - age, now - age))
PY
}
once() { OUT="$(bash "$Q" --once 2>&1)"; RC=$?; }

echo "=== quota-watch tests ==="
set_threshold 93

# --- Q: --once at the edges ------------------------------------------------
write_payload 92 3600 10; once
check "Q01  92% is below the threshold: exit 0" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC out=$OUT"
write_payload 93 3600 10; once
check "Q02  93% is AT the threshold: exit 1" "$([ "$RC" -eq 1 ]; echo $?)" "rc=$RC out=$OUT"
write_payload 94 3600 10; once
check "Q03  94% is above the threshold: exit 1" "$([ "$RC" -eq 1 ]; echo $?)" "rc=$RC out=$OUT"

rm -f "$QUOTA_PAYLOAD"; once
check "Q04  no payload at all is UNKNOWN: exit 2" "$([ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'UNKNOWN'; echo $?)" "rc=$RC out=$OUT"
printf '{"rate_limits": {"five_hour": {"used_perc' >"$QUOTA_PAYLOAD"; once
check "Q05  invalid JSON is UNKNOWN: exit 2" "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC out=$OUT"
printf '{"model": {"display_name": "x"}}' >"$QUOTA_PAYLOAD"; once
check "Q06  a payload with no rate_limits.five_hour is UNKNOWN: exit 2" "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC out=$OUT"
write_payload '"ninety"' 3600 10; once
check "Q07  a non-number used_percentage is UNKNOWN: exit 2" "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC out=$OUT"

write_payload 50 3600 600; once
check "Q08  a STALE reading below the threshold is UNKNOWN: exit 2, and says stale" \
    "$([ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'stale'; echo $?)" "rc=$RC out=$OUT"
write_payload 95 3600 600; once
check "Q09  a STALE reading at or above the threshold is still at or above: exit 1" "$([ "$RC" -eq 1 ]; echo $?)" "rc=$RC out=$OUT"
write_payload 50 -60 10; once
check "Q10  a reading whose window has ENDED is UNKNOWN: exit 2" \
    "$([ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'ended'; echo $?)" "rc=$RC out=$OUT"

write_payload 99 3600 10
set_threshold __none__; once
check "Q11  QUOTA_PAUSE_PERCENT undeclared is UNKNOWN (no built-in 93): exit 2" \
    "$([ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'not declared'; echo $?)" "rc=$RC out=$OUT"
set_threshold '"abc"'; once
check "Q12  a malformed QUOTA_PAUSE_PERCENT is UNKNOWN: exit 2" "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC out=$OUT"
set_threshold 50; write_payload 60 3600 10; once
check "Q13  the threshold is READ from orchestration.config: 60% against a declared 50 is at or above" \
    "$([ "$RC" -eq 1 ]; echo $?)" "rc=$RC out=$OUT"
set_threshold 93

write_payload 40 7200 20; once
check "Q14  --once prints the reading, its age and the reset time" \
    "$(printf '%s' "$OUT" | grep -q '40% of the five-hour window' && printf '%s' "$OUT" | grep -qE 'read 2[0-9] s ago' \
       && printf '%s' "$OUT" | grep -qE 'resets [0-9]{2}:[0-9]{2}Z'; echo $?)" "out=$OUT"
OUT="$(bash "$Q" --status 2>&1)"; RC=$?
check "Q15  --status: his words, the declared line and the live workers" \
    "$([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'PAUSE subagents. Then resume after quota rest.' \
       && printf '%s' "$OUT" | grep -q 'QUOTA_PAUSE_PERCENT=93' && printf '%s' "$OUT" | grep -q 'live workers:'; echo $?)" "rc=$RC out=$OUT"

write_payload 50 3600 400
OUT="$( unset QUOTA_WATCH_POLL_SECONDS QUOTA_WATCH_STALE_SECONDS; bash "$Q" --once 2>&1 )"; RC400=$?
write_payload 50 3600 200
OUT2="$( unset QUOTA_WATCH_POLL_SECONDS QUOTA_WATCH_STALE_SECONDS; bash "$Q" --once 2>&1 )"; RC200=$?
check "Q16  by default a reading older than ONE 5-minute poll is UNKNOWN (400 s: exit 2), a younger one is not (200 s: exit 0)" \
    "$([ "$RC400" -eq 2 ] && [ "$RC200" -eq 0 ]; echo $?)" "rc400=$RC400 ($OUT) rc200=$RC200 ($OUT2)"

# --- Q17-Q24: his 2026-09-25 update, on a PINNED clock ---------------------
# QUOTA_WATCH_NOW pins "now" for --once/--status/--notice, so 1200 s means
# exactly 20 minutes, not 20 minutes minus however long python3 took to start.
PIN=1790000000
write_payload_at() { # <used> <resets-in-seconds> <age-seconds>, relative to $PIN
    python3 - "$QUOTA_PAYLOAD" "$1" "$2" "$3" "$PIN" <<'PY'
import json, os, sys
path, used, rin, age, now = sys.argv[1], json.loads(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
with open(path + ".tmp", "w") as fh:
    json.dump({"rate_limits": {"five_hour": {"used_percentage": used, "resets_at": now + rin}}}, fh)
os.replace(path + ".tmp", path)
os.utime(path, (now - age, now - age))
PY
}
once_at() { OUT="$(QUOTA_WATCH_NOW="$PIN" bash "$Q" --once 2>&1)"; RC=$?; }

write_payload_at 95 1140 10; once_at
check "Q17  95% with 19 minutes to the reset: NO PAUSE, exit 3, and says why" \
    "$([ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'NO PAUSE' && printf '%s' "$OUT" | grep -q 'less than 20 minutes'; echo $?)" "rc=$RC out=$OUT"
write_payload_at 95 1200 10; once_at
check "Q18  95% with EXACTLY 20 minutes to the reset still pauses: exit 1" "$([ "$RC" -eq 1 ]; echo $?)" "rc=$RC out=$OUT"
write_payload_at 95 1260 10; once_at
check "Q19  95% with 21 minutes to the reset pauses: exit 1" "$([ "$RC" -eq 1 ]; echo $?)" "rc=$RC out=$OUT"

write_payload_at 95 1199 10; once_at; RC1199=$RC; OUT1199=$OUT
write_payload_at 95 1 10; once_at; RC1=$RC; OUT1=$OUT
write_payload_at 95 0 10; once_at; RC0=$RC
check "Q20  1199 s and 1 s are inside the exception (exit 3); 0 s is an ended window, UNKNOWN (exit 2)" \
    "$([ "$RC1199" -eq 3 ] && [ "$RC1" -eq 3 ] && [ "$RC0" -eq 2 ] && printf '%s' "$OUT" | grep -q 'ended'; echo $?)" \
    "rc1199=$RC1199 ($OUT1199) rc1=$RC1 ($OUT1) rc0=$RC0 ($OUT)"

write_payload_at 95 1140 600; once_at; RCS19=$RC; OUTS19=$OUT
write_payload_at 95 1260 600; once_at; RCS21=$RC
check "Q21  a STALE reading at or above gets the exception too: 19 min exit 3, 21 min exit 1" \
    "$([ "$RCS19" -eq 3 ] && [ "$RCS21" -eq 1 ]; echo $?)" "rc19=$RCS19 ($OUTS19) rc21=$RCS21 ($OUT)"

write_payload_at 92 1140 10; once_at; RCB=$RC; OUTB=$OUT
write_payload_at 50 1140 600; once_at; RCU=$RC
check "Q22  below the threshold at 19 min is still below (exit 0); a stale reading below it is still UNKNOWN (exit 2)" \
    "$([ "$RCB" -eq 0 ] && [ "$RCU" -eq 2 ]; echo $?)" "rcB=$RCB ($OUTB) rcU=$RCU ($OUT)"

write_payload 69 3600 400
OUT="$( unset QUOTA_WATCH_POLL_SECONDS QUOTA_WATCH_STALE_SECONDS; bash "$Q" --once 2>&1 )"; RC69=$?
write_payload 71 3600 400
OUT2="$( unset QUOTA_WATCH_POLL_SECONDS QUOTA_WATCH_STALE_SECONDS; bash "$Q" --once 2>&1 )"; RC71=$?
check "Q23  one 5-minute poll at every usage level: 69% and 71% readings 400 s old are both UNKNOWN (exit 2)" \
    "$([ "$RC69" -eq 2 ] && [ "$RC71" -eq 2 ]; echo $?)" "rc69=$RC69 ($OUT) rc71=$RC71 ($OUT2)"

write_payload_at 95 1140 10
OUT="$(QUOTA_WATCH_NOW="$PIN" bash "$Q" --status 2>&1)"; RC=$?
check "Q24  --status names the 2026-09-25 update and says NO PAUSE inside the last 20 minutes: exit 3" \
    "$([ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'update    : Updated 2026-09-25' \
       && printf '%s' "$OUT" | grep -q 'verdict   : AT OR ABOVE the threshold, NO PAUSE'; echo $?)" "rc=$RC out=$OUT"

# --- W: --watch ------------------------------------------------------------
start_watch() { # <outfile> [args...]
    local out="$1"; shift
    bash "$Q" --watch "$@" >"$out" 2>&1 &
    WATCH_PID=$!
}
finish_watch() { # <timeout-seconds> — sets WRC (124 on timeout)
    local n=0 lim=$(( $1 * 10 ))
    while kill -0 "$WATCH_PID" 2>/dev/null && [ "$n" -lt "$lim" ]; do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$WATCH_PID" 2>/dev/null; then
        kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WRC=124
    else
        wait "$WATCH_PID"; WRC=$?
    fi
    WATCH_PID=""
}
wait_for_line() { # <file> <pattern> <timeout-seconds>
    local n=0 lim=$(( $3 * 10 ))
    while ! grep -q "$2" "$1" 2>/dev/null && [ "$n" -lt "$lim" ]; do sleep 0.1; n=$((n + 1)); done
}

# --- G: the reading from Claude Code's own get_usage ------------------------
# The fixture stands in for `claude`: it refuses any argument list that is not
# the control-only one, records its pid and every request, answers from files
# ($FAKE/mode, $FAKE/used, $FAKE/reset_in), and after its input closes it
# LINGERS 30 s, the way a process nobody ended would, so a reader that does
# not end its own process is caught (G02).
mkdir -p "$FAKE"
cat >"$FAKE/claude" <<'PY'
#!/usr/bin/env python3
import datetime, json, os, sys, time
d = os.environ["QUOTA_FAKE_DIR"]
open(os.path.join(d, "pids"), "a").write("%d\n" % os.getpid())
want = ["--print", "--input-format=stream-json", "--output-format=stream-json", "--verbose",
        "--setting-sources", "", "--no-session-persistence", "--tools", "",
        "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
if sys.argv[1:] != want or "CLAUDECODE" in os.environ or os.getcwd() != "/":
    open(os.path.join(d, "refused"), "a").write(json.dumps([sys.argv[1:], os.getcwd()]) + "\n")
    sys.exit(3)
read = lambda n, dflt: (open(os.path.join(d, n)).read().strip() if os.path.exists(os.path.join(d, n)) else dflt)
mode = read("mode", "ok")
if mode == "hang":
    time.sleep(30); sys.exit(0)
if mode == "eof":
    sys.exit(0)
for line in sys.stdin:
    v = json.loads(line)
    kind = v["request"]["subtype"]
    open(os.path.join(d, "requests"), "a").write(kind + "\n")
    if kind == "initialize":
        body, sub = {}, "success"
    elif mode == "error":
        body, sub = {}, "error"
    elif mode == "unavailable":
        body, sub = {"rate_limits_available": False}, "success"
    else:
        used = read("used", "50")
        used = json.loads(used)
        reset = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(read("reset_in", "3600")))
        body = {"rate_limits_available": True, "rate_limits": {
            "five_hour": {"utilization": used if mode != "garbage" else "high", "resets_at": reset.isoformat()},
            "seven_day": {"utilization": 3, "resets_at": reset.isoformat()}}}
        sub = "success"
    print(json.dumps({"type": "control_response",
                      "response": {"subtype": sub, "request_id": v["request_id"], "response": body}}), flush=True)
time.sleep(30)
PY
chmod +x "$FAKE/claude"
export QUOTA_FAKE_DIR="$FAKE"
fake() { # <mode> [used] [reset-in] — resets the fixture's record
    printf '%s' "$1" >"$FAKE/mode"; printf '%s' "${2:-50}" >"$FAKE/used"; printf '%s' "${3:-3600}" >"$FAKE/reset_in"
    rm -f "$FAKE/requests" "$FAKE/refused"
    : >"$FAKE/pids.now"
}
last_fake_pid() { tail -1 "$FAKE/pids" 2>/dev/null; }
gonce() { OUT="$(QUOTA_CLAUDE_BIN="$FAKE/claude" bash "$Q" --once 2>&1)"; RC=$?; }

write_payload 50 3600 10
fake ok 95; gonce
check "G01  --once reads get_usage (95%), not the status-line file (50%): exit 1, via get_usage" \
    "$([ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '95% of the five-hour window.*via get_usage' \
       && ! printf '%s' "$OUT" | grep -q 'source: the status-line file' && [ ! -f "$FAKE/refused" ]; echo $?)" \
    "rc=$RC out=$OUT refused=$(cat "$FAKE/refused" 2>/dev/null)"
GPID="$(last_fake_pid)"
check "G02  the control-only process it started is ENDED after the read (it would have lingered 30 s), and it asked initialize then get_usage" \
    "$([ -n "$GPID" ] && ! kill -0 "$GPID" 2>/dev/null && [ "$(tr '\n' ' ' <"$FAKE/requests")" = "initialize get_usage " ]; echo $?)" \
    "pid=$GPID alive=$(kill -0 "$GPID" 2>/dev/null && echo yes || echo no) requests=$(cat "$FAKE/requests" 2>/dev/null)"

fake error; gonce
check "G03  get_usage refused: it falls back to the status-line file (50%, exit 0) and says why" \
    "$([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'via the status line' \
       && printf '%s' "$OUT" | grep -q 'source: the status-line file, because get_usage was refused'; echo $?)" "rc=$RC out=$OUT"
fake unavailable; gonce
check "G04  no subscription limits reported: the status-line fallback, and it says so" \
    "$([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'did not report subscription limits'; echo $?)" "rc=$RC out=$OUT"

fake hang
( export QUOTA_WATCH_GET_USAGE_SECONDS=2; QUOTA_CLAUDE_BIN="$FAKE/claude" bash "$Q" --once >"$SB/g05.out" 2>&1 ) &
WATCH_PID=$!; finish_watch 8; OUT="$(cat "$SB/g05.out")"; GPID="$(last_fake_pid)"
check "G05  a claude that never answers is BOUNDED: the fallback within the deadline, and the hung process ended" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'no answer to initialize within 2 s' \
       && ! kill -0 "$GPID" 2>/dev/null; echo $?)" "rc=$WRC out=$OUT pid=$GPID"

fake garbage; gonce; OUTG=$OUT; RCG=$RC
fake eof; gonce
check "G06  an unreadable answer and an early close both fall back to the status-line file, each saying why" \
    "$([ "$RCG" -eq 0 ] && printf '%s' "$OUTG" | grep -q 'cannot read' && [ "$RC" -eq 0 ] \
       && printf '%s' "$OUT" | grep -q 'closed its output'; echo $?)" "garbage: rc=$RCG $OUTG // eof: rc=$RC $OUT"

# W01 needs a worker, so it runs after the registry exists; see the E block.
write_payload 50 3 10
start_watch "$SB/w02.out"; finish_watch 10; OUT="$(cat "$SB/w02.out")"
check "W02  the reset passing wakes the lead: WINDOW-RESET with the resume message and no pause-until: line" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^WINDOW-RESET' && printf '%s' "$OUT" | grep -q 'RESUME:' \
       && ! printf '%s' "$OUT" | grep -q 'pause-until:'; echo $?)" "rc=$WRC out=$OUT"

# W03: 1203 s to the reset, so the first polls are outside the last 20 minutes
# (nothing working: nothing to pause) and the polls from about 4 s on are
# inside it (nobody held: nothing to release). It is still waiting at 8 s.
write_payload 96 1203 10
start_watch "$SB/w03.out"; finish_watch 8; OUT="$(cat "$SB/w03.out")"
check "W03  at the threshold with NOTHING working it does not fire, and with nobody held there is no QUOTA-RELEASE" \
    "$([ "$WRC" -eq 124 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD' && ! printf '%s' "$OUT" | grep -q '^QUOTA-RELEASE' \
       && printf '%s' "$OUT" | grep -q 'nothing to pause' && printf '%s' "$OUT" | grep -q 'less than 20 minutes: no pause'; echo $?)" "rc=$WRC out=$OUT"

write_payload 50 3 60
start_watch "$SB/w06.out"; finish_watch 10; OUT="$(cat "$SB/w06.out")"
check "W06  a stale reading with nothing working does NOT wake the lead" \
    "$([ "$WRC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-UNKNOWN' && printf '%s' "$OUT" | grep -q '^WINDOW-RESET'; echo $?)" "rc=$WRC out=$OUT"

# W13: a reading at the refresh point (27 s of a 30 s bound) with nothing
# working: there is no spend to hide, so the lead is not woken to refresh.
write_payload 50 3600 28
start_watch "$SB/w13.out"; finish_watch 3; OUT="$(cat "$SB/w13.out")"
check "W13  at the refresh point with nothing working, the lead is NOT woken to refresh" \
    "$([ "$WRC" -eq 124 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-REFRESH' && printf '%s' "$OUT" | grep -q 'no refresh needed'; echo $?)" "rc=$WRC out=$OUT"

# W09: his "every 5 minutes" is the default. The registry cannot name this
# session here (no session is given and none is recorded), so the watcher
# cannot rule out a running worker and fires at once, after its first line.
write_payload 95 3600 0
( unset QUOTA_WATCH_POLL_SECONDS RICHOS_SESSION_ID; bash "$Q" --watch >"$SB/w09.out" 2>&1 ) &
WATCH_PID=$!; finish_watch 10; OUT="$(cat "$SB/w09.out")"
check "W09  the default poll is his every 5 minutes (300 s), and an unnamed worker set still fires the threshold" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'polling every 300 s' && printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD' \
       && printf '%s' "$OUT" | grep -q 'live workers: UNKNOWN'; echo $?)" "rc=$WRC out=$OUT"

rm -f "$QUOTA_PAYLOAD"
start_watch "$SB/w07.out"; finish_watch 5; OUT="$(cat "$SB/w07.out")"
check "W07  no payload at all: --watch cannot watch, exit 2" \
    "$([ "$WRC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^QUOTA-UNKNOWN'; echo $?)" "rc=$WRC out=$OUT"

write_payload 50 3600 10; set_threshold __none__
start_watch "$SB/w08.out"; finish_watch 5; OUT="$(cat "$SB/w08.out")"
check "W08  no threshold declared: --watch cannot watch, exit 2" \
    "$([ "$WRC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'not declared'; echo $?)" "rc=$WRC out=$OUT"
set_threshold 93

# --- E: end to end through the real registry and the real resume guard ----
TX="$SB/tx"
mkdir -p "$TX/.claude/worktrees"
git -C "$TX" init -q -b main
printf 'seed\n' >"$TX/seed.txt"
git -C "$TX" add -A
git -C "$TX" commit -q -m seed
python3 "$WS_PY" --entity "$TX" --session "$SID" integration --repo "$TX" --branch main \
    --why "the quota-watch suite's body of work" >/dev/null
ws_spawn() { # <name> <agent-id>
    python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_use_id":"tu-"+sys.argv[2],"tool_name":"Agent","tool_input":{"name":sys.argv[2],"subagent_type":"dev","isolation":"worktree","prompt":"x"}}))' "$SID" "$1" \
        | python3 "$WS_PY" --entity "$TX" register-spawn >/dev/null
    git -C "$TX" worktree add -q -b "worktree-agent-$2" "$TX/.claude/worktrees/agent-$2"
    printf '{"hook_event_name":"PostToolUse","session_id":"%s","tool_use_id":"tu-%s","tool_name":"Agent","tool_input":{"name":"%s"},"tool_response":{"agentId":"%s"}}' "$SID" "$1" "$1" "$2" \
        | python3 "$WS_PY" --entity "$TX" hook >/dev/null
}
ws_send() { # <name> <message-file> — the lead's SendMessage, as the registry's PostToolUse sees it
    python3 - "$SID" "$1" "$2" <<'PY' | python3 "$WS_PY" --entity "$TX" hook >/dev/null
import json, sys
sid, to, path = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": sid, "tool_name": "SendMessage",
                  "tool_input": {"to": to, "message": open(path).read()}, "tool_response": {"success": True}}))
PY
}
ws_stop() { # <agent-id>
    printf '{"hook_event_name":"SubagentStop","session_id":"%s","agent_id":"%s"}' "$SID" "$1" \
        | python3 "$WS_PY" --entity "$TX" hook >/dev/null
}
recipient() { python3 "$WS_PY" --session "$SID" recipient --name "$1" 2>/dev/null | cut -f1; }
guard_wake() { # <name> — the resume guard's exit for a plain wake message
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"SendMessage","tool_input":{"to":sys.argv[1],"message":"RESUME: continue."},"session_id":sys.argv[2]}))' "$1" "$SID" \
        | bash "$GUARD" >/dev/null 2>&1
}
extract_message() { # <watch-output-file> <dest>
    sed -n '/---- message begins ----/,/---- message ends ----/p' "$1" | sed '1d;$d' | sed 's/^  //' >"$2"
}

HELD_AID="a0000000000qheld"
OLD_AID="a0000000000q0918"
ws_spawn dev-held "$HELD_AID"
ws_spawn dev-0918 "$OLD_AID"

# W01: crossing while two workers run, an hour before the reset.
write_payload 50 3600 5
start_watch "$SB/w01.out"
wait_for_line "$SB/w01.out" 'of the five-hour window' 5
write_payload 94 3600 0
finish_watch 10; OUT="$(cat "$SB/w01.out")"
check "W01  crossing wakes the lead: QUOTA-THRESHOLD with the pause-until: line, minutes to reset, live-worker count" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD 94%' \
       && printf '%s' "$OUT" | grep -qE '^  pause-until: the five-hour quota reset at [0-9]{2}:[0-9]{2}Z$' \
       && printf '%s' "$OUT" | grep -qE 'minutes to reset: (59|60)$' && printf '%s' "$OUT" | grep -q 'live workers: 2 working'; echo $?)" "rc=$WRC out=$OUT"
check "E01  at the threshold both running workers are named" \
    "$(printf '%s' "$OUT" | grep -q 'each working agent: dev-0918, dev-held'; echo $?)" "out=$OUT"

extract_message "$SB/w01.out" "$SB/pause.msg"
# The 2026-09-18 15:04Z hold message, verbatim from session 5645c662: it asked
# for exactly the right behavior and carried no pause-until: line.
cat >"$SB/0918.msg" <<'MSG'
PAUSE — CEO's standing quota rule: the five-hour window is at 92% used with 36 minutes to its reset and three workers are running. Finish the edit you are in the middle of, commit everything you have on your branch (atomic, with truthful messages; a WIP commit is fine and gets amended later), write one line in your worktree at .claude/PAUSED.md saying where you stopped and what comes next, and then STOP — make no further tool calls until you receive my message "RESUME". Do not hand off, do not mark the task complete.
MSG
ws_send dev-held "$SB/pause.msg"
ws_send dev-0918 "$SB/0918.msg"
ws_stop "$HELD_AID"
ws_stop "$OLD_AID"

check "E02  the printed pause message keeps its agent PAUSED through its own SubagentStop" \
    "$([ "$(recipient dev-held)" = paused ]; echo $?)" "registry says: $(recipient dev-held)"
guard_wake dev-held; GRC=$?
check "E03  the lead's wake message to the paused agent is ALLOWED by the resume guard" "$([ "$GRC" -eq 0 ]; echo $?)" "guard exit=$GRC"
guard_wake dev-0918; GRC=$?
check "E04  the 2026-09-18 message (no pause-until:) leaves a FINISHED agent, and its wake is REFUSED" \
    "$([ "$(recipient dev-0918)" = finished ] && [ "$GRC" -eq 2 ]; echo $?)" "registry says: $(recipient dev-0918), guard exit=$GRC"

# E05: his 2026-09-25 update. The hold releases when the reset is LESS than 20
# minutes away. 1203 s out, at the DEFAULT 300 s poll: the first poll is
# outside the window (nothing working, nothing to pause, nothing released),
# and the watcher must wake at the boundary about 4 s later, not a poll later.
write_payload 96 1203 0
( unset QUOTA_WATCH_POLL_SECONDS; bash "$Q" --watch >"$SB/e05.out" 2>&1 ) &
WATCH_PID=$!; finish_watch 12; OUT="$(cat "$SB/e05.out")"
check "E05  inside the last 20 minutes QUOTA-RELEASE names only the quota-paused agent, on time at the 300 s poll" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-RELEASE' && printf '%s' "$OUT" | grep -q 'with this message: dev-held$' \
       && printf '%s' "$OUT" | grep -q 'polling every 300 s' && printf '%s' "$OUT" | grep -q 'nothing to pause' \
       && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD' && ! printf '%s' "$OUT" | grep -q 'pause-until:'; echo $?)" "rc=$WRC out=$OUT"
extract_message "$SB/e05.out" "$SB/release.msg"
ws_send dev-held "$SB/release.msg"
check "E06  the printed release message resumes the SAME agent in the registry" \
    "$([ "$(recipient dev-held)" = active ] && grep -q 'less than 20 minutes from now' "$SB/release.msg"; echo $?)" \
    "registry says: $(recipient dev-held); message: $(cat "$SB/release.msg")"

# Held again, for the --until-reset release and the reset itself.
ws_send dev-held "$SB/pause.msg"
ws_stop "$HELD_AID"
write_payload 96 1202 0
( unset QUOTA_WATCH_POLL_SECONDS; bash "$Q" --watch --until-reset >"$SB/e07.out" 2>&1 ) &
WATCH_PID=$!; finish_watch 12; OUT="$(cat "$SB/e07.out")"
check "E07  --until-reset also wakes at the release when an agent is held" \
    "$([ "$(recipient dev-held)" != active ] && [ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-RELEASE' \
       && printf '%s' "$OUT" | grep -q 'with this message: dev-held$'; echo $?)" "registry says: $(recipient dev-held); rc=$WRC out=$OUT"

# A lead that starts the watcher after the reset has passed, with the agent
# still held: WINDOW-RESET names it.
write_payload 96 -5 0
start_watch "$SB/e08.out" --until-reset; finish_watch 10; OUT="$(cat "$SB/e08.out")"
check "E08  at the reset only the quota-paused agent is named to wake (and the threshold did not re-fire)" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^WINDOW-RESET' && printf '%s' "$OUT" | grep -q 'with this message: dev-held$' \
       && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD'; echo $?)" "rc=$WRC out=$OUT"
extract_message "$SB/e08.out" "$SB/resume.msg"
ws_send dev-held "$SB/resume.msg"
check "E09  the printed resume message resumes it in the registry" \
    "$([ "$(recipient dev-held)" = active ]; echo $?)" "registry says: $(recipient dev-held)"

# W04 / W05 / W10 / W11 need a worker running: dev-held is active again.
write_payload 97 3 0
start_watch "$SB/w04.out" --until-reset; finish_watch 10; OUT="$(cat "$SB/w04.out")"
check "W04  --until-reset never fires the threshold, only the reset" \
    "$([ "$WRC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD' && printf '%s' "$OUT" | grep -q '^WINDOW-RESET'; echo $?)" "rc=$WRC out=$OUT"
write_payload 50 3600 60
start_watch "$SB/w05.out"; finish_watch 10; OUT="$(cat "$SB/w05.out")"
check "W05  a stale reading with a worker running wakes the lead with QUOTA-STALE and tells it to refresh" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-STALE' && printf '%s' "$OUT" | grep -q 'REFRESH THE READING' \
       && printf '%s' "$OUT" | grep -q 'NOT the current value'; echo $?)" "rc=$WRC out=$OUT"

write_payload 96 1140 0
start_watch "$SB/w10.out"; finish_watch 3; OUT="$(cat "$SB/w10.out")"
check "W10  19 minutes to the reset with a worker running: no QUOTA-THRESHOLD, it says why and keeps watching" \
    "$([ "$WRC" -eq 124 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD' && ! printf '%s' "$OUT" | grep -q '^QUOTA-RELEASE' \
       && printf '%s' "$OUT" | grep -q 'less than 20 minutes: no pause'; echo $?)" "rc=$WRC out=$OUT"
write_payload 96 1260 0
start_watch "$SB/w11.out"; finish_watch 10; OUT="$(cat "$SB/w11.out")"
check "W11  21 minutes to the reset with a worker running: QUOTA-THRESHOLD" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD 96%' \
       && printf '%s' "$OUT" | grep -qE 'minutes to reset: (20|21)$'; echo $?)" "rc=$WRC out=$OUT"

# --- R01 / R02: this morning's log, replayed -------------------------------
# 2026-09-25, the lead's own watcher (session c47f83d0, task bm7x9unl0): the
# payload re-rendered only when the lead spoke, so five_hour sat at 56% from
# 00:43Z to 01:08Z, at 71% to 01:33Z, at 89% from 01:53Z to 02:13Z, and next
# read 100% at 02:18Z. Every line of that log reads resets_at=03:40Z. The 93%
# crossing was never seen.
#
# The replay: one real second is one five-minute poll. The payload is rewritten
# ONLY at the minutes that log shows a new value, exactly as the idle lead's
# status line did — and whenever the watcher wakes the lead with QUOTA-REFRESH
# or QUOTA-STALE,
# the "lead" replies, which re-renders the status line with the TRUE value
# (the log's change points joined by straight lines; usage grows between
# them). Each write carries the reset as the log does, as minutes from the
# simulated now, so the watcher sees the real time left.
#
#   R01  the real reset, 03:40Z: the alarm comes long before 100%, and
#        QUOTA-THRESHOLD fires while the true value is still below 100%, with
#        about 90 minutes to the reset, so the near-reset exception is not in
#        play and the pause stands
#   R02  the same log with the reset moved to 02:20Z: the true value crosses
#        93% at about 02:02Z, less than 20 minutes before the reset, so the
#        watcher says "no pause" and QUOTA-THRESHOLD never fires
replay() { # <label> <reset minute after midnight UTC> — writes $SB/<label>.report
    python3 - "$Q" "$QUOTA_PAYLOAD" "$SB/$1" "$2" >"$SB/$1.report" 2>&1 <<'PY'
import glob, json, os, re, subprocess, sys, time
q, payload, work, reset_min = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
os.makedirs(work, exist_ok=True)
# (sim minute after midnight UTC, value) — the minutes this morning's log first shows each value
renders = [(28, 49), (33, 51), (38, 54), (43, 56), (73, 71), (98, 81), (113, 89), (138, 100)]
def truth(m):
    for (m0, v0), (m1, v1) in zip(renders, renders[1:]):
        if m0 <= m <= m1:
            return int(v0 + (v1 - v0) * (m - m0) / float(m1 - m0))
    return renders[-1][1]
t0 = time.time()
sim = lambda: 28 + 5 * (time.time() - t0)
def write(v):
    now = time.time()
    tmp = payload + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({"rate_limits": {"five_hour": {"used_percentage": v,
                                                 "resets_at": int(now) + int((reset_min - sim()) * 60)}}}, fh)
    os.replace(tmp, payload)
env = dict(os.environ, QUOTA_WATCH_POLL_SECONDS="1", QUOTA_WATCH_STALE_SECONDS="1")
write(49)
done, first_alarm, stale_wakes, n = None, None, 0, 0
proc = None
next_render = 1
while sim() < 140 and done is None:
    if proc is None:
        n += 1
        out = open(os.path.join(work, "run%02d.out" % n), "w")
        proc = subprocess.Popen(["bash", q, "--watch"], stdout=out, stderr=subprocess.STDOUT, env=env)
    while next_render < len(renders) and sim() >= renders[next_render][0]:
        write(renders[next_render][1]); next_render += 1
    if proc.poll() is not None:
        text = open(os.path.join(work, "run%02d.out" % n)).read()
        m = sim()
        if "\nQUOTA-THRESHOLD" in "\n" + text:
            mins = re.search(r"minutes to reset: (\d+)", text)
            done = ("THRESHOLD", m, truth(m), int(mins.group(1)) if mins else None)
            first_alarm = first_alarm or m
        elif "\nQUOTA-STALE" in "\n" + text or "\nQUOTA-REFRESH" in "\n" + text:
            stale_wakes += 1
            first_alarm = first_alarm or m
            write(truth(m))          # the lead replies: its status line renders the true value
        else:
            done = ("OTHER", m, text[-400:], None)
        proc = None
        continue
    time.sleep(0.1)
if proc is not None and proc.poll() is None:
    proc.terminate(); proc.wait()
no_pause = any("less than 20 minutes: no pause" in open(f).read() for f in glob.glob(os.path.join(work, "run*.out")))
print(json.dumps({"done": done, "first_alarm_min": first_alarm, "stale_wakes": stale_wakes,
                  "said_no_pause": no_pause, "reset_min": reset_min}))
PY
}

replay r01 220
R01="$(tail -1 "$SB/r01.report")"
check "R01  this morning's log replayed with its real reset (03:40Z): the lead is woken to refresh while stuck at 56%, and QUOTA-THRESHOLD before 100% (02:18Z), far from the reset $R01" \
    "$(printf '%s' "$R01" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
kind, minute, val, mins = d["done"]
ok = (kind == "THRESHOLD" and minute < 138 and val < 100 and d["first_alarm_min"] < 73 and d["stale_wakes"] >= 1
      and mins is not None and mins >= 20 and abs(mins - (220 - minute)) <= 2 and not d["said_no_pause"])
sys.exit(0 if ok else 1)' 2>/dev/null; echo $?)" "report=$(cat "$SB/r01.report")"

replay r02 140
R02="$(tail -1 "$SB/r02.report")"
check "R02  the same log with the reset moved to 02:20Z: the crossing is inside the last 20 minutes, no pause $R02" \
    "$(printf '%s' "$R02" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
ok = d["done"] is None and d["said_no_pause"] and d["stale_wakes"] >= 1 and d["first_alarm_min"] < 73
sys.exit(0 if ok else 1)' 2>/dev/null; echo $?)" "report=$(cat "$SB/r02.report")"

# --- W12 / R03: the reading is refreshed BEFORE it turns one poll old -------
# 2026-09-25, measured: the lead read 91% at 07:57Z and 95% at 08:07Z, and the
# pause fired at 95%, not 93%. A reading counts as current up to one poll
# (300 s), so a loop polling every 300 s first saw it stale at its SECOND
# poll, about 600 s after the render: with the lead idle, the effective
# refresh was every 10 minutes against his "Keep it consistent at 5 minutes".
#
# W12: a 30 s bound (refresh point 27 s), a reading 25 s old with a worker
# running. The watcher must schedule its poll for the refresh point and wake
# the lead there, while the reading is still under 30 s old.
write_payload 50 3600 25
( export QUOTA_WATCH_POLL_SECONDS=30 QUOTA_WATCH_STALE_SECONDS=30; bash "$Q" --watch >"$SB/w12.out" 2>&1 ) &
WATCH_PID=$!; finish_watch 10; OUT="$(cat "$SB/w12.out")"
check "W12  below the threshold, the lead is woken with QUOTA-REFRESH before the reading turns one poll old" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-REFRESH' \
       && printf '%s' "$OUT" | grep -qE 'the reading is 2[0-9] s old and stops counting as current at 30 s'; echo $?)" "rc=$WRC out=$OUT"

# R03: this morning's shape, replayed. One poll is 10 real seconds standing for
# 300 (one real second is 30 simulated seconds). The true value grows from 91%
# at 07:57Z to 95% at 08:07Z, so it crosses 93% at 08:02Z. The payload is
# rewritten only when the watcher wakes the lead (the idle lead's reply
# renders the true value). Before the fix the lead was woken at 08:07Z with
# 95%; now every wake comes while the reading is under one poll old, and the
# threshold fires before 08:07Z at under 95%.
python3 - "$Q" "$QUOTA_PAYLOAD" "$SB/r03" >"$SB/r03.report" 2>&1 <<'PY'
import json, os, re, subprocess, sys, time
q, payload, work = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(work, exist_ok=True)
SCALE = 30.0                      # simulated seconds per real second
t0 = time.time()
sim = lambda: (time.time() - t0) * SCALE
truth = lambda s: int(91 + 4 * s / 600.0)
def write(v):
    now = time.time()
    with open(payload + ".tmp", "w") as fh:
        json.dump({"rate_limits": {"five_hour": {"used_percentage": v, "resets_at": int(now) + 7200}}}, fh)
    os.replace(payload + ".tmp", payload)
env = dict(os.environ, QUOTA_WATCH_POLL_SECONDS="10", QUOTA_WATCH_STALE_SECONDS="10")
write(91)
wake_ages, done, n = [], None, 0
while sim() < 900 and done is None:
    n += 1
    path = os.path.join(work, "run%02d.out" % n)
    proc = subprocess.Popen(["bash", q, "--watch"], stdout=open(path, "w"), stderr=subprocess.STDOUT, env=env)
    while proc.poll() is None and sim() < 900:
        time.sleep(0.05)
    if proc.poll() is None:
        proc.terminate(); proc.wait(); break
    text, s = open(path).read(), sim()
    m = re.search(r"^QUOTA-THRESHOLD (\d+)%", text, re.M)
    if m:
        done = ("THRESHOLD", s, int(m.group(1)))
        break
    m = re.search(r"^QUOTA-(REFRESH|STALE): the reading is (\d+) s old", text, re.M)
    if not m:
        done = ("OTHER", s, text[-300:])
        break
    wake_ages.append([m.group(1), int(m.group(2))])
    write(truth(s))               # the lead replies: its status line renders the true value
print(json.dumps({"done": done, "wake_ages": wake_ages}))
PY
R03="$(tail -1 "$SB/r03.report")"
check "R03  91% at 07:57Z, 95% at 08:07Z replayed: every wake is a REFRESH under one poll old, and the pause fires before 08:07Z under 95% $R03" \
    "$(printf '%s' "$R03" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
kind, s, val = d["done"]
ok = (kind == "THRESHOLD" and s < 600 and 93 <= val < 95 and d["wake_ages"]
      and all(k == "REFRESH" and age < 10 for k, age in d["wake_ages"]))
sys.exit(0 if ok else 1)' 2>/dev/null; echo $?)" "report=$(cat "$SB/r03.report")"

# --- G07 / G08 / R04: --watch with get_usage (a worker is running) ---------
# G07: get_usage answers at every poll, so a status-line file that is ten
# minutes old does not matter: no QUOTA-STALE, no QUOTA-REFRESH, one fresh
# get_usage per poll.
fake ok 60
write_payload 50 3600 600
( QUOTA_CLAUDE_BIN="$FAKE/claude" bash "$Q" --watch >"$SB/g07.out" 2>&1 ) &
WATCH_PID=$!; finish_watch 4; OUT="$(cat "$SB/g07.out")"
NGET="$(grep -c '^get_usage$' "$FAKE/requests" 2>/dev/null || true)"
check "G07  --watch takes a fresh get_usage at every poll: a stale status-line file wakes nobody" \
    "$([ "$WRC" -eq 124 ] && [ "${NGET:-0}" -ge 2 ] && printf '%s' "$OUT" | grep -q '60% of the five-hour window.*via get_usage' \
       && ! printf '%s' "$OUT" | grep -qE '^QUOTA-(STALE|REFRESH|UNKNOWN)'; echo $?)" "rc=$WRC get_usage=$NGET out=$OUT"

# G08: get_usage failing falls back to the file, and the file's rules wake the
# lead exactly as before: a stale reading is QUOTA-STALE, saying why.
fake error
write_payload 50 3600 60
( QUOTA_CLAUDE_BIN="$FAKE/claude" bash "$Q" --watch >"$SB/g08.out" 2>&1 ) &
WATCH_PID=$!; finish_watch 10; OUT="$(cat "$SB/g08.out")"
check "G08  get_usage failing falls back to the file, and a stale file still wakes the lead with QUOTA-STALE, saying why" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-STALE' \
       && printf '%s' "$OUT" | grep -q 'status-line file, because get_usage was refused'; echo $?)" "rc=$WRC out=$OUT"

# R04: this morning's shape again (91% at 07:57Z growing to 95% at 08:07Z), now
# read through get_usage, with the lead idle the whole time and the status-line
# file never rewritten after its first 91%. One poll is 5 real seconds standing
# for 300 (one real second is 60 simulated seconds). The poll at 08:02Z reads
# the true 93% and fires: no wake of the lead is needed to see it.
fake ok 91
python3 - "$Q" "$QUOTA_PAYLOAD" "$FAKE" "$SB/r04.out" >"$SB/r04.report" 2>&1 <<'PY'
import json, os, re, subprocess, sys, time
q, payload, fake, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
SCALE = 60.0
with open(payload, "w") as fh:
    json.dump({"rate_limits": {"five_hour": {"used_percentage": 91, "resets_at": int(time.time()) + 7200}}}, fh)
t0 = time.time()
sim = lambda: (time.time() - t0) * SCALE
env = dict(os.environ, QUOTA_CLAUDE_BIN=os.path.join(fake, "claude"),
           QUOTA_WATCH_POLL_SECONDS="5", QUOTA_WATCH_STALE_SECONDS="5")
proc = subprocess.Popen(["bash", q, "--watch"], stdout=open(out, "w"), stderr=subprocess.STDOUT, env=env)
while proc.poll() is None and sim() < 900:
    with open(os.path.join(fake, "used.tmp"), "w") as fh:
        fh.write(str(int(91 + 4 * sim() / 600.0)))
    os.replace(os.path.join(fake, "used.tmp"), os.path.join(fake, "used"))
    time.sleep(0.05)
s = sim()
if proc.poll() is None:
    proc.terminate(); proc.wait()
text = open(out).read()
m = re.search(r"^QUOTA-THRESHOLD (\d+)%", text, re.M)
print(json.dumps({"fired_at": s if m else None, "value": int(m.group(1)) if m else None,
                  "lead_woken": bool(re.search(r"^QUOTA-(STALE|REFRESH|UNKNOWN)", text, re.M)),
                  "via_get_usage": "via get_usage" in text}))
PY
R04="$(tail -1 "$SB/r04.report")"
check "R04  91% at 07:57Z, 95% at 08:07Z, lead idle, read through get_usage: the pause fires before 08:07Z under 95%, with no wake of the lead $R04" \
    "$(printf '%s' "$R04" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
ok = d["fired_at"] is not None and d["fired_at"] < 600 and 93 <= d["value"] < 95 and not d["lead_woken"] and d["via_get_usage"]
sys.exit(0 if ok else 1)' 2>/dev/null; echo $?)" "report=$(cat "$SB/r04.report") out=$(cat "$SB/r04.out")"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== quota-watch tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== quota-watch tests: all $PASS passed ==="

if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/quota-watch.mutation.sh" ]; then
    bash "$SCRIPT_DIR/quota-watch.mutation.sh" || exit 1
fi
exit 0
