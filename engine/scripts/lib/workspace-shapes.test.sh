#!/usr/bin/env bash
#
# workspace-shapes.test.sh — the DECLARED allow-list and the closed-world
# report that reads it (scripts/lib/workspace-shapes.py,
# scripts/lib/workspace-scope.py).
#
# What is proven here, each refusal beside its pass: every one of the four
# real shapes on this machine classifies to the right kind and says which
# property it read; the declaration is DATA, so a shape the config omits stops
# being ours; a codex workspace is classified by name in BOTH of its shapes and
# never as ours; and the report gives EVERY worktree of a repository exactly
# one disposition with a reason, including one that no record names.
#
# Every repository here is disposable and every store is redirected. The report
# is read-only by construction, so a failure in this file cannot cost a
# workspace.
#
# Run directly: scripts/lib/workspace-shapes.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHAPES_PY="$SCRIPT_DIR/workspace-shapes.py"
SCOPE_PY="$SCRIPT_DIR/workspace-scope.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t workspace-shapes-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$SHAPES_PY" ] || { echo "FATAL: missing $SHAPES_PY" >&2; exit 1; }
[ -f "$SCOPE_PY" ]  || { echo "FATAL: missing $SCOPE_PY" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
export RICHOS_WORKTREE_LEDGER="$SANDBOX/ledger.jsonl"
export RICHOS_WORKTREE_CAPTURE_DIR="$SANDBOX/captures"
export RICHOS_DAILY_PROCESSES=none
export RICHOS_SESSION_PROCESSES=none
export RICHOS_SESSIONS_DIR="$SANDBOX/no-sessions"
mkdir -p "$RICHOS_SESSIONS_DIR"
# No global or system configuration reaches a disposable fixture repository:
# the operator's hooks and identity are not part of what this suite tests, and
# the same isolation is what every other suite in this engine uses.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

kind() { python3 "$SHAPES_PY" "$1" --branch "${2:-}" ${3:+--repo "$3"} | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])'; }
why()  { python3 "$SHAPES_PY" "$1" --branch "${2:-}" ${3:+--repo "$3"} | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])'; }

echo "=== workspace-shapes tests ==="

# --- 1. the four shapes, on the exact paths this machine carries ------------
V="$(kind /Users/alex/ab/richos-wt/x cc/zach-opus-x)"
[ "$V" = "cc-branch" ] && ok "S01  a cc/ branch is ours -- the prefix this engine writes on a ref it created" \
    || bad "S01  expected cc-branch, got '$V'"

V="$(kind /Users/alex/ab/femcboost/.claude/worktrees/agent-a42c9 worktree-agent-a42c9)"
[ "$V" = "native-agent" ] && ok "S02  the harness's own isolation worktree is ours by DECLARATION (we cannot rename these)" \
    || bad "S02  expected native-agent, got '$V'"

V="$(kind /Users/alex/ab/richos-wt/zach-opus-red1 zach-opus-red1)"
[ "$V" = "legacy-teammate" ] && ok "S03  the pre-cc/ convention is still ours: -wt/ location + enforced spawn shape + branch == directory, three properties coinciding" \
    || bad "S03  expected legacy-teammate, got '$V'"

V="$(kind /private/tmp/ci-base main)"
[ "$V" = "not-ours" ] && ok "S04  a CI checkout is NOT OURS -- which is a decision, not an unknown" \
    || bad "S04  expected not-ours, got '$V'"

# --- 2. the two shapes of the CEO's codex ruling ----------------------------
V="$(kind /Users/alex/ab/richos-wt/codex-rollback codex/rollback)"
R="$(why /Users/alex/ab/richos-wt/codex-rollback codex/rollback)"
if [ "$V" = "codex" ] && printf '%s' "$R" | grep -q 'excluded by CEO ruling'; then
    ok "S05  a codex/ branch is EXCLUDED BY NAME (ceo-decisions.md 31 asks for the words, not merely for the omission)"
else
    bad "S05  expected a named codex exclusion, got '$V' -- $R"
fi

V="$(kind /Users/alex/.codex/worktrees/06e6/femcboost main)"
[ "$V" = "codex" ] && ok "S06  ...and so is a worktree under ~/.codex/, whose branch is main and whose directory is not codex-anything: a branch-only test misses two of the nine" \
    || bad "S06  expected codex for the .codex path, got '$V'"

# --- 3. the declaration is DATA ---------------------------------------------
NARROW="$SANDBOX/narrow"; mkdir -p "$NARROW"
printf 'OWNED_WORKSPACE_SHAPES="cc-branch"\n' >"$NARROW/orchestration.config"
V="$(kind /Users/alex/ab/richos-wt/zach-opus-red1 zach-opus-red1 "$NARROW")"
[ "$V" = "not-ours" ] && ok "S07  an entity that declares only cc-branch stops owning the legacy shape -- retiring a convention is one word in a config file" \
    || bad "S07  expected not-ours under a narrowed declaration, got '$V'"
