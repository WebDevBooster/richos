#!/usr/bin/env bash
#
# create-teammate-worktree.test.sh — behavioral tests for the one command that
# creates a cc/ workspace (docs/plans/worktree-spec-2026-09-11.md, points 1-3).
#
# The helper REGISTERS the workspace in the workspace registry before anything
# exists on disk, creates it on a cc/ branch, seeds .worktreeinclude, confirms
# the registration, and deletes nothing. Every case is two-sided where a verdict
# is involved. HOME, CLAUDE_CONFIG_DIR and the registry are pinned into the
# sandbox and the session is a process of the suite's own, so no case can touch
# the operator's record.
#
# Run directly: scripts/create-teammate-worktree.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/create-teammate-worktree.sh"
WS_PY="$SCRIPT_DIR/lib/workspaces.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t create-teammate-wt.XXXXXX)" && pwd -P)"
SESS_PID="$(sh -c 'sleep 3600 >/dev/null 2>&1 & echo $!')"
trap 'kill "$SESS_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$HELPER" ] || { echo "FATAL: helper missing/non-executable: $HELPER" >&2; exit 1; }

export HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude"
export RICHOS_WORKSPACES_DIR="$SANDBOX/workspaces"
export RICHOS_SESSION_PID="$SESS_PID" RICHOS_SESSION_ID="feedface-0000-4000-8000-000000000001"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$CLAUDE_CONFIG_DIR"
REC() { printf '%s/agents/%s--%s.json' "$RICHOS_WORKSPACES_DIR" "${2:-$RICHOS_SESSION_ID}" "$1"; }

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

# 1. THE HAPPY PATH: created at <repo>-wt/<name>, on branch cc/<name> from HEAD,
#    seeded, and REGISTERED with path/repo/branch/session.
OUT="$("$HELPER" "$REPO/app" echo-opus-ct1 2>&1)"; rc=$?
WT="$SANDBOX/repo-wt/echo-opus-ct1"
if [ "$rc" -eq 0 ] && [ -d "$WT" ] \
   && [ "$(git -C "$WT" symbolic-ref -q --short HEAD)" = "cc/echo-opus-ct1" ] \
   && [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse HEAD)" ]; then
    ok "C01  creates <repo>-wt/<name> on branch cc/<name> at the main checkout's HEAD (point 1)"
else
    bad "C01  create (rc=$rc): $OUT"
fi
if [ -f "$WT/.envrc" ] && [ -f "$WT/app/.env.local" ] && [ -f "$WT/app/deep/.env.local" ] \
   && [ ! -f "$WT/app/other.local" ] && printf '%s' "$OUT" | grep -q 'seeded:     3 file(s)'; then
    ok "C02  seeds every gitignored file matching .worktreeinclude (root and nested), nothing else"
else
    bad "C02  seeding: $(ls -la "$WT" "$WT/app" 2>/dev/null | tr '\n' ' ')"
fi
if python3 - "$(REC echo-opus-ct1)" "$WT" "$REPO" <<'PY' 2>/dev/null
import json, os, sys
r = json.load(open(sys.argv[1]))
assert r["name"] == "echo-opus-ct1" and r["session_id"] == "feedface-0000-4000-8000-000000000001", r
w = r["workspaces"][0]
assert w["kind"] == "cc" and w["branch"] == "cc/echo-opus-ct1" and w["created"] is True, w
assert os.path.realpath(w["path"]) == os.path.realpath(sys.argv[2]), w
assert os.path.realpath(w["repo"]) == os.path.realpath(sys.argv[3]), w
assert r["session_identity"]["pid"] and r["session_identity"]["pid_start"], r
PY
then ok "C03  the workspace is REGISTERED: name, session, repo, exact path, cc/ branch, created, and the session's process identity (point 3)"
else bad "C03  registration: $(cat "$(REC echo-opus-ct1)" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"; fi
if printf '%s' "$OUT" | grep -q 'isolation: "worktree"' \
   && printf '%s' "$OUT" | grep -q "cross-repo-worktree: $WT" \
   && printf '%s' "$OUT" | grep -q 'prepare-agent-spawn.py' \
   && ! printf '%s' "$OUT" | grep -q 'cwd: "'; then
    ok "C05  prints native+external and acknowledgement preparation; never recommends cwd-only"
else
    bad "C05  spawn contract: $OUT"
fi

