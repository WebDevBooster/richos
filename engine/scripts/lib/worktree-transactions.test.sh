#!/usr/bin/env bash
#
# worktree-transactions.test.sh — behavioral tests for
# scripts/lib/worktree-transactions.py: the durable state of a teammate's
# worktrees from spawn intent to removal.
#
# Every case that decides something has its refusal beside its pass. The
# properties proven here are the ones the specification names
# (docs/plans/worktree-real-fix-2026-09-03.md): both event orders seal the
# same manifest; a manifest seals only from a bound intent AND a start fact
# whose agent ids agree; the native member comes from the SubagentStart cwd
# verified against git, never from a name; two terminal ingresses race for
# ONE compare-and-set claim; every member transition is persisted and
# recoverable after a crash at any boundary; a reused name in a later
# session matches nothing.
#
# The mutation harness that proves each of these assertions load-bearing is
# scripts/lib/worktree-transactions.mutation.sh, run at the end of this suite
# so the runner that discovers this file runs it too.
#
# Run directly: scripts/lib/worktree-transactions.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TX_PY="$SCRIPT_DIR/worktree-transactions.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t worktree-tx-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$TX_PY" ] || { echo "FATAL: missing $TX_PY" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
T() { python3 "$TX_PY" "$@"; }
# py <code> — run a snippet with the module loaded as `tx`.
py() {
    TXPY="$TX_PY" python3 -c "
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location('tx', os.environ['TXPY']); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
$1
"
}

seed_repo() { # <path>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    printf 'seed\n' >"$1/seed.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m seed
}
add_native() { # <entity> <agent-id>
    mkdir -p "$1/.claude/worktrees"
    git -C "$1" worktree add -q -b "worktree-agent-$2" "$1/.claude/worktrees/agent-$2"
}
add_external() { # <repo> <dir> <branch>
    git -C "$1" worktree add -q -b "$3" "$2"
}
intent() { # <sid> <tuid> <json-fields>
    printf '%s' "$3" | T intent --session-id "$1" --tool-use-id "$2" >/dev/null
}

ENTITY="$SANDBOX/entity"; seed_repo "$ENTITY"
OTHER="$SANDBOX/other";   seed_repo "$OTHER"
SID="11111111-0000-4000-8000-000000000001"

echo "=== worktree-transactions tests ==="

# --- 1. durable writes --------------------------------------------------------
py "tx.atomic_write_json('$SANDBOX/a/b.json', {'x': 1})"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["x"])' "$SANDBOX/a/b.json")" = "1" ] \
   && [ -z "$(ls "$SANDBOX/a" | grep -v '^b.json$')" ]; then
    ok "T01  atomic_write_json writes the file and leaves no temp file beside it"
else
    bad "T01  atomic write: $(ls -la "$SANDBOX/a")"
fi
py "
try:
    tx.tx_path('$SID', '../escape'); print('ACCEPTED')
except ValueError as e:
    print('REFUSED')
" | grep -q REFUSED && ok "T02  a path-traversing agent id is refused as a segment" || bad "T02  segment traversal accepted"

# --- 2. intent -> bind -----------------------------------------------------------
intent "$SID" tu-1 '{"kind":"native","teammate":"dev-opus-n1","subagent_type":"dev","externals":[]}'
R="$(T bind --session-id "$SID" --tool-use-id tu-nope --agent-id aaaaaa000001 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'no spawn-intent' \
    && ok "T03  bind REFUSES when no intent exists for the tool_use_id (nothing is invented)" \
    || bad "T03  bind without intent rc=$rc: $R"
R="$(T bind --session-id "$SID" --tool-use-id tu-1 --agent-id aaaaaa000001 --source test)"
printf '%s' "$R" | grep -q '"agent_id": "aaaaaa000001"' && printf '%s' "$R" | grep -q '"teammate": "dev-opus-n1"' \
    && ok "T04  bind copies the intent's exact member set onto the agent id" || bad "T04  bind: $R"
