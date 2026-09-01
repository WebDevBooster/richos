#!/usr/bin/env bash
#
# agent-finished-reap-worktrees.test.sh — behavioral tests for the
# TeammateIdle/TaskCompleted reaper wrapper.
#
# The wrapper is thin, but it is the trigger that fires MOST OFTEN into the
# only hook-reachable code in this engine that DELETES things. Three properties
# matter and they pull against each other:
#
#   1. It must actually sweep. A wrapper that resolves nothing and exits 0 is
#      indistinguishable from a healthy one, and that shape has already been
#      shipped once here — probe Layer K was green for as long as its list had
#      existed, over a scanner that never ran.
#   2. It must never destroy unlanded work, and never block a teammate going
#      idle or a task completing (log-only / fail-open).
#   3. Under the REAP_WORKTREES_ROOT test override it must NOT discover other
#      repositories. That is not tidiness: this wrapper runs --execute, and a
#      discovering sandbox sweep would reach the operator's real checkouts from
#      inside a unit test.
#
# Every case runs against a THROWAWAY git repo through that override, so the
# real .claude/worktrees/ is never touched. Wiring and hashing of the same
# chain is probe Layer Q's job (Q1b, Q4, Q5).
#
# Run directly: scripts/hooks/agent-finished-reap-worktrees.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- declare the root under test -------------------------------------------
# Same reason as the sibling suite: hooks resolve the governed repository from
# the SESSION, so a run seated in some OTHER repository would correctly find no
# adoption marker, stand down, and let every case below pass by never running.
RICHOS_ENTITY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

HOOK="$SCRIPT_DIR/agent-finished-reap-worktrees.sh"

PASS=0
FAIL=0
# `pwd -P`: on macOS mktemp returns a /var/... symlink while `git worktree
# list` reports /private/var/..., and an unresolved root would silently defeat
# every path comparison in the reaper.
SANDBOX="$(cd "$(mktemp -d -t reap-finish-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ ! -x "$HOOK" ]; then
    echo "FATAL: hook missing/non-executable: $HOOK" >&2
    exit 1
fi

# --- helpers ---------------------------------------------------------------
# NO local git identity override: the fixtures inherit the operator's real
# global identity, which a machine-wide pre-commit identity guard requires.
# With a fake one the seed commit is REFUSED and every case below silently
# exercises an empty repository.
make_repo() { # <name> -> repo path
    local repo="$SANDBOX/$1"
    mkdir -p "$repo/.claude/worktrees"
    git -C "$repo" init -q -b main
    printf 'seed\n' >"$repo/seed.txt"
    printf 'PROTECTED_PATHS="src"\n' >"$repo/orchestration.config"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m seed
    printf '%s\n' "$repo"
}

add_tree() { # <repo> <id>
    git -C "$1" worktree add -q -b "worktree-agent-$2" "$1/.claude/worktrees/agent-$2"
}

RC=0
LOGDIR=""
run_hook() { # <repo> -> stderr text; exit code in $RC
    local out
    LOGDIR="$SANDBOX/teams-$RANDOM"
    mkdir -p "$LOGDIR/session-test"
    out="$(REAP_WORKTREES_ROOT="$1" REAP_TEAM_DIR="$LOGDIR" "$HOOK" </dev/null 2>&1 >/dev/null)"
    RC=$?
    printf '%s' "$out"
}

echo "=== agent-finished-reap-worktrees (TeammateIdle/TaskCompleted) tests ==="

# 1. Nothing to reap -> exit 0, and it SAYS it swept rather than saying nothing.
REPO="$(make_repo clean)"
OUT="$(run_hook "$REPO")"; rc=$RC
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'reaped=0'; then
    ok "empty repo: exit 0 and a summary reporting reaped=0"
else
    bad "empty repo (rc=$rc out=$OUT)"
fi

# 2. IT ACTUALLY SWEEPS. This is the whole point of a second trigger: a merged,
#    clean worktree is gone and its branch with it, WITHOUT waiting for the
#    next session to start.
REPO="$(make_repo reapable)"
add_tree "$REPO" "aaaa1001"
OUT="$(run_hook "$REPO")"; rc=$RC
BRANCH_GONE=1
git -C "$REPO" rev-parse --verify --quiet refs/heads/worktree-agent-aaaa1001 >/dev/null && BRANCH_GONE=0
if [ "$rc" -eq 0 ] && [ ! -d "$REPO/.claude/worktrees/agent-aaaa1001" ] && [ "$BRANCH_GONE" -eq 1 ]; then
    ok "merged+clean worktree reaped at agent-finish (dir removed, branch deleted)"
else
    bad "agent-finish reap (rc=$rc branch_gone=$BRANCH_GONE)"
fi

# 3. A DIRTY worktree survives. The case that must never regress, on the
#    trigger that fires most often.
REPO="$(make_repo dirty)"
add_tree "$REPO" "bbbb1002"
printf 'unlanded work\n' >"$REPO/.claude/worktrees/agent-bbbb1002/unlanded.txt"
OUT="$(run_hook "$REPO")"; rc=$RC
if [ "$rc" -eq 0 ] && [ -f "$REPO/.claude/worktrees/agent-bbbb1002/unlanded.txt" ]; then
    ok "dirty worktree survives with its uncommitted file"
else
    bad "dirty worktree (rc=$rc)"
fi

