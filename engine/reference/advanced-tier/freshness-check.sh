#!/bin/bash
#
# ============================================================================
# REFERENCE EXAMPLE — advanced "identity-or-refuse" tier. NOT wired into the
# engine's mechanical layer. This script came from a real Convex + native-mobile
# project; product identifiers were genericized to placeholders (example /
# legacyapp) and any test credential replaced with <TEST_PASSWORD>. It is
# illustrative, not runnable as-is — adapt it to your own deploy/device
# pipeline. See reference/advanced-tier/README.md.
# ============================================================================
#
#
# scripts/freshness-check.sh — universal build-identity verifier.
#
# The consumer half of the Freshness Contract (docs/freshness-contract.md).
# Every artifact that exists on disk, on a server, or on a device has a commit
# SHA baked INSIDE it. This script asks each layer "what SHA are you?" and
# compares against the expected SHA. Identity or refuse.
#
# Usage:
#   scripts/freshness-check.sh [expected-sha] [--tree=example|legacyapp] [--layers=<list>] [--with-data-contract]
#
# Arguments:
#   expected-sha   12-char commit hash every layer MUST report. Defaults to
#                  the SHA of main in the current repo (git).
#
# Flags:
#   --tree=<name>  example (default) or legacyapp. Picks which web + Convex endpoints
#                  to hit.
#   --layers=<csv> Restrict to a subset of layers. Known layers:
#                    git, default-wc, current-wc, web, convex, data, android,
#                    ios, android-seal, ios-seal
#                  Default: git,default-wc,web,convex,data
#                  (Device layers are opt-in — they require a connected device.)
#                  current-wc is ALSO opt-in: it verifies the CURRENT checkout
#                  (which may be a linked worktree) is clean and its own HEAD
#                  resolves to the expected SHA — no refs/heads/main requirement,
#                  unlike default-wc. Use it for worktree build-verification.
#   --with-data-contract
#                  Append `android-seal` + `ios-seal` to the default layer list.
#                  Adds the Client Data-Render Contract seal-validity gate
#                  (docs/client-data-contract.md §7) for BOTH platforms. Seals
#                  are populated by scripts/{android,ios}-install-fresh.sh and
#                  validated by scripts/client-data-seal-verify.sh. An invalid
#                  or missing seal hard-fails the check with exit 2.
#
# The `data` layer verifies the deployed backend has complete test data for
# the canonical test user by calling the Convex query dataFreshnessProbe:verify.
# It is not about code identity — it is the companion contract that guarantees
# seeded rows exist (for today) so Home renders real values instead of zeros.
#
# Exit codes:
#   0  all checked layers matched the expected SHA
#   1  script error / usage error
#   2  one or more layers FAILED (observed SHA ≠ expected)
#   3  one or more layers were SKIPPED because the producer endpoint/script does
#      not exist yet (graceful degradation during rollout). No hard failures.
#
# Output: one line per layer:
#   ✓ <layer>: <observed> (matches expected)
#   ✗ <layer>: FAIL — expected <X>, got <Y>
#   ⊘ <layer>: SKIPPED — <reason>
#
set -uo pipefail

# Fail-closed, not fail-open: this "identity-or-refuse" verifier depends on
# python3 for JSON field extraction throughout (jq is preferred where present,
# but every fallback path is python3). If python3 is absent, several call
# sites below are `|| true`-guarded and would silently degrade to an empty/
# unverified value — exactly the "it looks fresh" failure mode this script
# exists to prevent. Refuse outright instead of reporting a false pass.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: freshness-check.sh: python3 is required for JSON field extraction — refusing (fail-closed)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The default-wc layer always targets the TRUE main checkout — the ONE shared
# checkout Rich's land sequence and every QA agent implicitly trust — NOT
# whichever linked worktree this script's own copy happens to be invoked from.
# resolve_main_checkout() returns the same value as REPO_ROOT when run from the
# main checkout (byte-identical behavior for existing callers) but correctly
# resolves to the main checkout when this script's copy runs from a worktree.
# The new (opt-in) current-wc layer below deliberately uses REPO_ROOT instead
# (the checkout under test, which MAY legitimately be a worktree) — see
# check_current_wc. Spec: docs/freshness-contract.md and
# docs/briefs/reed-brief-installfresh-worktree-2026-07-14.md §4.
# shellcheck source=lib/resolve-main-checkout.sh
_RMC_LIB="$SCRIPT_DIR/lib/resolve-main-checkout.sh"
if [ ! -f "$_RMC_LIB" ]; then
    echo "ERROR: missing helper $_RMC_LIB — cannot resolve main checkout" >&2
    exit 1
