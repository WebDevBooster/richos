#!/usr/bin/env bash
#
# create-teammate-worktree.test.sh — behavioral tests for the sanctioned
# cross-repository worktree helper.
#
# The helper replaces a sentence in a spawn prompt ("run git worktree add")
# with one call that creates, seeds, and REGISTERS. Every case here is
# two-sided where a verdict is involved, and the ledger and session registry
# are pinned into the sandbox so no case can touch the operator's record.
#
# Run directly: scripts/create-teammate-worktree.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/create-teammate-worktree.sh"
LEDGER_PY="$SCRIPT_DIR/lib/worktree-ledger.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t create-teammate-wt.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$HELPER" ] || { echo "FATAL: helper missing/non-executable: $HELPER" >&2; exit 1; }

export RICHOS_WORKTREE_LEDGER="$SANDBOX/wt-ledger.jsonl"
export RICHOS_SESSIONS_DIR="$SANDBOX/sessions"
mkdir -p "$RICHOS_SESSIONS_DIR"
export CLAUDE_PID="$$"
printf '{"pid":%s,"sessionId":"feedface-0000-4000-8000-000000000001","startedAt":%s000}\n' "$$" "$(date +%s)" >"$RICHOS_SESSIONS_DIR/$$.json"

# A repository with a .worktreeinclude and the gitignored files it names, in
# the same shape femcboost carries (.envrc at the root, .env.local nested).
REPO="$SANDBOX/repo"
mkdir -p "$REPO/app/deep"
git -C "$REPO" init -q -b main
printf '.envrc\n**/.env.local\n' >"$REPO/.worktreeinclude"
printf '.envrc\n.env.local\n' >"$REPO/.gitignore"
printf 'seed\n' >"$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m seed
printf 'export X=1\n' >"$REPO/.envrc"
printf 'A=1\n' >"$REPO/app/.env.local"
printf 'B=2\n' >"$REPO/app/deep/.env.local"
printf 'not-seeded\n' >"$REPO/app/other.local"

echo "=== create-teammate-worktree tests ==="

# 1. THE HAPPY PATH: created at <repo>-wt/<name>, on branch <name> from HEAD,
#    seeded, and registered with path/repo/branch/session/pid.
OUT="$("$HELPER" "$REPO/app" echo-opus-ct1 2>&1)"; rc=$?
WT="$SANDBOX/repo-wt/echo-opus-ct1"
if [ "$rc" -eq 0 ] && [ -d "$WT" ] \
   && [ "$(git -C "$WT" symbolic-ref -q --short HEAD)" = "echo-opus-ct1" ] \
   && [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse HEAD)" ]; then
    ok "C01  creates <repo>-wt/<name> on branch <name> at the main checkout's HEAD (from a subdirectory argument)"
else
    bad "C01  create (rc=$rc): $OUT"
fi
if [ -f "$WT/.envrc" ] && [ -f "$WT/app/.env.local" ] && [ -f "$WT/app/deep/.env.local" ] \
   && [ ! -f "$WT/app/other.local" ] && printf '%s' "$OUT" | grep -q 'seeded:     3 file(s)'; then
    ok "C02  seeds every gitignored file matching .worktreeinclude (root and nested), nothing else"
else
    bad "C02  seeding: $(ls -la "$WT" "$WT/app" 2>/dev/null | tr '\n' ' ')"
fi
if python3 - "$RICHOS_WORKTREE_LEDGER" "$WT" "$REPO" "$$" <<'PY' 2>/dev/null
import json, os, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = rows[-1]
assert r["event"] == "prepared" and r["class"] == "hand-rolled", r
assert r["teammate"] == "echo-opus-ct1" and r["branch"] == "echo-opus-ct1", r
assert os.path.realpath(r["worktree"]) == os.path.realpath(sys.argv[2]), r
assert os.path.realpath(r["repo"]) == os.path.realpath(sys.argv[3]), r
assert r["session_pid"] == int(sys.argv[4]) and r.get("pid_start"), r
assert r["session_id"] == "feedface-0000-4000-8000-000000000001", r
assert r["source"] == "create-teammate-worktree.sh", r
PY
then ok "C03  writes a PREPARED record with path, repo, branch, session id (from the registry), pid and start time"
else bad "C03  prepared record: $(tail -1 "$RICHOS_WORKTREE_LEDGER" 2>/dev/null)"; fi
if python3 "$LEDGER_PY" prepared --session-id feedface-0000-4000-8000-000000000001 --teammate echo-opus-ct1 --worktree "$WT" >/dev/null; then
    ok "C04  the prepared record resolves by EXACT (session, teammate, path) — the key the spawn guard and the seal use"
