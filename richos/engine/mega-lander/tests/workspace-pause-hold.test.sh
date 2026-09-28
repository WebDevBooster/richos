#!/usr/bin/env bash
#
# workspace-pause-hold.test.sh — a pause frees the Mac at once and keeps the work.
#
# The CEO (2026-09-10): "once it crosses the 93% threshold: PAUSE subagents. Then
# resume after quota rest." (2026-09-25): "Not stop, PAUSE." On 2026-09-27 a pause
# reached each agent only at its next tool call, so running commands kept the CPU
# for minutes, and one had to be interrupted, which lost its run.
#
# End to end, through the hooks the platform runs, in a sandbox: an agent is
# registered by the spawn guard and the lifecycle hook, its Bash call is rewritten
# by the real shell-evidence.sh and run as the harness runs it (a shell leading its
# own session, as Claude Code 2.1.283 starts it: ps shows `Ss`), and the lead's generated PAUSE and RESUME go through the
# PostToolUse[SendMessage] lifecycle hook. Asserted: the running work is suspended
# within seconds and uses no CPU while held, and its foreground call returns the
# WAIT at once so the harness hands over the queued message (2026-09-28); a new
# command of the held agent is refused at once with the WAIT and runs nothing; after
# RESUME the same processes finish with the right result and the agent's wait prints
# it; a stop and a session end never leave work suspended. Only processes this test
# started are ever signaled.
#
# Usage: workspace-pause-hold.test.sh [--keep]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/../.." && pwd)"
HOOKS="$ENGINE/scripts/hooks"
LIB="$ENGINE/scripts/lib"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
SHELL_BIN="$(command -v zsh || echo /bin/sh)"

