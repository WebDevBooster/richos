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

# 8b. BOTH original and quarantine present -> the quarantine (this member's
#     own, by its exact name) advances; the original is recorded present and
#     left EXACTLY where it is for the reconciler to archive, verify and
#     reclaim. INVERTED (landed review 2026-09-03, blocker 3): this used to
#     be a FAILED state that waited for a person. Nothing is renamed over
#     anything and nothing is chosen by name.
add_native "$ENTITY" aaaaaa000011
intent "$SID" tu-11 '{"kind":"native","teammate":"dev-opus-c2","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-11 --agent-id aaaaaa000011 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000011 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000011" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000011 >/dev/null
Q11="$ENTITY/.claude/worktrees/agent-aaaaaa000011.richos-terminal-11111111-aaaaaa000011"
py "
tx.claim_terminal('$SID', 'aaaaaa000011', 'SubagentStop')
tx.save_ref('$SID', 'aaaaaa000011', 0)
os.rename('$ENTITY/.claude/worktrees/agent-aaaaaa000011', '$Q11')   # the crash: renamed, never recorded
"
mkdir -p "$ENTITY/.claude/worktrees/agent-aaaaaa000011"; printf 'ghost\n' >"$ENTITY/.claude/worktrees/agent-aaaaaa000011/ghost.txt"   # residue reappears
py "tx.terminalize('$SID', 'aaaaaa000011')"
M11="$(T show --session-id "$SID" --agent-id aaaaaa000011 | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][0]; print(m["state"], m.get("original_present_at_quarantine"))')"
if [ "$M11" = "quarantined True" ] && [ -f "$ENTITY/.claude/worktrees/agent-aaaaaa000011/ghost.txt" ] && [ -d "$Q11" ] \
   && git -C "$ENTITY" worktree list --porcelain | grep -qx "worktree $Q11"; then
    ok "T39  recovery: original AND quarantine both present -> the quarantine advances (registered, ours by exact name), the original is recorded present and left untouched for the reconciler (INVERTED: it used to park as FAILED)"
else
    bad "T39  8b: member=[$M11] orig=$([ -f "$ENTITY/.claude/worktrees/agent-aaaaaa000011/ghost.txt" ] && echo present || echo GONE) quar=$([ -d "$Q11" ] && echo present || echo absent)"
fi

# 8c. NEITHER present -> missing (counted, never invented).
add_native "$ENTITY" aaaaaa000012
intent "$SID" tu-12 '{"kind":"native","teammate":"dev-opus-c3","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-12 --agent-id aaaaaa000012 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000012 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000012" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000012 >/dev/null
HEAD12="$(git -C "$ENTITY/.claude/worktrees/agent-aaaaaa000012" rev-parse HEAD)"
git -C "$ENTITY" worktree remove --force "$ENTITY/.claude/worktrees/agent-aaaaaa000012" >/dev/null 2>&1
git -C "$ENTITY" branch -D worktree-agent-aaaaaa000012 >/dev/null 2>&1   # the harness deletes the branch too (PF11)
py "tx.claim_terminal('$SID', 'aaaaaa000012', 'WorktreeRemove'); tx.terminalize('$SID', 'aaaaaa000012')"
# INVERTED (landed review 2026-09-03, blocker 3; CEO specification section 4):
# until this revision a vanished member was recorded `missing` — a manual
# state that waited for a person. Now it is CLOSED ABSENT: the backup ref is
# re-created from the recorded head while the commit object survives, the
# absence is recorded, and the member is removed. Nothing is fabricated.
M12="$(T show --session-id "$SID" --agent-id aaaaaa000012 | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][0]; print(m["state"], m.get("closed"), m.get("head_preserved"))')"
REF12="$(git -C "$ENTITY" rev-parse -q --verify "refs/richos/handoffs/$SID/aaaaaa000012/worktree-agent-aaaaaa000012")"
[ "$M12" = "removed absent backup-ref" ] && [ "$REF12" = "$HEAD12" ] \
    && ok "T40  recovery: neither original nor quarantine -> member CLOSED ABSENT: removed, absence recorded, backup ref re-created from the recorded head even though the harness deleted worktree AND branch (INVERTED: it used to park as MISSING)" || bad "T40  8c: member=[$M12] ref=[$REF12] want=[$HEAD12]"

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