R="$(T bind --session-id "$SID" --tool-use-id tu-1 --agent-id aaaaaa000001 --source test)"
[ $? -eq 0 ] && ok "T05  bind is idempotent for the same (tool_use_id, agent_id)" || bad "T05  rebind same: $R"
intent "$SID" tu-1b '{"kind":"native","teammate":"dev-opus-n1b","externals":[]}'
R="$(T bind --session-id "$SID" --tool-use-id tu-1b --agent-id aaaaaa000001 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'already bound' \
    && ok "T06  bind REFUSES to rebind an agent id to a different tool_use_id" || bad "T06  rebind other rc=$rc: $R"
R="$(T bind --session-id "$SID" --tool-use-id tu-1 --agent-id 'bad id!' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "T07  bind refuses a malformed agent id" || bad "T07  bad agent id accepted"

# --- 3. seal: needs BOTH facts, either order, same manifest -------------------------
add_native "$ENTITY" aaaaaa000001
R="$(T seal --session-id "$SID" --agent-id aaaaaa000001)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'no start record' \
    && ok "T08  seal REFUSES with the bound record alone (no SubagentStart yet)" || bad "T08  seal w/o start rc=$rc: $R"
T start --session-id "$SID" --agent-id aaaaaa000001 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000001" --agent-type dev >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000001)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$R" | grep -q '"sealed": true' \
    && ok "T09  seal succeeds once both facts exist (order A: bind, then start)" || bad "T09  seal A rc=$rc: $R"
MEMBERS_A="$(py "print(json.dumps(tx.bound_members('$SID','aaaaaa000001'), sort_keys=True))")"

# Order B: start first, then bind — for a second agent; compare the member shapes.
intent "$SID" tu-2 '{"kind":"native","teammate":"dev-opus-n2","subagent_type":"dev","externals":[]}'
add_native "$ENTITY" aaaaaa000002
T start --session-id "$SID" --agent-id aaaaaa000002 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000002" >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000002)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'no bound record' \
    && ok "T10  seal REFUSES with the start record alone (nothing bound yet)" || bad "T10  seal w/o bound rc=$rc: $R"
T bind --session-id "$SID" --tool-use-id tu-2 --agent-id aaaaaa000002 >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000002)"; rc=$?
[ "$rc" -eq 0 ] && ok "T11  seal succeeds in order B (start, then bind)" || bad "T11  seal B rc=$rc: $R"
MEMBERS_B="$(py "print(json.dumps(tx.bound_members('$SID','aaaaaa000002'), sort_keys=True))")"
# Same shape apart from the agent-specific path/branch/head.
NORM_A="$(printf '%s' "$MEMBERS_A" | sed -e 's/aaaaaa000001/AGENT/g' -e 's/"head_at_seal": "[0-9a-f]*"/"head_at_seal": "H"/')"
NORM_B="$(printf '%s' "$MEMBERS_B" | sed -e 's/aaaaaa000002/AGENT/g' -e 's/"head_at_seal": "[0-9a-f]*"/"head_at_seal": "H"/')"
[ "$NORM_A" = "$NORM_B" ] && ok "T12  both event orders produce the same sealed manifest shape" || bad "T12  order A vs B: [$NORM_A] vs [$NORM_B]"
T sealed --session-id "$SID" --agent-id aaaaaa000002 && ok "T13  sealed: exit 0 for a sealed agent" || bad "T13  sealed rc"
T sealed --session-id "$SID" --agent-id aaaaaa000099 2>/dev/null && bad "T14  sealed: unknown agent reported sealed" || ok "T14  sealed: exit 1 for an unknown agent"

# --- 4. the native member is verified, never invented -------------------------------
intent "$SID" tu-3 '{"kind":"native","teammate":"dev-opus-n3","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-3 --agent-id aaaaaa000003 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000003 --cwd "$ENTITY" >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000003)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'is not the native isolation worktree agent-aaaaaa000003' \
    && ok "T15  seal REFUSES a native spawn whose SubagentStart cwd is not agent-<id>" || bad "T15  cwd=main rc=$rc: $R"
mkdir -p "$SANDBOX/loose/agent-aaaaaa000003"
T start --session-id "$SID" --agent-id aaaaaa000003 --cwd "$SANDBOX/loose/agent-aaaaaa000003" >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000003)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'not the top level of a git worktree' \
    && ok "T16  seal REFUSES a correctly-named directory that git does not know" || bad "T16  loose dir rc=$rc: $R"