V="$(kind /Users/alex/ab/richos-wt/x cc/zach-opus-x "$NARROW")"
[ "$V" = "cc-branch" ] && ok "S08  ...and the shape it DOES declare is unaffected (the negative control for S07)" \
    || bad "S08  expected cc-branch under the narrowed declaration, got '$V'"

# --- 4. the closed-world report ---------------------------------------------
# One disposable repository with four worktrees: ours-and-ready, ours-and-held
# (unmerged), codex, and a stranger. Nothing in the ledger names any of them,
# which is the case the old tools could say nothing about at all.
REPO="$SANDBOX/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "fixture@example.invalid"
git -C "$REPO" config user.name "Fixture"
printf 'seed\n' >"$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m seed
WTS="$SANDBOX/repo-wt"; mkdir -p "$WTS"
git -C "$REPO" worktree add -q -b cc/zach-opus-s1 "$WTS/zach-opus-s1"
git -C "$REPO" worktree add -q -b cc/zach-opus-s2 "$WTS/zach-opus-s2"
printf 'undelivered\n' >"$WTS/zach-opus-s2/seed.txt"
git -C "$WTS/zach-opus-s2" commit -qam 'not in main'
git -C "$REPO" worktree add -q -b codex/s3 "$WTS/codex-s3"
git -C "$REPO" worktree add -q -b operator-tree "$WTS/operator-tree"
printf '%s\n' "$REPO" >"$SANDBOX/known-repos.txt"

OUT="$(HOME="$SANDBOX" RICHOS_KNOWN_REPOS="$SANDBOX/known-repos.txt" python3 "$SCOPE_PY" --json 2>&1)"
row() { printf '%s' "$OUT" | python3 -c '
import json,sys
want = sys.argv[1]
for r in json.load(sys.stdin)["rows"]:
    if r["path"].endswith(want):
        print(r["disposition"] + "\t" + r["reason"]); break
else:
    print("MISSING\t")
' "$1"; }

D="$(row /zach-opus-s1 | cut -f1)"
[ "$D" = "OURS-READY" ] && ok "S10  the report gives a clean, merged, allow-listed worktree the disposition OURS-READY" \
    || bad "S10  expected OURS-READY for zach-opus-s1, got '$D' -- $(row /zach-opus-s1 | cut -f2)"

D="$(row /zach-opus-s2 | cut -f1)"; R="$(row /zach-opus-s2 | cut -f2)"
if [ "$D" = "OURS-HELD" ] && printf '%s' "$R" | grep -qi 'no ownership record\|does not contain\|no longer contains'; then
    ok "S11  an UNMERGED one is OURS-HELD with the cause named -- never swept, and never reported as a shrug"
else
    bad "S11  expected OURS-HELD with a cause for zach-opus-s2, got '$D' -- $R"
fi

D="$(row /codex-s3 | cut -f1)"; R="$(row /codex-s3 | cut -f2)"
if [ "$D" = "EXCLUDED" ] && printf '%s' "$R" | grep -q 'excluded by CEO ruling'; then
    ok "S12  a codex workspace is REPORTED as excluded by CEO ruling -- present in the report, never silently absent"
else
    bad "S12  expected EXCLUDED for codex-s3, got '$D' -- $R"
fi

D="$(row /operator-tree | cut -f1)"
[ "$D" = "NOT-OURS" ] && ok "S13  an operator's own worktree is NOT-OURS: declared someone else's rather than left unknown" \
    || bad "S13  expected NOT-OURS for operator-tree, got '$D'"

MISSING="$(printf '%s' "$OUT" | python3 -c '
import json,sys
rows = json.load(sys.stdin)["rows"]
bad = [r for r in rows if not r.get("disposition") or not r.get("reason")]
print(len(bad))
')"
TOTAL="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))')"
if [ "$MISSING" = "0" ] && [ "$TOTAL" -ge 4 ]; then
    ok "S14  EVERY row carries a disposition AND a reason ($TOTAL rows, 0 without one) -- the closed world is closed"
else
    bad "S14  $MISSING of $TOTAL rows had no disposition or no reason"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== workspace-shapes tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== workspace-shapes tests: all $PASS passed ==="

if [ -f "$SCRIPT_DIR/workspace-shapes.mutation.sh" ]; then
    bash "$SCRIPT_DIR/workspace-shapes.mutation.sh" || exit 1
fi
exit 0
