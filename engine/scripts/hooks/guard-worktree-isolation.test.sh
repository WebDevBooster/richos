#!/usr/bin/env bash
#
# guard-worktree-isolation.test.sh — regression tests for
# scripts/hooks/guard-worktree-isolation.sh.
#
# Covers: (a) file-capable, no isolation, no marker -> exit 2 with the
# self-documenting remediation message; (b) with isolation:"worktree" ->
# exit 0; (c) read-only agent type -> exit 0 with NO isolation/name required;
# (d) additional file-capable role types with NO isolation and NO marker ->
# exit 2 (BLOCKED like any other type), WITH isolation:"worktree" -> exit 0,
# WITH the main-checkout-run: marker -> exit 0; (e) the main-checkout-run:
# marker present -> exit 0; (f) bad/bare name -> exit 2 (with isolation, with
# the marker — the name requirement is never relaxed); (g) unparseable Agent
# payload -> exit 2 (fail-closed); (h) non-Agent tool -> exit 0; (i) the
# marker use is best-effort logged to .claude/state/; (j) CLAUSE 3 — a name
# reused within a session (ledger / active roster / completed event-log) ->
# exit 2, a fresh name -> exit 0 and recorded, and the clause is inert without
# a resolvable session team dir; (k) the <model> token (middle segment of
# <role>-<model>-<identifier>) — old 2-part / garbage tokens BLOCKED (clause
# 2a); truthfulness (clause 2b): correct token via LIVE frontmatter default AND
# via explicit override, wrong token vs frontmatter AND vs override -> BLOCKED
# naming both models + the source, override wins over frontmatter (precedence),
# a non-live templates/ name never resolves (undeterminable), verbose-id
# override normalized to its alias, and undeterminable model (no live def /
# model:"inherit") accepts a valid alias while still enforcing the 2a floor.
# (m) CLAUSE 5 — the STAFFING gate: a generic/built-in agent type is refused
# unless the prompt carries a reasoned "generic-agent: <why>" line; the refusal
# names the roster alternative and why it matters; a well-formed reason passes
# and is logged; a bare/trivial/filler marker and a speed-or-convenience excuse
# are refused; harness utilities (statusline-setup, claude-code-guide) carry no
# hatch at all; general-purpose is closed via GENERIC_AGENT_TYPES; roster types
# are wholly unaffected; and the WORKTREE-ISOLATION exemption for allowlisted
# types still holds independently (block (c) proves it with the hatch present,
# so neither property can silently absorb the other).
#
# (n) CLAUSE 6 — the model capability order is DATA (orchestration.config
# MODEL_TIERS, parsed only by scripts/lib/model-tiers.sh): an explicit model:
# override to a LOWER tier than the definition's default is BLOCKED naming the
# teammate, both models, both ranks, the declaration and the exact line to add;
# a reasoned `model-downgrade-ack:` line permits it and is logged; a bare
# marker exempts nothing; equal-or-higher tier is SILENT (no output at all —
# the 2026-09-02 incident's own shapes: a Sonnet-default teammate on Fable, an
# Opus-default teammate on Fable); the clause fails OPEN with a notice on a
# missing parser / blank / malformed / unranking declaration and never
# announces on a spawn that needed no ranking; and a declaration that
# contradicts the alias names is OBEYED, proving nothing infers from a name.
#
# NOTE: the truthfulness cases resolve against the engine's REAL live agent defs
# (frank=opus); if that frontmatter default changes, update the expected tokens.
#
# Run directly: scripts/hooks/guard-worktree-isolation.test.sh
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

HOOK="$SCRIPT_DIR/guard-worktree-isolation.sh"

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

# run_case_silent <name> <json> — asserts exit 0 AND no output on either
# stream. "Silent" is a contract, not a nicety: clause 6 must say NOTHING on an
# equal-or-higher tier, and a notice there is a nag that becomes noise.
run_case_silent() {
    local name="$1" json="$2"
    local out actual
    out="$(printf '%s' "$json" | "$HOOK" 2>&1)"
    actual=$?
    if [ "$actual" -eq 0 ] && [ -z "$out" ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected exit 0 with NO output, got exit %s: %s)\n' "$name" "$actual" "${out:0:160}"
        FAIL=$((FAIL + 1))
    fi
}

