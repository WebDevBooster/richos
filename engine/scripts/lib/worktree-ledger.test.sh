#!/usr/bin/env bash
#
# worktree-ledger.test.sh — behavioral tests for scripts/lib/worktree-ledger.py,
# the durable ownership record that lets a worktree's owner be judged AFTER the
# harness's lock is gone.
#
# Every verdict-shaped case is TWO-SIDED: the case that must be refused and the
# case that must pass sit next to each other, because a resolver that says
# INDETERMINATE for everything satisfies every safety assertion and reaps
# nothing — the exact shape of the defect this file exists to close.
#
# Run directly: scripts/lib/worktree-ledger.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_PY="$SCRIPT_DIR/worktree-ledger.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t worktree-ledger-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$LEDGER_PY" ] || { echo "FATAL: missing $LEDGER_PY" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

LEDGER="$SANDBOX/ledger.jsonl"
L() { python3 "$LEDGER_PY" --ledger "$LEDGER" "$@"; }

# NO local git identity override: fixtures inherit the operator's real global
# identity, which a machine-wide pre-commit identity guard requires.
seed_repo() { # <path>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    printf 'seed\n' >"$1/seed.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m seed
}
add_native() { # <entity> <agent-id> [lock-pid]
    mkdir -p "$1/.claude/worktrees"
    git -C "$1" worktree add -q -b "worktree-agent-$2" "$1/.claude/worktrees/agent-$2"
    if [ -n "${3:-}" ]; then
        git -C "$1" worktree lock --reason "claude agent agent-$2 (pid $3 start test)" \
            "$1/.claude/worktrees/agent-$2"
    fi
}

ENTITY="$SANDBOX/entity"
seed_repo "$ENTITY"
MY_START="$(python3 "$LEDGER_PY" pid-start "$$")"

echo "=== worktree-ledger tests ==="

# 1. record appends one JSON line carrying ts + the fields given.
L record registered --teammate zach-opus-t1 --agent-id aaa111 --session-id sess-1 \
    --session-pid "$$" --pid-start-of-session --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-t1" --branch zach-opus-t1 --class hand-rolled \
    --source test >/dev/null
if [ "$(grep -c . "$LEDGER")" -eq 1 ] && python3 - "$LEDGER" "$MY_START" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip())
assert d["event"] == "registered" and d["teammate"] == "zach-opus-t1"
assert isinstance(d["session_pid"], int)
assert d["pid_start"] == sys.argv[2], (d["pid_start"], sys.argv[2])
assert "ts" in d and d["class"] == "hand-rolled"
PY
then ok "record appends one line with ts, fields, and pid_start read from ps"
else bad "record shape: $(cat "$LEDGER")"; fi

# 2. UNRESOLVED: nothing on record for a name and no transcript -> UNRESOLVED,
#    never NOT-ALIVE. (Absence is not death.)
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/nobody" --name nobody-owns-this --format triple --no-write)"
case "$V" in
UNRESOLVED*) ok "no record + no transcript -> UNRESOLVED" ;;
*) bad "unresolved owner got: $V" ;;
esac

# 3. SESSION PROVABLY GONE -> NOT-ALIVE. A registration whose session pid was a
#    process that has since exited. This is the prior-session case: the native
#    worktree never existed in this entity, and the tree is decidable anyway.
sleep 5 &
DEAD_PID=$!
DEAD_START="$(python3 "$LEDGER_PY" pid-start "$DEAD_PID")"
kill "$DEAD_PID" 2>/dev/null; wait "$DEAD_PID" 2>/dev/null || true
L record registered --teammate zach-opus-gone --agent-id gone001 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$ENTITY" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-gone" --name zach-opus-gone --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*host session pid .* is gone'; then
    ok "registration whose session pid is GONE -> NOT-ALIVE (prior-session owner is decidable)"
else
    bad "dead session pid: $V"
fi

# 4. SESSION STILL RUNNING, native absent -> INDETERMINATE, naming the pid.
#    The negative control for case 3: same shape, live process.
L record registered --teammate zach-opus-live --agent-id live001 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
if printf '%s' "$V" | grep -q "^INDETERMINATE.*session pid $$ is still running"; then
    ok "registration whose session pid is RUNNING and native worktree absent -> INDETERMINATE"
else
    bad "live session pid: $V"
fi