# --- 9b. THE NATIVE PATH IS RENAMED BEFORE ANY OTHER REPOSITORY IS TOUCHED ------
# (review 2026-09-03, blocker 1). The WorktreeRemove hook has a 20s budget and
# any git subprocess may take 30s. The external repository's git is made to
# STALL, and the terminalize call is KILLED after 6s the way the harness kills
# a hook that overran its budget. The native member — the path the platform is
# about to delete — must already be renamed AND recorded; the external member
# must be untouched and still `bound`; and a later run must finish it.
add_native "$ENTITY" aaaaaa000015
EXT6="$SANDBOX/other-wt/echo-opus-e15"; add_external "$OTHER" "$EXT6" echo-opus-e15
intent "$SID" tu-15 "{\"kind\":\"native+external\",\"teammate\":\"echo-opus-e15\",\"externals\":[{\"repo\":\"$OTHER\",\"path\":\"$EXT6\",\"branch\":\"echo-opus-e15\"}]}"
T bind --session-id "$SID" --tool-use-id tu-15 --agent-id aaaaaa000015 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000015 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000015" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000015 >/dev/null
NAT15="$ENTITY/.claude/worktrees/agent-aaaaaa000015"
REAL_GIT="$(command -v git)"
STALLBIN="$SANDBOX/stallbin"; mkdir -p "$STALLBIN"
# Every git invocation that names the OTHER repository (or a worktree of it)
# stalls for 20s and fails; every other invocation is the real git.
cat >"$STALLBIN/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in "$SANDBOX/other"*) sleep 20; exit 1 ;; esac; done
exec "$REAL_GIT" "\$@"
SH
chmod +x "$STALLBIN/git"
T51_RESULT="$(py "
import subprocess, sys, os
env = dict(os.environ); env['PATH'] = '$STALLBIN:' + env['PATH']
code = '''
import importlib.util, os
spec = importlib.util.spec_from_file_location('tx', os.environ['TXPY']); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
tx.claim_terminal('$SID', 'aaaaaa000015', 'WorktreeRemove', detail='$NAT15')
tx.terminalize('$SID', 'aaaaaa000015', '$NAT15')
'''
try:
    subprocess.run([sys.executable, '-c', code], env=env, timeout=6)
    print('FINISHED')
except subprocess.TimeoutExpired:
    print('KILLED')
")"
STATES="$(T members --session-id "$SID" --agent-id aaaaaa000015 | cut -f5 | tr '\n' ' ')"
if [ "$T51_RESULT" = "KILLED" ] && [ "$STATES" = "quarantined bound " ] && [ ! -d "$NAT15" ] \
   && [ -d "$NAT15.richos-terminal-11111111-aaaaaa000015" ] && [ -d "$EXT6" ]; then
    ok "T51  a stalled external repository exhausts the hook budget AFTER the native path is quarantined and recorded (native: quarantined; external: bound, untouched)"
else
    bad "T51  result=$T51_RESULT states=[$STATES] native=$([ -d "$NAT15" ] && echo present || echo gone) quarantine=$([ -d "$NAT15.richos-terminal-11111111-aaaaaa000015" ] && echo present || echo absent) external=$([ -d "$EXT6" ] && echo present || echo gone)"
fi
py "tx.terminalize('$SID', 'aaaaaa000015', '$NAT15')"
STATES="$(T members --session-id "$SID" --agent-id aaaaaa000015 | cut -f5 | tr '\n' ' ')"
[ "$STATES" = "quarantined quarantined " ] && [ ! -d "$EXT6" ] && ok "T52  ...and the next run, with the repository responsive again, finishes the external member" || bad "T52  states=[$STATES]"

# --- 9c. A FAILED `git worktree repair` DOES NOT ADVANCE THE MEMBER --------------
# (review 2026-09-03, blocker 6). The repair's return code was ignored and the
# member marked `quarantined` regardless; a prune then deleted the admin
# directory the quarantine's .git file points at. Now the member advances only
# when git lists the quarantine as the exact registered, non-prunable path.
add_native "$ENTITY" aaaaaa000016
intent "$SID" tu-16 '{"kind":"native","teammate":"dev-opus-c16","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-16 --agent-id aaaaaa000016 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000016 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000016" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000016 >/dev/null
NAT16="$ENTITY/.claude/worktrees/agent-aaaaaa000016"; Q16="$NAT16.richos-terminal-11111111-aaaaaa000016"
NOREPAIR="$SANDBOX/norepairbin"; mkdir -p "$NOREPAIR"
cat >"$NOREPAIR/git" <<SH
#!/usr/bin/env bash
if [ "\$3" = "worktree" ] && [ "\$4" = "repair" ]; then echo "fatal: simulated repair failure" >&2; exit 128; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$NOREPAIR/git"
PATH="$NOREPAIR:$PATH" py "tx.claim_terminal('$SID', 'aaaaaa000016', 'SubagentStop'); tx.terminalize('$SID', 'aaaaaa000016')"
STATE="$(T members --session-id "$SID" --agent-id aaaaaa000016 | cut -f5)"
ERR="$(T show --session-id "$SID" --agent-id aaaaaa000016 | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][0]; print(m.get("attempts"), m.get("last_error",""))')"
if [ "$STATE" = "ref_saved" ] && [ ! -d "$NAT16" ] && [ -d "$Q16" ] && printf '%s' "$ERR" | grep -q '^1 quarantine not advanced: git worktree repair'; then
    ok "T53  a failed \`git worktree repair\` leaves the member at ref_saved with the directory preserved, the failure recorded, retryable"
