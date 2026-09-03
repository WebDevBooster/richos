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
TEST_SID="deadbeef-0000-4000-8000-000000000000"
# Every case pins the transaction store per sandbox; this default catches any
# invocation that forgets, so nothing this suite does can reach the operator's
# real ~/.claude/state (it did once, on 2026-09-03, and W15 of the
# session-start suite now watches for it).
DEFAULT_TX_SANDBOX="$(mktemp -d -t detect-tx-default.XXXXXX)"
export RICHOS_WORKTREE_TX_DIR="$DEFAULT_TX_SANDBOX/tx"
export RICHOS_WORKTREE_LEDGER="$DEFAULT_TX_SANDBOX/wt-ledger.jsonl"
TEST_AID="deadbeefcafe0001"

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
    cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" \
       "$SCRIPT_DIR/../lib/worktree-transactions.py" "$SCRIPT_DIR/../lib/worktree-ledger.py" \
       "$SCRIPT_DIR/../lib/agent-liveness.py" "$root/scripts/lib/"
    chmod +x "$root/scripts/hooks/detect-nonnative-worktree.sh"
    # The spawn-intent guard-worktree-isolation.sh would have written for this
    # suite's fixed tool_use_id: a native isolation spawn, no externals.
    RICHOS_WORKTREE_TX_DIR="$root/tx" python3 "$SCRIPT_DIR/../lib/worktree-transactions.py" intent \
        --session-id "$TEST_SID" --tool-use-id toolu_test_agent >/dev/null <<'JSON'
{"kind": "native", "teammate": "dev-1", "subagent_type": "dev", "isolation": "worktree", "externals": []}
JSON
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

# json_agent <subagent_type> <name> <isolation> <prompt> [tool_use_id] [agent_id|none] [transcript]
# Carries what the real PostToolUse payload carries: the tool_use_id of the
# call and, for an async launch, the acknowledgement naming the agent id.
# "none" as agent_id models a SYNCHRONOUS return (no acknowledgement).
json_agent() {
    local subagent="$1" name="$2" isolation="$3" prompt="$4" tuid="${5:-toolu_test_agent}" aid="${6:-$TEST_AID}" tp="${7:-}"
    python3 - "$subagent" "$name" "$isolation" "$prompt" "$tuid" "$aid" "$tp" <<'PY'
import json, sys
subagent, name, isolation, prompt, tuid, aid, tp = sys.argv[1:8]
ti = {"prompt": prompt}
if subagent:
    ti["subagent_type"] = subagent
if name:
    ti["name"] = name
if isolation:
    ti["isolation"] = isolation
d = {"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000", "tool_use_id": tuid}
if aid and aid != "none":
    d["tool_response"] = "Async agent launched successfully. (internal)\nagentId: %s (internal ID - do not mention)\nThe agent is working in the background." % aid
else:
    d["tool_response"] = "Done. The task completed: nothing to report."
if tp:
    d["transcript_path"] = tp
print(json.dumps(d))
PY
}

# run_case <name> <expected-exit> <repo> <json>
run_case() {
    local name="$1" expected="$2" repo="$3" json="$4"
    local actual
    printf '%s' "$json" | RICHOS_ENTITY_ROOT="$repo" RICHOS_WORKTREE_TX_DIR="$repo/tx" RICHOS_WORKTREE_LEDGER="$repo/wt-ledger.jsonl" \
        "$repo/scripts/hooks/detect-nonnative-worktree.sh" >/dev/null 2>&1
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
    out="$(printf '%s' "$json" | RICHOS_ENTITY_ROOT="$repo" RICHOS_WORKTREE_TX_DIR="$repo/tx" RICHOS_WORKTREE_LEDGER="$repo/wt-ledger.jsonl" \
        "$repo/scripts/hooks/detect-nonnative-worktree.sh" 2>&1 >/dev/null)"
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
    | RICHOS_ENTITY_ROOT="$ROOT" RICHOS_WORKTREE_TX_DIR="$ROOT/tx" RICHOS_WORKTREE_LEDGER="$ROOT/wt-ledger.jsonl" "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" 2>&1 >/dev/null)"; ZP_RC=$?
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

# =========================================================================
# THE BINDER (third job, 2026-09-03): bound(session_id, tool_use_id, agent_id,
# members). Each refusal sits beside the pass it differs from by one fact.
# =========================================================================
bound_file() { printf '%s/tx/%s/bound/%s.json' "$1" "$TEST_SID" "$2"; }

