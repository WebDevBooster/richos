#!/usr/bin/env bash
#
# session-start-reap-worktrees.test.sh — behavioral tests for the SessionStart
# wrapper, which since 2026-09-03 has NO destructive authority: it runs the
# reconciler as crash recovery and the reaper in DRY-RUN as an inventory.
#
# What is proven: a merged, clean, unlocked native worktree is NOT removed at
# session start (the old behavior, now forbidden); a terminal transaction left
# mid-way IS completed by the wrapper's reconciler run; the inventory still
# reports its denominator and its verdict; every failure is announced, not
# swallowed; the hook always exits 0 and always emits one line of SessionStart
# JSON; nothing in the operator's real record is touched from a sandbox.
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
export RICHOS_RECONCILE_SETTLE=0.2
SID="deadbeef-0000-4000-8000-000000000000"
T() { python3 "$TX_PY" "$@"; }

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

echo "=== session-start-reap-worktrees (recovery + inventory) tests ==="

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

# W07 CRASH RECOVERY: a terminal transaction left at 'quarantined' is carried
# forward to 'verified' — captured, re-read, and then RETAINED.
#
# INVERTED 2026-09-06 (a6c076c; docs/workspace-retirement-safety.md). This case
# used to require state 'removed', the quarantine GONE and the context word
# DONE. Automatic erasure is disabled: after the repeated reviews of the
# worktree-container deletion, neither a process scan nor a final content check
# can exclude a concurrent writer, so `unregister_member` refuses and the
# quarantine and its Git registration stay. `verified` is the terminal member
# state and the verdict word is BLOCKED.
#
# WHAT IS STILL PROVEN, which is the part that matters: the wrapper RAN the
# reconciler and drove the member from 'quarantined' all the way to 'verified'
# with the archive on disk (W08 reads the bytes back out of it). A wrapper that
# runs no reconciler leaves the member at 'quarantined' and turns this red, the
# same as before. What is NO LONGER proven here is deletion, because deletion
# is no longer what the engine does.
REPO="$(make_repo recover)"
AID="a0000000000ssr01"
add_tree "$REPO" "$AID"
printf '{"kind":"native","teammate":"dev-opus-ssr1","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr1 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr1 --agent-id "$AID" >/dev/null
T start --session-id "$SID" --agent-id "$AID" --cwd "$REPO/.claude/worktrees/agent-$AID" >/dev/null
T seal --session-id "$SID" --agent-id "$AID" >/dev/null
printf 'evidence\n' >"$REPO/.claude/worktrees/agent-$AID/evidence.txt"
T claim --session-id "$SID" --agent-id "$AID" --ingress SubagentStop >/dev/null   # quarantined; the reconciler never ran
Q="$REPO/.claude/worktrees/agent-$AID.richos-terminal-${SID:0:8}-$AID"
[ -d "$Q" ] || bad "W07-setup  quarantine missing"
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
STATE="$(T members --session-id "$SID" --agent-id "$AID" | cut -f5)"
W07_WHY="$(blocked_why "$AID")"
if [ "$RC" -eq 0 ] && [ "$STATE" = "verified" ] && [ -d "$Q" ] && [ -f "$SANDBOX/captures/$SID/$AID/member-0/tree.tar" ] \
   && printf '%s' "$CTX" | grep -q 'worktree reconciler: BLOCKED' \
   && printf '%s' "$W07_WHY" | grep -q 'automatic erasure is disabled'; then
    ok "W07  a terminal transaction left mid-way is carried forward at session start: quarantined -> captured -> verified with the archive on disk, and the quarantine RETAINED with the policy named (INVERTED 2026-09-06: it used to require removed + quarantine gone + DONE)"
else
    bad "W07  rc=$RC state=$STATE q=$([ -e "$Q" ] && echo present || echo gone) why=$W07_WHY ctx=$CTX"
fi
tar -xOf "$SANDBOX/captures/$SID/$AID/member-0/tree.tar" evidence.txt | grep -q '^evidence$' \
    && ok "W08  ...and the evidence survived byte-for-byte in the archive" || bad "W08  archive"
printf '%s' "$CTX" | grep -q 'transactions touched=1' && ok "W09  the context line says how many transactions were touched" || bad "W09  ctx=$CTX"

