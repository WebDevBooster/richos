#!/usr/bin/env bash
#
# terminalize-agent-worktrees.test.sh — behavioral tests for the terminal
# ingress, scripts/hooks/terminalize-agent-worktrees.sh, on both of its
# events.
#
# What is proven, each refusal beside its pass: SubagentStop for a sealed
# agent claims the transaction, saves a backup ref in EACH owning repository
# before anything moves, quarantines every member (native and external) and
# writes the terminal indexes; WorktreeRemove for the exact native path does
# the same and quarantines that path first; whichever arrives second resumes
# idempotently and changes nothing; a third event is a no-op; an agent with no
# sealed transaction (a helper subagent, a read-only type, an unbound spawn)
# produces no claim and touches nothing; a path RichOS never sealed is never
# adopted; a reused name in a later session matches nothing; the hook never
# exits nonzero.
#
# The mutation harness proving each assertion load-bearing is
# scripts/hooks/terminalize-agent-worktrees.mutation.sh, run at the end.
#
# Run directly: scripts/hooks/terminalize-agent-worktrees.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/terminalize-agent-worktrees.sh"
TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t terminalize-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing/non-executable" >&2; exit 1; }
[ -f "$TX_PY" ] || { echo "FATAL: $TX_PY missing" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
SID="deadbeef-0000-4000-8000-000000000000"
T() { python3 "$TX_PY" "$@"; }

seed_repo() { mkdir -p "$1"; git -C "$1" init -q -b main; printf 'seed\n' >"$1/seed.txt"; git -C "$1" add -A; git -C "$1" commit -q -m seed; }
ENTITY="$SANDBOX/entity"; seed_repo "$ENTITY"; mkdir -p "$ENTITY/.claude/worktrees"
OTHER="$SANDBOX/other";   seed_repo "$OTHER"
THIRD="$SANDBOX/third";   seed_repo "$THIRD"

# seal <agent-id> <teammate> [external-repo:path:branch ...]
seal() {
    local aid="$1" name="$2"; shift 2
    local kind="native" ext="[]" first=1 spec
    git -C "$ENTITY" worktree add -q -b "worktree-agent-$aid" "$ENTITY/.claude/worktrees/agent-$aid"
    if [ "$#" -gt 0 ]; then
        kind="native+external"; ext="["
        for spec in "$@"; do
            local repo="${spec%%:*}" rest="${spec#*:}" path branch
            path="${rest%%:*}"; branch="${rest#*:}"
            git -C "$repo" worktree add -q -b "$branch" "$path"
            [ "$first" -eq 1 ] || ext="$ext,"
            ext="$ext{\"repo\":\"$repo\",\"path\":\"$path\",\"branch\":\"$branch\"}"; first=0
        done
        ext="$ext]"
    fi
    printf '{"kind":"%s","teammate":"%s","externals":%s}' "$kind" "$name" "$ext" | T intent --session-id "$SID" --tool-use-id "tu-$aid" >/dev/null
    T bind --session-id "$SID" --tool-use-id "tu-$aid" --agent-id "$aid" >/dev/null
    T start --session-id "$SID" --agent-id "$aid" --cwd "$ENTITY/.claude/worktrees/agent-$aid" >/dev/null
    T seal --session-id "$SID" --agent-id "$aid" >/dev/null
}
stop_payload() { printf '{"session_id":"%s","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"dev","last_assistant_message":"done"}' "$SID" "$1"; }
remove_payload() { printf '{"session_id":"%s","hook_event_name":"WorktreeRemove","worktree_path":"%s"}' "$SID" "$1"; }
run() { OUT="$(printf '%s' "$1" | "$HOOK" 2>&1)"; RC=$?; }
q() { printf '%s.richos-terminal-%s-%s' "$1" "${SID:0:8}" "$2"; }

echo "=== terminalize-agent-worktrees tests ==="

# --- 1. SubagentStop on a two-repository worker -------------------------------
A1="a000000000000t01"
seal "$A1" dev-opus-t1 "$OTHER:$SANDBOX/other-wt/dev-opus-t1:dev-opus-t1"
printf 'evidence\n' >"$SANDBOX/other-wt/dev-opus-t1/untracked.txt"
HEAD_N="$(git -C "$ENTITY/.claude/worktrees/agent-$A1" rev-parse HEAD)"
HEAD_E="$(git -C "$SANDBOX/other-wt/dev-opus-t1" rev-parse HEAD)"
run "$(stop_payload "$A1")"
[ "$RC" -eq 0 ] && ok "R01  SubagentStop exits 0 (a terminal event is never prevented)" || bad "R01  rc=$RC: $OUT"
printf '%s' "$OUT" | grep -q "SubagentStop ingress WON the claim for agent $A1" && ok "R02  the ingress reports that it WON the claim" || bad "R02  report: $OUT"
[ "$(git -C "$ENTITY" rev-parse -q --verify "refs/richos/handoffs/$SID/$A1/worktree-agent-$A1")" = "$HEAD_N" ] \
    && ok "R03  a backup ref for the native member's HEAD exists in the entity repository" || bad "R03  native backup ref"
[ "$(git -C "$OTHER" rev-parse -q --verify "refs/richos/handoffs/$SID/$A1/dev-opus-t1")" = "$HEAD_E" ] \
    && ok "R04  a backup ref for the external member's HEAD exists in ITS repository" || bad "R04  external backup ref"
[ ! -d "$ENTITY/.claude/worktrees/agent-$A1" ] && [ -d "$(q "$ENTITY/.claude/worktrees/agent-$A1" "$A1")" ] \
    && ok "R05  the native member was quarantined beside its original path" || bad "R05  native quarantine"
[ ! -d "$SANDBOX/other-wt/dev-opus-t1" ] && [ -f "$(q "$SANDBOX/other-wt/dev-opus-t1" "$A1")/untracked.txt" ] \
    && ok "R06  the external member was quarantined with its untracked evidence intact" || bad "R06  external quarantine"
T terminal-agent --agent-id "$A1" && ok "R07  the agent id is in the terminal index" || bad "R07  terminal index"
T terminal-name --session-id "$SID" --teammate dev-opus-t1 && ok "R08  the teammate name is terminal in this session" || bad "R08  terminal name"
STATES="$(T members --session-id "$SID" --agent-id "$A1" | cut -f5 | tr '\n' ' ')"
[ "$STATES" = "quarantined quarantined " ] && ok "R09  both members are persisted as quarantined" || bad "R09  states: $STATES"

# --- 2. a second and third event are idempotent --------------------------------
BEFORE="$(T show --session-id "$SID" --agent-id "$A1")"
run "$(stop_payload "$A1")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "SubagentStop ingress resumed the claim" && ok "R10  a second SubagentStop RESUMES (does not re-claim) and exits 0" || bad "R10  rc=$RC: $OUT"
run "$(remove_payload "$(q "$ENTITY/.claude/worktrees/agent-$A1" "$A1")")"
[ "$RC" -eq 0 ] && ok "R11  a WorktreeRemove for the (now quarantined) native path also resumes, exit 0" || bad "R11  rc=$RC: $OUT"
AFTER="$(T show --session-id "$SID" --agent-id "$A1")"
[ "$BEFORE" = "$AFTER" ] && ok "R12  ...and neither changed the transaction record (idempotent)" || bad "R12  record changed"
[ -d "$(q "$SANDBOX/other-wt/dev-opus-t1" "$A1")" ] && ok "R13  ...and the quarantines are untouched" || bad "R13  quarantine moved"

# --- 3. WorktreeRemove FIRST, by exact native path --------------------------
A2="a000000000000t02"
seal "$A2" dev-opus-t2 "$OTHER:$SANDBOX/other-wt/dev-opus-t2:dev-opus-t2" "$THIRD:$SANDBOX/third-wt/dev-opus-t2:dev-opus-t2"
run "$(remove_payload "$ENTITY/.claude/worktrees/agent-$A2")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "WorktreeRemove ingress WON the claim for agent $A2" \
    && ok "R14  WorktreeRemove for the exact native path WINS the claim" || bad "R14  rc=$RC: $OUT"
[ ! -d "$ENTITY/.claude/worktrees/agent-$A2" ] && [ ! -d "$SANDBOX/other-wt/dev-opus-t2" ] && [ ! -d "$SANDBOX/third-wt/dev-opus-t2" ] \
    && ok "R15  THREE repositories: native + two externals all quarantined under one transaction" || bad "R15  three-repo quarantine"
INGRESS="$(T show --session-id "$SID" --agent-id "$A2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["terminal"]["ingress"])')"
[ "$INGRESS" = "WorktreeRemove" ] && ok "R16  the record names WorktreeRemove as the winning ingress" || bad "R16  ingress=$INGRESS"
run "$(stop_payload "$A2")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "resumed the claim" && ok "R17  the later SubagentStop resumes; the same transaction completes once" || bad "R17  rc=$RC: $OUT"
[ "$(T show --session-id "$SID" --agent-id "$A2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["terminal"]["ingress"])')" = "WorktreeRemove" ] \
    && ok "R18  ...and did not overwrite the winner" || bad "R18  winner overwritten"