# (B1) intent + async acknowledgement -> exit 0 and a bound record carrying
#      the intent's members and the acknowledged agent id
ROOT="$(make_sandbox)"
run_case "B01  intent + async acknowledgement -> bound, clean exit" 0 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["record"] == "bound" and d["agent_id"] == sys.argv[2] and d["tool_use_id"] == "toolu_test_agent"
assert d["kind"] == "native" and d["bound_source"] == "tool_response", d
' "$(bound_file "$ROOT" "$TEST_AID")" "$TEST_AID" 2>/dev/null; then
    printf '  PASS  B02  the bound record carries the acknowledged agent id, the tool_use_id and the intent kind\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  B02  bound record: %s\n' "$(cat "$(bound_file "$ROOT" "$TEST_AID")" 2>/dev/null | tr '\n' ' ')"; FAIL=$((FAIL + 1))
fi
if grep -q "\"agent_id\": \"$TEST_AID\"" "$ROOT/wt-ledger.jsonl" 2>/dev/null; then
    printf '  PASS  B03  the ledger inventory row carries the REAL agent id (not agent_id="")\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  B03  ledger row: %s\n' "$(cat "$ROOT/wt-ledger.jsonl" 2>/dev/null | tail -1)"; FAIL=$((FAIL + 1))
fi
rm -rf "$ROOT"

# (B4) NO acknowledgement, but the parent transcript joins this tool_use_id
#      to an agent id -> bound from the shared transcript join
ROOT="$(make_sandbox)"
python3 - "$ROOT/transcript.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"message": {"content": [{"type": "tool_use", "name": "Agent", "id": "toolu_test_agent", "input": {"name": "dev-1"}}]}}) + "\n")
    f.write(json.dumps({"message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_test_agent"}]}, "toolUseResult": {"agentId": "cafef00d00000002"}}) + "\n")
PY
run_case "B04  no acknowledgement + transcript join on the tool_use_id -> bound, clean exit" 0 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.' toolu_test_agent none "$ROOT/transcript.jsonl")"
if grep -q '"bound_source": "transcript"' "$(bound_file "$ROOT" cafef00d00000002)" 2>/dev/null; then
    printf '  PASS  B05  the bound record names the transcript as its source\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  B05  transcript-sourced binding missing\n'; FAIL=$((FAIL + 1))
fi
rm -rf "$ROOT"

# (B6) intent, but NO agent id anywhere: a SYNCHRONOUS file-writing call ->
#      exit 2, and the message says it ran unbound
ROOT="$(make_sandbox)"
run_case "B06  intent + no agent id (synchronous return) -> exit 2" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.' toolu_test_agent none)"
run_case_msg "B07  ...naming the synchronous-run cause" "SYNCHRONOUS run" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.' toolu_test_agent none)"
run_case_msg "B08  ...under the binding-failed banner" "WORKTREE BINDING FAILED" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.' toolu_test_agent none)"
[ ! -e "$(bound_file "$ROOT" "$TEST_AID")" ] && { printf '  PASS  B09  ...and nothing was bound\n'; PASS=$((PASS + 1)); } \
                                            || { printf '  FAIL  B09  a synchronous run was bound\n'; FAIL=$((FAIL + 1)); }
rm -rf "$ROOT"

# (B10) NO spawn-intent for this tool_use_id -> exit 2, naming the missing intent
ROOT="$(make_sandbox)"
run_case "B10  acknowledgement but NO spawn-intent on disk -> exit 2" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.' toolu_never_intended)"
run_case_msg "B11  ...naming the absent intent" "NO spawn-intent is on disk for tool_use toolu_never_intended" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.' toolu_never_intended)"
[ ! -e "$(bound_file "$ROOT" "$TEST_AID")" ] && { printf '  PASS  B12  ...and nothing was invented: no bound record\n'; PASS=$((PASS + 1)); } \
                                            || { printf '  FAIL  B12  a member set was invented without an intent\n'; FAIL=$((FAIL + 1)); }
rm -rf "$ROOT"

# (B13) a READ-ONLY type with no intent is silent (it was never meant to be bound)
ROOT="$(make_sandbox)"
run_case "B13  read-only type, no intent -> silent exit 0" 0 "$ROOT" \
    "$(json_agent 'Explore' '' '' 'Find the login button.' toolu_never_intended none)"
rm -rf "$ROOT"

