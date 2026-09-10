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
# The reclaim lane reads the ownership ledger and archives ignored residue.
# Both stores are redirected with the transaction store or the lane refuses
# to act at all (its hermetic-rooting check): a sandbox must never read the
# operator's real record, nor write into the operator's real captures.
export RICHOS_WORKTREE_LEDGER="$SANDBOX/ledger.jsonl"
export RICHOS_WORKTREE_CAPTURE_DIR="$SANDBOX/captures"
SID="deadbeef-0000-4000-8000-000000000000"
# These quarantine/capture regressions replay records from the pre-platform-owner
# format. New native ownership is covered by native-platform-cleanup.test.py.
# Convert only fixture records after a successful explicit seal, never production code.
#
# A HISTORICAL RECORD IS DEFINED BY THE ABSENCE OF EVERY CLEANUP-ROUTING KEY,
# and there is now more than one. terminalize() sends a member down the
# quarantine/capture route only when it is neither platform-owned
# (`cleanup_owner`, which selects Claude-owned native cleanup) nor
# daily-reclaimed (`cleanup_policy: integrated-daily`, which leaves the
# worktree at its original path for the reconciler). Seal stamps BOTH. A
# converter that strips one and not the other produces a record that is
# historical in name only, and the cases below then assert a route their own
# fixture no longer selects. Any future key that routes cleanup belongs in
# this list on the same commit that introduces it.
SEAL_MODERN=0   # 1 = keep the cleanup-routing keys a real seal stamps
T() {
    python3 "$TX_PY" "$@"
    local rc=$?
    if [ "$rc" -eq 0 ] && [ "${1:-}" = seal ] && [ "$SEAL_MODERN" -eq 0 ]; then
        python3 - "$RICHOS_WORKTREE_TX_DIR" <<'HISTORICAL'
import json, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('*/*.json'):
    record=json.loads(path.read_text())
    if record.get('record')=='transaction' and not record.get('terminal'):
        for member in record.get('members',[]):
            member.pop('cleanup_owner',None)
            member.pop('cleanup_policy',None)
        path.write_text(json.dumps(record))
HISTORICAL
    fi
    return "$rc"
}

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
# ROUND 11 (2026-09-10): this is the one case in this file whose record is
# NOT converted to the historical shape (the converter skips a record that is
# already terminal), so it is the only one that exercises a MODERN seal — and
# a modern seal now reclaims in the event instead of leaving the workspace for
# the 04:00 job. The assertion that it "preserves Claude-owned native cleanup"
# was the 24-hour gap written down as an expectation.
if [ "$ING3" = "SubagentStop via" ] && [ ! -e "$ENTITY/.claude/worktrees/agent-$A3" ] \
   && [ ! -e "$(q "$ENTITY/.claude/worktrees/agent-$A3" "$A3")" ] \
   && ! git -C "$ENTITY" show-ref --verify -q "refs/heads/worktree-agent-$A3" \
   && [ ! -f "$SANDBOX/tx/$SID/pending-terminal/$A3.json" ]; then
    ok "R21b ...and when the manifest later SEALS, the pending event claims it (ingress SubagentStop, via pending), reclaims the clean workspace and its branch in that same event, and is consumed"
else
    bad "R21b ingress=[$ING3] orig=$([ -e "$ENTITY/.claude/worktrees/agent-$A3" ] && echo present || echo gone) branch=$(git -C "$ENTITY" show-ref --verify -q "refs/heads/worktree-agent-$A3" && echo kept || echo deleted) pending=$([ -f "$SANDBOX/tx/$SID/pending-terminal/$A3.json" ] && echo kept || echo consumed)"
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

