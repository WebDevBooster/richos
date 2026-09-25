#!/usr/bin/env bash
#
# operator-fences.test.sh: THE FENCE SUITE. The land lease (land-lease.sh), the
# Git fence (the launcher scripts/lib/operator-fence-launcher.sh and the fence in
# scripts/lib/operator_fences.py), the switch and its installer
# (operator-fences.sh, scripts/lib/operator_fences_admin.py), the restore intent
# in mega-lander/workspaces.py and the product lander's wait in mega-lander/app.py.
#
# Spec: richos-hq docs/plans/2026-09-24-operator-back-end-spec-r3.md (e1, e2, e7,
# e8), with Frank's G1-G12 on top. Every case runs in a scratch repository with a
# bare origin, through the operator's own global Git dispatcher when it exists
# (spec e2: "through his global dispatcher"), ONCE PER GIT: Homebrew git and Apple
# git where both are installed, because Frank measured the fence's decisions on
# both and they are the two this Mac runs. Under Apple git, PATH puts /usr/bin
# first, so the launcher runs the fence under /usr/bin/python3 (3.9), which is the
# oldest interpreter it can meet.
#
# Sessions are fixture processes (scripts/lib/operator-fences-fixture.sh): A and
# B are Claude sessions with their own session records; X is a stand-in Codex, a
# copy of bash at a fixture path declared as LAND_LEASE_HOLDERS' codex, with no
# session record, so a land from it has no `claude` anywhere in its tree.
#
#   F1   a conflicting merge into main without the lease is refused before the
#        tree is touched: no MERGE_HEAD, status unchanged, main unchanged (G1)
#   F2   --no-ff and --ff-only without the lease: refused, main unchanged (G1)
#   F3   reset --hard and --soft without the lease: refused (G1)
#   F4   a commit on main without the lease: refused at the move (e2)
#   F5   a linked worktree's commit and merge on its own branch: pass, no lease
#   F6   the lease holder's commit, merge and push: pass
#   F7   ref packing without a lease: pack-refs, gc, maintenance pack-refs and an
#        auto-maintenance run triggered by a worktree commit all pass (F2)
#   F8   update-ref of main to its current value, no old value given: pass (F2)
#   F9   deleting main while loose = packed, without the lease: refused (G4)
#   F10  the engine's create-only restore of a deleted main passes through its
#        restore intent; a restore with no intent, or to another value, is
#        refused (G3)
#   F11  switching the main checkout away from main, or detaching it, without
#        the lease: refused; with it: pass; switching back to main: pass;
#        `git worktree add` from the main checkout: pass (Frank §4 (B))
#   F12  `git merge --abort` without the lease: refused, the merge intact (G1)
#   F13  a conflicted cherry-pick is NOT stopped by the fence (stated), its
#        starter is recorded, its commit is refused and recorded, and only the
#        lease holder may abort it once it is orphaned, after preserving it; a
#        live starter's is never aborted (G1 point 4, G5, G6)
#   F14  refusals are recorded; the forensic recorder runs on refused
#        transactions and still names Git as the writer
#   F15  `git -c core.hooksPath=/dev/null` is not fenced: stated, and asserted,
#        so nobody believes the engine's own integrate is (G2)
#   F16  a declared non-Claude holder (the Codex stand-in) acquires, lands and
#        releases from a tree with no claude in it; a lead waits on it; a
#        --holder-pid that is not an ancestor is refused (F1)
#   F17  a non-Claude lease past its time is taken at rest; not at rest it stays
#        held and names the takeover, which preserves first (e1, G5)
#   F18  the default wait is 90 s; a wait above 540 s is refused (G7)
#   F19  a caller whose lease home differs from the launcher's is refused (G10)
#   F20  WITH THE SWITCH OFF NOTHING IS REFUSED: every refused operation above
#        passes, a crashing fence program changes nothing, the lease commands are
#        no-ops, and a twin repository without the launcher behaves identically
#   F21  with the switch on, a fence that cannot decide refuses and names
#        `operator-fences.sh off` (e8)
#   F22  status, on and off against the declaration (e8, G12)
#   F23  uninstall restores the repository's previous hook
#   F24  install moves the existing hook into the chain and keeps the state
#   F25  a dead Claude holder's lease: taken at rest, takeover otherwise
#   F26  install-ref-forensics.sh installs into the chain, never over the launcher
#   F27  the product lander's land_lock() waits on a live lease (G2)
#        and a hook that is not UTF-8 reads as no lease, never an exception (#13)
#   F28  a lease naming a live pid with another start time is dead: a recycled
#        pid is never mistaken for the holder
#   F29  a live, in-time lease cannot be taken over (G5)
#   F3L, F12L  measured limits, asserted so the record goes red if Git changes:
#        a refused reset --hard and a refused merge --abort have already
#        rewritten the tree (the early check exists for exactly these)
#   M    the mutation harness runs as its own unit: operator-fences-mutation.test.sh
#
# Usage: scripts/operator-fences.test.sh
# Exit 0 = every case passed under every git found.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/operator-fences-fixture.sh
. "$ENGINE_ROOT/scripts/lib/operator-fences-fixture.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -12; FAIL=$((FAIL + 1)); return 0; }
expect() { # <id> <description> <condition-rc> [detail]
    if [ "$3" = 0 ]; then ok "$1 $2"; else bad "$1 $2" "${4:-}"; fi
}

ORIG_PATH="$PATH"
ofx_init || { echo "cannot create the fixture"; exit 1; }
trap ofx_cleanup EXIT
echo "=== operator-fences: the lease, the fence and the switch (dispatcher: $OFX_DISPATCHER) ==="

LEASE="$ENGINE_ROOT/scripts/land-lease.sh"
FENCES="$ENGINE_ROOT/scripts/operator-fences.sh"
RECORDER="$ENGINE_ROOT/scripts/hooks/ref-transaction-forensics.sh"

GITS=""; GITS_SEEN=""
for d in ${OPERATOR_FENCES_GITS:-/opt/homebrew/bin /usr/bin}; do
    [ -x "$d/git" ] || continue
    v="$("$d/git" --version 2>/dev/null)" || continue
    case " $GITS_SEEN " in *" $v "*) continue ;; esac
    GITS_SEEN="${GITS_SEEN:-} $v"
    GITS="$GITS $d"
