#!/usr/bin/env bash
#
# scan-secrets.test.sh — regression tests for scripts/hooks/scan-secrets.sh.
#
# Covers: (a) positive cases — every vendor-prefix pattern (AWS, GitHub incl.
# fine-grained PAT, Anthropic, OpenAI incl. project keys, Stripe LIVE keys,
# PEM private key) and the generic high-entropy key=value literal class, each
# across Write/Edit/MultiEdit/NotebookEdit tool shapes; (b) negative cases —
# clean content, non-Write/Edit tools, malformed JSON (fail-open, matching
# guard-main-checkout-writes.sh's sibling convention); (c) placeholder-must-
# NOT-false-positive cases — repeated-char placeholders (incl. the exact
# `re_xxxxxxxxx` shape cited in the roadmap), known placeholder words,
# environment-variable-reference syntax, Stripe TEST-mode keys, and a
# SECRET_SCAN_ALLOWLIST config entry; (d) the python3-missing fail-closed
# case, mirroring the rest of the hook family.
#
# Run directly: scripts/hooks/scan-secrets.test.sh
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

HOOK="$SCRIPT_DIR/scan-secrets.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# json_write <tool> <content-field-name> <value> [file_path]
json_write() {
    python3 -c "
import json, sys
tool, field, value, fp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ti = {'file_path': fp}
ti[field] = value
print(json.dumps({'tool_name': tool, 'tool_input': ti}))
" "$1" "$2" "$3" "${4:-/tmp/x.txt}"
}

# json_multiedit <new_string_1> [new_string_2 ...]
json_multiedit() {
    python3 -c "
import json, sys
edits = [{'old_string': 'x', 'new_string': v} for v in sys.argv[1:]]
print(json.dumps({'tool_name': 'MultiEdit', 'tool_input': {'file_path': '/tmp/x.txt', 'edits': edits}}))
" "$@"
}

# make_fakebin_no_python3 — mirrors the rest of the hook family's own repro.
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

echo "=== scan-secrets tests ==="

# --- pass-through: non-Write/Edit tool, missing content, malformed JSON ---
run_case "non-Write tool (Bash) passes"      0 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run_case "Write with no content field passes" 0 '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"}}'
run_case "malformed JSON fails OPEN (sibling convention)" 0 'this is not json'
run_case "clean Write content passes"        0 "$(json_write Write content 'hello world, nothing secret here')"

# --- (a) POSITIVE — vendor-prefix patterns, one per vendor ---
run_case "AWS access key (Write)" 2 \
    "$(json_write Write content 'AWS_KEY=AKIAABCDEFGHIJKLMNOP')"
run_case "GitHub personal token (Edit)" 2 \
    "$(json_write Edit new_string 'TOKEN = "ghp_ABCDEFGHIJ1234567890abcdefghij123456"')"
run_case "GitHub fine-grained PAT" 2 \
    "$(json_write Write content 'github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')"
run_case "Anthropic API key" 2 \
    "$(json_write Write content 'key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"')"
run_case "OpenAI project API key" 2 \
    "$(json_write Write content 'key = "sk-proj-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP1234"')"
run_case "OpenAI classic API key" 2 \
    "$(json_write Write content 'key = "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL"')"
run_case "Stripe LIVE secret key" 2 \
    "$(json_write Write content 'const key = "sk_live_4eC39HqLyjWDarjtT1zdp7dc";')"
run_case "Stripe LIVE publishable key" 2 \
    "$(json_write Write content 'const key = "pk_live_4eC39HqLyjWDarjtT1zdp7dc";')"
run_case "PEM private key block" 2 \
    "$(json_write Write content $'-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA...\n-----END RSA PRIVATE KEY-----')"

# --- (a) POSITIVE — generic key=value, high entropy ---
run_case "password= literal, high entropy" 2 \
    "$(json_write Write content 'password = "Xk9\$mQp2zR7vLw4Tn8Bq"')"
run_case "api_key= literal, high entropy" 2 \
    "$(json_write Write content 'api_key: "aB3xQ9zM2kP7wR5vN8tL"')"
run_case "secret= literal, high entropy" 2 \
    "$(json_write Write content 'secret=zK4pQ8mX2vB7nR9wL3tY')"

# --- (a) POSITIVE — MultiEdit and NotebookEdit tool shapes ---
run_case "MultiEdit: secret in one of several edits" 2 \
    "$(json_multiedit 'harmless change' 'AWS_KEY=AKIAABCDEFGHIJKLMNOP' 'another harmless change')"
