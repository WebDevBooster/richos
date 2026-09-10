#!/usr/bin/env bash
#
# ci-surface-watch.test.sh — the scheduled pass must be able to say it FAILED.
#
# ===========================================================================
# WHAT THIS SUITE IS ACTUALLY FOR
# ===========================================================================
# It is easy to write a scheduled job that reports success. The reconciler this
# one is modeled against does it every day at 04:00 and reclaims nothing. So
# the interesting cases here are not "does a good pass say effective" — that is
# one case, W1, and it is the least informative one. The rest all ask the same
# question from different directions:
#
#     CAN THIS JOB TELL THE DIFFERENCE BETWEEN WORKING AND MERELY RUNNING?
#
# Every case below breaks the pass in a specific way and asserts that the
# verdict line says so. A suite that only proved the happy path would leave the
# job free to degrade into the exact thing it was built not to be.
#
#   W1  a healthy pass says `effective`, exits 0, and writes a verdict line.
#   W2  a BROKEN CLASSIFIER stops the pass with `ineffective`, and NO report is
#       filed. A reassuring report built on a judge known to be broken is worse
#       than no report, because somebody will read it.
#   W3  a NEGATIVE CONTROL THAT COMES BACK CLEAN is `ineffective`. This is the
#       case that catches a reader which has stopped reading: shown a workflow
#       that is red, undeclared on every axis and carrying an undeclared skip,
#       it must find something.
#   W4  COVERAGE SHRINKING is `degraded`, even though every other signal is
#       healthy. A smaller inventory reports fewer problems and fewer problems
#       reads like progress.
#   W5  an EMPTY CORPUS is `ineffective`. Zero workflows is the one result that
#       can never be reassuring, and it is what every scanner in this project's
#       history reported clean over.
#   W6  BLIND SPOTS or API FAILURES are `degraded` — part of the surface was
#       not read, which is not the same as read and clear.
#   W7  the verdict line is appended on EVERY path, including the failing ones.
#       A pass that dies without a verdict is indistinguishable from a pass
#       that never fired.
#   W8  the high-water mark RATCHETS UP after a larger pass, so tomorrow's
#       shrink is measured against the best ever seen and not against
#       yesterday.
#   W9  A TIMED-OUT CALL CAN NEVER PRODUCE A CLEAR VERDICT — proven against the
#       REAL reader with `gh` replaced by a GitHub that never answers, because
#       this is a property of the reader the watch runs, not of the watch's
#       arithmetic over a document.
#   W10 THE PASS LEAVES THE CACHE WARM and NAMES its cache mode. It used to run
#       `--no-cache` — neither reading nor writing — which reported
#       `cache_hits: 0` beside a full state directory and left the red gate to
#       look over the network on its own.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/ci-surface-watch.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-watch-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$WATCH" ] || { echo "FATAL: missing $WATCH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== ci-surface-watch tests ==="

# ---------------------------------------------------------------------------
# A FAKE ENGINE. The watch finds its parts relative to itself, so the parts are
# replaced rather than the lookup — which means the real resolution path is the
# one under test, not an environment variable only this file sets.
# ---------------------------------------------------------------------------
ENG="$SANDBOX/engine"
mkdir -p "$ENG/scripts/lib"
cp "$WATCH" "$ENG/scripts/"
STUB_WATCH="$ENG/scripts/ci-surface-watch.sh"

cat > "$ENG/scripts/ci-status.sh" <<'ST'
#!/usr/bin/env bash
echo "(rendered report stub)"
ST

cat > "$ENG/scripts/lib/ci-red.py" <<'RP'
#!/usr/bin/env python3
import sys
print("{}")
sys.exit(0)
RP

# The stub surface. Every knob it needs is an environment variable, so one file
# covers all eight cases and the differences between them are visible here
# rather than buried in six near-identical fixtures.
cat > "$ENG/scripts/lib/ci-surface.py" <<'CS'
#!/usr/bin/env python3
import json, os, sys
from datetime import datetime, timezone


def now_utc():
    return datetime.now(timezone.utc)


def parse_declarations(src):
    return {"budget": None, "skips": {}, "evidence": None, "cadence": None, "malformed": []}


def parse_triggers(src):
    return {"parsed": True, "events": ["push"], "push_paths": [], "cron": [], "reason": "stub"}


def judge(entry, decls, triggers, wf, runs, jobs, branch, mtime, now):
    # WATCH_CONTROL_BLIND makes the judgment return nothing but OK, which is
    # what a reader that has stopped reading looks like from outside.
    v = "OK" if os.environ.get("WATCH_CONTROL_BLIND") == "1" else "FINDING"
    entry["axes"] = {a: {"verdict": v, "detail": "stub"} for a in
                     ["slow", "red", "skipped", "never-run", "stale", "hollow"]}
    return entry