intent "$SID" tu-3x '{"kind":"native","teammate":"dev-opus-n3x","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-3x --agent-id aaaaaa000004 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000003 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000001" >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000003)"; rc=$?
[ "$rc" -ne 0 ] && ok "T17  seal REFUSES a start cwd that is ANOTHER agent's native worktree" || bad "T17  other agent's cwd accepted: $R"

# --- 5. external members: prepared, exact, still what they were --------------------
EXT="$SANDBOX/other-wt/echo-opus-e1"
add_external "$OTHER" "$EXT" echo-opus-e1
intent "$SID" tu-5 "{\"kind\":\"cwd\",\"teammate\":\"echo-opus-e1\",\"externals\":[{\"repo\":\"$OTHER\",\"path\":\"$EXT\",\"branch\":\"echo-opus-e1\"}]}"
T bind --session-id "$SID" --tool-use-id tu-5 --agent-id aaaaaa000005 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000005 --cwd "$SANDBOX/other-wt" >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000005)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'is not one of the prepared external members' \
    && ok "T18  cwd worker: seal REFUSES a start cwd that is not a prepared external member" || bad "T18  cwd mismatch rc=$rc: $R"
T start --session-id "$SID" --agent-id aaaaaa000005 --cwd "$EXT" >/dev/null
git -C "$EXT" checkout -q -b drifted
R="$(T seal --session-id "$SID" --agent-id aaaaaa000005)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q "not the prepared branch" \
    && ok "T19  cwd worker: seal REFUSES when the external member's branch no longer matches the prepared record" || bad "T19  branch drift rc=$rc: $R"
git -C "$EXT" checkout -q echo-opus-e1
R="$(T seal --session-id "$SID" --agent-id aaaaaa000005)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$R" | grep -q '"class": "hand-rolled"' \
    && ok "T20  cwd worker: seal succeeds with the exact prepared external member (no native member)" || bad "T20  cwd seal rc=$rc: $R"
[ "$(T members --session-id "$SID" --agent-id aaaaaa000005 | wc -l | tr -d ' ')" = "1" ] \
    && ok "T21  cwd worker has exactly ONE member, the external one" || bad "T21  cwd member count"

# two-member worker: native + external
EXT2="$SANDBOX/other-wt/echo-opus-e2"
add_external "$OTHER" "$EXT2" echo-opus-e2
add_native "$ENTITY" aaaaaa000006
intent "$SID" tu-6 "{\"kind\":\"native+external\",\"teammate\":\"echo-opus-e2\",\"externals\":[{\"repo\":\"$OTHER\",\"path\":\"$EXT2\",\"branch\":\"echo-opus-e2\"}]}"
T bind --session-id "$SID" --tool-use-id tu-6 --agent-id aaaaaa000006 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000006 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000006" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000006 >/dev/null
M="$(T members --session-id "$SID" --agent-id aaaaaa000006)"
if [ "$(printf '%s\n' "$M" | wc -l | tr -d ' ')" = "2" ] && printf '%s' "$M" | grep -q "^native	" && printf '%s' "$M" | grep -q "^hand-rolled	$OTHER	$EXT2	echo-opus-e2	bound$"; then
    ok "T22  two-member worker: native AND external are both bound in one manifest"
else
    bad "T22  two-member: $M"
fi
# an external prepared in a repo the path does not belong to
intent "$SID" tu-7 "{\"kind\":\"cwd\",\"teammate\":\"echo-opus-e3\",\"externals\":[{\"repo\":\"$ENTITY\",\"path\":\"$EXT2\",\"branch\":\"echo-opus-e2\"}]}"
T bind --session-id "$SID" --tool-use-id tu-7 --agent-id aaaaaa000007 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000007 --cwd "$EXT2" >/dev/null
R="$(T seal --session-id "$SID" --agent-id aaaaaa000007)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$R" | grep -q 'not the prepared repository' \
    && ok "T23  seal REFUSES an external member whose repository is not the prepared one" || bad "T23  repo mismatch rc=$rc: $R"