done
[ -n "$GITS" ] || { echo "no git found"; exit 1; }

rev() { git -C "$1" rev-parse -q --verify "$2" 2>/dev/null; }
sym() { git -C "$1" symbolic-ref -q HEAD 2>/dev/null; }
lease_file() { ls "$OFX/locks/"*.lease 2>/dev/null | head -1; }

N=0
for GDIR in $GITS; do
N=$((N + 1))
export PATH="$GDIR:$ORIG_PATH"
G="$(git --version | awk '{print $3}')"
echo "--- git $G ($GDIR/git), python3 $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])') ---"

# ---- setup -------------------------------------------------------------------
ofx_declare on
ofx_repo "r$N"; R="$OFX_R"
cp "$RECORDER" "$R/.git/hooks/reference-transaction"; chmod +x "$R/.git/hooks/reference-transaction"
out="$(ofx_install "$R" 2>&1)"; rc=$?
chain="$R/.git/hooks/reference-transaction.d"
[ $rc = 0 ] && cmp -s "$RECORDER" "$chain/20-ref-transaction-forensics.sh" \
    && grep -q 'richos-operator-fence-launcher' "$R/.git/hooks/reference-transaction" \
    && grep -q '^OPERATOR_FENCES_STATE="off"$' "$R/.git/hooks/reference-transaction"
expect "F24" "[git $G] install moves the recorder into the chain, writes the launcher, starts OFF" "$?" "$out"
ofx_install "$R" >/dev/null 2>&1
out="$(ofx_on "$R" 2>&1)"; rc=$?
[ $rc = 0 ] && ofx_install "$R" >/dev/null 2>&1 && grep -q '^OPERATOR_FENCES_STATE="on"$' "$R/.git/hooks/reference-transaction"
expect "F24" "[git $G] a second install is idempotent and keeps the state ON" "$?" "$out"

W="$OFX/w$N"
git -C "$R" worktree add -q -b feat "$W" >/dev/null 2>&1
rc=$?; [ $rc = 0 ] && [ -f "$W/f.txt" ] && [ "$(sym "$R")" = "refs/heads/main" ]
expect "F11" "[git $G] 'git worktree add' from the main checkout passes without a lease" "$?"
( cd "$W" && printf 'feat\n' > g.txt && git add g.txt && git commit -q -m feat ) >/dev/null 2>&1
expect "F5" "[git $G] a linked worktree's commit on its own branch passes without a lease" "$?"
( cd "$W" && git switch -q -c clash main && printf 'clash\n' > f.txt && git commit -q -am clash \
  && git switch -q -c ffb main && printf 'ff\n' > ff.txt && git add ff.txt && git commit -q -m ff && git switch -q feat ) >/dev/null 2>&1
CLASH="$(rev "$R" clash)"; FFB="$(rev "$R" ffb)"

ofx_session A; ofx_session B
PID_A="$(cat "$OFX/s/A.pid")"

ofx_in A "$(ofx_lease acquire --repo "$R")"; rc=$?
[ $rc = 0 ] && printf '%s' "$OFX_OUT" | grep -q "ACQUIRED"
expect "F6" "[git $G] a Claude session acquires the free lease" "$?" "$OFX_OUT"
ofx_in A "cd '$R' && printf 'ours\n' > f.txt && git commit -q -am ours && git push -q origin main"
expect "F6" "[git $G] the lease holder commits on main and pushes" "$?" "$OFX_OUT"
ofx_in A "$(ofx_lease release --repo "$R")"; rc=$?
[ $rc = 0 ] && [ -z "$(lease_file)" ]
expect "F6" "[git $G] release removes the holder's lease" "$?" "$OFX_OUT"

# ---- G1: refused before the tree is touched ------------------------------------
M0="$(rev "$R" main)"; S0="$(git -C "$R" status --porcelain --untracked-files=no)"
ofx_in B "git -C '$R' merge -q clash -m m"; rc=$?
[ $rc -ne 0 ] && [ ! -f "$R/.git/MERGE_HEAD" ] && [ "$(rev "$R" main)" = "$M0" ] \
    && [ "$(git -C "$R" status --porcelain --untracked-files=no)" = "$S0" ] && grep -qx 'ours' "$R/f.txt" \
    && printf '%s' "$OFX_OUT" | grep -q "ORIG_HEAD"
expect "F1" "[git $G] a conflicting merge without the lease is refused: no MERGE_HEAD, tree and main unchanged" "$?" "rc=$rc $OFX_OUT"
ofx_in B "git -C '$R' merge -q --no-ff feat -m m"; rc1=$?
ofx_in B "git -C '$R' merge -q --ff-only ffb"; rc2=$?
[ $rc1 -ne 0 ] && [ $rc2 -ne 0 ] && [ "$(rev "$R" main)" = "$M0" ] && [ ! -f "$R/ff.txt" ]
expect "F2" "[git $G] --no-ff and --ff-only merges without the lease are refused, main unchanged" "$?" "rc=$rc1/$rc2"
ofx_in B "git -C '$R' reset -q --hard HEAD~1"; rc1=$?
[ $rc1 -ne 0 ] && [ "$(rev "$R" main)" = "$M0" ]
expect "F3" "[git $G] reset --hard without the lease is refused and main does not move" "$?" "rc=$rc1"
# THE MEASURED LIMIT behind the early check's `reset` (as-built deviation from
# G1): Git rewrites the index and tree BEFORE it writes ORIG_HEAD, so a refused
# reset --hard has already reset the shared tree. If Git ever stops doing that,
# this case goes red and the record describing it is stale.
grep -qx 'base' "$R/f.txt"
expect "F3L" "[git $G] (measured limit) the refused reset --hard had already rewritten the tree; only the early check stops that" "$?"
git -C "$R" restore --source=HEAD --staged --worktree -- . >/dev/null 2>&1
ofx_in B "git -C '$R' reset -q --soft HEAD~1"; rc2=$?
[ $rc2 -ne 0 ] && [ "$(rev "$R" main)" = "$M0" ] && [ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ]
expect "F3" "[git $G] reset --soft without the lease is refused, main and tree unchanged" "$?" "rc=$rc2"
ofx_in B "cd '$R' && printf 'x\n' > h.txt && git add h.txt && git commit -q -m x"; rc=$?
[ $rc -ne 0 ] && [ "$(rev "$R" main)" = "$M0" ] && printf '%s' "$OFX_OUT" | grep -q "a move of main"
expect "F4" "[git $G] a commit on main without the lease is refused at the move" "$?" "rc=$rc $OFX_OUT"
git -C "$R" restore --staged h.txt >/dev/null 2>&1; rm -f "$R/h.txt"
ofx_in B "cd '$W' && git merge -q --no-ff ffb -m wt"; rc=$?
expect "F5" "[git $G] a linked worktree's merge on its own branch passes without a lease" "$rc" "$OFX_OUT"

