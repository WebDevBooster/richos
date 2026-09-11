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

# THE SESSION TEAMS DIRECTORY IS REDIRECTED TOO (round 14, 2026-09-11 — the
# sibling of Sage D4). The hook appends every spawn's name to
# <teams>/session-<sid8>/spawned-names.log, and its default teams directory
# is $HOME/.claude/teams. Six firing sites in this file passed no
# GUARD_ISOLATION_TEAMS_DIR, so on the operator's machine
# ~/.claude/teams/session-deadbeef/spawned-names.log held 25 KB of this
# suite's fixture names (dev-1 x2,483, deviceqa-1 x241, dev-2 x160, ...),
# written on every run of a suite that is run on every land. The default
# below catches every site that does not name its own; the per-case
# overrides (an unwritable directory, a ledger-specific one) still win, as
# an environment assignment on the command line does. Asserted both ways at
# the end: the sandbox log received names, the real file did not grow.
REAL_SPAWNED_NAMES_LOG="$HOME/.claude/teams/session-${TEST_SID:0:8}/spawned-names.log"
count_real_spawned_names() {
    if [ -f "$REAL_SPAWNED_NAMES_LOG" ]; then wc -l <"$REAL_SPAWNED_NAMES_LOG" | tr -d ' '; else printf '0'; fi
}
REAL_SPAWNED_NAMES_BEFORE="$(count_real_spawned_names)"
export GUARD_ISOLATION_TEAMS_DIR="$DEFAULT_TX_SANDBOX/teams"
mkdir -p "$GUARD_ISOLATION_TEAMS_DIR/session-${TEST_SID:0:8}"

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
       "$SCRIPT_DIR/../lib/unevaluated-notice.sh" \
       "$root/scripts/lib/"
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

# json_agent <subagent_type> <name> <isolation> <prompt> [tool_use_id] [agent_id|none] [transcript]
# Carries what the real PostToolUse payload carries: the tool_use_id of the
# call and, for an async launch, the acknowledgement naming the agent id.
# "none" as agent_id models a SYNCHRONOUS return (no acknowledgement).
json_agent() {
    local subagent="$1" name="$2" isolation="$3" prompt="$4" tuid="${5:-toolu_test_agent}" aid="${6:-$TEST_AID}" tp="${7:-}"
    python3 - "$subagent" "$name" "$isolation" "$prompt" "$tuid" "$aid" "$tp" <<'PY'
import json, os, sys
subagent, name, isolation, prompt, tuid, aid, tp = sys.argv[1:8]
ti = {"prompt": prompt}
if subagent:
    ti["subagent_type"] = subagent
if name:
    ti["name"] = name
if isolation:
    ti["isolation"] = isolation
d = {"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000", "tool_use_id": tuid}
# The REAL shape, measured 2026-09-03 from three live spawns: the Agent result
# is a structured object, not prose. Until this revision every fixture here
# emitted prose, which is why 56 assertions passed while the binder bound
# nothing on a real machine. Set RESP_PROSE=1 to exercise the prose fallback.
if os.environ.get("RESP_ASYNC_NO_ID"):
    # asynchronous, but the result carries no readable agentId: the binder-defect
    # shape that every real spawn hit on 2026-09-03 and no fixture reproduced.
    # Checked FIRST so a caller can request it while still naming an agent id.
    d["tool_response"] = {"isAsync": True, "status": "async_launched",
                          "description": "fixture", "prompt": "fixture",
                          "outputFile": "/dev/null", "canReadOutputFile": True}
elif aid and aid != "none":
    if os.environ.get("RESP_PROSE"):
        d["tool_response"] = "Async agent launched successfully. (internal)\nagentId: %s (internal ID - do not mention)\nThe agent is working in the background." % aid
    else:
        d["tool_response"] = {"agentId": aid, "isAsync": True, "status": "async_launched",
                              "description": "fixture", "prompt": "fixture",
                              "outputFile": "/dev/null", "canReadOutputFile": True,
                              "resolvedModel": "claude-fable-5-1"}
else:
    d["tool_response"] = {"isAsync": False, "status": "completed",
                          "description": "fixture", "prompt": "fixture"}
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
        RICHOS_WORKSPACE_RETIRE_DIR="$repo/retire" \
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
        RICHOS_WORKSPACE_RETIRE_DIR="$repo/retire" \
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

# --- a payload this hook CANNOT READ is waved through, and SAYS SO -----------
# `TOOL_NAME=$(... || true)` gives an unreadable payload the same empty string a
# non-Agent call gets, so until 2026-09-10 the two took one silent exit 0. This
# hook is the BINDER: when it skips, guard-sealed-worktree.sh refuses that
# agent's every write afterwards, and nothing anywhere said why. PostToolUse
# cannot undo a spawn, so the exit stays 0 — what is asserted here is that it is
# no longer silent, on all three degraded shapes.
ROOT="$(make_sandbox)"
for _shape in empty truncated non-json; do
    case "$_shape" in
        empty)     _payload="" ;;
        truncated) _payload='{"tool_name":"Agent","tool_input":{"subagent_ty' ;;
        *)         _payload='this is not JSON, it is a sentence' ;;
    esac
    run_case "unreadable payload ($_shape) is allowed, not blocked" 0 "$ROOT" "$_payload"
    run_case_msg "unreadable payload ($_shape) SAYS the spawn was not examined" \
        "could not read this call" "$ROOT" "$_payload"
done
# THE CONTROL, and without it the three above are satisfied by a hook that
# announces on every call it ever sees.
_CTL_OUT="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | RICHOS_ENTITY_ROOT="$ROOT" RICHOS_WORKTREE_TX_DIR="$ROOT/tx" \
      RICHOS_WORKTREE_LEDGER="$ROOT/wt-ledger.jsonl" \
      "$ROOT/scripts/hooks/detect-nonnative-worktree.sh" 2>&1 || true)"