RUN=0; RED=0
sub() { # <label> <cond> [detail]
    RUN=$((RUN + 1))
    if eval "$2"; then printf '  ok    %s\n' "$1"; else
        printf '  FAIL  %s\n' "$1"; RED=$((RED + 1))
        [ -n "${3:-}" ] && printf '        %s\n' "$(printf '%s' "$3" | head -c 800 | tr '\n' ' ')"
    fi
}

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ws-pause-hold.XXXXXX")" && pwd -P)"
OURS=()   # every pid this test started, recorded at spawn
cleanup() {
    for p in "${OURS[@]+"${OURS[@]}"}"; do kill -CONT "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
    if [ "$KEEP" -eq 1 ]; then echo "sandbox kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/home/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
export GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
printf '[user]\n\tname = hold\n\temail = hold@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
unset RICHOS_WORKSPACES_DIR RICHOS_SESSION_ID CLAUDE_PROJECT_DIR RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT RICHOS_SESSION_PID RICHOS_AGENT_HOLD_DIR 2>/dev/null || true
export SEAL_WAIT_SECONDS=0 RICHOS_WORKSPACES_SPAWN_WINDOW=0 RICHOS_WORKSPACES_STOP_GRACE=1 RICHOS_WORKSPACES_RETRY_BASE=0
export TESTVM_ROOT="$T/testvm" RICHOS_CPU_GUARD_STATE="$T/cpu-guard"
export RICHOS_AGENT_HOLD_WATCH_SECONDS=0.5     # the watchdog polls faster than its 5 s default
mkdir -p "$TESTVM_ROOT"
STORE="$CLAUDE_CONFIG_DIR/state/workspaces"
HOLD_STATE="$CLAUDE_CONFIG_DIR/state/agent-hold"

ENT="$T/entity"
mkdir -p "$ENT" && git init -q -b main "$ENT"
printf 'x\n' > "$ENT/README"
cp "$ENGINE/orchestration.config" "$ENT/orchestration.config"
printf '.claude/\n.env\n' > "$ENT/.gitignore"
git -C "$ENT" add -A && git -C "$ENT" commit -q -m init
export RICHOS_ENTITY_ROOT="$ENT"

payload() { python3 -c 'import json,sys; d=json.loads(sys.argv[2]); d["hook_event_name"]=sys.argv[1]; print(json.dumps(d))' "$1" "$2"; }
lifecycle() { bash "$HOOKS/workspace-lifecycle.sh"; }
start_session() { # <session-id>  the "session process" is a sleeper this test owns
    local pid
    pid="$(sh -c 'sleep 3600 >/dev/null 2>&1 & echo $!')"; OURS+=("$pid")
    export RICHOS_SESSION_PID="$pid"; CUR_SID="$1"
    payload SessionStart "{\"session_id\":\"$1\",\"cwd\":\"$ENT\"}" | lifecycle >"$T/start.out" 2>>"$T/hooks.err"
}
register_agent() { # <name> <agent-id>
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":sys.argv[1],"tool_use_id":"tu-"+sys.argv[2],"tool_name":"Agent","cwd":sys.argv[3],"tool_input":{"name":sys.argv[2],"subagent_type":"zach","isolation":"worktree","prompt":"work that gets paused"}}))' "$CUR_SID" "$1" "$ENT" \
        | bash "$HOOKS/guard-worktree-isolation.sh" >/dev/null 2>"$T/spawn.err"
    local np="$ENT/.claude/worktrees/agent-$2"
    git -C "$ENT" worktree add -q "$np" -b "worktree-agent-$2"
    payload SubagentStart "{\"session_id\":\"$CUR_SID\",\"agent_id\":\"$2\",\"agent_type\":\"zach\",\"cwd\":\"$np\"}" | lifecycle >/dev/null 2>>"$T/hooks.err"
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","session_id":sys.argv[1],"tool_use_id":"tu-"+sys.argv[2],"tool_name":"Agent","cwd":sys.argv[4],"tool_input":{"name":sys.argv[2],"isolation":"worktree"},"tool_response":{"agentId":sys.argv[3],"status":"async_launched"}}))' "$CUR_SID" "$1" "$2" "$ENT" \
        | lifecycle >/dev/null 2>>"$T/hooks.err"
}
send() { # <to> <message> <out-file>  the lead's PostToolUse[SendMessage]; the hook's output kept
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","session_id":sys.argv[1],"tool_name":"SendMessage","cwd":sys.argv[4],"tool_input":{"to":sys.argv[2],"message":sys.argv[3]},"tool_response":{}}))' "$CUR_SID" "$1" "$2" "$ENT" \
        | lifecycle >"$3" 2>>"$T/hooks.err"
}
PAUSE_TEXT="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pause_protocol as p; print(p.render("manual"))' "$LIB")"
RESUME_TEXT="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pause_protocol as p; print(p.render_resume("manual"))' "$LIB")"

# One Bash call of the agent: rewritten by the real hook, run as the harness runs it.
cat > "$T/launch.py" <<'PY'
import subprocess, sys
shell, cmd, pidfile, rcfile = sys.argv[1:5]
out = open(rcfile[:-3] + ".stdout", "w")
p = subprocess.Popen([shell, "-c", cmd], start_new_session=True, stdout=out, stderr=subprocess.STDOUT,
                     stdin=subprocess.DEVNULL)
open(pidfile, "w").write(str(p.pid))
rc = p.wait()          # the rc file appears only once the call has ended
open(rcfile, "w").write(str(rc))
PY
cat > "$T/worker.py" <<'PY'
import hashlib, os, sys
out, rounds = sys.argv[1], int(sys.argv[2])
open(out + ".pid", "w").write(str(os.getpid()))
h = b"richos"
for i in range(rounds):
    h = hashlib.sha256(h).digest()
    if i % 20000 == 0:
        open(out + ".progress", "w").write(str(i))
open(out, "w").write(h.hex())
PY
ROUNDS=4000000     # several seconds of work: a shorter run can finish before the pause lands
EXPECTED="$(python3 -c 'import hashlib,sys
h=b"richos"
for _ in range(int(sys.argv[1])): h=hashlib.sha256(h).digest()
print(h.hex())' "$ROUNDS")"

agent_call() { # <agent-id> <tool_use_id> <command> <tag> [bg]  -> starts it; shell pid in $T/<tag>.shell
    local rewritten
    rewritten="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":sys.argv[1],"agent_id":sys.argv[2],"tool_use_id":sys.argv[3],"tool_name":"Bash","cwd":sys.argv[5],"tool_input":{"command":sys.argv[4],"run_in_background":sys.argv[6]=="bg"}}))' "$CUR_SID" "$1" "$2" "$3" "$ENT" "${5:-fg}" \
        | bash "$HOOKS/shell-evidence.sh" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["updatedInput"]["command"])')"
    python3 "$T/launch.py" "$SHELL_BIN" "$rewritten" "$T/$4.shell" "$T/$4.rc" &
    OURS+=("$!")
    local i=0; while [ ! -s "$T/$4.shell" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    OURS+=("$(cat "$T/$4.shell")")
}
wait_file() { local i=0; while [ ! -s "$1" ] && [ $i -lt "${2:-400}" ]; do sleep 0.05; i=$((i + 1)); done; [ -s "$1" ]; }
pstate() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' '; }
is_stopped() { case "$(pstate "$1")" in T*) return 0;; *) return 1;; esac; }
children_of() { ps -A -o pid=,ppid= | awk -v p="$1" '$2 == p {print $1}'; }