# 5. PID REUSED -> NOT-ALIVE. Same pid as case 4, but the recorded start time is
#    not this process's start time: that process is gone and its number was
#    handed to someone else. A bare kill -0 would call this ALIVE.
L record registered --teammate zach-opus-reused --agent-id reuse01 --session-id sess-x \
    --session-pid "$$" --pid-start "Mon 1 Jan 00:00:00 1990" --repo "$ENTITY" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-reused" --name zach-opus-reused --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*is reused'; then
    ok "running pid with a DIFFERENT start time -> NOT-ALIVE (pid reuse is not liveness)"
else
    bad "pid reuse: $V"
fi

# 6. ALIVE WINS. Two registrations for one name: one dead session, one whose
#    native isolation worktree is LOCKED by a running pid. The tree's owner is
#    ALIVE — one live registration outranks any number of dead ones.
add_native "$ENTITY" "twin01" "$$"
L record registered --teammate zach-opus-twin --agent-id twin00 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$ENTITY" --class native >/dev/null
L record registered --teammate zach-opus-twin --agent-id twin01 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$ENTITY/.claude/worktrees/agent-twin01" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-twin" --name zach-opus-twin --format triple --no-write)"
if printf '%s' "$V" | grep -q '^ALIVE.*LOCKED by running pid'; then
    ok "two registrations, one LOCKED by a running pid -> ALIVE (a live owner outranks a dead twin)"
else
    bad "alive wins: $V"
fi

# 7. THE ACCEPTANCE PROPERTY. Native worktree registered + unlocked -> NOT-ALIVE
#    OBSERVED, and the observation is WRITTEN. Then the native worktree is
#    removed (what a land does) and the same tree is STILL decidable from the
#    record. This is the case every prior fix failed.
add_native "$ENTITY" "done01"
L record registered --teammate zach-opus-done --agent-id done01 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$ENTITY/.claude/worktrees/agent-done01" --class native >/dev/null
BEFORE="$(grep -c '"event": "terminated"' "$LEDGER" || true)"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-done" --name zach-opus-done --format triple)"
AFTER="$(grep -c '"event": "terminated"' "$LEDGER" || true)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*OBSERVED now' && [ "$AFTER" -eq $((BEFORE + 1)) ]; then
    ok "native registered+unlocked -> NOT-ALIVE observed, and a 'terminated' record is written"
else
    bad "observed termination (before=$BEFORE after=$AFTER): $V"
fi
git -C "$ENTITY" worktree remove "$ENTITY/.claude/worktrees/agent-done01" >/dev/null 2>&1
git -C "$ENTITY" branch -d worktree-agent-done01 >/dev/null 2>&1
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-done" --name zach-opus-done --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*witnessed termination on record'; then
    ok "AFTER the native worktree is gone, the owner is STILL NOT-ALIVE from the witnessed record"
else
    bad "post-removal decidability: $V"
fi

# 7b. NEGATIVE CONTROL for 7: the same shape WITHOUT the witnessed record and
#     with a running session is INDETERMINATE — the record is what decides it,
#     not the removal.
add_native "$ENTITY" "quiet01"
L record registered --teammate zach-opus-quiet --agent-id quiet01 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$ENTITY/.claude/worktrees/agent-quiet01" --class native >/dev/null
git -C "$ENTITY" worktree remove "$ENTITY/.claude/worktrees/agent-quiet01" >/dev/null 2>&1
git -C "$ENTITY" branch -d worktree-agent-quiet01 >/dev/null 2>&1
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-quiet" --name zach-opus-quiet --format triple --no-write)"
case "$V" in
INDETERMINATE*) ok "native removed with NO witnessed record and a live session -> INDETERMINATE (never guessed)" ;;
*) bad "unwitnessed removal: $V" ;;
esac

# 8. --no-write writes nothing, even on an observation.
add_native "$ENTITY" "nowrite1"
L record registered --teammate zach-opus-nw --agent-id nowrite1 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" --class native >/dev/null
BEFORE="$(grep -c . "$LEDGER")"
L judge --entity "$ENTITY" --name zach-opus-nw --format triple --no-write >/dev/null
AFTER="$(grep -c . "$LEDGER")"
[ "$AFTER" -eq "$BEFORE" ] && ok "--no-write appends nothing" || bad "--no-write appended $((AFTER - BEFORE)) line(s)"

