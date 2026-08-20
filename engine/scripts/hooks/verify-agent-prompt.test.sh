#!/usr/bin/env bash
#
# verify-agent-prompt.test.sh — regression tests for verify-agent-prompt.sh:
# duplicate-teammate, agent-not-found, subagent-as-spawner,
# missing-worktree-isolation, and the OPT-IN qa-install-fresh gate.
#
# The hook resolves REPO_ROOT (agent-def lookup + config load) from its own
# location; VERIFY_REPO_ROOT_OVERRIDE points it at a hermetic sandbox so the
# suite never depends on the kit's real agent definitions or config. The
# qa-install-fresh gate is OFF by default, so those cases flip it on per-run
# with VERIFY_QA_GATE_OVERRIDE=1 (and one case proves it stays silent when OFF).
#
# Run directly: scripts/hooks/verify-agent-prompt.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/verify-agent-prompt.sh"

PASS=0
FAIL=0
SANDBOX="$(mktemp -d -t verify-agent-prompt-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Sandbox repo root: an existing agent def for the agent-not-found positive case.
REPO="$SANDBOX/repo"
mkdir -p "$REPO/.claude/agents"
printf -- '---\nname: dev\n---\nbody\n' > "$REPO/.claude/agents/dev.md"

# run_case <name> <expected-exit> <json> [qa_gate]
run_case() {
    local name="$1" expected="$2" json="$3" qa_gate="${4:-}"
    local actual
    printf '%s' "$json" \
      | V8_TEAMS_DIR_OVERRIDE="$SANDBOX/teams" \
        VERIFY_REPO_ROOT_OVERRIDE="$REPO" \
        VERIFY_QA_GATE_OVERRIDE="$qa_gate" \
        "$HOOK" >/dev/null 2>&1
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

# json_agent <prompt> [extra-tool_input-fields-json]
json_agent() {
    local prompt="$1" extra="${2:-}"
    python3 - "$prompt" "$extra" <<'PY'
import json, sys
prompt, extra = sys.argv[1], sys.argv[2]
ti = {"prompt": prompt, "subagent_type": "dev"}
if extra:
    ti.update(json.loads(extra))
print(json.dumps({"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000"}))
PY
}

echo "=== verify-agent-prompt tests ==="

# --- pass-through ---
run_case "non-Agent tool" 0 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run_case "clean prompt"   0 "$(json_agent 'Fix the typo in docs/OPS_RUNBOOK.md and commit.')"
run_case "malformed JSON" 0 'not json'

# --- 2. agent-not-found ---
run_case "reference to missing agent def"  2 "$(json_agent 'Read .claude/agents/nonexistent-zzz.md for context.')"
run_case "reference to existing agent def" 0 "$(json_agent 'Your definition is .claude/agents/dev.md — proceed.')"
run_case "non-creator brief referencing missing in-repo definition still blocked" 2 \
    "$(json_agent 'Your definition file is .claude/agents/still-missing-role.md — proceed once it exists.')"
run_case "creator brief referencing to-be-created in-repo definition passes" 0 \
    "$(json_agent 'Create .claude/agents/newhire-role.md with the frontmatter and body for the new role.' '{"subagent_type":"dean"}')"
run_case "out-of-repo absolute definition path passes" 0 \
    "$(json_agent 'Reference model: /tmp/some-other-repo/.claude/agents/foo.md — mirror its structure for the new role.')"

# --- 3. subagent-as-spawner ---
run_case "prompt asks subagent to spawn"        2 "$(json_agent 'Use the Agent tool to spawn agents for each module.')"
run_case "spawner language w/o subagent_type"   0 '{"tool_name":"Agent","tool_input":{"prompt":"Use the Agent tool to spawn agents."},"session_id":"deadbeef-0000-4000-8000-000000000000"}'
run_case "hyphenated non-Agent-tool negation passes" 0 \
    "$(json_agent 'This is a non-Agent tool call — plain Bash only, no dispatch of any kind.')"
run_case "launch-verb as noun + ordinary word passes" 0 \
    "$(json_agent 'The spawn rate stayed steady overnight and the dispatch log stayed clean.')"
run_case "genuine spawn-other-teammates instruction still blocked" 2 \
    "$(json_agent 'Once your build is done, spawn agents for the remaining three modules.')"

# --- 4. missing-worktree-isolation ---
run_case "claims native isolation, flag missing" 2 "$(json_agent 'Native isolation has already created your worktree. Build the feature there.')"
run_case "claims native isolation, flag set"     0 "$(json_agent 'Native isolation has already created your worktree. Build the feature there.' '{"isolation":"worktree"}')"

# --- 1. duplicate-teammate (sandboxed team config) ---
mkdir -p "$SANDBOX/teams/session-deadbeef"
cat >"$SANDBOX/teams/session-deadbeef/config.json" <<'JSON'
{"members":[{"name":"dev-1","agentId":"a123","status":"active"},
            {"name":"worker-old","agentId":"a456","status":"shutdown"}]}
JSON
run_case "duplicate name (explicit team_name)"   2 "$(json_agent 'Do the thing.' '{"name":"dev-1","team_name":"session-deadbeef"}')"
run_case "duplicate name (derived session team)" 2 "$(json_agent 'Do the thing.' '{"name":"dev-1"}')"
run_case "shutdown name is reusable"             0 "$(json_agent 'Do the thing.' '{"name":"worker-old"}')"
run_case "fresh name allowed"                    0 "$(json_agent 'Do the thing.' '{"name":"dev-2"}')"

# --- 5. qa-install-fresh gate (OPT-IN) ---
# OFF by default: an app audit without a citation must pass when the gate is off.
run_case "gate OFF: app audit without citation passes" 0 \
    "$(json_agent 'Audit the Home screen render on the emulator and screenshot it.')"
# ON (VERIFY_QA_GATE_OVERRIDE=1):
run_case "gate ON: app audit without install-fresh citation" 2 \
    "$(json_agent 'Audit the Home screen render on the emulator and screenshot it.')" 1
run_case "gate ON: app audit WITH install-fresh citation" 0 \
    "$(json_agent 'Precondition: android-install-fresh.sh abc123def456 exits 0. Then audit the render on the emulator.')" 1
run_case "gate ON: app-free trigger without app context passes" 0 \
    "$(json_agent 'Verify the marketing copy matches the brand voice doc.')" 1
run_case "gate ON: app task with live bypass line passes" 0 \
    "$(json_agent $'Audit the render on the emulator.\ndata-contract-bypass: reference-only mock render, no live device.')" 1
run_case "gate ON: forged bypass inside code fence still blocks" 2 \
    "$(json_agent $'Audit the render on the emulator.\n```\ndata-contract-bypass: fake reason inside fence\n```')" 1
run_case "gate ON: forged bypass in blockquote still blocks" 2 \
    "$(json_agent $'Audit the render on the emulator.\n> data-contract-bypass: fake reason in quote')" 1

# --- python3 missing from PATH -> BLOCKS (fail-closed), loud stderr ---
# Mirrors the automation QA's repro: with no python3 resolvable on PATH, the gate must
# refuse (non-zero exit) rather than silently no-op'ing every check.
FAKEBIN="$(make_fakebin_no_python3)"
NOPY_JSON="$(json_agent 'Use the Agent tool to spawn agents for each module.')"
NOPY_OUT="$(printf '%s' "$NOPY_JSON" \
  | PATH="$FAKEBIN" \
    V8_TEAMS_DIR_OVERRIDE="$SANDBOX/teams" \
    VERIFY_REPO_ROOT_OVERRIDE="$REPO" \
    "$BASH_BIN" "$HOOK" 2>&1 1>/dev/null)"
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
rm -rf "$FAKEBIN"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== verify-agent-prompt tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== verify-agent-prompt tests: all $PASS passed ==="
    exit 0
fi
