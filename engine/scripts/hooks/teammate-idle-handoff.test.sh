#!/usr/bin/env bash
#
# teammate-idle-handoff.test.sh — regression tests for the log-only
# teammate-idle-handoff.sh.
#
# Run directly: scripts/hooks/teammate-idle-handoff.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/teammate-idle-handoff.sh"

PASS=0
FAIL=0
SANDBOX="$(mktemp -d -t teammate-idle-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

TEAMS="$SANDBOX/teams"
SESSION_DIR="$TEAMS/session-cafebabe"
mkdir -p "$SESSION_DIR"
LOG="$SESSION_DIR/idle-events.jsonl"

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

run_hook() { # <json> ; returns hook exit code
    printf '%s' "$1" | TEAMMATE_IDLE_TEAMS_DIR="$TEAMS" HOME="$SANDBOX/home" "$HOOK" >/dev/null 2>&1
}

line_count() { [ -f "$LOG" ] && grep -c . "$LOG" || echo 0; }

echo "=== teammate-idle-handoff (log-only) tests ==="

# 1. Valid idle event -> exit 0 + one record appended
BEFORE="$(line_count)"
run_hook '{"hook_event_name":"TeammateIdle","session_id":"cafebabe-1111-4222-8333-444455556666","transcript_path":"/tmp/t.jsonl","cwd":"/tmp"}'
RC=$?
AFTER="$(line_count)"
if [ "$RC" -eq 0 ] && [ "$AFTER" -eq $((BEFORE + 1)) ]; then ok "valid event logs one record, exit 0"; else bad "valid event (rc=$RC before=$BEFORE after=$AFTER)"; fi

# 2. Record fields sane
LAST="$(tail -1 "$LOG")"
if printf '%s' "$LAST" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["event"]=="TeammateIdle"; assert d["decision"]=="logged"; assert d["session_id"].startswith("cafebabe")' 2>/dev/null; then
    ok "record carries event/decision/session_id"
else
    bad "record fields ($LAST)"
fi

# 3. Malformed JSON -> exit 0, nothing appended
BEFORE="$(line_count)"
run_hook 'this is not json'
RC=$?
AFTER="$(line_count)"
if [ "$RC" -eq 0 ] && [ "$AFTER" -eq "$BEFORE" ]; then ok "malformed JSON is a silent no-op"; else bad "malformed JSON (rc=$RC)"; fi

# 4. Wrong event name -> exit 0, nothing appended
BEFORE="$(line_count)"
run_hook '{"hook_event_name":"SomethingElse","session_id":"cafebabe-1111-4222-8333-444455556666"}'
RC=$?
AFTER="$(line_count)"
if [ "$RC" -eq 0 ] && [ "$AFTER" -eq "$BEFORE" ]; then ok "non-TeammateIdle event ignored"; else bad "wrong event name (rc=$RC)"; fi

# 5. Dirty git cwd -> uncommitted_changes annotation
GITDIR="$SANDBOX/repo"
mkdir -p "$GITDIR"
git -C "$GITDIR" init -q
printf 'one\n' > "$GITDIR/a.txt"
printf 'two\n' > "$GITDIR/b.txt"
run_hook "{\"hook_event_name\":\"TeammateIdle\",\"session_id\":\"cafebabe-1111-4222-8333-444455556666\",\"cwd\":\"$GITDIR\"}"
LAST="$(tail -1 "$LOG")"
if printf '%s' "$LAST" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d.get("uncommitted_changes")==2' 2>/dev/null; then
    ok "dirty cwd annotated with uncommitted_changes=2"
else
    bad "uncommitted annotation ($LAST)"
fi

# 6. Unknown session -> falls back to HOME log, still exit 0
mkdir -p "$SANDBOX/home/.claude"
run_hook '{"hook_event_name":"TeammateIdle","session_id":"00000000-9999-4999-8999-999999999999"}'
RC=$?
if [ "$RC" -eq 0 ]; then ok "unknown session still exits 0 (fallback log)"; else bad "unknown session (rc=$RC)"; fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== teammate-idle-handoff tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== teammate-idle-handoff tests: all $PASS passed ==="
    exit 0
fi