# ---- F14: refusals recorded, recorder ran on the refused transactions ----------
REF="$OFX/locks/fence-refusals.jsonl"
python3 - "$REF" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
ok = any(r["ref"] == "ORIG_HEAD" and (r.get("caller") or {}).get("session_id") == "B" for r in rows)
sys.exit(0 if ok else 1)
PY
expect "F14" "[git $G] a refusal is recorded with the caller's session and the refused update" "$?"
python3 - "$OFX/forensics/ref-transactions.jsonl" "$R/.git" "$M0" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if sys.argv[2] in l]
orig = [r for r in rows if r["ref"] == "ORIG_HEAD"]
# The REFUSED transactions: B's merges and resets wrote ORIG_HEAD = main's tip M0,
# and nothing before this point wrote that value successfully (the setup's own
# ORIG_HEAD rows, from `git worktree add`, carry other values). So the prepared
# rows carrying M0 exist only if the chain ran on the refused transactions.
prep = [r for r in orig if r["phase"] == "prepared" and r["new"] == sys.argv[3]]
ab = [r for r in orig if r["phase"] == "aborted"]
writer_is_git = bool(prep) and all(r["writer_cmd"].split()[0].endswith("git") for r in prep)
sys.exit(0 if prep and ab and writer_is_git else 1)
PY
expect "F14" "[git $G] the recorder logs refused transactions (prepared and aborted) and names Git as the writer" "$?"

# ---- F6: the holder lands ---------------------------------------------------------
ofx_in A "$(ofx_lease acquire --repo "$R") && git -C '$R' merge -q --no-ff feat -m land && git -C '$R' push -q origin main && $(ofx_lease release --repo "$R")"
expect "F6" "[git $G] acquire, merge --no-ff, push, release: the whole land passes" "$?" "$OFX_OUT"

# ---- F7/F8/F9: packing is not a move; a deletion is ------------------------------
ofx_in B "git -C '$R' pack-refs --all"; rc=$?
[ $rc = 0 ] && [ ! -f "$R/.git/refs/heads/main" ] && [ -n "$(rev "$R" main)" ]
expect "F7" "[git $G] pack-refs --all passes without a lease (and really packed main)" "$?" "$OFX_OUT"
M1="$(rev "$R" main)"
ofx_in B "git -C '$R' update-ref refs/heads/main $M1"; rc=$?
[ $rc = 0 ] && [ "$(rev "$R" main)" = "$M1" ]
expect "F8" "[git $G] update-ref of main to its current value, no old value: passes" "$?" "$OFX_OUT"
ofx_in B "git -C '$R' gc -q"; rc1=$?
ofx_in B "git -C '$R' maintenance run --task=pack-refs"; rc2=$?
[ $rc1 = 0 ] && [ $rc2 = 0 ] && [ "$(rev "$R" main)" = "$M1" ]
expect "F7" "[git $G] gc and maintenance run --task=pack-refs pass without a lease" "$?" "rc=$rc1/$rc2 $OFX_OUT"
# Fixture setup through the documented bypass (F15), never through the fence:
# a real move writes a loose ref, which gives the packing cases something to pack.
loosen() { git -C "$R" -c core.hooksPath=/dev/null update-ref refs/heads/main "$M1~1" >/dev/null 2>&1 \
           && git -C "$R" -c core.hooksPath=/dev/null update-ref refs/heads/main "$M1" >/dev/null 2>&1; }
loosen
# Measured (both gits): a worktree commit with maintenance.auto runs
# `git maintenance run --auto`, whose gc runs `git pack-refs --all --prune --auto`
# as a grandchild. gc.auto=0 in the fixture's config disables that, so it is
# re-enabled per command; two packs over gc.autoPackLimit=1 make gc run; and
# pack-refs --auto packs only past a count of loose refs, so forty are made.
git -C "$R" repack -q >/dev/null 2>&1; ( cd "$W" && git commit --allow-empty -q -m pack2 ) >/dev/null 2>&1
git -C "$R" repack -q >/dev/null 2>&1
i=0; while [ $i -lt 40 ]; do i=$((i + 1)); git -C "$R" update-ref "refs/heads/loose$i" "$M1" >/dev/null 2>&1; done
ofx_in B "cd '$W' && git -c gc.auto=6700 -c gc.autoPackLimit=1 -c maintenance.auto=true -c gc.autoDetach=false -c maintenance.autoDetach=false commit --allow-empty -q -m auto"; rc=$?
if [ -f "$R/.git/refs/heads/main" ]; then
    bad "F7 [git $G] auto-maintenance fixture did not pack main, so the case proves nothing" "$OFX_OUT"
else
    expect "F7" "[git $G] auto-maintenance triggered by a worktree commit packs main and passes" "$rc" "$OFX_OUT"
fi
loosen
git -C "$R" pack-refs --all --no-prune >/dev/null 2>&1
if [ -f "$R/.git/refs/heads/main" ] && grep -q " refs/heads/main$" "$R/.git/packed-refs"; then
    ofx_in B "git -C '$R' update-ref -d refs/heads/main"; rc=$?
    [ $rc -ne 0 ] && [ "$(rev "$R" main)" = "$M1" ] && printf '%s' "$OFX_OUT" | grep -q "deletion of main"
    expect "F9" "[git $G] deleting main while loose = packed, without the lease, is refused" "$?" "rc=$rc $OFX_OUT"