# (B14) the transaction library MISSING -> exit 2 naming it (a worker that
#       cannot be bound is announced, never quietly registered)
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/lib/worktree-transactions.py"
run_case "B14  transaction library missing -> exit 2" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
run_case_msg "B15  ...naming the missing library" "worktree-transactions.py is MISSING" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
rm -rf "$ROOT"

# (B16) the same agent id bound twice to the SAME tool_use_id is idempotent
#       (a double-fired hook), and to a DIFFERENT one is refused loudly
ROOT="$(make_sandbox)"
run_case "B16  first binding -> exit 0" 0 "$ROOT" "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
run_case "B17  the same binding again (double fire) -> still exit 0" 0 "$ROOT" "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
RICHOS_WORKTREE_TX_DIR="$ROOT/tx" python3 "$SCRIPT_DIR/../lib/worktree-transactions.py" intent \
    --session-id "$TEST_SID" --tool-use-id toolu_second >/dev/null <<'JSON'
{"kind": "native", "teammate": "dev-2", "externals": []}
JSON
run_case "B18  the same agent id under a DIFFERENT tool_use_id -> exit 2 (refused rebind)" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-2' 'worktree' 'Do the thing.' toolu_second)"
run_case_msg "B19  ...naming the rebind" "already bound" "$ROOT" \
    "$(json_agent 'dev' 'dev-2' 'worktree' 'Do the thing.' toolu_second)"
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

# --- SECOND JOB: the spawned-names ledger append ---------------------------
#
# This hook owns the WRITE that guard-worktree-isolation.sh's name-reuse clause
# READS. Every case below is a pair, because a hook that appends nothing and a
# hook that appends everything both satisfy a single-sided assertion.
ROOT="$(make_sandbox)"
LEDGER_TEAMS="$(mktemp -d "${TMPDIR:-/tmp}/detect-ledger-teams.XXXXXX")"
SESS="deadbeef-0000-4000-8000-000000000000"
LEDGER_TEAM_DIR="$LEDGER_TEAMS/session-deadbeef"
mkdir -p "$LEDGER_TEAM_DIR"
LEDGER="$LEDGER_TEAM_DIR/spawned-names.log"

ledger_run() { # <json>
    printf '%s' "$1" | GUARD_ISOLATION_TEAMS_DIR="$LEDGER_TEAMS" \
        RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" >/dev/null 2>&1 || true
}

# (L1) a file-capable spawn that RAN is recorded
ledger_run "$(json_agent 'dev' 'dev-sonnet-led1' 'worktree' 'Do the thing.')"
if grep -qxF "dev-sonnet-led1" "$LEDGER" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: an executed spawn is appended to spawned-names.log\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: executed spawn NOT appended (reuse detection would go blind)\n'
fi

# (L2) NEGATIVE — a read-only type is never tracked, so it is never recorded.
# Without this arm, L1 is satisfied by a hook that records indiscriminately.
ledger_run "$(json_agent 'Explore' 'Explore' '' 'Look around.')"
if ! grep -qxF "Explore" "$LEDGER" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: a read-only type is NOT recorded\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: read-only type was recorded\n'
fi

# (L3) NEGATIVE — no name means nothing to record.
ledger_run "$(json_agent 'dev' '' 'worktree' 'Do the thing.')"
if [ "$(grep -c . "$LEDGER" 2>/dev/null || echo 0)" -eq 1 ]; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: a nameless spawn adds no line\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: a nameless spawn wrote a line (%s lines total)\n' "$(grep -c . "$LEDGER" 2>/dev/null || echo 0)"
fi

# (L4) the append is best-effort: an unwritable teams dir must not change the
# hook's verdict for the launch it was actually asked about.
UNWRITABLE="$(mktemp -d "${TMPDIR:-/tmp}/detect-ledger-ro.XXXXXX")"
chmod 500 "$UNWRITABLE"
printf '%s' "$(json_agent 'dev' 'dev-sonnet-led2' 'worktree' 'Do the thing.')" \
    | GUARD_ISOLATION_TEAMS_DIR="$UNWRITABLE" RICHOS_ENTITY_ROOT="$ROOT" RICHOS_WORKTREE_TX_DIR="$ROOT/tx" RICHOS_WORKTREE_LEDGER="$ROOT/wt-ledger.jsonl" \
      "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" >/dev/null 2>&1
rc=$?
chmod 700 "$UNWRITABLE"; rm -rf "$UNWRITABLE"
if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: an unwritable ledger does not change the detector verdict\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: unwritable ledger changed the verdict (exit %s)\n' "$rc"
fi
rm -rf "$LEDGER_TEAMS" "$ROOT"