else
    bad "C04  prepared lookup by exact key failed"
fi
if printf '%s' "$OUT" | grep -q 'isolation: "worktree"' \
   && printf '%s' "$OUT" | grep -q "cross-repo-worktree: $WT" \
   && printf '%s' "$OUT" | grep -q 'prepare-agent-spawn.py' \
   && ! printf '%s' "$OUT" | grep -q 'cwd: "'; then
    ok "C05  prints native+external and acknowledgement preparation; never recommends cwd-only"
else
    bad "C05  spawn contract: $OUT"
fi

# 2. REFUSALS, each named. Nothing is created and nothing is registered.
N0="$(grep -c . "$RICHOS_WORKTREE_LEDGER")"
"$HELPER" "$REPO" echo-opus-ct1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "C06  refuses a name whose branch already exists (exit 3)" || bad "C06  duplicate name rc=$rc"
"$HELPER" "$REPO" echo-ct2 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && [ ! -d "$SANDBOX/repo-wt/echo-ct2" ] && ok "C07  refuses a name that is not <role>-<model>-<identifier> (exit 3)" || bad "C07  bad name rc=$rc"
"$HELPER" "$REPO" echo-gpt-ct3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "C08  refuses a model token outside the allowed set (exit 3)" || bad "C08  bad model rc=$rc"
mkdir -p "$SANDBOX/repo-wt/echo-opus-ct4"
"$HELPER" "$REPO" echo-opus-ct4 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "C09  refuses a target path that already exists (exit 3)" || bad "C09  existing path rc=$rc"
"$HELPER" "$REPO" echo-opus-ct5 --base no-such-ref >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "C10  refuses a base ref that does not resolve (exit 3)" || bad "C10  bad base rc=$rc"
"$HELPER" "$SANDBOX" echo-opus-ct6 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "C11  refuses a path that is not inside a repository (exit 3)" || bad "C11  non-repo rc=$rc"
"$HELPER" "$REPO" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "C12  missing arguments is a usage error (exit 2)" || bad "C12  usage rc=$rc"
[ "$(grep -c . "$RICHOS_WORKTREE_LEDGER")" -eq "$N0" ] && ok "C13  no refusal wrote a registration" || bad "C13  a refusal wrote to the ledger"

# 3. --dir, --base and --session/--pid are honored; the tree is judged by the
#    reaper's own library as an OWNED tree afterwards (the whole point).
sleep 5 & DEAD=$!; DEAD_START="$(python3 "$LEDGER_PY" pid-start "$DEAD")"; kill "$DEAD"; wait "$DEAD" 2>/dev/null
git -C "$REPO" branch older-base HEAD
OUT="$("$HELPER" "$REPO" mark-sonnet-ct7 --dir "$SANDBOX/elsewhere/mark-sonnet-ct7" --base older-base --session cafebabe-0000-4000-8000-000000000002 --pid "$DEAD" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -d "$SANDBOX/elsewhere/mark-sonnet-ct7" ] \
   && tail -1 "$RICHOS_WORKTREE_LEDGER" | grep -q '"session_id": "cafebabe-0000-4000-8000-000000000002"' \
   && tail -1 "$RICHOS_WORKTREE_LEDGER" | grep -q "\"session_pid\": $DEAD,"; then
    ok "C14  --dir, --base, --session and --pid are honored"
else
    bad "C14  options (rc=$rc): $OUT / $(tail -1 "$RICHOS_WORKTREE_LEDGER")"
fi
V="$(python3 "$LEDGER_PY" judge --entity "$REPO" --worktree "$SANDBOX/elsewhere/mark-sonnet-ct7" --name mark-sonnet-ct7 --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*host session pid .* is gone'; then
    ok "C15  a helper-created tree whose recorded session has ended is judged NOT-ALIVE by path — no name convention needed"
else
    bad "C15  judge after create: $V"
fi
V="$(python3 "$LEDGER_PY" judge --entity "$REPO" --worktree "$WT" --name echo-opus-ct1 --format triple --no-write)"
case "$V" in INDETERMINATE*) ok "C16  a helper-created tree whose session is THIS process stays INDETERMINATE" ;; *) bad "C16  live judge: $V" ;; esac