else
    bad "F9 [git $G] the fixture did not reach loose = packed, so the case proves nothing"
fi

# ---- F10: the create-only restore (G3) --------------------------------------------
TIP="$(rev "$R" main)"
ofx_in A "$(ofx_lease acquire --repo "$R") && git -C '$R' update-ref -d refs/heads/main"; rc=$?
if [ $rc = 0 ] && [ -z "$(rev "$R" main)" ] && [ ! -e "$R/.git/logs/refs/heads/main" ]; then
    RESTORE="import sys; sys.path.insert(0, '$ENGINE_ROOT/mega-lander'); import workspaces as W; rc, o, e = W._recreate_deleted_ref('$R', 'main', sys.argv[1], 'fixture'); sys.stderr.write(e); sys.exit(rc)"
    ofx_in B "python3 -c \"$RESTORE\" $TIP"; rc=$?
    [ $rc = 0 ] && [ "$(rev "$R" main)" = "$TIP" ] && [ -z "$(ls "$OFX/locks/restore-intents" 2>/dev/null)" ]
    expect "F10" "[git $G] the engine's create-only restore of a deleted main (reflog gone) passes, no lease, and its intent is removed" "$?" "rc=$rc $OFX_OUT"
    ofx_in A "git -C '$R' update-ref -d refs/heads/main"
    ofx_in B "git -C '$R' update-ref -m x --no-deref refs/heads/main $CLASH ''"; rc1=$?
    ofx_in B "git -C '$R' update-ref -m x --no-deref refs/heads/main $TIP ''"; rc2=$?
    WRONG="import sys, subprocess; sys.path.insert(0, '$ENGINE_ROOT/mega-lander'); import workspaces as W; W._fence_restore_intent('$R', 'main', '$TIP'); sys.exit(subprocess.call(['git', '-C', '$R', 'update-ref', '-m', 'x', '--no-deref', 'refs/heads/main', '$CLASH', '']))"
    ofx_in B "python3 -c \"$WRONG\""; rc3=$?
    [ $rc1 -ne 0 ] && [ $rc2 -ne 0 ] && [ $rc3 -ne 0 ] && [ -z "$(rev "$R" main)" ]
    expect "F10" "[git $G] a restore with no intent, or to a value its intent does not name, is refused" "$?" "rc=$rc1/$rc2/$rc3"
    rm -f "$OFX/locks/restore-intents/"*.json
    ofx_in A "git -C '$R' update-ref -m restore --no-deref refs/heads/main $TIP '' && $(ofx_lease release --repo "$R")"
    [ "$(rev "$R" main)" = "$TIP" ] || bad "F10 [git $G] the fixture could not put main back" "$OFX_OUT"
else
    bad "F10 [git $G] the fixture could not delete main with the lease (or the reflog survived), so the case proves nothing" "$OFX_OUT"
fi

# ---- F11: the shared checkout stays on main (Frank §4 (B)) ---------------------------
git -C "$R" branch side >/dev/null 2>&1
ofx_in B "git -C '$R' switch -q side"; rc1=$?
ofx_in B "git -C '$R' checkout -q --detach"; rc2=$?
[ $rc1 -ne 0 ] && [ $rc2 -ne 0 ] && [ "$(sym "$R")" = "refs/heads/main" ]
expect "F11" "[git $G] switching or detaching the main checkout without the lease is refused" "$?" "rc=$rc1/$rc2 $OFX_OUT"
ofx_in A "$(ofx_lease acquire --repo "$R") && git -C '$R' switch -q side"; rc1=$?
[ "$(sym "$R")" = "refs/heads/side" ]; on_side=$?
ofx_in B "git -C '$R' switch -q main"; rc2=$?
[ $rc1 = 0 ] && [ $on_side = 0 ] && [ $rc2 = 0 ] && [ "$(sym "$R")" = "refs/heads/main" ]
expect "F11" "[git $G] the lease holder may switch away; anyone may switch back to main" "$?" "rc=$rc1/$rc2"
ofx_in A "$(ofx_lease release --repo "$R")"

# ---- F12: merge --abort is fenced (G1) ----------------------------------------------
ofx_in A "$(ofx_lease acquire --repo "$R") && git -C '$R' merge -q clash -m m"
if [ -f "$R/.git/MERGE_HEAD" ]; then
    # The early check is what keeps the holder's merge: it refuses B's abort
    # before it runs. (The Git fence alone refuses it too late: see F12L.)
    payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s merge --abort"},"cwd":"%s"}' "$R" "$OFX")"
    ofx_in B "printf '%s' '$payload' | bash '$ENGINE_ROOT/scripts/hooks/guard-land-lease-commands.sh'"; rc=$?
    [ $rc = 2 ] && [ -f "$R/.git/MERGE_HEAD" ] && grep -q '^<<<<<<<' "$R/f.txt"
    expect "F12" "[git $G] B's 'git merge --abort' is refused by the early check before it runs; the holder's merge survives" "$?" "rc=$rc $OFX_OUT"
    ofx_in B "sh -c 'git -C $R merge --abort'"; rc=$?
    [ $rc -ne 0 ] && [ -f "$R/.git/MERGE_HEAD" ]
    expect "F12" "[git $G] run where the text check cannot see it, the fence still refuses the abort (MERGE_HEAD kept)" "$?" "rc=$rc $OFX_OUT"
    ! grep -q '^<<<<<<<' "$R/f.txt"
    expect "F12L" "[git $G] (measured limit) that refused abort had already discarded the conflicted tree; the early check is the only thing that stops it" "$?"
    ofx_in A "git -C '$R' merge --abort && $(ofx_lease release --repo "$R")"; rc=$?
    [ $rc = 0 ] && [ ! -f "$R/.git/MERGE_HEAD" ]
    expect "F12" "[git $G] the holder's own merge --abort passes" "$?" "$OFX_OUT"
else
    bad "F12 [git $G] the fixture's merge did not conflict, so the case proves nothing" "$OFX_OUT"
fi