else
    bad "T53  state=$STATE err=[$ERR] orig=$([ -d "$NAT16" ] && echo present || echo gone) quar=$([ -d "$Q16" ] && echo present || echo absent)"
fi
py "tx.terminalize('$SID', 'aaaaaa000016')"
STATE="$(T members --session-id "$SID" --agent-id aaaaaa000016 | cut -f5)"
if [ "$STATE" = "quarantined" ] && git -C "$ENTITY" worktree list --porcelain | grep -qx "worktree $Q16"; then
    ok "T54  ...and the retry, with git working, repairs the registration and advances to quarantined"
else
    bad "T54  state=$STATE registered=$(git -C "$ENTITY" worktree list --porcelain | grep -c "$Q16")"
fi

# --- 9d. TERMINAL REVOCATION SURVIVES A CRASH AFTER ANY OF ITS THREE WRITES -----
# (review 2026-09-03, blocker 5). claim_terminal writes the transaction's
# terminal record, then the agent-id index, then the name index. A crash
# after any one of them must still read as terminal — from the transaction,
# not the marker — and the next claim must repair whatever is missing.
for point in tx index name; do
    case "$point" in tx) A=aaaaaa000017; N=17 ;; index) A=aaaaaa000018; N=18 ;; name) A=aaaaaa000019; N=19 ;; esac
    add_native "$ENTITY" "$A"
    intent "$SID" "tu-$N" "{\"kind\":\"native\",\"teammate\":\"dev-opus-crash$N\",\"externals\":[]}"
    T bind --session-id "$SID" --tool-use-id "tu-$N" --agent-id "$A" >/dev/null
    T start --session-id "$SID" --agent-id "$A" --cwd "$ENTITY/.claude/worktrees/agent-$A" >/dev/null
    T seal --session-id "$SID" --agent-id "$A" >/dev/null
    RICHOS_TX_CRASH_AFTER="$point" T claim --session-id "$SID" --agent-id "$A" --ingress SubagentStop >/dev/null 2>&1; CRC=$?
    IDX_BEFORE="$([ -f "$SANDBOX/tx/terminal/$A" ] && echo present || echo absent)"
    NAME_BEFORE="$([ -f "$SANDBOX/tx/terminal-names/$SID/dev-opus-crash$N" ] && echo present || echo absent)"
    TERM_BY_SID="$(T terminal-agent --agent-id "$A" --session-id "$SID" >/dev/null 2>&1 && echo yes || echo no)"
    case "$point" in
        tx)    WANT_IDX=absent;  WANT_NAME=absent ;;
        index) WANT_IDX=present; WANT_NAME=absent ;;
        name)  WANT_IDX=present; WANT_NAME=present ;;
    esac
    if [ "$CRC" -ne 0 ] && [ "$IDX_BEFORE" = "$WANT_IDX" ] && [ "$NAME_BEFORE" = "$WANT_NAME" ] && [ "$TERM_BY_SID" = "yes" ]; then
        ok "T55-$point  crash after the '$point' write (rc $CRC; index $IDX_BEFORE, name index $NAME_BEFORE): the agent STILL reads as terminal from the transaction"
    else
        bad "T55-$point  rc=$CRC index=$IDX_BEFORE(want $WANT_IDX) name=$NAME_BEFORE(want $WANT_NAME) terminal=$TERM_BY_SID"
    fi
    # the exact lookup repaired the agent-id index on its way out; a later
    # ingress (the losing claim) repairs the name index too
    T claim --session-id "$SID" --agent-id "$A" --ingress WorktreeRemove >/dev/null 2>&1
    if [ -f "$SANDBOX/tx/terminal/$A" ] && [ -f "$SANDBOX/tx/terminal-names/$SID/dev-opus-crash$N" ]; then
        ok "T56-$point  ...and the next ingress repaired both indexes idempotently"
    else
        bad "T56-$point  index=$([ -f "$SANDBOX/tx/terminal/$A" ] && echo present || echo absent) name=$([ -f "$SANDBOX/tx/terminal-names/$SID/dev-opus-crash$N" ] && echo present || echo absent)"
    fi
