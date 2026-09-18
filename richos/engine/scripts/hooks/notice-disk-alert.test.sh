#!/usr/bin/env bash
#
# notice-disk-alert.test.sh — THE ALERT MUST REACH RICH, AND MUST NOT BECOME
#                             WALLPAPER ON A HEALTHY MACHINE.
#
#   D1  a healthy machine: SILENT on both events, exit 0.
#   D2  SessionStart renders the WHOLE BLOCK on BOTH channels (systemMessage
#       for the operator, additionalContext for the model). stderr is never
#       used — measured 2026-09-14 to reach no channel at SessionStart.
#   D3  Stop renders ONE LINE. The host prefixes every line with "Stop says: ",
#       so a block there is noise.
#   D4  the Stop line carries the FACTS: the volume, the free space, the stuck
#       paths and the classification.
#   D5  IT REPEATS EVERY TURN while the condition holds. Every other Stop notice
#       in this engine announces on entry and goes quiet; the CEO asked for this
#       one to repeat "every turn until the condition clears", so the case that
#       matters is the SECOND consecutive turn.
#   D6  ...and goes silent the moment it clears.
#   D7  THE ALERT CANNOT BE SILENCED BY CONFIGURATION. DISK_WATCHDOG_ENABLE=0
#       stands down the scheduled reading and the CEO's notifications; an alert
#       with an off switch is not an alert.
#   D8  the hook never writes the watchdog's state file, so a turn end cannot
#       destroy the baseline the drop arithmetic subtracts from.
#   D9  exit is ALWAYS 0. A notice that takes the session down with it is worse
#       than no notice.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/notice-disk-alert.sh"
SCRIPTS="$(cd "$HOOK_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/disk-alert-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== notice-disk-alert tests ==="

CFG="$SANDBOX/orchestration.config"
STATE="$SANDBOX/state.json"
LOG="$SANDBOX/watchdog.log"
LA="$SANDBOX/LaunchAgents"
FAILS="$SANDBOX/scratch-failures.json"
LEDGER_DIR="$SANDBOX/claude"
mkdir -p "$LA" "$LEDGER_DIR/state"
touch "$LA/com.richos.disk-watchdog.plist"      # installed, so D1 can be silent

# write_cfg <rich-floor-gb> [enable]
write_cfg() {
    cat >"$CFG" <<CFG
DISK_WATCHDOG_ENABLE="${2:-1}"
DISK_PRIMARY_VOLUME="/System/Volumes/Data"
DISK_EXTRA_VOLUMES=""
DISK_RICH_ALERT_GB="$1"
DISK_DROP_ALERT_GB="999999"
DISK_CEO_NOTIFY_GB="0"
DISK_CEO_URGENT_GB="0"
DISK_CEO_REPEAT_HOURS="24"
DISK_SCALE_EXTRA_VOLUMES="1"
DISK_WATCHDOG_MINUTES="15"
DISK_CONSUMER_CANDIDATES="$SANDBOX"
DISK_STATE_JSON="$STATE"
SCRATCH_ROOT_NAME="richos-scratch"
SCRATCH_CLAUDE_ROOTS="$SANDBOX/claude-%u"
SCRATCH_FAILURES_STATE="$FAILS"
CFG
}

# The hook's own ledger lives under CLAUDE_CONFIG_DIR, so the de-duplication
# state is this suite's and never the operator's.
run_hook() {                # <event>
    DISK_WATCHDOG_CONFIG="$CFG" \
    DISK_WATCHDOG_LOG="$LOG" \
    RICHOS_LAUNCH_AGENTS_DIR="$LA" \
    CLAUDE_CONFIG_DIR="$LEDGER_DIR" \
    bash "$HOOK" --event "$1" </dev/null 2>"$SANDBOX/err.txt"
}

# ---------------------------------------------------------------------------
# D1 — a healthy machine is silent on both events
# ---------------------------------------------------------------------------
write_cfg 1
OUT_SS="$(run_hook SessionStart)"; RC_SS=$?
OUT_ST="$(run_hook Stop)"; RC_ST=$?
if [ "$RC_SS" = "0" ] && [ -z "$OUT_SS" ]; then
    ok "D1  SessionStart is silent on a healthy machine"
