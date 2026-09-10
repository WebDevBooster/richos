#!/usr/bin/env bash
#
# finish-row-completion.test.sh — a finish row names the WHOLE assignment and
# knows who it was, whichever of the three hooks writes it.
#
# ===========================================================================
# THE DEFECT, MEASURED 2026-09-10 over 15,728 finish rows in the real ledger
# ===========================================================================
#   finished rows naming a CROSS-REPOSITORY (`<repo>-wt/`) workspace :      0
#   finished rows naming a NATIVE worktree                           : 10,749
#   finished rows with a BLANK teammate                              : 15,728
#
# Both follow from the payload. `cwd` is the agent's native isolation
# worktree, which is where a worker runs, and SubagentStop carries none of the
# name keys the hooks look for. So an assignment holding four folders was
# recorded as holding one, and the one field that could have joined it to the
# other three -- the teammate name the cross-repo folders are named after --
# was blank on every row ever written.
#
# The entry side always had it: 65 agents had folders registered at spawn that
# day and 61 had MORE THAN ONE. So the fix RESOLVES rather than guesses, and it
# lives in ONE place -- worktree-ledger.append() completes the row itself, so
# all three writers get it and none of them gains a line.
#
# WHAT THIS IS NOT. The row is advisory and stays advisory: `judge()` prints
# finish signals as "advisory, never decisive", and adoption quotes T3 without
# authorizing. Reclamation is anchored on the transaction's terminal record,
# which the same event writes about every member -- zach-opus-dor1 has ZERO
# finish rows of any kind and its transaction is sealed, terminal and carrying
# all four of its workspaces. F5 is that boundary, asserted.
#
# Run directly: scripts/lib/finish-row-completion.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../hooks"
LEDGER_PY="$SCRIPT_DIR/worktree-ledger.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t finish-row-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
[ -f "$LEDGER_PY" ] || { echo "FATAL: missing $LEDGER_PY" >&2; exit 1; }

export RICHOS_WORKTREE_LEDGER="$SANDBOX/ledger.jsonl"
export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
SID="feedbeef-0000-4000-8000-000000000001"

seal_tx() { # <agent-id> <teammate>
    mkdir -p "$RICHOS_WORKTREE_TX_DIR/$SID"
    python3 - "$RICHOS_WORKTREE_TX_DIR/$SID/$1.json" "$SID" "$1" "$2" "$SANDBOX" <<'PY'
import json, sys
path, sid, aid, teammate, sandbox = sys.argv[1:6]
json.dump({"record": "transaction", "session_id": sid, "agent_id": aid, "teammate": teammate,
           "sealed": True, "state": "sealed", "members": [
               {"class": "native", "cleanup_owner": "claude-code",
                "path": sandbox + "/entity/.claude/worktrees/agent-" + aid},
               {"class": "hand-rolled", "path": sandbox + "/richos-wt/" + teammate},
               {"class": "hand-rolled", "path": sandbox + "/deeply-wt/" + teammate}]},
          open(path, "w"))
PY
}

fire() { # <hook-basename> <event-name> <agent-id> [extra-json]
    local hook="$1" event="$2" aid="$3" extra="${4:-}"
    printf '{"session_id":"%s","hook_event_name":"%s","agent_id":"%s","cwd":"%s/entity/.claude/worktrees/agent-%s"%s}' \
        "$SID" "$event" "$aid" "$SANDBOX" "$aid" "$extra" | bash "$HOOKS/$hook" >/dev/null 2>&1
    printf '%s' "$?"
}

last_row() {
    python3 -c '
import json, os
rows = [json.loads(l) for l in open(os.environ["RICHOS_WORKTREE_LEDGER"]) if l.strip()]
rows = [r for r in rows if r.get("event") == "finished"]
print(json.dumps(rows[-1]) if rows else "{}")
'
}

names_all() { # <row-json> <teammate>
    printf '%s' "$1" | grep -q "\"teammate\": \"$2\"" \
        && printf '%s' "$1" | grep -q "richos-wt/$2" \
        && printf '%s' "$1" | grep -q "deeply-wt/$2"
}

echo "=== finish-row completion tests ==="

# --- F1-F3. all three writers, one implementation --------------------------
seal_tx a00000000000fr01 zach-opus-fr1
RC="$(fire worker-ended-handoff.sh SubagentStop a00000000000fr01)"
ROW="$(last_row)"
if [ "$RC" = "0" ] && names_all "$ROW" zach-opus-fr1; then
    ok "F1  worker-ended-handoff.sh: the row carries the teammate AND all three workspaces, including the two cross-repository ones no finish row has ever named"
else
    bad "F1  row=$ROW rc=$RC"
fi

seal_tx a00000000000fr02 zach-opus-fr2
RC="$(fire teammate-idle-handoff.sh TeammateIdle a00000000000fr02)"
ROW="$(last_row)"
if [ "$RC" = "0" ] && names_all "$ROW" zach-opus-fr2; then
    ok "F2  teammate-idle-handoff.sh: the same, with NO change to that hook -- the completion is in the ledger, so a fourth writer was never created"
else
    bad "F2  row=$ROW rc=$RC"
fi

# F3 is asserted at the implementation rather than through the third hook, and
# deliberately: task-completed-handoff.sh is a delivery GATE whose contract is
# to exit 2 when integration is unproven, so driving it here would test that
# gate rather than this row. What matters is that all three writers reach ONE
# implementation, which is a fact about the code and is checked as one.
WRITERS=0
for _h in worker-ended-handoff.sh teammate-idle-handoff.sh task-completed-handoff.sh; do
    grep -q '"event": "finished"' "$HOOKS/$_h" && grep -q 'wl.append(rec)' "$HOOKS/$_h" \
        && WRITERS=$((WRITERS + 1))