start_session "sess-hold-1111"
# Point 14: a spawn is registered only when this body of work's branch is recorded.
python3 "$ENGINE/mega-lander/workspaces.py" --entity "$ENT" --session "$CUR_SID" integration --repo "$ENT" --branch main \
    --why "the pause-hold suite's body of work" >/dev/null 2>>"$T/hooks.err"
AID="aholdholdholdhold"
register_agent "zach-opus-hold1" "$AID"
sub "H0 the agent is registered with its id" "grep -q '\"agent_id\": \"$AID\"' \"\$(ls $STORE/agents/*--zach-opus-hold1.json)\"" "$(cat "$T/spawn.err" "$T/hooks.err" 2>/dev/null)"

echo "=== H1 PAUSE suspends the running work at once; it uses no CPU while held ==="
agent_call "$AID" "toolu_work1" "python3 $T/worker.py $T/w1 $ROUNDS" w1
wait_file "$T/w1.progress"; W1="$(cat "$T/w1.pid")"; OURS+=("$W1"); SH1="$(cat "$T/w1.shell")"
T0="$(python3 -c 'import time; print(time.time())')"
send "zach-opus-hold1" "$PAUSE_TEXT" "$T/pause.out"
T1="$(python3 -c 'import time; print(time.time())')"
cpu() { ps -o time= -p "$1" | tr -d ' '; }
C1="$(cpu "$W1")"; P1="$(cat "$T/w1.progress")"; sleep 1.5; C2="$(cpu "$W1")"; P2="$(cat "$T/w1.progress")"
sub "H1.1 the worker is suspended when the pause hook returns ($(pstate "$W1"))" "is_stopped $W1" "$(cat "$T/pause.out")"
wait_file "$T/w1.rc" 100
sub "H1.1b its foreground call has returned the WAIT, so the queued message reaches the agent now (rc $(cat "$T/w1.rc" 2>/dev/null))" \
    "[ \"\$(cat $T/w1.rc 2>/dev/null)\" = 0 ] && grep -q '^WAIT: the orchestrator has told you to wait while this command was running' '$T/w1.stdout' && ! kill -0 $SH1 2>/dev/null" "$(cat "$T/w1.stdout" 2>/dev/null)"
sub "H1.2 it uses no CPU and makes no progress while held (cpu $C1 -> $C2, progress $P1 -> $P2)" "[ '$C1' = '$C2' ] && [ '$P1' = '$P2' ]"
sub "H1.3 the lead is told, measured, in its own context" \
    "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d[\"hookSpecificOutput\"][\"additionalContext\"]; sys.exit(0 if \"HOLD zach-opus-hold1:\" in c and \"suspended in\" in c else 1)' '$T/pause.out'" "$(cat "$T/pause.out")"
sub "H1.4 the registry records the pause" "grep -q '\"until\": \"the user' \"\$(ls $STORE/agents/*--zach-opus-hold1.json)\""
printf '  measured: pause hook returned %.2f s after the send began; %s\n' "$(python3 -c "print($T1 - $T0)")" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"])' "$T/pause.out" 2>/dev/null)"