# --- THIRD JOB: the OWNERSHIP LEDGER registration ---------------------------
#
# spawned-names.log is names only. The ownership ledger is what lets a
# worktree's owner be judged after its native lock is gone, so it must carry
# the agent id, the session identity and the paths. The sandbox for these
# cases carries the ledger library (the hook records nothing without it, by
# design — a sandbox modeling an engine without the library records nothing,
# and that is the honest answer, not a silent success).
ROOT="$(make_sandbox)"
cp "$SCRIPT_DIR/../lib/worktree-ledger.py" "$SCRIPT_DIR/../lib/agent-liveness.py" "$ROOT/scripts/lib/"
ROOT_PHYS="$(cd "$ROOT" && pwd -P)"
WL="$ROOT/wt-ledger.jsonl"
ACK='Async agent launched successfully.\nagentId: a1b2c3d4e5f60718\nYou can check on it later.'
json_spawn() { # <name> <isolation> <prompt> <tool_response|""> <cwd|"">
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
name, isolation, prompt, resp, cwd = sys.argv[1:6]
ti = {"subagent_type": "dev", "name": name, "prompt": prompt}
if isolation: ti["isolation"] = isolation
if cwd: ti["cwd"] = cwd
d = {"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000", "tool_use_id": "toolu_test_agent"}
if resp: d["tool_response"] = resp.replace("\\n", "\n")
print(json.dumps(d))
PY
}
wl_run() { # <json> ; runs the hook with the ledger pinned, our own pid as the session
    printf '%s' "$1" | RICHOS_WORKTREE_LEDGER="$WL" CLAUDE_PID="$$" GUARD_ISOLATION_TEAMS_DIR="$ROOT/teams" RICHOS_WORKTREE_TX_DIR="$ROOT/tx" \
        RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" >/dev/null 2>&1 || true
}
wl_last() { tail -1 "$WL" 2>/dev/null; }

# (W1) an ASYNC native spawn: the acknowledgement names the agent id; the
#      native worktree exists and is LOCKED with a session pid -> registered
#      with agent_id, worktree path, branch, session_pid from the LOCK, pid_start.
add_worktree "$ROOT" "agent-a1b2c3d4e5f60718" "worktree-agent-a1b2c3d4e5f60718"
git -C "$ROOT" worktree lock --reason "claude agent agent-a1b2c3d4e5f60718 (pid $$ start test)" "$ROOT/.claude/worktrees/agent-a1b2c3d4e5f60718"
wl_run "$(json_spawn 'dev-sonnet-wl1' 'worktree' 'Do the thing.' "$ACK" '')"
if wl_last | python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "registered" and d["class"] == "native", d
assert d["teammate"] == "dev-sonnet-wl1" and d["agent_id"] == "a1b2c3d4e5f60718", d
assert d["session_pid"] == int(sys.argv[1]) and d.get("pid_start"), d
assert d["worktree"].endswith("/.claude/worktrees/agent-a1b2c3d4e5f60718"), d
assert d["branch"] == "worktree-agent-a1b2c3d4e5f60718" and d["native_registered"] is True, d
assert d["session_id"].startswith("deadbeef"), d
' "$$" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: an async native spawn is REGISTERED with agent id, lock pid, start time, path, branch\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: async native spawn registration: %s\n' "$(wl_last)"
fi

# (W2) a `cwd` spawn (no isolation — the harness forbids both) into a linked
#      worktree of another repository -> a HAND-ROLLED registration keyed by
#      the exact path, with that repository and branch.
OTHER="$ROOT/../other-$RANDOM"; mkdir -p "$OTHER"
git -C "$OTHER" init -q -b main; printf 'r\n' >"$OTHER/r.txt"; git -C "$OTHER" add -A; git -C "$OTHER" commit -q -m r
git -C "$OTHER" worktree add -q -b dev-sonnet-wl2 "$OTHER-wt/dev-sonnet-wl2"
wl_run "$(json_spawn 'dev-sonnet-wl2' '' 'Work in the other repo.' "$ACK" "$OTHER-wt/dev-sonnet-wl2")"
if grep -q '"class": "hand-rolled"' "$WL" && wl_last | python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "registered" and d["class"] == "hand-rolled", d
assert d["teammate"] == "dev-sonnet-wl2" and d["agent_id"] == "a1b2c3d4e5f60718", d
assert os.path.realpath(d["worktree"]) == os.path.realpath(sys.argv[1]), (d["worktree"], sys.argv[1])
assert d["branch"] == "dev-sonnet-wl2" and d["repo"] == os.path.realpath(sys.argv[2]), d
assert d["session_pid"] == int(sys.argv[3]), d
' "$OTHER-wt/dev-sonnet-wl2" "$OTHER" "$$" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: a cwd spawn is REGISTERED hand-rolled by exact path, repo and branch\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: cwd spawn registration: %s\n' "$(wl_last)"
fi