fi
. "$_RMC_LIB"
DEFAULT_WC_ROOT="$(resolve_main_checkout "$SCRIPT_DIR" "$REPO_ROOT")"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

EXPECTED=""
TREE="example"
LAYERS="git,default-wc,web,convex,data"
WITH_DATA_CONTRACT=0

usage() {
    sed -n '3,35p' "$0"
}

for arg in "$@"; do
    case "$arg" in
    --tree=*) TREE="${arg#--tree=}" ;;
    --layers=*) LAYERS="${arg#--layers=}" ;;
    --with-data-contract) WITH_DATA_CONTRACT=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    --*)
        echo "ERROR: unknown flag: $arg" >&2
        exit 1
        ;;
    *)
        if [ -z "$EXPECTED" ]; then
            EXPECTED="$arg"
        else
            echo "ERROR: unexpected positional arg: $arg" >&2
            exit 1
        fi
        ;;
    esac
done

if [ "$WITH_DATA_CONTRACT" -eq 1 ]; then
    # Append per-platform seal layers. These are checked via
    # scripts/client-data-seal-verify.sh and assert the on-device data
    # contract is green for the platforms QA will test against. See
    # docs/client-data-contract.md §7.
    LAYERS="${LAYERS},android-seal,ios-seal"
fi

if [ "$TREE" != "example" ] && [ "$TREE" != "legacyapp" ]; then
    echo "ERROR: --tree must be example or legacyapp (got: $TREE)" >&2
    exit 1
fi

# Resolve expected SHA from main if not given.
if [ -z "$EXPECTED" ]; then
    EXPECTED="$(cd "$REPO_ROOT" && git rev-parse --short=12 main 2>/dev/null || true)"
fi

if [ -z "$EXPECTED" ]; then
    echo "ERROR: could not resolve expected SHA. Pass one explicitly:" >&2
    echo "       scripts/freshness-check.sh <12-char-sha>" >&2
    exit 1
fi

# Normalize: take first 12 chars, lowercase.
EXPECTED="$(printf '%s' "$EXPECTED" | tr 'A-Z' 'a-z' | cut -c1-12)"
if [ "${#EXPECTED}" -ne 12 ]; then
    echo "ERROR: expected SHA must be 12 chars (got ${#EXPECTED}: '$EXPECTED')" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_DIM=""
    C_RESET=""
fi

FAILURES=0
SKIPS=0
PASSES=0

pass() {
    local layer="$1" observed="$2"
    printf "  %s✓%s %s: %s %s(matches expected)%s\n" \
        "$C_GREEN" "$C_RESET" "$layer" "$observed" "$C_DIM" "$C_RESET"
    PASSES=$((PASSES + 1))
}

fail() {
    local layer="$1" observed="$2"
    printf "  %s✗%s %s: FAIL — expected %s, got %s\n" \
        "$C_RED" "$C_RESET" "$layer" "$EXPECTED" "$observed"
    FAILURES=$((FAILURES + 1))
}

skip() {
    local layer="$1" reason="$2"
    printf "  %s⊘%s %s: SKIPPED — %s\n" \
        "$C_YELLOW" "$C_RESET" "$layer" "$reason"
    SKIPS=$((SKIPS + 1))
}

# Normalize any SHA string to 12 lowercase chars (or empty).
normalize_sha() {
    printf '%s' "$1" | tr -d '[:space:]' | tr 'A-Z' 'a-z' | cut -c1-12
}

# Compare and emit pass/fail.
compare() {
    local layer="$1" observed="$2"
    observed="$(normalize_sha "$observed")"
    if [ -z "$observed" ]; then
        fail "$layer" "<empty>"
        return
    fi
    if [ "$observed" = "$EXPECTED" ]; then
        pass "$layer" "$observed"
    else
        fail "$layer" "$observed"
    fi
}

# Extract a JSON field with jq if available, python3 fallback otherwise.
json_field() {
    local file="$1" key="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // empty' <"$file" 2>/dev/null || true
    else
        python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    v = d.get('$key', '')
    print(v if v is not None else '')
except Exception:
    pass
" 2>/dev/null || true
    fi
}