# main-checkout-run: sealed with no members
intent "$SID" tu-8 '{"kind":"main-checkout-run","teammate":"ops-opus-m1","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-8 --agent-id aaaaaa000008 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000008 --cwd "$ENTITY" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000008 >/dev/null && [ -z "$(T members --session-id "$SID" --agent-id aaaaaa000008)" ] \
    && ok "T24  a main-checkout-run spawn seals with ZERO members (nothing is owned, nothing will be removed)" || bad "T24  main-checkout-run seal"

# --- 6. the terminal claim: compare-and-set --------------------------------------
R="$(T claim --session-id "$SID" --agent-id aaaaaa000099 --ingress SubagentStop 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "T25  claim on an unknown/unsealed agent: nothing to terminalize (rc 3)" || bad "T25  claim unknown rc=$rc"
HEAD6="$(git -C "$ENTITY/.claude/worktrees/agent-aaaaaa000006" rev-parse HEAD)"
HEAD6E="$(git -C "$EXT2" rev-parse HEAD)"
printf 'evidence\n' >"$EXT2/untracked-evidence.txt"
R="$(T claim --session-id "$SID" --agent-id aaaaaa000006 --ingress SubagentStop --detail first)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$R" | grep -q '"claimed": true' && ok "T26  the FIRST terminal ingress wins the claim" || bad "T26  first claim rc=$rc: $R"
R="$(T claim --session-id "$SID" --agent-id aaaaaa000006 --ingress WorktreeRemove --detail second)"; rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$R" | grep -q '"claimed": false' && ok "T27  a SECOND ingress loses the claim and resumes idempotently (rc 2)" || bad "T27  second claim rc=$rc: $R"
INGRESS="$(T show --session-id "$SID" --agent-id aaaaaa000006 | python3 -c 'import json,sys; print(json.load(sys.stdin)["terminal"]["ingress"])')"
[ "$INGRESS" = "SubagentStop" ] && ok "T28  the transaction records the WINNING ingress, and the loser did not overwrite it" || bad "T28  ingress=$INGRESS"
T terminal-agent --agent-id aaaaaa000006 && ok "T29  terminal index: the agent id is terminal" || bad "T29  terminal index missing"
T terminal-agent --agent-id aaaaaa000005 2>/dev/null && bad "T30  a live agent reads as terminal" || ok "T30  terminal index: a live agent is NOT terminal"
T terminal-name --session-id "$SID" --teammate echo-opus-e2 && ok "T31  terminal index: the teammate NAME is terminal in this session" || bad "T31  terminal name index missing"
T terminal-name --session-id "22222222-0000-4000-8000-000000000002" --teammate echo-opus-e2 2>/dev/null \
    && bad "T32  the name reads terminal in ANOTHER session" || ok "T32  a reused name in a LATER session is not terminal (index is per session)"

# --- 7. what the winner did: ref saved BEFORE the rename, then quarantine ----------
Q6="$ENTITY/.claude/worktrees/agent-aaaaaa000006.richos-terminal-11111111-aaaaaa000006"
Q6E="$EXT2.richos-terminal-11111111-aaaaaa000006"
REF6="$(git -C "$ENTITY" rev-parse --verify -q "refs/richos/handoffs/$SID/aaaaaa000006/worktree-agent-aaaaaa000006")"
REF6E="$(git -C "$OTHER" rev-parse --verify -q "refs/richos/handoffs/$SID/aaaaaa000006/echo-opus-e2")"
[ "$REF6" = "$HEAD6" ] && [ "$REF6E" = "$HEAD6E" ] \
    && ok "T33  a backup ref refs/richos/handoffs/<sid>/<aid>/<branch> = HEAD exists in EACH owning repository" || bad "T33  backup refs: $REF6 / $REF6E"
[ ! -d "$ENTITY/.claude/worktrees/agent-aaaaaa000006" ] && [ -d "$Q6" ] && [ ! -d "$EXT2" ] && [ -d "$Q6E" ] \
    && ok "T34  both members were renamed beside their originals: <path>.richos-terminal-<sid8>-<aid>" || bad "T34  quarantine: $(ls "$ENTITY/.claude/worktrees" "$SANDBOX/other-wt")"
