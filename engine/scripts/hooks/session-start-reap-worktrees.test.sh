#!/usr/bin/env bash
#
# session-start-reap-worktrees.test.sh — behavioral tests for the SessionStart
# worktree-reaper wrapper (scripts/hooks/session-start-reap-worktrees.sh).
#
# The wrapper is thin, but it is the trigger for the only hook-reachable code in
# this engine that DELETES things (scripts/reap-stale-worktrees.sh runs with
# --execute --unlock-stale on every session start). Two properties matter, and
# they pull in opposite directions:
#   1. It must actually sweep — a gutted wrapper silently re-creates the
#      stale-worktree backlog (43 of them upstream) with nothing reporting it.
#   2. It must never destroy unlanded work, and must never block a session
#      start (log-only / fail-open, like teammate-idle-handoff.sh).
# So every case below is run against a THROWAWAY git repo via the wrapper's
# REAP_WORKTREES_ROOT test override — the real .claude/worktrees/ is never
# touched. Wiring/hashing of the same chain is probe Layer Q's job
# (scripts/hooks/contract-integrity-probe.sh).
#
# Run directly: scripts/hooks/session-start-reap-worktrees.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- declare the root under test -------------------------------------------
# The hooks now resolve the governed repository from the SESSION (see
# scripts/lib/resolve-roots.sh), not from their own on-disk location. Run from
# a session seated in some OTHER repository, they would correctly resolve that
# repository, find no adoption marker, stand down — and every case below would
# pass by never running. Declaring the subject makes the suite independent of
# ambient session state, and exercises the env-override candidate for free.
RICHOS_ENTITY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export RICHOS_ENTITY_ROOT
# CLAUDE_PROJECT_DIR is deliberately cleared: leaving the launching session's
# value in place would leave a second, lower-precedence candidate pointing
# somewhere irrelevant, and a future precedence change would then alter these
# results silently.
unset CLAUDE_PROJECT_DIR

HOOK="$SCRIPT_DIR/session-start-reap-worktrees.sh"

PASS=0
FAIL=0
# `pwd -P` matters: on macOS mktemp returns a /var/... symlink while
# `git worktree list` reports the resolved /private/var/... path, so an
# unresolved sandbox root would silently defeat the reaper's path matching and
# every reap case would "pass" for the wrong reason.
SANDBOX="$(cd "$(mktemp -d -t reap-hook-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ ! -x "$HOOK" ]; then
    echo "FATAL: hook missing/non-executable: $HOOK" >&2
    exit 1
fi

# --- helpers ---------------------------------------------------------------

# make_repo <name> -> prints the repo path. A seeded git repo on `main` with an
# empty .claude/worktrees/, ready for agent-shaped linked worktrees.
make_repo() {
    local repo="$SANDBOX/$1"
    mkdir -p "$repo/.claude/worktrees"
    git -C "$repo" init -q -b main
    # NO local identity override: these throwaway fixtures inherit the
    # operator's real global identity, which is what the machine-wide
    # pre-commit identity guard requires. With a fake identity the seed commit
    # is REFUSED, the repo has no `main`, `git worktree add` fails, and every
    # reap case below silently exercises an empty repository.
    printf 'seed\n' >"$repo/seed.txt"
    # The adoption marker: this fixture stands in for a governed repository.
    printf 'PROTECTED_PATHS="src"\n' >"$repo/orchestration.config"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m seed
    printf '%s\n' "$repo"
}

# add_tree <repo> <id> -> creates .claude/worktrees/agent-<id> on branch
# worktree-agent-<id>, exactly like native isolation does.
add_tree() {
    local repo="$1" id="$2"
    git -C "$repo" worktree add -q -b "worktree-agent-$id" "$repo/.claude/worktrees/agent-$id"
}

# run_hook <repo> -> hook stdout in $OUT_HOOK; exit code in $RC. CALLED
# DIRECTLY, never inside $(...): a command substitution is a subshell, so RC
# never reached the caller and every `[ "$rc" -eq 0 ]` below was true by
# initialization. Found 2026-09-02 in the sibling suite.
RC=0
OUT_HOOK=""
run_hook() {
    OUT_HOOK="$(REAP_WORKTREES_ROOT="$1" "$HOOK" </dev/null 2>/dev/null)"
    RC=$?
}

json_context() { # <hook stdout> -> additionalContext string ("" if unparseable)
    printf '%s' "$1" | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
    print(d["hookSpecificOutput"]["additionalContext"])
except Exception:
    pass' 2>/dev/null
}

echo "=== session-start-reap-worktrees (SessionStart reaper wrapper) tests ==="

# 1. Nothing to reap -> exit 0, valid SessionStart JSON, reaped=0.
REPO="$(make_repo clean)"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && printf '%s' "$CTX" | grep -q 'reaped=0 skipped=0'; then
    ok "empty repo: exit 0 + SessionStart JSON reporting reaped=0"