# run_case_msg <name> <expected-substring> <json> — asserts stderr mentions it
run_case_msg() {
    local name="$1" needle="$2" json="$3"
    local out
    out="$(printf '%s' "$json" | "$HOOK" 2>&1 >/dev/null)"
    if printf '%s' "$out" | grep -qF "$needle"; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (stderr did not mention "%s")\n' "$name" "$needle"
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

# json_agent_model <subagent> <name> <isolation> <model> <prompt> — as json_agent
# but also sets tool_input.model (the explicit per-spawn override that exercises
# clause 2b's override precedence).
json_agent_model() {
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
subagent, name, isolation, model, prompt = sys.argv[1:6]
ti = {"prompt": prompt}
if subagent: ti["subagent_type"] = subagent
if name: ti["name"] = name
if isolation: ti["isolation"] = isolation
if model: ti["model"] = model
print(json.dumps({"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000"}))
PY
}

echo "=== guard-worktree-isolation tests ==="

# --- non-Agent tool passes through untouched ---
run_case "non-Agent tool (Bash)" 0 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run_case "non-Agent tool (Read)" 0 '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'

# --- (a) file-capable, no isolation, no marker -> exit 2 ---
run_case "no isolation, no marker, well-formed name, dev" 2 \
    "$(json_agent 'dev' 'dev-sonnet-1' '' 'Do the thing.')"
run_case_msg "block message is self-documenting: names isolation flag" 'isolation: "worktree"' \
    "$(json_agent 'dev' 'dev-sonnet-1' '' 'Do the thing.')"
run_case_msg "block message is self-documenting: names main-checkout-run fallback" 'main-checkout-run:' \
    "$(json_agent 'dev' 'dev-sonnet-1' '' 'Do the thing.')"

# --- (b) isolation:"worktree" -> exit 0 ---
run_case "isolation worktree, well-formed name" 0 \
    "$(json_agent 'dev' 'dev-sonnet-1' 'worktree' 'Do the thing.')"
run_case "isolation remote, well-formed name" 0 \
    "$(json_agent 'dev' 'dev-sonnet-r1' 'remote' 'Do the thing.')"

# --- (c) read-only agent type -> exit 0, no isolation/name required ---
# THE ISOLATION EXEMPTION, PROVEN ON ITS OWN. Explore/Plan carry the clause-5
# staffing hatch here so that what these cases assert is exactly one thing: an
# allowlisted type needs NO isolation and NO name. Clause 5 is proven separately
# in block (m); if a future change collapsed the two, block (m) goes red.
GA_OK='generic-agent: a read-only sweep across three repositories that no roster teammate has a seat for'
run_case "read-only type Explore, no isolation/name (isolation exemption holds)" 0 \
    "$(json_agent 'Explore' '' '' "Find where the login button is defined.
$GA_OK")"
run_case "read-only type Plan, no isolation/name (isolation exemption holds)" 0 \
    "$(json_agent 'Plan' '' '' "Plan the next sprint.
$GA_OK")"
run_case "read-only type claude-code-guide" 0 "$(json_agent 'claude-code-guide' '' '' 'Explain a feature.')"
run_case "read-only type statusline-setup" 0 "$(json_agent 'statusline-setup' '' '' 'Configure statusline.')"

# --- (d) additional file-capable role types (e.g. device/visual QA) are
# blocked without isolation, exactly like any other file-capable type; WITH
# isolation:"worktree" or WITH the main-checkout-run: marker they pass.
run_case "deviceqa: no isolation, no marker -> BLOCKED" 2 \
    "$(json_agent 'deviceqa' 'deviceqa-sonnet-1' '' 'Run native device QA.')"
run_case "visualqa: no isolation, no marker -> BLOCKED" 2 \
    "$(json_agent 'visualqa' 'visualqa-sonnet-1' '' 'Adversarially verify the visual verdict.')"
run_case "funcqa: no isolation, no marker -> BLOCKED" 2 \
    "$(json_agent 'funcqa' 'funcqa-sonnet-1' '' 'Functional QA on staging.')"
run_case "deviceqa: isolation worktree -> exit 0" 0 \
    "$(json_agent 'deviceqa' 'deviceqa-sonnet-1' 'worktree' 'Run native device QA.')"
run_case "visualqa: isolation worktree -> exit 0" 0 \
    "$(json_agent 'visualqa' 'visualqa-sonnet-1' 'worktree' 'Adversarially verify the visual verdict.')"
run_case "funcqa: isolation worktree -> exit 0" 0 \
    "$(json_agent 'funcqa' 'funcqa-sonnet-1' 'worktree' 'Functional QA on staging.')"
run_case "deviceqa: main-checkout-run marker, no isolation -> exit 0" 0 \
    "$(json_agent 'deviceqa' 'deviceqa-sonnet-oneoff1' '' $'Run a one-off main-checkout task.\nmain-checkout-run: deliberate one-off main-checkout run.')"

# --- (e) main-checkout-run: marker present -> exit 0 ---
run_case "main-checkout-run marker, well-formed name, no isolation" 0 \
    "$(json_agent 'worker' 'worker-sonnet-oneoff1' '' $'Run a one-off main-checkout task.\nmain-checkout-run: needs main checkout HEAD for X.')"
run_case "marker mid-prompt on its own line still matches" 0 \
    "$(json_agent 'worker' 'worker-sonnet-oneoff2' '' $'Do the task.\n\nmain-checkout-run: precondition explained here.\n\nProceed once passing.')"

# --- (f) bad/bare name -> exit 2, regardless of isolation or marker ---
run_case "bare name with isolation set" 2 \
    "$(json_agent 'dev' 'dev' 'worktree' 'Do the thing.')"
run_case "run-together name with isolation set" 2 \
    "$(json_agent 'dev' 'dev1' 'worktree' 'Do the thing.')"
run_case "bare name with marker present (not relaxed)" 2 \
    "$(json_agent 'worker' 'worker' '' $'Do the task.\nmain-checkout-run: needs main checkout.')"
run_case "bare name for deviceqa, isolation set (not relaxed)" 2 \
    "$(json_agent 'deviceqa' 'deviceqa' 'worktree' 'Run device QA.')"
run_case_msg "malformed-name message present" 'missing/malformed name' \
    "$(json_agent 'dev' 'dev' 'worktree' 'Do the thing.')"

# --- (k) <model> token: format (2a) + truthfulness (2b) ---
# The <model> token (middle segment of <role>-<model>-<identifier>) must be a
# real alias AND match the model the instance boots on: an explicit
# tool_input.model override wins, else the model: frontmatter of the LIVE agent
# def .claude/agents/<subagent_type>.md (engine live defs: frank=opus). Generic
# roles here (dev, worker, ...) have NO live def -> undeterminable -> a valid
# alias token is accepted.
#
# Old 2-part name now BLOCKED — the model token is MISSING.
run_case "old 2-part name (missing model token), isolation set -> BLOCKED" 2 \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
run_case_msg "missing-model-token message names the 3-part form" '<role>-<model>-<identifier>' \
    "$(json_agent 'dev' 'dev-1' 'worktree' 'Do the thing.')"
# Garbage / non-alias model token -> BLOCKED (clause 2a).
run_case "garbage model token 'gpt' -> BLOCKED" 2 \
    "$(json_agent 'dev' 'dev-gpt-1' 'worktree' 'Do the thing.')"
run_case_msg "garbage-token message says 'not an allowed model'" 'is not an allowed model' \
    "$(json_agent 'dev' 'dev-gpt-1' 'worktree' 'Do the thing.')"

# 'fable' is an allowed model alias too (orchestration.config's ALLOWED_MODELS
# default): a truthfully-named dev-fable-* spawn with an explicit model:"fable"
# override passes both set-membership (2a) and truthfulness (2b).
run_case "correct token via override (fable is an allowed alias, dev-fable-*)" 0 \
    "$(json_agent_model 'dev' 'dev-fable-1' 'worktree' 'fable' 'Do the thing.')"

# Correct token via LIVE frontmatter default (frank=opus).
run_case "correct token via live frontmatter default (frank->opus)" 0 \
    "$(json_agent 'frank' 'frank-opus-1' 'worktree' 'Stress-test the plan.')"
# Wrong token vs live frontmatter default -> BLOCKED (clause 2b).
run_case "wrong token vs frontmatter (frank is opus, name says sonnet) -> BLOCKED" 2 \
    "$(json_agent 'frank' 'frank-sonnet-2' 'worktree' 'Stress-test the plan.')"
run_case_msg "frontmatter-mismatch message names BOTH models" "claims 'sonnet' but this spawn boots on 'opus'" \
    "$(json_agent 'frank' 'frank-sonnet-2' 'worktree' 'Stress-test the plan.')"
run_case_msg "frontmatter-mismatch message is labelled 'untruthful model token'" 'untruthful model token' \
    "$(json_agent 'frank' 'frank-sonnet-2' 'worktree' 'Stress-test the plan.')"

# A non-live TEMPLATE name is NOT a spawnable type and must NOT resolve from
# .claude/agents/templates/ — so it is undeterminable and a valid alias passes
# regardless of the template's own frontmatter (templates/backend-engineer.md is
# sonnet; an opus token must still be accepted, proving templates never resolve).
run_case "template-named type does NOT resolve from templates/ (undeterminable)" 0 \
    "$(json_agent 'backend-engineer' 'be-opus-1' 'worktree' 'Build a feature.')"

# Explicit override WINS over frontmatter (precedence proof). frank=opus; override
# to sonnet, name claims sonnet -> exit 0. Since clause 6 (2026-09-02) that
# override is also a move to a LOWER tier, so the fixture carries the stated
# reason the clause demands — the precedence intent is unchanged, and block (n)
# below pins the no-reason refusal on its own.
run_case "correct token via override (override sonnet beats frontmatter opus)" 0 \
    "$(json_agent_model 'frank' 'frank-sonnet-ov1' 'worktree' 'sonnet' $'Stress-test.\nmodel-downgrade-ack: precedence fixture; the stated reason clause 6 requires for opus -> sonnet.')"
# Override sonnet, name claims opus (matches frontmatter but NOT the override) -> BLOCKED.
run_case "wrong token vs override (override sonnet, name says opus) -> BLOCKED" 2 \
    "$(json_agent_model 'frank' 'frank-opus-ov2' 'worktree' 'sonnet' 'Stress-test.')"
run_case_msg "override-mismatch message cites the override source" "explicit model override 'sonnet'" \
    "$(json_agent_model 'frank' 'frank-opus-ov2' 'worktree' 'sonnet' 'Stress-test.')"
# Verbose model id in the override is normalized to its alias.
run_case "verbose override id 'claude-opus-4-8' normalizes to opus" 0 \
    "$(json_agent_model 'dev' 'dev-opus-ov3' 'worktree' 'claude-opus-4-8' 'Do the thing.')"

# Undeterminable model -> accept a valid alias (never fail on unknowable info).
run_case "undeterminable (no live def, no override) accepts valid alias token" 0 \
    "$(json_agent 'worker' 'worker-haiku-u1' 'worktree' 'Do the thing.')"
# model:"inherit" override -> undeterminable even though a live def exists.
run_case "undeterminable via model:inherit accepts valid alias token" 0 \
    "$(json_agent_model 'frank' 'frank-haiku-u2' 'worktree' 'inherit' 'Stress-test.')"
# Undeterminable STILL requires a valid alias (garbage token -> BLOCKED).
run_case "undeterminable but garbage token still BLOCKED (2a floor holds)" 2 \
    "$(json_agent 'worker' 'worker-gpt-u3' 'worktree' 'Do the thing.')"

# --- (n) CLAUSE 6 — a move to a LOWER capability tier is stated, never silent ---
# The order is DATA: this engine's orchestration.config declares
# MODEL_TIERS="fable > opus > sonnet > haiku", read only through
# scripts/lib/model-tiers.sh. Engine live defs: frank=opus, reed=sonnet. The
# first two cases are the REAL shapes from 2026-09-02 — the first is the one
# the killed guard had backwards (it would have refused it forever), the
# second is the spawn the CEO ordered himself.
run_case_silent "reed (sonnet default) on fable, no reason -> allowed, SILENT (an upgrade)" \
    "$(json_agent_model 'reed' 'reed-fable-c6a' 'worktree' 'fable' 'Read the sources.')"
run_case_silent "frank (opus default) on fable, no reason -> allowed, SILENT (same tier; the CEO's own spawn shape)" \
    "$(json_agent_model 'frank' 'frank-fable-c6b' 'worktree' 'fable' 'Stress-test.')"
run_case_silent "frank on opus, its own default, explicit -> SILENT" \
    "$(json_agent_model 'frank' 'frank-opus-c6c' 'worktree' 'opus' 'Stress-test.')"
run_case_silent "reed upgraded to opus -> SILENT" \
    "$(json_agent_model 'reed' 'reed-opus-c6d' 'worktree' 'opus' 'Read the sources.')"
run_case_silent "reed on sonnet, its own default, explicit -> SILENT" \
    "$(json_agent_model 'reed' 'reed-sonnet-c6e' 'worktree' 'sonnet' 'Read the sources.')"
run_case_silent "frank with NO override -> clause 6 never fires" \
    "$(json_agent 'frank' 'frank-opus-c6f' 'worktree' 'Stress-test.')"

C6_DOWN="$(json_agent_model 'frank' 'frank-sonnet-c6g' 'worktree' 'sonnet' 'Stress-test.')"
run_case "frank (opus default) on sonnet, no reason -> BLOCKED" 2 "$C6_DOWN"
run_case_msg "the tier refusal names the teammate" "'frank-sonnet-c6g' of 'frank'" "$C6_DOWN"
run_case_msg "the tier refusal names the definition default" "defaults to 'opus'" "$C6_DOWN"
run_case_msg "the tier refusal names the requested model" "requests model 'sonnet'" "$C6_DOWN"
run_case_msg "the tier refusal names the declaration it read" 'MODEL_TIERS="fable > opus > sonnet > haiku"' "$C6_DOWN"
run_case_msg "the tier refusal names the exact line to add" 'model-downgrade-ack: <why' "$C6_DOWN"
run_case_msg "the tier refusal says equal-or-higher never needs it" 'Equal or higher tier never needs it' "$C6_DOWN"
run_case "frank on haiku, no reason -> BLOCKED" 2 \
    "$(json_agent_model 'frank' 'frank-haiku-c6h' 'worktree' 'haiku' 'Stress-test.')"
run_case "reed (sonnet default) on haiku, no reason -> BLOCKED" 2 \
    "$(json_agent_model 'reed' 'reed-haiku-c6i' 'worktree' 'haiku' 'Read the sources.')"
run_case "frank on sonnet WITH a reasoned model-downgrade-ack: -> allowed" 0 \
    "$(json_agent_model 'frank' 'frank-sonnet-c6j' 'worktree' 'sonnet' $'Stress-test.\nmodel-downgrade-ack: a mechanical grep pass; the judgment seat is not needed for it.')"
run_case "a BARE model-downgrade-ack: exempts nothing -> BLOCKED" 2 \
    "$(json_agent_model 'frank' 'frank-sonnet-c6k' 'worktree' 'sonnet' $'Stress-test.\nmodel-downgrade-ack:')"
run_case "model-downgrade-ack: tolerates leading whitespace" 0 \
    "$(json_agent_model 'frank' 'frank-sonnet-c6l' 'worktree' 'sonnet' $'Stress-test.\n   model-downgrade-ack: leading-whitespace fixture, a real reason.')"
run_case "model-downgrade-ack: does NOT relax clause 2b (untruthful name still BLOCKED)" 2 \
    "$(json_agent_model 'frank' 'frank-opus-c6m' 'worktree' 'sonnet' $'Stress-test.\nmodel-downgrade-ack: a real reason, but the name lies about the model.')"
run_case "a verbose lower-tier override id is normalized before ranking -> BLOCKED" 2 \
    "$(json_agent_model 'frank' 'frank-sonnet-c6n' 'worktree' 'claude-sonnet-4-5' 'Stress-test.')"

# Sandbox entity: a judgment role defaulting to opus, and a declaration this
# block rewrites per case. Same shape as the (i) sandbox above.
C6SB="$(mktemp -d -t guard-c6.XXXXXX)"
mkdir -p "$C6SB/.claude/agents"
printf -- '---\nname: judge\nmodel: opus\n---\nA sandbox judgment role that exists only for these cases.\n' >"$C6SB/.claude/agents/judge.md"
c6_config() { printf 'ALLOWED_MODELS="fable opus sonnet haiku"\nMODEL_TIERS="%s"\n' "$1" >"$C6SB/orchestration.config"; }
c6_out() { printf '%s' "$1" | RICHOS_ENTITY_ROOT="$C6SB" "$HOOK" 2>&1; }
c6_case() { # <name> <expected-exit> <expected-substring-or-empty-for-silence> <json>
    local name="$1" expected="$2" needle="$3" json="$4" out rc
    out="$(c6_out "$json")"; rc=$?
    if [ "$rc" -eq "$expected" ] && { { [ -z "$needle" ] && [ -z "$out" ]; } || { [ -n "$needle" ] && printf '%s' "$out" | grep -qF "$needle"; }; }; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        local want="with NO output"; [ -z "$needle" ] || want="mentioning \"$needle\""
        printf '  FAIL  %s (expected exit %s %s, got exit %s: %s)\n' "$name" "$expected" "$want" "$rc" "${out:0:160}"; FAIL=$((FAIL + 1))
    fi
}

# Accepted ack is logged, with both models; a refusal is never logged.
c6_config "fable > opus > sonnet > haiku"
C6_MARK="c6-log-canary-$$"
c6_out "$(json_agent_model 'judge' 'judge-sonnet-log1' 'worktree' 'sonnet' "Judge.
model-downgrade-ack: logging fixture $C6_MARK")" >/dev/null
C6_LOG="$C6SB/.claude/state/model-downgrade-acks.log"
if grep -qF "$C6_MARK" "$C6_LOG" 2>/dev/null && grep -qF "default=opus" "$C6_LOG" && grep -qF "requested=sonnet" "$C6_LOG"; then
    PASS=$((PASS + 1)); printf '  PASS  an accepted model-downgrade-ack: is logged to .claude/state/model-downgrade-acks.log with both models\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  an accepted model-downgrade-ack: is logged to .claude/state/model-downgrade-acks.log with both models\n'
fi
c6_out "$(json_agent_model 'judge' 'judge-sonnet-log2' 'worktree' 'sonnet' 'Judge, no reason.')" >/dev/null
if grep -qF "judge-sonnet-log2" "$C6_LOG" 2>/dev/null; then
    FAIL=$((FAIL + 1)); printf '  FAIL  a REFUSED downgrade was logged as if it were a waiver\n'
else
    PASS=$((PASS + 1)); printf '  PASS  a REFUSED downgrade is not logged (a refusal is not a waiver)\n'
fi

# FAIL OPEN on the clause's own error — allowed, and announced.
c6_config "opus > sonnet"
c6_case "an alias MODEL_TIERS does not rank -> allowed (fail-open)" 0 "SKIPPED" \
    "$(json_agent_model 'judge' 'judge-haiku-fo1' 'worktree' 'haiku' 'Judge.')"
c6_case "the fail-open skip is announced, naming the unranked alias" 0 "'haiku'" \
    "$(json_agent_model 'judge' 'judge-haiku-fo1' 'worktree' 'haiku' 'Judge.')"
c6_case "the fail-open skip reaches the orchestrator as a systemMessage" 0 '"systemMessage"' \
    "$(json_agent_model 'judge' 'judge-haiku-fo1' 'worktree' 'haiku' 'Judge.')"
c6_config ""
c6_case "a BLANK MODEL_TIERS -> allowed (fail-open), announced as blank" 0 "blank" \
    "$(json_agent_model 'judge' 'judge-haiku-fo2' 'worktree' 'haiku' 'Judge.')"
c6_config "opus > > sonnet"
c6_case "a MALFORMED MODEL_TIERS -> allowed (fail-open), announced as malformed" 0 "empty" \
    "$(json_agent_model 'judge' 'judge-haiku-fo3' 'worktree' 'haiku' 'Judge.')"
c6_case "a broken declaration is NOT announced on a spawn that never needed it (no override)" 0 "" \
    "$(json_agent 'judge' 'judge-opus-fo4' 'worktree' 'Judge.')"
c6_case "a broken declaration is NOT announced on model:inherit" 0 "" \
    "$(json_agent_model 'judge' 'judge-opus-fo5' 'worktree' 'inherit' 'Judge.')"

# Parser library missing -> allowed (fail-open), announced.
C6NOLIB="$(mktemp -d -t guard-c6-nolib.XXXXXX)"
mkdir -p "$C6NOLIB/scripts/hooks" "$C6NOLIB/scripts/lib"
cp "$HOOK" "$C6NOLIB/scripts/hooks/guard-worktree-isolation.sh"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$C6NOLIB/scripts/lib/"
chmod +x "$C6NOLIB/scripts/hooks/guard-worktree-isolation.sh"
c6_config "fable > opus > sonnet > haiku"
C6NL_OUT="$(printf '%s' "$(json_agent_model 'judge' 'judge-haiku-fo6' 'worktree' 'haiku' 'Judge.')" | RICHOS_ENTITY_ROOT="$C6SB" "$C6NOLIB/scripts/hooks/guard-worktree-isolation.sh" 2>&1)"
C6NL_RC=$?
if [ "$C6NL_RC" -eq 0 ] && printf '%s' "$C6NL_OUT" | grep -qF "model-tiers.sh is missing"; then
    PASS=$((PASS + 1)); printf '  PASS  parser library missing -> allowed (fail-open), announced\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  parser library missing -> allowed (fail-open), announced (got exit %s: %s)\n' "$C6NL_RC" "${C6NL_OUT:0:160}"
fi
rm -rf "$C6NOLIB"

# DATA, NEVER INFERENCE. A declaration that contradicts the alias names is
# obeyed to the letter. If any consumer ranked by name, this block is the one
# that goes red — and it is the property the whole clause exists for.
c6_config "haiku > opus fable > sonnet"
c6_case "the declared order is obeyed even when it contradicts the alias names: opus-default on haiku -> SILENT" 0 "" \
    "$(json_agent_model 'judge' 'judge-haiku-dn1' 'worktree' 'haiku' 'Judge.')"
c6_case "the declared order is obeyed even when it contradicts the alias names: opus-default on fable (same tier) -> SILENT" 0 "" \
    "$(json_agent_model 'judge' 'judge-fable-dn2' 'worktree' 'fable' 'Judge.')"
c6_case "the declared order is obeyed even when it contradicts the alias names: opus-default on sonnet -> BLOCKED" 2 "model tier" \
    "$(json_agent_model 'judge' 'judge-sonnet-dn3' 'worktree' 'sonnet' 'Judge.')"
rm -rf "$C6SB"

# --- (g) unparseable Agent payload -> exit 2 (fail-closed) ---
run_case "tool_input is not a dict (tool_name IS Agent)" 2 \
    '{"tool_name":"Agent","tool_input":"not-a-dict"}'
run_case "tool_input is null (tool_name IS Agent)" 2 \
    '{"tool_name":"Agent","tool_input":null}'

# --- (h) non-Agent tool_name entirely (structurally different payload) -> exit 0 ---
run_case "totally invalid JSON body (no Agent tool_name resolvable)" 0 'not json'

# --- (i) marker use is best-effort logged to .claude/state/ ---
SANDBOX="$(mktemp -d -t guard-worktree-isolation-log-test.XXXXXX)"
mkdir -p "$SANDBOX/scripts/hooks" "$SANDBOX/scripts/lib" "$SANDBOX/.claude"
cp "$HOOK" "$SANDBOX/scripts/hooks/guard-worktree-isolation.sh"
chmod +x "$SANDBOX/scripts/hooks/guard-worktree-isolation.sh"
# The copied hook resolves its library relative to its own location, and its
# root from the SESSION — so the sandbox needs both the library and an explicit
# declaration. Without the library it refuses to start; without the declaration
# it would write the log into the launching session's repository, which is the
# very behavior under repair.
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$SANDBOX/scripts/lib/"
printf 'ALLOWED_MODELS="fable opus sonnet haiku"\n' >"$SANDBOX/orchestration.config"
printf '%s' "$(json_agent 'worker' 'worker-sonnet-log1' '' $'Do the task.\nmain-checkout-run: needs main checkout for X.')" \
    | RICHOS_ENTITY_ROOT="$SANDBOX" "$SANDBOX/scripts/hooks/guard-worktree-isolation.sh" >/dev/null 2>&1
if [ -f "$SANDBOX/.claude/state/main-checkout-runs.log" ] \
    && grep -qF "worker-sonnet-log1" "$SANDBOX/.claude/state/main-checkout-runs.log" \
    && grep -qF "main-checkout-run:" "$SANDBOX/.claude/state/main-checkout-runs.log"; then
    PASS=$((PASS + 1)); printf '  PASS  marker use logged to .claude/state/main-checkout-runs.log\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  marker use logged to .claude/state/main-checkout-runs.log\n'
fi
# A blocked spawn (no marker) is rejected outright — it never reaches the
# marker-logging path, so no log entry.
printf '%s' "$(json_agent 'deviceqa' 'deviceqa-sonnet-log2' '' 'Run device QA, no marker given.')" \
    | "$SANDBOX/scripts/hooks/guard-worktree-isolation.sh" >/dev/null 2>&1
if [ -f "$SANDBOX/.claude/state/main-checkout-runs.log" ] \
    && grep -qF "deviceqa-sonnet-log2" "$SANDBOX/.claude/state/main-checkout-runs.log"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  blocked spawn (no marker) must NOT be logged as a marker use\n'
else
    PASS=$((PASS + 1)); printf '  PASS  blocked spawn (no marker) must NOT be logged as a marker use\n'
fi
rm -rf "$SANDBOX"

# --- python3 missing from PATH -> BLOCKED (fail-closed), loud stderr ---
# Mirrors the automation QA's repro: with no python3 resolvable on PATH, the guard must
# refuse (non-zero exit) rather than silently waving the spawn through.
FAKEBIN="$(make_fakebin_no_python3)"
NOPY_JSON="$(json_agent 'dev' 'dev-sonnet-1' 'worktree' 'Do the thing.')"
NOPY_OUT="$(printf '%s' "$NOPY_JSON" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" 2>&1 1>/dev/null)"
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

