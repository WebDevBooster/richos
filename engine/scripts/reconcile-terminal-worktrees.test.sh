#!/usr/bin/env bash
#
# reconcile-terminal-worktrees.test.sh — behavioral tests for the persistent
# reconciler, scripts/reconcile-terminal-worktrees.py.
#
# What is proven: a terminal two-repository transaction is driven quarantined
# -> captured -> verified -> unregistered -> removed with the backup refs
# intact; staged, unstaged, untracked and ignored evidence survive
# byte-for-byte in the archive while a disposable path does not; a process
# holding the quarantine is terminated before capture; a recreated original
# path is reclaimed; a crash after every transition is recovered on the next
# run; a write during the settle defers capture (retried, never a torn
# archive); an archive that does not verify keeps the quarantine; a hard
# failure stays counted as dead-present; --status reports the definition of
# done; a time budget stops cleanly; nothing is ever matched by name.
#
# The mutation harness proving each assertion load-bearing is
# scripts/reconcile-terminal-worktrees.mutation.sh, run at the end.
#
# Run directly: scripts/reconcile-terminal-worktrees.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="$SCRIPT_DIR/reconcile-terminal-worktrees.py"
TX_PY="$SCRIPT_DIR/lib/worktree-transactions.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t reconcile-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
[ -f "$REC" ] || { echo "FATAL: $REC missing" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
export RICHOS_WORKTREE_CAPTURE_DIR="$SANDBOX/captures"
export RICHOS_RECONCILE_SETTLE=0.2
export RICHOS_RECONCILE_BACKOFF_BASE=0   # C42 proves the backoff; every other case retries at once
SID="deadbeef-0000-4000-8000-000000000000"
T() { python3 "$TX_PY" "$@"; }
R() { python3 "$REC" "$@"; }

seed_repo() { mkdir -p "$1"; git -C "$1" init -q -b main; printf 'seed\n' >"$1/seed.txt"; printf 'node_modules/\n*.log\n' >"$1/.gitignore"; git -C "$1" add -A; git -C "$1" commit -q -m seed; }
ENTITY="$SANDBOX/entity"; seed_repo "$ENTITY"; mkdir -p "$ENTITY/.claude/worktrees"
OTHER="$SANDBOX/other";   seed_repo "$OTHER"

seal() { # <aid> <teammate> [external-repo:path:branch]
    local aid="$1" name="$2" kind="native" ext="[]"
    git -C "$ENTITY" worktree add -q -b "worktree-agent-$aid" "$ENTITY/.claude/worktrees/agent-$aid"
    if [ -n "${3:-}" ]; then
        local repo="${3%%:*}" rest="${3#*:}"; local path="${rest%%:*}" branch="${rest#*:}"
        git -C "$repo" worktree add -q -b "$branch" "$path"
        kind="native+external"; ext="[{\"repo\":\"$repo\",\"path\":\"$path\",\"branch\":\"$branch\"}]"
    fi
    printf '{"kind":"%s","teammate":"%s","externals":%s}' "$kind" "$name" "$ext" | T intent --session-id "$SID" --tool-use-id "tu-$aid" >/dev/null
    T bind --session-id "$SID" --tool-use-id "tu-$aid" --agent-id "$aid" >/dev/null
    T start --session-id "$SID" --agent-id "$aid" --cwd "$ENTITY/.claude/worktrees/agent-$aid" >/dev/null
    T seal --session-id "$SID" --agent-id "$aid" >/dev/null
}
states() { T members --session-id "$SID" --agent-id "$1" | cut -f5 | tr '\n' ' '; }
q() { printf '%s.richos-terminal-%s-%s' "$1" "${SID:0:8}" "$2"; }

echo "=== reconcile-terminal-worktrees tests ==="

# --- 1. the full path, two repositories, every evidence class ------------------
A1="a00000000000rc01"
EXT1="$SANDBOX/other-wt/dev-opus-r1"
seal "$A1" dev-opus-r1 "$OTHER:$EXT1:dev-opus-r1"
NAT1="$ENTITY/.claude/worktrees/agent-$A1"
# unstaged tracked edit, staged new file, untracked file, ignored file, a disposable dir
printf 'edited\n' >>"$EXT1/seed.txt"
printf 'staged\n' >"$EXT1/staged.txt"; git -C "$EXT1" add staged.txt
printf 'untracked\n' >"$EXT1/notes.txt"
printf 'ignored secret-ish evidence\n' >"$EXT1/run.log"
mkdir -p "$EXT1/node_modules/x"; printf 'disposable\n' >"$EXT1/node_modules/x/a.js"
ln -s seed.txt "$EXT1/link-to-seed"
HEAD_E="$(git -C "$EXT1" rev-parse HEAD)"; HEAD_N="$(git -C "$NAT1" rev-parse HEAD)"
T claim --session-id "$SID" --agent-id "$A1" --ingress SubagentStop >/dev/null
OUT="$(R 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(states "$A1")" = "removed removed " ] && ok "C01  one run drives both members quarantined -> removed" || bad "C01  rc=$RC states=$(states "$A1") $OUT"
[ ! -e "$(q "$NAT1" "$A1")" ] && [ ! -e "$(q "$EXT1" "$A1")" ] && [ ! -e "$NAT1" ] && [ ! -e "$EXT1" ] \
    && ok "C02  both quarantine directories are gone and neither original was recreated" || bad "C02  directories remain"
! git -C "$OTHER" worktree list --porcelain | grep -q "dev-opus-r1" && ! git -C "$ENTITY" worktree list --porcelain | grep -q "agent-$A1" \
    && ok "C03  git no longer lists either worktree" || bad "C03  still registered"
[ "$(git -C "$OTHER" rev-parse -q --verify "refs/richos/handoffs/$SID/$A1/dev-opus-r1")" = "$HEAD_E" ] \
    && [ "$(git -C "$ENTITY" rev-parse -q --verify "refs/richos/handoffs/$SID/$A1/worktree-agent-$A1")" = "$HEAD_N" ] \
    && ok "C04  the backup refs survive in both repositories (unlanded commits stay reachable)" || bad "C04  backup refs"
git -C "$OTHER" rev-parse -q --verify refs/heads/dev-opus-r1 >/dev/null && ok "C05  the member's branch itself is left alone" || bad "C05  branch deleted"
CAP="$SANDBOX/captures/$SID/$A1/member-1"
[ -f "$CAP/tree.tar" ] && [ -f "$CAP/manifest.json" ] && [ -f "$CAP/index.json" ] && [ -f "$CAP/provenance.json" ] \
    && ok "C06  the archive holds tree.tar, manifest.json, index.json and provenance.json" || bad "C06  archive files: $(ls "$CAP" 2>/dev/null | tr '\n' ' ')"
X="$SANDBOX/extract1"; mkdir -p "$X"; tar -xf "$CAP/tree.tar" -C "$X"
if [ "$(cat "$X/seed.txt")" = "$(printf 'seed\nedited\n')" ] && [ "$(cat "$X/staged.txt")" = "staged" ] \
   && [ "$(cat "$X/notes.txt")" = "untracked" ] && [ "$(cat "$X/run.log")" = "ignored secret-ish evidence" ] \
   && [ "$(readlink "$X/link-to-seed")" = "seed.txt" ]; then
    ok "C07  unstaged, staged, untracked, IGNORED evidence and a symlink survive byte-for-byte in the archive"
else
    bad "C07  archive contents: $(ls -la "$X" | tr '\n' ' ' | cut -c1-300)"
fi
[ ! -e "$X/node_modules" ] && ok "C08  the declared disposable path (node_modules) is not captured" || bad "C08  disposable captured"
python3 - "$CAP/index.json" "$CAP/blobs" <<'PY' && ok "C09  the staged blob's bytes are archived under its index sha" || bad "C09  staged blob"
import json, os, sys
idx = json.load(open(sys.argv[1]))
e = next(x for x in idx if x["path"] == "staged.txt")
assert open(os.path.join(sys.argv[2], e["sha"])).read() == "staged\n"
PY
python3 - "$CAP/provenance.json" "$HEAD_E" "$EXT1" <<'PY' && ok "C10  provenance names the repo, original path, branch, HEAD and backup ref" || bad "C10  provenance"
import json, sys
p = json.load(open(sys.argv[1]))
assert p["head"] == sys.argv[2] and p["original_path"] == sys.argv[3] and p["branch"] == "dev-opus-r1"
assert p["backup_ref"].startswith("refs/richos/handoffs/") and p["repo"]
PY

# --- 2. --status is the definition of done -------------------------------------
S="$(R --status)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$S" | grep -q '"terminal_members_with_a_directory_present": 0' && ok "C11  --status: zero dead-present, zero pending -> done (exit 0)" || bad "C11  status rc=$RC: $S"

