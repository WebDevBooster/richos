#!/usr/bin/env bash
#
# session-start-reap-worktrees.test.sh — behavioral tests for the SessionStart
# wrapper. SessionStart reads reconciler status and dry-run inventory only.
# Pending transactions, captures, working bytes and refs stay unchanged.
# Failures remain announced in one SessionStart JSON line and the hook exits 0.
# All transaction and ledger state is isolated in the fixture.
#
# The mutation harness proving each assertion load-bearing is
# scripts/hooks/session-start-reap-worktrees.mutation.sh, run at the end.
#
# Run directly: scripts/hooks/session-start-reap-worktrees.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/session-start-reap-worktrees.sh"
TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t session-start-reap.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing/non-executable" >&2; exit 1; }

unset CLAUDE_PROJECT_DIR
export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
export RICHOS_WORKTREE_CAPTURE_DIR="$SANDBOX/captures"
# THE OWNERSHIP LEDGER IS SANDBOXED FOR THE SAME REASON THE TRANSACTION STORE
# IS, and until 2026-09-06 it was not. That was a hermeticity gap this suite
# already had an opinion about — case W15 asserts that no transaction for the
# test session reaches the operator's real store — applied to one of the two
# stores. It became visible when the reconciler gained its adoption pass, which
# reads the ledger: with the transaction store redirected and the ledger left
# at its default, the pass refuses fail-closed (correctly, and loudly) and its
# refusal landed in the context line four cases assert against.
#
# The refusal was right and this is the fix it was asking for. Redirecting both
# is what "sandboxed" was always supposed to mean.
export RICHOS_WORKTREE_LEDGER="$SANDBOX/wt-ledger.jsonl"
export RICHOS_RECONCILE_SETTLE=0.2
SID="deadbeef-0000-4000-8000-000000000000"
T() { python3 "$TX_PY" "$@"; }

# Build the old sealed-record format explicitly for historical crash recovery.
# Current native records belong to Claude Code and must not be quarantined.
historical_seal() {
    T seal --session-id "$SID" --agent-id "$1" >/dev/null || return
    python3 - "$TX_PY" "$SID" "$1" <<'PYH'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tx", sys.argv[1])
tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
record = tx.load_tx(sys.argv[2], sys.argv[3])
assert record["sealed"] and len(record["members"]) == 1
member = record["members"][0]
assert member["class"] == "native" and member["cleanup_owner"] == "claude-code"
del member["cleanup_owner"]
member.pop("cleanup_policy", None)
tx.atomic_write_json(tx.tx_path(sys.argv[2], sys.argv[3]), record)
PYH
}