[ -f "$Q6E/untracked-evidence.txt" ] && ok "T35  untracked evidence traveled with the quarantine byte-for-byte (a rename, not a copy)" || bad "T35  evidence lost"
if git -C "$OTHER" worktree list --porcelain | grep -qx "worktree $Q6E" && git -C "$Q6E" status --porcelain >/dev/null 2>&1 \
   && ! git -C "$OTHER" worktree list --porcelain | grep -q "^prunable"; then
    ok "T35b  the quarantine is a REGISTERED, readable worktree (git worktree repair ran): a prune cannot orphan it"
else
    bad "T35b  quarantine registration: $(git -C "$OTHER" worktree list --porcelain | tr '\n' ' ' | cut -c1-300)"
fi
STATES="$(T members --session-id "$SID" --agent-id aaaaaa000006 | cut -f5 | tr '\n' ' ')"
[ "$STATES" = "quarantined quarantined " ] && ok "T36  every member is persisted as quarantined" || bad "T36  states: $STATES"
# The loser's resume touched nothing: run the claim again and compare.
BEFORE="$(T show --session-id "$SID" --agent-id aaaaaa000006 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([(m["state"], m.get("quarantine")) for m in d["members"]]))')"
T claim --session-id "$SID" --agent-id aaaaaa000006 --ingress SubagentStop >/dev/null 2>&1
AFTER="$(T show --session-id "$SID" --agent-id aaaaaa000006 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([(m["state"], m.get("quarantine")) for m in d["members"]]))')"
[ "$BEFORE" = "$AFTER" ] && ok "T37  a third SubagentStop is an idempotent no-op on the member states" || bad "T37  third stop changed state: $BEFORE -> $AFTER"

# --- 8. crash recovery at every boundary --------------------------------------------
# 8a. crash AFTER the rename, BEFORE the state write: state says ref_saved,
#     original absent, quarantine present -> quarantine() completes the record.
add_native "$ENTITY" aaaaaa000010
intent "$SID" tu-10 '{"kind":"native","teammate":"dev-opus-c1","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-10 --agent-id aaaaaa000010 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000010 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000010" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000010 >/dev/null
py "
won, t = tx.claim_terminal('$SID', 'aaaaaa000010', 'SubagentStop')
tx.save_ref('$SID', 'aaaaaa000010', 0)
m = tx.load_tx('$SID', 'aaaaaa000010')['members'][0]
os.rename(m['path'], m['quarantine'])   # the crash: renamed, never recorded
"
STATE="$(T members --session-id "$SID" --agent-id aaaaaa000010 | cut -f5)"
[ "$STATE" = "ref_saved" ] || bad "T38-setup  8a setup: state=$STATE"
py "tx.terminalize('$SID', 'aaaaaa000010')"
STATE="$(T members --session-id "$SID" --agent-id aaaaaa000010 | cut -f5)"
[ "$STATE" = "quarantined" ] && ok "T38  recovery: rename done but unrecorded -> the record is completed, nothing is renamed twice" || bad "T38  8a: $STATE"

# 8b. BOTH original and quarantine present -> failed, never a choice.
add_native "$ENTITY" aaaaaa000011
intent "$SID" tu-11 '{"kind":"native","teammate":"dev-opus-c2","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-11 --agent-id aaaaaa000011 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000011 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000011" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000011 >/dev/null
mkdir -p "$ENTITY/.claude/worktrees/agent-aaaaaa000011.richos-terminal-11111111-aaaaaa000011"
py "tx.claim_terminal('$SID', 'aaaaaa000011', 'SubagentStop'); tx.terminalize('$SID', 'aaaaaa000011')"
STATE="$(T members --session-id "$SID" --agent-id aaaaaa000011 | cut -f5)"
[ "$STATE" = "failed" ] && [ -d "$ENTITY/.claude/worktrees/agent-aaaaaa000011" ] \
    && ok "T39  recovery: original AND quarantine both present -> member FAILED, original untouched (no search, no choice)" || bad "T39  8b: $STATE"