# --- 4. nothing sealed -> nothing claimed, nothing touched ----------------------
run "$(stop_payload "aba6d9fa03bc418f3")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "R19  SubagentStop for an agent with no transaction (a helper subagent) is silent and exits 0" || bad "R19  rc=$RC: $OUT"
mkdir -p "$ENTITY/.claude/worktrees/agent-stranger0000001"
run "$(remove_payload "$ENTITY/.claude/worktrees/agent-stranger0000001")"
[ "$RC" -eq 0 ] && [ -d "$ENTITY/.claude/worktrees/agent-stranger0000001" ] && [ -z "$OUT" ] \
    && ok "R20  WorktreeRemove for a path RichOS never sealed: not adopted, not moved, silent" || bad "R20  rc=$RC: $OUT"
# --- 4b. an UNSEALED agent's terminal event is REMEMBERED, never discarded ------
# (review 2026-09-03, blocker 4). Until this revision the assertion here was
# the opposite: that a bound-but-unstarted agent's SubagentStop left its
# worktree present AND created no terminal marker — the event was dropped,
# and a later bind or seal could never recover it. The old assertion was the
# defect wearing a test's clothes. Now: the event is persisted as PENDING
# keyed by (session_id, agent_id); the agent is terminal by policy from that
# moment (first SubagentStop is terminal, sealed or not); nothing is
# quarantined yet because nothing is sealed; and the moment the manifest
# seals, the pending event claims and terminalizes it automatically.
A3="a000000000000t03"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A3" "$ENTITY/.claude/worktrees/agent-$A3"
printf '{"kind":"native","teammate":"dev-opus-t3","externals":[]}' | T intent --session-id "$SID" --tool-use-id "tu-$A3" >/dev/null
T bind --session-id "$SID" --tool-use-id "tu-$A3" --agent-id "$A3" >/dev/null
run "$(stop_payload "$A3")"
if [ "$RC" -eq 0 ] && [ -d "$ENTITY/.claude/worktrees/agent-$A3" ] && [ -f "$SANDBOX/tx/$SID/pending-terminal/$A3.json" ] \
   && printf '%s' "$OUT" | grep -q 'recorded as PENDING' && T terminal-agent --agent-id "$A3" >/dev/null 2>&1; then
    ok "R21  an UNSEALED (bound, never started) agent's SubagentStop is PERSISTED as pending, the agent is terminal by policy, and its worktree is not touched yet (nothing is sealed)"