# 4. An UNMERGED branch survives — a landed-LOOKING tree whose handoff was
#    never merged.
REPO="$(make_repo unmerged)"
add_tree "$REPO" "cccc1003"
TREE="$REPO/.claude/worktrees/agent-cccc1003"
printf 'committed but unlanded\n' >"$TREE/work.txt"
git -C "$TREE" add work.txt
git -C "$TREE" commit -q -m "teammate work not yet landed"
OUT="$(run_hook "$REPO")"; rc=$RC
if [ "$rc" -eq 0 ] && [ -d "$TREE" ]; then
    ok "unmerged branch survives"
else
    bad "unmerged branch (rc=$rc)"
fi

# 5. A LOCKED worktree survives: a lock means possibly still live, and a fresh
#    one is never broken.
REPO="$(make_repo locked)"
add_tree "$REPO" "dddd1004"
git -C "$REPO" worktree lock "$REPO/.claude/worktrees/agent-dddd1004"
OUT="$(run_hook "$REPO")"; rc=$RC
if [ "$rc" -eq 0 ] && [ -d "$REPO/.claude/worktrees/agent-dddd1004" ]; then
    ok "freshly-locked worktree survives"
else
    bad "locked worktree (rc=$rc)"
fi

# 6. THE TEST OVERRIDE SUPPRESSES DISCOVERY. Without this the case above would
#    have run --execute against every repository beside the sandbox, including
#    the operator's own. The reaper declares the suppression, so it is
#    assertable rather than assumed.
REPO="$(make_repo scoped)"
OUT="$(run_hook "$REPO")"; rc=$RC
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'repos=1'; then
    ok "under REAP_WORKTREES_ROOT the sweep is confined to one repository"
else
    bad "discovery suppression (rc=$rc out=$OUT)"
fi

# 7. THE DENOMINATOR TRAVELS. The summary reports what it is a fraction of;
#    a bare `reaped=N` is the shape that read as a clean machine for months.
REPO="$(make_repo coverage)"
add_tree "$REPO" "eeee1005"
OUT="$(run_hook "$REPO")"; rc=$RC
if printf '%s' "$OUT" | grep -q 'coverage' && printf '%s' "$OUT" | grep -q 'worktrees='; then
    ok "the reported summary carries the coverage denominator"
else
    bad "coverage in summary (out=$OUT)"
fi

# 8. DURABLE AUDIT LINE. The transcript is not a record. A sweep nobody can
#    read afterwards is how a wrong summary survives.
REPO="$(make_repo audit)"
add_tree "$REPO" "ffff1006"
run_hook "$REPO" >/dev/null
LOG="$LOGDIR/session-test/reap-events.jsonl"
if [ -f "$LOG" ] && python3 -c '
import json, sys
rec = json.loads(open(sys.argv[1], encoding="utf-8").read().strip().splitlines()[-1])
assert rec["event"] == "AgentFinishedReap"
assert "summary" in rec and "blind" in rec and "reaped" in rec
assert any("agent-ffff1006" in r for r in rec["reaped"])
' "$LOG" 2>/dev/null; then
    ok "appends a durable reap-events.jsonl record naming what it reaped"
else
    bad "audit line (log=$LOG)"
fi

# 9. The reaper is an ENGINE asset. Absent, the wrapper must still exit 0 (a
#    teammate going idle is never held up) but must NOT call it a "skip" —
#    that wording is what let a broken plugin install read as routine for a
#    whole migration step.
FAKE="$SANDBOX/no-reaper"
mkdir -p "$FAKE/scripts/hooks" "$FAKE/scripts/lib"
cp "$HOOK" "$FAKE/scripts/hooks/"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$FAKE/scripts/lib/"
printf 'PROTECTED_PATHS="src"\n' >"$FAKE/orchestration.config"
set +e
OUT="$(RICHOS_ENTITY_ROOT="$FAKE" "$FAKE/scripts/hooks/agent-finished-reap-worktrees.sh" </dev/null 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'ENGINE INSTALL FAILURE' \
   && ! printf '%s' "$OUT" | grep -qi 'skipped'; then
    ok "missing reaper: exits 0, calls it an INSTALL FAILURE, never a skip"
else
    bad "missing reaper (rc=$rc out=$OUT)"
fi

# 10. FAIL-OPEN: a target that is not a git repo -> the reaper errors, the
#     wrapper still exits 0.
NOTGIT="$SANDBOX/not-a-repo"
mkdir -p "$NOTGIT"
OUT="$(run_hook "$NOTGIT")"; rc=$RC
if [ "$rc" -eq 0 ] && [ -n "$OUT" ]; then
    ok "non-git target: exits 0 with a diagnostic (fail-open)"
else
    bad "non-git target (rc=$rc)"
fi

# 11. Garbage on stdin is a no-op. This hook deliberately does not read the
#     payload — an unconditional read of an inherited pipe hangs forever, which
#     cost 92 seconds inside the integrity probe once already.
REPO="$(make_repo stdin)"
set +e
OUT="$(printf 'this is not json' | REAP_WORKTREES_ROOT="$REPO" "$HOOK" 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -n "$OUT" ]; then
    ok "garbage stdin is a silent no-op (exit 0, summary still produced)"
else
    bad "garbage stdin (rc=$rc)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== agent-finished-reap-worktrees tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== agent-finished-reap-worktrees tests: all $PASS passed ==="
    exit 0
fi