# ---- F13: cherry-pick, the starter record, orphan abort (G1.4, G5, G6) ---------------
ofx_in B "git -C '$R' cherry-pick clash"
if [ -f "$R/.git/CHERRY_PICK_HEAD" ]; then
    ok "F13 [git $G] a conflicted cherry-pick is NOT stopped by the fence (stated limit): CHERRY_PICK_HEAD written"
    python3 - "$OFX/locks/in-progress" "$CLASH" <<'PY'
import glob, json, sys
recs = [json.load(open(p)) for p in glob.glob(sys.argv[1] + "/*.json")]
sys.exit(0 if any((r.get("owner") or {}).get("session_id") == "B" and r["refs"].get("CHERRY_PICK_HEAD") == sys.argv[2] for r in recs) else 1)
PY
    expect "F13" "[git $G] the launcher records who started it (session B) and its head (G6)" "$?"
    ofx_in B "cd '$R' && git add f.txt && git commit -q --no-edit"; rc=$?
    grep -q "\"cherry_pick_head\": \"$CLASH\"" "$REF"; recorded=$?
    [ $rc -ne 0 ] && [ $recorded = 0 ] && [ -f "$R/.git/CHERRY_PICK_HEAD" ]
    expect "F13" "[git $G] its commit is refused, and the refusal carries CHERRY_PICK_HEAD" "$?" "rc=$rc"
    ofx_in B "python3 '$ENGINE_ROOT/scripts/lib/operator_fences.py' merge-owner --repo '$R'"; vb="$OFX_OUT"
    ofx_in A "python3 '$ENGINE_ROOT/scripts/lib/operator_fences.py' merge-owner --repo '$R'"; va="$OFX_OUT"
    printf '%s' "$vb" | grep -q '"refused-mine"' && printf '%s' "$va" | grep -q '"refused-other"'
    expect "F13" "[git $G] merge-owner: refused-mine for its starter, refused-other for anyone else" "$?" "B=$vb A=$va"
    ofx_in A "$(ofx_lease acquire --repo "$R")"; acq="$OFX_OUT"
    ofx_in A "$(ofx_lease abort-orphan --repo "$R")"; rc=$?
    kept="$(printf '%s' "$OFX_OUT" | sed -n 's/.*preserved in \([^ ]*\)\.$/\1/p')"
    [ $rc = 0 ] && [ ! -f "$R/.git/CHERRY_PICK_HEAD" ] && [ -n "$kept" ] && [ -f "$kept/CHERRY_PICK_HEAD" ] \
        && [ -f "$kept/ls-files-unmerged.txt" ] && grep -q '^+clash' "$kept/diff-binary-HEAD.patch" \
        && printf '%s' "$acq" | grep -q "abort-orphan"
    expect "F13" "[git $G] acquire names the orphan; abort-orphan preserves (head, the staged change) then aborts" "$?" "rc=$rc $OFX_OUT | $acq"
    ofx_in A "$(ofx_lease release --repo "$R")"
else
    bad "F13 [git $G] the fixture's cherry-pick did not conflict, so the case proves nothing" "$OFX_OUT"
fi
ofx_session C
ofx_in C "git -C '$R' cherry-pick clash"
ofx_end C
ofx_in A "python3 '$ENGINE_ROOT/scripts/lib/operator_fences.py' merge-owner --repo '$R'"; va="$OFX_OUT"
ofx_in A "$(ofx_lease acquire --repo "$R") && $(ofx_lease abort-orphan --repo "$R") && $(ofx_lease release --repo "$R")"; rc=$?
printf '%s' "$va" | grep -q '"owner-ended"' && [ $rc = 0 ] && [ ! -f "$R/.git/CHERRY_PICK_HEAD" ]
expect "F13" "[git $G] a starter that has ended is named as ended, and its orphan is cleared by the holder" "$?" "$va | $OFX_OUT"
ofx_session D
ofx_in D "git -C '$R' cherry-pick clash"
ofx_in A "$(ofx_lease acquire --repo "$R")"
ofx_in A "$(ofx_lease abort-orphan --repo "$R")"; rc=$?
[ $rc -ne 0 ] && [ -f "$R/.git/CHERRY_PICK_HEAD" ] && printf '%s' "$OFX_OUT" | grep -q "never abort a merge you did not start"
expect "F13" "[git $G] a LIVE starter's cherry-pick is never aborted by the holder" "$?" "rc=$rc $OFX_OUT"
ofx_in A "$(ofx_lease release --repo "$R")"
ofx_in D "git -C '$R' cherry-pick --abort"; rc1=$?
ofx_in D "$(ofx_lease acquire --repo "$R") && git -C '$R' cherry-pick --abort && $(ofx_lease release --repo "$R")"; rc2=$?
[ $rc1 -ne 0 ] && [ $rc2 = 0 ] && [ ! -f "$R/.git/CHERRY_PICK_HEAD" ]
expect "F13" "[git $G] its own starter aborts it once it takes the lease (the abort writes ORIG_HEAD)" "$?" "rc=$rc1/$rc2 $OFX_OUT"
ofx_end D

# ---- F15: the bypass that exists, asserted (G2) ----------------------------------------
before="$(grep -c . "$OFX/forensics/ref-transactions.jsonl")"; rbefore="$(grep -c . "$REF")"
M2="$(rev "$R" main)"
ofx_in B "git -C '$R' -c core.hooksPath=/dev/null update-ref refs/heads/main $M2~1"; rc=$?
after="$(grep -c . "$OFX/forensics/ref-transactions.jsonl")"; rafter="$(grep -c . "$REF")"
[ $rc = 0 ] && [ "$(rev "$R" main)" != "$M2" ] && [ "$before" = "$after" ] && [ "$rbefore" = "$rafter" ]
expect "F15" "[git $G] core.hooksPath=/dev/null (the engine's own integrate) moves main with NO hook call: not fenced, by design" "$?"
git -C "$R" -c core.hooksPath=/dev/null update-ref refs/heads/main "$M2" >/dev/null 2>&1