# Return 0 if the CSV list $1 contains token $2.
layer_enabled() {
    case ",$LAYERS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Layer implementations
# ---------------------------------------------------------------------------

check_git() {
    echo "${C_DIM}→ git rev-parse --short=12 main (in $DEFAULT_WC_ROOT)${C_RESET}"
    if ! command -v git >/dev/null 2>&1; then
        skip "git" "git not installed"
        return
    fi
    local observed
    observed="$(cd "$DEFAULT_WC_ROOT" && git rev-parse --short=12 main 2>/dev/null || true)"
    if [ -z "$observed" ]; then
        skip "git" "git could not resolve main"
        return
    fi
    compare "git" "$observed"
}

check_default_wc() {
    echo "${C_DIM}→ git status --short && git symbolic-ref HEAD (main checkout)${C_RESET}"
    if ! command -v git >/dev/null 2>&1; then
        skip "default-wc" "git not installed"
        return
    fi
    local status head
    status="$(cd "$DEFAULT_WC_ROOT" && git status --short 2>/dev/null || true)"
    head="$(cd "$DEFAULT_WC_ROOT" && git symbolic-ref HEAD 2>/dev/null || true)"
    if [ -n "$status" ]; then
        fail "default-wc" "dirty working copy ($(printf '%s' "$status" | wc -l | tr -d ' ') changes)"
        return
    fi
    if [ "$head" != "refs/heads/main" ]; then
        fail "default-wc" "HEAD detached or on wrong branch (${head:-<none>})"
        return
    fi
    pass "default-wc" "clean, HEAD=refs/heads/main"
}

# --- current-wc: the checkout UNDER TEST (may legitimately be a worktree) ---
#
# OPT-IN ONLY (not in the default LAYERS set). Semantics deliberately differ
# from default-wc: current-wc asks "is the checkout that actually produced the
# SHA I'm about to test clean, and does ITS OWN HEAD resolve to EXPECTED?" — it
# does NOT require HEAD to be attached to refs/heads/main, because a worktree's
# HEAD is legitimately on refs/heads/worktree-<id>. This is the layer a
# worktree build-verification run uses; default-wc remains the distinct
# main-checkout / IDE-visibility invariant and is unchanged. See
# docs/freshness-contract.md and
# docs/briefs/reed-brief-installfresh-worktree-2026-07-14.md §4/§6.2.
check_current_wc() {
    echo "${C_DIM}→ git status --short && git rev-parse HEAD (current checkout: $REPO_ROOT)${C_RESET}"
    if ! command -v git >/dev/null 2>&1; then
        skip "current-wc" "git not installed"
        return
    fi
    local status head_sha
    status="$(cd "$REPO_ROOT" && git status --short 2>/dev/null || true)"
    if [ -n "$status" ]; then
        fail "current-wc" "dirty working copy ($(printf '%s\n' "$status" | wc -l | tr -d ' ') changes)"
        return
    fi
    head_sha="$(cd "$REPO_ROOT" && git rev-parse --short=12 HEAD 2>/dev/null || true)"
    if [ -z "$head_sha" ]; then
        fail "current-wc" "could not resolve HEAD"
        return
    fi
    compare "current-wc" "$head_sha"
}

check_web() {
    local host
    case "$TREE" in
    example) host="https://example-web-staging.up.railway.app" ;;
    legacyapp) host="https://legacyapp-web-staging.up.railway.app" ;;
    esac
    local url="$host/api/__version"
    echo "${C_DIM}→ curl -sS $url${C_RESET}"

    if ! command -v curl >/dev/null 2>&1; then
        skip "web" "curl not installed"
        return
    fi

    local body_file headers_file http_code
    body_file="$(mktemp -t freshness-web-body.XXXXXX)"
    headers_file="$(mktemp -t freshness-web-headers.XXXXXX)"
    http_code="$(curl -sS -o "$body_file" -D "$headers_file" \
        -w '%{http_code}' \
        --max-time 10 \
        -H 'Cache-Control: no-cache' \
        "$url" 2>/dev/null || echo "000")"

    if [ "$http_code" = "000" ]; then
        skip "web" "curl error reaching $url"
        rm -f "$body_file" "$headers_file"
        return
    fi
    if [ "$http_code" = "404" ]; then
        skip "web" "/api/__version not deployed yet (HTTP 404)"
        rm -f "$body_file" "$headers_file"
        return
    fi
    if [ "$http_code" != "200" ]; then
        fail "web" "HTTP $http_code from $url"
        rm -f "$body_file" "$headers_file"
        return
    fi

    # Cache-Control must be no-store so we know we aren't looking at CDN mush.
    if ! grep -qi '^cache-control:.*no-store' "$headers_file"; then
        fail "web" "missing Cache-Control: no-store header (CDN-cached?)"
        rm -f "$body_file" "$headers_file"
        return
    fi

    local observed observed_tree
    observed="$(json_field "$body_file" gitSha)"
    observed_tree="$(json_field "$body_file" tree)"
    rm -f "$body_file" "$headers_file"

    if [ -z "$observed" ]; then
        fail "web" "response missing gitSha field"
        return
    fi
    if [ -n "$observed_tree" ] && [ "$observed_tree" != "$TREE" ]; then
        fail "web" "tree mismatch (expected $TREE, got $observed_tree)"
        return
    fi
    compare "web" "$observed"
}

