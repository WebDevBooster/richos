#!/usr/bin/env bash
#
# record-subagent-start.test.sh — behavioral tests for
# scripts/hooks/record-subagent-start.sh, the SubagentStart fact writer.
#
# What is proven: the hook writes the start fact (agent id, exact cwd, type)
# durably; it seals the manifest when the parent's binding is already on disk
# and leaves it unsealed (with the fact recorded) when it is not; it NEVER
# exits nonzero — SubagentStart cannot block, and this hook never pretends it
# can; an unattributable start (no agent id) records nothing; a missing
# library is announced, not swallowed silently.
#
# The mutation harness proving each assertion load-bearing is
# scripts/hooks/record-subagent-start.mutation.sh, run at the end.
#
# Run directly: scripts/hooks/record-subagent-start.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/record-subagent-start.sh"
TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t record-start-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing/non-executable" >&2; exit 1; }
[ -f "$TX_PY" ] || { echo "FATAL: $TX_PY missing" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
SID="deadbeef-0000-4000-8000-000000000000"
AID="a1b2c3d4e5f60001"
T() { python3 "$TX_PY" "$@"; }

ENTITY="$SANDBOX/entity"
mkdir -p "$ENTITY/.claude/worktrees"
git -C "$ENTITY" init -q -b main
printf 'seed\n' >"$ENTITY/seed.txt"; git -C "$ENTITY" add -A; git -C "$ENTITY" commit -q -m seed
git -C "$ENTITY" worktree add -q -b "worktree-agent-$AID" "$ENTITY/.claude/worktrees/agent-$AID"
NATIVE="$ENTITY/.claude/worktrees/agent-$AID"

payload() { # <agent_id> <cwd> [agent_type] [event]
    python3 -c '
import json, sys
aid, cwd, at, ev = sys.argv[1:5]
d = {"session_id": "deadbeef-0000-4000-8000-000000000000", "hook_event_name": ev or "SubagentStart", "cwd": cwd,
     "agent_type": at, "agent_transcript_path": "/tmp/x.jsonl"}
if aid: d["agent_id"] = aid
print(json.dumps(d))' "$1" "$2" "${3:-dev}" "${4:-SubagentStart}"
}
run() { # <payload> -> stdout+stderr captured in OUT, rc in RC
    OUT="$(printf '%s' "$1" | "$HOOK" 2>&1)"; RC=$?
}

echo "=== record-subagent-start tests ==="

# S01. the start fact is written, exactly
run "$(payload "$AID" "$NATIVE" dev)"
if [ "$RC" -eq 0 ] && python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["record"] == "start" and d["agent_id"] == sys.argv[2] and d["agent_type"] == "dev"
assert d["cwd_real"] == os.path.realpath(sys.argv[3]) and d["session_id"] == sys.argv[4]
' "$SANDBOX/tx/$SID/starts/$AID.json" "$AID" "$NATIVE" "$SID" 2>/dev/null; then
    ok "S01  the start fact is written with agent id, exact cwd, type and session"
else
    bad "S01  start fact (rc=$RC): $(cat "$SANDBOX/tx/$SID/starts/$AID.json" 2>/dev/null | tr '\n' ' ') $OUT"
fi
[ -z "$OUT" ] && ok "S02  a recorded start is silent" || bad "S02  output on a clean start: $OUT"

# S03. with no bound record the manifest stays UNSEALED (and that is not an error)
T sealed --session-id "$SID" --agent-id "$AID" 2>/dev/null && bad "S03  sealed without a bound record" || ok "S03  no bound record yet -> the manifest stays unsealed"

# S04. once the parent's binding exists, the start hook seals (order: bind, then start)
printf '{"kind":"native","teammate":"dev-opus-s1","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-s1 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-s1 --agent-id "$AID" >/dev/null
run "$(payload "$AID" "$NATIVE" dev)"
if [ "$RC" -eq 0 ] && T sealed --session-id "$SID" --agent-id "$AID"; then
    ok "S04  bound record on disk + start fact -> the start hook SEALS the manifest"
else
    bad "S04  seal after bind (rc=$RC): $OUT"
fi
M="$(T members --session-id "$SID" --agent-id "$AID")"
printf '%s' "$M" | grep -q "^native	$ENTITY	$NATIVE	worktree-agent-$AID	bound$" \
    && ok "S05  the sealed native member is the event cwd, verified against git" || bad "S05  members: $M"

# S06. the reverse order: start first (unsealed), bind later, start again -> sealed
AID2="a1b2c3d4e5f60002"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$AID2" "$ENTITY/.claude/worktrees/agent-$AID2"
run "$(payload "$AID2" "$ENTITY/.claude/worktrees/agent-$AID2" dev)"
T sealed --session-id "$SID" --agent-id "$AID2" 2>/dev/null && bad "S06  sealed before any binding" || ok "S06  start before bind -> recorded, unsealed"
printf '{"kind":"native","teammate":"dev-opus-s2","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-s2 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-s2 --agent-id "$AID2" >/dev/null
T seal --session-id "$SID" --agent-id "$AID2" >/dev/null \
    && ok "S07  ...and the binder's own try_seal seals it from the recorded start (either order works)" \
    || bad "S07  seal from the binder side failed"

# S08. a start whose cwd is NOT the native worktree records the fact and does not seal
AID3="a1b2c3d4e5f60003"
printf '{"kind":"native","teammate":"dev-opus-s3","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-s3 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-s3 --agent-id "$AID3" >/dev/null
run "$(payload "$AID3" "$ENTITY" dev)"
if [ "$RC" -eq 0 ] && [ -f "$SANDBOX/tx/$SID/starts/$AID3.json" ] && ! T sealed --session-id "$SID" --agent-id "$AID3" 2>/dev/null; then
    ok "S08  a start in the MAIN checkout is recorded and NOT sealed (the barrier will refuse its writes)"
else
    bad "S08  wrong-cwd start (rc=$RC sealed=$(T sealed --session-id "$SID" --agent-id "$AID3" && echo yes || echo no))"
fi

# S09. no agent id -> nothing recorded, exit 0
run "$(payload "" "$NATIVE" dev)"
[ "$RC" -eq 0 ] && [ ! -d "$SANDBOX/tx/$SID/starts" ] || [ -z "$(ls "$SANDBOX/tx/$SID/starts" 2>/dev/null | grep -v "$AID\|$AID2\|$AID3")" ] \
    && ok "S09  an unattributable start (no agent id) records nothing and exits 0" || bad "S09  rc=$RC"

# S10. a different event name is ignored
run "$(payload "a1b2c3d4e5f60009" "$NATIVE" dev SubagentStop)"
[ "$RC" -eq 0 ] && [ ! -f "$SANDBOX/tx/$SID/starts/a1b2c3d4e5f60009.json" ] \
    && ok "S10  a payload for another event is ignored" || bad "S10  wrong event handled (rc=$RC)"

# S11. NEVER BLOCKS: garbage stdin -> exit 0
OUT="$(printf 'not json' | "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "S11  unparseable payload -> exit 0 (SubagentStart cannot block, and this hook never pretends to)" || bad "S11  rc=$RC"

# S12. the library missing -> exit 0 with a NOTICE naming it (announced, not swallowed)
NOLIB="$(mktemp -d -t record-start-nolib.XXXXXX)"
mkdir -p "$NOLIB/scripts/hooks" "$NOLIB/scripts/lib"
cp "$HOOK" "$NOLIB/scripts/hooks/"
OUT="$(printf '%s' "$(payload "$AID" "$NATIVE" dev)" | "$NOLIB/scripts/hooks/record-subagent-start.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'worktree-transactions.py is missing'; then
    ok "S12  library missing -> exit 0 and a NOTICE naming the missing file"
else
    bad "S12  nolib (rc=$RC): $OUT"
fi
rm -rf "$NOLIB"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== record-subagent-start tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== record-subagent-start tests: all $PASS passed ==="

if [ -f "$SCRIPT_DIR/record-subagent-start.mutation.sh" ]; then
    bash "$SCRIPT_DIR/record-subagent-start.mutation.sh" || exit 1
fi
exit 0
