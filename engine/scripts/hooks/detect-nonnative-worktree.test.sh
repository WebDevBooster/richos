#!/usr/bin/env bash
#
# detect-nonnative-worktree.test.sh — regression tests for
# scripts/hooks/detect-nonnative-worktree.sh.
#
# The hook resolves its own REPO_ROOT from BASH_SOURCE, and check (b) shells
# out to `git -C "$REPO_ROOT" worktree list`. To test both (a) the per-launch
# JSON check and (b) the on-disk worktree-list check without touching the real
# repo, each case runs against an isolated sandbox git repo: a fresh tmpdir,
# `git init`, one commit, then the hook copied in at scripts/hooks/ so its
# self-resolved REPO_ROOT is the sandbox root.
#
# Covers: (a) file-capable, no isolation, no marker -> exit 2 warning; (b) a
# hand-rolled (non agent-<hex>) worktree present -> exit 2 warning (two-causes
# explanation preserved); (c) a clean native-only worktree list + a
# well-formed, isolated launch -> exit 0; (d) additional file-capable role
# types with NO isolation and NO marker -> exit 2 warning, WITH isolation ->
# exit 0, WITH the marker -> exit 0; (e) the main-checkout-run: marker present
# -> no (a) warning; (f) the marker suppresses (a) but never (b).
#
# Run directly: scripts/hooks/detect-nonnative-worktree.test.sh
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

HOOK_SRC="$SCRIPT_DIR/detect-nonnative-worktree.sh"

PASS=0
FAIL=0

if [ ! -x "$HOOK_SRC" ]; then
    echo "FATAL: detect-nonnative-worktree.sh missing/non-exec" >&2
    exit 1
fi

# make_sandbox — a fresh git repo that plays the part of "the repository the
# session is in": it carries the adoption marker, the engine library the hook's
# bootstrap needs, and a copy of the hook itself.
#
# The hook no longer derives its root from its own location, so the sandbox is
# DECLARED by each run_case via RICHOS_ENTITY_ROOT. Relying on the old
# self-resolution would mean these cases quietly ran against whatever repository
# the test was launched from.
make_sandbox() {
    local root
    root="$(mktemp -d -t detect-nonnative-worktree.XXXXXX)"
    mkdir -p "$root/scripts/hooks" "$root/scripts/lib"
    cp "$HOOK_SRC" "$root/scripts/hooks/detect-nonnative-worktree.sh"
    cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$root/scripts/lib/"
    chmod +x "$root/scripts/hooks/detect-nonnative-worktree.sh"
    printf 'READONLY_ALLOWLIST="Explore Plan claude-code-guide statusline-setup"\n' >"$root/orchestration.config"
    git init -q "$root"
    printf 'seed\n' > "$root/README.md"
    git -C "$root" add -A
    git -C "$root" commit -q -m init
    echo "$root"
}

# add_worktree <repo> <dirname-under-.claude/worktrees> <branch>
add_worktree() {
    local repo="$1" dirname="$2" branch="$3"
    git -C "$repo" worktree add -q "$repo/.claude/worktrees/$dirname" -b "$branch" >/dev/null 2>&1
}

# json_agent <subagent_type> <name> <isolation> <prompt>
json_agent() {
    local subagent="$1" name="$2" isolation="$3" prompt="$4"
    python3 - "$subagent" "$name" "$isolation" "$prompt" <<'PY'
import json, sys
subagent, name, isolation, prompt = sys.argv[1:5]
ti = {"prompt": prompt}
if subagent:
    ti["subagent_type"] = subagent
if name:
    ti["name"] = name
if isolation:
    ti["isolation"] = isolation
print(json.dumps({"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000"}))
PY
}

