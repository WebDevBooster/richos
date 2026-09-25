#!/usr/bin/env bash
#
# guard-land-lease-commands.test.sh: the operator fence's early Bash check
# (scripts/hooks/guard-land-lease-commands.sh, a module of dispatch-pretooluse.sh;
# spec r3 e7 item 1, Frank G1 points 2 and 3, and the measured additions of
# `reset` and `merge --abort`).
#
#   E1   `git commit` aimed at a fenced main checkout, no lease: refused (exit 2),
#        naming the acquire command
#   E2   the same command from the session that holds the lease: allowed
#   E3   G1 point 3: a commit in a linked worktree that sits INSIDE the main
#        checkout's directory (a femcboost native worktree) is allowed; the target
#        is decided by the checkout it runs in, never by a path prefix
#   E4   `cd <main> && git cherry-pick X` and a payload cwd in the main checkout
#        are both resolved to the main checkout and refused
#   E5   `git stash list`/`show` pass; `git stash` is refused
#   E6   a plain `git merge` is left to the fence (allowed here); `merge --abort`
#        and every `reset` form are refused (measured: the fence stops them only
#        after the tree is rewritten)
#   E7   commands that are not the listed Git verbs pass: `git log`, a word
#        "commit" outside git, `echo git commit`
#   E8   WITH THE SWITCH OFF nothing is refused, and a repository with no launcher
#        is never looked at
#   E9   through the real dispatcher (dispatch-pretooluse.sh Bash), the refusal
#        arrives as exit 2 with its text
#
# Usage: scripts/hooks/guard-land-lease-commands.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$SCRIPT_DIR/guard-land-lease-commands.sh"
# shellcheck source=../lib/operator-fences-fixture.sh
. "$ENGINE_ROOT/scripts/lib/operator-fences-fixture.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -8; FAIL=$((FAIL + 1)); return 0; }

ofx_init || exit 1
trap ofx_cleanup EXIT
ofx_repo main; R="$OFX_R"
ofx_install "$R" >/dev/null 2>&1 && ofx_on "$R" >/dev/null 2>&1
git -C "$R" -c core.hooksPath=/dev/null worktree add -q -b inner "$R/.claude/worktrees/agent-x" >/dev/null 2>&1
INNER="$R/.claude/worktrees/agent-x"
[ -d "$INNER" ] || { echo "fixture: no inner worktree"; exit 1; }
ofx_repo plain; P="$OFX_R"

payload() { # <command> [cwd]
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
        "$1" "${2:-$OFX}"
}
check() { # <expected rc> <id> <description> <command> [cwd]
    local out rc
    out="$(payload "$4" "${5:-$OFX}" | bash "$HOOK" 2>&1)"; rc=$?
    if [ "$rc" = "$1" ]; then ok "$2 $3"; else bad "$2 $3" "rc=$rc (expected $1) $out"; fi
    LAST_OUT="$out"
}

echo "=== guard-land-lease-commands: the early check (switch on) ==="
check 2 E1 "a commit aimed at the fenced main checkout without the lease is refused" "git -C $R commit -m x"
printf '%s' "$LAST_OUT" | grep -q "land-lease.sh acquire --repo $R" && ok "E1 the refusal names the acquire command" \
    || bad "E1 the refusal names the acquire command" "$LAST_OUT"

ofx_session A
ofx_in A "$(ofx_lease acquire --repo "$R")"
ofx_in A "printf '%s' '$(payload "git -C $R commit -m x")' | bash '$HOOK'"; rc=$?
[ "$rc" = 0 ] && ok "E2 the session holding the lease is allowed" || bad "E2 the session holding the lease is allowed" "rc=$rc $OFX_OUT"
ofx_in A "$(ofx_lease release --repo "$R")"
ofx_end A

check 0 E3 "a commit in a linked worktree INSIDE the main checkout's directory is allowed (G1 point 3)" "git -C $INNER commit -m x"
check 0 E3 "the same, reached by cd" "cd $INNER && git commit -am x"
check 2 E4 "cd <main> && git cherry-pick is resolved to the main checkout and refused" "cd $R && git cherry-pick abc123"
check 2 E4 "a bare git commit with the payload's cwd in the main checkout is refused" "git commit -am x" "$R"
check 0 E5 "git stash list passes" "git -C $R stash list"
check 0 E5 "git stash show passes" "git -C $R stash show"
check 2 E5 "git stash is refused" "git -C $R stash"
check 0 E6 "a plain merge is left to the fence (which stops it cleanly)" "git -C $R merge feat"
check 2 E6 "merge --abort is refused (measured: the fence stops it only after the tree is discarded)" "git -C $R merge --abort"
check 2 E6 "reset --hard is refused" "git -C $R reset --hard HEAD~1"
check 2 E6 "reset --merge is refused" "git -C $R reset --merge"
check 2 E6 "a path reset is refused too (it writes the shared index)" "git -C $R reset -- f.txt"
check 2 E6 "rebase is refused" "git -C $R rebase main"
check 2 E6 "revert is refused" "git -C $R revert HEAD"
check 2 E6 "am is refused" "git -C $R am < x.patch"
check 0 E7 "git log passes" "git -C $R log --oneline -3"
check 0 E7 "a word 'commit' outside git passes" "echo commit > $OFX/note"
check 0 E7 "echo git commit is not a git call" "echo git commit"
check 0 E8 "a repository with no launcher is never refused" "git -C $P commit -m x"

echo "=== the switch off ==="
ofx_off "$R" >/dev/null 2>&1
check 0 E8 "OFF: a commit in the main checkout is allowed" "git -C $R commit -m x"
check 0 E8 "OFF: merge --abort is allowed" "git -C $R merge --abort"
check 0 E8 "OFF: reset --hard is allowed" "git -C $R reset --hard"
ofx_on "$R" >/dev/null 2>&1

echo "=== through the dispatcher ==="
out="$(payload "git -C $R commit -m x" | bash "$SCRIPT_DIR/dispatch-pretooluse.sh" Bash 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "OPERATOR FENCE"; then
    ok "E9 dispatch-pretooluse.sh Bash runs this module and returns its refusal"
else
    bad "E9 dispatch-pretooluse.sh Bash runs this module and returns its refusal" "rc=$rc $out"
fi

# M: this rule's mutation harness (the verb list, the checkout-identity test,
# cd tracking, the holder's authorization, the switch).
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/land-lease-commands.mutation.sh" ]; then
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/land-lease-commands.mutation.sh"; then
        ok "M. every rule above has been watched fail"
    else
        bad "M. the mutation harness found a property this suite does not actually prove"
    fi
fi

printf 'guard-land-lease-commands: %d passed, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