check_convex() {
    echo "${C_DIM}→ ./scripts/convex --tree=$TREE run version:get${C_RESET}"
    if [ ! -x "$SCRIPT_DIR/convex" ]; then
        skip "convex" "scripts/convex wrapper not found"
        return
    fi
    local out
    out="$("$SCRIPT_DIR/convex" --tree="$TREE" run version:get 2>&1 || true)"

    if printf '%s' "$out" | grep -qiE 'could not find|unknown function|not found|no such function|module not found'; then
        skip "convex" "version:get not deployed yet"
        return
    fi
    if [ -z "$out" ]; then
        skip "convex" "empty response from convex wrapper"
        return
    fi

    # scripts/convex prints JSON (possibly with a trailing newline / log preamble).
    # Isolate the JSON object and extract gitSha + tree.
    local json observed observed_tree
    json="$(printf '%s' "$out" | awk '/\{/{flag=1} flag{print} /\}/{flag=0}')"
    if [ -z "$json" ]; then
        skip "convex" "no JSON object in convex response"
        return
    fi
    local tmp
    tmp="$(mktemp -t freshness-convex.XXXXXX)"
    printf '%s' "$json" >"$tmp"
    observed="$(json_field "$tmp" gitSha)"
    observed_tree="$(json_field "$tmp" tree)"
    rm -f "$tmp"

    if [ -z "$observed" ]; then
        fail "convex" "response missing gitSha field"
        return
    fi
    if [ -n "$observed_tree" ] && [ "$observed_tree" != "$TREE" ]; then
        fail "convex" "tree mismatch (expected $TREE, got $observed_tree)"
        return
    fi
    compare "convex" "$observed"
}

data_fail_line() {
    # Emit a "data: FAIL — <reason>" line without routing through the SHA-shaped
    # fail() helper (which would misleadingly print "expected X, got …").
    local reason="$1"
    printf "  %s✗%s data: FAIL — %s\n" "$C_RED" "$C_RESET" "$reason"
    FAILURES=$((FAILURES + 1))
}

check_data() {
    echo "${C_DIM}→ ./scripts/convex --tree=$TREE run dataFreshnessProbe:verify${C_RESET}"
    if [ ! -x "$SCRIPT_DIR/convex" ]; then
        skip "data" "scripts/convex wrapper not found"
        return
    fi

    # Capture stdout and stderr separately. The convex wrapper prints status
    # preamble ("[convex] tree=legacyapp …") to stderr; the function return value
    # is raw JSON on stdout. Merging them corrupts the parser.
    local stdout_file stderr_file rc
    stdout_file="$(mktemp -t freshness-data-out.XXXXXX)"
    stderr_file="$(mktemp -t freshness-data-err.XXXXXX)"
    "$SCRIPT_DIR/convex" --tree="$TREE" run dataFreshnessProbe:verify \
        >"$stdout_file" 2>"$stderr_file"
    rc=$?

    # Missing-function detection checks both streams (convex may print the
    # error on either).
    if grep -qiE 'could not find|unknown function|not found|no such function|module not found' \
        "$stdout_file" "$stderr_file" 2>/dev/null; then
        skip "data" "dataFreshnessProbe:verify not deployed yet (rollout phase — run seedE2E + redeploy to activate)"
        rm -f "$stdout_file" "$stderr_file"
        return
    fi

    if [ "$rc" -ne 0 ] && [ ! -s "$stdout_file" ]; then
        local err_preview
        err_preview="$(head -3 "$stderr_file" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
        data_fail_line "convex wrapper exit=$rc, stderr: ${err_preview:-<empty>}"
        rm -f "$stdout_file" "$stderr_file"
        return
    fi

    if [ ! -s "$stdout_file" ]; then
        data_fail_line "empty stdout from dataFreshnessProbe:verify"
        rm -f "$stdout_file" "$stderr_file"
        return
    fi

    # Parent line.
    printf "  %s→%s data:\n" "$C_DIM" "$C_RESET"

    # Parse with python3's raw_decode — tolerant of leading junk and trailing
    # noise, correctly handles multi-line pretty-printed JSON with nested
    # objects and arrays. Accepts both shapes the convex CLI may emit:
    #   { ok, checks: [...] }                  — raw return value (current)
    #   { "type":"ok", "value": { ok, checks } } — wrapped envelope
    # Emits TSV: <ok>\t<name>\t<detail> per check, plus a trailing
    # "__OVERALL__\t<ok>\t<total>" line for the summary.
    local parsed_file
    parsed_file="$(mktemp -t freshness-data-parsed.XXXXXX)"
    python3 - "$stdout_file" >"$parsed_file" 2>/dev/null <<'PY' || true
import json, sys
try:
    raw = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)