# run_case <name> <expected-exit> <repo> <json>
run_case() {
    local name="$1" expected="$2" repo="$3" json="$4"
    local actual
    printf '%s' "$json" | RICHOS_ENTITY_ROOT="$repo" "$repo/scripts/hooks/detect-nonnative-worktree.sh" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

# make_fakebin_no_python3 — a PATH dir populated with symlinks to every
# external tool the hook needs EXCEPT python3, so `command -v python3` fails
# while everything else the hook shells out to (including git) still resolves
# normally. Mirrors the automation QA's fail-open repro (PATH lacking python3).
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

# run_case_msg <name> <expected-substring> <repo> <json>
run_case_msg() {
    local name="$1" needle="$2" repo="$3" json="$4"
    local out
    out="$(printf '%s' "$json" | RICHOS_ENTITY_ROOT="$repo" "$repo/scripts/hooks/detect-nonnative-worktree.sh" 2>&1 >/dev/null)"
    if printf '%s' "$out" | grep -qF "$needle"; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (stderr did not mention "%s")\n' "$name" "$needle"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== detect-nonnative-worktree tests ==="

# --- non-Agent tool passes through untouched ---
ROOT="$(make_sandbox)"
run_case "non-Agent tool" 0 "$ROOT" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
rm -rf "$ROOT"

# --- (a) file-capable, no isolation, no marker -> exit 2 warning ---
ROOT="$(make_sandbox)"
run_case "no isolation, no marker, dev -> warning" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' '' 'Do the thing.')"
run_case_msg "warning names the missing-isolation tell" "spawned WITHOUT native isolation" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' '' 'Do the thing.')"
rm -rf "$ROOT"

# --- read-only type exempt from check (a), no worktree stray -> exit 0 ---
ROOT="$(make_sandbox)"
run_case "read-only type Explore, no isolation" 0 "$ROOT" \
    "$(json_agent 'Explore' '' '' 'Find where the login button is defined.')"
rm -rf "$ROOT"

# --- (c) clean native-only worktree list + well-formed isolated launch -> exit 0 ---
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "agent-deadbeef01" "worktree-deadbeef01"
run_case "native-only worktree list + isolated launch -> clean" 0 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
rm -rf "$ROOT"

# --- (d) additional file-capable role types: NO isolation and NO marker ->
# exit 2 warning. WITH isolation:"worktree" or WITH the marker -> exit 0.
ROOT="$(make_sandbox)"
run_case "deviceqa: no isolation, no marker -> warning" 2 "$ROOT" \
    "$(json_agent 'deviceqa' 'deviceqa-1' '' 'Run device QA.')"
rm -rf "$ROOT"
ROOT="$(make_sandbox)"
run_case "visualqa: no isolation, no marker -> warning" 2 "$ROOT" \
    "$(json_agent 'visualqa' 'visualqa-1' '' 'Adversarially verify the visual verdict.')"
rm -rf "$ROOT"
ROOT="$(make_sandbox)"
run_case "funcqa: no isolation, no marker -> warning" 2 "$ROOT" \
    "$(json_agent 'funcqa' 'funcqa-1' '' 'Functional QA on staging.')"
rm -rf "$ROOT"
ROOT="$(make_sandbox)"
run_case "deviceqa: isolation worktree, clean worktree list -> no warning" 0 "$ROOT" \
    "$(json_agent 'deviceqa' 'deviceqa-1' 'worktree' 'Run device QA.')"
rm -rf "$ROOT"
ROOT="$(make_sandbox)"
run_case "deviceqa: main-checkout-run marker, no isolation -> no warning" 0 "$ROOT" \
    "$(json_agent 'deviceqa' 'deviceqa-oneoff1' '' $'Run a one-off task.\nmain-checkout-run: deliberate one-off main-checkout run.')"
rm -rf "$ROOT"

# --- (e) main-checkout-run: marker present -> no (a) warning ---
ROOT="$(make_sandbox)"
run_case "marker present, no isolation -> no (a) warning" 0 "$ROOT" \
    "$(json_agent 'worker' 'worker-oneoff1' '' $'Do the task.\nmain-checkout-run: needs main checkout HEAD.')"
rm -rf "$ROOT"

# --- (b) a hand-rolled (non agent-<hex>) worktree present -> exit 2 warning ---
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "design-echo-mirror" "design-echo-mirror"
run_case "hand-rolled worktree present -> warning even for a clean launch" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
run_case_msg "warning names the stray worktree + two-causes explanation" "lingering NON-NATIVE worktree" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
run_case_msg "two-causes explanation mentions the LEAD cause" "the LEAD omitted isolation" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
run_case_msg "two-causes explanation mentions the SUBAGENT-freelance cause" "SUBAGENT ran 'git worktree add' ITSELF" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
rm -rf "$ROOT"

# --- (b) hand-rolled worktree present alongside a native one for the SAME
# agent (cause 2: subagent went freelance from its own correct worktree) ---
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "agent-cafefeed02" "worktree-cafefeed02"
add_worktree "$ROOT" "design-freelance-mirror" "design-freelance-mirror"
run_case "stray alongside a native worktree still warns" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
rm -rf "$ROOT"

# --- (f) the main-checkout-run: marker does not suppress check (b) — a stray
# worktree still warns even for a properly-isolated launch ---
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "design-echo-mirror" "design-echo-mirror"
run_case "isolated deviceqa launch does not suppress (b) when a stray exists" 2 "$ROOT" \
    "$(json_agent 'deviceqa' 'deviceqa-1' 'worktree' 'Run device QA.')"
rm -rf "$ROOT"

ROOT="$(make_sandbox)"
add_worktree "$ROOT" "design-echo-mirror" "design-echo-mirror"
run_case "marker present suppresses (a) but not (b) when a stray exists" 2 "$ROOT" \
    "$(json_agent 'worker' 'worker-oneoff2' '' $'Do the task.\nmain-checkout-run: needs main checkout HEAD.')"
rm -rf "$ROOT"

# =========================================================================
# NEW TELLS: zombie residue — (c) directories, (d) processes. A background child
# (a detached long-running verification) can outlive its agent AND its worktree;
# the reaped-then-recreated agent-<hex> dir is native-SHAPED, so old tell (b)
# misses it — these two catch it.
# =========================================================================

# --- (c) zombie residue DIR: on disk but ABSENT from the registry -> exit 2,
# AUTO-REAPED. CRITICAL NEGATIVE: a REGISTERED native worktree alongside is NEVER
# reaped. The residue is given a native-shaped name to prove name-shape alone
# does not save it — only registration does.
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "agent-cafefeed10" "worktree-cafefeed10"   # REGISTERED
mkdir -p "$ROOT/.claude/worktrees/agent-deaddead11"             # UNREGISTERED residue
printf 'ghost\n' > "$ROOT/.claude/worktrees/agent-deaddead11/seal.json"
run_case "zombie residue dir present -> exit 2 (auto-reap path)" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
mkdir -p "$ROOT/.claude/worktrees/agent-deaddead11"
printf 'ghost\n' > "$ROOT/.claude/worktrees/agent-deaddead11/seal.json"
run_case_msg "zombie residue dir -> stderr names AUTO-REAPED" "AUTO-REAPED" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
if [ ! -d "$ROOT/.claude/worktrees/agent-deaddead11" ]; then
    printf '  PASS  unregistered zombie dir was reaped from disk\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  unregistered zombie dir was NOT reaped\n'; FAIL=$((FAIL + 1))
fi
if [ -d "$ROOT/.claude/worktrees/agent-cafefeed10" ]; then
    printf '  PASS  registered native worktree survived the reap (critical negative)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  registered native worktree was wrongly reaped (critical negative)\n'; FAIL=$((FAIL + 1))
fi
rm -rf "$ROOT"

# --- (c) critical negative in isolation: ONLY a registered worktree, NO residue
# -> exit 0, nothing reaped.
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "agent-beefbeef12" "worktree-beefbeef12"
run_case "registered-only worktree list -> clean exit 0 (no false reap)" 0 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
if [ -d "$ROOT/.claude/worktrees/agent-beefbeef12" ]; then
    printf '  PASS  registered worktree untouched when no residue exists\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  registered worktree removed when no residue exists\n'; FAIL=$((FAIL + 1))
fi
rm -rf "$ROOT"

# --- (d) zombie PROCESS: an orphaned process referencing an UNREGISTERED
# worktree path under THIS sandbox's main checkout -> exit 2, REPORT-ONLY (pid +
# kill recommendation), never auto-killed. `exec -a` plants the ghost path in
# argv[0] (macOS `bash -c 'cmd' name` exec-optimizes the name away).
ROOT="$(make_sandbox)"
ROOT_PHYS="$(cd "$ROOT" && pwd -P)"
GHOST_PATH="$ROOT_PHYS/.claude/worktrees/agent-ghostproc13/scripts/install-fresh.sh"
bash -c 'exec -a "$1" sleep 30' _ "$GHOST_PATH" &
GHOST_PID=$!
sleep 0.4
ZP_OUT="$(printf '%s' "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')" \
    | RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" 2>&1 >/dev/null)"; ZP_RC=$?
kill "$GHOST_PID" 2>/dev/null || true
wait "$GHOST_PID" 2>/dev/null || true
if [ "$ZP_RC" -eq 2 ]; then
    printf '  PASS  zombie process present -> exit 2\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  zombie process present -> expected exit 2, got %s\n' "$ZP_RC"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$ZP_OUT" | grep -qF "pid ${GHOST_PID}"; then
    printf '  PASS  zombie process report names the PID\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  zombie process report did not name PID %s\n' "$GHOST_PID"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$ZP_OUT" | grep -qF "kill ${GHOST_PID}"; then
    printf '  PASS  zombie process report recommends a kill command\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  zombie process report missing kill recommendation\n'; FAIL=$((FAIL + 1))
fi
rm -rf "$ROOT"

# --- python3 missing from PATH -> BLOCKS (fail-closed), loud stderr ---
# Mirrors the automation QA's repro: with no python3 resolvable on PATH, the detector must
# refuse (non-zero exit) rather than silently going blind.
ROOT="$(make_sandbox)"
FAKEBIN="$(make_fakebin_no_python3)"
NOPY_JSON="$(json_agent 'dev' 'dev-1' '' 'Do the thing.')"
NOPY_OUT="$(printf '%s' "$NOPY_JSON" | PATH="$FAKEBIN" "$BASH_BIN" "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" 2>&1 1>/dev/null)"
NOPY_RC=$?
if [ "$NOPY_RC" -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  python3 missing from PATH -> BLOCKS (exit %s)\n' "$NOPY_RC"
else
    FAIL=$((FAIL + 1)); printf '  FAIL  python3 missing from PATH -> expected non-zero exit, got 0 (FAIL-OPEN)\n'
fi
if printf '%s' "$NOPY_OUT" | grep -qF 'python3'; then
    PASS=$((PASS + 1)); printf '  PASS  python3-missing stderr names the missing interpreter\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  python3-missing stderr did not mention python3 (%s)\n' "$NOPY_OUT"
fi
rm -rf "$FAKEBIN" "$ROOT"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== detect-nonnative-worktree tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== detect-nonnative-worktree tests: all $PASS passed ==="
    exit 0
fi