# 4. The ledger write failing is NOT silent and does NOT leave a tree behind:
#    exit 5, the worktree and branch are rolled back, and the message says so.
N0="$(grep -c . "$RICHOS_WORKTREE_LEDGER")"
OUT="$(RICHOS_WORKTREE_LEDGER=/nonexistent-dir/ledger.jsonl "$HELPER" "$REPO" norm-opus-ct8 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && [ ! -d "$SANDBOX/repo-wt/norm-opus-ct8" ] && printf '%s' "$OUT" | grep -q 'ROLLED BACK' \
   && ! git -C "$REPO" rev-parse --verify -q refs/heads/norm-opus-ct8 >/dev/null \
   && ! git -C "$REPO" worktree list --porcelain | grep -q 'norm-opus-ct8'; then
    ok "C17  an unrecordable tree exits 5 and is ROLLED BACK: directory, branch and registration all gone"
else
    bad "C17  unrecordable (rc=$rc): $OUT / $(ls "$SANDBOX/repo-wt" 2>/dev/null | tr '\n' ' ')"
fi
[ "$(grep -c . "$RICHOS_WORKTREE_LEDGER")" -eq "$N0" ] && ok "C18  the rollback wrote nothing to the real ledger" || bad "C18  rollback wrote to the ledger"

# 5. NO SESSION ID -> refused and rolled back. A prepared record with no
#    session can never match a spawn-intent, so the tree could never be bound.
OUT="$(RICHOS_SESSIONS_DIR="$SANDBOX/no-sessions" CLAUDE_PID=1 "$HELPER" "$REPO" norm-opus-ct9 --pid 1 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && [ ! -d "$SANDBOX/repo-wt/norm-opus-ct9" ] && printf '%s' "$OUT" | grep -q 'no session id could be resolved' \
   && ! git -C "$REPO" rev-parse --verify -q refs/heads/norm-opus-ct9 >/dev/null; then
    ok "C19  no resolvable session id -> exit 5, rolled back (a record that can never be bound is not written)"
else
    bad "C19  no-session (rc=$rc): $OUT"
fi
# ...and the same call WITH --session succeeds (positive control).
"$HELPER" "$REPO" norm-opus-ct9 --pid 1 --session cafebabe-0000-4000-8000-000000000009 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -d "$SANDBOX/repo-wt/norm-opus-ct9" ] && ok "C20  the same call with an explicit --session succeeds (positive control for 5)" || bad "C20  explicit session rc=$rc"

# 6. THE ROLLBACK'S FALLBACK PATH — the half C17 cannot reach.
#
#    C17 only exercises the case where the worktree removal SUCCEEDS. The
#    rollback's first line is `<removal> || rm -rf "$DIR"`, and that fallback
#    arm behaved differently: it leaves the tree's admin registration in
#    <main>/.git/worktrees/<id>, and git then REFUSES the branch delete on the
#    next line with "cannot delete branch used by worktree at ...". That line
#    swallowed its status and the function printed "ROLLED BACK" regardless,
#    so a failed creation reported a cleanup that had not happened. Both
#    halves are covered here.
#
#    The failure is injected with a `git` shim on PATH that forwards every
#    call to the real git except the ones named in SHIM_FAIL. Making the real
#    removal fail on demand is not otherwise reachable from a test, and an
#    unreachable failure path is how this one stayed wrong.
SHIM="$SANDBOX/shim"
mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
cat >"$SHIM/git" <<SHIMEOF
#!/usr/bin/env bash
# Forwards to the real git; fails only the subcommands named in SHIM_FAIL.
args=("\$@"); sub=""; rest=""
i=0
while [ \$i -lt \${#args[@]} ]; do
    case "\${args[\$i]}" in
        -C|-c) i=\$((i + 2)); continue ;;
        -*)    i=\$((i + 1)); continue ;;
        *)     sub="\${args[\$i]}"; rest="\${args[\$((i + 1))]:-}"; break ;;
    esac
done
case " \${SHIM_FAIL:-} " in
    *" worktree-remove "*)
        [ "\$sub" = "worktree" ] && [ "\$rest" = "remove" ] && {
            echo "shim: simulated worktree-removal failure" >&2; exit 1; } ;;
esac
case " \${SHIM_FAIL:-} " in
    *" branch-delete "*)
        [ "\$sub" = "branch" ] && [ "\$rest" = "-D" ] && {
            echo "shim: simulated branch-delete failure" >&2; exit 1; } ;;
esac
exec "$REAL_GIT" "\$@"
SHIMEOF
chmod +x "$SHIM/git"