# W10 both present at session start: the RECREATED ORIGINAL IS PRESERVED and
# the member is blocked, never reported as a hard failure for a person.
#
# INVERTED TWICE, and the second one is 2026-09-06 (a6c076c). The 2026-09-03
# revision made this case certify that the residue was archived and removed and
# the context read DONE — it had previously certified PENDING with
# dead-present=1, the manual queue as a session-context line. a6c076c changed
# the answer again: a path that reappeared at the original location has UNKNOWN
# ownership, so the reconciler refuses to touch it at all and records
# `exclusive-access-unavailable: recreated original ... is preserved; ownership
# is unknown`. Nothing is captured, nothing is deleted, and the member stays at
# 'quarantined'.
#
# What this case now proves: the reappeared bytes are STILL THERE afterwards,
# no residue archive was fabricated over them, the reason is recorded on the
# member, and the person is not handed a hard failure (dead-present=0).
REPO="$(make_repo hardfail)"
AID2="a0000000000ssr02"
add_tree "$REPO" "$AID2"
printf '{"kind":"native","teammate":"dev-opus-ssr2","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr2 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr2 --agent-id "$AID2" >/dev/null
T start --session-id "$SID" --agent-id "$AID2" --cwd "$REPO/.claude/worktrees/agent-$AID2" >/dev/null
T seal --session-id "$SID" --agent-id "$AID2" >/dev/null
T claim --session-id "$SID" --agent-id "$AID2" --ingress SubagentStop >/dev/null
mkdir -p "$REPO/.claude/worktrees/agent-$AID2"; printf 'ghost\n' >"$REPO/.claude/worktrees/agent-$AID2/ghost.txt"   # both present: residue reappeared
python3 - "$TX_PY" "$SID" "$AID2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tx", sys.argv[1]); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
with tx.tx_lock(sys.argv[2], sys.argv[3]):
    tx.update_member(sys.argv[2], sys.argv[3], 0, state="ref_saved")
PY
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
STATE2="$(T members --session-id "$SID" --agent-id "$AID2" | cut -f5)"
RES2="$SANDBOX/captures/$SID/$AID2/member-0/residue-1.tar"
W10_WHY="$(blocked_why "$AID2")"
if [ "$RC" -eq 0 ] && printf '%s' "$CTX" | grep -q 'worktree reconciler: BLOCKED' && printf '%s' "$CTX" | grep -q 'hard failures (dead-present)=0' \
   && [ "$STATE2" = "quarantined" ] && printf '%s' "$W10_WHY" | grep -q 'recreated original' \
   && [ "$(cat "$REPO/.claude/worktrees/agent-$AID2/ghost.txt" 2>/dev/null)" = "ghost" ] && [ ! -f "$RES2" ]; then
    ok "W10  both present at session start PRESERVES the recreated original: its bytes are untouched, no residue archive is written over them, the member records 'recreated original ... ownership is unknown', and the person gets no hard failure (dead-present=0) (INVERTED 2026-09-06: it used to require the residue archived and the member removed)"
else
    bad "W10  rc=$RC state=$STATE2 residue=$([ -f "$RES2" ] && echo yes || echo no) ghost=$(cat "$REPO/.claude/worktrees/agent-$AID2/ghost.txt" 2>/dev/null) why=$W10_WHY ctx=$CTX"
fi