# EVERYTHING BELOW IS UNDER `__main__`, and that is not a style choice. The
# watch's negative control IMPORTS this module to call judge() on a synthetic
# workflow. Top-level output or a top-level sys.exit() would run during that
# import and the control would read a JSON document where it expected a list of
# axes. The real ci-surface.py is guarded the same way; the first version of
# this stub was not, and every case in this suite failed for that reason alone.
if __name__ == "__main__":
    if "--self-test" in sys.argv:
        if os.environ.get("WATCH_SELFTEST_FAIL") == "1":
            print("  SELF-TEST FAIL  the stub was told to fail")
            sys.exit(1)
        print("stub self-test: ok")
        sys.exit(0)

    nrepo = int(os.environ.get("WATCH_N_REPOS", "3"))
    nwf = int(os.environ.get("WATCH_N_WORKFLOWS", "9"))
    blind = json.loads(os.environ.get("WATCH_BLIND", "[]"))
    apifail = json.loads(os.environ.get("WATCH_APIFAIL", "[]"))
    print(json.dumps({
        "generated_at": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "branch": "main",
        "repositories": [{"slug": "o/r%d" % i, "root": "/x/%d" % i, "source": "stub"}
                         for i in range(nrepo)],
        "workflows": [],
        "blind": blind,
        "api": {"calls": 1, "cache_hits": 0, "failures": apifail},
        "counts": {"repositories": nrepo, "workflows": nwf, "findings": 4},
    }, indent=2))
    sys.exit(1)
CS

STATE="$SANDBOX/state"

# run  -> $OUT (stdout+stderr), $RC, and the verdict word in $V
run() {
    OUT="$(CI_SURFACE_STATE_DIR="$STATE" bash "$STUB_WATCH" --quiet 2>&1)"
    RC=$?
    V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
}

# --- W1 --------------------------------------------------------------------
rm -rf "$STATE"
run
if [ "$V" = "effective" ] && [ "$RC" -eq 0 ] && grep -q "verdict: effective" "$STATE/watch.log"; then
    ok "W1   a healthy pass says effective, exits 0, and writes a verdict line"
else
    bad "W1   verdict=$V rc=$RC — a healthy pass did not report itself effective"
fi

# --- W8 --------------------------------------------------------------------
HW_R="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["high_water_repositories"])' "$STATE/watch-state.json" 2>/dev/null || echo -1)"
if [ "$HW_R" = "3" ]; then
    ok "W8   the high-water mark records what was actually observed (3 repositories)"
else
    bad "W8   high_water_repositories=$HW_R, expected 3"
fi

# --- W4 --------------------------------------------------------------------
# Same state directory, a SMALLER pass. Everything else is healthy.
OUT="$(CI_SURFACE_STATE_DIR="$STATE" WATCH_N_REPOS=2 WATCH_N_WORKFLOWS=4 \
       bash "$STUB_WATCH" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
if [ "$V" = "degraded" ] && [ "$RC" -eq 1 ] && grep -q "COVERAGE SHRANK" <<<"$OUT"; then
    ok "W4   coverage shrinking is degraded, even with every other signal healthy"
else
    bad "W4   verdict=$V rc=$RC — a silently smaller inventory was reported as success:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | tail -4
fi

# --- W2 --------------------------------------------------------------------
rm -rf "$STATE"
OUT="$(CI_SURFACE_STATE_DIR="$STATE" WATCH_SELFTEST_FAIL=1 bash "$STUB_WATCH" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
if [ "$V" = "ineffective" ] && [ "$RC" -eq 2 ] && [ ! -f "$STATE/latest.json" ]; then
    ok "W2   a broken classifier stops the pass and files NO report"
else
    bad "W2   verdict=$V rc=$RC report=$( [ -f "$STATE/latest.json" ] && echo written || echo absent )"
fi

# --- W3 --------------------------------------------------------------------
rm -rf "$STATE"
OUT="$(CI_SURFACE_STATE_DIR="$STATE" WATCH_CONTROL_BLIND=1 bash "$STUB_WATCH" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
if [ "$V" = "ineffective" ] && [ "$RC" -eq 2 ] && grep -q "NEGATIVE CONTROL WAS NOT CAUGHT" <<<"$OUT"; then
    ok "W3   a negative control that comes back clean is ineffective, and says which check failed"
else
    bad "W3   verdict=$V rc=$RC — a reader that had stopped reading was reported as working:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | tail -4
fi

# --- W5 --------------------------------------------------------------------
rm -rf "$STATE"
OUT="$(CI_SURFACE_STATE_DIR="$STATE" WATCH_N_REPOS=0 WATCH_N_WORKFLOWS=0 \
       bash "$STUB_WATCH" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
if [ "$V" = "ineffective" ] && [ "$RC" -eq 2 ] && grep -q "empty corpus" <<<"$OUT"; then
    ok "W5   an empty corpus is ineffective — the one result that can never be reassuring"
