#!/usr/bin/env bash
#
# task-completed-handoff.test.sh — unit tests for task-completed-handoff.sh.
#
# Runs the hook against a sandbox TASK_COMPLETED_TEAMS_DIR with synthetic
# payloads and asserts: (a) it always exits 0, (b) it writes one
# well-formed JSON line per TaskCompleted event into task-events.jsonl,
# (c) it parses the task identity fields, (d) it ignores non-TaskCompleted
# events, (e) it never crashes on garbage input.
#
#   scripts/hooks/task-completed-handoff.test.sh
#
# Exit 0 = all pass, 1 = a failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/task-completed-handoff.sh"

SANDBOX="$(mktemp -d -t task-completed-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

TEAMS_DIR="$SANDBOX/teams"
SESSION_DIR="$TEAMS_DIR/session-abcd1234"
mkdir -p "$SESSION_DIR"

FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

WL="$SANDBOX/wt-ledger.jsonl"
export RICHOS_WORKTREE_LEDGER="$WL"
run_hook() {
    # $1 = payload JSON. Echoes exit code on stdout.
    printf '%s' "$1" | TASK_COMPLETED_TEAMS_DIR="$TEAMS_DIR" RICHOS_WORKTREE_LEDGER="$WL" "$HOOK" >/dev/null 2>&1
    echo $?
}

LOG="$SESSION_DIR/task-events.jsonl"

# --- Test 1: valid TaskCompleted writes one line, exit 0 ---
# Real payload field names captured empirically: task_subject, teammate_name,
# team_name (NOT task_title / agent_type).
rc="$(run_hook '{"hook_event_name":"TaskCompleted","session_id":"abcd1234-deadbeef","team_name":"session-abcd1234","task_id":"7","task_subject":"Wire TaskCompleted hook","teammate_name":"infra-coord"}')"
if [ "$rc" = "0" ]; then pass "valid payload exits 0"; else fail "valid payload exit ($rc != 0)"; fi
if [ -f "$LOG" ]; then pass "log file created"; else fail "log file missing"; fi
lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
if [ "$lines" = "1" ]; then pass "exactly one log line"; else fail "line count ($lines != 1)"; fi

# Validate JSON shape + fields of the single line.
python3 - "$LOG" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    rows = [json.loads(l) for l in f if l.strip()]
r = rows[-1]
assert r["event"] == "TaskCompleted", r
assert r["task_id"] == "7", r
assert r["task_subject"] == "Wire TaskCompleted hook", r
assert r["teammate"] == "infra-coord", r
assert r["decision"] == "logged", r
assert r["session_id"] == "abcd1234-deadbeef", r
assert "timestamp" in r and r["timestamp"], r
print("FIELDS_OK")
PY
if [ "$?" = "0" ]; then pass "log line fields correct"; else fail "log line fields wrong"; fi

# --- Test 2: second completion appends (does not truncate) ---
run_hook '{"hook_event_name":"TaskCompleted","session_id":"abcd1234-deadbeef","team_name":"session-abcd1234","task_id":"8","task_subject":"Codify doctrine"}' >/dev/null
lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
if [ "$lines" = "2" ]; then pass "second completion appends"; else fail "append failed ($lines != 2)"; fi

# --- Test 3: non-TaskCompleted event is ignored (no new line) ---
run_hook '{"hook_event_name":"TaskCreated","session_id":"abcd1234-deadbeef","task_id":"9"}' >/dev/null
lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
if [ "$lines" = "2" ]; then pass "non-TaskCompleted ignored"; else fail "non-TaskCompleted wrote a line ($lines != 2)"; fi

# --- Test 4: garbage input never crashes (exit 0) ---
rc="$(run_hook 'this is not json at all }{')"
if [ "$rc" = "0" ]; then pass "garbage input exits 0"; else fail "garbage input exit ($rc != 0)"; fi

# --- Test 5: empty input exits 0 ---
rc="$(run_hook '')"
if [ "$rc" = "0" ]; then pass "empty input exits 0"; else fail "empty input exit ($rc != 0)"; fi

# --- Test 6: missing team dir falls back, still exit 0 ---
# HOME is overridden so the fallback write lands in the sandbox, not the
# operator's real ~/.claude/teammate-task-events.jsonl.
mkdir -p "$SANDBOX/home/.claude"
rc="$(printf '%s' '{"hook_event_name":"TaskCompleted","session_id":"zzzzzzzz-nodir","task_id":"1"}' | TASK_COMPLETED_TEAMS_DIR="$SANDBOX/does-not-exist" HOME="$SANDBOX/home" "$HOOK" >/dev/null 2>&1; echo $?)"
if [ "$rc" = "0" ]; then pass "missing team dir exits 0"; else fail "missing team dir exit ($rc != 0)"; fi

# --- Ownership ledger: an ADVISORY finish signal carrying task id + teammate ---
if grep -q '"signal": "TaskCompleted"' "$WL" 2>/dev/null && python3 - "$WL" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = next(r for r in rows if r.get("task_id") == "7")
assert r["event"] == "finished" and r["signal"] == "TaskCompleted" and r["teammate"] == "infra-coord", r
PY
then pass "ownership ledger: TaskCompleted retained as an advisory finish signal (task 7, infra-coord)"; else fail "ownership ledger: TaskCompleted finish signal missing or malformed"; fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "ALL TASK-COMPLETED HOOK TESTS PASSED"
    exit 0
else
    echo "$FAIL TASK-COMPLETED HOOK TEST(S) FAILED"
    exit 1
fi