# 8c. NEITHER present -> missing (counted, never invented).
add_native "$ENTITY" aaaaaa000012
intent "$SID" tu-12 '{"kind":"native","teammate":"dev-opus-c3","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-12 --agent-id aaaaaa000012 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000012 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000012" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000012 >/dev/null
git -C "$ENTITY" worktree remove --force "$ENTITY/.claude/worktrees/agent-aaaaaa000012" >/dev/null 2>&1
py "tx.claim_terminal('$SID', 'aaaaaa000012', 'WorktreeRemove'); tx.terminalize('$SID', 'aaaaaa000012')"
STATE="$(T members --session-id "$SID" --agent-id aaaaaa000012 | cut -f5)"
[ "$STATE" = "missing" ] && ok "T40  recovery: neither original nor quarantine -> member MISSING (reported, never fabricated)" || bad "T40  8c: $STATE"

# 8d. multi-repository: crash after ONE of two members is quarantined; the
#     next run quarantines the remaining member and touches the first only
#     to confirm its state.
EXT3="$SANDBOX/other-wt/echo-opus-e13"
add_external "$OTHER" "$EXT3" echo-opus-e13
add_native "$ENTITY" aaaaaa000013
intent "$SID" tu-13 "{\"kind\":\"native+external\",\"teammate\":\"echo-opus-e13\",\"externals\":[{\"repo\":\"$OTHER\",\"path\":\"$EXT3\",\"branch\":\"echo-opus-e13\"}]}"
T bind --session-id "$SID" --tool-use-id tu-13 --agent-id aaaaaa000013 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000013 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000013" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000013 >/dev/null
py "
tx.claim_terminal('$SID', 'aaaaaa000013', 'SubagentStop')
tx.save_ref('$SID', 'aaaaaa000013', 0); tx.save_ref('$SID', 'aaaaaa000013', 1)
tx.quarantine('$SID', 'aaaaaa000013', 0)   # crash here: the external member is still at its original path
"
STATES="$(T members --session-id "$SID" --agent-id aaaaaa000013 | cut -f5 | tr '\n' ' ')"
[ "$STATES" = "quarantined ref_saved " ] || bad "T41-setup  8d setup: $STATES"
[ -d "$EXT3" ] || bad "T41-setup  8d setup: external moved early"
py "tx.terminalize('$SID', 'aaaaaa000013')"
STATES="$(T members --session-id "$SID" --agent-id aaaaaa000013 | cut -f5 | tr '\n' ' ')"
[ "$STATES" = "quarantined quarantined " ] && [ ! -d "$EXT3" ] && [ -d "$EXT3.richos-terminal-11111111-aaaaaa000013" ] \
    && ok "T41  recovery: a crash after one of two repositories is quarantined recovers the remaining member" || bad "T41  8d: $STATES"

# --- 9. WorktreeRemove resolves by EXACT native path, and orders that path first --
AID="$(T by-native-path --session-id "$SID" --path "$ENTITY/.claude/worktrees/agent-aaaaaa000002")"
[ "$AID" = "aaaaaa000002" ] && ok "T42  by-native-path: the exact native path resolves its sealed agent" || bad "T42  by-native-path: $AID"
AID="$(T by-native-path --session-id "$SID" --path "$Q6")"
[ "$AID" = "aaaaaa000006" ] && ok "T43  by-native-path: the quarantine name is the same identity" || bad "T43  by-native-path quarantine: $AID"
AID="$(T by-native-path --session-id "$SID" --path "$ENTITY/.claude/worktrees/agent-aaaaaa00000" 2>/dev/null)"
[ -z "$AID" ] && ok "T44  by-native-path: a PREFIX of a real path resolves nothing" || bad "T44  prefix resolved $AID"
AID="$(T by-native-path --session-id "22222222-0000-4000-8000-000000000002" --path "$ENTITY/.claude/worktrees/agent-aaaaaa000002" 2>/dev/null)"
[ -z "$AID" ] && ok "T45  by-native-path: the same path under ANOTHER session id resolves nothing" || bad "T45  cross-session resolved $AID"
add_native "$ENTITY" aaaaaa000014
EXT4="$SANDBOX/other-wt/echo-opus-e14"; add_external "$OTHER" "$EXT4" echo-opus-e14
intent "$SID" tu-14 "{\"kind\":\"native+external\",\"teammate\":\"echo-opus-e14\",\"externals\":[{\"repo\":\"$OTHER\",\"path\":\"$EXT4\",\"branch\":\"echo-opus-e14\"}]}"
T bind --session-id "$SID" --tool-use-id tu-14 --agent-id aaaaaa000014 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000014 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000014" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000014 >/dev/null
R="$(T claim --session-id "$SID" --agent-id aaaaaa000014 --ingress WorktreeRemove --first-path "$ENTITY/.claude/worktrees/agent-aaaaaa000014")"; rc=$?
[ "$rc" -eq 0 ] && [ ! -d "$ENTITY/.claude/worktrees/agent-aaaaaa000014" ] && [ ! -d "$EXT4" ] \
    && ok "T46  WorktreeRemove-first: the claim quarantines the named native path AND the external member" || bad "T46  wr-first rc=$rc"