# --- 3. crash recovery at EVERY transition ---------------------------------------
A2="a00000000000rc02"
EXT2="$SANDBOX/other-wt/dev-opus-r2"
seal "$A2" dev-opus-r2 "$OTHER:$EXT2:dev-opus-r2"
printf 'x\n' >"$EXT2/x.txt"
T claim --session-id "$SID" --agent-id "$A2" --ingress WorktreeRemove --first-path "$ENTITY/.claude/worktrees/agent-$A2" >/dev/null
# drive ONE member ONE step at a time through a subprocess we can "crash" after each step
STEP_OK=1
for expect in captured verified unregistered removed; do
    python3 - "$REC" "$SID" "$A2" "$expect" <<'PY' || STEP_OK=0
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("rec", sys.argv[1]); rec = importlib.util.module_from_spec(spec); spec.loader.exec_module(rec)
tx = rec.tx
sid, aid, expect = sys.argv[2:5]
t = tx.load_tx(sid, aid)
st = t["members"][1]["state"]
step = rec.STEPS[st]
t = step(t, 1)
t = tx.load_tx(sid, aid)
assert t["members"][1]["state"] == expect, (t["members"][1]["state"], expect)
os._exit(0)   # the "crash": no cleanup, no further steps
PY
done
[ "$STEP_OK" -eq 1 ] && ok "C12  each transition of the external member can be taken alone and persists (crash after every step)" || bad "C12  stepwise"
R >/dev/null 2>&1
[ "$(states "$A2")" = "removed removed " ] && ok "C13  the next run finishes the OTHER member from wherever it was" || bad "C13  states=$(states "$A2")"

# --- 4. a process using the quarantine is terminated before capture -------------
A3="a00000000000rc03"
EXT3="$SANDBOX/other-wt/dev-opus-r3"
seal "$A3" dev-opus-r3 "$OTHER:$EXT3:dev-opus-r3"
T claim --session-id "$SID" --agent-id "$A3" --ingress SubagentStop >/dev/null
Q3="$(q "$EXT3" "$A3")"
( cd "$Q3" && exec sleep 300 ) &
HOLDER=$!
sleep 0.3
R >/dev/null 2>&1
if ! kill -0 "$HOLDER" 2>/dev/null && [ "$(states "$A3")" = "removed removed " ]; then
    ok "C14  a process whose cwd is inside the quarantine is terminated and the member still completes"
else
    bad "C14  holder alive=$(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no) states=$(states "$A3")"
    kill "$HOLDER" 2>/dev/null
fi
wait "$HOLDER" 2>/dev/null

# --- 5. a recreated ORIGINAL path is reclaimed --------------------------------
A4="a00000000000rc04"
EXT4="$SANDBOX/other-wt/dev-opus-r4"
seal "$A4" dev-opus-r4 "$OTHER:$EXT4:dev-opus-r4"
T claim --session-id "$SID" --agent-id "$A4" --ingress SubagentStop >/dev/null
mkdir -p "$EXT4"; printf 'ghost write\n' >"$EXT4/ghost.txt"     # residue after quarantine
R >/dev/null 2>&1
if [ ! -e "$EXT4" ] && [ -f "$SANDBOX/captures/$SID/$A4/member-1/residue-1.tar" ] && [ "$(states "$A4")" = "removed removed " ]; then
    ok "C15  a recreated original path is detected, its bytes kept as residue-1.tar, and it is removed"
else
    bad "C15  residue: exists=$([ -e "$EXT4" ] && echo yes || echo no) states=$(states "$A4")"
fi

# --- 6. a write during the settle DEFERS capture; nothing torn, nothing lost -------
A5="a00000000000rc05"
EXT5="$SANDBOX/other-wt/dev-opus-r5"
seal "$A5" dev-opus-r5 "$OTHER:$EXT5:dev-opus-r5"
T claim --session-id "$SID" --agent-id "$A5" --ingress SubagentStop >/dev/null
Q5="$(q "$EXT5" "$A5")"
( for i in 1 2 3 4 5 6 7 8; do printf '%s\n' "$i" >>"$Q5/churn.txt"; sleep 0.15; done ) &
WRITER=$!
OUT="$(RICHOS_RECONCILE_NO_KILL=1 RICHOS_RECONCILE_SETTLE=0.5 R 2>&1)"
wait "$WRITER"
if [ "$(states "$A5")" = "removed quarantined " ] && printf '%s' "$OUT" | grep -q 'changed during the settle interval' && [ -d "$Q5" ]; then
    ok "C16  a quarantine that changes during the settle is NOT captured: retried later, the quarantine kept, no torn archive"
else
    bad "C16  states=$(states "$A5") out=${OUT:0:200}"
fi
R >/dev/null 2>&1
[ "$(states "$A5")" = "removed removed " ] && [ "$(tar -xOf "$SANDBOX/captures/$SID/$A5/member-1/tree.tar" churn.txt | wc -l | tr -d ' ')" = "8" ] \
    && ok "C17  ...and the next run captures the settled bytes completely" || bad "C17  states=$(states "$A5")"

# --- 7. an archive that does not verify keeps the quarantine --------------------
A6="a00000000000rc06"
EXT6="$SANDBOX/other-wt/dev-opus-r6"
seal "$A6" dev-opus-r6 "$OTHER:$EXT6:dev-opus-r6"
T claim --session-id "$SID" --agent-id "$A6" --ingress SubagentStop >/dev/null
python3 - "$REC" "$SID" "$A6" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rec", sys.argv[1]); rec = importlib.util.module_from_spec(spec); spec.loader.exec_module(rec)
t = rec.tx.load_tx(sys.argv[2], sys.argv[3])
rec.capture_member(t, 1)
PY
Q6="$(q "$EXT6" "$A6")"
# damage the archive: overwrite the recorded digest of one file, so the tar's
# real bytes no longer match what the manifest claims
python3 - "$SANDBOX/captures/$SID/$A6/member-1/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["seed.txt"]["sha256"] = "0" * 64
json.dump(m, open(sys.argv[1], "w"))
PY
OUT="$(RICHOS_RECONCILE_MAX_ONE=1 R --agent "$SID/$A6" 2>&1)"
if [ -d "$Q6" ] && printf '%s' "$OUT" | grep -q 'digest mismatch' && printf '%s' "$OUT" | grep -q 'the capture is void'; then
    ok "C18  a damaged archive does not verify: the capture is VOID, the quarantine is kept, nothing is deleted on its strength"
else
    bad "C18  states=$(states "$A6") out=${OUT:0:200}"
fi
R --agent "$SID/$A6" >/dev/null 2>&1
[ "$(states "$A6")" = "removed removed " ] && ok "C18b ...and the next run re-captures from the untouched quarantine and completes" || bad "C18b states=$(states "$A6")"

# --- 8. BOTH PRESENT is resolved AUTOMATICALLY (landed review 2026-09-03,
# blocker 3). Until this revision C19/C20 certified the opposite: original AND
# quarantine present -> FAILED, both kept, reported once, never retried,
# counted as dead-present "until an operator resolves it". That certification
# is replaced. The quarantine name embeds the session prefix and the agent id,
# so a directory at that exact name is this member's own quarantine; whatever
# reappeared at the original path is residue — archived, VERIFIED against its
# manifest, then removed — unless git registers it as another worktree (C45).
A7="a00000000000rc07"
seal "$A7" dev-opus-r7
NAT7="$ENTITY/.claude/worktrees/agent-$A7"
T claim --session-id "$SID" --agent-id "$A7" --ingress SubagentStop >/dev/null
Q7="$(q "$NAT7" "$A7")"
mkdir -p "$NAT7"; printf 'ghost\n' >"$NAT7/ghost.txt"    # residue reappears at the original path
python3 - "$TX_PY" "$SID" "$A7" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tx", sys.argv[1]); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
# rewind the member to ref_saved so recovery re-evaluates the rename step with both paths present
with tx.tx_lock(sys.argv[2], sys.argv[3]):
    tx.update_member(sys.argv[2], sys.argv[3], 0, state="ref_saved")
PY
OUT="$(R 2>&1)"
M7="$(T show --session-id "$SID" --agent-id "$A7" | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][0]; print(m["state"], m.get("original_present_at_quarantine"), m.get("residue_count"), m.get("residue_verified"))')"
RES7="$SANDBOX/captures/$SID/$A7/member-0/residue-1.tar"
if [ "$M7" = "removed True 1 True" ] && [ ! -e "$NAT7" ] && [ ! -e "$Q7" ] && [ -f "$RES7" ] && [ -f "${RES7%.tar}.manifest.json" ] \
   && [ "$(tar -xOf "$RES7" ghost.txt)" = "ghost" ] && ! printf '%s' "$OUT" | grep -q 'FAILURE'; then
    ok "C19  original AND quarantine present -> resolved AUTOMATICALLY: the residue at the original path is archived and VERIFIED (residue-1.tar + manifest) then removed, the quarantine is captured and removed, nothing is reported as a failure and nobody is asked (INVERTED: it used to park as FAILED for an operator)"
else
    bad "C19  member=[$M7] orig=$([ -e "$NAT7" ] && echo present || echo gone) quar=$([ -e "$Q7" ] && echo present || echo gone) residue=$([ -f "$RES7" ] && echo yes || echo no) out=${OUT:0:200}"
fi
S="$(R --status)"
printf '%s' "$S" | grep -q '"hard_failures_counted_as_dead_present": 0' && ok "C20  ...and --status counts no hard failure: there is no manual queue" || bad "C20  status: ${S:0:200}"

# --- 9. nothing is matched by name; only terminal transactions are touched ---------
A8="a00000000000rc08"
seal "$A8" dev-opus-r1     # SAME teammate name as A1, live (never claimed)
R >/dev/null 2>&1
[ -d "$ENTITY/.claude/worktrees/agent-$A8" ] && [ "$(states "$A8")" = "bound " ] \
    && ok "C21  a LIVE agent reusing a terminal agent's name is untouched (nothing is matched by name)" || bad "C21  live agent touched"