# --- 4c. A MISMATCHED SubagentStop NEVER CLAIMS BY cwd -------------------------
# (CEO specification 2026-09-03, worktree-terminal-authority-fix-recommendation
# section 2). MEASURED on this machine 2026-09-03: nine SubagentStop events
# carrying DIFFERENT agent ids, empty agent_type and cwd = a LIVE teammate's
# native worktree fired while that teammate was working — nested / helper
# agents execute inside the parent's cwd. Promoting such a stop to the
# parent's ownership by cwd would have terminalized a live worker nine times.
# The stop-side id is authority only when it IS the ownership id.
A3C="a000000000000t3c"
seal "$A3C" dev-opus-t3c "$OTHER:$SANDBOX/other-wt/dev-opus-t3c:dev-opus-t3c"
NAT3C="$ENTITY/.claude/worktrees/agent-$A3C"
STOPS_OK=1
for n in 1 2 3 4 5 6 7 8 9 10; do
    OUT="$(printf '{"session_id":"%s","hook_event_name":"SubagentStop","agent_id":"nested%02d00000000000","agent_type":"","cwd":"%s","stop_hook_active":false}' "$SID" "$n" "$NAT3C" | "$HOOK" 2>&1)"; RC=$?
    { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || STOPS_OK=0
done
STATE3C="$(T show --session-id "$SID" --agent-id "$A3C" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state"))')"
if [ "$STOPS_OK" -eq 1 ] && [ -d "$NAT3C" ] && [ -d "$SANDBOX/other-wt/dev-opus-t3c" ] && [ "$STATE3C" = "sealed" ] \
   && ! T terminal-agent --agent-id "$A3C" >/dev/null 2>&1 && [ "$(ls "$SANDBOX/tx/$SID/pending-terminal" 2>/dev/null | grep -c nested)" = "0" ]; then
    ok "R28  TEN different nested stop ids from inside a live worker's cwd claim NOTHING: no terminal record, no pending record, both worktrees untouched, the transaction still sealed"
else
    bad "R28  stops_ok=$STOPS_OK state=$STATE3C native=$([ -d "$NAT3C" ] && echo present || echo GONE) ext=$([ -d "$SANDBOX/other-wt/dev-opus-t3c" ] && echo present || echo GONE) terminal=$(T terminal-agent --agent-id "$A3C" >/dev/null 2>&1 && echo yes || echo no)"
fi
run "$(stop_payload "$A3C")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "SubagentStop ingress WON the claim for agent $A3C" && [ ! -d "$NAT3C" ] \
    && ok "R29  ...while the SubagentStop whose agent_id IS the ownership id claims it (exact authority, not a preferred event)" || bad "R29  rc=$RC: ${OUT:0:160}"

# --- 4d. TaskStop: THE EXPLICIT-KILL INGRESS ------------------------------------
# (CEO specification 2026-09-03, section 1). Measured shape of the TaskStop
# result on this machine (lead transcript, session df2b4fd1, 17:10): the tool
# result is a JSON STRING
#   {"message":"Successfully stopped task: <id> (<desc>)","task_id":"<id>","task_type":"local_agent","command":"<desc>"}
# and the REQUEST carried task_id = the reusable teammate name ("zach-opus-b1").
# Only the result supplied the immutable ownership id; the hook joins on the
# structured task_id and nothing else — not the request, not the sentence.
taskstop_payload() { # <requested-name> <shape: str|dict|list|noid|error> <returned-id>
    python3 - "$SID" "$1" "$2" "$3" <<'PY'
import json, sys
sid, requested, shape, tid = sys.argv[1:5]
obj = {"message": "Successfully stopped task: %s (Close six blockers)" % tid, "task_id": tid,
       "task_type": "local_agent", "command": "Close six blockers"}
if shape == "str":     resp = json.dumps(obj)
elif shape == "dict":  resp = obj
elif shape == "list":  resp = [{"type": "text", "text": json.dumps(obj)}]
elif shape == "noid":  resp = {"message": "Successfully stopped task: %s (Close six blockers)" % tid}
elif shape == "error": resp = dict(obj, error="task not found", is_error=True)
else: raise SystemExit("bad shape")
print(json.dumps({"session_id": sid, "hook_event_name": "PostToolUse", "tool_name": "TaskStop", "tool_use_id": "toolu_ts",
                  "tool_input": {"task_id": requested}, "tool_response": resp}))
PY
}
A3D="a000000000000t3d"
seal "$A3D" dev-opus-t3d "$OTHER:$SANDBOX/other-wt/dev-opus-t3d:dev-opus-t3d"
run "$(taskstop_payload dev-opus-t3d str "$A3D")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "TaskStop ingress WON the claim for agent $A3D" \
   && [ ! -d "$ENTITY/.claude/worktrees/agent-$A3D" ] && [ ! -d "$SANDBOX/other-wt/dev-opus-t3d" ] && T terminal-agent --agent-id "$A3D" >/dev/null 2>&1; then
    ok "R30  a successful TaskStop whose request named the TEAMMATE and whose result (a JSON string, the measured shape) returned the ownership id claims that exact transaction: both members quarantined, agent terminal"
else
    bad "R30  rc=$RC native=$([ -d "$ENTITY/.claude/worktrees/agent-$A3D" ] && echo present || echo gone) out=${OUT:0:200}"
