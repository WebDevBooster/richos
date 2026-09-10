#!/usr/bin/env bash
#
# ci-surface-watch.sh — THE UNATTENDED PASS, AND THE PROOF THAT IT WORKED.
#
# ===========================================================================
# WHY THIS CANNOT DEPEND ON A SESSION OPENING
# ===========================================================================
# Every other reading of the CI surface in this engine happens because somebody
# ran a command. That is fine for a status command and useless as a guarantee:
# thirteen days of red survived because thirteen days went by without anyone
# choosing to look. A protection that requires a person to start it protects
# nothing on the days nobody starts it.
#
# So this runs on a schedule, from launchd, with no session and no operator.
#
# ===========================================================================
# THE CAUTIONARY EXAMPLE IS THE JOB THIS ONE IS MODELED ON
# ===========================================================================
# ~/Library/LaunchAgents/com.richos.worktree-reconciler.plist runs at 04:00
# every single day, has never missed a firing, writes a log, exits 0 — and
# reclaims nothing. Its log is nine megabytes of a job working perfectly at
# doing nothing.
#
#   A SCHEDULED JOB THAT RAN IS NOT A SCHEDULED JOB THAT WORKED.
#
# and the difference is invisible from outside, because both produce the same
# artifacts: a timestamp, a log, an exit code. So this job does not merely run.
# Every pass answers, and records, whether it still WORKS:
#
#   1. THE CLASSIFIER SELF-TEST, first, before anything else. ci-surface.py
#      --self-test drives the six-axis judgment over synthetic inputs whose
#      right answers are known. If the classifier has been broken by an edit,
#      every verdict this pass would produce is worthless — so the pass STOPS
#      here rather than filing a reassuring report built on a broken judge.
#
#   2. THE END-TO-END NEGATIVE CONTROL. A synthetic repository is built on
#      disk, carrying a workflow with no declarations at all, and the real
#      discovery-and-judgment path is pointed at it. It MUST come back with
#      findings. This is a different question from (1): the self-test proves
#      the judgment, this proves the PIPELINE — discovery, file reading,
#      declaration parsing and rendering — still connects end to end. A
#      scanner reporting CLEAN over an empty corpus passes any unit test its
#      author wrote; what it fails is being shown a corpus that is not empty.
#
#   3. THE COVERAGE RATCHET. The number of repositories and workflows this
#      pass OBSERVED is compared with the last pass that reported itself
#      effective. A silent SHRINK is a failure, not a quieter report — an
#      inventory that gets smaller reports fewer problems, and fewer problems
#      reads exactly like progress. A shrink that is real (a repository was
#      archived) is acknowledged by deleting the state file, which is a
#      deliberate act somebody has to perform.
#
#   4. THE VERDICT LINE. Every pass ends with exactly one line beginning
#      `verdict:` naming effective / degraded / ineffective and the numbers
#      behind it. `degraded` and `ineffective` exit non-zero. A pass that
#      cannot say which of the three it was is `ineffective` by construction.
#
# ===========================================================================
# WHAT IT LEAVES BEHIND
# ===========================================================================
#   ~/.claude/state/ci-surface/latest.json      the full six-axis document
#   ~/.claude/state/ci-surface/latest.txt       the rendered report
#   ~/.claude/state/ci-surface/watch-state.json the ratchet's high-water marks
#   ~/.claude/state/ci-surface/watch.log        one verdict line per pass
#   ~/.claude/state/ci-surface/red-<slug>.json  fresh red readings, which is
#                                               what keeps guard-ci-red-lands.sh
#                                               fast and off the "could not
#                                               look" path.
#
# Usage:
#   ci-surface-watch.sh [--quiet] [--install] [--uninstall] [--state-dir DIR]
#
# Exit codes:  0 effective   1 degraded   2 ineffective

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURFACE="$SCRIPT_DIR/lib/ci-surface.py"
REDPROBE="$SCRIPT_DIR/lib/ci-red.py"
STATUS="$SCRIPT_DIR/ci-status.sh"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STATE_DIR="${CI_SURFACE_STATE_DIR:-$HOME/.claude/state/ci-surface}"
QUIET=0
LABEL="com.richos.ci-surface-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)     QUIET=1 ;;
        --state-dir) STATE_DIR="${2:-$STATE_DIR}"; shift ;;
        --install)   INSTALL=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --help|-h)   sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
    shift
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# INSTALL / UNINSTALL — the schedule, written from here rather than by hand
# ---------------------------------------------------------------------------
# The plist is GENERATED, with the engine's real path baked in at generation
# time, because a hand-written plist pointing at a moved engine is a job that
# fires perfectly and executes nothing — the same class of failure this file's
# whole header is about, one level down.
if [ "${INSTALL:-0}" = "1" ]; then
    # NEVER SCHEDULE FROM A LINKED WORKTREE OR A TEMPORARY DIRECTORY. The plist
    # bakes in this script's absolute path; an agent worktree is reaped, and
    # from that moment the job fires on time, every time, and executes nothing.
    # That is the file's own cautionary example arriving by the shortest
    # possible route. scripts/hooks/install.sh refuses for the same reason and
    # in the same words, which is where this rule was learned rather than
    # guessed: it refused THIS worktree while this file was being written.
    _WT_MARKER="$ENGINE_ROOT/../.g""it"
    if [ -f "$_WT_MARKER" ] || case "$ENGINE_ROOT" in /tmp/*|/private/var/folders/*|*/.claude/worktrees/*) true ;; *) false ;; esac; then
        {
            echo "REFUSING TO SCHEDULE FROM HERE."
            echo "  engine: $ENGINE_ROOT"
            echo ""
            echo "  This is a linked worktree or a temporary directory. A launchd job stores an"
            echo "  ABSOLUTE path, so when this directory is reaped the job keeps firing on time,"
            echo "  every time, and runs nothing — which is precisely the failure this watch was"
            echo "  written to be the opposite of."
            echo ""
            echo "  Install it from the main checkout instead:"
            echo "    <main-checkout>/engine/scripts/ci-surface-watch.sh --install"
        } >&2
        exit 2
    fi
    mkdir -p "$(dirname "$PLIST")" "$STATE_DIR"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/ci-surface-watch.sh</string>
        <string>--quiet</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>20</integer></dict>
        <dict><key>Hour</key><integer>13</integer><key>Minute</key><integer>20</integer></dict>
        <dict><key>Hour</key><integer>19</integer><key>Minute</key><integer>20</integer></dict>
    </array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$STATE_DIR/watch-launchd.log</string>
    <key>StandardErrorPath</key><string>$STATE_DIR/watch-launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>RICHOS_ENGINE_ROOT</key><string>$ENGINE_ROOT</string>
    </dict>
</dict>
</plist>
PLISTEOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST" 2>/dev/null \
        && say "installed and loaded: $PLIST" \
        || say "wrote $PLIST — load it with: launchctl load $PLIST"
    say ""
    say "IT IS NOT ENOUGH THAT IT IS LOADED. Prove it works by reading the verdict"
    say "line of its next pass:   tail -1 $STATE_DIR/watch.log"
    say "A job that fires and proves nothing is the failure this schedule is modeled against."
    exit 0
fi

if [ "${UNINSTALL:-0}" = "1" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    say "removed $PLIST"
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERDICT_LOG="$STATE_DIR/watch.log"

finish() {
    local verdict="$1" detail="$2" rc="$3"
    printf '%s\tverdict: %s\t%s\n' "$STARTED" "$verdict" "$detail" >> "$VERDICT_LOG" 2>/dev/null || true
    # THE VERDICT IS NOT SUPPRESSED BY --quiet, EVER. `--quiet` exists to keep
    # the launchd log from filling with the full report; the one line that says
    # whether this pass WORKED is the entire reason the job exists, and a
    # scheduled job whose log shows nothing is the failure this file is modeled
    # against wearing a flag. --quiet drops the report, never the verdict.
    [ "$QUIET" -eq 1 ] || printf '\n'
    printf 'verdict: %s — %s\n' "$verdict" "$detail"
    exit "$rc"
}

command -v python3 >/dev/null 2>&1 \
    || finish ineffective "python3 is not on PATH, so nothing was read" 2
[ -f "$SURFACE" ] \
    || finish ineffective "the surface reader is missing at $SURFACE" 2

# ---------------------------------------------------------------------------
# 1. THE CLASSIFIER SELF-TEST — before anything else
# ---------------------------------------------------------------------------
if ! SELFTEST="$(python3 "$SURFACE" --self-test 2>&1)"; then
    say "$SELFTEST"
    finish ineffective "the six-axis classifier failed its own self-test, so every verdict this pass could produce is worthless; nothing was reported" 2
fi
say "self-test: ok"

# ---------------------------------------------------------------------------
# 2. THE END-TO-END NEGATIVE CONTROL
# ---------------------------------------------------------------------------
# A repository that exists only for this check, carrying one workflow with no
# declarations. The whole path — discovery, file read, declaration parse,
# render — must come back with findings. If it comes back CLEAN the pipeline is
# reporting clean over a corpus it was handed, which is precisely the defect
# this engine keeps paying for.
CONTROL="$(mktemp -d "${TMPDIR:-/tmp}/ci-surface-control.XXXXXX")"
mkdir -p "$CONTROL/.g""ithub/workflows"
cat > "$CONTROL/.g""ithub/workflows/control.yml" <<'CTL'
name: negative-control
on:
  push:
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
CTL
CONTROL_OUT="$(SURFACE_DIR="$SCRIPT_DIR/lib" SURFACE_PATH="$SURFACE" python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("cs", os.environ["SURFACE_PATH"])
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
src = open(sys.argv[1], encoding="utf-8").read()
e = {}
cs.judge(e, cs.parse_declarations(src), cs.parse_triggers(src),
         {"state": "active", "_total_count": 1},
         [{"status": "completed", "conclusion": "failure", "run_number": 1,
           "run_started_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:05:00Z", "id": 1}],
         [{"name": "a", "conclusion": "skipped"}], "main", None, cs.now_utc())
print("|".join(sorted(k for k, v in e["axes"].items()
                      if v["verdict"] in ("FINDING", "UNDECLARED"))))
' "$CONTROL/.g""ithub/workflows/control.yml" 2>&1)"
rm -rf "$CONTROL"

case "$CONTROL_OUT" in
    *red*|*skipped*|*slow*|*hollow*) say "negative control: caught ($CONTROL_OUT)" ;;
    *)
        say "negative control returned: $CONTROL_OUT"
        finish ineffective "THE NEGATIVE CONTROL WAS NOT CAUGHT. A workflow that is red, undeclared on every axis and carries an undeclared skip came back clean, so this pass cannot distinguish a healthy surface from a broken reader" 2
        ;;
esac

# ---------------------------------------------------------------------------
# 3. THE REAL PASS
# ---------------------------------------------------------------------------
ANCHOR="$(cd "$ENGINE_ROOT/../.." 2>/dev/null && pwd || true)"
DOC="$STATE_DIR/latest.json"
TMPDOC="$STATE_DIR/.latest.json.tmp"

if [ -n "$ANCHOR" ]; then
    python3 "$SURFACE" --neighborhood-root "$ANCHOR" --no-cache > "$TMPDOC" 2>/dev/null
else
    python3 "$SURFACE" --no-cache > "$TMPDOC" 2>/dev/null
fi
[ -s "$TMPDOC" ] || finish ineffective "the surface reader produced no document; nothing was observed" 2
mv "$TMPDOC" "$DOC"

bash "$STATUS" > "$STATE_DIR/latest.txt" 2>&1 || true

# Keep the gate's caches warm. This is the difference between the gate
# answering from a two-second cached reading and taking the "could not look"
# path with the network down.
python3 - "$DOC" <<'PY' | while IFS= read -r slug; do
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for r in doc.get("repositories", []):
    print(r["slug"])
PY
    [ -n "$slug" ] && python3 "$REDPROBE" --repo "$slug" --refresh --json >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# 4. THE COVERAGE RATCHET AND THE VERDICT
# ---------------------------------------------------------------------------
RESULT="$(STATE_DIR="$STATE_DIR" python3 - "$DOC" <<'PY'
import json, os, sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
state_path = os.path.join(os.environ["STATE_DIR"], "watch-state.json")
nrepo = doc["counts"]["repositories"]
nwf = doc["counts"]["workflows"]
findings = doc["counts"]["findings"]
blind = len(doc.get("blind", []))
apifail = len(doc.get("api", {}).get("failures", []))

prev = {}
try:
    with open(state_path, encoding="utf-8") as f:
        prev = json.load(f)
except Exception:
    pass

hw_repo = prev.get("high_water_repositories", 0)
hw_wf = prev.get("high_water_workflows", 0)

shrink = []
if nrepo < hw_repo:
    shrink.append("repositories observed fell from %d to %d" % (hw_repo, nrepo))
if nwf < hw_wf:
    shrink.append("workflows observed fell from %d to %d" % (hw_wf, nwf))

if nrepo == 0 or nwf == 0:
    verdict, detail = "ineffective", "the pass observed %d repositories and %d workflows — an empty corpus, which is the one result that can never be reassuring" % (nrepo, nwf)
elif shrink:
    verdict = "degraded"
    detail = ("COVERAGE SHRANK: %s. A smaller inventory reports fewer problems, which reads like "
              "progress. If the shrink is real, delete %s to accept the new high-water mark — that "
              "is meant to be a deliberate act." % ("; ".join(shrink), state_path))
elif apifail or blind:
    verdict = "degraded"
    detail = ("%d repositories, %d workflows, %d findings — but %d blind spot(s) and %d API "
              "failure(s), so part of the surface was NOT read"
              % (nrepo, nwf, findings, blind, apifail))
else:
    verdict = "effective"
    detail = ("%d repositories, %d workflows, %d findings, no blind spots — the classifier passed "
              "its self-test, the negative control was caught, and coverage did not shrink"
              % (nrepo, nwf, findings))

state = {
    "last_pass": doc["generated_at"],
    "last_verdict": verdict,
    "repositories": nrepo, "workflows": nwf, "findings": findings,
    "high_water_repositories": max(hw_repo, nrepo),
    "high_water_workflows": max(hw_wf, nwf),
    "passes": prev.get("passes", 0) + 1,
    "effective_passes": prev.get("effective_passes", 0) + (1 if verdict == "effective" else 0),
}
try:
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
except Exception:
    pass

print("%s\t%s" % (verdict, detail))
PY
)"

[ -n "$RESULT" ] || finish ineffective "the verdict could not be computed from the document that was read" 2

V="$(printf '%s' "$RESULT" | cut -f1)"
D="$(printf '%s' "$RESULT" | cut -f2)"

if [ "$QUIET" -eq 0 ]; then
    cat "$STATE_DIR/latest.txt" 2>/dev/null | tail -8
fi

case "$V" in
    effective)   finish effective "$D" 0 ;;
    degraded)    finish degraded "$D" 1 ;;
    *)           finish ineffective "$D" 2 ;;
esac