mkdir -p "$SANDBOX/other-wt/dev-opus-r1"   # a stranger directory with a terminal member's old path
R >/dev/null 2>&1
[ -d "$SANDBOX/other-wt/dev-opus-r1" ] && ok "C22  a stranger directory at a REMOVED member's old path is not reclaimed (the member is done; no search)" || bad "C22  stranger removed"

# --- 10. a time budget stops cleanly -------------------------------------------------
A9="a00000000000rc09"; A10="a00000000000rc10"
seal "$A9" dev-opus-r9; seal "$A10" dev-opus-r10
T claim --session-id "$SID" --agent-id "$A9" --ingress SubagentStop >/dev/null
T claim --session-id "$SID" --agent-id "$A10" --ingress SubagentStop >/dev/null
OUT="$(R --max-seconds 0.001 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'time budget reached' && { [ "$(states "$A9")" != "removed " ] || [ "$(states "$A10")" != "removed " ]; }; then
    ok "C23  --max-seconds stops cleanly, says so, and leaves the rest for the next run"
else
    bad "C23  rc=$RC states9=$(states "$A9") states10=$(states "$A10") out=${OUT:0:120}"
fi
R --agent "$SID/$A9" >/dev/null 2>&1
[ "$(states "$A9")" = "removed " ] && ok "C24  --agent reconciles exactly one transaction" || bad "C24  states=$(states "$A9")"
R >/dev/null 2>&1
[ "$(states "$A10")" = "removed " ] && ok "C25  an unbudgeted run finishes what the budgeted one left" || bad "C25  states=$(states "$A10")"

# --- 11. a PENDING terminal event that can never seal is routed through
# creation-time cleanup (review 2026-09-03, blocker 4) --------------------------
# The agent was bound (native+external: the lead prepared an external tree)
# but its start fact never arrived, and its SubagentStop came first. After the
# grace period the reconciler builds the transaction from the BOUND record's
# prepared external member — verified against git exactly as the seal would —
# and drives it to removed. The native tree, which no start fact ever named,
# is NOT invented: it stays where it is for the inventory to report.
A11="a00000000000rc11"
EXT11="$SANDBOX/other-wt/dev-opus-r11"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A11" "$ENTITY/.claude/worktrees/agent-$A11"
git -C "$OTHER" worktree add -q -b dev-opus-r11 "$EXT11"
printf 'unstaged evidence\n' >"$EXT11/notes.txt"
printf '{"kind":"native+external","teammate":"dev-opus-r11","externals":[{"repo":"%s","path":"%s","branch":"dev-opus-r11"}]}' "$OTHER" "$EXT11" \
    | T intent --session-id "$SID" --tool-use-id "tu-$A11" >/dev/null
T bind --session-id "$SID" --tool-use-id "tu-$A11" --agent-id "$A11" >/dev/null
T claim --session-id "$SID" --agent-id "$A11" --ingress SubagentStop >/dev/null 2>&1   # unsealed -> pending
[ -f "$SANDBOX/tx/$SID/pending-terminal/$A11.json" ] || bad "C26-setup  no pending record"
RICHOS_PENDING_TERMINAL_GRACE=3600 R >/dev/null 2>&1
if [ -d "$EXT11" ] && [ -f "$SANDBOX/tx/$SID/pending-terminal/$A11.json" ] && ! T show --session-id "$SID" --agent-id "$A11" >/dev/null 2>&1; then
    ok "C26  within the grace period a pending event waits: no transaction is built, nothing moves"
else
    bad "C26  ext=$([ -d "$EXT11" ] && echo present || echo gone) pending=$([ -f "$SANDBOX/tx/$SID/pending-terminal/$A11.json" ] && echo kept || echo gone)"
fi
OUT="$(RICHOS_PENDING_TERMINAL_GRACE=0 R 2>&1)"
SEALED_BY="$(T show --session-id "$SID" --agent-id "$A11" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("sealed_by",""), len(d["members"]), (d.get("terminal") or {}).get("ingress",""))')"
if [ "$SEALED_BY" = "pending-terminal-fallback 1 SubagentStop" ] && [ "$(states "$A11")" = "removed " ] && [ ! -e "$EXT11" ] \
   && [ -d "$ENTITY/.claude/worktrees/agent-$A11" ] && [ ! -f "$SANDBOX/tx/$SID/pending-terminal/$A11.json" ] \
   && [ "$(tar -xOf "$SANDBOX/captures/$SID/$A11/member-0/tree.tar" notes.txt)" = "unstaged evidence" ]; then
    ok "C27  after the grace period the BOUND record's prepared external member is verified, terminalized and removed with its evidence captured; the never-started native tree is not invented"
else
    bad "C27  sealed_by=[$SEALED_BY] states=$(states "$A11") ext=$([ -e "$EXT11" ] && echo present || echo gone) native=$([ -d "$ENTITY/.claude/worktrees/agent-$A11" ] && echo present || echo GONE) out=${OUT:0:200}"
fi
# --- 11b. a START-ONLY pending event (landed review 2026-09-03, blocker 2).
# Until this revision C28 certified that EVERY pending record with no bound
# record was dropped after the grace period as "nothing was ever owned" — and
# its fixture was the main checkout, so it never exercised the case that
# leaks: a SubagentStart that named the exact native worktree while the
# parent's binder failed. That certification is replaced by the three cases
# below: only the helper-in-main case results in no filesystem mutation, and
# even it keeps the terminal record rather than reinterpreting the event.
# C28a — a harmless helper whose start fact names the MAIN checkout: no
# mutation, but a zero-member terminal TOMBSTONE and the agent stays terminal
A12="a00000000000rc12"
T start --session-id "$SID" --agent-id "$A12" --cwd "$ENTITY" >/dev/null
T claim --session-id "$SID" --agent-id "$A12" --ingress SubagentStop >/dev/null 2>&1
[ -f "$SANDBOX/tx/$SID/pending-terminal/$A12.json" ] || bad "C28-setup  no pending record for the start-only agent"
RICHOS_PENDING_TERMINAL_GRACE=0 R >/dev/null 2>&1
TOMB="$(T show --session-id "$SID" --agent-id "$A12" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state"), len(d.get("members") or []), d.get("sealed_by"), (d.get("terminal") or {}).get("ingress"), d.get("closed"))')"
if [ ! -f "$SANDBOX/tx/$SID/pending-terminal/$A12.json" ] && [ "$TOMB" = "removed 0 pending-terminal-fallback SubagentStop no-members" ] \
   && T terminal-agent --agent-id "$A12" >/dev/null 2>&1 && [ -f "$ENTITY/seed.txt" ] && git -C "$ENTITY" status --porcelain >/dev/null 2>&1; then
    ok "C28a a start-only helper in the MAIN checkout: no filesystem mutation, but the terminal event is KEPT as a zero-member terminal transaction (removed, no-members) and the agent stays terminal (INVERTED: the record used to be dropped)"
else
    bad "C28a tombstone=[$TOMB] pending=$([ -f "$SANDBOX/tx/$SID/pending-terminal/$A12.json" ] && echo kept || echo gone) terminal=$(T terminal-agent --agent-id "$A12" >/dev/null 2>&1 && echo yes || echo no)"
fi
# C28b — a start-only EXACT native worktree (the binder failed): retired after grace
A18="a00000000000rc18"
NAT18="$ENTITY/.claude/worktrees/agent-$A18"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A18" "$NAT18"
printf 'work the binder never bound\n' >"$NAT18/unbound.txt"
HEAD18="$(git -C "$NAT18" rev-parse HEAD)"
T start --session-id "$SID" --agent-id "$A18" --cwd "$NAT18" --agent-type dev >/dev/null
T claim --session-id "$SID" --agent-id "$A18" --ingress SubagentStop >/dev/null 2>&1
[ -f "$SANDBOX/tx/$SID/pending-terminal/$A18.json" ] || bad "C28b-setup  no pending record"
OUT="$(RICHOS_PENDING_TERMINAL_GRACE=0 R 2>&1)"
FB18="$(T show --session-id "$SID" --agent-id "$A18" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["members"]; print(d.get("sealed_by"), d.get("bound_record"), len(m), m[0]["class"], m[0]["state"], d.get("state"))')"
if [ "$FB18" = "pending-terminal-fallback False 1 native removed removed" ] && [ ! -e "$NAT18" ] && [ ! -e "$(q "$NAT18" "$A18")" ] \
   && [ "$(git -C "$ENTITY" rev-parse -q --verify "refs/richos/handoffs/$SID/$A18/worktree-agent-$A18")" = "$HEAD18" ] \
   && [ "$(tar -xOf "$SANDBOX/captures/$SID/$A18/member-0/tree.tar" unbound.txt)" = "work the binder never bound" ] \
   && [ ! -f "$SANDBOX/tx/$SID/pending-terminal/$A18.json" ] && printf '%s' "$OUT" | grep -q 'no bound record: the native member came from the start fact'; then
    ok "C28b a start-only EXACT native worktree (no bound record) is verified from the start fact, terminalized as a one-member fallback and RETIRED: backup ref saved, evidence captured, worktree removed (INVERTED: it used to leak forever)"
else
    bad "C28b fallback=[$FB18] native=$([ -e "$NAT18" ] && echo present || echo gone) quar=$([ -e "$(q "$NAT18" "$A18")" ] && echo present || echo gone) out=${OUT:0:200}"