run_case "NotebookEdit: secret in new_source" 2 \
    "$(python3 -c 'import json; print(json.dumps({"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/tmp/x.ipynb","new_source":"key = \"sk-ant-api03-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP\""}}))')"

run_case_msg "block message never echoes the full secret" 'redacted' \
    "$(json_write Write content 'AWS_KEY=AKIAABCDEFGHIJKLMNOP')"
run_case_msg "block message points at SECRET_SCAN_ALLOWLIST" 'SECRET_SCAN_ALLOWLIST' \
    "$(json_write Write content 'AWS_KEY=AKIAABCDEFGHIJKLMNOP')"

# --- (c) PLACEHOLDER — must NOT false-positive ---
run_case "placeholder re_xxxxxxxxx (roadmap's cited example)" 0 \
    "$(json_write Write content 'api_key = "re_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"')"
run_case "repeated-char placeholder (all zeros)" 0 \
    "$(json_write Write content 'token = "00000000000000000000"')"
run_case "known placeholder word (changeme)" 0 \
    "$(json_write Write content 'password = "changeme_please_1234567890"')"
run_case "known placeholder word (placeholder)" 0 \
    "$(json_write Write content 'api_key = "placeholder_value_never_real"')"
run_case "env-var reference \${VAR} syntax" 0 \
    "$(json_write Write content 'api_key = "\${OPENAI_API_KEY}"')"
run_case "env-var reference os.environ" 0 \
    "$(json_write Write content 'api_key = os.environ["API_KEY"]')"
run_case "env-var reference process.env" 0 \
    "$(json_write Write content 'const apiKey = process.env.OPENAI_API_KEY;')"
run_case "Stripe TEST-mode key is not flagged" 0 \
    "$(json_write Write content 'const key = "sk_test_4eC39HqLyjWDarjtT1zdp7dc";')"
run_case "short generic value under MIN_LENGTH passes" 0 \
    "$(json_write Write content 'pwd=abc123')"