fi
DET="$(T show --session-id "$SID" --agent-id "$A3D" | python3 -c 'import json,sys; t=json.load(sys.stdin)["terminal"]; print(t["ingress"], t["detail"])')"
[ "$DET" = "TaskStop requested=dev-opus-t3d" ] && ok "R31  the record names TaskStop as the ingress and keeps the requested name as provenance only" || bad "R31  detail=[$DET]"
run "$(taskstop_payload dev-opus-t3d str "$A3D")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'TaskStop ingress resumed the claim' && ok "R32  a second TaskStop result resumes idempotently" || bad "R32  rc=$RC: ${OUT:0:120}"
A3E="a000000000000t3e"; seal "$A3E" dev-opus-t3e
run "$(taskstop_payload dev-opus-t3e dict "$A3E")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "TaskStop ingress WON" && [ ! -d "$ENTITY/.claude/worktrees/agent-$A3E" ] \
    && ok "R33  tool_response as a structured dict claims too" || bad "R33  dict rc=$RC: ${OUT:0:120}"
A3F="a000000000000t3f"; seal "$A3F" dev-opus-t3f
run "$(taskstop_payload dev-opus-t3f list "$A3F")"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "TaskStop ingress WON" && [ ! -d "$ENTITY/.claude/worktrees/agent-$A3F" ] \
    && ok "R34  tool_response as content blocks whose text is the JSON claims too" || bad "R34  list rc=$RC: ${OUT:0:120}"
A3G="a000000000000t3g"; seal "$A3G" dev-opus-t3g
run "$(taskstop_payload dev-opus-t3g noid "$A3G")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -d "$ENTITY/.claude/worktrees/agent-$A3G" ] && ! T terminal-agent --agent-id "$A3G" >/dev/null 2>&1; then
    ok "R35  a result with NO structured task_id claims nothing — even though its success sentence names the id and its request names a sealed teammate (neither prose nor the request is authority)"
else
    bad "R35  noid rc=$RC terminal=$(T terminal-agent --agent-id "$A3G" >/dev/null 2>&1 && echo yes || echo no) out=${OUT:0:120}"
fi
run "$(taskstop_payload dev-opus-t3g error "$A3G")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -d "$ENTITY/.claude/worktrees/agent-$A3G" ] && ! T terminal-agent --agent-id "$A3G" >/dev/null 2>&1 \
    && ok "R36  a result carrying an error marker claims nothing, task_id or not (a failed stop stops nothing)" || bad "R36  error rc=$RC out=${OUT:0:120}"
run "$(taskstop_payload some-helper str helper0000000000001)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -f "$SANDBOX/tx/terminal/helper0000000000001" ] \
    && ok "R37  a successful TaskStop for an id RichOS never recorded is a silent no-op (TaskStop may target an agent that owns no worktree)" || bad "R37  helper rc=$RC out=${OUT:0:120}"
run "$(printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"toolu_x","tool_input":{"command":"ls"},"tool_response":{"task_id":"%s","stdout":"x"}}' "$SID" "$A3G")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ! T terminal-agent --agent-id "$A3G" >/dev/null 2>&1 \
    && ok "R38  a PostToolUse for any tool other than TaskStop is ignored even when its response happens to carry a task_id" || bad "R38  other-tool rc=$RC out=${OUT:0:120}"

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
# R25 — TeammateIdle holds NO destructive authority until its payload is
# MEASURED (CEO specification 2026-09-03, worktree-terminal-authority-fix-
# recommendation section 3). The landed review's blocker 1 asked for the
# opposite — register it as an exact-id ingress — and the specification
# supersedes it: on this machine the event has never fired live (1,171
# idle-events rows on 2026-09-03, every one a test fixture with an empty
# session_id), so no field of it is proven to join to the ownership id. The
# assertion below is therefore the same as before this revision, but what it
# certifies is the measurement gate, not the retired "idle is not done"
# doctrine: idle IS done by the CEO's rule; the event is simply unproven.
# When a live payload proves an exact join, it is registered through the
# same compare-and-set claim and this case is inverted. Until then the
# native-disappearance backstop (reconciler) covers native workers.
OUT="$(printf '{"session_id":"%s","hook_event_name":"TeammateIdle","agent_id":"%s","cwd":"%s"}' "$SID2" "$A4" "$ENTITY/.claude/worktrees/agent-$A4" | "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ -d "$ENTITY/.claude/worktrees/agent-$A4" ] && ! T terminal-agent --agent-id "$A4" 2>/dev/null \
    && ok "R25  TeammateIdle is NOT YET a terminal ingress (payload unmeasured on this platform; CEO specification section 3): no claim, no mutation, even with the exact id AND the exact cwd in the payload" || bad "R25  TeammateIdle acted (rc=$RC)"