else
    bad "R21  rc=$RC pending=$([ -f "$SANDBOX/tx/$SID/pending-terminal/$A3.json" ] && echo yes || echo no) terminal=$(T terminal-agent --agent-id "$A3" >/dev/null 2>&1 && echo yes || echo no) out=${OUT:0:160}"
fi
# the start fact arrives late (the race the review names): sealing consumes the
# pending event — the transaction is claimed, the worktree quarantined
T start --session-id "$SID" --agent-id "$A3" --cwd "$ENTITY/.claude/worktrees/agent-$A3" >/dev/null
T seal --session-id "$SID" --agent-id "$A3" >/dev/null 2>&1
ING3="$(T show --session-id "$SID" --agent-id "$A3" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("terminal") or {}; print(t.get("ingress",""), "via" if t.get("via_pending") else "direct")')"
if [ "$ING3" = "SubagentStop via" ] && [ ! -d "$ENTITY/.claude/worktrees/agent-$A3" ] && [ -d "$(q "$ENTITY/.claude/worktrees/agent-$A3" "$A3")" ] \
   && [ ! -f "$SANDBOX/tx/$SID/pending-terminal/$A3.json" ]; then
    ok "R21b ...and when the manifest later SEALS, the pending event claims it (ingress SubagentStop, via pending), quarantines the worktree and is consumed"
else
    bad "R21b ingress=[$ING3] orig=$([ -d "$ENTITY/.claude/worktrees/agent-$A3" ] && echo present || echo gone) pending=$([ -f "$SANDBOX/tx/$SID/pending-terminal/$A3.json" ] && echo kept || echo consumed)"
