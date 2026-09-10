#!/usr/bin/env bash
#
# session-start-ci-surface.test.sh — the notice must be silent when it should
# be, and loud about the right two things when it should not.
#
# THE CASES:
#
#   N1  CLEAN AND WATCHED -> completely silent. This is the load-bearing case.
#       This engine already carries eight session-start notices; a ninth that
#       speaks every time is a ninth that trains people to scroll past all of
#       them, and the two that matter go with it.
#   N2  RED -> named, with the AGE of each streak, oldest first. An age is what
#       makes "red" obviously wrong rather than merely present: thirteen days
#       is the fact this whole subsystem was built from.
#   N3  THE WATCH NOT INSTALLED -> said out loud. Every other part of this
#       subsystem is silent when healthy, so an uninstalled watch would
#       otherwise be indistinguishable from a clean surface — which is the
#       single most dangerous state available to it.
#   N4  THE WATCH REPORTING degraded/ineffective -> said out loud, with the
#       command that shows why. "It ran and it did not work."
#   N5  THE WATCH SILENT FOR TOO LONG -> said out loud. A scheduled job that
#       quietly stopped looks exactly like a clean surface.
#   N6  A REPOSITORY THAT COULD NOT BE READ -> named as UNREAD, never folded
#       into clear.
#   N7  TRUNCATION IS ANNOUNCED. The first version of this notice printed a
#       count of eleven above a list of eight, dropping three red workflows —
#       all of them in the repository the reader most cared about. A number
#       and a list that disagree is a scanner that stopped reading.
#   N8  IT NEVER BLOCKS. A SessionStart hook that exits non-zero can wedge a
#       session; nothing here is worth that.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/session-start-ci-surface.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-notice.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== session-start-ci-surface tests ==="

S="$SANDBOX/state"
mkdir -p "$S"
FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME/Library/LaunchAgents"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

install_watch() { : > "$FAKE_HOME/Library/LaunchAgents/com.richos.ci-surface-watch.plist"; }
uninstall_watch() { rm -f "$FAKE_HOME/Library/LaunchAgents/com.richos.ci-surface-watch.plist"; }

# write_state <verdict> <hours-ago>
write_state() {
    python3 -c '
import json, sys
from datetime import datetime, timedelta, timezone
t = datetime.now(timezone.utc) - timedelta(hours=float(sys.argv[3]))
json.dump({"last_pass": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "last_verdict": sys.argv[2],
           "repositories": 5, "workflows": 21, "findings": 0,
           "high_water_repositories": 5, "high_water_workflows": 21,
           "passes": 9, "effective_passes": 9}, open(sys.argv[1], "w"), indent=2)' \
        "$S/watch-state.json" "$1" "$2"
}

# write_red <slug> <state> <n-red>
write_red() {
    python3 -c '
import json, sys
slug, st, n = sys.argv[2], sys.argv[3], int(sys.argv[4])
doc = {"repo": slug, "branch": "main", "read_at": "2026-09-10T00:00:00Z",
       "source": "test", "workflows_seen": 9, "state": st, "red": []}
if st == "unknown":
    doc["reason"] = "the fixture said so"
for i in range(n):
    doc["red"].append({"workflow": "wf-%02d.yml" % i, "name": "wf-%02d" % i,
                       "conclusion": "failure", "run_number": 90 + i,
                       "since_run": 50 + i, "days": 60 - i,
                       "days_is_a_floor": False, "last_green_run": 49,
                       "file_backed": True, "path": ".github/workflows/wf.yml"})
json.dump(doc, open(sys.argv[1], "w"), indent=2)' \
        "$S/red-$(printf '%s' "$1" | tr '/' '-')-main.json" "$1" "$2" "$3"
}

run() {
    OUT="$(HOME="$FAKE_HOME" CI_SURFACE_STATE_DIR="$S" bash "$HOOK" 2>&1)"
    RC=$?
}

# --- N1 --------------------------------------------------------------------
rm -f "$S"/red-*.json
install_watch
write_state effective 2
run
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then
    ok "N1   clean and watched: completely silent"
else
    bad "N1   rc=$RC out=<$OUT> — a ninth always-on banner trains people to scroll past all nine"
fi

# --- N3 --------------------------------------------------------------------
uninstall_watch
run
if grep -q "NOT INSTALLED" <<<"$OUT"; then
    ok "N3   an uninstalled watch is said out loud, not mistaken for a clean surface"
else
    bad "N3   an uninstalled watch was silent — the most dangerous state it has"
fi
install_watch

# --- N4 --------------------------------------------------------------------
write_state degraded 2
run
if grep -q "degraded" <<<"$OUT" && grep -q "did not work" <<<"$OUT"; then
    ok "N4   a watch that ran and did not work says exactly that"
else
    bad "N4   out=<$OUT>"
fi

# --- N5 --------------------------------------------------------------------
write_state effective 40
run
if grep -q "has not completed a pass" <<<"$OUT"; then
    ok "N5   a watch that quietly stopped is reported, not read as clean"
else
    bad "N5   a 40-hour silence from a thrice-daily job went unmentioned"
fi
write_state effective 2

# --- N2 --------------------------------------------------------------------
write_red "Example/alpha" red 2
run
if grep -q "CI IS RED — 2 workflow" <<<"$OUT" \
   && grep -q "60 day" <<<"$OUT" && grep -q "oldest first" <<<"$OUT"; then
    ok "N2   red is named with the age of each streak, oldest first"
else
    bad "N2   out=<$OUT>"
fi

# --- N7 --------------------------------------------------------------------
rm -f "$S"/red-*.json
write_red "Example/alpha" red 20
run
COUNT_LINE="$(grep -c "wf-" <<<"$OUT" || true)"
if grep -q "CI IS RED — 20 workflow(s), the 12 oldest of them shown here" <<<"$OUT" \
   && grep -q "and 8 more" <<<"$OUT" && [ "$COUNT_LINE" -eq 12 ]; then
    ok "N7   a truncated list ANNOUNCES the truncation and the remainder ($COUNT_LINE rows shown of 20)"
else
    bad "N7   a count and a list disagreed with nobody being told: rows=$COUNT_LINE"
    printf '%s\n' "$OUT" | sed 's/^/          /' | head -5
fi

# --- N6 --------------------------------------------------------------------
rm -f "$S"/red-*.json
write_red "Example/beta" unknown 0
run
if grep -q "could not be read at all" <<<"$OUT" && grep -q "UNREAD" <<<"$OUT"; then
    ok "N6   a repository that could not be read is UNREAD, never folded into clear"
else
    bad "N6   out=<$OUT>"
fi

# --- N8 --------------------------------------------------------------------
if [ "$RC" -eq 0 ]; then
    ok "N8   the notice exits 0 even while shouting — it never wedges a session"
else
    bad "N8   rc=$RC — a SessionStart notice returned non-zero"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== session-start-ci-surface tests: all $PASS passed ==="
    exit 0
fi
echo "=== session-start-ci-surface tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