# --- (c) config-driven allowlist ---
ALLOW_CONFIG_ROOT="$(mktemp -d -t scan-secrets-allowlist.XXXXXX)"
mkdir -p "$ALLOW_CONFIG_ROOT/scripts/hooks"
cp "$HOOK" "$ALLOW_CONFIG_ROOT/scripts/hooks/scan-secrets.sh"
chmod +x "$ALLOW_CONFIG_ROOT/scripts/hooks/scan-secrets.sh"
mkdir -p "$ALLOW_CONFIG_ROOT/scripts/lib"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$ALLOW_CONFIG_ROOT/scripts/lib/"
cat >"$ALLOW_CONFIG_ROOT/orchestration.config" <<'CFG'
SECRET_SCAN_ALLOWLIST="AKIAABCDEFGHIJKLMNOP"
CFG
ALLOWLIST_JSON="$(json_write Write content 'AWS_KEY=AKIAABCDEFGHIJKLMNOP')"
# This case is specifically about the config being read from the ROOT UNDER
# TEST, so it declares that root rather than inheriting the file-level one.
printf '%s' "$ALLOWLIST_JSON" | RICHOS_ENTITY_ROOT="$ALLOW_CONFIG_ROOT" "$ALLOW_CONFIG_ROOT/scripts/hooks/scan-secrets.sh" >/dev/null 2>&1
ALLOWLIST_RC=$?
if [ "$ALLOWLIST_RC" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  orchestration.config SECRET_SCAN_ALLOWLIST suppresses a real match\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  orchestration.config SECRET_SCAN_ALLOWLIST suppresses a real match (rc=%s)\n' "$ALLOWLIST_RC"
fi
rm -rf "$ALLOW_CONFIG_ROOT"

# --- python3 missing from PATH -> BLOCKS (fail-closed), loud stderr ---
FAKEBIN="$(make_fakebin_no_python3)"
NOPY_JSON="$(json_write Write content 'AWS_KEY=AKIAABCDEFGHIJKLMNOP')"
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

# --- SECRET_SCAN_CODE_AWARE (opt-in precision, default OFF) ----------------
#
# Every case is a TRIPLE: what the strict default does, what the opt-in does,
# and — for the cases that matter — the cost the opt-in buys the precision
# with. Presenting only the wins would be selling the setting, not testing it.
#
# The dense-token fixtures below are ASSEMBLED at run time. Written out as
# literals they are exactly what this scanner exists to block, so a scanner
# guarding this repository refuses the edit — correctly. A test fixture must
# not require weakening the thing under test.
# The setting is an orchestration.config key, and the config is sourced AFTER
# the environment — so an env-var override is NOT the production path and a
# test that used one would be testing something the shipped hook never does.
# Two real roots instead, one per setting.
ca_mkroot() { # <value>
    local d; d="$(mktemp -d -t scan-secrets-codeaware)"
    mkdir -p "$d/scripts/hooks" "$d/scripts/lib"
    cp "$HOOK" "$d/scripts/hooks/scan-secrets.sh"; chmod +x "$d/scripts/hooks/scan-secrets.sh"
    cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$d/scripts/lib/"
    printf 'SECRET_SCAN_CODE_AWARE=%s\n' "$1" >"$d/orchestration.config"
    printf '%s' "$d"
}
CA_ROOT_OFF="$(ca_mkroot 0)"
CA_ROOT_ON="$(ca_mkroot 1)"

ca_case() { # <name> <want-default> <want-code-aware> <content>
    local name="$1" want_def="$2" want_ca="$3" content="$4" j rc_def rc_ca
    j="$(json_write Write content "$content")"
    printf '%s' "$j" | RICHOS_ENTITY_ROOT="$CA_ROOT_OFF" "$CA_ROOT_OFF/scripts/hooks/scan-secrets.sh" >/dev/null 2>&1; rc_def=$?
    printf '%s' "$j" | RICHOS_ENTITY_ROOT="$CA_ROOT_ON"  "$CA_ROOT_ON/scripts/hooks/scan-secrets.sh"  >/dev/null 2>&1; rc_ca=$?
    if [ "$rc_def" -eq "$want_def" ] && [ "$rc_ca" -eq "$want_ca" ]; then
        printf '  PASS  code-aware: %s (default=%s, opt-in=%s)\n' "$name" "$rc_def" "$rc_ca"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  code-aware: %s (default want %s got %s; opt-in want %s got %s)\n' \
            "$name" "$want_def" "$rc_def" "$want_ca" "$rc_ca"
        FAIL=$((FAIL + 1))
    fi
}

# The precision the setting buys: code shapes stop being flagged.
ca_case "type annotation"        2 0 'let token: NSObjectProtocol? = nil'
ca_case "dotted member path"     2 0 'api_key = config.credentials.apiKey'
ca_case "call expression"        2 0 'secret = getSecret(fromKeychain)'
ca_case "descriptive fixture"    2 0 'password = "BEARER_PROTOCOL_FUTURE_TOKEN"'
ca_case "hyphenated descriptive" 2 0 'token = "verification-token-alpha"'

# The price, stated rather than hidden. These are the shapes the opt-in also
# waves through. A reviewer reading this suite sees the trade in the same place
# as the benefit.
ca_case "COST: all-alpha passphrase"  2 0 'password = "correcthorsebatterystaple"'
ca_case "COST: all-digit long value"  2 0 'secret = "839201748392017483920174"'

# What the opt-in must NEVER touch. If any of these flipped, the setting would
# be a hole, not a filter.
CA_DENSE="$(printf 'aZ3k%sLm7P%s' 'Q9x2' 'w5Rv8Nt1')"
CA_B64="$(printf 'dGhpc2lz%s%s' 'YXNlY3Jl' 'dDEyMw')"
CA_VENDOR="$(printf 'A%s%s' 'KIA' 'IOSFODNN7EXAMPLZ')"
ca_case "dense mixed token still blocked" 2 2 "token = \"$CA_DENSE\""
ca_case "base64-ish still blocked"        2 2 "secret = \"$CA_B64\""
ca_case "vendor-prefix key still blocked" 2 2 "$CA_VENDOR"

# The default with the key ABSENT altogether must equal the key set to 0 —
# otherwise "default OFF" would be a claim about a config file rather than
# about the hook, and an adopter with no such line would get a surprise.
CA_ROOT_UNSET="$(ca_mkroot 0)"; : >"$CA_ROOT_UNSET/orchestration.config"
printf '%s' "$(json_write Write content 'password = "BEARER_PROTOCOL_FUTURE_TOKEN"')" \
  | RICHOS_ENTITY_ROOT="$CA_ROOT_UNSET" "$CA_ROOT_UNSET/scripts/hooks/scan-secrets.sh" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    PASS=$((PASS + 1)); printf '  PASS  code-aware: key ABSENT behaves as OFF\n'
else
    FAIL=$((FAIL + 1)); printf '  FAIL  code-aware: key ABSENT did not behave as OFF (rc=%s)\n' "$rc"
fi
rm -rf "$CA_ROOT_OFF" "$CA_ROOT_ON" "$CA_ROOT_UNSET"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== scan-secrets tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== scan-secrets tests: all $PASS passed ==="
    exit 0
fi