# (W3) `cross-repo-worktree: <path>` prompt lines register the same way,
#      alongside the native registration.
git -C "$OTHER" worktree add -q -b dev-sonnet-wl3 "$OTHER-wt/dev-sonnet-wl3"
BEFORE="$(grep -c . "$WL")"
wl_run "$(json_spawn 'dev-sonnet-wl3' 'worktree' $'Do it.\ncross-repo-worktree: '"$OTHER-wt/dev-sonnet-wl3"$'\nThen commit.' "$ACK" '')"
AFTER="$(grep -c . "$WL")"
if [ "$AFTER" -eq $((BEFORE + 2)) ] && wl_last | python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
assert d["class"] == "hand-rolled" and d["teammate"] == "dev-sonnet-wl3", d
assert os.path.realpath(d["worktree"]) == os.path.realpath(sys.argv[1]), d
' "$OTHER-wt/dev-sonnet-wl3" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: a cross-repo-worktree: prompt line registers the path beside the native record\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: marker registration (lines %s -> %s): %s\n' "$BEFORE" "$AFTER" "$(wl_last)"
fi

# (W4) NEGATIVE — a read-only type registers nothing.
BEFORE="$(grep -c . "$WL" 2>/dev/null || echo 0)"
wl_run "$(python3 -c 'import json; print(json.dumps({"tool_name":"Agent","tool_input":{"subagent_type":"Explore","name":"Explore","prompt":"look"},"session_id":"deadbeef-0000-4000-8000-000000000000"}))')"
[ "$(grep -c . "$WL" 2>/dev/null || echo 0)" -eq "$BEFORE" ] \
    && { PASS=$((PASS + 1)); printf '  PASS  ledger: a read-only type is NOT registered\n'; } \
    || { FAIL=$((FAIL + 1)); printf '  FAIL  ledger: read-only type was registered\n'; }

# (W5) a SYNCHRONOUS run (no acknowledgement, no agent id) still registers the
#      name with its session identity, so a name-owned tree can be judged by
#      session — agent_id empty, never invented.
wl_run "$(json_spawn 'dev-sonnet-wl5' 'worktree' 'Quick sync task.' 'Done: the answer is 42.' '')"
if wl_last | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "registered" and d["teammate"] == "dev-sonnet-wl5" and d["agent_id"] == "", d
assert d["session_pid"] == int(sys.argv[1]) and d["worktree"] == "", d
' "$$" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  ledger: a synchronous run registers name + session identity with NO invented agent id\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  ledger: sync-run registration: %s\n' "$(wl_last)"
fi

# (W6) the write is best-effort: an unwritable ledger leaves the verdict alone.
printf '%s' "$(json_spawn 'dev-sonnet-wl6' 'worktree' 'Do the thing.' "$ACK" '')" \
    | RICHOS_WORKTREE_LEDGER="/nonexistent-dir/ledger.jsonl" CLAUDE_PID="$$" RICHOS_ENTITY_ROOT="$ROOT" RICHOS_WORKTREE_TX_DIR="$ROOT/tx" \
      "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] \
    && { PASS=$((PASS + 1)); printf '  PASS  ledger: an unwritable ledger does not change the detector verdict\n'; } \
    || { FAIL=$((FAIL + 1)); printf '  FAIL  ledger: unwritable ledger changed the verdict (exit %s)\n' "$rc"; }
rm -rf "$ROOT" "$OTHER" "$OTHER-wt"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== detect-nonnative-worktree tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== detect-nonnative-worktree tests: all $PASS passed ==="

# The mutation harness is part of this suite's definition of green: a suite
# nobody has watched go red proves nothing (open-items rows 3.22-3.29).
if [ -f "$SCRIPT_DIR/worktree-binder.mutation.sh" ]; then
    bash "$SCRIPT_DIR/worktree-binder.mutation.sh" || exit 1
fi
exit 0
