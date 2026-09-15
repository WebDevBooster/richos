#!/usr/bin/env bash
#
# check-census.test.sh — the census is only worth having if its verdicts agree
#                        with what the checks ACTUALLY DO.
#
# ===========================================================================
# WHAT THIS SUITE IS FOR, AND WHAT IT DELIBERATELY IS NOT
# ===========================================================================
# scripts/check-census.py classifies every registered check by reading its
# source and its event. A classifier checked only against itself is the type-Z
# failure this engine has now recorded eight times: the case passes because
# the thing it names never ran.
#
# So the load-bearing cases here do not read the census's reasoning. They RUN
# the hook with a payload that contains a real finding and compare the exit
# code to the verdict:
#
#   C2  a check the census calls a CONTROL is driven with a finding and must
#       refuse (exit 2).
#   C3  a check the census does NOT call a CONTROL is driven with a finding
#       and must not refuse (exit 0) — with a positive control on the same
#       run, because "exit 0 and silent" would pass this case for the wrong
#       reason. The finding has to be PRESENT in the output for the case to
#       count.
#
# C1 pins the population against hooks.json, derived on both sides. C4 pins
# the invariant that makes the whole class meaningful: nothing registered on
# an event whose host ceiling is `none` may ever be called a CONTROL, whatever
# its code says. C5 pins the fail-loud clause.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CENSUS="$SCRIPT_DIR/check-census.py"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$CENSUS" ] || { echo "FATAL: missing $CENSUS" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-census.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== check-census tests ==="

JSON="$SANDBOX/census.json"
if ! python3 "$CENSUS" --engine-root "$ENGINE_ROOT" --format json > "$JSON" 2>"$SANDBOX/err"; then
    echo "  FATAL  the census would not run:"; sed 's/^/          /' "$SANDBOX/err"; exit 1
fi

# --- C1 --------------------------------------------------------------------
# The population, derived on both sides from hooks.json and required to agree.
C1="$(ENGINE_ROOT="$ENGINE_ROOT" JSON="$JSON" python3 -c '
import json, os, re
doc = json.load(open(os.environ["JSON"]))
hooks = json.load(open(os.path.join(os.environ["ENGINE_ROOT"], "hooks", "hooks.json")))["hooks"]
regs, scripts = 0, set()
for event, matchers in hooks.items():
    for m in matchers:
        for hk in m.get("hooks", []):
            regs += 1
            mm = re.search(r"\$\{CLAUDE_PLUGIN_ROOT\}/(\S+?)(?:\"|\s|$)", hk.get("command", ""))
            scripts.add(mm.group(1).rstrip("\"") if mm else "<inline>")
named = {r["check"] for r in doc["checks"]}
if doc["registrations"] != regs:
    print("registrations %d != %d" % (doc["registrations"], regs))
elif len(named) != len(scripts):
    print("checks %d != %d" % (len(named), len(scripts)))
else:
    print("ok %d registrations, %d checks" % (regs, len(scripts)))' 2>&1)"
case "$C1" in
    ok\ *) ok "C1   population matches hooks.json exactly ($C1)" ;;
    *)     bad "C1   $C1" ;;
esac

# --- C2 --------------------------------------------------------------------
# A CONTROL, driven with a finding, must refuse. guard-workflow-ban.sh is used
# because its finding is a single field of the payload, so the case cannot
# fail for an unrelated environmental reason.
printf '%s' '{"session_id":"census-test","cwd":"'"$ENGINE_ROOT"'","hook_event_name":"PreToolUse","tool_name":"Workflow","tool_input":{"workflow":"x"}}' > "$SANDBOX/wf.json"
bash "$ENGINE_ROOT/scripts/hooks/guard-workflow-ban.sh" < "$SANDBOX/wf.json" >/dev/null 2>&1
RC_WF=$?
CLS_WF="$(JSON="$JSON" python3 -c '
import json, os
doc = json.load(open(os.environ["JSON"]))
print(next((r["class"] for r in doc["checks"] if r["check"] == "guard-workflow-ban.sh"), "ABSENT"))')"
if [ "$RC_WF" -eq 2 ] && [ "$CLS_WF" = "CONTROL" ]; then
    ok "C2   census says CONTROL and the hook refuses the call (exit $RC_WF)"