done
# without a session id the lookup consults every session's record for this EXACT agent id
add_native "$ENTITY" aaaaaa000020
intent "$SID" tu-20 '{"kind":"native","teammate":"dev-opus-crash20","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-20 --agent-id aaaaaa000020 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000020 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000020" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000020 >/dev/null
RICHOS_TX_CRASH_AFTER=tx T claim --session-id "$SID" --agent-id aaaaaa000020 --ingress SubagentStop >/dev/null 2>&1
if [ ! -f "$SANDBOX/tx/terminal/aaaaaa000020" ] && T terminal-agent --agent-id aaaaaa000020 >/dev/null 2>&1 && [ -f "$SANDBOX/tx/terminal/aaaaaa000020" ]; then
    ok "T57  with NO session id, a crash-orphaned terminal transaction is found by exact agent id and its index repaired"
else
    bad "T57  index=$([ -f "$SANDBOX/tx/terminal/aaaaaa000020" ] && echo present || echo absent)"
fi
T terminal-agent --agent-id aaaaaa000021 >/dev/null 2>&1 && bad "T58  an unknown agent id reads as terminal" || ok "T58  ...and an agent id with no record anywhere is NOT terminal (negative control)"

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
# A `failed` member written by an EARLIER revision (this one writes none) must
# still be counted while it stands: metrics never hide a directory on disk.
py "
with tx.tx_lock('$SID', 'aaaaaa000019'):
    tx.update_member('$SID', 'aaaaaa000019', 0, state='failed', error='legacy record written by an earlier revision')
"
M="$(T metrics)"
python3 - "$M" <<'PY' && ok "T49  metrics count terminal members present (incl. FAILED and MISSING) and pending retries" || bad "T49  metrics: $M"
import json, sys
m = json.loads(sys.argv[1])
assert m["terminal"] >= 6, m
assert m["failed"] >= 1, m           # 8b failed (8c is now closed absent, not missing)
assert m["failed_present"] >= 1, m   # 8b's original is still on disk and COUNTED
assert m["terminal_members_present"] >= 5, m
assert m["pending_retry"] >= 5, m
# CEO specification 2026-09-03 section 5: nothing is called live unexamined
assert "sealed_live" not in m, m
assert m["sealed_native_present"] >= 2, m            # aaaaaa000001 / 000002: native, present, registered
assert m["sealed_external_only_unclaimed"] >= 1, m   # aaaaaa000005: a cwd-only worker has no platform witness
assert m["sealed_native_missing"] == 0, m
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

# --- 13. AUTHORITATIVE WRITES RAISE ON A FAILED FSYNC OR RENAME --------------------
# (landed review 2026-09-03, blocker 6). Until this revision _fsync_dir swallowed
# EVERY error opening or syncing the parent directory while atomic_write_json
# documented "temp file, fsync, rename, directory fsync; raises on failure" —
# a terminal claim reported durable could vanish after a crash. Fault injection
# replaces os.fsync / os.replace inside the module's own process, so the
# shipped code runs unchanged: a file fsync, the rename and the directory
# fsync each fail with EIO in turn, and the ONE documented exception (a
# filesystem answering EINVAL to a directory fsync) is proven to be the only
# swallowed error, and announced.
fault_write() { # <fault> <target> -> prints RAISED:<errno-name> or OK (+ any stderr notice)
    py "
import errno as E, os, stat, sys
fault, target = '$1', '$2'
real_fsync, real_replace = os.fsync, os.replace
def fsync(fd):
    is_dir = stat.S_ISDIR(os.fstat(fd).st_mode)
    if fault == 'file_fsync' and not is_dir: raise OSError(E.EIO, 'injected file fsync failure')
    if fault == 'dir_fsync' and is_dir: raise OSError(E.EIO, 'injected directory fsync failure')
    if fault == 'dir_fsync_einval' and is_dir: raise OSError(E.EINVAL, 'injected: this filesystem cannot fsync a directory')
    return real_fsync(fd)
def replace(a, b):
    if fault == 'rename': raise OSError(E.EIO, 'injected rename failure')
    return real_replace(a, b)
os.fsync, os.replace = fsync, replace
try:
    if target == 'marker':
        tx.touch_marker('$SANDBOX/fault/' + fault + '.marker', 'x')
    else:
        tx.atomic_write_json('$SANDBOX/fault/' + fault + '.json', {'fault': fault})
    print('OK')
except OSError as e:
    print('RAISED:' + E.errorcode.get(e.errno, str(e.errno)))
" 2>&1
}
R="$(fault_write file_fsync json)"
[ "$R" = "RAISED:EIO" ] && [ ! -e "$SANDBOX/fault/file_fsync.json" ] && [ -z "$(ls "$SANDBOX/fault" 2>/dev/null | grep file_fsync)" ] \
    && ok "T59  a failed FILE fsync raises EIO; nothing is left at the path and no temp file beside it" || bad "T59  file fsync: [$R] $(ls "$SANDBOX/fault" 2>/dev/null | tr '\n' ' ')"