echo "=== H2 a NEW command of the held agent returns the WAIT at once and runs nothing (Sage's catch B) ==="
agent_call "$AID" "toolu_late1" "python3 -c \"open('$T/late.ran','w').write('ran')\"" late
wait_file "$T/late.rc" 100
sub "H2.1 the new call returned at once, refused with the WAIT (rc $(cat "$T/late.rc" 2>/dev/null))" \
    "[ \"\$(cat $T/late.rc 2>/dev/null)\" = 75 ] && grep -q 'so this command did not run' '$T/late.stdout'" "$(cat "$T/late.stdout" 2>/dev/null)"
sub "H2.2 its command did not run" "[ ! -e '$T/late.ran' ]"

echo "=== H3 the generated RESUME continues the same work, which finishes correctly ==="
send "zach-opus-hold1" "$RESUME_TEXT" "$T/resume.out"
sub "H3.1 the lead is told what continued" "grep -q 'RELEASE zach-opus-hold1:' '$T/resume.out'" "$(cat "$T/resume.out")"
WAITCMD="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pause_protocol as p; print(p.WAIT_COMMAND.replace("~/.claude/richos-engine", sys.argv[2]))' "$LIB" "$ENGINE")"
agent_call "$AID" "toolu_wait1" "$WAITCMD" wait1
wait_file "$T/wait1.rc" 1200
sub "H3.2 the held worker finished with the correct result" "[ \"\$(cat $T/w1 2>/dev/null)\" = '$EXPECTED' ]"
sub "H3.3 the agent's wait prints RESUMED and the frozen command's own exit status" \
    "grep -q '^RESUMED at' '$T/wait1.stdout' && grep -q 'has finished with exit status 0' '$T/wait1.stdout' && [ \"\$(cat $T/wait1.rc)\" = 0 ]" "$(cat "$T/wait1.stdout" 2>/dev/null)"
unpaused() { python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("pause") is None else 1)' "$(ls "$STORE"/agents/*--"$1".json)"; }
sub "H3.4 the registry records the resume and no hold is left" "[ -z \"\$(ls $HOLD_STATE/held 2>/dev/null)\" ] && unpaused zach-opus-hold1" \
    "held: $(ls "$HOLD_STATE/held" 2>&1 | tr '\n' ' ')"

echo "=== H4 a stop never leaves held work suspended ==="
agent_call "$AID" "toolu_work2" "python3 $T/worker.py $T/w2 $((ROUNDS * 50))" w2
wait_file "$T/w2.progress"; W2="$(cat "$T/w2.pid")"; OURS+=("$W2")
send "zach-opus-hold1" "$PAUSE_TEXT" "$T/pause2.out"
sub "H4.1 held" "is_stopped $W2"
RICHOS_SESSION_ID="$CUR_SID" "$ENGINE/mega-lander/workspaces.sh" stop zach-opus-hold1 --why "no longer wanted" >"$T/stop.out" 2>&1
sub "H4.2 the stop continued it (so a termination is delivered, never pending on a frozen process)" "! is_stopped $W2 && grep -q 'RELEASE zach-opus-hold1' '$T/stop.out'" "$(cat "$T/stop.out")"
kill -9 "$W2" 2>/dev/null

echo "=== H5 a session end never leaves held work suspended ==="
AID2="aholdtwotwotwotwo"
register_agent "zach-opus-hold2" "$AID2"
agent_call "$AID2" "toolu_work3" "python3 $T/worker.py $T/w3 $((ROUNDS * 50))" w3
wait_file "$T/w3.progress"; W3="$(cat "$T/w3.pid")"; OURS+=("$W3")
send "zach-opus-hold2" "$PAUSE_TEXT" "$T/pause3.out"
sub "H5.1 held" "is_stopped $W3" "$(cat "$T/pause3.out")"
payload SessionEnd "{\"session_id\":\"$CUR_SID\",\"cwd\":\"$ENT\",\"reason\":\"other\"}" | lifecycle >/dev/null 2>>"$T/hooks.err"
sub "H5.2 the session end continued it" "! is_stopped $W3"
kill -9 "$W3" 2>/dev/null

