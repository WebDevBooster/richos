#!/usr/bin/env bash
#
# stall-watch.test.sh: THE STALL WATCHER, PROVEN ON REAL SLOT HOLDERS, REAL
# WAITERS AND A FIXTURE TEAMMATE REGISTRY. Never the operator's
# ~/.richos-nightly slots, ~/.richos-waits, registry, transcripts or ledger.
#
# The CEO, 2026-09-28: "WHERE THE FUCK WAS THAT FUCKING WATCHER BEFORE???"
# Every case below fails on a checkout without scripts/stall-watch.sh.
#
#   S01  a proof-run slot wait over 10 min by one teammate behind another is
#        told ONCE: the waiter, "proof-run slot", its place in line, the
#        holder's name and pid, since when, the Mac's CPU, and `set 2`
#   S02  the next look says nothing (not repeated)
#   S03  after the repeat interval it is told once more, marked as still going
#   S04  the look after that says nothing again
#   S05  at 95% CPU the action is to reorder, not `set 2`
#   S06  the waiter ends: one miss clears nothing, the second look prints ONE
#        STALL-CLEARED line, and the third look says nothing
#   X01  a teammate waiting on a proof-run slot its OWN other process holds is
#        a SELF-WAIT at 3 minutes (never a plain WAIT), naming both pids
#   X02  not repeated
#   X03  cleared once when it ends
#   X04  two DIFFERENT teammates at 3 minutes: nothing is said at all
#   X05  ownership read from the inherited owner tag (agent_hold.py's
#        RICHOS_AGENT_OWNER), through the registry to the teammate's name,
#        though the two records carry different waiter names
#   X06  a holder that is the waiter's own ancestor is a DEADLOCK
#   W01  a test VM wait and a device wait over 10 min: one block, two stalls,
#        who holds each ("no holder recorded" / "not recorded by the waiter")
#   T01  a live teammate with no commit and no transcript write for 25 min is
#        SILENT: its name, last commit, last transcript write, what to do
#   T02  not repeated
#   T03  it writes its transcript: cleared after two looks, once
#   T04  a long honest run (transcript written 5 min ago, no commit for an
#        hour), a paused teammate and a finished one: none is SILENT
#   M01  END TO END: --monitor (the plugin monitor's command) on the fixture
#        prints the stall once over several looks, --alive says watching,
#        a second --monitor for the same session stands down, nothing it
#        watched was touched, and it ends with its session
#   M02  --alive with nothing watching: NOT WATCHED, exit 1
#   M03  --monitor in a repository that never adopted the engine: silent, 0
#   N01  the SessionStart hook: additionalContext only (no systemMessage),
#        names --monitor and the one-line --alive check, says it only reports
#   N02  the hook is silent where the engine was never adopted
#   N03  monitors.json starts `stall-watch.sh --monitor` always, and hooks.json
#        registers session-start-stall.sh once, under SessionStart
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/.." && pwd)"
SW="$SCRIPT_DIR/stall-watch.sh"
HOOK="$SCRIPT_DIR/hooks/session-start-stall.sh"
APP_LIB="$ENGINE/../app/scripts/lib"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 1; }

# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"
SB="$(scratch_new stall-watch-test)" || { echo "FATAL: no scratch" >&2; exit 1; }

# Every process this suite signals is one it started, its pid captured at
# spawn and kept in PIDS. Nothing is ever chosen by name.
PIDS=()
spawn_sleeper() { sh -c 'sleep 900 >/dev/null 2>&1 & echo $!'; }
cleanup() {
    local p f
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    # Every slot user writes its own pid at start (slotproc.py): this suite's.
    for f in "$SB"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
    scratch_release "$SB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1 -- $3"; fi; }
has()   { printf '%s' "$1" | grep -qF -- "$2"; }
count() { printf '%s' "$1" | grep -cF -- "$2" || true; }