else
    bad "empty repo (rc=$rc ctx=$CTX)"
fi

# 2. The emitted line is exactly ONE line of valid JSON naming SessionStart —
#    the harness parses it; a stray extra line would corrupt the transcript.
LINES="$(printf '%s\n' "$OUT" | grep -c .)"
if [ "$LINES" -eq 1 ] && printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"' 2>/dev/null; then
    ok "emits exactly one line of valid SessionStart JSON"
else
    bad "output shape (lines=$LINES out=$OUT)"
fi

# 3. A merged, clean, unlocked agent worktree IS reaped — worktree removed AND
#    its branch deleted (the anti-accumulation half of the contract).
REPO="$(make_repo reapable)"
add_tree "$REPO" "aaaa0001"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
BRANCH_GONE=1
git -C "$REPO" rev-parse --verify --quiet refs/heads/worktree-agent-aaaa0001 >/dev/null && BRANCH_GONE=0
if [ "$rc" -eq 0 ] && [ ! -d "$REPO/.claude/worktrees/agent-aaaa0001" ] && [ "$BRANCH_GONE" -eq 1 ] \
   && printf '%s' "$CTX" | grep -q 'reaped=1'; then
    ok "merged+clean worktree reaped (dir removed, branch deleted, reaped=1)"
else
    bad "merged+clean reap (rc=$rc dir=$([ -d "$REPO/.claude/worktrees/agent-aaaa0001" ] && echo present || echo gone) branch_gone=$BRANCH_GONE ctx=$CTX)"
fi

# 4. A DIRTY worktree survives (gate 3) — uncommitted teammate work is never
#    destroyed. This is the case that must never regress.
REPO="$(make_repo dirty)"
add_tree "$REPO" "bbbb0002"
printf 'unlanded work\n' >"$REPO/.claude/worktrees/agent-bbbb0002/unlanded.txt"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && [ -f "$REPO/.claude/worktrees/agent-bbbb0002/unlanded.txt" ] \
   && printf '%s' "$CTX" | grep -q 'reaped=0 skipped=1'; then
    ok "dirty worktree survives with its uncommitted file (skipped=1)"
else
    bad "dirty worktree (rc=$rc ctx=$CTX)"
fi

# 5. An UNMERGED branch survives (gate 2) — clean tree, but commits not yet in
#    the target branch: a landed-looking tree whose handoff was never merged.
REPO="$(make_repo unmerged)"
add_tree "$REPO" "cccc0003"
TREE="$REPO/.claude/worktrees/agent-cccc0003"
printf 'committed but unlanded\n' >"$TREE/work.txt"
git -C "$TREE" add work.txt
git -C "$TREE" commit -q -m "teammate work not yet landed"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && [ -d "$TREE" ] && printf '%s' "$CTX" | grep -q 'reaped=0 skipped=1'; then
    ok "unmerged branch survives (skipped=1)"
else
    bad "unmerged branch (rc=$rc dir=$([ -d "$TREE" ] && echo present || echo GONE) ctx=$CTX)"
fi

# 6. A LOCKED worktree survives (gate 1) — a lock means "possibly still live",
#    and a fresh lock is never broken even with --unlock-stale.
REPO="$(make_repo locked)"
add_tree "$REPO" "dddd0004"
git -C "$REPO" worktree lock "$REPO/.claude/worktrees/agent-dddd0004"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && [ -d "$REPO/.claude/worktrees/agent-dddd0004" ] && printf '%s' "$CTX" | grep -q 'reaped=0 skipped=1'; then
    ok "freshly-locked worktree survives (skipped=1)"
else
    bad "locked worktree (rc=$rc ctx=$CTX)"
fi

# 7. Non-agent worktrees and the repo itself are out of scope — only
#    .claude/worktrees/agent-* is ever considered.
REPO="$(make_repo scope)"
git -C "$REPO" worktree add -q -b feature-branch "$SANDBOX/scope-external"
add_tree "$REPO" "eeee0005"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
if [ "$rc" -eq 0 ] && [ -d "$SANDBOX/scope-external" ] && [ -f "$REPO/seed.txt" ] \
   && [ ! -d "$REPO/.claude/worktrees/agent-eeee0005" ]; then
    ok "hand-rolled worktree + main checkout untouched, agent tree still swept"
else
    bad "scope (rc=$rc external=$([ -d "$SANDBOX/scope-external" ] && echo present || echo GONE))"
fi

