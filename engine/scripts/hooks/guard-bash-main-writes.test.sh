#!/usr/bin/env bash
#
# guard-bash-main-writes.test.sh — regression tests for the Bash-write guard.
# Feeds synthetic PreToolUse[Bash] JSON to the hook and asserts exit codes.
# Protected trees are read from orchestration.config so the fixtures track
# whatever an adopter configures. Run directly:
#   scripts/hooks/guard-bash-main-writes.test.sh
#
# Exit 0 = all cases pass; exit 1 = at least one failure.
#
# DETERMINISM NOTE: the hook resolves REPO_ROOT to the TRUE main checkout (via
# scripts/lib/resolve-main-checkout.sh). To make the suite independent of where
# it is run (main checkout OR a linked worktree whose path contains
# "/.claude/worktrees/"), it builds a synthetic temp root, seeds it with an
# orchestration.config carrying the SAME PROTECTED_PATHS the adopter configured,
# copies the hook + resolver lib in, and drives every case against paths under
# that temp root. The temp root is a plain (non-git) tmpdir, so the resolver
# takes its no-git fallback = the temp root.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_HOOK="$SRC_DIR/guard-bash-main-writes.sh"
ENGINE_ROOT="$(cd "$SRC_DIR/../.." && pwd)"

# Read the adopter's protected trees from the real config.
CONFIG="$ENGINE_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${PROTECTED_PATHS:=}"

# Build the synthetic main checkout.
TMPROOT="$(mktemp -d -t guard-bash-main-writes.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/scripts/hooks" "$TMPROOT/scripts/lib"
cp "$SRC_HOOK" "$TMPROOT/scripts/hooks/guard-bash-main-writes.sh"
chmod +x "$TMPROOT/scripts/hooks/guard-bash-main-writes.sh"
cp "$SRC_DIR/../lib/resolve-main-checkout.sh" "$TMPROOT/scripts/lib/" 2>/dev/null || true
# The hook's bootstrap resolves its library relative to its OWN location, so a
# sandbox hosting a copy of the hook must host the library too — otherwise the
# hook correctly refuses to start ("BROKEN INSTALL") and every case below would
# fail for that reason rather than the one under test.
cp "$SRC_DIR/../lib/resolve-roots.sh" "$TMPROOT/scripts/lib/"
printf 'PROTECTED_PATHS="%s"\n' "$PROTECTED_PATHS" > "$TMPROOT/orchestration.config"
HOOK="$TMPROOT/scripts/hooks/guard-bash-main-writes.sh"
ROOT="$TMPROOT"
# Declare the synthetic checkout as the governed root. Without this the hook
# would resolve the LAUNCHING session's repository, which is not what any case
# below is about.
RICHOS_ENTITY_ROOT="$TMPROOT"
export RICHOS_ENTITY_ROOT
WT="$ROOT/.claude/worktrees/agent-x"

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

# JSON builders (python3 does the escaping so command strings stay literal).
json_cmd() { # <command> [cwd]
    python3 -c '
import json, sys
d = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}
if len(sys.argv) > 2 and sys.argv[2]:
    d["cwd"] = sys.argv[2]
print(json.dumps(d))
' "$1" "${2:-}"
}

echo "=== guard-bash-main-writes tests ==="
echo "  (protected trees from orchestration.config: ${PROTECTED_PATHS:-<none>})"

# --- BLOCKED: writes into a protected tree in the main checkout ---
if [ -z "${PROTECTED_PATHS// /}" ]; then
    printf '  FAIL  no PROTECTED_PATHS configured — cannot exercise the block path\n'
    FAIL=$((FAIL + 1))
else
    for p in $PROTECTED_PATHS; do
        run_case "abs-path mkdir into main $p"      2 "$(json_cmd "mkdir -p $ROOT/$p/module/x")"
        run_case "cd-compound + relative $p write"  2 "$(json_cmd "cd $ROOT && mkdir $p/foo")"
        run_case "cwd-main + relative $p write"     2 "$(json_cmd "rm $p/foo" "$ROOT")"
    done
    run_case "abs redirect into main $FIRST_PROTECTED" 2 "$(json_cmd "echo hi > $ROOT/$FIRST_PROTECTED/z")"
    run_case "cwd-empty + relative $FIRST_PROTECTED tee" 2 "$(json_cmd "tee $FIRST_PROTECTED/x <<<hi")"
fi

# --- ALLOWED: worktree-scoped writes ---
run_case "abs write inside a worktree"          0 "$(json_cmd "mkdir -p $WT/$FIRST_PROTECTED/module/x")"
run_case "cwd=worktree + relative write"        0 "$(json_cmd "mkdir -p $FIRST_PROTECTED/foo" "$WT")"
run_case "cd-into-worktree then relative write" 0 "$(json_cmd "cd $WT && mkdir $FIRST_PROTECTED/foo" "$ROOT")"