# --- isolation -------------------------------------------------------------
unset CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT RICHOS_ENGINE_ROOT RICHOS_PROOF_RUN_SLOT_HELD
# This suite may itself run under a teammate's owner tag; its fixture
# processes must not inherit it, or every fixture would share one owner.
unset RICHOS_AGENT_OWNER RICHOS_AGENT_SESSION RICHOS_WAITER
SID="beadfeed-0000-4000-8000-00000000s001"
SLEEPER="$(spawn_sleeper)"; PIDS+=("$SLEEPER")
export RICHOS_ENTITY_ROOT="$SB/entity"
export RICHOS_SESSIONS_DIR="$SB/platform-sessions"
export RICHOS_PROJECTS_DIR="$SB/projects"
export RICHOS_SESSION_PID="$SLEEPER"
export RICHOS_SESSION_ID="$SID"
export RICHOS_WAITS_DIR="$SB/waits"
export RICHOS_PROOF_RUN_SLOTS_DIR="$SB/slots"
export TESTVM_ROOT="$SB/testvm"
export RICHOS_ESCALATION_LEDGER="$SB/escalations.jsonl"
export RICHOS_AGENT_HOLD_DIR="$SB/agent-hold"
export RICHOS_TEST_DEVICES_DIR="$SB/test-devices"
export STALL_WATCH_CPU_BUSY=30
mkdir -p "$RICHOS_ENTITY_ROOT" "$RICHOS_SESSIONS_DIR" "$RICHOS_PROJECTS_DIR" "$RICHOS_WAITS_DIR" \
         "$RICHOS_PROOF_RUN_SLOTS_DIR" "$TESTVM_ROOT" "$RICHOS_AGENT_HOLD_DIR"
printf 'PROTECTED_PATHS=""\n' >"$RICHOS_ENTITY_ROOT/orchestration.config"
printf '1\n' >"$RICHOS_PROOF_RUN_SLOTS_DIR/limit"

new_registry() { # <name>: an empty registry holding this suite's session
    export RICHOS_WORKSPACES_DIR="$SB/ws-$1"
    mkdir -p "$RICHOS_WORKSPACES_DIR/sessions" "$RICHOS_WORKSPACES_DIR/agents"
    python3 - "$ENGINE" "$RICHOS_WORKSPACES_DIR" "$SID" "${RICHOS_SESSION_PID}" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "mega-lander"))
import workspaces
st, start = workspaces.process_start(int(sys.argv[4]))
with open(os.path.join(sys.argv[2], "sessions", sys.argv[3] + ".json"), "w") as fh:
    json.dump({"session_id": sys.argv[3], "pid": int(sys.argv[4]), "pid_start": start}, fh)
PY
}
new_state() { export STALL_WATCH_STATE_DIR="$SB/state-$1"; }

add_agent() { # <name> <agent-id> <session> <started-ago-s> <commit-ago-s> <transcript-ago-s> [pause|end]
    python3 - "$ENGINE" "$SB" "$@" <<'PY'
import json, os, subprocess, sys, time
engine, sb, name, aid, sid, started, commit, tr = sys.argv[1:9]
extra = sys.argv[9] if len(sys.argv) > 9 else ""
sys.path.insert(0, os.path.join(engine, "mega-lander"))
import workspaces
# Whole seconds, like tick's `date +%s`: a fractional fixture clock made an age of
# exactly N minutes read as N-1 whenever tick ran inside the same second.
now = float(int(time.time()))
repo = os.path.join(sb, "repos", name)
os.makedirs(repo, exist_ok=True)
# Only the commit's DATE is the fixture's. The identity is the operator's own
# configured one (a machine-wide identity guard refuses any other, rightly),
# with a placeholder only where none is configured at all.
env = dict(os.environ)
env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = "@%d +0000" % int(now - float(commit))
ident = [] if subprocess.run(["git", "config", "--get", "user.email"], capture_output=True).stdout.strip() \
    else ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid"]
subprocess.run(["git", "init", "-q", "-b", "cc/" + name, repo], check=True, env=env)
subprocess.run(["git"] + ident + ["-C", repo, "commit", "-q", "--allow-empty", "-m", "work"], check=True, env=env)
reg = os.environ["RICHOS_WORKSPACES_DIR"]
sess = json.load(open(os.path.join(reg, "sessions", os.environ["RICHOS_SESSION_ID"] + ".json")))
rec = workspaces.new_record("%s--%s" % (sid, name), name=name, session_id=sid, agent_id=aid,
                            session_identity={"pid": sess["pid"], "pid_start": sess["pid_start"]},
                            started_at=workspaces.iso(now - float(started)),
                            workspaces=[{"kind": "cc", "repo": repo, "path": os.path.realpath(repo),
                                         "branch": "cc/" + name, "deleted_at": None}])
if extra == "pause":
    rec["pause"] = {"at": now - 60, "until": "the fixture's resume", "control": True}
if extra == "end":
    rec["end"] = {"at": now - 60, "signal": "SubagentStop", "detail": "fixture"}
    rec["handed_in"] = {"at": now - 61}
with open(os.path.join(reg, "agents", rec["key"] + ".json"), "w") as fh:
    json.dump(rec, fh)
tdir = os.path.join(os.environ["RICHOS_PROJECTS_DIR"], "fixture-project", sid, "subagents")
os.makedirs(tdir, exist_ok=True)
t = os.path.join(tdir, "agent-%s.jsonl" % aid)
open(t, "a").close()
os.utime(t, (now - float(tr), now - float(tr)))
PY
}
touch_transcript() { # <agent-id>
    python3 -c 'import os,sys; p=sys.argv[1]; os.utime(p, None)' \
        "$RICHOS_PROJECTS_DIR/fixture-project/$SID/subagents/agent-$1.jsonl"
}