echo "=== H6 Sage's catch 3: a land's in-flight notice never thaws a generated pause; only the generated RESUME does ==="
start_session "sess-hold-2222"
python3 "$ENGINE/mega-lander/workspaces.py" --entity "$ENT" --session "$CUR_SID" integration --repo "$ENT" --branch main \
    --why "the pause-hold suite's body of work" >/dev/null 2>>"$T/hooks.err"
AID3="aholdthreethreeth"
register_agent "zach-opus-hold3" "$AID3"
agent_call "$AID3" "toolu_work6" "python3 $T/worker.py $T/w6 $ROUNDS" w6
wait_file "$T/w6.progress"; W6="$(cat "$T/w6.pid")"; OURS+=("$W6")
send "zach-opus-hold3" "$PAUSE_TEXT" "$T/pause6.out"
sub "H6.1 held by the generated pause" "is_stopped $W6" "$(cat "$T/pause6.out")"
NOTICE="main moved to 0123456789abcdef0123456789abcdef01234567
impact: none
ack: scripts/inflight-ack.sh --sha 0123456789abcdef0123456789abcdef01234567 --impact none"
send "zach-opus-hold3" "$NOTICE" "$T/notice6.out"
send "zach-opus-hold3" "RESUME: continue." "$T/wake6.out"
sub "H6.2 after an in-flight notice and a handwritten wake it still waits: frozen, paused, held" \
    "is_stopped $W6 && ! unpaused zach-opus-hold3 && [ -n \"\$(ls $HOLD_STATE/held 2>/dev/null)\" ]" "$(cat "$T/notice6.out")"
sub "H6.3 the lead is told the message did not resume it, and how to" \
    "grep -q 'is WAITING under the generated pause' '$T/notice6.out' && grep -q 'pause_protocol.py --resume --to zach-opus-hold3' '$T/notice6.out'" \
    "$(cat "$T/notice6.out")"
send "zach-opus-hold3" "$RESUME_TEXT" "$T/resume6.out"
wait_file "$T/w6" 1200     # its call returned the WAIT at the pause; the frozen worker writes this when it ends
sub "H6.4 the generated RESUME continues it; it finishes with the correct result" \
    "unpaused zach-opus-hold3 && [ \"\$(cat $T/w6 2>/dev/null)\" = '$EXPECTED' ]" "$(cat "$T/resume6.out")"

echo "=== H7 Sage's catch 1: a TaskStop releases the hold by the id it names, whatever the registry holds ==="
agent_call "$AID3" "toolu_work7" "python3 $T/worker.py $T/w7 $((ROUNDS * 50))" w7
wait_file "$T/w7.progress"; W7="$(cat "$T/w7.pid")"; OURS+=("$W7")
send "zach-opus-hold3" "$PAUSE_TEXT" "$T/pause7.out"
sub "H7.1 held" "is_stopped $W7" "$(cat "$T/pause7.out")"
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","session_id":sys.argv[1],"tool_name":"TaskStop","cwd":sys.argv[3],"tool_input":{"task_id":sys.argv[2]},"tool_response":{"task_id":sys.argv[2],"success":True}}))' "$CUR_SID" "$AID3" "$ENT" \
    | lifecycle >"$T/taskstop7.out" 2>>"$T/hooks.err"
sub "H7.2 the TaskStop's hook continued it, so the stop's signal is delivered" "! is_stopped $W7" "$(cat "$T/taskstop7.out")"
kill -9 "$W7" 2>/dev/null
# An id the registry never registered, held directly (as a hold outliving its record would be).
GHOST="aghostghostghosts"
agent_call "$GHOST" "toolu_ghost" "python3 $T/worker.py $T/wg $((ROUNDS * 50))" wg
wait_file "$T/wg.progress"; WG="$(cat "$T/wg.pid")"; OURS+=("$WG")
RICHOS_AGENT_HOLD_DIR="$HOLD_STATE" python3 "$LIB/agent_hold.py" hold --session "$CUR_SID" --agent "$GHOST" >/dev/null
sub "H7.3 held without any registry record" "is_stopped $WG"
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","session_id":sys.argv[1],"tool_name":"TaskStop","cwd":sys.argv[3],"tool_input":{"task_id":sys.argv[2]},"tool_response":{"task_id":sys.argv[2],"success":True}}))' "$CUR_SID" "$GHOST" "$ENT" \
    | lifecycle >/dev/null 2>>"$T/hooks.err"