# --- (j) CLAUSE 3 — name reuse is structurally impossible ---
# These use a controlled team dir via GUARD_ISOLATION_TEAMS_DIR so the reuse
# clause is active (the cases above use session "deadbeef…" with no team dir, so
# the clause is inert for them — that inertness is itself the proof the existing
# cases are unaffected).
REUSE_TEAMS="$(mktemp -d -t guard-isolation-reuse.XXXXXX)"
REUSE_SESSION="cafef00d-0000-4000-8000-000000000000"
REUSE_TEAM_DIR="$REUSE_TEAMS/session-cafef00d"
mkdir -p "$REUSE_TEAM_DIR"
export GUARD_ISOLATION_TEAMS_DIR="$REUSE_TEAMS"

# json_agent_sess <subagent> <name> <isolation> <prompt> <session_id>
json_agent_sess() {
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
subagent, name, isolation, prompt, sid = sys.argv[1:6]
ti = {"prompt": prompt}
if subagent: ti["subagent_type"] = subagent
if name: ti["name"] = name
if isolation: ti["isolation"] = isolation
print(json.dumps({"tool_name": "Agent", "tool_input": ti, "session_id": sid}))
PY
}

# Seed the roster with an ACTIVE member and the event logs with a COMPLETED
# (roster-pruned) member — the two independent history sources.
cat >"$REUSE_TEAM_DIR/config.json" <<JSON
{ "name": "session-cafef00d",
  "members": [
    { "agentId": "team-lead@session-cafef00d", "name": "team-lead" },
    { "agentId": "dev-sonnet-active@session-cafef00d", "name": "dev-sonnet-active" }
  ] }