fi
# C28c — the exact native path named by a WorktreeRemove (first_path) when the
# start fact names somewhere else (the main checkout): verified from first_path
A19="a00000000000rc19"
NAT19="$ENTITY/.claude/worktrees/agent-$A19"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A19" "$NAT19"
T start --session-id "$SID" --agent-id "$A19" --cwd "$ENTITY" >/dev/null
T claim --session-id "$SID" --agent-id "$A19" --ingress WorktreeRemove --detail "$NAT19" >/dev/null 2>&1
RICHOS_PENDING_TERMINAL_GRACE=0 R >/dev/null 2>&1
FB19="$(T show --session-id "$SID" --agent-id "$A19" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["members"]; print(len(m), m[0]["path"] if m else "-", d.get("state"), (d.get("terminal") or {}).get("ingress"))')"
[ "$FB19" = "1 $NAT19 removed WorktreeRemove" ] && [ ! -e "$NAT19" ] \
    && ok "C28c the exact native path a WorktreeRemove named (first_path) is verified and retired even though the start fact named the main checkout" || bad "C28c fallback=[$FB19] native=$([ -e "$NAT19" ] && echo present || echo gone)"

# --- 12. index capture must SUCCEED, or the member is not captured -------------
# (review 2026-09-03, blocker 2). A failed `git ls-files -s` used to be
# recorded as an empty index and the member still advanced to captured.
A13="a00000000000rc13"
EXT13="$SANDBOX/other-wt/dev-opus-r13"
seal "$A13" dev-opus-r13 "$OTHER:$EXT13:dev-opus-r13"
printf 'staged only\n' >"$EXT13/only-in-index.txt"; git -C "$EXT13" add only-in-index.txt
T claim --session-id "$SID" --agent-id "$A13" --ingress SubagentStop >/dev/null
Q13="$(q "$EXT13" "$A13")"
REAL_GIT="$(command -v git)"
NOLS="$SANDBOX/nolsbin"; mkdir -p "$NOLS"
cat >"$NOLS/git" <<SH
#!/usr/bin/env bash
if [ "\$3" = "ls-files" ]; then echo "fatal: simulated index read failure" >&2; exit 128; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$NOLS/git"
OUT="$(PATH="$NOLS:$PATH" R --agent "$SID/$A13" 2>&1)"
M13="$(T show --session-id "$SID" --agent-id "$A13" | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][1]; print(m["state"], m.get("attempts"), m.get("last_error","")[:60])')"
if [ "$(states "$A13")" = "quarantined quarantined " ] && [ -d "$Q13" ] && printf '%s' "$M13" | grep -q '^quarantined 1 git ls-files' \
   && [ ! -f "$SANDBOX/captures/$SID/$A13/member-1/index.json" ]; then
    ok "C29  a failed \`git ls-files\` keeps the member QUARANTINED (attempt counted, error named, no index.json written) — nothing is captured, nothing deleted"
else
    bad "C29  states=$(states "$A13") member=[$M13] quar=$([ -d "$Q13" ] && echo present || echo GONE) out=${OUT:0:200}"
fi
R --agent "$SID/$A13" >/dev/null 2>&1
IDX13="$SANDBOX/captures/$SID/$A13/member-1/index.json"
python3 - "$IDX13" "$SANDBOX/captures/$SID/$A13/member-1/blobs" <<'PY' && [ "$(states "$A13")" = "removed removed " ] \
    && ok "C30  ...the retry captures the index exactly: the staged-only entry is marked needs_blob and its blob is archived; the seed entry (in HEAD) is not" || bad "C30  states=$(states "$A13")"
import json, os, sys
idx = json.load(open(sys.argv[1]))
e = next(x for x in idx if x["path"] == "only-in-index.txt")
s = next(x for x in idx if x["path"] == "seed.txt")
assert e["needs_blob"] is True and s["needs_blob"] is False, idx
assert open(os.path.join(sys.argv[2], e["sha"])).read() == "staged only\n"
assert not os.path.exists(os.path.join(sys.argv[2], s["sha"]))
PY

# --- 13. verification requires EVERY expected blob and EVERY manifest entry ------
# (blockers 2 and 8): a missing staged blob, a wrong symlink target and a
# wrong mode each VOID the capture; the quarantine is kept.
verify_void() { # <aid> <ext-path> <damage-python> <needle> <case-id> <label>
    local aid="$1" ext="$2" damage="$3" needle="$4" cid="$5" label="$6"
    seal "$aid" "dev-opus-$aid" "$OTHER:$ext:dev-opus-$aid"
    printf 'staged\n' >"$ext/staged.txt"; git -C "$ext" add staged.txt
    ln -s seed.txt "$ext/link"; chmod 0755 "$ext/seed.txt"
    T claim --session-id "$SID" --agent-id "$aid" --ingress SubagentStop >/dev/null
    python3 - "$REC" "$SID" "$aid" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rec", sys.argv[1]); rec = importlib.util.module_from_spec(spec); spec.loader.exec_module(rec)
t = rec.tx.load_tx(sys.argv[2], sys.argv[3]); rec.capture_member(t, 1)
PY
    python3 - "$SANDBOX/captures/$SID/$aid/member-1" <<PY
import json, os, sys
d = sys.argv[1]
$damage
PY
    local out; out="$(R --agent "$SID/$aid" 2>&1)"
    if [ -d "$(q "$ext" "$aid")" ] && printf '%s' "$out" | grep -q "$needle" && printf '%s' "$out" | grep -q 'the capture is void'; then
        ok "$cid  $label -> capture VOID ('$needle'), quarantine kept"
    else
        bad "$cid  states=$(states "$aid") out=${out:0:200}"
    fi
    R --agent "$SID/$aid" >/dev/null 2>&1
    [ "$(states "$aid")" = "removed removed " ] && ok "$cid-r ...and the re-capture from the untouched quarantine verifies and completes" || bad "$cid-r states=$(states "$aid")"
}
verify_void a00000000000rc14 "$SANDBOX/other-wt/dev-opus-r14" \
    'idx = json.load(open(os.path.join(d, "index.json"))); e = next(x for x in idx if x["path"] == "staged.txt"); os.unlink(os.path.join(d, "blobs", e["sha"]))' \
    'is missing from the archive' C31 "a staged blob that should exist but does not"
verify_void a00000000000rc15 "$SANDBOX/other-wt/dev-opus-r15" \
    'm = json.load(open(os.path.join(d, "manifest.json"))); m["link"]["target"] = "elsewhere.txt"; json.dump(m, open(os.path.join(d, "manifest.json"), "w"))' \
    'symlink target mismatch' C32 "a symlink whose archived target is not the manifest target"
verify_void a00000000000rc16 "$SANDBOX/other-wt/dev-opus-r16" \
    'm = json.load(open(os.path.join(d, "manifest.json"))); m["seed.txt"]["mode"] = 0o600; json.dump(m, open(os.path.join(d, "manifest.json"), "w"))' \
    'mode mismatch' C33 "a file whose archived mode is not the manifest mode"

# --- 14. artifacts are PRIVATE, and retention is automatic --------------------------
CAP14="$SANDBOX/captures/$SID/a00000000000rc16/member-1"
MODES="$(python3 -c 'import os,sys; print(" ".join(oct(os.stat(p).st_mode & 0o777) for p in sys.argv[1:]))' "$CAP14" "$CAP14/tree.tar" "$CAP14/blobs" "$SANDBOX/captures/$SID/a00000000000rc16")"
[ "$MODES" = "0o700 0o600 0o700 0o700" ] && ok "C34  capture directories are 0700 and archives 0600 (explicit modes, not the ambient umask)" || bad "C34  modes=[$MODES]"
# retention: nothing expires at the defaults; everything expires at 0 days
R >/dev/null 2>&1
[ -f "$CAP14/tree.tar" ] && git -C "$OTHER" rev-parse -q --verify "refs/richos/handoffs/$SID/a00000000000rc16/dev-opus-a00000000000rc16" >/dev/null \
    && ok "C35  at the default retention (30/90/90 days) a just-removed transaction keeps its capture and backup ref" || bad "C35  expired too early"
# a transaction whose capture has expired but whose backup ref has not is NOT deleted (the record outlives every artifact it names)
OUT="$(RICHOS_CAPTURE_RETENTION_DAYS=0 RICHOS_BACKUP_REF_RETENTION_DAYS=1000 RICHOS_TRANSACTION_RETENTION_DAYS=0 R 2>&1)"
if [ ! -e "$CAP14" ] && T show --session-id "$SID" --agent-id a00000000000rc16 >/dev/null 2>&1 \
   && git -C "$OTHER" rev-parse -q --verify "refs/richos/handoffs/$SID/a00000000000rc16/dev-opus-a00000000000rc16" >/dev/null \
   && printf '%s' "$OUT" | grep -q 'retention: expired'; then
    ok "C36  capture retention at 0 days expires the capture; the record whose backup ref is still within retention is KEPT (no artifact is ever orphaned from its record)"
else
    bad "C36  cap=$([ -e "$CAP14" ] && echo present || echo gone) tx=$(T show --session-id "$SID" --agent-id a00000000000rc16 >/dev/null 2>&1 && echo present || echo gone) out=${OUT:0:200}"