done
seal_tx a00000000000fr03 zach-opus-fr3
ROW="$(RICHOS_WORKTREE_LEDGER="$RICHOS_WORKTREE_LEDGER" python3 - "$LEDGER_PY" "$SID" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("wl", sys.argv[1])
wl = importlib.util.module_from_spec(spec); spec.loader.exec_module(wl)
wl.append({"event": "finished", "signal": "TaskCompleted", "agent_id": "a00000000000fr03",
           "teammate": "", "session_id": sys.argv[2], "worktree": "", "task_id": "t-1",
           "source": "task-completed-handoff.sh"})
rows = [json.loads(l) for l in open(os.environ["RICHOS_WORKTREE_LEDGER"]) if l.strip()]
print(json.dumps(rows[-1]))
PY
)"
if [ "$WRITERS" = "3" ] && names_all "$ROW" zach-opus-fr3; then
    ok "F3  all three writers reach ONE implementation (wl.append), and that implementation completes the row -- so the third hook gets this without a line of its own and a fourth writer was never created"
else
    bad "F3  writers=$WRITERS row=$ROW"
fi

# --- F4. `worktree` is unchanged -------------------------------------------
seal_tx a00000000000fr02b zach-opus-fr2b
RC="$(fire teammate-idle-handoff.sh TeammateIdle a00000000000fr02b)"
ROW="$(last_row)"
if [ "$RC" = "0" ] && printf '%s' "$ROW" | python3 -c '
import json, sys
r = json.load(sys.stdin)
sys.exit(0 if r.get("worktree", "").endswith("/.claude/worktrees/agent-a00000000000fr02b") else 1)
'; then
    ok "F4  the 'worktree' field still carries the native cwd exactly as before: this ADDS a field, it never redefines an old one, so no existing reader changes meaning"
else
    bad "F4  worktree field changed meaning: $ROW"
fi

# --- F5. the boundary: advisory, and never a claim --------------------------
# The completion resolves from the record. It does not create one, it does not
# make the row decisive, and the reclaim path does not consult it.
if grep -q 'advisory, never decisive' "$LEDGER_PY"; then
    ok "F5  the ledger still prints finish signals as advisory and never decisive -- a truer breadcrumb is not a new authority"
else
    bad "F5  the advisory framing disappeared from worktree-ledger.py"
fi

# --- F6. no record: silence, never an invention -----------------------------
RC="$(fire worker-ended-handoff.sh SubagentStop a00000000000fr09)"
ROW="$(last_row)"
if [ "$RC" = "0" ] && printf '%s' "$ROW" | grep -q '"agent_id": "a00000000000fr09"' \
   && ! printf '%s' "$ROW" | grep -q '"workspaces"'; then
    ok "F6  an agent nothing has registered still gets its row, and NO workspaces are invented for it"
else
    bad "F6  row=$ROW rc=$RC"
fi

# --- F7. id-less preparation rows join, but only unambiguously --------------
# create-teammate-worktree.sh writes a `prepared` row BEFORE any spawn exists
# to carry an agent id. That row is this assignment's when exactly one agent id
# has ever been recorded for the teammate in this session -- and nobody's when
# a second one has.
python3 "$LEDGER_PY" record prepared --teammate zach-opus-fr4 --session-id "$SID" \
    --repo "$SANDBOX/repo" --worktree "$SANDBOX/late-wt/zach-opus-fr4" --branch cc/zach-opus-fr4 \
    --class hand-rolled --source test >/dev/null 2>&1
python3 "$LEDGER_PY" record registered --teammate zach-opus-fr4 --session-id "$SID" --agent-id a00000000000fr04 \
    --repo "$SANDBOX/repo" --worktree "$SANDBOX/entity/.claude/worktrees/agent-a00000000000fr04" \
    --branch worktree-agent-a00000000000fr04 --class native --source test >/dev/null 2>&1
RC="$(fire worker-ended-handoff.sh SubagentStop a00000000000fr04)"
ROW="$(last_row)"
if [ "$RC" = "0" ] && printf '%s' "$ROW" | grep -q "late-wt/zach-opus-fr4"; then
    ok "F7  a folder prepared BEFORE the spawn -- with no agent id, because none existed yet -- joins the row through the teammate name when that name is unambiguous in the session"
else
    bad "F7  row=$ROW rc=$RC"
fi

python3 "$LEDGER_PY" record registered --teammate zach-opus-fr4 --session-id "$SID" --agent-id a00000000000fr05 \
    --repo "$SANDBOX/repo" --worktree "$SANDBOX/entity/.claude/worktrees/agent-a00000000000fr05" \
    --branch worktree-agent-a00000000000fr05 --class native --source test >/dev/null 2>&1
RC="$(fire worker-ended-handoff.sh SubagentStop a00000000000fr04)"
ROW="$(last_row)"
if [ "$RC" = "0" ] && ! printf '%s' "$ROW" | grep -q "late-wt/zach-opus-fr4"; then
    ok "F8  ...and a SECOND agent id recorded for that teammate makes the name ambiguous, so the id-less folder joins nobody (the negative control for F7)"
else
    bad "F8  row=$ROW rc=$RC"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== finish-row completion tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== finish-row completion tests: all $PASS passed ==="
exit 0