else
    bad "D1  SessionStart spoke on a healthy machine (rc=$RC_SS)"
    printf '%s\n' "$OUT_SS" | sed 's/^/        /' | head -5
fi
# Stop may legitimately emit a recovery notice; what it must not do is alert.
if [ "$RC_ST" = "0" ] && ! printf '%s' "$OUT_ST" | grep -q 'MASSIVE ALERT'; then
    ok "D1b Stop raises no alert on a healthy machine"
else
    bad "D1b Stop alerted on a healthy machine (rc=$RC_ST)"
    printf '%s\n' "$OUT_ST" | sed 's/^/        /' | head -5
fi

# ---------------------------------------------------------------------------
# D2 — SessionStart carries the whole block on both channels
# ---------------------------------------------------------------------------
write_cfg 999999                                  # an unreachable floor
python3 - "$FAILS" <<'PY'
import json, sys
json.dump({"/tmp/stuck-forever": {
    "first": "2026-09-18T07:40:05Z", "last": "2026-09-18T08:00:00Z",
    "error": "[Errno 1] Operation not permitted", "attempts": 7}},
    open(sys.argv[1], "w"), indent=1)
PY
OUT="$(run_hook SessionStart)"; RC=$?
if [ "$RC" = "0" ] && printf '%s' "$OUT" | python3 -c '
import json, sys
o = json.load(sys.stdin)
sm = o.get("systemMessage") or ""
ac = (o.get("hookSpecificOutput") or {}).get("additionalContext") or ""
assert "MASSIVE ALERT" in sm, "systemMessage carries no alert"
assert sm == ac, "the two channels disagree"
assert sm.count("\n") > 3, "the block was flattened to a line"
' 2>/dev/null; then
    ok "D2  SessionStart emits the whole block on BOTH channels"
else
    bad "D2  the SessionStart payload is wrong (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -5
fi
if [ ! -s "$SANDBOX/err.txt" ]; then
    ok "D2b nothing is written to stderr, which reaches no channel"
else
    bad "D2b the hook wrote to stderr"
    sed 's/^/        /' "$SANDBOX/err.txt" | head -4
fi

# ---------------------------------------------------------------------------
# D3 / D4 — Stop is one line, and the line carries the facts
# ---------------------------------------------------------------------------
OUT="$(run_hook Stop)"; RC=$?
MSG="$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("systemMessage") or ""))
except Exception:
    print("")
' 2>/dev/null)"
if [ "$RC" = "0" ] && [ "$(printf '%s' "$MSG" | wc -l | tr -d ' ')" = "0" ] \
   && [ -n "$MSG" ]; then
    ok "D3  Stop emits exactly ONE line"
else
    bad "D3  the Stop message is empty or multi-line (rc=$RC)"
    printf '%s\n' "$MSG" | sed 's/^/        /' | head -6
fi
if printf '%s' "$MSG" | grep -q 'MASSIVE ALERT' \
   && printf '%s' "$MSG" | grep -q '/System/Volumes/Data' \
   && printf '%s' "$MSG" | grep -q 'free' \
   && printf '%s' "$MSG" | grep -q 'could not be deleted' \
   && printf '%s' "$MSG" | grep -q 'classification'; then
    ok "D4  the Stop line carries volume, free space, stuck paths, class"
else
    bad "D4  the Stop line is missing a fact"
    printf '%s\n' "$MSG" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# D5 — IT REPEATS. The second consecutive turn is the case that matters.
# ---------------------------------------------------------------------------
# Every other Stop notice in this engine de-duplicates and would be SILENT here.
sleep 1
OUT2="$(run_hook Stop)"
MSG2="$(printf '%s' "$OUT2" | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("systemMessage") or ""))
except Exception:
    print("")
' 2>/dev/null)"
if printf '%s' "$MSG2" | grep -q 'MASSIVE ALERT'; then
    ok "D5  the alert repeats on the NEXT turn while the condition holds"