sub "H7.4 a TaskStop naming it still continues it" "! is_stopped $WG"
kill -9 "$WG" 2>/dev/null

echo "=== H8 the agent WAITS inside its run: its wait command returns RESUMED only after the generated RESUME ==="
AID4="aholdfourfourfour"
register_agent "zach-opus-hold4" "$AID4"
# A background call this time: frozen whole, so the wait returns at RESUME without collecting it.
agent_call "$AID4" "toolu_work8" "python3 $T/worker.py $T/w8 $((ROUNDS * 50))" w8 bg
wait_file "$T/w8.progress"; W8="$(cat "$T/w8.pid")"; OURS+=("$W8")
send "zach-opus-hold4" "$PAUSE_TEXT" "$T/pause8.out"
WAITCMD="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pause_protocol as p; print(p.WAIT_COMMAND.replace("~/.claude/richos-engine", sys.argv[2]))' "$LIB" "$ENGINE")"
agent_call "$AID4" "toolu_wait8" "$WAITCMD" wait8
SHW="$(cat "$T/wait8.shell")"
sleep 1
sub "H8.1 the wait the message names runs (never refused, never frozen: Sage's catch A) and has not returned" \
    "! is_stopped $SHW && [ ! -e '$T/wait8.rc' ]" "$(pstate "$SHW") $(cat "$T/wait8.stdout" 2>/dev/null)"
send "zach-opus-hold4" "$RESUME_TEXT" "$T/resume8.out"
wait_file "$T/wait8.rc" 200
sub "H8.2 after the generated RESUME it prints RESUMED and exits 0; the worker runs again" \
    "grep -q '^RESUMED at' '$T/wait8.stdout' && [ \"\$(cat $T/wait8.rc)\" = 0 ] && ! is_stopped $W8" "$(cat "$T/wait8.stdout" "$T/resume8.out")"
kill -9 "$W8" 2>/dev/null

echo "=== H9 Sage's catch 6: a lead that dies without SessionEnd never leaves work frozen ==="
start_session "sess-hold-3333"
python3 "$ENGINE/mega-lander/workspaces.py" --entity "$ENT" --session "$CUR_SID" integration --repo "$ENT" --branch main \
    --why "the pause-hold suite's body of work" >/dev/null 2>>"$T/hooks.err"
LEADPID="$RICHOS_SESSION_PID"
AID5="aholdfivefivefive"
register_agent "zach-opus-hold5" "$AID5"
# A real agent's shells are children of the lead's `claude`; here they are children of
# launch.py, so after the pause the hold record keeps only the lead's session process.
agent_call "$AID5" "toolu_work9" "python3 $T/worker.py $T/w9 $((ROUNDS * 50))" w9
wait_file "$T/w9.progress"; W9="$(cat "$T/w9.pid")"; OURS+=("$W9")
send "zach-opus-hold5" "$PAUSE_TEXT" "$T/pause9.out"
python3 - "$HOLD_STATE" "$CUR_SID" "$AID5" "$LEADPID" <<'PY'
import json, os, sys
d, sid, aid, lead = sys.argv[1:5]
p = os.path.join(d, "held", "%s__%s.json" % (sid, aid))
r = json.load(open(p))
r["parents"] = {lead: r["parents"][lead]}      # only the lead's session process, as for a real agent
json.dump(r, open(p, "w"))
PY
sub "H9.1 held while its lead lives" "is_stopped $W9" "$(cat "$T/pause9.out")"
T9="$(python3 -c 'import time; print(time.time())')"
kill -9 "$LEADPID"
i=0; while is_stopped "$W9" && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
sub "H9.2 with no hook at all, the watchdog continued it after the lead died ($(python3 -c "import time; print('%.1f s' % (time.time() - $T9))"))" \
    "! is_stopped $W9 && [ -z \"\$(ls $HOLD_STATE/held 2>/dev/null)\" ]"
kill -9 "$W9" 2>/dev/null

echo ""
echo "CHECKS: $RUN  RED: $RED"
[ "$RED" -eq 0 ]