else
    bad "C2   census=$CLS_WF exit=$RC_WF — a control that does not refuse, or a refusal the census missed"
fi

# --- C3 --------------------------------------------------------------------
# A non-CONTROL, driven with a finding that is PRESENT in its output, must not
# refuse. The presence check is the positive control: silence would otherwise
# pass this case without the hook ever reaching its verdict.
S="$SANDBOX/ci-state"; mkdir -p "$S"
python3 -c '
import json, os, sys
from datetime import datetime, timezone
d = sys.argv[1]
json.dump({"last_pass": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
           "last_verdict": "effective"}, open(os.path.join(d, "watch-state.json"), "w"))
json.dump({"repo": "Example/alpha", "state": "red",
           "red": [{"workflow": "wf-00.yml", "name": "wf-00", "conclusion": "failure",
                    "run_number": 90, "since_run": 50, "days": 60,
                    "days_is_a_floor": False, "last_green_run": 49,
                    "file_backed": True, "path": ".github/workflows/wf.yml"}]},
          open(os.path.join(d, "red-alpha.json"), "w"))' "$S"
FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME/Library/LaunchAgents"
touch "$FAKE_HOME/Library/LaunchAgents/com.richos.ci-surface-watch.plist"
printf '%s' '{"session_id":"census-test","cwd":"'"$ENGINE_ROOT"'","hook_event_name":"SessionStart"}' > "$SANDBOX/ss.json"
OUT_CI="$(HOME="$FAKE_HOME" CI_SURFACE_STATE_DIR="$S" \
    bash "$ENGINE_ROOT/scripts/hooks/session-start-ci-surface.sh" < "$SANDBOX/ss.json" 2>&1)"
RC_CI=$?
CLS_CI="$(JSON="$JSON" python3 -c '
import json, os
doc = json.load(open(os.environ["JSON"]))
print(next((r["class"] for r in doc["checks"] if r["check"] == "session-start-ci-surface.sh"), "ABSENT"))')"
case "$OUT_CI" in *"CI IS RED"*) SAW_FINDING=yes ;; *) SAW_FINDING=no ;; esac
if [ "$RC_CI" -eq 0 ] && [ "$SAW_FINDING" = yes ] && [ "$CLS_CI" != "CONTROL" ]; then
    ok "C3   census says $CLS_CI; the hook found its thing and refused nothing (exit $RC_CI)"
else
    bad "C3   census=$CLS_CI exit=$RC_CI finding-present=$SAW_FINDING"
fi

# --- C4 --------------------------------------------------------------------
# The invariant that makes the class mean anything: a check cannot be a CONTROL
# on an event where the host refuses nothing, however it exits.
C4="$(JSON="$JSON" python3 -c '
import json, os
doc = json.load(open(os.environ["JSON"]))
bad = [r["check"] for r in doc["checks"]
       if r["class"] == "CONTROL" and r["host_act"] == "none"]
print("ok" if not bad else "CONTROL on an event that refuses nothing: " + ", ".join(bad))')"
if [ "$C4" = "ok" ]; then
    ok "C4   no check is called a CONTROL on an event whose host ceiling is none"
else
    bad "C4   $C4"
fi

# --- C5 --------------------------------------------------------------------
# Fail loud, never silently empty: an unreadable or empty registration table is
# a broken parser, and a census of zero checks would read as a clean engine.
mkdir -p "$SANDBOX/fake/hooks"
printf '%s' '{"hooks":{}}' > "$SANDBOX/fake/hooks/hooks.json"
C5="$(CENSUS="$CENSUS" SB="$SANDBOX" python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("cc", os.environ["CENSUS"])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
try:
    mod.registrations(os.path.join(os.environ["SB"], "fake"))
except SystemExit as e:
    print("raised" if "NO registration" in str(e) else "wrong-message")
else:
    print("returned-quietly")' 2>&1)"
if [ "$C5" = "raised" ]; then
    ok "C5   an empty registration table is refused, not reported as a clean engine"
else
    bad "C5   $C5"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== check-census tests: all $PASS passed ==="
    exit 0
fi
echo "=== check-census tests: $PASS passed, $FAIL FAILED ==="
exit 1
