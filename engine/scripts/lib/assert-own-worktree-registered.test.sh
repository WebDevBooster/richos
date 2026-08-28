#!/usr/bin/env bash
#
# assert-own-worktree-registered.test.sh — regression tests for
# scripts/lib/assert-own-worktree-registered.sh (the Layer-1 zombie-path
# guard used by android/ios-install-fresh.sh).
#
# The guard proves a run's OWN working location is legitimate before it writes
# state: it must be the true main checkout, or a path currently REGISTERED in
# that main checkout's `git worktree list`. A reaped-then-recreated worktree
# directory (an orphaned background run outliving its agent) is unregistered
# and must be refused.
#
# Each case runs against an isolated sandbox git repo so we never touch the real
# repo. Sandbox-level verification is sufficient per the CEO directive — the
# end-to-end device path is exercised by the next routine QA install-fresh.
#
# Covers:
#   (a) main-checkout cwd                      -> return 0 (legit main run)
#   (b) registered linked worktree cwd         -> return 0 (legit worktree run)
#   (c) unregistered zombie dir cwd            -> return 1 (refuse) + NO dir created
#   (d) the refusal message names the zombie condition
#   (e) reaped-then-recreated dir (registration removed, path re-made) -> return 1
#
# Run directly: scripts/tests/assert-own-worktree-registered.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SRC="$SCRIPT_DIR/assert-own-worktree-registered.sh"

PASS=0
FAIL=0

if [ ! -f "$LIB_SRC" ]; then
    echo "FATAL: assert-own-worktree-registered.sh missing" >&2
    exit 1
fi

# make_sandbox — a fresh git repo with BOTH lib files copied in at their
# canonical relative location (scripts/lib/) so the guard's sibling-source of
# resolve-main-checkout.sh resolves inside the sandbox.
make_sandbox() {
    local root
    root="$(mktemp -d -t assert-own-wt.XXXXXX)"
    # macOS mktemp returns /var/... which is a symlink to /private/var/...;
    # canonicalize so cwd/pwd comparisons are byte-stable.
    root="$(cd "$root" && pwd)"
    mkdir -p "$root/scripts/lib"
    cp "$LIB_SRC" "$root/scripts/lib/assert-own-worktree-registered.sh"
    cp "$SCRIPT_DIR/resolve-main-checkout.sh" "$root/scripts/lib/resolve-main-checkout.sh"
    git init -q "$root"
    # NO local identity override: the fixture inherits the operator's real
    # global identity, which is what a machine-wide pre-commit identity guard
    # requires. A refused seed commit leaves the fixture with no branch and
    # every case below would fail for that reason instead of the one under test.
    printf 'seed\n' > "$root/README.md"
    git -C "$root" add -A
    git -C "$root" commit -q -m init
    echo "$root"
}

# run_case — source the sandbox lib and call the guard from <cwd>, asserting
# the return code. Runs in a subshell so cwd changes never leak.
# run_case <name> <expected-rc> <sandbox-root> <cwd> <repo_root>
run_case() {
    local name="$1" expected="$2" root="$3" cwd="$4" repo_root="$5" actual
    (
        cd "$cwd" 2>/dev/null || exit 99
        # shellcheck source=/dev/null
        . "$root/scripts/lib/assert-own-worktree-registered.sh"
        assert_own_worktree_registered "$root/scripts" "$repo_root" "test" >/dev/null 2>&1
    )
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected rc %s, got %s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL + 1))
    fi
}

echo "=== assert-own-worktree-registered tests ==="

# (a) main-checkout cwd -> legit
ROOT="$(make_sandbox)"
run_case "main checkout is legit" 0 "$ROOT" "$ROOT" "$ROOT"
rm -rf "$ROOT"

# (b) a REGISTERED linked worktree -> legit
ROOT="$(make_sandbox)"
git -C "$ROOT" worktree add -q "$ROOT/.claude/worktrees/agent-cafefeed01" -b worktree-cafefeed01 >/dev/null 2>&1
WT="$(cd "$ROOT/.claude/worktrees/agent-cafefeed01" && pwd)"
run_case "registered linked worktree is legit" 0 "$ROOT" "$WT" "$WT"
rm -rf "$ROOT"

# (c) an UNREGISTERED zombie dir under .claude/worktrees/ -> refuse, and the
# guard must NOT create any directory.
ROOT="$(make_sandbox)"
ZOMBIE="$ROOT/.claude/worktrees/agent-deaddead02"
mkdir -p "$ZOMBIE"   # a bare dir — never `git worktree add`ed (or since reaped)
ZOMBIE="$(cd "$ZOMBIE" && pwd)"
run_case "unregistered zombie dir is refused" 1 "$ROOT" "$ZOMBIE" "$ZOMBIE"
# The guard writes nothing; assert it created no state dir under the zombie.
if [ ! -e "$ZOMBIE/.claude" ] && [ ! -e "$ZOMBIE/scripts" ]; then
    printf '  PASS  guard created no directories under the zombie path\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  guard created directories under the zombie path\n'; FAIL=$((FAIL + 1))
fi
rm -rf "$ROOT"

# (d) refusal message names the zombie condition
ROOT="$(make_sandbox)"
ZOMBIE="$ROOT/.claude/worktrees/agent-deaddead03"
mkdir -p "$ZOMBIE"
ZOMBIE="$(cd "$ZOMBIE" && pwd)"
OUT="$(
    cd "$ZOMBIE" || exit 99
    . "$ROOT/scripts/lib/assert-own-worktree-registered.sh"
    assert_own_worktree_registered "$ROOT/scripts" "$ZOMBIE" "test" 2>&1 >/dev/null
)"
if printf '%s' "$OUT" | grep -qF "ZOMBIE-PATH ABORT"; then
    printf '  PASS  refusal message names the zombie-path condition\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  refusal message did not name the zombie-path condition\n'; FAIL=$((FAIL + 1))
fi
rm -rf "$ROOT"

# (e) reaped-then-recreated: register a worktree, `git worktree remove` it,
# then re-create the bare directory (the exact incident shape) -> refuse.
ROOT="$(make_sandbox)"
git -C "$ROOT" worktree add -q "$ROOT/.claude/worktrees/agent-beefbeef04" -b worktree-beefbeef04 >/dev/null 2>&1
git -C "$ROOT" worktree remove --force "$ROOT/.claude/worktrees/agent-beefbeef04" >/dev/null 2>&1
mkdir -p "$ROOT/.claude/worktrees/agent-beefbeef04"   # orphan re-creates the path
REVENANT="$(cd "$ROOT/.claude/worktrees/agent-beefbeef04" && pwd)"
run_case "reaped-then-recreated worktree is refused" 1 "$ROOT" "$REVENANT" "$REVENANT"
rm -rf "$ROOT"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== assert-own-worktree-registered tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== assert-own-worktree-registered tests: all $PASS passed ==="
    exit 0
fi