# Positive control for the shim itself: with SHIM_FAIL empty it must be
# indistinguishable from real git, or every verdict below is about the shim.
if PATH="$SHIM:$PATH" git -C "$REPO" rev-parse --verify -q HEAD >/dev/null \
   && [ "$(PATH="$SHIM:$PATH" SHIM_FAIL="worktree-remove" git -C "$REPO" worktree remove --force /nonexistent >/dev/null 2>&1; echo $?)" -eq 1 ]; then
    ok "C21  the git shim passes real calls through and fails only the named subcommand (control)"
else
    bad "C21  shim control: passthrough or injection is not behaving"
fi

# 6a. Removal fails -> the fallback runs -> rollback is still COMPLETE.
N1="$(grep -c . "$RICHOS_WORKTREE_LEDGER")"
OUT="$(PATH="$SHIM:$PATH" SHIM_FAIL="worktree-remove" \
       RICHOS_WORKTREE_LEDGER=/nonexistent-dir/ledger.jsonl "$HELPER" "$REPO" norm-opus-ct21 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && [ ! -e "$SANDBOX/repo-wt/norm-opus-ct21" ] && printf '%s' "$OUT" | grep -q 'ROLLED BACK' \
   && ! git -C "$REPO" rev-parse --verify -q refs/heads/norm-opus-ct21 >/dev/null \
   && ! git -C "$REPO" worktree list --porcelain | grep -q 'norm-opus-ct21' \
   && [ ! -d "$REPO/.git/worktrees/norm-opus-ct21" ]; then
    ok "C22  removal failing does NOT strand the branch: the fallback drops only THIS tree's registration, branch and admin dir gone, exit 5"
else
    bad "C22  fallback rollback (rc=$rc): $OUT / admin=$(ls "$REPO/.git/worktrees" 2>/dev/null | tr '\n' ' ')"
fi
[ "$(grep -c . "$RICHOS_WORKTREE_LEDGER")" -eq "$N1" ] && ok "C23  the fallback rollback wrote nothing to the real ledger" || bad "C23  fallback rollback wrote to the ledger"

# 6b. AN UNRELATED registration whose directory is merely absent must SURVIVE
#     the rollback. This is the harm a bulk `git worktree prune` would do, and
#     the reason the targeted delete is targeted.
git -C "$REPO" worktree add -q "$SANDBOX/bystander" -b bystander-opus-ct1
rm -rf "$SANDBOX/bystander"          # dir gone, registration deliberately left
OUT="$(PATH="$SHIM:$PATH" SHIM_FAIL="worktree-remove" \
       RICHOS_WORKTREE_LEDGER=/nonexistent-dir/ledger.jsonl "$HELPER" "$REPO" norm-opus-ct22 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && git -C "$REPO" rev-parse --verify -q refs/heads/bystander-opus-ct1 >/dev/null \
   && [ -d "$REPO/.git/worktrees/bystander" ]; then
    ok "C24  an unrelated registration whose directory is absent SURVIVES the rollback (no bulk prune)"
else
    bad "C24  bystander (rc=$rc): admin=$(ls "$REPO/.git/worktrees" 2>/dev/null | tr '\n' ' ')"
fi

# 6c. WHEN THE CLEANUP CANNOT COMPLETE, SAY SO. Report the artifact, never the
#     command: the branch delete is made to fail, so the branch survives, so
#     the message must name it and the exit code must not be the success code.
OUT="$(PATH="$SHIM:$PATH" SHIM_FAIL="worktree-remove branch-delete" \
       RICHOS_WORKTREE_LEDGER=/nonexistent-dir/ledger.jsonl "$HELPER" "$REPO" norm-opus-ct23 2>&1)"; rc=$?
if [ "$rc" -eq 6 ] && printf '%s' "$OUT" | grep -q 'ROLLBACK INCOMPLETE' \
   && printf '%s' "$OUT" | grep -q 'branch: *norm-opus-ct23' \
   && ! printf '%s' "$OUT" | grep -q 'ROLLED BACK'; then
    ok "C25  a rollback that could NOT finish exits 6 and names what survived — it never claims a cleanup it did not achieve"
else
    bad "C25  incomplete rollback (rc=$rc): $OUT"
fi
git -C "$REPO" branch -D norm-opus-ct23 >/dev/null 2>&1 || true

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== create-teammate-worktree tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== create-teammate-worktree tests: all $PASS passed ==="

# The mutation harness is part of this suite's definition of green: a suite
# nobody has watched go red proves nothing (open-items rows 3.22-3.29).
if [ -f "$SCRIPT_DIR/create-teammate-worktree.mutation.sh" ]; then
    bash "$SCRIPT_DIR/create-teammate-worktree.mutation.sh" || exit 1
fi
exit 0