else
    bad "W5   verdict=$V rc=$RC — zero workflows was reported as a clean surface"
fi

# --- W6 --------------------------------------------------------------------
rm -rf "$STATE"
OUT="$(CI_SURFACE_STATE_DIR="$STATE" WATCH_BLIND='["a source went silent"]' \
       bash "$STUB_WATCH" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
if [ "$V" = "degraded" ] && [ "$RC" -eq 1 ] && grep -q "blind spot" <<<"$OUT"; then
    ok "W6   a blind spot is degraded — part of the surface was not read"
else
    bad "W6   verdict=$V rc=$RC — an unread part of the surface passed as read"
fi

rm -rf "$STATE"
OUT="$(CI_SURFACE_STATE_DIR="$STATE" WATCH_APIFAIL='["gh exited 4"]' \
       bash "$STUB_WATCH" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
if [ "$V" = "degraded" ] && [ "$RC" -eq 1 ]; then
    ok "W6b  an API failure is degraded for the same reason"
else
    bad "W6b  verdict=$V rc=$RC"
fi

# --- W7 --------------------------------------------------------------------
# Every failing path above wrote into a fresh state dir; this asserts the log
# line exists on the FAILING path specifically, which is the one that matters:
# a pass that dies quietly cannot be told apart from one that never fired.
rm -rf "$STATE"
CI_SURFACE_STATE_DIR="$STATE" WATCH_SELFTEST_FAIL=1 bash "$STUB_WATCH" --quiet >/dev/null 2>&1
if [ -f "$STATE/watch.log" ] && grep -q "verdict: ineffective" "$STATE/watch.log"; then
    ok "W7   the verdict line is written on the FAILING path too"
else
    bad "W7   a failing pass left no verdict line — indistinguishable from never having fired"
fi

# ---------------------------------------------------------------------------
# W9 / W10 — THE REAL READER, WITH THE NETWORK REPLACED RATHER THAN THE READER
# ---------------------------------------------------------------------------
# Every case above stubs ci-surface.py, which is right for proving what the
# WATCH does with a document. Neither of the two properties below can be proven
# that way, because both are properties of the reader the watch actually runs:
#
#   W9   A TIMED-OUT CALL CAN NEVER PRODUCE A CLEAR VERDICT. This is the case
#        the 2026-09-10 repair exists to nail down. The tempting fix for a
#        `degraded` verdict is to make the failing read cheap enough to succeed
#        — and the moment it is cheap, the temptation is to treat a failure as
#        "nothing found", which turns the whole watch quiet instead of correct.
#        So: real reader, real watch, and a `gh` that never answers.
#   W10  THE PASS LEAVES THE CACHE WARM. It used to run `--no-cache`, which
#        meant it neither read nor wrote — so it reported `cache_hits: 0`
#        beside a state directory full of responses (indistinguishable from a
#        broken cache) and left nothing behind for the red gate that reads
#        minutes later. `--cache-mode refresh` fetches everything fresh AND
#        writes it. This asserts the writing, because that half is invisible in
#        the verdict line.
#
# `gh` is replaced on PATH; nothing else about the run is faked.
REAL_SURFACE="$SCRIPT_DIR/lib/ci-surface.py"
WF=".g""ithub/workflows"
NB="$SANDBOX/nb"
ENG2="$NB/hq/engine"
mkdir -p "$ENG2/scripts/lib" "$SANDBOX/bin" "$SANDBOX/home2/.claude/state"
cp "$WATCH" "$ENG2/scripts/"
cp "$REAL_SURFACE" "$ENG2/scripts/lib/"
cp "$ENG/scripts/ci-status.sh" "$ENG2/scripts/"
cp "$ENG/scripts/lib/ci-red.py" "$ENG2/scripts/lib/"
# A ledger that EXISTS, and an engine root that RESOLVES: the absence of either
# is itself an announced blind spot, and a case that cannot tell those blind
# spots from the one under test proves nothing. The launchd job sets
# RICHOS_ENGINE_ROOT for the same reason, so this is the production shape.
printf '{"repo": "/nonexistent/not-a-real-checkout"}\n' \
    > "$SANDBOX/home2/.claude/state/worktree-ledger.jsonl"
git -C "$NB/hq" init -q -b main 2>/dev/null
git -C "$NB/hq" remote add origin "git@github.com:Example/hq.git" 2>/dev/null

TARGET="$NB/target"
mkdir -p "$TARGET/$WF"
git -C "$TARGET" init -q -b main 2>/dev/null
git -C "$TARGET" remote add origin "git@github.com:Example/target.git" 2>/dev/null
: > "$TARGET/orchestration.config"
cat > "$TARGET/$WF/w.yml" <<'Y'
name: w
on:
  push:
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
Y