else
    bad "D5  the alert went quiet on the second turn. The CEO asked for it to be"
    bad "     repeated every turn until the condition clears."
    printf '%s\n' "$MSG2" | sed 's/^/        /' | head -4
fi

# ---------------------------------------------------------------------------
# D6 — and it clears
# ---------------------------------------------------------------------------
write_cfg 1
rm -f "$FAILS"
sleep 1
OUT3="$(run_hook Stop)"
if ! printf '%s' "$OUT3" | grep -q 'MASSIVE ALERT'; then
    ok "D6  the alert stops the moment the condition clears"
else
    bad "D6  the alert persisted after the condition cleared"
    printf '%s\n' "$OUT3" | sed 's/^/        /' | head -4
fi

# ---------------------------------------------------------------------------
# D7 — it cannot be silenced by configuration
# ---------------------------------------------------------------------------
write_cfg 999999 0                                # unreachable floor, ENABLE=0
OUT="$(run_hook SessionStart)"
if printf '%s' "$OUT" | grep -q 'MASSIVE ALERT'; then
    ok "D7  DISK_WATCHDOG_ENABLE=0 does NOT silence the alert"
else
    bad "D7  the alert was silenced by configuration. An alert with an off"
    bad "     switch is not an alert."
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -4
fi
# THE CONTROL: the same flag DOES stand down a scheduled reading, so D7 is
# measuring the alert path specifically and not a flag that does nothing at all.
OUT="$(DISK_WATCHDOG_CONFIG="$CFG" DISK_WATCHDOG_LOG="$LOG" \
       RICHOS_LAUNCH_AGENTS_DIR="$LA" bash "$SCRIPTS/disk-watchdog.sh" --check 2>&1)"
if printf '%s' "$OUT" | grep -q 'STOOD DOWN'; then
    ok "D7b CONTROL: the same flag DOES stand down the scheduled reading"
else
    bad "D7b the flag stands nothing down, so D7 proves nothing"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -4
fi

# ---------------------------------------------------------------------------
# D8 — the hook never moves the drop baseline
# ---------------------------------------------------------------------------
write_cfg 999999
DISK_WATCHDOG_CONFIG="$CFG" DISK_WATCHDOG_LOG="$LOG" \
    RICHOS_LAUNCH_AGENTS_DIR="$LA" bash "$SCRIPTS/disk-watchdog.sh" --check >/dev/null 2>&1
SUM_BEFORE="$(python3 -c "
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$STATE")"
run_hook SessionStart >/dev/null 2>&1
run_hook Stop >/dev/null 2>&1
SUM_AFTER="$(python3 -c "
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$STATE")"
if [ "$SUM_BEFORE" = "$SUM_AFTER" ]; then
    ok "D8  the hook leaves the watchdog state byte-identical"
else
    bad "D8  the hook rewrote the state file and moved the drop baseline"
fi

# ---------------------------------------------------------------------------
# D9 — exit is always 0, even with everything broken
# ---------------------------------------------------------------------------
BAD_CFG="$SANDBOX/not-a-config"
RC=0
DISK_WATCHDOG_CONFIG="$BAD_CFG" CLAUDE_CONFIG_DIR="$LEDGER_DIR" \
    RICHOS_LAUNCH_AGENTS_DIR="$LA" bash "$HOOK" --event SessionStart >/dev/null 2>&1 || RC=$?
RC2=0
DISK_WATCHDOG_CONFIG="$BAD_CFG" CLAUDE_CONFIG_DIR="$LEDGER_DIR" \
    RICHOS_LAUNCH_AGENTS_DIR="$LA" bash "$HOOK" --event Stop </dev/null >/dev/null 2>&1 || RC2=$?
if [ "$RC" = "0" ] && [ "$RC2" = "0" ] ; then
    ok "D9  a missing config still exits 0 on both events"
else
    bad "D9  the hook exited non-zero (SessionStart=$RC Stop=$RC2)"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