fi
OUT="$(RICHOS_CAPTURE_RETENTION_DAYS=0 RICHOS_BACKUP_REF_RETENTION_DAYS=0 RICHOS_TRANSACTION_RETENTION_DAYS=0 R 2>&1)"
if [ ! -e "$SANDBOX/captures/$SID/a00000000000rc16" ] \
   && ! git -C "$OTHER" rev-parse -q --verify "refs/richos/handoffs/$SID/a00000000000rc16/dev-opus-a00000000000rc16" >/dev/null \
   && ! T show --session-id "$SID" --agent-id a00000000000rc16 >/dev/null 2>&1 \
   && [ ! -f "$SANDBOX/tx/$SID/bound/a00000000000rc16.json" ] && [ ! -f "$SANDBOX/tx/terminal-names/$SID/dev-opus-a00000000000rc16" ] \
   && [ -f "$SANDBOX/tx/terminal/a00000000000rc16" ] && printf '%s' "$OUT" | grep -q 'retention: expired'; then
    ok "C37  at 0 days for all three, the backup ref, the transaction record and its facts are expired by the run itself; the agent-id terminal index is kept"
else
    bad "C37  ref=$(git -C "$OTHER" rev-parse -q --verify "refs/richos/handoffs/$SID/a00000000000rc16/dev-opus-a00000000000rc16" >/dev/null && echo present || echo gone) tx=$(T show --session-id "$SID" --agent-id a00000000000rc16 >/dev/null 2>&1 && echo present || echo gone) out=${OUT:0:200}"
fi

# --- 15. a FAILED backup-ref deletion cannot be marked expired, and cannot let
# the record go (landed review 2026-09-03, blocker 4). Until this revision
# `git update-ref -d` ran with its result ignored, the member was stamped
# expired regardless, and transaction retention — which trusts the stamp —
# then deleted the only record saying the ref existed. Fault injection: a
# git shim rejects `update-ref -d`; the ref, the member's tracking and the
# transaction record must all remain, and the next (unshimmed) run expires
# them properly.
A17="a00000000000rc17"
EXT17="$SANDBOX/other-wt/dev-opus-r17"
seal "$A17" dev-opus-r17 "$OTHER:$EXT17:dev-opus-r17"
T claim --session-id "$SID" --agent-id "$A17" --ingress SubagentStop >/dev/null
R --agent "$SID/$A17" >/dev/null 2>&1
[ "$(states "$A17")" = "removed removed " ] || bad "C38-setup  states=$(states "$A17")"
REF17="refs/richos/handoffs/$SID/$A17/dev-opus-r17"
NODEL="$SANDBOX/nodelbin"; mkdir -p "$NODEL"
cat >"$NODEL/git" <<SH
#!/usr/bin/env bash
if [ "\$3" = "update-ref" ] && [ "\$4" = "-d" ]; then echo "fatal: simulated refusal to delete \$5" >&2; exit 128; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$NODEL/git"
OUT="$(PATH="$NODEL:$PATH" RICHOS_CAPTURE_RETENTION_DAYS=0 RICHOS_BACKUP_REF_RETENTION_DAYS=0 RICHOS_TRANSACTION_RETENTION_DAYS=0 R 2>&1)"
M17="$(T show --session-id "$SID" --agent-id "$A17" 2>/dev/null | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][1]; print("expired" if m.get("backup_ref_expired_ts") else "tracked", m.get("backup_ref_expire_attempts"), "named" if (m.get("backup_ref_expire_error") or "").startswith("git update-ref -d ") else "unnamed")')"
if git -C "$OTHER" rev-parse -q --verify "$REF17" >/dev/null && [ "$M17" = "tracked 1 named" ] \
   && T show --session-id "$SID" --agent-id "$A17" >/dev/null 2>&1 && printf '%s' "$OUT" | grep -q 'NOT expired (attempt 1)'; then
    ok "C38  git REJECTS the backup-ref deletion: the ref remains, the member is NOT stamped expired (attempt + error recorded), and the transaction record is NOT deleted"
else
    bad "C38  ref=$(git -C "$OTHER" rev-parse -q --verify "$REF17" >/dev/null && echo present || echo GONE) member=[$M17] tx=$(T show --session-id "$SID" --agent-id "$A17" >/dev/null 2>&1 && echo present || echo GONE) out=${OUT:0:200}"
fi
# a shim whose deletion "succeeds" but leaves the ref in place is caught by the verification, not the exit code
cat >"$NODEL/git" <<SH
#!/usr/bin/env bash
if [ "\$3" = "update-ref" ] && [ "\$4" = "-d" ]; then exit 0; fi
exec "$REAL_GIT" "\$@"
SH
OUT="$(PATH="$NODEL:$PATH" RICHOS_CAPTURE_RETENTION_DAYS=0 RICHOS_BACKUP_REF_RETENTION_DAYS=0 RICHOS_TRANSACTION_RETENTION_DAYS=0 R 2>&1)"
if git -C "$OTHER" rev-parse -q --verify "$REF17" >/dev/null && T show --session-id "$SID" --agent-id "$A17" >/dev/null 2>&1 \
   && printf '%s' "$OUT" | grep -q 'exited 0 but the ref still resolves'; then
    ok "C38b a deletion that exits 0 but leaves the ref resolving is NOT expired either: the exact ref is verified absent, the exit code is not trusted"
else
    bad "C38b ref=$(git -C "$OTHER" rev-parse -q --verify "$REF17" >/dev/null && echo present || echo GONE) out=${OUT:0:200}"
fi
OUT="$(RICHOS_CAPTURE_RETENTION_DAYS=0 RICHOS_BACKUP_REF_RETENTION_DAYS=0 RICHOS_TRANSACTION_RETENTION_DAYS=0 R 2>&1)"
if ! git -C "$OTHER" rev-parse -q --verify "$REF17" >/dev/null && ! T show --session-id "$SID" --agent-id "$A17" >/dev/null 2>&1; then
    ok "C38c ...and the next run with git working deletes the ref, verifies it gone, and only then expires the record"
else
    bad "C38c ref=$(git -C "$OTHER" rev-parse -q --verify "$REF17" >/dev/null && echo present || echo gone) tx=$(T show --session-id "$SID" --agent-id "$A17" >/dev/null 2>&1 && echo present || echo gone)"
fi

# --- 16. NATIVE DISAPPEARANCE is a terminal ingress (CEO specification
# 2026-09-03, section 4). Measured on this machine: a worker killed by
# TaskStop had its native worktree torn down by the platform while no hook
# delivered its id; the transaction stayed sealed, --status said done, and
# the hand-rolled richos member leaked. The reconciler now verifies every
# sealed live transaction's native member against its recorded repository
# and path, claims the transaction when it is gone or unregistered, closes
# the native member absent (backup ref from head_at_seal) and retires the
# surviving hand-rolled member through the normal state machine.
A20="a00000000000rc20"
EXT20="$SANDBOX/other-wt/dev-opus-r20"
seal "$A20" dev-opus-r20 "$OTHER:$EXT20:dev-opus-r20"
NAT20="$ENTITY/.claude/worktrees/agent-$A20"
HEAD20="$(git -C "$NAT20" rev-parse HEAD)"
printf 'survives the kill\n' >"$EXT20/evidence.txt"
# the platform's teardown: worktree AND branch, no hook (PF11)
git -C "$ENTITY" worktree remove --force "$NAT20" >/dev/null 2>&1
git -C "$ENTITY" branch -D "worktree-agent-$A20" >/dev/null 2>&1
OUT="$(R 2>&1)"
T20="$(T show --session-id "$SID" --agent-id "$A20" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["members"]; print((d.get("terminal") or {}).get("ingress"), d.get("state"), m[0]["state"], m[0].get("closed"), m[0].get("head_preserved"), m[1]["state"])')"
if [ "$T20" = "NativeMemberGone removed removed absent backup-ref removed" ] && [ ! -e "$EXT20" ] && [ ! -e "$(q "$EXT20" "$A20")" ] \
   && [ "$(git -C "$ENTITY" rev-parse -q --verify "refs/richos/handoffs/$SID/$A20/worktree-agent-$A20")" = "$HEAD20" ] \
   && [ "$(tar -xOf "$SANDBOX/captures/$SID/$A20/member-1/tree.tar" evidence.txt)" = "survives the kill" ] \
   && printf '%s' "$OUT" | grep -q "NATIVE MEMBER GONE for deadbeef/$A20"; then
    ok "C39  a sealed LIVE transaction whose native member the platform tore down (worktree + branch, no hook) is claimed with ingress NativeMemberGone: the native member closes absent with its backup ref re-created, and the hand-rolled member is captured and removed"
else
    bad "C39  tx=[$T20] ext=$([ -e "$EXT20" ] && echo present || echo gone) out=${OUT:0:240}"
fi
# NEGATIVE CONTROL: a sealed live transaction whose native member is present and registered is untouched
A22="a00000000000rc22"
EXT22="$SANDBOX/other-wt/dev-opus-r22"
seal "$A22" dev-opus-r22 "$OTHER:$EXT22:dev-opus-r22"
R >/dev/null 2>&1
T22="$(T show --session-id "$SID" --agent-id "$A22" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("terminal"), d.get("state"))')"
[ "$T22" = "None sealed" ] && [ -d "$ENTITY/.claude/worktrees/agent-$A22" ] && [ -d "$EXT22" ] \
    && ok "C40  a sealed live transaction whose native member is present and registered is NOT claimed by the backstop (negative control)" || bad "C40  tx=[$T22]"

