#!/usr/bin/env bash
#
# guard-main-checkout-writes.test.sh — regression tests for the main-checkout
# write guard. Feeds synthetic PreToolUse JSON to the hook and asserts exit
# codes. Protected trees are read from orchestration.config so the fixtures
# track whatever an adopter configures. Run directly:
#   scripts/hooks/guard-main-checkout-writes.test.sh
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-main-checkout-writes.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Mirror the hook's own config resolution so the fixtures use the same
# protected trees the hook will enforce.
CONFIG="$REPO_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${PROTECTED_PATHS:=}"
# First protected tree, for the worktree-allow fixture.
set -- $PROTECTED_PATHS
FIRST_PROTECTED="${1:-src}"

PASS=0
FAIL=0

# run_case <name> <expected-exit> <json>
run_case() {
    local name="$1" expected="$2" json="$3"
    local actual
    printf '%s' "$json" | "$HOOK" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

json_write() { # <tool> <file_path>
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"
}

# make_fakebin_no_python3 — a PATH dir populated with symlinks to every
# external tool the hook needs EXCEPT python3, so `command -v python3` fails
# while everything else the hook shells out to still resolves normally.
# Mirrors the automation QA's fail-open repro (PATH lacking python3).
make_fakebin_no_python3() {
    local dir
    dir="$(mktemp -d -t fakebin-no-python3.XXXXXX)"
    local tools="cat grep sed cut tr date mkdir git mktemp basename dirname rm ln awk sort uniq wc head tail shasum sha256sum env"
    local t p
    for t in $tools; do
        p="$(command -v "$t" 2>/dev/null || true)"
        [ -n "$p" ] && ln -sf "$p" "$dir/$t"
    done
    echo "$dir"
}
BASH_BIN="$(command -v bash)"

echo "=== guard-main-checkout-writes tests ==="
echo "  (protected trees from orchestration.config: ${PROTECTED_PATHS:-<none>})"

# --- BLOCKED: source writes in the main checkout, one case per protected tree ---
if [ -z "${PROTECTED_PATHS// /}" ]; then
    printf '  FAIL  no PROTECTED_PATHS configured — cannot exercise the block path\n'
    FAIL=$((FAIL + 1))
else
    for p in $PROTECTED_PATHS; do
        run_case "Write to main $p source"  2 "$(json_write Write "$REPO_ROOT/$p/module/file.txt")"
        run_case "Edit to main $p source"   2 "$(json_write Edit  "$REPO_ROOT/$p/lib/file.txt")"
    done
    # NotebookEdit under the first protected tree.
    run_case "NotebookEdit under $FIRST_PROTECTED" 2 \
        "$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$REPO_ROOT/$FIRST_PROTECTED/analysis.ipynb")"
fi

# --- ALLOWED: docs/config in the main checkout ---
run_case "Write to docs"                0 "$(json_write Write "$REPO_ROOT/docs/some-doc.md")"
run_case "Edit CLAUDE.md"               0 "$(json_write Edit  "$REPO_ROOT/CLAUDE.md")"
run_case "Write to scripts"             0 "$(json_write Write "$REPO_ROOT/scripts/foo.sh")"
run_case "Write to team"                0 "$(json_write Write "$REPO_ROOT/team/someone.md")"
run_case "Write to .claude agents"      0 "$(json_write Write "$REPO_ROOT/.claude/agents/mark.md")"

# --- ALLOWED: worktree paths, even for protected source ---
run_case "Write protected source inside native worktree" 0 \
    "$(json_write Write "$REPO_ROOT/.claude/worktrees/agent-abc123/$FIRST_PROTECTED/module/file.txt")"
run_case "Write protected source inside manual worktree" 0 \
    "$(json_write Write "$REPO_ROOT/.claude/worktrees/dev-1/$FIRST_PROTECTED/lib/file.txt")"

# --- ALLOWED: pass-through cases ---
run_case "Non-write tool (Bash)"        0 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run_case "Missing file_path"            0 '{"tool_name":"Write","tool_input":{}}'
run_case "Relative path"                0 "$(json_write Write "$FIRST_PROTECTED/module/file.txt")"
run_case "Path outside repo"            0 "$(json_write Write "/tmp/scratch/notes.md")"
run_case "Malformed JSON"               0 'this is not json'

# --- python3 missing from PATH -> BLOCKED (fail-closed), loud stderr ---
# Mirrors the automation QA's repro: with no python3 resolvable on PATH, the guard must
# refuse a protected-path write (non-zero exit) rather than silently allowing it.
FAKEBIN="$(make_fakebin_no_python3)"
NOPY_JSON="$(json_write Write "$REPO_ROOT/$FIRST_PROTECTED/module/file.txt")"
NOPY_OUT="$(printf '%s' "$NOPY_JSON" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" 2>&1 1>/dev/null)"
NOPY_RC=$?
if [ "$NOPY_RC" -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  python3 missing from PATH -> BLOCKS a protected write (exit %s)\n' "$NOPY_RC"
else
    FAIL=$((FAIL + 1)); printf '  FAIL  python3 missing from PATH -> expected non-zero exit, got 0 (FAIL-OPEN)\n'
fi
if printf '%s' "$NOPY_OUT" | grep -qF 'python3'; then
    PASS=$((PASS + 1)); printf '  PASS  python3-missing stderr names the missing interpreter\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  python3-missing stderr did not mention python3 (%s)\n' "$NOPY_OUT"
fi
rm -rf "$FAKEBIN"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-main-checkout-writes tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== guard-main-checkout-writes tests: all $PASS passed ==="
    exit 0
fi