fi
run "$(stop_payload "$A3")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'resumed the claim' && ok "R21c ...and a later SubagentStop resumes the same transaction (idempotent)" || bad "R21c rc=$RC: ${OUT:0:120}"
# WorktreeRemove for the native path of an UNSEALED agent this session has a
# record for: the exact platform id in `agent-<id>`, accepted only because a
# bound record exists for it; the removal is recorded as pending too
A3B="a000000000000t3b"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A3B" "$ENTITY/.claude/worktrees/agent-$A3B"
printf '{"kind":"native","teammate":"dev-opus-t3b","externals":[]}' | T intent --session-id "$SID" --tool-use-id "tu-$A3B" >/dev/null
T bind --session-id "$SID" --tool-use-id "tu-$A3B" --agent-id "$A3B" >/dev/null
run "$(remove_payload "$ENTITY/.claude/worktrees/agent-$A3B")"
if [ "$RC" -eq 0 ] && [ -f "$SANDBOX/tx/$SID/pending-terminal/$A3B.json" ] && [ -d "$ENTITY/.claude/worktrees/agent-$A3B" ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ingress"])' "$SANDBOX/tx/$SID/pending-terminal/$A3B.json")" = "WorktreeRemove" ]; then
    ok "R21d WorktreeRemove for an unsealed-but-bound agent's native path is recorded as a pending WorktreeRemove (exact platform id; nothing moved)"
else
    bad "R21d rc=$RC pending=$([ -f "$SANDBOX/tx/$SID/pending-terminal/$A3B.json" ] && echo yes || echo no) out=${OUT:0:160}"
fi
# an agent with NO record of any kind (a helper subagent) still produces nothing
run "$(stop_payload "aba6d9fa03bc418f4")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -f "$SANDBOX/tx/$SID/pending-terminal/aba6d9fa03bc418f4.json" ] \
    && ok "R21e an agent with neither a bound nor a start record gets NO pending record (a stop event about nobody is silence)" || bad "R21e rc=$RC out=${OUT:0:120}"

# --- 5. a reused name in a LATER session matches nothing ------------------------
SID2="22222222-0000-4000-8000-000000000002"
A4="b000000000000t04"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A4" "$ENTITY/.claude/worktrees/agent-$A4"
printf '{"kind":"native","teammate":"dev-opus-t1","externals":[]}' | RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx" T intent --session-id "$SID2" --tool-use-id "tu-$A4" >/dev/null
T bind --session-id "$SID2" --tool-use-id "tu-$A4" --agent-id "$A4" >/dev/null
T start --session-id "$SID2" --agent-id "$A4" --cwd "$ENTITY/.claude/worktrees/agent-$A4" >/dev/null
T seal --session-id "$SID2" --agent-id "$A4" >/dev/null
T terminal-name --session-id "$SID2" --teammate dev-opus-t1 2>/dev/null && bad "R22  reused name inherited terminal state" \
    || ok "R22  the same teammate name in a LATER session is not terminal; its transaction is its own"
[ -d "$ENTITY/.claude/worktrees/agent-$A4" ] && ok "R23  ...and its worktree is untouched by the earlier agent's terminalization" || bad "R23  reused-name tree moved"

# --- 6. never blocks -------------------------------------------------------------
OUT="$(printf 'not json' | "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "R24  unparseable payload -> exit 0" || bad "R24  rc=$RC"
OUT="$(printf '{"session_id":"%s","hook_event_name":"TeammateIdle","agent_id":"%s"}' "$SID2" "$A4" | "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ -d "$ENTITY/.claude/worktrees/agent-$A4" ] && ! T terminal-agent --agent-id "$A4" 2>/dev/null \
    && ok "R25  TeammateIdle (diagnostic only) is ignored: no claim, no mutation" || bad "R25  TeammateIdle acted (rc=$RC)"
NOLIB="$(mktemp -d -t terminalize-nolib.XXXXXX)"; mkdir -p "$NOLIB/scripts/hooks" "$NOLIB/scripts/lib"; cp "$HOOK" "$NOLIB/scripts/hooks/"
OUT="$(printf '%s' "$(stop_payload "$A4")" | "$NOLIB/scripts/hooks/terminalize-agent-worktrees.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'worktree-transactions.py is missing' && ok "R26  library missing -> exit 0 with a NOTICE naming it" || bad "R26  nolib rc=$RC: $OUT"
rm -rf "$NOLIB"

# --- 7. the write barrier and the resume guard read the same terminal index -------
[ -f "$SANDBOX/tx/terminal/$A1" ] && [ -f "$SANDBOX/tx/terminal-names/$SID/dev-opus-t1" ] \
    && ok "R27  the terminal indexes are on disk where guard-sealed-worktree.sh and guard-resume-isolation.sh read them" || bad "R27  indexes"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== terminalize-agent-worktrees tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== terminalize-agent-worktrees tests: all $PASS passed ==="

if [ -f "$SCRIPT_DIR/terminalize-agent-worktrees.mutation.sh" ]; then
    bash "$SCRIPT_DIR/terminalize-agent-worktrees.mutation.sh" || exit 1
fi
exit 0