# --- 17. PERSISTENT BACKOFF: a transient failure is retried, later, forever;
# never abandoned, never handed to a person (landed review 2026-09-03, blocker 3)
A23="a00000000000rc23"
EXT23="$SANDBOX/other-wt/dev-opus-r23"
seal "$A23" dev-opus-r23 "$OTHER:$EXT23:dev-opus-r23"
T claim --session-id "$SID" --agent-id "$A23" --ingress SubagentStop >/dev/null
Q23="$(q "$EXT23" "$A23")"
OUT="$(PATH="$NOLS:$PATH" RICHOS_RECONCILE_BACKOFF_BASE=1000 R --agent "$SID/$A23" 2>&1)"
B23="$(T show --session-id "$SID" --agent-id "$A23" | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][1]; print(m["state"], m.get("attempts"), bool(m.get("retry_after_epoch")))')"
OUT2="$(RICHOS_RECONCILE_BACKOFF_BASE=1000 R --agent "$SID/$A23" 2>&1)"
B23b="$(T show --session-id "$SID" --agent-id "$A23" | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][1]; print(m["state"], m.get("attempts"))')"
S="$(RICHOS_RECONCILE_BACKOFF_BASE=1000 R --status)"; SRC=$?
if [ "$B23" = "quarantined 1 True" ] && [ "$B23b" = "quarantined 1" ] && printf '%s' "$OUT2" | grep -q 'in backoff until' && [ -d "$Q23" ] && [ "$SRC" -ne 0 ]; then
    ok "C42  a transient failure (git ls-files rejected) records attempt 1 and a retry time; the next run within the backoff SKIPS the member (quarantine kept, --status not done), no operator named"
else
    bad "C42  first=[$B23] second=[$B23b] status_rc=$SRC out2=${OUT2:0:160}"
fi
R --agent "$SID/$A23" >/dev/null 2>&1
[ "$(states "$A23")" = "removed removed " ] && ok "C42b ...and once the backoff has elapsed (base 0 here) the retry runs and the member completes" || bad "C42b states=$(states "$A23")"

# --- 18. git cannot read the native directory and no longer registers it: the
# native-gone backstop claims it and the RAW bytes are captured, verified and
# closed; the backup ref comes from head_at_seal (blocker 3, spec section 4)
A21="a00000000000rc21"
EXT21="$SANDBOX/other-wt/dev-opus-r21"
seal "$A21" dev-opus-r21 "$OTHER:$EXT21:dev-opus-r21"
NAT21="$ENTITY/.claude/worktrees/agent-$A21"
HEAD21="$(git -C "$NAT21" rev-parse HEAD)"
printf 'bytes git can no longer read\n' >"$NAT21/orphaned.txt"
rm -rf "$ENTITY/.git/worktrees/agent-$A21"      # the administrative directory is gone: git neither lists nor reads it
OUT="$(R 2>&1)"
T21="$(T show --session-id "$SID" --agent-id "$A21" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["members"]; print((d.get("terminal") or {}).get("ingress"), d.get("state"), m[0]["state"], m[0].get("git_unreadable"), m[0].get("capture_kind"), m[0].get("head_preserved"), m[1]["state"])')"
if [ "$T21" = "NativeMemberGone removed removed True raw-bytes backup-ref removed" ] && [ ! -e "$NAT21" ] && [ ! -e "$(q "$NAT21" "$A21")" ] && [ ! -e "$EXT21" ] \
   && [ "$(git -C "$ENTITY" rev-parse -q --verify "refs/richos/handoffs/$SID/$A21/worktree-agent-$A21")" = "$HEAD21" ] \
   && [ "$(tar -xOf "$SANDBOX/captures/$SID/$A21/member-0/tree.tar" orphaned.txt)" = "bytes git can no longer read" ]; then
    ok "C43  a native directory git can neither list nor read is claimed by the backstop, its RAW bytes captured and verified, the backup ref taken from head_at_seal, and it is removed; the hand-rolled member is retired too"
else
    bad "C43  tx=[$T21] native=$([ -e "$NAT21" ] && echo present || echo gone) out=${OUT:0:240}"
fi

# --- 19. the quarantine's HEAD moved after the backup ref was saved: the moved
# HEAD is preserved under <ref>@drift-1 and the member proceeds (blocker 3)
A24="a00000000000rc24"
seal "$A24" dev-opus-r24
NAT24="$ENTITY/.claude/worktrees/agent-$A24"
HEAD24="$(git -C "$NAT24" rev-parse HEAD)"
T claim --session-id "$SID" --agent-id "$A24" --ingress SubagentStop >/dev/null
Q24="$(q "$NAT24" "$A24")"
git -C "$Q24" commit -q --allow-empty -m 'moved after the ref was saved'
NEW24="$(git -C "$Q24" rev-parse HEAD)"
OUT="$(R --agent "$SID/$A24" 2>&1)"
REF24="refs/richos/handoffs/$SID/$A24/worktree-agent-$A24"
D24="$(T show --session-id "$SID" --agent-id "$A24" | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][0]; d=m.get("head_drift") or {}; print(m["state"], d.get("found"), d.get("ref"))')"
if [ "$D24" = "removed $NEW24 $REF24@drift-1" ] && [ "$(git -C "$ENTITY" rev-parse -q --verify "$REF24@drift-1")" = "$NEW24" ] \
   && [ "$(git -C "$ENTITY" rev-parse -q --verify "$REF24")" = "$HEAD24" ] && printf '%s' "$OUT" | grep -q 'moved from'; then
    ok "C44  a quarantine whose HEAD moved after the backup ref was saved: the moved HEAD is preserved under the drift ref, the original ref is untouched, the drift is recorded and the member is removed (INVERTED: provenance-contradicts-git used to park as FAILED)"
else
    bad "C44  member=[$D24] drift_ref=$(git -C "$ENTITY" rev-parse -q --verify "$REF24@drift-1" 2>/dev/null || echo none) out=${OUT:0:200}"
fi

# --- 20. something ELSE is registered at the original path: not ours, never
# touched; this member's quarantine still completes (blocker 3)
A25="a00000000000rc25"
EXT25="$SANDBOX/other-wt/dev-opus-r25"
seal "$A25" dev-opus-r25 "$OTHER:$EXT25:dev-opus-r25"
T claim --session-id "$SID" --agent-id "$A25" --ingress SubagentStop >/dev/null
Q25="$(q "$EXT25" "$A25")"
git -C "$OTHER" worktree add -q -b someone-else-later "$EXT25"     # a NEW worktree, prepared later, at the same path
printf 'a live worker lives here now\n' >"$EXT25/live.txt"
OUT="$(R --agent "$SID/$A25" 2>&1)"
F25="$(T show --session-id "$SID" --agent-id "$A25" | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][1]; print(m["state"], bool(m.get("foreign_worktree_at_original")))')"
if [ "$F25" = "removed True" ] && [ -f "$EXT25/live.txt" ] && git -C "$OTHER" worktree list --porcelain | grep -qx "worktree $EXT25" && [ ! -e "$Q25" ] \
   && printf '%s' "$OUT" | grep -q 'ANOTHER worktree'; then
    ok "C45  a worktree git registers at the original path is NOT this member's: recorded, never touched (its bytes intact, still registered); the member's own quarantine is captured and removed"
else
    bad "C45  member=[$F25] foreign=$([ -f "$EXT25/live.txt" ] && echo intact || echo DAMAGED) quar=$([ -e "$Q25" ] && echo present || echo gone) out=${OUT:0:200}"
fi
rm -rf "$EXT25"; git -C "$OTHER" worktree prune    # sandbox cleanup of the later worktree

# --- 21. a member an EARLIER revision left `failed` is re-derived from disk and
# completes; nothing waits for a person (blocker 3)
A26="a00000000000rc26"
seal "$A26" dev-opus-r26
T claim --session-id "$SID" --agent-id "$A26" --ingress SubagentStop >/dev/null
Q26="$(q "$ENTITY/.claude/worktrees/agent-$A26" "$A26")"
python3 - "$TX_PY" "$SID" "$A26" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tx", sys.argv[1]); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
with tx.tx_lock(sys.argv[2], sys.argv[3]):
    tx.update_member(sys.argv[2], sys.argv[3], 0, state="failed", error="both present (written by an earlier revision)")
PY
R --agent "$SID/$A26" >/dev/null 2>&1
L26="$(T show --session-id "$SID" --agent-id "$A26" | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"][0]; print(m["state"], m.get("rederived_from"))')"
[ "$L26" = "removed failed" ] && [ ! -e "$Q26" ] && ok "C46  a legacy FAILED member is re-derived from what exists on disk, re-enters the state machine and is removed" || bad "C46  member=[$L26] quar=$([ -e "$Q26" ] && echo present || echo gone)"

