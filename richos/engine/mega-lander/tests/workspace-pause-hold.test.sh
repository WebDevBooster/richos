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
# own process group), and the lead's generated PAUSE and RESUME go through the
# PostToolUse[SendMessage] lifecycle hook. Asserted: the running work is suspended
# within seconds and uses no CPU while held; a new command of the held agent starts
# nothing until RESUME; after RESUME the same processes finish with the right
# result; a stop and a session end never leave work suspended. Only processes this
# test started are ever signaled.
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
p = subprocess.Popen([shell, "-c", cmd], process_group=0, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
open(pidfile, "w").write(str(p.pid))
open(rcfile, "w").write(str(p.wait()))
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
ROUNDS=600000
EXPECTED="$(python3 -c 'import hashlib,sys
h=b"richos"
for _ in range(int(sys.argv[1])): h=hashlib.sha256(h).digest()
print(h.hex())' "$ROUNDS")"

agent_call() { # <agent-id> <tool_use_id> <command> <tag>  -> starts it; shell pid in $T/<tag>.shell
    local rewritten
    rewritten="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":sys.argv[1],"agent_id":sys.argv[2],"tool_use_id":sys.argv[3],"tool_name":"Bash","cwd":sys.argv[5],"tool_input":{"command":sys.argv[4]}}))' "$CUR_SID" "$1" "$2" "$3" "$ENT" \
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
sub "H1.1 the worker and its shell are suspended when the pause hook returns ($(pstate "$W1"), $(pstate "$SH1"))" "is_stopped $W1 && is_stopped $SH1" "$(cat "$T/pause.out")"
sub "H1.2 it uses no CPU and makes no progress while held (cpu $C1 -> $C2, progress $P1 -> $P2)" "[ '$C1' = '$C2' ] && [ '$P1' = '$P2' ]"
sub "H1.3 the lead is told, measured, in its own context" \
    "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d[\"hookSpecificOutput\"][\"additionalContext\"]; sys.exit(0 if \"HOLD zach-opus-hold1:\" in c and \"suspended in\" in c else 1)' '$T/pause.out'" "$(cat "$T/pause.out")"
sub "H1.4 the registry records the pause" "grep -q '\"until\": \"the user' \"\$(ls $STORE/agents/*--zach-opus-hold1.json)\""
printf '  measured: pause hook returned %.2f s after the send began; %s\n' "$(python3 -c "print($T1 - $T0)")" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"])' "$T/pause.out" 2>/dev/null)"

echo "=== H2 a NEW command of the held agent starts nothing until RESUME, and is never refused ==="
agent_call "$AID" "toolu_late1" "python3 -c \"open('$T/late.ran','w').write('ran')\"" late
SHL="$(cat "$T/late.shell")"
i=0; while ! is_stopped "$SHL" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
sleep 1
sub "H2.1 the new call's shell suspended itself before its command ($(pstate "$SHL"))" "is_stopped $SHL"
sub "H2.2 it started no process and its command has not run" "[ -z \"\$(children_of $SHL)\" ] && [ ! -e '$T/late.ran' ] && [ ! -e '$T/late.rc' ]"

echo "=== H3 the generated RESUME continues the same work, which finishes correctly ==="
send "zach-opus-hold1" "$RESUME_TEXT" "$T/resume.out"
sub "H3.1 the lead is told what continued" "grep -q 'RELEASE zach-opus-hold1:' '$T/resume.out' && grep -q 'new command(s) that waited' '$T/resume.out'" "$(cat "$T/resume.out")"
wait_file "$T/w1.rc" 1200; wait_file "$T/late.rc" 200
sub "H3.2 the held worker finished with the correct result, exit 0" "[ \"\$(cat $T/w1 2>/dev/null)\" = '$EXPECTED' ] && [ \"\$(cat $T/w1.rc)\" = 0 ]" "rc=$(cat "$T/w1.rc" 2>/dev/null)"
sub "H3.3 the command that waited ran normally after RESUME, exit 0" "[ \"\$(cat $T/late.ran 2>/dev/null)\" = ran ] && [ \"\$(cat $T/late.rc)\" = 0 ]"
sub "H3.4 the registry records the resume and no hold is left" "[ -z \"\$(ls $HOLD_STATE/held 2>/dev/null)\" ] && ! grep -q '\"pause\": {' \"\$(ls $STORE/agents/*--zach-opus-hold1.json)\""

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

echo ""
echo "CHECKS: $RUN  RED: $RED"
[ "$RED" -eq 0 ]