# ---- F16/F17: the declared non-Claude holder (F1, e1, G5) -------------------------------
ofx_session X codex
ofx_in X "$(ofx_lease acquire --repo "$R" --holder codex)"; rc=$?
python3 -c "import json,sys; h=json.load(open(sys.argv[1]))['holder']; l=json.load(open(sys.argv[1])); sys.exit(0 if h['kind']=='codex' and l['expires'] else 1)" "$(lease_file)" 2>/dev/null
rcl=$?; [ $rc = 0 ] && [ $rcl = 0 ]
expect "F16" "[git $G] the Codex stand-in (no claude in its tree) acquires with --holder codex, with a time-to-live" "$?" "$OFX_OUT"
ofx_in X "cd '$R' && printf 'c\n' > c.txt && git add c.txt && git commit -q -m codex"; rc=$?
ofx_in A "$(ofx_lease acquire --repo "$R" --wait 1)"; rca=$?; aout="$OFX_OUT"
ofx_in X "git -C '$R' push -q origin main && $(ofx_lease release --repo "$R" --holder codex)"; rcr=$?
[ $rc = 0 ] && [ $rca = 75 ] && printf '%s' "$aout" | grep -q "Codex" && [ $rcr = 0 ] && [ -z "$(lease_file)" ]
expect "F16" "[git $G] Codex lands; a lead's acquire meanwhile exits 75 naming Codex; Codex releases" "$?" "rc=$rc/$rca/$rcr $aout"
ofx_in X "$(ofx_lease acquire --repo "$R")"; rc1=$?
ofx_in X "$(ofx_lease acquire --repo "$R" --holder codex --holder-pid "$PID_A")"; rc2=$?; o2="$OFX_OUT"
ofx_in A "$(ofx_lease acquire --repo "$R" --holder codex)"; rc3=$?
[ $rc1 -ne 0 ] && [ $rc2 -ne 0 ] && printf '%s' "$o2" | grep -q "not an ancestor" && [ $rc3 -ne 0 ] && [ -z "$(lease_file)" ]
expect "F16" "[git $G] refused: no holder named from a codex tree; a --holder-pid that is not an ancestor; --holder codex from a claude tree" "$?" "rc=$rc1/$rc2/$rc3 $o2"
ofx_in X "LAND_LEASE_TTL=1 $(ofx_lease acquire --repo "$R" --holder codex)"; sleep 2
ofx_in A "$(ofx_lease acquire --repo "$R" --wait 1)"; rc=$?; aout="$OFX_OUT"
ofx_in X "cd '$R' && printf 'late\n' > late.txt && git add late.txt && git commit -q -m late"; rcx=$?
[ $rc = 0 ] && printf '%s' "$aout" | grep -q "past its time" && [ $rcx -ne 0 ]
expect "F17" "[git $G] a Codex lease past its time is taken at rest, and Codex's next move is refused" "$?" "rc=$rc/$rcx $aout"
git -C "$R" restore --staged late.txt >/dev/null 2>&1; rm -f "$R/late.txt"
ofx_in A "$(ofx_lease release --repo "$R")"
ofx_in X "LAND_LEASE_TTL=1 $(ofx_lease acquire --repo "$R" --holder codex) && printf 'edit\n' >> '$R/f.txt'"; sleep 2
ofx_in A "$(ofx_lease acquire --repo "$R" --wait 1)"; rc=$?; aout="$OFX_OUT"
ofx_in A "$(ofx_lease takeover --repo "$R")"; rct=$?; tout="$OFX_OUT"
kept="$(printf '%s' "$tout" | sed -n 's/.* first, in \([^;]*\);.*/\1/p')"
[ $rc = 75 ] && printf '%s' "$aout" | grep -q "past its time" && printf '%s' "$aout" | grep -q "takeover" \
    && [ $rct = 0 ] && [ -n "$kept" ] && grep -q '^+edit' "$kept/diff-binary-HEAD.patch" && grep -q "edit" "$R/f.txt"
expect "F17" "[git $G] not at rest it stays held (exit 75, 'past its time', names takeover); takeover preserves the edit first and changes nothing" "$?" "rc=$rc/$rct $aout | $tout"
ofx_in X "cd '$R' && git commit -q -am codex-edit"; rcx=$?
[ $rcx -ne 0 ]
expect "F17" "[git $G] after the takeover, the old Codex holder's commit is refused" "$?"
git -C "$R" checkout -- f.txt >/dev/null 2>&1
ofx_in A "$(ofx_lease release --repo "$R")"
ofx_end X

# ---- F25: a dead Claude holder -----------------------------------------------------------
ofx_session D2
ofx_in D2 "$(ofx_lease acquire --repo "$R")"; ofx_end D2
ofx_in A "$(ofx_lease acquire --repo "$R")"; rc=$?
[ $rc = 0 ] && printf '%s' "$OFX_OUT" | grep -q "had ended"
expect "F25" "[git $G] a dead holder's lease on a repository at rest is taken by the next acquire" "$?" "$OFX_OUT"
ofx_in A "$(ofx_lease release --repo "$R")"
ofx_session D3
ofx_in D3 "$(ofx_lease acquire --repo "$R") && printf 'dead\n' >> '$R/f.txt'"; ofx_end D3
ofx_in A "$(ofx_lease acquire --repo "$R" --wait 1)"; rc=$?; aout="$OFX_OUT"
ofx_in A "$(ofx_lease takeover --repo "$R")"; rct=$?
[ $rc = 75 ] && printf '%s' "$aout" | grep -q "holder has ended" && [ $rct = 0 ]
expect "F25" "[git $G] not at rest, a dead holder's lease is held (exit 75) until a takeover" "$?" "rc=$rc/$rct $aout"
git -C "$R" checkout -- f.txt >/dev/null 2>&1
ofx_in A "$(ofx_lease release --repo "$R")"

# ---- F28/F29: a recycled pid is not the holder; a live lease cannot be taken over ---------
LF="$(python3 -c "import sys; sys.path.insert(0, '$ENGINE_ROOT/scripts/lib'); import operator_fences as F; c=F.read_launcher('$R/.git/hooks/reference-transaction'); print(F.Files(c).lease)")"
python3 - "$LF" "$$" "$R" <<'PY'
import json, sys, time
json.dump({"schema": 1, "repository": sys.argv[3], "acquired_epoch": time.time(), "expires": None,
           "holder": {"kind": "claude", "pid": int(sys.argv[2]), "start": 1, "session_id": "recycled"}},
          open(sys.argv[1], "w"))
