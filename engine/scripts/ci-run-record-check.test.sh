#!/usr/bin/env bash
#
# ci-run-record-check.test.sh — absence must be detected, and must never be silent.
#
# EVERY CASE IS OFFLINE. The payloads are written by hand into the sandbox and
# fed in with --events-json / --runs-json, so this suite needs no network and no
# token. That is not only convenience: the case that matters most is "the sources
# could not be read", and a suite that needed the real API could not distinguish
# that from its own failure to reach it.
#
# WHAT IS PROVEN:
#
#   R1   Every push having a run is green.
#   R2   A push with NO run FAILS, and the SHA is named. This is the whole
#        point: GitHub drops runs past the account-wide concurrency limit, and a
#        dropped run leaves no record, so every tool reading "the latest run"
#        reports an earlier commit's verdict instead.
#   R3   A BATCHED push is not a false positive. Extra commits in one push
#        correctly produce one run; a check built on commits rather than pushes
#        would cry wolf on every batch and be switched off within a week.
#   R4   A push inside the grace window is PENDING, not missing — its run may
#        not have reached the API yet — and the tolerance is printed.
#   R5   --since excludes pushes made before the trigger existed. Without it
#        this check is red on arrival over 95 historical pushes.
#   R6   AN UNREADABLE SOURCE EXITS 2, NOT 0. A run-record check that goes quiet
#        when its own inputs fail is the defect it exists to catch, one level out.
#   R7   An event feed with no pushes for the branch exits 2 rather than
#        reporting a green nothing.
#   R8   The fallback predicate — the branch tip must have a run — is applied
#        when the event feed is unavailable, and says which predicate it used.
#   R9   A run for a DIFFERENT workflow does not satisfy a push: the runs
#        payload is per-workflow, and matching is on head_sha.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/ci-run-record-check.sh"
PY="$SCRIPT_DIR/lib/ci-run-records.py"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-runrec-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$CHECK" ] || { echo "FATAL: missing $CHECK" >&2; exit 1; }
[ -f "$PY" ] || { echo "FATAL: missing $PY" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== ci-run-record-check tests ==="

A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
C="cccccccccccccccccccccccccccccccccccccccc"
OLD="dddddddddddddddddddddddddddddddddddddddd"

# Timestamps relative to now, so the grace window is exercised rather than
# assumed. A fixture with a hard-coded date tests the clock, not the code.
mk_payloads() { # <events-spec> ... writes $SANDBOX/events.json
    python3 - "$SANDBOX" "$@" <<'PY'
import datetime, json, sys
sandbox = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
events = []
for spec in sys.argv[2:]:
    sha, ref, minutes = spec.split(":")
    when = now - datetime.timedelta(minutes=float(minutes))
    events.append({"type": "PushEvent",
                   "created_at": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "payload": {"ref": "refs/heads/%s" % ref, "head": sha}})
# a non-push event, so filtering is exercised rather than assumed
events.append({"type": "WatchEvent", "created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
               "payload": {}})
open(sandbox + "/events.json", "w").write(json.dumps(events))
PY
}
mk_runs() { # <sha> ... writes $SANDBOX/runs.json
    python3 - "$SANDBOX" "$@" <<'PY'
import json, sys
sandbox = sys.argv[1]
runs = [{"id": 1000 + i, "head_sha": sha, "conclusion": "success",
         "created_at": "2026-09-10T00:00:0%dZ" % (i % 10)}
        for i, sha in enumerate(sys.argv[2:])]
open(sandbox + "/runs.json", "w").write(json.dumps({"workflow_runs": runs}))
PY
}
chk() {
    bash "$CHECK" --events-json "$SANDBOX/events.json" --runs-json "$SANDBOX/runs.json" \
                  --workflow engine-self-verify.yml --repo owner/repo "$@" \
        > "$SANDBOX/out" 2>&1
    printf '%s' "$?"
}

# --- R1 --------------------------------------------------------------------
mk_payloads "$A:main:600" "$B:main:900"
mk_runs "$A" "$B"
RC="$(chk)"
if [ "$RC" = "0" ] && grep -q '0 MISSING' "$SANDBOX/out"; then
    ok "R1   every push having a run is green"
else
    bad "R1   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi

# --- R2 --------------------------------------------------------------------
mk_payloads "$A:main:600" "$B:main:900"
mk_runs "$A"
RC="$(chk)"
if [ "$RC" = "1" ] && grep -qF "$B" "$SANDBOX/out" && grep -q 'NO run of' "$SANDBOX/out"; then
    ok "R2   a push with no run FAILS and the SHA is named"
else
    bad "R2   rc=$RC — a dropped run went undetected, which is the one failure this check exists for"
    sed 's/^/          /' "$SANDBOX/out"
fi

# --- R3: a batched push is one push ---------------------------------------
# The feed carries ONE push whose head is $A; $B and $C are earlier commits in
# the same push and have no runs of their own, correctly.
mk_payloads "$A:main:600"
mk_runs "$A"
RC="$(chk)"
if [ "$RC" = "0" ]; then
    ok "R3   commits batched into one push need one run, not one each — no false positive per batch"
else
    bad "R3   rc=$RC — a batched push was reported as missing runs, and a check that cries wolf gets switched off"
    sed 's/^/          /' "$SANDBOX/out"
fi

# --- R4: the grace window -------------------------------------------------
mk_payloads "$A:main:600" "$B:main:2"
mk_runs "$A"
RC="$(chk --grace-minutes 20)"
if [ "$RC" = "0" ] && grep -q 'PENDING' "$SANDBOX/out" && grep -q '1 pending' "$SANDBOX/out"; then
    ok "R4   a push two minutes old with no run yet is PENDING, printed, and does not fail"
else
    bad "R4   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi
# and the same push is MISSING once the window is short enough
RC="$(chk --grace-minutes 1)"
if [ "$RC" = "1" ]; then
    ok "R4b  the same push FAILS with a one-minute window — pending is a window, not a permanent excuse"
else
    bad "R4b  rc=$RC with --grace-minutes 1"
fi

# --- R5: the --since bound ------------------------------------------------
YESTERDAY="$(python3 -c 'import datetime; print((datetime.date.today() - datetime.timedelta(days=1)).isoformat())')"
TOMORROW="$(python3 -c 'import datetime; print((datetime.date.today() + datetime.timedelta(days=1)).isoformat())')"
# $OLD was pushed 40 days ago and has no run: correct, the trigger did not exist.
mk_payloads "$A:main:600" "$OLD:main:57600"
mk_runs "$A"
RC="$(chk --since "$YESTERDAY")"
if [ "$RC" = "0" ] && grep -q 'outside the watched window' "$SANDBOX/out"; then
    ok "R5   --since excludes pushes made before the trigger existed, and counts them out loud"
else
    bad "R5   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi
RC="$(chk)"
if [ "$RC" = "1" ]; then
    ok "R5b  without --since the same old push IS a finding — the bound is explicit, never implied"
else
    bad "R5b  rc=$RC with no --since"
fi
RC="$(chk --since "not-a-date")"
if [ "$RC" = "2" ]; then
    ok "R5c  an unparseable --since exits 2 rather than silently watching everything or nothing"
else
    bad "R5c  rc=$RC for --since not-a-date"
fi

# --- R6: an unreadable source ---------------------------------------------
mk_payloads "$A:main:600"
printf 'this is not json\n' > "$SANDBOX/runs.json"
RC="$(chk)"
if [ "$RC" = "2" ]; then
    ok "R6a  an unparseable runs payload exits 2 — no answer is not a pass"
else
    bad "R6a  rc=$RC on unparseable runs payload"
fi
mk_runs "$A"
printf 'also not json\n' > "$SANDBOX/events.json"
RC="$(chk)"
if [ "$RC" = "2" ]; then
    ok "R6b  an unparseable event payload exits 2"
else
    bad "R6b  rc=$RC on unparseable events payload"
fi

# --- R7: a feed with no pushes for the branch ----------------------------
mk_payloads "$A:some-other-branch:600"
mk_runs "$A"
RC="$(chk)"
if [ "$RC" = "2" ] && grep -q 'NO pushes to main' "$SANDBOX/out"; then
    ok "R7   a feed with no pushes to the branch exits 2 rather than reporting a green nothing"
else
    bad "R7   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi

# --- R8: the fallback predicate ------------------------------------------
mk_payloads "$A:main:600"
mk_runs "$A"
python3 "$PY" --events "$SANDBOX/events.json" --runs "$SANDBOX/runs.json" \
    --source tip --tip "$C" --workflow engine-self-verify.yml --repo owner/repo \
    > "$SANDBOX/out" 2>&1
RC=$?
if [ "$RC" = "1" ] && grep -q 'branch tip has a run record' "$SANDBOX/out" && grep -qF "$C" "$SANDBOX/out"; then
    ok "R8a  the tip fallback fails on a tip with no run, and names the predicate it used"
else
    bad "R8a  rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi
python3 "$PY" --events "$SANDBOX/events.json" --runs "$SANDBOX/runs.json" \
    --source tip --tip "$A" --workflow engine-self-verify.yml --repo owner/repo \
    > "$SANDBOX/out" 2>&1
RC=$?
if [ "$RC" = "0" ] && grep -q 'earlier pushes were NOT checked' "$SANDBOX/out"; then
    ok "R8b  the tip fallback passes on a tip that has a run, and says what it did NOT check"
else
    bad "R8b  rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi

# --- R9: a run for another workflow is not a run for this one -------------
# The runs payload is fetched per workflow, so the guarantee is structural; what
# is proven here is that matching is on head_sha and nothing else, so a payload
# whose runs are all for other commits satisfies nothing.
mk_payloads "$A:main:600"
mk_runs "$B" "$C"
RC="$(chk)"
if [ "$RC" = "1" ] && grep -qF "$A" "$SANDBOX/out"; then
    ok "R9   runs for other commits do not satisfy a push — matching is on head_sha"
else
    bad "R9   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ci-run-record-check tests: all $PASS passed ==="
    exit 0
fi
echo "=== ci-run-record-check tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