# Find the first '{' and attempt raw_decode from there. If that fails, scan
# forward for subsequent '{' positions — handles any leading non-JSON noise.
start = raw.find("{")
obj = None
dec = json.JSONDecoder()
while start != -1:
    try:
        obj, _end = dec.raw_decode(raw[start:])
        break
    except Exception:
        start = raw.find("{", start + 1)

if obj is None or not isinstance(obj, dict):
    sys.exit(0)

# Unwrap { type: "ok", value: {...} } if present.
if isinstance(obj.get("value"), dict) and ("type" in obj or "ok" not in obj):
    obj = obj["value"]

checks = obj.get("checks")
if not isinstance(checks, list):
    sys.exit(0)

# Per-check lines.
for c in checks:
    if not isinstance(c, dict):
        continue
    ok = "true" if c.get("ok") else "false"
    name = str(c.get("name", ""))
    detail = c.get("detail", "") or ""
    # Tabs inside detail would break TSV; replace with spaces.
    detail = str(detail).replace("\t", " ").replace("\n", " ")
    print("\t".join([ok, name, detail]))

# Overall summary line.
overall_ok = "true" if obj.get("ok") else "false"
print("\t".join(["__OVERALL__", overall_ok, str(len(checks))]))
PY

    if [ ! -s "$parsed_file" ]; then
        # Surface a snippet of stdout so debugging doesn't require guesswork.
        local preview
        preview="$(head -c 200 "$stdout_file" | tr '\n' ' ')"
        data_fail_line "could not parse JSON from dataFreshnessProbe (stdout head: ${preview})"
        rm -f "$stdout_file" "$stderr_file" "$parsed_file"
        return
    fi

    # Walk the parsed output: per-check lines, then the __OVERALL__ sentinel.
    local total=0 data_pass=0 data_fail=0 overall_ok="false"
    local col1 col2 col3
    while IFS=$'\t' read -r col1 col2 col3; do
        if [ "$col1" = "__OVERALL__" ]; then
            overall_ok="$col2"
            continue
        fi
        total=$((total + 1))
        if [ "$col1" = "true" ]; then
            printf "    %s✓%s %s\n" "$C_GREEN" "$C_RESET" "$col2"
            data_pass=$((data_pass + 1))
        else
            printf "    %s✗%s %s: %s\n" "$C_RED" "$C_RESET" "$col2" "${col3:-<no detail>}"
            data_fail=$((data_fail + 1))
        fi
    done <"$parsed_file"
    rm -f "$stdout_file" "$stderr_file" "$parsed_file"

    if [ "$total" -eq 0 ]; then
        data_fail_line "dataFreshnessProbe response had no checks array"
        return
    fi

    if [ "$overall_ok" = "true" ] && [ "$data_fail" -eq 0 ]; then
        printf "  %s✓%s data: %d/%d checks %s(all green)%s\n" \
            "$C_GREEN" "$C_RESET" "$data_pass" "$total" "$C_DIM" "$C_RESET"
        PASSES=$((PASSES + 1))
    else
        printf "  %s✗%s data: %d/%d checks failed\n" \
            "$C_RED" "$C_RESET" "$data_fail" "$total"
        FAILURES=$((FAILURES + 1))
    fi
}