PY
ofx_in A "$(ofx_lease status --repo "$R")"; st="$OFX_OUT"
ofx_in A "$(ofx_lease acquire --repo "$R" --wait 1)"; rc=$?
printf '%s' "$st" | grep -q "lease dead" && [ $rc = 0 ]
expect "F28" "[git $G] a lease naming a live pid with another start time is dead (a recycled pid is never the holder)" "$?" "$st | $OFX_OUT"
ofx_in B "$(ofx_lease takeover --repo "$R")"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$OFX_OUT" | grep -q "cannot be taken over"
expect "F29" "[git $G] a live, in-time lease cannot be taken over" "$?" "rc=$rc $OFX_OUT"
ofx_in A "$(ofx_lease release --repo "$R")"

# ---- F18/F19: the wait and the home (G7, G10) -------------------------------------------
python3 -c "import sys; sys.path.insert(0, '$ENGINE_ROOT/scripts/lib'); import operator_fences as F; sys.exit(0 if F._wait_budget({}) == 90.0 and F.MAX_WAIT == 540.0 else 1)"
expect "F18" "[git $G] the default wait is 90 s (below the Bash tool's 120 s default) and the ceiling 540 s" "$?"
ofx_in A "$(ofx_lease acquire --repo "$R" --wait 541)"; rc1=$?; o1="$OFX_OUT"
ofx_in A "$(ofx_lease acquire --repo "$R" --wait 540) && $(ofx_lease release --repo "$R")"; rc2=$?
[ $rc1 -ne 0 ] && printf '%s' "$o1" | grep -q "540" && [ $rc2 = 0 ]
expect "F18" "[git $G] --wait 541 is refused; --wait 540 is accepted" "$?" "rc=$rc1/$rc2 $o1"
ofx_in A "RICHOS_LAND_LOCKS_DIR='$OFX/elsewhere' $(ofx_lease acquire --repo "$R")"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$OFX_OUT" | grep -q "G10" && [ -z "$(ls "$OFX/elsewhere/"*.lease 2>/dev/null)" ]
expect "F19" "[git $G] a caller whose lease home differs from the launcher's is refused" "$?" "rc=$rc $OFX_OUT"

# ---- F27: the product lander waits on a live lease (G2) -----------------------------------
LL="import sys, os; sys.path.insert(0, '$ENGINE_ROOT/mega-lander'); import app
try:
    with app.land_lock({'binding': {}}, '$R') as status: print('ENTERED')
except ValueError as e: print('WAITED:', e)"
ofx_in A "$(ofx_lease acquire --repo "$R")"
held="$(RICHOS_LAND_LOCK_TIMEOUT=2 python3 -c "$LL" 2>&1)"
ofx_in A "$(ofx_lease release --repo "$R")"
free="$(RICHOS_LAND_LOCK_TIMEOUT=2 python3 -c "$LL" 2>&1)"
printf '%s' "$held" | grep -q "operator land lease" && printf '%s' "$free" | grep -q "ENTERED"
expect "F27" "[git $G] land_lock() waits on a live lease, and enters once it is released" "$?" "held: $held | free: $free"
# Frank's #13: a reference-transaction hook that is not UTF-8 is not ours. It
# reads as "no lease" in the product lander and as "fences off" in the lease
# commands, never as an exception.
ofx_repo "u$N"; U="$OFX_R"
printf '#!/bin/sh\n# richos-operator-fence-launcher \377\376\n' > "$U/.git/hooks/reference-transaction"
u1="$(python3 -c "import sys; sys.path.insert(0, '$ENGINE_ROOT/mega-lander'); import app; print('RESULT', app._live_fence_lease('$U'))" 2>&1)"
u2="$(bash "$LEASE" status --repo "$U" 2>&1)"; rcu=$?
printf '%s' "$u1" | grep -q "RESULT None" && [ $rcu = 0 ] && printf '%s' "$u2" | grep -q "operator fences are" \
    && ! printf '%s%s' "$u1" "$u2" | grep -q "Traceback"
expect "F27" "[git $G] a hook that is not UTF-8 reads as no lease, never an exception (#13)" "$?" "$u1 | $u2"

# ---- F21: on, and the fence cannot decide: refuse, name the way out (e8) -------------------
PROG="$R/.git/hooks/operator-fences/operator_fences.py"
cp "$PROG" "$OFX/prog.bak"
printf 'import sys\nsys.exit(3)\n' > "$PROG"
ofx_in A "$(ofx_lease acquire --repo "$R") && cd '$R' && printf 'y\n' > y.txt && git add y.txt && git commit -q -m y"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$OFX_OUT" | grep -q "could not decide" && printf '%s' "$OFX_OUT" | grep -q "operator-fences.sh off"
expect "F21" "[git $G] ON with a fence that cannot decide: even the holder is refused, and the refusal names 'operator-fences.sh off'" "$?" "rc=$rc $OFX_OUT"
cp "$OFX/prog.bak" "$PROG"
git -C "$R" restore --staged y.txt >/dev/null 2>&1; rm -f "$R/y.txt"
ofx_in A "$(ofx_lease release --repo "$R")"

# ---- F22: status against the declaration (e8, G12) -----------------------------------------
out="$(bash "$FENCES" status --repo "$R" --entity "$OFX/entity" 2>&1)"; rc=$?
expect "F22" "[git $G] status exits 0 when on, current and reachable" "$([ $rc = 0 ] && printf '%s' "$out" | grep -q "OK" && echo 0 || echo 1)" "$out"
printf '# drift\n' >> "$PROG"
out="$(bash "$FENCES" status --repo "$R" --entity "$OFX/entity" 2>&1)"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$out" | grep -q "differs"
expect "F22" "[git $G] status fails when the installed fence program differs from the engine's" "$?" "$out"
ofx_install "$R" >/dev/null 2>&1
ofx_declare off
out="$(ofx_on "$R" 2>&1)"; rc1=$?
out2="$(bash "$FENCES" status --repo "$R" --entity "$OFX/entity" --declaration-check 2>&1)"; rc2=$?
ofx_off "$R" >/dev/null 2>&1
out3="$(bash "$FENCES" status --repo "$R" --entity "$OFX/entity" --declaration-check 2>&1)"; rc3=$?
[ $rc1 -ne 0 ] && printf '%s' "$out" | grep -q "REFUSED" && [ $rc2 -ne 0 ] && [ $rc3 = 0 ]
expect "F22" "[git $G] 'on' is refused while the declaration says off; the probe check fails on disagreement and passes on agreement" "$?" "rc=$rc1/$rc2/$rc3 $out | $out2 | $out3"