# 2. REFUSALS, each named. Nothing is created and nothing is registered.
N0="$(ls "$RICHOS_WORKSPACES_DIR/agents" | wc -l | tr -d ' ')"
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
git -C "$REPO" branch codex/their-fix HEAD
"$HELPER" "$REPO" echo-opus-cx1 --base codex/their-fix >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && [ ! -d "$SANDBOX/repo-wt/echo-opus-cx1" ] && ok "C12b refuses a codex/ base: an agent works from a copy, never inside codex/ (point 2)" || bad "C12b codex base rc=$rc"
[ "$(ls "$RICHOS_WORKSPACES_DIR/agents" | wc -l | tr -d ' ')" -eq "$N0" ] && ok "C13  no refusal wrote a registration" || bad "C13  a refusal wrote a registration"

# 3. --dir, --base and --session are honored.
git -C "$REPO" branch older-base HEAD
OUT="$("$HELPER" "$REPO" mark-sonnet-ct7 --dir "$SANDBOX/elsewhere/mark-sonnet-ct7" --base older-base --session cafebabe-0000-4000-8000-000000000002 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -d "$SANDBOX/elsewhere/mark-sonnet-ct7" ] && [ -f "$(REC mark-sonnet-ct7 cafebabe-0000-4000-8000-000000000002)" ]; then
    ok "C14  --dir, --base and --session are honored (registered under the named session)"
else
    bad "C14  options (rc=$rc): $OUT"
fi

# 4. REGISTRATION FIRST: when it cannot be written, NOTHING is created (point 3).
OUT="$(RICHOS_WORKSPACES_DIR=/nonexistent-dir/registry "$HELPER" "$REPO" norm-opus-ct8 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && [ ! -e "$SANDBOX/repo-wt/norm-opus-ct8" ] \
   && ! git -C "$REPO" rev-parse --verify -q refs/heads/cc/norm-opus-ct8 >/dev/null \
   && printf '%s' "$OUT" | grep -q 'could not be registered, so it was not created'; then
    ok "C17  an unregistrable workspace is NEVER CREATED: no directory, no branch (point 3)"
else
    bad "C17  unregistrable (rc=$rc): $OUT"
fi

# 5. NO SESSION PROCESS -> refused before anything exists: a registration that
#    could never tell its session ended is not a registration (point 12).
OUT="$(RICHOS_SESSION_PID=999999 "$HELPER" "$REPO" norm-opus-ct9 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && [ ! -e "$SANDBOX/repo-wt/norm-opus-ct9" ] && printf '%s' "$OUT" | grep -q 'process identity'; then
    ok "C19  no readable session process -> refused, nothing created"
else
    bad "C19  no-session (rc=$rc): $OUT"
fi
"$HELPER" "$REPO" norm-opus-ct9 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -d "$SANDBOX/repo-wt/norm-opus-ct9" ] && ok "C20  the same call with a readable session succeeds (positive control)" || bad "C20  positive control rc=$rc"

# 6. CREATION FAILS AFTER REGISTRATION: recorded, NOTHING DELETED by the helper.
#    A `git` shim fails `worktree add` only.
SHIM="$SANDBOX/shim"
mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
cat >"$SHIM/git" <<SHIMEOF
#!/usr/bin/env bash
# Forwards to the real git; fails only 'worktree add'.
args=("\$@"); sub=""; rest=""
i=0
while [ \$i -lt \${#args[@]} ]; do
    case "\${args[\$i]}" in
        -C|-c) i=\$((i + 2)); continue ;;
        -*)    i=\$((i + 1)); continue ;;
        *)     sub="\${args[\$i]}"; rest="\${args[\$((i + 1))]:-}"; break ;;
    esac
done
[ "\$sub" = "worktree" ] && [ "\$rest" = "add" ] && { echo "shim: simulated worktree add failure" >&2; exit 1; }
exec "$REAL_GIT" "\$@"
SHIMEOF
chmod +x "$SHIM/git"
OUT="$(PATH="$SHIM:$PATH" "$HELPER" "$REPO" norm-opus-ct21 2>&1)"; rc=$?
if [ "$rc" -eq 4 ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("creation_failed"), r' "$(REC norm-opus-ct21)" 2>/dev/null \
   && printf '%s' "$OUT" | grep -q "page's own land"; then
    ok "C22  creation failing AFTER registration is RECORDED (creation_failed), exit 4; the helper deletes nothing"
else
    bad "C22  failed creation (rc=$rc): $OUT"
fi
if ! grep -qE 'worktree (remove|prune)|branch -D|rm -rf' "$HELPER"; then
    ok "C23  the helper contains no deletion: land and discard are the only deleters (points 4, 7)"
else
    bad "C23  the helper deletes something: $(grep -nE 'worktree (remove|prune)|branch -D|rm -rf' "$HELPER" | head -3)"
fi

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