STATE2="$SANDBOX/state2"

# --- W9 --------------------------------------------------------------------
cat > "$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env python3
# A GitHub that accepts the connection and never answers.
import time
time.sleep(120)
GH
chmod +x "$SANDBOX/bin/gh"

# RUN FROM INSIDE THE SANDBOX. Discovery starts from the working directory, so
# a case run from a real checkout sweeps that machine's real repositories and
# asks the real GitHub about them — which is a case that proves something, but
# not the thing it says on the label. Caught the first time these two ran: 5
# repositories and 24 workflows in a fixture containing one of each.
rm -rf "$STATE2"
OUT="$(cd "$NB" && PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home2" CI_SURFACE_STATE_DIR="$STATE2" \
       RICHOS_ENGINE_ROOT="$ENG2" \
       CI_SURFACE_TIMEOUT=1 CI_SURFACE_RETRIES=0 \
       bash "$ENG2/scripts/ci-surface-watch.sh" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
if [ "$V" = "degraded" ] && [ "$RC" -ne 0 ] && grep -q "timed out" "$STATE2/latest.json" 2>/dev/null; then
    ok "W9   a timed-out read can never produce a clear verdict: got '$V' (rc=$RC), and the timeout is named in the document"
else
    bad "W9   verdict=$V rc=$RC — a read that never happened did not degrade the verdict:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | tail -4
fi

if grep -q '"verdict": "OK"' "$STATE2/latest.json" 2>/dev/null; then
    bad "W9b  an axis read as OK while every single read timed out"
else
    ok "W9b  NOT ONE axis reads OK while every read timed out — unread never rounds down to clear"
fi

# --- W10 -------------------------------------------------------------------
cat > "$SANDBOX/bin/gh" <<'GH'
#!/usr/bin/env python3
# A GitHub that answers: one active workflow, one green run on the tip.
import json, sys
from datetime import datetime, timedelta, timezone

p = sys.argv[2] if len(sys.argv) > 2 else ""
now = datetime.now(timezone.utc)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
SHA = "a" * 40
run = {"status": "completed", "conclusion": "success", "run_number": 7, "id": 7,
       "head_sha": SHA, "run_started_at": iso(now - timedelta(hours=2)),
       "created_at": iso(now - timedelta(hours=2)),
       "updated_at": iso(now - timedelta(hours=2) + timedelta(minutes=4))}

if "actions/workflows?per_page" in p:
    out = {"total_count": 1, "workflows": [
        {"id": 1, "name": "w", "path": ".g" "ithub/workflows/w.yml", "state": "active"}]}
elif "/actions/workflows/1/runs" in p:
    out = {"total_count": 1, "workflow_runs": [run]}
elif "/actions/runs/7/jobs" in p:
    out = {"jobs": [{"name": "a", "conclusion": "success",
                     "started_at": run["run_started_at"], "completed_at": run["updated_at"]}]}
elif "/commits?sha=" in p:
    out = [{"sha": SHA, "commit": {"committer": {"date": iso(now - timedelta(hours=3))},
                                   "message": "a commit"}}]
else:
    out = []
print(json.dumps(out))
GH
chmod +x "$SANDBOX/bin/gh"

rm -rf "$STATE2"
OUT="$(cd "$NB" && PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home2" CI_SURFACE_STATE_DIR="$STATE2" \
       RICHOS_ENGINE_ROOT="$ENG2" \
       CI_SURFACE_TIMEOUT=10 CI_SURFACE_RETRIES=0 \
       bash "$ENG2/scripts/ci-surface-watch.sh" --quiet 2>&1)"; RC=$?
V="$(printf '%s\n' "$OUT" | sed -n 's/^verdict: \([a-z]*\).*/\1/p' | tail -1)"
CACHED="$(ls "$STATE2"/api_*.json 2>/dev/null | wc -l | tr -d ' ')"
if [ "$V" = "effective" ] && [ "$RC" -eq 0 ]; then
    ok "W10  a pass in which every read answered is effective (findings are not degradation)"
else
    bad "W10  verdict=$V rc=$RC — a fully-read surface did not report itself effective:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | tail -4
fi
if [ "${CACHED:-0}" -ge 1 ]; then
    ok "W10b the pass leaves the cache WARM ($CACHED response(s) written), so the red gate that reads next does not have to look over the network"
else
    bad "W10b the pass wrote 0 cached responses — the cache is dead by construction again"
fi
if grep -q '"cache_mode": "refresh"' "$STATE2/latest.json" 2>/dev/null; then
    ok "W10c the document NAMES its cache mode, so cache_hits: 0 can never again be read as a broken cache"
else
    bad "W10c the document does not name its cache mode next to the hit count"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ci-surface-watch tests: all $PASS passed ==="
    exit 0
fi
echo "=== ci-surface-watch tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