NOLIB="$(mktemp -d -t terminalize-nolib.XXXXXX)"; mkdir -p "$NOLIB/scripts/hooks" "$NOLIB/scripts/lib"; cp "$HOOK" "$NOLIB/scripts/hooks/"
OUT="$(printf '%s' "$(stop_payload "$A4")" | "$NOLIB/scripts/hooks/terminalize-agent-worktrees.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'worktree-transactions.py is missing' && ok "R26  library missing -> exit 0 with a NOTICE naming it" || bad "R26  nolib rc=$RC: $OUT"
rm -rf "$NOLIB"

# --- 7. the write barrier and the resume guard read the same terminal index -------
[ -f "$SANDBOX/tx/terminal/$A1" ] && [ -f "$SANDBOX/tx/terminal-names/$SID/dev-opus-t1" ] \
    && ok "R27  the terminal indexes are on disk where guard-sealed-worktree.sh and guard-resume-isolation.sh read them" || bad "R27  indexes"

# --- 8. THE IMMEDIATE RECLAIM, END TO END THROUGH THIS HOOK ------------------
# The CEO, 2026-09-10: "WHEN THE FUCK WILL ALL THE FINISHED GARBAGE START
# GETTING CLEANED UP AUTOMATICALLY AND STOP WASTING MY FUCKING TIME?"
#
# Everything below runs the REAL hook on a REAL SubagentStop payload against
# REAL git repositories, with the sealed record produced by the real CLI. The
# only thing not real is the harness that would have spawned the worker.
# E1 is the clean case: gone in the event. E2-E5 are the four refusals, each
# through this same ingress. E6 is the nightly backstop still reclaiming what
# the ingress deliberately skipped.
SEAL_MODERN=1
say_elapsed() { printf '        [%s -> %s, %ss]\n' "$1" "$2" "$3"; }

# E1  the clean case, both member classes, in the event
A9="a000000000000t09"
seal "$A9" dev-opus-t9 "$THIRD:$SANDBOX/third-wt/dev-opus-t9:dev-opus-t9"
E1_NATIVE="$ENTITY/.claude/worktrees/agent-$A9"; E1_EXT="$SANDBOX/third-wt/dev-opus-t9"
E1_T0="$(date -u +%H:%M:%S.%N 2>/dev/null || date -u +%H:%M:%S)"; E1_S0="$(python3 -c 'import time;print(time.time())')"
run "$(stop_payload "$A9")"
E1_T1="$(date -u +%H:%M:%S.%N 2>/dev/null || date -u +%H:%M:%S)"
E1_EL="$(python3 -c 'import sys,time;print("%.2f"%(time.time()-float(sys.argv[1])))' "$E1_S0")"
if [ "$RC" -eq 0 ] && [ ! -e "$E1_NATIVE" ] && [ ! -e "$E1_EXT" ] \
   && ! git -C "$ENTITY" show-ref --verify -q "refs/heads/worktree-agent-$A9" \
   && ! git -C "$THIRD" show-ref --verify -q "refs/heads/dev-opus-t9"; then
    ok "E1  a finished agent's workspaces are GONE and both branches resolved in the stop event itself (native + cross-repository)"
    say_elapsed "$E1_T0" "$E1_T1" "$E1_EL"
else
    bad "E1  rc=$RC native=$([ -e "$E1_NATIVE" ] && echo present || echo gone) external=$([ -e "$E1_EXT" ] && echo present || echo gone) out=${OUT:0:200}"
fi

# E2  UNMERGED is never swept
A10="a000000000000t10"
seal "$A10" dev-opus-t10
E2="$ENTITY/.claude/worktrees/agent-$A10"
printf 'undelivered\n' >"$E2/seed.txt"; git -C "$E2" commit -qam 'not in main'
E2_TIP="$(git -C "$E2" rev-parse HEAD)"
run "$(stop_payload "$A10")"
[ "$RC" -eq 0 ] && [ -d "$E2" ] && [ "$(git -C "$ENTITY" rev-parse "refs/heads/worktree-agent-$A10")" = "$E2_TIP" ] \
    && ok "E2  UNMERGED work is never swept: the workspace and its branch tip survive the ingress" \
    || bad "E2  rc=$RC present=$([ -d "$E2" ] && echo yes || echo no)"

