#!/usr/bin/env bash
#
# ci-status.test.sh — the one-line CI sentence never claims more than was read.
#
# P5-40: `--axis red --sentence` counted only the red axis but said "all six
# axes", hiding a slow FINDING; and a reading with blind spots or API failures
# said "CI is clear" on the line a script quotes, admitting the blindness only in
# an exit code. ci-status.sh is run against a stub surface so each document is a
# fixture and nothing reads GitHub.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -4; FAIL=$((FAIL + 1)); }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ci-status-test.XXXXXX")" || exit 2
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/scripts/lib"
cp "$HERE/ci-status.sh" "$SANDBOX/scripts/ci-status.sh"
cat > "$SANDBOX/scripts/lib/ci-surface.py" <<'PY'
import os, sys
sys.stdout.write(open(os.environ["CI_FIXTURE"], encoding="utf-8").read())
PY

mkdoc() { # <file> <slow verdict> <blind count> <api failure count>
    python3 - "$@" <<'PY'
import json, sys
path, slow, nblind, nfail = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
axes = {a: {"verdict": "OK", "detail": "fine"} for a in ["slow", "red", "skipped", "never-run", "stale", "hollow"]}
axes["slow"] = {"verdict": slow, "detail": "takes too long"}
doc = {"generated_at": "2026-09-30T00:00:00Z", "branch": "main",
       "counts": {"repositories": 1, "workflows": 1},
       "workflows": [{"repo": "r", "workflow": "w", "state": "active", "axes": axes}],
       "blind": ["blind spot %d" % i for i in range(nblind)],
       "api": {"calls": 1, "cache_hits": 0, "failures": ["boom"] * nfail},
       "paused_repositories": [], "repositories": []}
json.dump(doc, open(path, "w"))
PY
}

run() { # <fixture> args... ; sets OUT and RC
    local fx="$1"; shift
    OUT="$(CI_FIXTURE="$fx" bash "$SANDBOX/scripts/ci-status.sh" "$@" 2>/dev/null)"; RC=$?
}

mkdoc "$SANDBOX/clean.json" OK 0 0
mkdoc "$SANDBOX/slow.json" FINDING 0 0
mkdoc "$SANDBOX/blind.json" OK 2 0
mkdoc "$SANDBOX/apifail.json" OK 0 1

run "$SANDBOX/clean.json" --sentence
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^CI is clear on all six axes'; then
    ok "1  a whole clean reading is clear on all six axes, exit 0"
else bad "1  a whole clean reading" "rc=$RC out=$OUT"; fi

run "$SANDBOX/slow.json" --axis red --sentence
if printf '%s' "$OUT" | grep -q 'all six axes'; then
    bad "2  --axis red must not claim all six axes" "$OUT"
elif printf '%s' "$OUT" | grep -q 'red axis only'; then
    ok "2  --axis red --sentence names the one axis it read"
else bad "2  --axis red --sentence does not name its coverage" "$OUT"; fi

run "$SANDBOX/blind.json" --sentence
if [ "$RC" = 3 ] && ! printf '%s' "$OUT" | grep -q '^CI is clear' && printf '%s' "$OUT" | grep -q 'NOT confirmed clear'; then
    ok "3  a blind reading never says CI is clear (and still exits 3)"
else bad "3  a blind reading" "rc=$RC out=$OUT"; fi

run "$SANDBOX/apifail.json" --sentence
if [ "$RC" = 3 ] && ! printf '%s' "$OUT" | grep -q '^CI is clear' && printf '%s' "$OUT" | grep -q '1 API failure'; then
    ok "4  API failures never say CI is clear (and still exit 3)"
else bad "4  API failures" "rc=$RC out=$OUT"; fi

run "$SANDBOX/slow.json" --sentence
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'NOT clear'; then
    ok "5  a real finding on the full reading is still NOT clear, exit 1"
else bad "5  finding on full reading" "rc=$RC out=$OUT"; fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