# --- 22. --status never calls an unexamined transaction live, and is NOT done
# over a sealed transaction whose native member is gone (CEO specification
# 2026-09-03, section 5). Measured: `sealed_live: 2, done: true` over a killed
# worker's leaked hand-rolled worktree.
A27="a00000000000rc27"
EXT27="$SANDBOX/other-wt/dev-opus-r27"
seal "$A27" dev-opus-r27 "$OTHER:$EXT27:dev-opus-r27"
NAT27="$ENTITY/.claude/worktrees/agent-$A27"
S="$(R --status)"; SRC=$?
V="$(printf '%s' "$S" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("sealed_live" in d, d["sealed_native_present"] >= 1, d["sealed_native_missing"], d["done"])')"
[ "$V" = "False True 0 True" ] && [ "$SRC" -eq 0 ] && ok "C47  a sealed transaction whose native member is present and registered is reported POSITIVELY present (there is no sealed_live key any more); status is done" || bad "C47  status=[$V] rc=$SRC"
git -C "$ENTITY" worktree remove --force "$NAT27" >/dev/null 2>&1     # the platform's teardown, no hook delivered
git -C "$ENTITY" branch -D "worktree-agent-$A27" >/dev/null 2>&1
S="$(R --status)"; SRC=$?
V="$(printf '%s' "$S" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sealed_native_missing"], d["definition_of_done"]["sealed_transactions_whose_native_member_is_gone"], d["done"])')"
[ "$V" = "1 1 False" ] && [ "$SRC" -ne 0 ] && [ -d "$EXT27" ] \
    && ok "C47b ...with the native member torn down, --status (no run) reports sealed_native_missing=1, is NOT done, exits 1 — the orphan is named, not called live (INVERTED: it used to say done: true over exactly this)" || bad "C47b status=[$V] rc=$SRC"
R >/dev/null 2>&1
S="$(R --status)"; SRC=$?
[ "$SRC" -eq 0 ] && [ ! -e "$EXT27" ] && [ "$(states "$A27")" = "removed removed " ] && ok "C47c ...and after one reconciler run the backstop has retired it and status is done again" || bad "C47c rc=$SRC states=$(states "$A27")"

# --- 23. THE HARNESS LOCK. Measured on this machine 2026-09-04: 30 verified
# members could not be removed because `git worktree remove --force` refuses a
# LOCKED worktree, and the lock names the SESSION pid, so it is released when
# Claude Code exits and never when an agent finishes. Every one of them was
# reported as a normal retry with a backoff doubling to six hours.
#
# The lock is released HERE, on this member's own quarantine, under five
# preconditions read at the instant of the act — and refused otherwise. Every
# refusal below is proven by a POSITIVE PROBE: the same fixture completes once
# the single refused precondition is repaired, so the case can never pass
# because the fixture was broken.
lock_as() { git -C "$ENTITY" worktree lock --reason "claude agent agent-$2 (pid $$ start Fri Sep  4 06:50:17 2026)" "$1"; }
member_field() { T show --session-id "$SID" --agent-id "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['members'][0].get('$2'))"; }
tamper() { python3 - "$TX_PY" "$SID" "$1" "$2" "$3" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tx", sys.argv[1]); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
with tx.tx_lock(sys.argv[2], sys.argv[3]):
    tx.update_member(sys.argv[2], sys.argv[3], 0, **{sys.argv[4]: sys.argv[5] if sys.argv[5] != "__NONE__" else None})
PY
}

# 23a. MUST BE REMOVED: locked by this member's own agent, on its own
# quarantine, with an unlanded commit and untracked evidence to lose.
A28="a00000000000rc28"
seal "$A28" dev-opus-r28
NAT28="$ENTITY/.claude/worktrees/agent-$A28"; Q28="$(q "$NAT28" "$A28")"
printf 'unlanded\n' >"$NAT28/work.txt"; git -C "$NAT28" add work.txt; git -C "$NAT28" commit -q -m 'unlanded work'
printf 'never committed\n' >"$NAT28/scratch.txt"
HEAD28="$(git -C "$NAT28" rev-parse HEAD)"
lock_as "$NAT28" "$A28"
T claim --session-id "$SID" --agent-id "$A28" --ingress SubagentStop >/dev/null
R --agent "$SID/$A28" >/dev/null 2>&1
[ "$(states "$A28")" = "removed " ] && [ ! -e "$Q28" ] && [ ! -e "$NAT28" ] \
    && ok "C48  a quarantine LOCKED by its own agent is removed (before this revision it retried forever: 30 stuck members, backoff at 21600s)" \
    || bad "C48  states=$(states "$A28") quar=$([ -e "$Q28" ] && echo present || echo gone)"
[ "$(git -C "$ENTITY" rev-parse -q --verify "refs/richos/handoffs/$SID/$A28/worktree-agent-$A28")" = "$HEAD28" ] \
    && ok "C49  ...and the unlanded commit is still reachable under the backup ref (breaking a lock never costs a commit)" || bad "C49  backup ref"
X28="$SANDBOX/extract28"; mkdir -p "$X28"; tar -xf "$SANDBOX/captures/$SID/$A28/member-0/tree.tar" -C "$X28" 2>/dev/null
[ "$(cat "$X28/scratch.txt" 2>/dev/null)" = "never committed" ] \
    && ok "C50  ...and the never-committed file survives byte-for-byte in the verified archive" || bad "C50  archive missing scratch.txt"
LB="$(member_field "$A28" lock_broken_line)"
case "$LB" in *"claude agent agent-$A28"*) ok "C51  ...and the exact lock line that was broken is recorded on the member as evidence" ;; *) bad "C51  lock_broken_line=[$LB]" ;; esac

# 23b. P4 — a lock signed by ANOTHER agent is never broken. The positive probe
# re-signs the same lock with the right agent and the member completes.
A29="a00000000000rc29"
seal "$A29" dev-opus-r29
NAT29="$ENTITY/.claude/worktrees/agent-$A29"; Q29="$(q "$NAT29" "$A29")"
lock_as "$NAT29" "a0000000000FOREIGN"
T claim --session-id "$SID" --agent-id "$A29" --ingress SubagentStop >/dev/null
R --agent "$SID/$A29" >/dev/null 2>&1
[ "$(states "$A29")" = "verified " ] && [ -d "$Q29" ] && [ "$(member_field "$A29" blocked)" = "True" ] \
    && ok "C52  P4: a quarantine locked by ANOTHER agent is NOT removed; the directory stands and the member is recorded blocked" \
    || bad "C52  states=$(states "$A29") quar=$([ -d "$Q29" ] && echo present || echo gone) blocked=$(member_field "$A29" blocked)"
case "$(member_field "$A29" blocked_reason)" in *"P4"*) ok "C53  ...and the recorded reason names the precondition that refused (P4), not a generic failure" ;; *) bad "C53  reason=[$(member_field "$A29" blocked_reason)]" ;; esac
S="$(R --status)"
printf '%s' "$S" | python3 -c 'import json,sys; d=json.load(sys.stdin); dd=d["definition_of_done"]; sys.exit(0 if dd["members_blocked_on_a_condition_waiting_cannot_clear"] >= 1 and d["done"] is False else 1)' \
    && ok "C54  ...and --status reports it BLOCKED, counted apart from pending normal retry (the false-green of wiki §5: a deadlock filed as a retry)" || bad "C54  status=$S"
git -C "$ENTITY" worktree unlock "$Q29" >/dev/null 2>&1; lock_as "$Q29" "$A29"
R --agent "$SID/$A29" >/dev/null 2>&1
[ "$(states "$A29")" = "removed " ] && [ ! -e "$Q29" ] && [ "$(member_field "$A29" blocked)" = "False" ] \
    && ok "C55  POSITIVE PROBE: re-signing that same lock with the right agent completes the member and clears the blocked flag — C52 refused for the reason it names, not because the fixture was broken" \
    || bad "C55  states=$(states "$A29") blocked=$(member_field "$A29" blocked)"

# 23c. P4 — a lock with NO reason names nobody, so it cannot be proven to be
# this agent's own. Fail closed.
A30="a00000000000rc30"
seal "$A30" dev-opus-r30
NAT30="$ENTITY/.claude/worktrees/agent-$A30"; Q30="$(q "$NAT30" "$A30")"
git -C "$ENTITY" worktree lock "$NAT30"
T claim --session-id "$SID" --agent-id "$A30" --ingress SubagentStop >/dev/null
R --agent "$SID/$A30" >/dev/null 2>&1
[ "$(states "$A30")" = "verified " ] && [ -d "$Q30" ] \
    && ok "C56  P4: an UNSIGNED lock (no reason) is never broken — a lock nobody signed cannot be shown to be this agent's own" \
    || bad "C56  states=$(states "$A30")"
git -C "$ENTITY" worktree unlock "$Q30" >/dev/null 2>&1; lock_as "$Q30" "$A30"
R --agent "$SID/$A30" >/dev/null 2>&1
[ "$(states "$A30")" = "removed " ] && ok "C57  POSITIVE PROBE: the same fixture, signed, completes" || bad "C57  states=$(states "$A30")"

# 23d. P1 — no verified archive on disk, no lock break. The block itself is the
# pause that lets the archive be removed between runs.
A31="a00000000000rc31"
seal "$A31" dev-opus-r31
NAT31="$ENTITY/.claude/worktrees/agent-$A31"; Q31="$(q "$NAT31" "$A31")"
lock_as "$NAT31" "a0000000000FOREIGN"
T claim --session-id "$SID" --agent-id "$A31" --ingress SubagentStop >/dev/null
R --agent "$SID/$A31" >/dev/null 2>&1        # parks at verified, blocked on P4
rm -rf "$SANDBOX/captures/$SID/$A31"
git -C "$ENTITY" worktree unlock "$Q31" >/dev/null 2>&1; lock_as "$Q31" "$A31"
R --agent "$SID/$A31" >/dev/null 2>&1
[ "$(states "$A31")" = "verified " ] && [ -d "$Q31" ] \
    && case "$(member_field "$A31" blocked_reason)" in *"P1"*) true ;; *) false ;; esac \
    && ok "C58  P1: with the verified archive gone from disk, the lock is NOT broken — the bytes are no longer provably preserved" \
    || bad "C58  states=$(states "$A31") reason=[$(member_field "$A31" blocked_reason)]"