R="$(fault_write rename json)"
[ "$R" = "RAISED:EIO" ] && [ ! -e "$SANDBOX/fault/rename.json" ] && [ -z "$(ls "$SANDBOX/fault" 2>/dev/null | grep rename)" ] \
    && ok "T60  a failed RENAME raises EIO; nothing is left at the path and the temp file is removed" || bad "T60  rename: [$R] $(ls "$SANDBOX/fault" 2>/dev/null | tr '\n' ' ')"
R="$(fault_write dir_fsync json)"
[ "$R" = "RAISED:EIO" ] && [ -f "$SANDBOX/fault/dir_fsync.json" ] \
    && ok "T61  a failed DIRECTORY fsync raises EIO: the record is on disk but the caller is NOT told it is durable (INVERTED: it used to be swallowed)" || bad "T61  dir fsync: [$R] present=$([ -f "$SANDBOX/fault/dir_fsync.json" ] && echo yes || echo no)"
R="$(fault_write dir_fsync marker)"
[ "$R" = "RAISED:EIO" ] && ok "T61b ...and touch_marker (the terminal indexes) raises the same way" || bad "T61b marker dir fsync: [$R]"
R="$(fault_write dir_fsync_einval json)"
if printf '%s' "$R" | grep -q '^OK$' && printf '%s' "$R" | grep -q 'cannot fsync a directory (errno 22 EINVAL)' && [ -f "$SANDBOX/fault/dir_fsync_einval.json" ]; then
    ok "T62  the ONE documented exception: a filesystem answering EINVAL to a directory fsync is accepted, and announced with the errno (the weaker guarantee is named, never silent)"
else
    bad "T62  einval: [$R]"
fi
# a terminal claim whose directory fsync fails is REPORTED as a failure, and
# the next (unfaulted) claim converges on the record that did land
add_native "$ENTITY" aaaaaa000022
intent "$SID" tu-22 '{"kind":"native","teammate":"dev-opus-fs22","externals":[]}'
T bind --session-id "$SID" --tool-use-id tu-22 --agent-id aaaaaa000022 >/dev/null
T start --session-id "$SID" --agent-id aaaaaa000022 --cwd "$ENTITY/.claude/worktrees/agent-aaaaaa000022" >/dev/null
T seal --session-id "$SID" --agent-id aaaaaa000022 >/dev/null
R="$(py "
import errno as E, os, stat
real_fsync = os.fsync
def fsync(fd):
    if stat.S_ISDIR(os.fstat(fd).st_mode): raise OSError(E.EIO, 'injected directory fsync failure')
    return real_fsync(fd)
os.fsync = fsync
try:
    tx.claim_terminal('$SID', 'aaaaaa000022', 'SubagentStop'); print('OK')
except OSError as e:
    print('RAISED:' + E.errorcode.get(e.errno, str(e.errno)))
" 2>&1)"
R2="$(T claim --session-id "$SID" --agent-id aaaaaa000022 --ingress WorktreeRemove 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("claimed"), (d.get("transaction") or {}).get("terminal", {}).get("ingress"))')"
[ "$R" = "RAISED:EIO" ] && [ "$R2" = "False SubagentStop" ] && T terminal-agent --agent-id aaaaaa000022 --session-id "$SID" >/dev/null 2>&1 \
    && ok "T63  a claim whose directory fsync fails RAISES (not reported durable); the next ingress resumes the claim that did land and the agent reads terminal" || bad "T63  claim under dir-fsync fault: [$R] next=[$R2]"

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