# --- ALLOWED: reads / git ops / non-write commands ---
run_case "read protected (cat, no write token)" 0 "$(json_cmd "cat $FIRST_PROTECTED/foo" "$ROOT")"
run_case "git add protected (no write token)"   0 "$(json_cmd "git add $FIRST_PROTECTED/foo" "$ROOT")"
run_case "git commit"                           0 "$(json_cmd "git commit -m wip" "$ROOT")"

# --- ALLOWED: scratchpad + non-source writes in main ---
run_case "scratchpad write"                     0 "$(json_cmd "mkdir -p /tmp/x && echo hi > /tmp/x/y" "$ROOT")"
run_case "docs write in main (not source)"      0 "$(json_cmd "echo x > $ROOT/docs/foo.md")"
run_case "scripts write in main (not source)"   0 "$(json_cmd "mkdir -p $ROOT/scripts/gen")"

# --- ALLOWED: non-Bash payloads pass straight through ---
run_case "non-Bash tool (Write)"                0 '{"tool_name":"Write","tool_input":{"file_path":"'"$ROOT/$FIRST_PROTECTED"'/x"}}'
run_case "malformed JSON"                        0 'this is not json'
run_case "empty command"                         0 "$(json_cmd "" "$ROOT")"

# --- POSITIVE-SHAPE probe -------------------------------------------------
# A PASS case could pass because the guard silently no-ops. Prove the guard is
# actually evaluating: take a genuine PASS command (scratchpad write) and swap
# only the target into a protected tree — it MUST flip from allow to block.
run_case "positive-shape: scratchpad->protected flips to BLOCK" 2 \
    "$(json_cmd "mkdir -p /tmp/x && echo hi > $ROOT/$FIRST_PROTECTED/y" "$ROOT")"

# --- PROTECTED_PATHS empty -> guard INACTIVE (allow + loud note) ----------
# The generic engine's sensible-failure contract: unconfigured -> visible no-op.
EMPTY_ROOT="$(mktemp -d -t guard-bash-empty.XXXXXX)"
mkdir -p "$EMPTY_ROOT/scripts/hooks" "$EMPTY_ROOT/scripts/lib"
cp "$SRC_HOOK" "$EMPTY_ROOT/scripts/hooks/guard-bash-main-writes.sh"
chmod +x "$EMPTY_ROOT/scripts/hooks/guard-bash-main-writes.sh"
cp "$SRC_DIR/../lib/resolve-main-checkout.sh" "$EMPTY_ROOT/scripts/lib/" 2>/dev/null || true
cp "$SRC_DIR/../lib/resolve-roots.sh" "$EMPTY_ROOT/scripts/lib/"
printf 'PROTECTED_PATHS=""\n' > "$EMPTY_ROOT/orchestration.config"
EMPTY_OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && mkdir src/foo"}}' "$EMPTY_ROOT" | RICHOS_ENTITY_ROOT="$EMPTY_ROOT" "$EMPTY_ROOT/scripts/hooks/guard-bash-main-writes.sh" 2>&1)"
EMPTY_RC=$?
if [ "$EMPTY_RC" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  empty PROTECTED_PATHS -> guard inactive (exit 0)\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  empty PROTECTED_PATHS -> expected exit 0, got %s\n' "$EMPTY_RC"
fi
if printf '%s' "$EMPTY_OUT" | grep -qF 'INACTIVE'; then
    PASS=$((PASS + 1)); printf '  PASS  empty PROTECTED_PATHS -> loud INACTIVE note on stderr\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  empty PROTECTED_PATHS -> no INACTIVE note (%s)\n' "$EMPTY_OUT"
fi
rm -rf "$EMPTY_ROOT"

# --- python3 missing from PATH -> BLOCKED (fail-closed), loud stderr ---
make_fakebin_no_python3() {
    local dir
    dir="$(mktemp -d -t fakebin-no-python3.XXXXXX)"
    local tools="cat grep sed cut tr date mkdir git mktemp basename dirname rm ln awk sort uniq wc head tail shasum sha256sum env cp chmod"
    local t p
    for t in $tools; do
        p="$(command -v "$t" 2>/dev/null || true)"
        [ -n "$p" ] && ln -sf "$p" "$dir/$t"
    done
    echo "$dir"
}
BASH_BIN="$(command -v bash)"
FAKEBIN="$(make_fakebin_no_python3)"
NOPY_JSON="$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && mkdir %s/foo"}}' "$ROOT" "$FIRST_PROTECTED")"
NOPY_OUT="$(printf '%s' "$NOPY_JSON" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" 2>&1 1>/dev/null)"
NOPY_RC=$?
if [ "$NOPY_RC" -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  python3 missing from PATH -> refuses (exit %s, fail-closed)\n' "$NOPY_RC"
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
    echo "=== guard-bash-main-writes tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== guard-bash-main-writes tests: all $PASS passed ==="
    exit 0
fi