# E3  UNCOMMITTED work is never destroyed
A11="a000000000000t11"
seal "$A11" dev-opus-t11
E3="$ENTITY/.claude/worktrees/agent-$A11"
printf 'unfinished\n' >"$E3/seed.txt"; printf 'evidence\n' >"$E3/untracked.txt"
run "$(stop_payload "$A11")"
[ "$RC" -eq 0 ] && [ -d "$E3" ] && [ "$(cat "$E3/seed.txt")" = "unfinished" ] && [ -f "$E3/untracked.txt" ] \
    && ok "E3  UNCOMMITTED work is never destroyed: modified and untracked bytes are exactly where the worker left them" \
    || bad "E3  rc=$RC present=$([ -d "$E3" ] && echo yes || echo no)"

# E4  a LIVE-LOCKED workspace is never touched, and the lock is never removed
A12="a000000000000t12"
seal "$A12" dev-opus-t12
E4="$ENTITY/.claude/worktrees/agent-$A12"
git -C "$ENTITY" worktree lock --reason "claude agent agent-$A12 (pid $$ start fixture)" "$E4"
IMMEDIATE_RECLAIM_WAIT_SECONDS=0 run "$(stop_payload "$A12")"
E4_REASON="$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1]))["members"][0].get("immediate_reclaim") or {}).get("reason",""))' "$SANDBOX/tx/$SID/$A12.json" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ -d "$E4" ] && git -C "$ENTITY" worktree list --porcelain | grep -q "^locked claude agent agent-$A12"; then
    ok "E4  a LIVE-LOCKED workspace is untouched and its lock is still the platform's -- this engine never removes it"
    printf '        [deferral written on the member: %s]\n' "${E4_REASON:0:110}"
else
    bad "E4  rc=$RC present=$([ -d "$E4" ] && echo yes || echo no) reason=${E4_REASON:0:120}"
fi

# E5  NO OWNERSHIP RECORD means nothing is ever swept, not even beside an owned one
E5="$ENTITY/.claude/worktrees/agent-unrecorded00001"
git -C "$ENTITY" worktree add -q -b unrecorded "$E5"
A13="a000000000000t13"
seal "$A13" dev-opus-t13
run "$(stop_payload "$A13")"
[ "$RC" -eq 0 ] && [ -d "$E5" ] && git -C "$ENTITY" show-ref --verify -q refs/heads/unrecorded \
    && [ ! -e "$ENTITY/.claude/worktrees/agent-$A13" ] \
    && ok "E5  a workspace with NO ownership record is not swept, while the recorded one beside it is: nothing is ever matched by name, by shape or by what it sits next to" \
    || bad "E5  rc=$RC unrecorded=$([ -d "$E5" ] && echo present || echo GONE) recorded=$([ -e "$ENTITY/.claude/worktrees/agent-$A13" ] && echo present || echo gone)"

# E6  the nightly backstop still reclaims what the ingress deliberately skipped
git -C "$ENTITY" worktree unlock "$E4"          # the platform releases its own lock
python3 "$SCRIPT_DIR/../reconcile-terminal-worktrees.py" --agent "$SID/$A12" --quiet >/dev/null 2>&1
[ ! -e "$E4" ] && ! git -C "$ENTITY" show-ref --verify -q "refs/heads/worktree-agent-$A12" \
    && ok "E6  the nightly reconciler still reclaims what the ingress skipped (E4's locked member, once the platform released it) -- the backstop is unchanged and still works" \
    || bad "E6  present=$([ -e "$E4" ] && echo yes || echo no) branch=$(git -C "$ENTITY" show-ref --verify -q "refs/heads/worktree-agent-$A12" && echo kept || echo deleted)"

# E7  ...and it still refuses what the ingress refused for cause
python3 "$SCRIPT_DIR/../reconcile-terminal-worktrees.py" --agent "$SID/$A10" --quiet >/dev/null 2>&1
python3 "$SCRIPT_DIR/../reconcile-terminal-worktrees.py" --agent "$SID/$A11" --quiet >/dev/null 2>&1
[ -d "$E2" ] && [ -d "$E3" ] && [ "$(cat "$E3/seed.txt")" = "unfinished" ] \
    && ok "E7  ...and the nightly pass refuses the unmerged and the uncommitted exactly as the ingress did" \
    || bad "E7  unmerged=$([ -d "$E2" ] && echo kept || echo GONE) dirty=$([ -d "$E3" ] && echo kept || echo GONE)"
SEAL_MODERN=0

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