# 23e. P5 — one preservation layer is not two.
A32="a00000000000rc32"
seal "$A32" dev-opus-r32
NAT32="$ENTITY/.claude/worktrees/agent-$A32"; Q32="$(q "$NAT32" "$A32")"
lock_as "$NAT32" "a0000000000FOREIGN"
T claim --session-id "$SID" --agent-id "$A32" --ingress SubagentStop >/dev/null
R --agent "$SID/$A32" >/dev/null 2>&1
tamper "$A32" backup_ref __NONE__
git -C "$ENTITY" worktree unlock "$Q32" >/dev/null 2>&1; lock_as "$Q32" "$A32"
R --agent "$SID/$A32" >/dev/null 2>&1
[ "$(states "$A32")" = "verified " ] && [ -d "$Q32" ] \
    && case "$(member_field "$A32" blocked_reason)" in *"P5"*) true ;; *) false ;; esac \
    && ok "C59  P5: with no backup ref, the lock is NOT broken — both preservation layers must be intact, not one" \
    || bad "C59  states=$(states "$A32") reason=[$(member_field "$A32" blocked_reason)]"

# 23f. P3 — THE ONE THAT MATTERS MOST. The lock break can never be aimed at
# anything but this member's own canonical quarantine name. Here the member's
# recorded quarantine is repointed at a DIFFERENT registered, locked worktree
# — the shape of every live-agent eviction in this record's history — and the
# name check refuses it even though the lock is correctly signed for this agent.
A33="a00000000000rc33"
seal "$A33" dev-opus-r33
NAT33="$ENTITY/.claude/worktrees/agent-$A33"; Q33="$(q "$NAT33" "$A33")"
lock_as "$NAT33" "a0000000000FOREIGN"
T claim --session-id "$SID" --agent-id "$A33" --ingress SubagentStop >/dev/null
R --agent "$SID/$A33" >/dev/null 2>&1
DECOY="$ENTITY/.claude/worktrees/agent-$A33.not-a-quarantine"
# Sign the lock correctly FIRST, so P3 is the only precondition left standing.
git -C "$ENTITY" worktree unlock "$Q33" >/dev/null 2>&1; lock_as "$Q33" "$A33"
mv "$Q33" "$DECOY"; git -C "$ENTITY" worktree repair "$DECOY" >/dev/null 2>&1
tamper "$A33" quarantine "$DECOY"
R --agent "$SID/$A33" >/dev/null 2>&1
[ "$(states "$A33")" = "verified " ] && [ -d "$DECOY" ] \
    && case "$(member_field "$A33" blocked_reason)" in *"P3"*) true ;; *) false ;; esac \
    && ok "C60  P3: a correctly-signed lock on a path that is NOT this member's canonical quarantine name is refused — the break cannot be aimed anywhere else" \
    || bad "C60  states=$(states "$A33") dir=$([ -d "$DECOY" ] && echo present || echo gone) reason=[$(member_field "$A33" blocked_reason)]"
mv "$DECOY" "$Q33"; git -C "$ENTITY" worktree repair "$Q33" >/dev/null 2>&1
tamper "$A33" quarantine "$Q33"
R --agent "$SID/$A33" >/dev/null 2>&1
[ "$(states "$A33")" = "removed " ] && ok "C61  POSITIVE PROBE: restored to its canonical quarantine name, the same locked member completes" || bad "C61  states=$(states "$A33")"

# 23g. A BLOCKED MEMBER DOES NOT COMPOUND ITS BACKOFF. Doubling suits a
# transient condition recovering gradually; a blocked one changes
# discontinuously, and compounding means a repair goes unnoticed for hours.
# Measured 2026-09-04: thirty blocked members had reached 21600s, so the fix
# for them would have read as not working for most of a working day.
A34="a00000000000rc34"
seal "$A34" dev-opus-r34
NAT34="$ENTITY/.claude/worktrees/agent-$A34"; Q34="$(q "$NAT34" "$A34")"
lock_as "$NAT34" "a0000000000FOREIGN"
T claim --session-id "$SID" --agent-id "$A34" --ingress SubagentStop >/dev/null
RICHOS_RECONCILE_BACKOFF_BASE=60 R --agent "$SID/$A34" >/dev/null 2>&1
RA1="$(member_field "$A34" retry_after)"
tamper "$A34" retry_after_epoch 0
RICHOS_RECONCILE_BACKOFF_BASE=60 R --agent "$SID/$A34" >/dev/null 2>&1
RA2="$(member_field "$A34" retry_after)"; AT2="$(member_field "$A34" attempts)"
case "$RA1|$RA2|$AT2" in
    *"+ 60s|"*"+ 60s|2") ok "C62  a blocked member is retried at the base interval on every attempt (attempt 2 is still + 60s, NOT the + 120s the doubling rule would give); the attempt count still climbs" ;;
    *) bad "C62  first=[$RA1] second=[$RA2] attempts=$AT2" ;;
esac
case "$RA2" in *"+ 120s"*) bad "C63  the doubled value is present: [$RA2]" ;; *) ok "C63  ...and the doubled value the old rule would have written is absent" ;; esac

# 24. THE SPARSIFIED SHELL IS STILL FULLY CAPTURED — the positive probe for
# property 4 of the never-read-shell ruling (scripts/lib/shell-worktree-sparse.py).
# A cross-repository teammate's native worktree is de-materialized at seal. It
# should never be written to; the system must not depend on manners. So write
# into one anyway — at the root and inside a directory sparse-checkout
# skipped — and require the bytes back out of the archive.
mkdir -p "$ENTITY/qa-audits/run"
for i in 1 2 3 4; do head -c 51200 /dev/urandom | base64 >"$ENTITY/qa-audits/run/shot-$i.b64"; done
git -C "$ENTITY" add qa-audits          # a pathspec: by now the fixture has quarantines beside it
git -C "$ENTITY" commit -q -m "qa-audits, the 202 MB of the measurement"
FULL_KB="$(du -sk "$ENTITY/qa-audits" | cut -f1)"
A35="a00000000000rc35"
EXT35="$SANDBOX/other-wt/dev-opus-r35"
seal "$A35" dev-opus-r35 "$OTHER:$EXT35:dev-opus-r35"
NAT35="$ENTITY/.claude/worktrees/agent-$A35"
SHELL_KB="$(du -sk "$NAT35" | cut -f1)"
SPARSE35="$(member_field "$A35" sparse)"
printf 'evidence the shell should never have had\n' >"$NAT35/STRAY.md"
mkdir -p "$NAT35/qa-audits/run"
printf 'written after sparsification, into a skipped directory\n' >"$NAT35/qa-audits/run/late.txt"
T claim --session-id "$SID" --agent-id "$A35" --ingress SubagentStop >/dev/null
R >/dev/null 2>&1
CAP35="$SANDBOX/captures/$SID/$A35/member-0"
X35="$SANDBOX/extract35"; mkdir -p "$X35"; tar -xf "$CAP35/tree.tar" -C "$X35" 2>/dev/null
if [ "$(cat "$X35/STRAY.md" 2>/dev/null)" = "evidence the shell should never have had" ] \
   && [ "$(cat "$X35/qa-audits/run/late.txt" 2>/dev/null)" = "written after sparsification, into a skipped directory" ]; then
    ok "C64  POSITIVE PROBE: a file written into a SPARSIFIED shell — at the root and inside a skipped directory — is archived byte-for-byte"
else
    bad "C64  extracted: $(find "$X35" -type f 2>/dev/null | sed "s|$X35/||" | tr '\n' ' ')"
fi
TAR_KB="$(du -sk "$CAP35/tree.tar" | cut -f1)"
if [ ! -e "$X35/qa-audits/run/shot-1.b64" ] && [ "$TAR_KB" -lt "$FULL_KB" ] && [ "$SHELL_KB" -lt "$FULL_KB" ]; then
    ok "C65  the saving lands on the ARCHIVE too and no archive code changed: the de-materialized bytes are absent, tree.tar is ${TAR_KB}K against ${FULL_KB}K of tracked screenshots (live shell ${SHELL_KB}K)"
else
    bad "C65  tar=${TAR_KB}K full=${FULL_KB}K shell=${SHELL_KB}K shot present=$([ -e "$X35/qa-audits/run/shot-1.b64" ] && echo YES || echo NO)"
fi
[ "$(states "$A35")" = "removed removed " ] && printf '%s' "$SPARSE35" | grep -q "True" \
    && ok "C66  the sparsified member runs the whole lifecycle unchanged: quarantined -> captured -> verified -> unregistered -> removed" \
    || bad "C66  states=$(states "$A35") sparse=[$SPARSE35]"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== reconcile-terminal-worktrees tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== reconcile-terminal-worktrees tests: all $PASS passed ==="

if [ -f "$SCRIPT_DIR/reconcile-terminal-worktrees.mutation.sh" ]; then
    bash "$SCRIPT_DIR/reconcile-terminal-worktrees.mutation.sh" || exit 1
fi
exit 0