# A real proof-run slot user, through the real slot library: it takes a slot
# (or waits in the real line, recording its wait) and then sleeps.
cat >"$SB/slotproc.py" <<'PY'
import os, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
import proof_slots
marker, sleep_s, child = sys.argv[2], float(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else ""
open(marker + ".pid", "w").write("%d\n" % os.getpid())
slot, waited = proof_slots.acquire({"selection": "fixture"}, wait_seconds=900)
open(marker, "w").write("held\n")
if child:
    # A nested run that does NOT borrow this slot: it waits behind its own parent.
    env = {k: v for k, v in os.environ.items() if k != proof_slots.HELD_ENV}
    subprocess.Popen([sys.executable, __file__, sys.argv[1], child, "600"], env=env)
time.sleep(sleep_s)
PY
SPID=""
start_slot() { # <waiter-name> <marker> [nested-child-marker|-] [owner-tag]; its pid lands in SPID
    # Called in THIS shell, never inside $(...): a pid recorded in a command
    # substitution's subshell never reaches the cleanup.
    local child="${3:-}"; [ "$child" = "-" ] && child=""
    ( cd "$SB" && if [ -n "${4:-}" ]; then export RICHOS_AGENT_OWNER="$4"; fi \
        && exec env RICHOS_WAITER="$1" python3 "$SB/slotproc.py" "$APP_LIB" "$2" 600 ${child:+"$child"} \
        >/dev/null 2>&1 ) &
    SPID=$!
    PIDS+=("$SPID")
    disown "$SPID" 2>/dev/null   # its end is this suite's doing, not news for the log
}
wait_for() { # <seconds> <test command...>
    local n="$1"; shift
    local i=0
    while [ "$i" -lt $((n * 10)) ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
    return 1
}
has_waiter() { ls "$RICHOS_PROOF_RUN_SLOTS_DIR"/wait-*.json >/dev/null 2>&1 && ls "$RICHOS_WAITS_DIR"/*.json >/dev/null 2>&1; }
no_waiter() { ! ls "$RICHOS_PROOF_RUN_SLOTS_DIR"/wait-*.json >/dev/null 2>&1; }
stop_slots() { # every slot user this suite started: each wrote its own pid at start
    local f
    for f in "$SB"/*.pid; do
        [ -f "$f" ] || continue
        kill "$(cat "$f")" 2>/dev/null
        rm -f "$f"
    done
    wait_for 10 no_waiter
    sleep 0.3
    rm -f "$RICHOS_WAITS_DIR"/*.json
}

tick() { # <now-offset-seconds>
    OUT="$(STALL_WATCH_NOW=$(( $(date +%s) + $1 )) bash "$SW" --tick 2>&1)"; RC=$?
}

echo "=== stall-watch tests ==="
[ -f "$SW" ] || echo "  (scripts/stall-watch.sh is missing: every case below fails)"
[ -d "$APP_LIB" ] || echo "  (the app tree is not beside this engine: the S and X cases fail)"

# --- S: a proof-run slot wait over 10 minutes --------------------------------
new_registry s; new_state s
start_slot alpha-opus-h1 "$SB/s-held"; H="$SPID"
wait_for 10 test -f "$SB/s-held"
start_slot bravo-opus-w1 "$SB/s-w-held"; W="$SPID"
wait_for 10 has_waiter
tick 660
check "S01  a slot wait over 10 min is told once: waiter, slot, place, holder and pid, CPU, set 2" \
    "$( [ "$(count "$OUT" "[WAIT]")" -eq 1 ] && has "$OUT" "[WAIT] bravo-opus-w1: waits for a proof-run slot" \
        && has "$OUT" "#1 in line, this Mac runs 1 at once" && has "$OUT" "alpha-opus-h1 (pid $H" \
        && has "$OUT" "30% busy" && has "$OUT" "proof_slots.py set 2" && has "$OUT" "(since "; echo $?)" "out=$OUT"
tick 720
check "S02  the next look says nothing" "$( [ -z "$OUT" ]; echo $?)" "out=$OUT"
tick 2530
check "S03  after the repeat interval: told once more, as still going" \
    "$( [ "$(count "$OUT" "[WAIT]")" -eq 1 ] && has "$OUT" "still, notice 2"; echo $?)" "out=$OUT"
tick 2590
check "S04  and then nothing again" "$( [ -z "$OUT" ]; echo $?)" "out=$OUT"
OUT="$(STALL_WATCH_CPU_BUSY=95 STALL_WATCH_NOW=$(( $(date +%s) + 660 )) bash "$SW" --once 2>&1)"; RC=$?
check "S05  at 95% CPU the action is to reorder, not another slot (and --once exits 1)" \
    "$( [ "$RC" -eq 1 ] && has "$OUT" "another slot would not run faster" && has "$OUT" "reorder" \
        && ! has "$OUT" "set 2"; echo $?)" "rc=$RC out=$OUT"
kill "$W" 2>/dev/null; wait_for 10 no_waiter
tick 2650; first="$OUT"
tick 2710; second="$OUT"
tick 2770; third="$OUT"
check "S06  the wait ends: cleared on the second miss, in one line, then silence" \
    "$( [ -z "$first" ] && [ "$(count "$second" "STALL-CLEARED")" -eq 1 ] && has "$second" "bravo-opus-w1" \
        && [ -z "$third" ]; echo $?)" "first=$first second=$second third=$third"
stop_slots

# --- X: waiting on your own slot --------------------------------------------
new_registry x; new_state x
start_slot charlie-opus-s1 "$SB/x-held"; H="$SPID"
wait_for 10 test -f "$SB/x-held"
start_slot charlie-opus-s1 "$SB/x-w-held"; W="$SPID"
wait_for 10 has_waiter
tick 180
check "X01  a self-wait is told at 3 min as SELF-WAIT, naming both pids" \
    "$( [ "$(count "$OUT" "[SELF-WAIT]")" -eq 1 ] && ! has "$OUT" "[WAIT]" && has "$OUT" "charlie-opus-s1" \
        && has "$OUT" "waiting: pid $W" && has "$OUT" "held by: pid $H" && has "$OUT" "ALSO charlie-opus-s1's" \
        && ! has "$OUT" "DEADLOCK"; echo $?)" "out=$OUT"
tick 240
check "X02  not repeated" "$( [ -z "$OUT" ]; echo $?)" "out=$OUT"
kill "$W" 2>/dev/null; wait_for 10 no_waiter
tick 300; tick 360
check "X03  cleared once when it ends" "$( [ "$(count "$OUT" "STALL-CLEARED")" -eq 1 ]; echo $?)" "out=$OUT"
stop_slots

new_state x4
start_slot delta-opus-h2 "$SB/x4-held"; H="$SPID"
wait_for 10 test -f "$SB/x4-held"
start_slot echo-opus-w2 "$SB/x4-w-held"; W="$SPID"
wait_for 10 has_waiter
tick 180
check "X04  two different teammates at 3 min: nothing is said" "$( [ -z "$OUT" ]; echo $?)" "out=$OUT"
stop_slots

new_registry x5; new_state x5
add_agent hotel-opus-t1 a0000000000fix5 "other-session" 60 30 10
start_slot foxtrot-a "$SB/x5-held" - a0000000000fix5; H="$SPID"
wait_for 10 test -f "$SB/x5-held"
start_slot golf-b "$SB/x5-w-held" - a0000000000fix5; W="$SPID"
wait_for 10 has_waiter
tick 180
check "X05  the owner tag names the teammate through the registry, whatever the waiter names say" \
    "$( has "$OUT" "[SELF-WAIT] hotel-opus-t1" && has "$OUT" "known from its owner tag"; echo $?)" "out=$OUT"
stop_slots

new_registry x6; new_state x6
start_slot india-opus-n1 "$SB/x6-held" "$SB/x6-child-held"; H="$SPID"
wait_for 10 test -f "$SB/x6-held"
wait_for 10 has_waiter
tick 180
check "X06  a holder that is the waiter's own ancestor is a DEADLOCK" \
    "$( has "$OUT" "[SELF-WAIT] india-opus-n1" && has "$OUT" "DEADLOCK" && has "$OUT" "held by: pid $H"; echo $?)" "out=$OUT"
# The nested child is this suite's too: it wrote its own pid at start.
[ -f "$SB/x6-child-held.pid" ] && kill "$(cat "$SB/x6-child-held.pid")" 2>/dev/null
stop_slots

# --- W: other recorded waits ---------------------------------------------------
new_registry w; new_state w
VMW="$(spawn_sleeper)"; PIDS+=("$VMW")
DEVW="$(spawn_sleeper)"; PIDS+=("$DEVW")
sleep 1.1
python3 - "$RICHOS_WAITS_DIR" "$VMW" "$DEVW" <<'PY'
import json, os, sys, time
d, vm, dev = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
for pid, res, who in ((vm, "testvm-slot", "juliet-opus-v1"), (dev, "android-device", "kilo-opus-d1")):
    with open(os.path.join(d, "%d-fixture.json" % pid), "w") as fh:
        json.dump({"schema": "richos-wait/1", "pid": pid, "since": time.time(), "resource": res,
                   "waiter": who, "reason": "fixture", "holding": [], "cwd": d, "command": "fixture"}, fh)
PY
tick 660
check "W01  a VM wait and a device wait: one block, two stalls, who holds each" \
    "$( [ "$(count "$OUT" "STALL-WATCH")" -eq 1 ] && has "$OUT" "2 stalls" \
        && has "$OUT" "[WAIT] juliet-opus-v1: waits for the test VM" && has "$OUT" "NO HOLDER IS RECORDED" \
        && has "$OUT" "[WAIT] kilo-opus-d1: waits for android-device" && has "$OUT" "not recorded by the waiter"; \
        echo $?)" "out=$OUT"
rm -f "$RICHOS_WAITS_DIR"/*.json

# --- T: silent teammates ------------------------------------------------------
new_registry t; new_state t
add_agent lima-opus-q1 a0000000000fixq "$SID" 3600 3000 1500
add_agent mike-opus-r1 a0000000000fixr "$SID" 3600 3500 300
add_agent november-opus-p1 a0000000000fixp "$SID" 3600 3500 3000 pause
add_agent oscar-opus-e1 a0000000000fixe "$SID" 3600 3500 3000 end
tick 0
check "T01  no commit and no transcript write for 25 min: SILENT, with last commit, transcript, action" \
    "$( [ "$(count "$OUT" "[SILENT]")" -eq 1 ] && has "$OUT" "[SILENT] lima-opus-q1: no commit and no transcript activity, for 25 min" \
        && has "$OUT" "on cc/lima-opus-q1" && has "$OUT" "last transcript write" && has "$OUT" "SendMessage to lima-opus-q1"; \
        echo $?)" "out=$OUT"
T01OUT="$OUT"
tick 60
check "T02  not repeated" "$( [ -z "$OUT" ]; echo $?)" "out=$OUT"
touch_transcript a0000000000fixq
tick 120; tick 180
check "T03  it writes its transcript: cleared once, after two looks" \
    "$( [ "$(count "$OUT" "STALL-CLEARED")" -eq 1 ] && has "$OUT" "lima-opus-q1"; echo $?)" "out=$OUT"
check "T04  a long honest run, a paused teammate and a finished one are not SILENT" \
    "$( has "$T01OUT" "[SILENT] lima-opus-q1" && ! has "$T01OUT" "mike-opus-r1" && ! has "$T01OUT" "november-opus-p1" \
        && ! has "$T01OUT" "oscar-opus-e1"; echo $?)" \
    "out=$T01OUT"

# --- M: the monitor end to end --------------------------------------------------
SESS2="$(spawn_sleeper)"; PIDS+=("$SESS2")
export RICHOS_SESSION_PID="$SESS2"
new_registry m; new_state m
add_agent papa-opus-m1 a0000000000fixm "$SID" 3600 3000 1500
( STALL_WATCH_POLL_SECONDS=1 exec bash "$SW" --monitor >"$SB/monitor.out" 2>"$SB/monitor.err" ) &
MON=$!; PIDS+=("$MON")
wait_for 15 grep -q "SILENT" "$SB/monitor.out"
sleep 4
MOUT="$(cat "$SB/monitor.out")"
ALIVE="$(bash "$SW" --alive 2>&1)"; ARC=$?
( STALL_WATCH_POLL_SECONDS=1 exec bash "$SW" --monitor >"$SB/monitor2.out" 2>&1 ) &
MON2=$!; PIDS+=("$MON2")
wait_for 10 sh -c "! kill -0 $MON2 2>/dev/null"
SECOND_GONE=$?
kill -0 "$SLEEPER" 2>/dev/null; UNTOUCHED=$?
kill "$SESS2" 2>/dev/null
wait_for 15 sh -c "! kill -0 $MON 2>/dev/null"; ENDED=$?
check "M01  --monitor tells the stall once over several looks, --alive says watching, one per session, touches nothing, ends with its session" \
    "$( [ "$(count "$MOUT" "[SILENT] papa-opus-m1")" -eq 1 ] && [ "$ARC" -eq 0 ] && has "$ALIVE" "watching" \
        && [ "$SECOND_GONE" -eq 0 ] && [ ! -s "$SB/monitor2.out" ] && [ "$UNTOUCHED" -eq 0 ] && [ "$ENDED" -eq 0 ]; echo $?)" \
    "out=$MOUT alive=$ALIVE arc=$ARC second_gone=$SECOND_GONE untouched=$UNTOUCHED ended=$ENDED err=$(cat "$SB/monitor.err")"
export RICHOS_SESSION_PID="$SLEEPER"

new_state m2
ALIVE="$(bash "$SW" --alive 2>&1)"; ARC=$?
check "M02  --alive with nothing watching: NOT WATCHED, exit 1, and the fallback command" \
    "$( [ "$ARC" -eq 1 ] && has "$ALIVE" "NOT WATCHED" && has "$ALIVE" "stall-watch.sh --watch"; echo $?)" "rc=$ARC out=$ALIVE"

mkdir -p "$SB/not-adopted"
OUT="$(RICHOS_ENTITY_ROOT="$SB/not-adopted" bash "$SW" --monitor 2>&1)"; RC=$?
check "M03  a repository that never adopted the engine: the monitor is silent and exits 0" \
    "$( [ "$RC" -eq 0 ] && [ -z "$OUT" ]; echo $?)" "rc=$RC out=$OUT"

# --- N: the SessionStart notice and the wiring ---------------------------------
OUT="$(bash "$HOOK" </dev/null 2>&1)"; RC=$?
check "N01  the hook: additionalContext only, names --monitor and the --alive check, only reports" \
    "$( [ "$RC" -eq 0 ] && printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d["hookSpecificOutput"]["additionalContext"]
ok = ("systemMessage" not in d and d["hookSpecificOutput"]["hookEventName"] == "SessionStart"
      and "stall-watch.sh --monitor" in c and "stall-watch.sh --alive" in c
      and "It only reports" in c and "never pauses, stops or kills" in c)
sys.exit(0 if ok else 1)'; echo $?)" "rc=$RC out=$OUT"
OUT="$(RICHOS_ENTITY_ROOT="$SB/not-adopted" bash "$HOOK" </dev/null 2>&1)"; RC=$?
check "N02  the hook is silent where the engine was never adopted" "$( [ "$RC" -eq 0 ] && [ -z "$OUT" ]; echo $?)" "rc=$RC out=$OUT"
python3 - "$ENGINE" <<'PY'; RC=$?
import json, os, sys
e = sys.argv[1]
mons = json.load(open(os.path.join(e, "monitors", "monitors.json")))
m = [x for x in mons if x.get("name") == "stall-watch"]
hooks = json.load(open(os.path.join(e, "hooks", "hooks.json")))["hooks"]
cmds = [h.get("command", "") for event, groups in hooks.items() for g in groups for h in g.get("hooks", [])
        if "session-start-stall.sh" in h.get("command", "")]
start = [h.get("command", "") for g in hooks.get("SessionStart", []) for h in g.get("hooks", [])
         if "session-start-stall.sh" in h.get("command", "")]
ok = (len(m) == 1 and m[0].get("when") == "always" and m[0]["command"].endswith("/scripts/stall-watch.sh --monitor")
      and len(cmds) == 1 and len(start) == 1)
sys.exit(0 if ok else 1)
PY
check "N03  monitors.json starts stall-watch.sh --monitor always; hooks.json registers session-start-stall.sh once at SessionStart" \
    "$RC" "monitors.json or hooks.json wiring"

if [ "$FAIL" -gt 0 ]; then
    echo "=== stall-watch tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== stall-watch tests: all $PASS passed ==="
exit 0