check_android() {
    local helper="$SCRIPT_DIR/android-install-fresh.sh"
    echo "${C_DIM}→ $helper $EXPECTED${C_RESET}"
    if [ ! -x "$helper" ]; then
        skip "android" "scripts/android-install-fresh.sh not present yet"
        return
    fi
    "$helper" "$EXPECTED"
    local rc=$?
    case "$rc" in
    0) pass "android" "device reports $EXPECTED" ;;
    2) fail "android" "device SHA mismatch (install-fresh returned 2)" ;;
    3) skip "android" "no BUILD_SHA stamp on device (install-fresh returned 3)" ;;
    *) fail "android" "install-fresh returned unexpected exit $rc" ;;
    esac
}

check_ios() {
    local helper="$SCRIPT_DIR/ios-install-fresh.sh"
    echo "${C_DIM}→ $helper $EXPECTED${C_RESET}"
    if [ ! -x "$helper" ]; then
        skip "ios" "scripts/ios-install-fresh.sh not present yet"
        return
    fi
    "$helper" "$EXPECTED"
    local rc=$?
    case "$rc" in
    0) pass "ios" "device reports $EXPECTED" ;;
    2) fail "ios" "device SHA mismatch (install-fresh returned 2)" ;;
    3) skip "ios" "no GIT_SHA stamp on device (install-fresh returned 3)" ;;
    *) fail "ios" "install-fresh returned unexpected exit $rc" ;;
    esac
}

# Client Data-Render Contract seal layers — per-platform. Checked via
# scripts/client-data-seal-verify.sh; docs/client-data-contract.md §7.
check_seal() {
    local platform="$1"
    local helper="$SCRIPT_DIR/client-data-seal-verify.sh"
    echo "${C_DIM}→ $helper $platform${C_RESET}"
    if [ ! -x "$helper" ]; then
        skip "${platform}-seal" "scripts/client-data-seal-verify.sh not present yet"
        return
    fi
    local out rc
    out="$("$helper" "$platform" 2>&1)"
    rc=$?
    case "$rc" in
    0)
        printf "  %s✓%s %s-seal: valid %s(%s)%s\n" \
            "$C_GREEN" "$C_RESET" "$platform" "$C_DIM" \
            "$(printf '%s' "$out" | head -1)" "$C_RESET"
        PASSES=$((PASSES + 1))
        ;;
    2)
        printf "  %s✗%s %s-seal: INVALID — %s\n" \
            "$C_RED" "$C_RESET" "$platform" \
            "$(printf '%s' "$out" | head -1)"
        FAILURES=$((FAILURES + 1))
        ;;
    *)
        printf "  %s✗%s %s-seal: unexpected exit %d\n" \
            "$C_RED" "$C_RESET" "$platform" "$rc"
        FAILURES=$((FAILURES + 1))
        ;;
    esac
}
check_android_seal() { check_seal android; }
check_ios_seal()     { check_seal ios; }

# ---------------------------------------------------------------------------
# Drive it
# ---------------------------------------------------------------------------

echo "Freshness check: expected=$EXPECTED tree=$TREE layers=$LAYERS"
echo ""

IFS=',' read -r -a LAYER_ARR <<<"$LAYERS"
for layer in "${LAYER_ARR[@]}"; do
    case "$layer" in
    jj)
        echo "⊘ jj: layer retired 2026-07-07 (repo migrated to plain git) — ignoring"
        ;;
    git) check_git ;;
    default-wc) check_default_wc ;;
    current-wc) check_current_wc ;;
    web) check_web ;;
    convex) check_convex ;;
    data) check_data ;;
    android) check_android ;;
    ios) check_ios ;;
    android-seal) check_android_seal ;;
    ios-seal) check_ios_seal ;;
    "") ;;
    *)
        echo "ERROR: unknown layer: $layer" >&2
        exit 1
        ;;
    esac
done

echo ""
echo "Summary: ${PASSES} pass, ${FAILURES} fail, ${SKIPS} skipped"

if [ "$FAILURES" -gt 0 ]; then
    exit 2
fi
if [ "$SKIPS" -gt 0 ]; then
    # Partial pass — some producers haven't landed yet. Deploy scripts treat
    # this as a warning during rollout.
    exit 3
fi
exit 0