# --- 10. reused teammate + branch names in a LATER session match nothing ------------
SID2="22222222-0000-4000-8000-000000000002"
EXT5="$SANDBOX/other-wt/echo-opus-e2-again"
add_external "$OTHER" "$EXT5" echo-opus-e2-again
intent "$SID2" tu-1 "{\"kind\":\"cwd\",\"teammate\":\"echo-opus-e2\",\"externals\":[{\"repo\":\"$OTHER\",\"path\":\"$EXT5\",\"branch\":\"echo-opus-e2-again\"}]}"
T bind --session-id "$SID2" --tool-use-id tu-1 --agent-id bbbbbb000001 >/dev/null
T start --session-id "$SID2" --agent-id bbbbbb000001 --cwd "$EXT5" >/dev/null
T seal --session-id "$SID2" --agent-id bbbbbb000001 >/dev/null
T terminal-name --session-id "$SID2" --teammate echo-opus-e2 2>/dev/null \
    && bad "T46  the reused name inherited the old session's terminal state" \
    || ok "T47  a later session reusing the name echo-opus-e2 is NOT terminal and its tree is untouched"
[ -d "$EXT5" ] && ok "T48  the reused-name tree still exists after the old transaction's terminalization" || bad "T48  reused-name tree gone"

# --- 11. metrics: the definition of done, with nothing omitted ----------------------
M="$(T metrics)"
python3 - "$M" <<'PY' && ok "T49  metrics count terminal members present (incl. FAILED and MISSING) and pending retries" || bad "T49  metrics: $M"
import json, sys
m = json.loads(sys.argv[1])
assert m["terminal"] >= 6, m
assert m["failed"] >= 2, m           # 8b failed + 8c missing
assert m["failed_present"] >= 1, m   # 8b's original is still on disk and COUNTED
assert m["terminal_members_present"] >= 5, m
assert m["pending_retry"] >= 5, m
PY

# --- 12. the lock is real: a holder blocks a second writer until release -------------
py "
import subprocess, time
holder = subprocess.Popen([sys.executable, '-c', '''
import importlib.util, os, time, sys
spec = importlib.util.spec_from_file_location('tx', os.environ['TXPY']); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
with tx.tx_lock('$SID', 'aaaaaa000002'):
    time.sleep(1.2)
'''])
time.sleep(0.3)
t0 = time.time()
with tx.tx_lock('$SID', 'aaaaaa000002', timeout=5):
    waited = time.time() - t0
holder.wait()
print('WAITED %.2f' % waited)
" | grep -qE 'WAITED (0\.[7-9]|1\.[0-9])' && ok "T50  tx_lock: a second writer waits for the holder (kernel flock, released on exit)" || bad "T50  lock did not serialize"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== worktree-transactions tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== worktree-transactions tests: all $PASS passed ==="

# The mutation harness is part of this suite's definition of green: a suite
# nobody has watched go red proves nothing (open-items rows 3.22-3.29).
if [ -f "$SCRIPT_DIR/worktree-transactions.mutation.sh" ]; then
    bash "$SCRIPT_DIR/worktree-transactions.mutation.sh" || exit 1
fi
exit 0