# 9. ADVISORY SIGNALS NEVER DECIDE. Three 'finished' records for a live-session
#    agent leave it INDETERMINATE, and the reason says they are advisory.
for sig in TeammateIdle TaskCompleted SubagentStop; do
    L record finished --signal "$sig" --agent-id live001 --teammate zach-opus-live --session-id sess-now >/dev/null
done
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
if printf '%s' "$V" | grep -q '^INDETERMINATE' && printf '%s' "$V" | grep -q 'advisory, never decisive: live001: 3 advisory finish signal'; then
    ok "TeammateIdle/TaskCompleted/SubagentStop are reported as advisory and never decide"
else
    bad "advisory signals: $V"
fi

# 10. TRANSCRIPT FALLBACK. No ledger row for the name; a transcript joins it to
#     an agent whose native worktree is LOCKED -> ALIVE; unlocked -> NOT-ALIVE.
T="$SANDBOX/transcript.jsonl"
python3 - "$T" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i, (name, aid) in enumerate([("echo-opus-tr1", "tr1"), ("echo-opus-tr2", "tr2")]):
        tu = "tu%d" % i
        f.write(json.dumps({"message": {"content": [{"type": "tool_use", "name": "Agent", "id": tu, "input": {"name": name}}]}}) + "\n")
        f.write(json.dumps({"message": {"content": [{"type": "tool_result", "tool_use_id": tu}]}, "toolUseResult": {"agentId": aid}}) + "\n")
PY
add_native "$ENTITY" "tr1" "$$"
add_native "$ENTITY" "tr2"
V1="$(L judge --entity "$ENTITY" --name echo-opus-tr1 --transcript "$T" --format triple --no-write)"
V2="$(L judge --entity "$ENTITY" --name echo-opus-tr2 --transcript "$T" --format triple --no-write)"
if printf '%s' "$V1" | grep -q '^ALIVE' && printf '%s' "$V2" | grep -q '^NOT-ALIVE.*OBSERVED now'; then
    ok "transcript fallback: locked -> ALIVE, registered+unlocked -> NOT-ALIVE observed"
else
    bad "transcript fallback: [$V1] [$V2]"
fi

# 11. judge-batch: one line per input path, same verdicts.
OUT="$(printf '%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s\n' \
        "$ENTITY" "$SANDBOX/wt/zach-opus-gone" zach-opus-gone zach-opus-gone \
        "$ENTITY" "$SANDBOX/wt/nobody" nobody nobody \
      | L judge-batch --entity "$ENTITY" --no-write)"
if printf '%s\n' "$OUT" | grep -q "^$SANDBOX/wt/zach-opus-gone	NOT-ALIVE	gone001	" \
   && printf '%s\n' "$OUT" | grep -q "^$SANDBOX/wt/nobody	UNRESOLVED		"; then
    ok "judge-batch emits path<TAB>verdict<TAB>agent-ids<TAB>reason per input line"
else
    bad "judge-batch: $OUT"
fi

# 12. branches --repo lists the registered branch names for that repository.
if [ "$(L branches --repo "$ENTITY" | tr '\n' ' ')" = "zach-opus-t1 " ]; then
    ok "branches --repo lists ledger-registered branches"
else
    bad "branches: $(L branches --repo "$ENTITY" | tr '\n' ' ')"
fi

# 13. A malformed line never poisons the record.
printf 'this is not json\n' >>"$LEDGER"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-gone" --name zach-opus-gone --format triple --no-write)"
printf '%s' "$V" | grep -q '^NOT-ALIVE' && ok "a malformed ledger line is skipped, not fatal" || bad "malformed line: $V"

# 14. Exact-path registration wins without any name match: a hand-rolled tree
#     registered by path, whose directory is named nothing like its owner.
L record registered --teammate mark-opus-p1 --agent-id gone002 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$SANDBOX/other" \
    --worktree "$SANDBOX/other-wt/feature-x" --branch feature-x --class hand-rolled >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/other-wt/feature-x" --name feature-x --format triple --no-write)"
printf '%s' "$V" | grep -q '^NOT-ALIVE.*host session pid' && ok "a path-registered tree is judged by its registration, not its name" || bad "path registration: $V"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== worktree-ledger tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== worktree-ledger tests: all $PASS passed ==="
    exit 0
fi