JSON
printf '{"event":"TaskCompleted","teammate":"eng-sonnet-done"}\n' >"$REUSE_TEAM_DIR/task-events.jsonl"
printf '{"event":"TeammateIdle","teammate":"qa-sonnet-gone"}\n' >"$REUSE_TEAM_DIR/idle-events.jsonl"

# (j1) fresh name -> exit 0, and THIS guard must NOT have written the ledger.
#
# THE NAME-BURN REGRESSION. This guard runs FIRST in a four-hook
# PreToolUse[Agent] chain, so anything it records is recorded before the later
# hooks have had their veto. Recording here burns the name of a spawn that a
# later hook then blocks — a teammate that never existed, whose corrected retry
# is refused as "reuse". Observed in production 2026-08-01 and reproduced
# against this engine 2026-08-28. The append moved to the PostToolUse partner
# (detect-nonnative-worktree.sh), which fires only for a call that ran.
#
# This case therefore asserts the ABSENCE of a write. Its positive counterpart
# — that the ledger is still WRITTEN, by the partner — is (j2), because
# "nobody writes it" would satisfy this case and destroy the reuse clause.
FRESH_JSON="$(json_agent_sess 'dev' 'dev-sonnet-fresh1' 'worktree' 'Do the thing.' "$REUSE_SESSION")"
printf '%s' "$FRESH_JSON" | "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -qxF "dev-sonnet-fresh1" "$REUSE_TEAM_DIR/spawned-names.log" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  reuse: fresh name allowed, and NOT burned into the ledger by this PreToolUse guard\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  reuse: fresh name allowed + not recorded here (exit %s)\n' "$rc"
fi