make_repo() { # <name>
    local repo="$SANDBOX/$1"
    mkdir -p "$repo/.claude/worktrees"
    git -C "$repo" init -q -b main
    printf 'seed\n' >"$repo/seed.txt"
    printf 'PROTECTED_PATHS="src"\n' >"$repo/orchestration.config"
    git -C "$repo" add -A; git -C "$repo" commit -q -m seed
    printf '%s\n' "$repo"
}
add_tree() { git -C "$1" worktree add -q -b "worktree-agent-$2" "$1/.claude/worktrees/agent-$2"; }
RC=0; OUT_HOOK=""
run_hook() { OUT_HOOK="$(REAP_WORKTREES_ROOT="$1" RICHOS_ENTITY_ROOT="$1" "$HOOK" </dev/null 2>/dev/null)"; RC=$?; }
json_context() { printf '%s' "$1" | python3 -c 'import json,sys
try:
    print(json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"])
except Exception:
    pass' 2>/dev/null; }

echo "=== session-start-reap-worktrees (status + inventory) tests ==="

# W01 nothing to do: exit 0, one line of SessionStart JSON, DONE + DRY-RUN
REPO="$(make_repo empty)"
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
[ "$RC" -eq 0 ] && printf '%s' "$CTX" | grep -q 'worktree reconciler: DONE' && printf '%s' "$CTX" | grep -q 'DRY-RUN, nothing removed' \
    && ok "W01  empty repo: exit 0, reconciler DONE, inventory DRY-RUN" || bad "W01  rc=$RC ctx=$CTX"
[ "$(printf '%s\n' "$OUT_HOOK" | grep -c .)" -eq 1 ] && printf '%s' "$OUT_HOOK" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null \
    && ok "W02  exactly one line of valid SessionStart JSON" || bad "W02  json: $OUT_HOOK"

# W03 THE INVERSION: a merged, clean, unlocked native worktree is NOT removed
REPO="$(make_repo reapable)"
add_tree "$REPO" aaaa0001
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
if [ "$RC" -eq 0 ] && [ -d "$REPO/.claude/worktrees/agent-aaaa0001" ] \
   && git -C "$REPO" rev-parse --verify -q refs/heads/worktree-agent-aaaa0001 >/dev/null \
   && printf '%s' "$CTX" | grep -q 'DRY-RUN, nothing removed'; then
    ok "W03  a merged, clean, unlocked native worktree SURVIVES session start (no sweep decides liveness any more)"
else
    bad "W03  rc=$RC dir=$([ -d "$REPO/.claude/worktrees/agent-aaaa0001" ] && echo present || echo GONE) ctx=$CTX"
fi
printf '%s' "$CTX" | grep -q 'summary (DRY-RUN)' && ok "W04  the inventory's summary is labeled DRY-RUN (a selection, never a removal)" || bad "W04  ctx=$CTX"
printf '%s' "$CTX" | grep -q 'coverage' && ok "W05  the inventory still carries its denominator (coverage line)" || bad "W05  ctx=$CTX"

# W06 a dirty worktree survives too, and so does one carrying unlanded commits
REPO="$(make_repo dirty)"
add_tree "$REPO" bbbb0002; printf 'wip\n' >"$REPO/.claude/worktrees/agent-bbbb0002/wip.txt"
add_tree "$REPO" bbbb0003; printf 'c\n' >"$REPO/.claude/worktrees/agent-bbbb0003/c.txt"
git -C "$REPO/.claude/worktrees/agent-bbbb0003" add c.txt; git -C "$REPO/.claude/worktrees/agent-bbbb0003" commit -q -m unlanded
run_hook "$REPO"
[ "$RC" -eq 0 ] && [ -f "$REPO/.claude/worktrees/agent-bbbb0002/wip.txt" ] && [ -f "$REPO/.claude/worktrees/agent-bbbb0003/c.txt" ] \
    && ok "W06  dirty and unmerged worktrees are untouched" || bad "W06  rc=$RC"

blocked_why() { # <agent-id> -> the member's blocked_reason, or ""
    T show --session-id "$SID" --agent-id "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    m = (json.load(sys.stdin).get("members") or [{}])[0]
except Exception:
    m = {}
print((m.get("blocked_reason") or "").replace("\n", " "))
' 2>/dev/null
}

# W07-W09: pending historical recovery is reported but never advanced.
REPO="$(make_repo recover)"
AID="a0000000000ssr01"
add_tree "$REPO" "$AID"
printf '{"kind":"native","teammate":"dev-opus-ssr1","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr1 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr1 --agent-id "$AID" >/dev/null
T start --session-id "$SID" --agent-id "$AID" --cwd "$REPO/.claude/worktrees/agent-$AID" >/dev/null
historical_seal "$AID"
printf 'evidence\n' >"$REPO/.claude/worktrees/agent-$AID/evidence.txt"
T claim --session-id "$SID" --agent-id "$AID" --ingress SubagentStop >/dev/null   # quarantined; the reconciler never ran
Q="$REPO/.claude/worktrees/agent-$AID.richos-terminal-${SID:0:8}-$AID"
[ -d "$Q" ] || bad "W07-setup  quarantine missing"
cp "$SANDBOX/tx/$SID/$AID.json" "$SANDBOX/w07-before.json"
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
STATE="$(T members --session-id "$SID" --agent-id "$AID" | cut -f5)"
if [ "$RC" -eq 0 ] && [ "$STATE" = "quarantined" ] && [ -d "$Q" ] \
   && cmp -s "$SANDBOX/w07-before.json" "$SANDBOX/tx/$SID/$AID.json" \
   && [ ! -e "$SANDBOX/captures/$SID/$AID" ] \
   && printf '%s' "$CTX" | grep -q 'worktree reconciler: PENDING'; then
    ok "W07  pending quarantine and exact transaction remain unchanged; no capture is created"
else
    bad "W07  rc=$RC state=$STATE ctx=$CTX"
fi
[ "$(cat "$Q/evidence.txt")" = "evidence" ] \
    && ok "W08  original pending evidence survives byte-for-byte at its existing path" || bad "W08  pending evidence changed"
printf '%s' "$CTX" | grep -q 'transactions touched=0' && ok "W09  status reports zero transactions touched" || bad "W09  ctx=$CTX"

# W10: a recreated original and its pending transaction remain exactly as found.
REPO="$(make_repo hardfail)"
AID2="a0000000000ssr02"
add_tree "$REPO" "$AID2"
printf '{"kind":"native","teammate":"dev-opus-ssr2","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr2 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr2 --agent-id "$AID2" >/dev/null
T start --session-id "$SID" --agent-id "$AID2" --cwd "$REPO/.claude/worktrees/agent-$AID2" >/dev/null
historical_seal "$AID2"
T claim --session-id "$SID" --agent-id "$AID2" --ingress SubagentStop >/dev/null
mkdir -p "$REPO/.claude/worktrees/agent-$AID2"; printf 'ghost\n' >"$REPO/.claude/worktrees/agent-$AID2/ghost.txt"   # both present: residue reappeared
python3 - "$TX_PY" "$SID" "$AID2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tx", sys.argv[1]); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
with tx.tx_lock(sys.argv[2], sys.argv[3]):
    tx.update_member(sys.argv[2], sys.argv[3], 0, state="ref_saved")
PY
cp "$SANDBOX/tx/$SID/$AID2.json" "$SANDBOX/w10-before.json"
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
STATE2="$(T members --session-id "$SID" --agent-id "$AID2" | cut -f5)"
if [ "$RC" -eq 0 ] && [ "$STATE2" = "ref_saved" ] \
   && cmp -s "$SANDBOX/w10-before.json" "$SANDBOX/tx/$SID/$AID2.json" \
   && [ "$(cat "$REPO/.claude/worktrees/agent-$AID2/ghost.txt")" = "ghost" ] \
   && [ ! -e "$SANDBOX/captures/$SID/$AID2" ]; then
    ok "W10  recreated original, exact pending transaction and absent captures remain unchanged"
else
    bad "W10  rc=$RC state=$STATE2 ctx=$CTX"
fi

# W10b: an already recorded blocked condition stays visible without retrying it.
REPO="$(make_repo blocked)"
AID2B="a000000000ssr02b"
add_tree "$REPO" "$AID2B"
git -C "$REPO" worktree lock --reason "claude agent agent-a0000000000FOREIGN (pid 1 start now)" "$REPO/.claude/worktrees/agent-$AID2B"
printf '{"kind":"native","teammate":"dev-opus-ssr2b","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr2b >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr2b --agent-id "$AID2B" >/dev/null
T start --session-id "$SID" --agent-id "$AID2B" --cwd "$REPO/.claude/worktrees/agent-$AID2B" >/dev/null
historical_seal "$AID2B"
T claim --session-id "$SID" --agent-id "$AID2B" --ingress SubagentStop >/dev/null
python3 - "$TX_PY" "$SID" "$AID2B" <<'PYB'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("tx",sys.argv[1]);tx=importlib.util.module_from_spec(spec);spec.loader.exec_module(tx)
with tx.tx_lock(sys.argv[2],sys.argv[3]):
    tx.update_member(sys.argv[2],sys.argv[3],0,blocked=True,blocked_reason="fixture existing ownership hold")
PYB
cp "$SANDBOX/tx/$SID/$AID2B.json" "$SANDBOX/w10b-before.json"
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
if [ "$RC" -eq 0 ] && printf '%s' "$CTX" | grep -q 'worktree reconciler: BLOCKED' \
   && printf '%s' "$CTX" | grep -qE 'BLOCKED=[1-9][0-9]*' \
   && cmp -s "$SANDBOX/w10b-before.json" "$SANDBOX/tx/$SID/$AID2B.json" \
   && [ -d "$REPO/.claude/worktrees/agent-$AID2B.richos-terminal-${SID:0:8}-$AID2B" ]; then
    ok "W10b existing BLOCKED status remains visible and its transaction is untouched"
else
    bad "W10b rc=$RC ctx=$CTX"
fi

# W11: even a legacy recovery budget cannot turn a status read into recovery.
# Snapshot every pending record and capture byte, including names and modes.
pending_snapshot() {
    python3 - "$SANDBOX/tx" "$SANDBOX/captures" <<'PYS'
import hashlib,json,os,stat,sys
rows=[]
for root in sys.argv[1:]:
    if not os.path.lexists(root):rows.append([root,"absent"]);continue
    for parent,dirs,files in os.walk(root):
        for name in sorted(dirs+files):
            path=os.path.join(parent,name);info=os.lstat(path)
            data=os.readlink(path).encode() if stat.S_ISLNK(info.st_mode) else open(path,'rb').read() if stat.S_ISREG(info.st_mode) else b''
            rows.append([path,info.st_mode,hashlib.sha256(data).hexdigest()])
print(hashlib.sha256(json.dumps(sorted(rows),sort_keys=True).encode()).hexdigest())
PYS
}
BEFORE="$(pending_snapshot)"
OUT_HOOK="$(SESSION_START_RECONCILE_BUDGET=3600 REAP_WORKTREES_ROOT="$REPO" RICHOS_ENTITY_ROOT="$REPO" "$HOOK" </dev/null 2>/dev/null)"; RC=$?
CTX="$(json_context "$OUT_HOOK")"
if [ "$RC" -eq 0 ] && [ "$BEFORE" = "$(pending_snapshot)" ] && printf '%s' "$CTX" | grep -q 'transactions touched=0'; then
    ok "W11  status-only SessionStart leaves every pending record/capture unchanged regardless of old recovery budget"
else
    bad "W11  rc=$RC pending snapshot changed or status absent: ctx=${CTX:0:200}"
fi

# W12 missing reconciler / missing reaper: exit 0, announced as INSTALL FAILURE
NOREC="$(mktemp -d -t ssr-norec.XXXXXX)"
mkdir -p "$NOREC/scripts/hooks" "$NOREC/scripts/lib"
cp "$HOOK" "$NOREC/scripts/hooks/"; cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$NOREC/scripts/lib/"
cp "$ENGINE_ROOT/scripts/reap-stale-worktrees.sh" "$NOREC/scripts/"; chmod +x "$NOREC/scripts/"*.sh "$NOREC/scripts/hooks/"*.sh
REPO="$(make_repo norec)"
OUT_HOOK="$(REAP_WORKTREES_ROOT="$REPO" RICHOS_ENTITY_ROOT="$REPO" RICHOS_ENGINE_ROOT="$NOREC" "$NOREC/scripts/hooks/session-start-reap-worktrees.sh" </dev/null 2>/dev/null)"; RC=$?
CTX="$(json_context "$OUT_HOOK")"
[ "$RC" -eq 0 ] && printf '%s' "$CTX" | grep -q 'ENGINE INSTALL FAILURE — scripts/reconcile-terminal-worktrees.py is missing' \
    && ok "W12  missing reconciler: exit 0 and an INSTALL FAILURE in the context, not a skip" || bad "W12  rc=$RC ctx=$CTX"
rm -f "$NOREC/scripts/reap-stale-worktrees.sh"; cp "$ENGINE_ROOT/scripts/reconcile-terminal-worktrees.py" "$NOREC/scripts/"; cp "$ENGINE_ROOT/scripts/lib/worktree-transactions.py" "$NOREC/scripts/lib/"
OUT_HOOK="$(REAP_WORKTREES_ROOT="$REPO" RICHOS_ENTITY_ROOT="$REPO" RICHOS_ENGINE_ROOT="$NOREC" "$NOREC/scripts/hooks/session-start-reap-worktrees.sh" </dev/null 2>/dev/null)"; RC=$?
CTX="$(json_context "$OUT_HOOK")"
[ "$RC" -eq 0 ] && printf '%s' "$CTX" | grep -q 'ENGINE INSTALL FAILURE — scripts/reap-stale-worktrees.sh is missing' \
    && ok "W13  missing inventory script: exit 0 and an INSTALL FAILURE in the context" || bad "W13  rc=$RC ctx=$CTX"
rm -rf "$NOREC"

# W14 garbage stdin is ignored (the hook never reads it)
REPO="$(make_repo stdin)"
OUT_HOOK="$(printf 'garbage' | REAP_WORKTREES_ROOT="$REPO" RICHOS_ENTITY_ROOT="$REPO" "$HOOK" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -n "$(json_context "$OUT_HOOK")" ] && ok "W14  garbage stdin: exit 0, JSON still emitted" || bad "W14  rc=$RC"

# W15 nothing was written outside the sandbox
[ ! -e "$HOME/.claude/state/worktree-transactions/$SID" ] && ok "W15  no transaction for the test session reached the operator's real store" || bad "W15  real store touched"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== session-start-reap-worktrees tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== session-start-reap-worktrees tests: all $PASS passed ==="

if [ -f "$SCRIPT_DIR/session-start-reap-worktrees.mutation.sh" ]; then
    bash "$SCRIPT_DIR/session-start-reap-worktrees.mutation.sh" || exit 1
fi
exit 0