# 8. The reaper script is an ENGINE asset. Absent, the wrapper must still exit
#    0 (a session start is never held up) but must NOT call it a "skip" — that
#    wording is what let a broken plugin install read as routine for a whole
#    migration step. The fixture is therefore a stripped copy of the ENGINE,
#    not of the swept repository.
FAKE="$SANDBOX/no-reaper"
mkdir -p "$FAKE/scripts/hooks" "$FAKE/scripts/lib"
cp "$HOOK" "$FAKE/scripts/hooks/"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$FAKE/scripts/lib/"
printf 'PROTECTED_PATHS="src"\n' >"$FAKE/orchestration.config"   # adopted, so we reach the asset check
set +e
OUT="$(RICHOS_ENTITY_ROOT="$FAKE" "$FAKE/scripts/hooks/session-start-reap-worktrees.sh" </dev/null 2>/dev/null)"
rc=$?
set -e
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && printf '%s' "$CTX" | grep -q 'ENGINE INSTALL FAILURE'; then
    ok "missing reaper: exits 0 and calls it an INSTALL FAILURE, not a skip"
else
    bad "missing reaper (rc=$rc ctx=$CTX)"
fi
# 8b NEGATIVE — and it must not be describable as a skip. Asserted separately
# because "said something" and "said something that cannot be misread" differ,
# and only the second one closes the incident this change answers.
if ! printf '%s' "$CTX" | grep -qi 'skipped'; then
    ok "missing reaper: the word 'skipped' does not appear"
else
    bad "missing reaper still reports a 'skipped' (ctx=$CTX)"
fi

# 9. FAIL-OPEN: a target root that is not a git repo -> the reaper errors, the
#    wrapper still exits 0 and reports the absent summary line.
NOTGIT="$SANDBOX/not-a-repo"
mkdir -p "$NOTGIT"
run_hook "$NOTGIT"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && [ -n "$CTX" ]; then
    ok "non-git target: exits 0 with a diagnostic summary (fail-open)"
else
    bad "non-git target (rc=$rc ctx=$CTX)"
fi

# 10. Garbage on stdin (the harness sends SessionStart JSON; the hook ignores
#     it) must not change the outcome.
REPO="$(make_repo stdin)"
set +e
OUT="$(printf 'this is not json' | REAP_WORKTREES_ROOT="$REPO" "$HOOK" 2>/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -n "$(json_context "$OUT")" ]; then
    ok "garbage stdin is a silent no-op (exit 0, JSON still emitted)"
else
    bad "garbage stdin (rc=$rc out=$OUT)"
fi

# 11. Idempotence: a second sweep over an already-swept repo is a clean no-op.
REPO="$(make_repo idempotent)"
add_tree "$REPO" "ffff0006"
run_hook "$REPO"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && printf '%s' "$CTX" | grep -q 'reaped=0 skipped=0 errors=0'; then
    ok "second sweep is a clean no-op (reaped=0 errors=0)"
else
    bad "idempotent sweep (rc=$rc ctx=$CTX)"
fi

# 12. THE VERDICT LEADS. A hand-rolled worktree whose owner nobody recorded is
#     an UNRESOLVED owner: the reaper's verdict is FAIL, and the SessionStart
#     context line must open with it — never a success-shaped count first.
REPO="$(make_repo failing)"
git -C "$REPO" worktree add -q -b nobody-opus-x1 "$SANDBOX/failing-wt/nobody-opus-x1"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && printf '%s' "$CTX" | grep -q '^WORKTREE REAP FAIL \[' \
   && printf '%s' "$CTX" | grep -q 'verdict: FAIL — unresolved=1' \
   && [ -d "$SANDBOX/failing-wt/nobody-opus-x1" ]; then
    ok "an unjudgeable worktree makes the context line open with WORKTREE REAP FAIL (and nothing is removed)"
else
    bad "failing verdict (rc=$rc ctx=$CTX)"
fi
# 12b. NEGATIVE: with every candidate decided, the line is NOT a FAIL and
#      carries the CLEAN verdict.
REPO="$(make_repo clean-verdict)"
add_tree "$REPO" "aaaa0007"
run_hook "$REPO"; OUT="$OUT_HOOK"; rc=$RC
CTX="$(json_context "$OUT")"
if [ "$rc" -eq 0 ] && ! printf '%s' "$CTX" | grep -q 'WORKTREE REAP FAIL' \
   && printf '%s' "$CTX" | grep -q 'verdict: CLEAN'; then
    ok "a fully decided sweep reports verdict CLEAN and no FAIL banner"
else
    bad "clean verdict (rc=$rc ctx=$CTX)"
fi
# 12c. HERMETIC: the sandbox sweep wrote its witnessed termination into the
#      SANDBOX ledger, not the operator's record.
if [ -f "$REPO/.claude/state/worktree-ledger.jsonl" ] && grep -q '"agent_id": "aaaa0007"' "$REPO/.claude/state/worktree-ledger.jsonl"; then
    ok "under REAP_WORKTREES_ROOT the ledger write lands inside the sandbox"
else
    bad "ledger redirection (looked in $REPO/.claude/state/worktree-ledger.jsonl)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== session-start-reap-worktrees tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== session-start-reap-worktrees tests: all $PASS passed ==="
    exit 0
fi