# (j1b) a spawn this guard allowed but a LATER hook blocked must be re-issuable
# under the SAME name. This is the burn, stated as a behavior.
printf '%s' "$FRESH_JSON" | "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && { PASS=$((PASS+1)); printf '  PASS  reuse: a name this guard approved but never executed is re-issuable\n'; } \
                || { FAIL=$((FAIL+1)); printf '  FAIL  reuse: name burned by an approval that never executed (exit %s)\n' "$rc"; }

# (j2) the ledger IS still consulted — write it the way the PostToolUse partner
# does, and the same name must now be refused. Without this arm, (j1) would
# also be satisfied by a guard that stopped reading the ledger entirely.
printf 'dev-sonnet-fresh1\n' >>"$REUSE_TEAM_DIR/spawned-names.log"
printf '%s' "$FRESH_JSON" | "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && { PASS=$((PASS+1)); printf '  PASS  reuse: ledger-recorded name reused -> block\n'; } \
                || { FAIL=$((FAIL+1)); printf '  FAIL  reuse: ledger-recorded name reused -> block (exit %s)\n' "$rc"; }

# (j3) ACTIVE roster name reused -> block
printf '%s' "$(json_agent_sess 'dev' 'dev-sonnet-active' 'worktree' 'x' "$REUSE_SESSION")" | "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && { PASS=$((PASS+1)); printf '  PASS  reuse: active roster name -> block\n'; } \
                || { FAIL=$((FAIL+1)); printf '  FAIL  reuse: active roster name -> block (exit %s)\n' "$rc"; }

# (j4) COMPLETED name absent from live roster but in event logs -> block (critical)
printf '%s' "$(json_agent_sess 'eng' 'eng-sonnet-done' 'worktree' 'x' "$REUSE_SESSION")" | "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && { PASS=$((PASS+1)); printf '  PASS  reuse: completed name (event-log only) -> block\n'; } \
                || { FAIL=$((FAIL+1)); printf '  FAIL  reuse: completed name (event-log only) -> block (exit %s)\n' "$rc"; }