# ---- F20: OFF CANNOT REFUSE ANYTHING, AND BEHAVES AS TODAY -----------------------------------
# The launcher is still installed, the switch is off (F22 left it off).
grep -q '^OPERATOR_FENCES_STATE="off"$' "$R/.git/hooks/reference-transaction" || bad "F20 [git $G] the fixture is not off"
printf 'import sys\nsys.exit(3)\n' > "$PROG"      # a broken fence program must not matter while off
rows0="$(grep -c . "$OFX/forensics/ref-transactions.jsonl")"
ofx_in B "cd '$R' && git merge -q --no-ff ffb -m off && git reset -q --hard HEAD~1 && git switch -q side && git checkout -q --detach && git switch -q main && git merge -q clash -m c; git merge --abort && printf 'o\n' > o.txt && git add o.txt && git commit -q -m o && git reset -q --soft HEAD~1 && git restore --staged o.txt && rm o.txt && git update-ref -d refs/heads/side && git branch side && git pack-refs --all"; rc=$?
rows1="$(grep -c . "$OFX/forensics/ref-transactions.jsonl")"
[ $rc = 0 ] && [ "$(sym "$R")" = "refs/heads/main" ] && [ "$rows1" -gt "$rows0" ]
expect "F20" "[git $G] OFF: merge, reset, switch, detach, merge --abort, commit, branch delete all pass with no lease, a broken fence program is never run, and the recorder still records" "$?" "rc=$rc $OFX_OUT"
ofx_in B "$(ofx_lease acquire --repo "$R")"; rc=$?
[ $rc = 0 ] && printf '%s' "$OFX_OUT" | grep -q "off" && [ -z "$(lease_file)" ]
expect "F20" "[git $G] OFF: the lease commands are no-ops that say so and write nothing" "$?" "$OFX_OUT"
payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m x"},"cwd":"%s"}' "$R" "$R")"
printf '%s' "$payload" | bash "$ENGINE_ROOT/scripts/hooks/guard-land-lease-commands.sh" >/dev/null 2>&1
expect "F20" "[git $G] OFF: the early Bash check never refuses" "$?"
# The twin: the same script, once through the OFF launcher and once through the
# plain recorder hook with no launcher at all, gives the same exit codes and the
# same refs. That is "his terminal behaves exactly as today", measured.
TWIN_SCRIPT='git switch -q -c t1 && printf "1\n" > t.txt && git add t.txt && git commit -q -m t1 && git switch -q main && git merge -q --no-ff t1 -m m1; echo "rc1=$?"; git reset -q --hard HEAD~1; echo "rc2=$?"; git checkout -q --detach; echo "rc3=$?"; git switch -q main; echo "rc4=$?"; git update-ref -d refs/heads/t1; echo "rc5=$?"; git pack-refs --all; echo "rc6=$?"; git for-each-ref --format="%(refname) %(objecttype)"; git symbolic-ref HEAD'
ofx_repo "twin$N"; T="$OFX_R"
cp "$RECORDER" "$T/.git/hooks/reference-transaction"; chmod +x "$T/.git/hooks/reference-transaction"
ofx_repo "twinoff$N"; TO="$OFX_R"
cp "$RECORDER" "$TO/.git/hooks/reference-transaction"; chmod +x "$TO/.git/hooks/reference-transaction"
ofx_install "$TO" >/dev/null 2>&1
printf 'import sys\nsys.exit(3)\n' > "$TO/.git/hooks/operator-fences/operator_fences.py"
plain="$(cd "$T" && bash -c "$TWIN_SCRIPT" 2>&1)"
fenced_off="$(cd "$TO" && bash -c "$TWIN_SCRIPT" 2>&1)"
[ "$plain" = "$fenced_off" ] && printf '%s' "$plain" | grep -q "rc6=0"
expect "F20" "[git $G] OFF: a twin repository without the launcher gives identical exit codes and refs for the same commands" "$?" "plain: $plain | off: $fenced_off"
ofx_install "$R" >/dev/null 2>&1

# ---- F26: install-ref-forensics.sh and the launcher --------------------------------------
before="$(shasum -a 256 "$R/.git/hooks/reference-transaction" | awk '{print $1}')"
rm -f "$chain/20-ref-transaction-forensics.sh"
out="$(bash "$ENGINE_ROOT/scripts/install-ref-forensics.sh" "$R" 2>&1)"; rc=$?
after="$(shasum -a 256 "$R/.git/hooks/reference-transaction" | awk '{print $1}')"
bash "$ENGINE_ROOT/scripts/install-ref-forensics.sh" --check "$R" >/dev/null 2>&1; rcc=$?
[ $rc = 0 ] && [ "$before" = "$after" ] && cmp -s "$RECORDER" "$chain/20-ref-transaction-forensics.sh" && [ $rcc = 0 ]
expect "F26" "[git $G] install-ref-forensics.sh installs the recorder into the chain and never over the launcher" "$?" "$out"

# ---- F23: uninstall -------------------------------------------------------------------------
out="$(bash "$FENCES" uninstall --repo "$R" 2>&1)"; rc=$?
[ $rc = 0 ] && cmp -s "$RECORDER" "$R/.git/hooks/reference-transaction" && [ ! -e "$chain" ] \
    && [ ! -e "$R/.git/hooks/operator-fences" ]
expect "F23" "[git $G] uninstall restores the previous hook and removes the launcher, chain and program" "$?" "$out"

ofx_end A; ofx_end B
done
export PATH="$ORIG_PATH"

# M: this suite's mutation harness runs as its own unit,
# scripts/operator-fences-mutation.test.sh, so each gets a deadline that fits it.

printf 'operator-fences: %d passed, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