if printf '%s' "$_CTL_OUT" | grep -q "could not read this call"; then
    printf '  FAIL  a payload it COULD read is not announced (it spoke anyway)\n'
    FAIL=$((FAIL + 1))
else
    printf '  PASS  a payload it COULD read is not announced — silence stays correct on the happy path\n'
    PASS=$((PASS + 1))
fi
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
run_case_msg "two-causes explanation mentions the claude --worktree cause" "claude --worktree" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
run_case_msg "two-causes explanation mentions the SUBAGENT-freelance cause" "the SUBAGENT ran 'git worktree add' itself" "$ROOT" \
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
# PRESERVED. Both unknown and registered paths keep their contents.
# A native-shaped directory name never establishes safe deletion authority.
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "agent-cafefeed10" "worktree-cafefeed10"   # REGISTERED
mkdir -p "$ROOT/.claude/worktrees/agent-deaddead11"             # UNREGISTERED residue
printf 'ghost\n' > "$ROOT/.claude/worktrees/agent-deaddead11/seal.json"
run_case "zombie residue dir present -> exit 2 (report-only path)" 2 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
mkdir -p "$ROOT/.claude/worktrees/agent-deaddead11"
printf 'ghost\n' > "$ROOT/.claude/worktrees/agent-deaddead11/seal.json"
run_case_msg "zombie residue dir -> stderr names PRESERVED" "PRESERVED" "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
if [ "$(cat "$ROOT/.claude/worktrees/agent-deaddead11/seal.json" 2>/dev/null)" = "ghost" ]; then
    printf '  PASS  unregistered directory and its file were preserved\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  unregistered directory contents were damaged\n'; FAIL=$((FAIL + 1))
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

# --- (c) THE QUARANTINE ITSELF is never residue. The container is
# ".richos-retired" and each quarantine inside it is "<base>.richos-retired-ws-
# <id>-<stamp>Z"; both are dot-prefixed, so bash's default globbing already
# skipped them — which is exactly why the skip is now WRITTEN DOWN. This case
# is the regression that notices if that ever stops being true, whether the
# cause is a `shopt -s dotglob` added for an unrelated reason or a rename.
ROOT="$(make_sandbox)"
add_worktree "$ROOT" "agent-cafefeed24" "worktree-cafefeed24"
mkdir -p "$ROOT/.claude/worktrees/.richos-retired/agent-old25.richos-retired-ws-00000000feedface-20260906T000000Z"
printf 'archived\n' > "$ROOT/.claude/worktrees/.richos-retired/agent-old25.richos-retired-ws-00000000feedface-20260906T000000Z/work.txt"
run_case "(c) a retirement quarantine alone is not residue -> clean exit 0" 0 "$ROOT" \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
if [ "$(cat "$ROOT/.claude/worktrees/.richos-retired/agent-old25.richos-retired-ws-00000000feedface-20260906T000000Z/work.txt" 2>/dev/null)" = "archived" ]; then
    printf '  PASS  (c) the quarantine and its bytes are intact\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  (c) the quarantine was damaged or removed\n'; FAIL=$((FAIL + 1))
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


# (L1/L2) the spawned-names ledger stayed in the sandbox — positive arm first,
# so the negative arm cannot pass because nothing was written anywhere.
SANDBOX_SPAWNED_NAMES_LOG="$GUARD_ISOLATION_TEAMS_DIR/session-${TEST_SID:0:8}/spawned-names.log"
SANDBOX_SPAWNED_NAMES="$(if [ -f "$SANDBOX_SPAWNED_NAMES_LOG" ]; then wc -l <"$SANDBOX_SPAWNED_NAMES_LOG" | tr -d ' '; else printf '0'; fi)"
if [ "${SANDBOX_SPAWNED_NAMES:-0}" -gt 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  L1 POSITIVE  spawned names were appended in the SANDBOX teams directory (%s lines at %s)\n' "$SANDBOX_SPAWNED_NAMES" "$SANDBOX_SPAWNED_NAMES_LOG"
else
    FAIL=$((FAIL + 1)); printf '  FAIL  L1 no spawned name reached the sandbox teams directory %s; the redirect is not exercised and L2 would pass for the wrong reason\n' "$SANDBOX_SPAWNED_NAMES_LOG"
fi
REAL_SPAWNED_NAMES_AFTER="$(count_real_spawned_names)"
if [ "$REAL_SPAWNED_NAMES_AFTER" = "$REAL_SPAWNED_NAMES_BEFORE" ]; then
    PASS=$((PASS + 1)); printf '  PASS  L2 and the operator'"'"'s REAL %s did not grow (%s before, %s after)\n' "$REAL_SPAWNED_NAMES_LOG" "$REAL_SPAWNED_NAMES_BEFORE" "$REAL_SPAWNED_NAMES_AFTER"
else
    FAIL=$((FAIL + 1)); printf '  FAIL  L2 %s went %s -> %s lines; a firing site ignored GUARD_ISOLATION_TEAMS_DIR\n' "$REAL_SPAWNED_NAMES_LOG" "$REAL_SPAWNED_NAMES_BEFORE" "$REAL_SPAWNED_NAMES_AFTER"
fi
rm -rf "$DEFAULT_TX_SANDBOX"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== detect-nonnative-worktree tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== detect-nonnative-worktree tests: all $PASS passed ==="

# This suite's former mutation harness exercised the transaction binder, which
# was removed with the store (docs/plans/worktree-spec-2026-09-11.md); binding
# is now scripts/lib/workspaces.py's and is mutated by workspaces.mutation.sh.
exit 0