# W10b A BLOCKED MEMBER LEADS THE VERDICT WORD. Before 2026-09-04 this state
# printed the word PENDING with a retry count, which is the shape of a
# condition under control. Thirty members read that way for a full day. The
# word is the finding, so the word changes.
#
# SAY WHAT STOPPED BEING PROVEN HERE (2026-09-06, a6c076c). This case was
# written around a quarantine locked by ANOTHER agent, on the reasoning that
# such a member can never be removed by this run and never by waiting. Since
# automatic erasure was disabled, the member never reaches the removal step at
# all: it is blocked by the POLICY, with `automatic erasure is disabled`, and
# the foreign lock is no longer what produces the verdict. The lock is still
# set up, so the case remains truthful about the scenario, but it no longer
# ISOLATES the lock path — a member with no lock at all now blocks identically.
# Whoever restores erasure behind an enforced access boundary should restore
# this case's discrimination with it.
#
# The BLOCKED COUNT IS NO LONGER 1. W07 and W10 leave their own blocked members
# in the same store, so a hard-coded `BLOCKED=1` was reading those cases'
# cleanup rather than this case's finding. It asserts a positive count and this
# member's own recorded reason instead.
REPO="$(make_repo blocked)"
AID2B="a000000000ssr02b"
add_tree "$REPO" "$AID2B"
git -C "$REPO" worktree lock --reason "claude agent agent-a0000000000FOREIGN (pid 1 start now)" "$REPO/.claude/worktrees/agent-$AID2B"
printf '{"kind":"native","teammate":"dev-opus-ssr2b","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr2b >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr2b --agent-id "$AID2B" >/dev/null
T start --session-id "$SID" --agent-id "$AID2B" --cwd "$REPO/.claude/worktrees/agent-$AID2B" >/dev/null
T seal --session-id "$SID" --agent-id "$AID2B" >/dev/null
T claim --session-id "$SID" --agent-id "$AID2B" --ingress SubagentStop >/dev/null
run_hook "$REPO"; CTX="$(json_context "$OUT_HOOK")"
W10B_WHY="$(blocked_why "$AID2B")"
if [ "$RC" -eq 0 ] && printf '%s' "$CTX" | grep -q 'worktree reconciler: BLOCKED' && printf '%s' "$CTX" | grep -qE 'BLOCKED=[1-9][0-9]*' \
   && printf '%s' "$W10B_WHY" | grep -q 'automatic erasure is disabled' \
   && [ -d "$REPO/.claude/worktrees/agent-$AID2B.richos-terminal-${SID:0:8}-$AID2B" ]; then
    ok "W10b a member blocked on a condition waiting cannot clear leads the verdict word with BLOCKED and carries a count; the quarantine is untouched and the member records why (INVERTED: it used to read PENDING with a retry count)"
else
    bad "W10b rc=$RC why=$W10B_WHY ctx=$CTX"
fi

# W11 the budget is honored (the hook must never hold a session start)
REPO="$(make_repo budget)"
AID3="a0000000000ssr03"
add_tree "$REPO" "$AID3"
printf '{"kind":"native","teammate":"dev-opus-ssr3","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr3 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr3 --agent-id "$AID3" >/dev/null
T start --session-id "$SID" --agent-id "$AID3" --cwd "$REPO/.claude/worktrees/agent-$AID3" >/dev/null
T seal --session-id "$SID" --agent-id "$AID3" >/dev/null
T claim --session-id "$SID" --agent-id "$AID3" --ingress SubagentStop >/dev/null
AID4="a0000000000ssr04"
add_tree "$REPO" "$AID4"
printf '{"kind":"native","teammate":"dev-opus-ssr4","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-ssr4 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-ssr4 --agent-id "$AID4" >/dev/null
T start --session-id "$SID" --agent-id "$AID4" --cwd "$REPO/.claude/worktrees/agent-$AID4" >/dev/null
T seal --session-id "$SID" --agent-id "$AID4" >/dev/null
T claim --session-id "$SID" --agent-id "$AID4" --ingress SubagentStop >/dev/null
# A budget of one microsecond cannot cover two captures: at least one of the two
# must be left for the next run, and the context must say the budget was hit.
OUT_HOOK="$(SESSION_START_RECONCILE_BUDGET=0.000001 REAP_WORKTREES_ROOT="$REPO" RICHOS_ENTITY_ROOT="$REPO" "$HOOK" </dev/null 2>/dev/null)"; RC=$?
CTX="$(json_context "$OUT_HOOK")"
S3="$(T members --session-id "$SID" --agent-id "$AID3" | cut -f5)"; S4="$(T members --session-id "$SID" --agent-id "$AID4" | cut -f5)"
if [ "$RC" -eq 0 ] && printf '%s' "$CTX" | grep -q 'time budget reached' && { [ "$S3" != "removed" ] || [ "$S4" != "removed" ]; }; then
    ok "W11  SESSION_START_RECONCILE_BUDGET is honored: the context says the budget was reached and work was left for the next run"
else
    bad "W11  rc=$RC s3=$S3 s4=$S4 ctx=${CTX:0:200}"
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