printf '%s' "$(json_agent_sess 'qa' 'qa-sonnet-gone' 'worktree' 'x' "$REUSE_SESSION")" | "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && { PASS=$((PASS+1)); printf '  PASS  reuse: completed name (idle-log only) -> block\n'; } \
                || { FAIL=$((FAIL+1)); printf '  FAIL  reuse: completed name (idle-log only) -> block (exit %s)\n' "$rc"; }

# (j5) block message is self-documenting: names the collision + prescribes fresh id
REUSE_MSG="$(printf '%s' "$(json_agent_sess 'dev' 'dev-sonnet-active' 'worktree' 'x' "$REUSE_SESSION")" | "$HOOK" 2>&1 >/dev/null)"
if printf '%s' "$REUSE_MSG" | grep -qF "name 'dev-sonnet-active' has ALREADY been used" \
   && printf '%s' "$REUSE_MSG" | grep -qF "FRESH"; then
    PASS=$((PASS+1)); printf '  PASS  reuse: block message self-documenting (collision + fresh-id fix)\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL  reuse: block message self-documenting\n'
fi

# (j6) reusing team-lead is NOT a collision (lead is not a spawnable name) — a
# fresh non-colliding name still passes even though team-lead is in roster
printf '%s' "$(json_agent_sess 'plan' 'plan-sonnet-1' 'worktree' 'x' "$REUSE_SESSION")" | "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && { PASS=$((PASS+1)); printf '  PASS  reuse: unrelated fresh name still allowed alongside roster\n'; } \
                || { FAIL=$((FAIL+1)); printf '  FAIL  reuse: unrelated fresh name still allowed (exit %s)\n' "$rc"; }

# (j7) inertness proof: with NO resolvable team dir (bad session), a name that
# WOULD collide in the seeded team is allowed (clause inert) — this is exactly
# why the un-sessioned cases above are unaffected.
printf '%s' "$(json_agent_sess 'dev' 'dev-sonnet-active' 'worktree' 'x' 'deadbeef-0000-4000-8000-000000000000')" | "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && { PASS=$((PASS+1)); printf '  PASS  reuse: clause inert without a resolvable team dir\n'; } \
                || { FAIL=$((FAIL+1)); printf '  FAIL  reuse: clause inert without a resolvable team dir (exit %s)\n' "$rc"; }

unset GUARD_ISOLATION_TEAMS_DIR
rm -rf "$REUSE_TEAMS"

# --- (l) CLAUSE 4 — cross-repository work runs in a worktree RichOS registered ---
#
# The Agent tool's `cwd` is "mutually exclusive with isolation: worktree", so a
# cross-repository teammate cannot be natively isolated; it works in a
# hand-rolled worktree. The rule is inverted from "improvise one" to "only a
# REGISTERED one": every pair below has its refusal beside its pass.
CR="$(cd "$(mktemp -d -t guard-isolation-crossrepo.XXXXXX)" && pwd -P)"
export RICHOS_WORKTREE_LEDGER="$CR/wt-ledger.jsonl"
CR_REPO="$CR/other"
mkdir -p "$CR_REPO"
git -C "$CR_REPO" init -q -b main
printf 'seed\n' >"$CR_REPO/seed.txt"
git -C "$CR_REPO" add -A
git -C "$CR_REPO" commit -q -m seed
# a REGISTERED linked worktree (what scripts/create-teammate-worktree.sh makes)
git -C "$CR_REPO" worktree add -q -b echo-opus-reg1 "$CR/other-wt/echo-opus-reg1"
python3 "$SCRIPT_DIR/../lib/worktree-ledger.py" record registered --teammate echo-opus-reg1 \
    --repo "$CR_REPO" --worktree "$CR/other-wt/echo-opus-reg1" --branch echo-opus-reg1 --class hand-rolled >/dev/null
# an UNREGISTERED linked worktree (improvised)
git -C "$CR_REPO" worktree add -q -b echo-opus-imp1 "$CR/other-wt/echo-opus-imp1"

json_cwd() { # <name> <isolation> <cwd> <prompt>
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
name, isolation, cwd, prompt = sys.argv[1:5]
ti = {"subagent_type": "dev", "name": name, "prompt": prompt}
if isolation: ti["isolation"] = isolation
if cwd: ti["cwd"] = cwd
print(json.dumps({"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000"}))
PY
}

# (l1) cwd = REGISTERED linked worktree, no isolation -> ALLOWED
run_case "cwd into a REGISTERED cross-repo worktree, no isolation -> allowed" 0 \
    "$(json_cwd 'echo-opus-reg1' '' "$CR/other-wt/echo-opus-reg1" 'Work there.')"
# (l2) cwd = linked worktree with NO registration -> BLOCKED, naming the helper
run_case "cwd into an UNREGISTERED linked worktree -> BLOCKED" 2 \
    "$(json_cwd 'echo-opus-imp1' '' "$CR/other-wt/echo-opus-imp1" 'Work there.')"
run_case_msg "unregistered-cwd message names the helper" 'create-teammate-worktree.sh' \
    "$(json_cwd 'echo-opus-imp1' '' "$CR/other-wt/echo-opus-imp1" 'Work there.')"
run_case_msg "unregistered-cwd message says the ledger holds no registration" 'holds NO registration' \
    "$(json_cwd 'echo-opus-imp1' '' "$CR/other-wt/echo-opus-imp1" 'Work there.')"
# (l3) cwd = the MAIN checkout -> BLOCKED (a teammate never works in main)
run_case "cwd = a main checkout -> BLOCKED" 2 \
    "$(json_cwd 'echo-opus-main1' '' "$CR_REPO" 'Work there.')"
# (l4) cwd = nonexistent -> BLOCKED
run_case "cwd = nonexistent path -> BLOCKED" 2 \
    "$(json_cwd 'echo-opus-none1' '' "$CR/nowhere" 'Work there.')"
# (l5) cwd + isolation -> BLOCKED, named as mutually exclusive
run_case "cwd together with isolation:worktree -> BLOCKED (mutually exclusive)" 2 \
    "$(json_cwd 'echo-opus-both1' 'worktree' "$CR/other-wt/echo-opus-reg1" 'Work there.')"
run_case_msg "cwd+isolation message says mutually exclusive" 'mutually exclusive' \
    "$(json_cwd 'echo-opus-both1' 'worktree' "$CR/other-wt/echo-opus-reg1" 'Work there.')"
# (l6) cwd spawn still needs a well-formed name (clause 2 not relaxed)
run_case "cwd spawn with a bare name -> BLOCKED (name contract not relaxed)" 2 \
    "$(json_cwd 'echo' '' "$CR/other-wt/echo-opus-reg1" 'Work there.')"
# (l7) cross-repo-worktree: line with isolation: registered -> allowed; unregistered -> blocked
run_case "cross-repo-worktree: REGISTERED path + isolation -> allowed" 0 \
    "$(json_cwd 'echo-opus-mk1' 'worktree' '' $'Do it.\ncross-repo-worktree: '"$CR/other-wt/echo-opus-reg1")"
