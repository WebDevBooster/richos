#!/usr/bin/env bash
#
# reader-teammate-hint.test.sh — regression tests for
# scripts/hooks/reader-teammate-hint.sh.
#
# Covers: (a) full-read task aimed at a generic reader -> exit 2, message
# names the reader specialist; (b) quick single-file locate aimed at Explore
# -> exit 0; (c) task aimed at the reader specialist -> exit 0; (d) build
# teammate whose prompt merely mentions reading -> exit 0; (e) non-Agent
# tool_name -> exit 0.
#
# Run directly: scripts/hooks/reader-teammate-hint.test.sh
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

HOOK="$SCRIPT_DIR/reader-teammate-hint.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG="$REPO_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${READER_TEAMMATE:=reed}"

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

# json_agent <subagent_type> <prompt>
json_agent() {
    local subagent="$1" prompt="$2"
    python3 - "$subagent" "$prompt" <<'PY'
import json, sys
subagent, prompt = sys.argv[1], sys.argv[2]
ti = {"prompt": prompt}
if subagent:
    ti["subagent_type"] = subagent
print(json.dumps({"tool_name": "Agent", "tool_input": ti, "session_id": "deadbeef-0000-4000-8000-000000000000"}))
PY
}

echo "=== reader-teammate-hint tests ==="

# --- non-Agent tool passes through untouched ---
run_case "non-Agent tool (Bash)" 0 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run_case "non-Agent tool (Read)" 0 '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'

# --- (a) full-read task aimed at a generic reader -> exit 2, names the reader ---
run_case "full-read task, Explore"        2 "$(json_agent 'Explore' 'Read all of the onboarding docs in full and enumerate every screen from the wiki.')"
run_case "full-read task, general-purpose" 2 "$(json_agent 'general-purpose' 'Ingest every ADR in docs/ end-to-end and summarize.')"
run_case "full-read task, unset subagent_type" 2 "$(json_agent '' 'Read the full onboarding wiki and catalog every page.')"
run_case_msg "full-read message names the reader specialist" "$READER_TEAMMATE" "$(json_agent 'Explore' 'Read all of the onboarding docs in full and enumerate every screen from the wiki.')"

# --- (b) quick single-file locate aimed at Explore -> exit 0 ---
run_case "quick locate, Explore" 0 "$(json_agent 'Explore' 'Find where the login button component is defined.')"

# --- (c) task aimed at the reader specialist -> exit 0 (even with full-read wording) ---
run_case "full-read task aimed at the reader specialist" 0 "$(json_agent "$READER_TEAMMATE" 'Read all of the onboarding docs in full and enumerate every screen.')"

# --- (d) build teammate whose prompt merely mentions reading -> exit 0 ---
run_case "build teammate (dev) mentions reading" 0 "$(json_agent 'dev' 'Read schema.ts and add the new field.')"
run_case "build teammate (builder) mentions reading"  0 "$(json_agent 'builder' 'Read the existing Home screen component and add a new card.')"

# --- (e) tool_name is not Agent -> exit 0 ---
run_case "Bash call with full-read-shaped command text" 0 '{"tool_name":"Bash","tool_input":{"command":"echo Read all of the wiki in full"}}'

# --- python3 missing from PATH -> BLOCKS (fail-closed), loud stderr ---
# Mirrors the automation QA's repro: with no python3 resolvable on PATH, the hint must
# refuse (non-zero exit) rather than silently letting a misrouted full-read
# task sail through with no redirect.
FAKEBIN="$(make_fakebin_no_python3)"
NOPY_JSON="$(json_agent 'Explore' 'Read all of the onboarding docs in full and enumerate every screen from the wiki.')"
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

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== reader-teammate-hint tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== reader-teammate-hint tests: all $PASS passed ==="
    exit 0
fi
