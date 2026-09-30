#!/usr/bin/env bash
#
# ci-red.test.sh — the CI red watcher must not let a SKIPPED latest run erase an
# unrepaired failure. It runs the real lib/ci-red.py against a stand-in `gh`.
#
#   D1  latest run failed -> red (the control).
#   D2  latest run succeeded, older run failed -> clear (a repaired failure).
#   D3  latest run SKIPPED, the run before it FAILED, no success since -> still
#       red, naming the failed run. (Hunt P5-10: the skipped run was taken as the
#       workflow's latest verdict and the report said clear.)
#   D4  latest run SKIPPED, the run before it SUCCEEDED -> clear.
#   D5  a workflow with only skipped runs is not red.
#
# CI_RED names another copy of ci-red.py that sits beside its ci_pause.py (used
# to show D3 fails before the fix).
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_RED="${CI_RED:-$SCRIPT_DIR/lib/ci-red.py}"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-red-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

mkdir -p "$SANDBOX/bin" "$SANDBOX/home"
cat > "$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env bash
cat "$GH_FIXTURE"
GH
chmod +x "$SANDBOX/bin/gh"

# runs_json <conclusion newest> [<conclusion> ...]  — one workflow, newest first
runs_json() {
    python3 - "$@" <<'PY'
import json, sys
runs = []
n = len(sys.argv) - 1
for i, c in enumerate(sys.argv[1:]):
    runs.append({"workflow_id": 7, "name": "verify", "path": ".github/workflows/verify.yml",
                 "status": "completed", "conclusion": c, "run_number": n - i,
                 "run_started_at": "2026-09-01T00:00:00Z", "html_url": "https://example.invalid/%d" % (n - i)})
print(json.dumps({"workflow_runs": runs}))
PY
}

# verdict <conclusions newest first...> -> STATE (clear|red), OUT
verdict() {
    runs_json "$@" > "$SANDBOX/fixture.json"
    rm -rf "$SANDBOX/home/.claude"
    OUT="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" GH_FIXTURE="$SANDBOX/fixture.json" \
           python3 "$CI_RED" --repo example/repo --refresh --json 2>&1)"
    STATE="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])' <<<"$OUT" 2>/dev/null || echo "unparseable")"
}

verdict failure success
if [ "$STATE" = red ]; then ok "D1  a failed latest run is red"; else bad "D1  state=$STATE: $OUT"; fi

verdict success failure
if [ "$STATE" = clear ]; then ok "D2  a repaired failure is clear"; else bad "D2  state=$STATE: $OUT"; fi

verdict skipped failure success
if [ "$STATE" = red ] && grep -q '"run_number": 2' <<<"$OUT"; then ok "D3  a skipped latest run does not erase the unrepaired failure"; else bad "D3  state=$STATE: $OUT"; fi

verdict skipped success failure
if [ "$STATE" = clear ]; then ok "D4  a skipped run over a success is clear"; else bad "D4  state=$STATE: $OUT"; fi

verdict skipped skipped
if [ "$STATE" = clear ]; then ok "D5  only skipped runs is not red"; else bad "D5  state=$STATE: $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