run_case "cross-repo-worktree: UNREGISTERED path + isolation -> BLOCKED" 2 \
    "$(json_cwd 'echo-opus-mk2' 'worktree' '' $'Do it.\ncross-repo-worktree: '"$CR/other-wt/echo-opus-imp1")"
# (l8) a prompt that instructs a hand-rolled worktree -> BLOCKED; hand-roll-ack: -> allowed + logged
run_case "prompt instructing 'git -C <repo> worktree add' -> BLOCKED" 2 \
    "$(json_cwd 'echo-opus-hr1' 'worktree' '' "Create a worktree: git -C $CR_REPO worktree add $CR/other-wt/x -b x, then work.")"
run_case_msg "hand-roll refusal names the helper and the ack" 'hand-roll-ack:' \
    "$(json_cwd 'echo-opus-hr1' 'worktree' '' "Create a worktree: git -C $CR_REPO worktree add $CR/other-wt/x -b x, then work.")"
run_case "prompt instructing 'git worktree add' with a hand-roll-ack: line -> allowed" 0 \
    "$(json_cwd 'echo-opus-hr2' 'worktree' '' $'Fix the helper that runs git worktree add.\nhand-roll-ack: this task is about the worktree tooling itself')"
run_case "an ordinary prompt mentioning neither -> allowed (no false positive)" 0 \
    "$(json_cwd 'echo-opus-plain1' 'worktree' '' 'Add a worktree-lifecycle section to the README and commit.')"
# (l9) FAIL-CLOSED without the ledger library: a cwd spawn in a sandbox copy
#      of the guard that lacks scripts/lib/worktree-ledger.py is BLOCKED and
#      the message names the missing file; a plain isolated spawn there still passes.
NOLIB="$(mktemp -d -t guard-isolation-nolib.XXXXXX)"
mkdir -p "$NOLIB/scripts/hooks" "$NOLIB/scripts/lib" "$NOLIB/.claude"
cp "$HOOK" "$NOLIB/scripts/hooks/guard-worktree-isolation.sh"; chmod +x "$NOLIB/scripts/hooks/guard-worktree-isolation.sh"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$NOLIB/scripts/lib/"
printf 'ALLOWED_MODELS="fable opus sonnet haiku"\n' >"$NOLIB/orchestration.config"
NOLIB_OUT="$(printf '%s' "$(json_cwd 'echo-opus-nolib1' '' "$CR/other-wt/echo-opus-reg1" 'Work there.')" \
    | RICHOS_ENTITY_ROOT="$NOLIB" "$NOLIB/scripts/hooks/guard-worktree-isolation.sh" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$NOLIB_OUT" | grep -qF 'ownership ledger library is missing'; then
    PASS=$((PASS + 1)); printf '  PASS  cwd spawn with the ledger library MISSING -> BLOCKED, naming the missing file (fail-closed)\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  cwd spawn without the ledger library (exit %s): %s\n' "$rc" "$NOLIB_OUT"
fi
printf '%s' "$(json_cwd 'echo-opus-nolib2' 'worktree' '' 'Do the thing.')" \
    | RICHOS_ENTITY_ROOT="$NOLIB" "$NOLIB/scripts/hooks/guard-worktree-isolation.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && { PASS=$((PASS + 1)); printf '  PASS  an isolated spawn without the ledger library still passes (clause 4 is inert for it)\n'; } \
                || { FAIL=$((FAIL + 1)); printf '  FAIL  isolated spawn without the ledger library blocked (exit %s)\n' "$rc"; }
# (l10) the hand-roll-ack use is logged
if grep -qF 'echo-opus-hr2' "$RICHOS_ENTITY_ROOT/.claude/state/hand-roll-acks.log" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  hand-roll-ack use is logged to .claude/state/hand-roll-acks.log\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  hand-roll-ack use not logged\n'
fi

# ---------------------------------------------------------------------------
# (m) CLAUSE 5 — THE STAFFING GATE.
# ---------------------------------------------------------------------------
# READONLY_ALLOWLIST answers "does this type need a worktree?". It never
# answered "may delegated work be STAFFED here?", and on 2026-09-02 the two
# were read as one permission: an engine-wide audit went to `Explore` because a
# roster teammate would have needed a worktree created first. These cases are a
# TWO-SIDED canary — a gate that refuses everything would satisfy "refused
# without a hatch" and is caught by the WITH-hatch and roster arms.

M_GOOD='generic-agent: a read-only sweep across three repositories that no roster teammate has a seat for'

# (m1) NO hatch -> BLOCKED, for every non-utility generic type.
run_case "Explore with NO generic-agent: line -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit every hook in the engine and report what is unwired.')"
run_case "Plan with NO generic-agent: line -> BLOCKED" 2 \
    "$(json_agent 'Plan' '' '' 'Draft the sprint plan.')"

# (m2) the refusal NAMES THE ALTERNATIVE and says why it matters — a refusal
# that only says no teaches nothing and gets worked around.
run_case_msg "refusal names the roster teammate as the fix" 'ROSTER TEAMMATE' \
    "$(json_agent 'Explore' '' '' 'Audit every hook in the engine.')"
run_case_msg "refusal says a generic agent is invisible in the team display" "team display" \
    "$(json_agent 'Explore' '' '' 'Audit every hook in the engine.')"
run_case_msg "refusal says a generic agent leaves no commit" 'leaves no commit' \
    "$(json_agent 'Explore' '' '' 'Audit every hook in the engine.')"
run_case_msg "refusal names the hatch line by its exact shape" 'generic-agent: <why no roster teammate fits this work>' \
    "$(json_agent 'Explore' '' '' 'Audit every hook in the engine.')"
run_case_msg "refusal separates the isolation exemption from the staffing question" 'has never been a permission to STAFF' \
    "$(json_agent 'Explore' '' '' 'Audit every hook in the engine.')"

# (m3) a WELL-FORMED reason PASSES (the other side of the canary).
run_case "Explore WITH a well-formed generic-agent: reason -> allowed" 0 \
    "$(json_agent 'Explore' '' '' "Audit every hook in the engine.
$M_GOOD")"
run_case "the hatch is recognized anywhere in the prompt, not only on line 1" 0 \
    "$(json_agent 'Explore' '' '' "$M_GOOD
Audit every hook in the engine.")"
run_case "the hatch tolerates leading whitespace" 0 \
    "$(json_agent 'Explore' '' '' "Audit.
   $M_GOOD")"

# (m4) A BARE OR TRIVIAL MARKER EXEMPTS NOTHING.
run_case "bare 'generic-agent:' with no reason -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent:')"
run_case "'generic-agent: because' -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: because')"
run_case "'generic-agent: n/a' -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: n/a')"
run_case "'generic-agent: -' -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: -')"
run_case_msg "a too-short reason is refused BY LENGTH, named" 'A bare or token marker exempts nothing' \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: because')"
# long enough in characters, but filler: five stopwords carrying nothing.
run_case "a long-but-empty reason (stopwords only) -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: this is the one that will just do it and that is all there is')"
run_case_msg "the filler refusal says so in those terms" 'reads as filler' \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: this is the one that will just do it and that is all there is')"

