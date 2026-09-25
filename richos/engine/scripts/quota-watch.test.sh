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
#            fire: there is nothing to pause, and it waits for the reset
#   W04      --watch --until-reset never fires the threshold, only the reset
#   W05      a stale reading with a worker running wakes the lead with
#            QUOTA-UNKNOWN (the watcher is blind)
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
#              E05  at the reset only the quota-paused agent is named to wake
#              E06  the printed resume message resumes it in the registry
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

# W01 needs a worker, so it runs after the registry exists; see the E block.
write_payload 50 3 10
start_watch "$SB/w02.out"; finish_watch 10; OUT="$(cat "$SB/w02.out")"
check "W02  the reset passing wakes the lead: WINDOW-RESET with the resume message and no pause-until: line" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^WINDOW-RESET' && printf '%s' "$OUT" | grep -q 'RESUME:' \
       && ! printf '%s' "$OUT" | grep -q 'pause-until:'; echo $?)" "rc=$WRC out=$OUT"

write_payload 96 3 10
start_watch "$SB/w03.out"; finish_watch 10; OUT="$(cat "$SB/w03.out")"
check "W03  at the threshold with NOTHING working it does not fire; it waits for the reset" \
    "$([ "$WRC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD' && printf '%s' "$OUT" | grep -q '^WINDOW-RESET' \
       && printf '%s' "$OUT" | grep -q 'nothing to pause'; echo $?)" "rc=$WRC out=$OUT"

write_payload 50 3 60
start_watch "$SB/w06.out"; finish_watch 10; OUT="$(cat "$SB/w06.out")"
check "W06  a stale reading with nothing working does NOT wake the lead" \
    "$([ "$WRC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-UNKNOWN' && printf '%s' "$OUT" | grep -q '^WINDOW-RESET'; echo $?)" "rc=$WRC out=$OUT"

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

# W01: crossing while two workers run.
write_payload 50 600 5
start_watch "$SB/w01.out"
wait_for_line "$SB/w01.out" 'of the five-hour window' 5
write_payload 94 600 0
finish_watch 10; OUT="$(cat "$SB/w01.out")"
check "W01  crossing wakes the lead: QUOTA-THRESHOLD with the pause-until: line, minutes to reset, live-worker count" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD 94%' \
       && printf '%s' "$OUT" | grep -qE '^  pause-until: the five-hour quota reset at [0-9]{2}:[0-9]{2}Z$' \
       && printf '%s' "$OUT" | grep -qE 'minutes to reset: (9|10)$' && printf '%s' "$OUT" | grep -q 'live workers: 2 working'; echo $?)" "rc=$WRC out=$OUT"
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

write_payload 96 3 0
start_watch "$SB/e05.out"; finish_watch 10; OUT="$(cat "$SB/e05.out")"
check "E05  at the reset only the quota-paused agent is named to wake (and the threshold did not re-fire)" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^WINDOW-RESET' && printf '%s' "$OUT" | grep -q 'with this message: dev-held$' \
       && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD'; echo $?)" "rc=$WRC out=$OUT"
extract_message "$SB/e05.out" "$SB/resume.msg"
ws_send dev-held "$SB/resume.msg"
check "E06  the printed resume message resumes it in the registry" \
    "$([ "$(recipient dev-held)" = active ]; echo $?)" "registry says: $(recipient dev-held)"

# W04 / W05 need a worker running: dev-held is active again.
write_payload 97 3 0
start_watch "$SB/w04.out" --until-reset; finish_watch 10; OUT="$(cat "$SB/w04.out")"
check "W04  --until-reset never fires the threshold, only the reset" \
    "$([ "$WRC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^QUOTA-THRESHOLD' && printf '%s' "$OUT" | grep -q '^WINDOW-RESET'; echo $?)" "rc=$WRC out=$OUT"
write_payload 50 3600 60
start_watch "$SB/w05.out"; finish_watch 10; OUT="$(cat "$SB/w05.out")"
check "W05  a stale reading with a worker running wakes the lead with QUOTA-UNKNOWN" \
    "$([ "$WRC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^QUOTA-UNKNOWN' && printf '%s' "$OUT" | grep -q 'stale'; echo $?)" "rc=$WRC out=$OUT"

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