# (m5) SPEED/CONVENIENCE is refused BY NAME — it is the incident's own reason.
run_case "reason 'faster to dispatch' -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: a roster teammate would need a worktree created first and this is faster to dispatch')"
run_case "reason 'saves time' -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: dispatching a built-in here saves time versus provisioning a teammate worktree')"
run_case "reason 'more convenient' -> BLOCKED" 2 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: it is simply more convenient than provisioning a roster teammate right now')"
run_case_msg "the speed refusal names create-teammate-worktree.sh as the answer" 'create-teammate-worktree.sh' \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: a roster teammate would need a worktree created first and this is faster to dispatch')"
# NO FALSE POSITIVE: a genuine reason that happens to mention worktrees passes.
run_case "a genuine reason mentioning worktrees is NOT read as a speed excuse" 0 \
    "$(json_agent 'Explore' '' '' 'Audit.
generic-agent: this enumerates worktree tooling across repositories the roster has no seat in')"

# (m6) HARNESS UTILITIES DO NOT CARRY THE HATCH — an over-broad guard that
# fires on a statusline change is how a defense becomes a formality.
run_case "statusline-setup needs NO hatch (harness utility)" 0 \
    "$(json_agent 'statusline-setup' '' '' 'Configure the statusline.')"
run_case "claude-code-guide needs NO hatch (harness utility)" 0 \
    "$(json_agent 'claude-code-guide' '' '' 'Explain how hooks work.')"

# (m7) GENERIC_AGENT_TYPES closes the obvious detour: general-purpose is NOT on
# the read-only allowlist, so before clause 5 it sailed through the whole
# contract on isolation + a truthful name alone.
run_case "general-purpose, isolated + well-named, NO hatch -> BLOCKED" 2 \
    "$(json_agent 'general-purpose' 'gen-sonnet-d1' 'worktree' 'Do the work.')"
run_case "general-purpose, isolated + well-named, WITH hatch -> allowed" 0 \
    "$(json_agent 'general-purpose' 'gen-sonnet-d2' 'worktree' "Do the work.
$M_GOOD")"
# ...and the hatch does NOT relax the rest of the contract for a file-capable type.
run_case "general-purpose WITH hatch but NO isolation -> still BLOCKED (clauses 1-2 hold)" 2 \
    "$(json_agent 'general-purpose' 'gen-sonnet-d3' '' "Do the work.
$M_GOOD")"

# (m8) ROSTER TEAMMATES ARE WHOLLY UNAFFECTED — the gate must not tax the
# normal path, or it will be routed around.
run_case "roster-style type, isolated, no hatch -> allowed (clause 5 inert)" 0 \
    "$(json_agent 'dev' 'dev-sonnet-m8a' 'worktree' 'Fix the bug and commit.')"
run_case "roster-style type, isolated, no hatch, second name -> allowed" 0 \
    "$(json_agent 'deviceqa' 'deviceqa-sonnet-m8b' 'worktree' 'Run device QA.')"
run_case "roster-style type WITHOUT isolation is still blocked by clause 1, not 5" 2 \
    "$(json_agent 'dev' 'dev-sonnet-m8c' '' 'Fix the bug.')"
run_case_msg "a roster-type refusal is the ISOLATION message, never the staffing one" 'missing native isolation' \
    "$(json_agent 'dev' 'dev-sonnet-m8d' '' 'Fix the bug.')"

# (m9) CONFIG IS THE SWITCH, AND ITS DEFAULT IS DENY. A type declared a harness
# utility in the entity's own config is exempt; a type merely added to
# READONLY_ALLOWLIST is NOT.
M9="$(mktemp -d -t guard-isolation-clause5.XXXXXX)"
mkdir -p "$M9/scripts/hooks" "$M9/scripts/lib" "$M9/.claude"
cp "$HOOK" "$M9/scripts/hooks/guard-worktree-isolation.sh"; chmod +x "$M9/scripts/hooks/guard-worktree-isolation.sh"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$SCRIPT_DIR/../lib/worktree-ledger.py" "$M9/scripts/lib/" 2>/dev/null || true
{
    printf 'ALLOWED_MODELS="fable opus sonnet haiku"\n'
    printf 'READONLY_ALLOWLIST="Explore Plan claude-code-guide statusline-setup housekeeping"\n'
    printf 'HARNESS_UTILITY_TYPES="claude-code-guide statusline-setup housekeeping"\n'
} >"$M9/orchestration.config"
m9_run() { # <payload> -> echoes rc
    printf '%s' "$1" | RICHOS_ENTITY_ROOT="$M9" "$M9/scripts/hooks/guard-worktree-isolation.sh" >/dev/null 2>&1
    echo $?
}
rc="$(m9_run "$(json_agent 'housekeeping' '' '' 'Tidy the config.')")"
[ "$rc" -eq 0 ] && { PASS=$((PASS + 1)); printf '  PASS  a type DECLARED in HARNESS_UTILITY_TYPES needs no hatch\n'; } \
                || { FAIL=$((FAIL + 1)); printf '  FAIL  declared harness utility was blocked (exit %s)\n' "$rc"; }
{
    printf 'ALLOWED_MODELS="fable opus sonnet haiku"\n'
    printf 'READONLY_ALLOWLIST="Explore Plan claude-code-guide statusline-setup housekeeping"\n'
    printf 'HARNESS_UTILITY_TYPES="claude-code-guide statusline-setup"\n'
} >"$M9/orchestration.config"
rc="$(m9_run "$(json_agent 'housekeeping' '' '' 'Tidy the config.')")"
[ "$rc" -eq 2 ] && { PASS=$((PASS + 1)); printf '  PASS  a type merely ADDED to READONLY_ALLOWLIST still needs the hatch (default is deny)\n'; } \
                || { FAIL=$((FAIL + 1)); printf '  FAIL  undeclared allowlist type waved through (exit %s)\n' "$rc"; }
rm -rf "$M9"

# (m10) THE USE IS LOGGED, so a habit of waiving is visible rather than invisible.
GA_LOG="$RICHOS_ENTITY_ROOT/.claude/state/generic-agent-dispatches.log"
GA_MARK="clause5-log-canary-$$"
printf '%s' "$(json_agent 'Explore' '' '' "Audit.
generic-agent: no roster teammate covers this cross-repository enumeration $GA_MARK")" \
    | "$HOOK" >/dev/null 2>&1
if grep -qF "$GA_MARK" "$GA_LOG" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  PASS  an accepted generic-agent: hatch is logged to .claude/state/generic-agent-dispatches.log\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  accepted generic-agent: hatch was NOT logged to %s\n' "$GA_LOG"
fi
# and a REFUSED dispatch is never logged (a refusal is not a waiver).
GA_MARK2="clause5-refused-canary-$$"
printf '%s' "$(json_agent 'Explore' '' '' "Audit.
generic-agent: nope $GA_MARK2")" | "$HOOK" >/dev/null 2>&1
if grep -qF "$GA_MARK2" "$GA_LOG" 2>/dev/null; then
    FAIL=$((FAIL + 1)); printf '  FAIL  a REFUSED generic-agent dispatch was logged as if it were a waiver\n'
else
    PASS=$((PASS + 1)); printf '  PASS  a REFUSED generic-agent dispatch is not logged (a refusal is not a waiver)\n'
fi

rm -rf "$NOLIB" "$CR"
unset RICHOS_WORKTREE_LEDGER

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-worktree-isolation tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== guard-worktree-isolation tests: all $PASS passed ==="
    exit 0
fi
