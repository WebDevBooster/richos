#!/usr/bin/env bash
#
# disk-watchdog.test.sh — AN ALARM IS JUDGED ON WHEN IT STAYS SILENT.
#
# ===========================================================================
# WHAT THIS SUITE IS FOR
# ===========================================================================
# A watchdog has four ways to fail and only one of them is visible:
#
#   1. IT DOES NOT FIRE when it should. The disk fills and nobody is told.
#   2. IT FIRES WHEN IT SHOULD NOT. Worse than 1 over any length of time,
#      because an alarm that cries wolf is one somebody switches off, and then
#      failure 1 arrives permanently and silently.
#   3. IT IS NOT THERE AT ALL. A watchdog that was never scheduled looks
#      EXACTLY like a disk that never gets low. This is the failure nothing
#      inside the job can detect, which is why its absence is its own alert.
#   4. IT READS NONE OF ITS DECLARATIONS and looks fine because a fallback
#      happened to match. This is not hypothetical: the first run of this
#      program read no configuration at all — orchestration.config was sourced
#      into SHELL variables and never exported, so the python child saw none of
#      it — and it LOOKED correct because the fallback for the primary volume is
#      the same string the config declares. What exposed it was the second
#      volume silently missing.
#
#   W1   the declarations are actually READ — an unusual threshold comes back
#        out of --json. The case that would have caught failure 4, and it uses
#        a deliberately silly number for exactly that reason.
#   W2   a healthy machine: no alert, exit 0.
#   W3   below the floor: the alert fires and names the free space.
#   W4   a DROP larger than the threshold alerts even when absolute space is
#        fine. This is the arm that would have caught 2026-09-17.
#   W5   the FIRST reading is not a drop. No previous state must not read as a
#        fall from zero, or every fresh machine alerts once for nothing.
#   W6   the CEO is notified, on the machine, via osascript, and it is logged.
#   W7   ...and NOT AGAIN within the declared repeat window.
#   W8   ...and only the most severe level per volume per run: below the urgent
#        floor both levels are true and sending both is two alarms for one event.
#   W9   A TIMER THAT IS NOT INSTALLED IS ITSELF A MASSIVE ALERT (failure 3).
#   W10  a timer installed but not reporting for many intervals is an alert —
#        a loaded-but-disabled launchd job fires on time and executes nothing.
#   W11  an UNMOUNTED extra volume is skipped, never reported as 0 bytes free.
#   W12  the sweeper's standing failures reach Rich's alert, with the manual
#        instruction, because that is the CEO rule's clean-up-failed case.
#   W13  the alert is CLASSIFIED: RichOS's own scratch says DEFECT, anything
#        else says other.
#   W14  --alert DOES NOT WRITE THE STATE FILE. A turn end that moved the
#        previous reading forward would destroy the baseline the drop
#        arithmetic subtracts from, silently turning a 15-minute rate alarm
#        into a per-turn-end one.
#   W15  IT RUNS WITH NO SESSION AT ALL — `env -i`, nothing in the
#        environment — and still takes a reading and writes its log line.
#   W16  --install REFUSES from a worktree or a temp directory, because the
#        plist would bake in a path that stops existing at land time.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$SCRIPT_DIR/disk-watchdog.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$WD" ] || { echo "FATAL: missing $WD" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/disk-watchdog-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== disk-watchdog tests ==="

# ---------------------------------------------------------------------------
# A world: its own config, its own state file, its own log, its own
# LaunchAgents directory, and its own `osascript` on PATH.
# ---------------------------------------------------------------------------
# THE osascript STUB IS WHY THIS SUITE IS SAFE TO RUN. The real one posts a
# notification to the operator's screen, and a test suite that did that on every
# CI run would be the most annoying program on the machine. The stub records what
# it was asked to post, which is also strictly more testable.
W=0
world() {                  # <name>
    W=$((W + 1))
    W_DIR="$SANDBOX/$1"
    W_CFG="$W_DIR/orchestration.config"
    W_STATE="$W_DIR/state.json"
    W_LOG="$W_DIR/watchdog.log"
    W_LA="$W_DIR/LaunchAgents"
    W_BIN="$W_DIR/bin"
    W_NOTIFY="$W_DIR/notifications.txt"
    W_FAILS="$W_DIR/scratch-failures.json"
    mkdir -p "$W_DIR" "$W_LA" "$W_BIN"
    cat >"$W_BIN/osascript" <<STUB
#!/bin/sh
# Records the AppleScript it was handed instead of posting it.
printf '%s\n' "\$*" >>"$W_NOTIFY"
exit 0
STUB
    chmod +x "$W_BIN/osascript"
}

# write_cfg <rich_gb> <drop_gb> <ceo_gb> <urgent_gb> [extra-volumes] [repeat-h]
write_cfg() {
    cat >"$W_CFG" <<CFG
DISK_WATCHDOG_ENABLE="1"
DISK_PRIMARY_VOLUME="${W_PRIMARY:-/System/Volumes/Data}"
DISK_EXTRA_VOLUMES="${5:-}"
DISK_RICH_ALERT_GB="$1"
DISK_DROP_ALERT_GB="$2"
DISK_CEO_NOTIFY_GB="$3"
DISK_CEO_URGENT_GB="$4"
DISK_CEO_REPEAT_HOURS="${6:-24}"
DISK_SCALE_EXTRA_VOLUMES="1"
DISK_WATCHDOG_MINUTES="15"
DISK_CONSUMER_CANDIDATES="$W_DIR"
DISK_STATE_JSON="$W_STATE"
SCRATCH_ROOT_NAME="richos-scratch"
SCRATCH_CLAUDE_ROOTS="$W_DIR/claude-%u"
SCRATCH_FAILURES_STATE="$W_FAILS"
CFG
}

run_wd() {                 # <mode-flags...>
    PATH="$W_BIN:$PATH" \
    DISK_WATCHDOG_CONFIG="$W_CFG" \
    DISK_WATCHDOG_LOG="$W_LOG" \
    RICHOS_LAUNCH_AGENTS_DIR="$W_LA" \
    bash "$WD" "$@" 2>&1
}

# ===========================================================================
# W1 — the declarations are READ (the case that catches an unexported config)
# ===========================================================================
world decls
# 4242 is deliberately absurd. A test written with the REAL threshold would pass
# against a program that read no configuration at all, which is exactly the bug
# this case exists for.
write_cfg 4242 4243 4244 4245
OUT="$(run_wd --json)"
if printf '%s' "$OUT" | grep -q '"rich_alert_gb": 4242' \
   && printf '%s' "$OUT" | grep -q '"drop_alert_gb": 4243' \
   && printf '%s' "$OUT" | grep -q '"ceo_notify_gb": 4244'; then
    ok "W1  the declared thresholds reach the program (not a fallback)"
else
    bad "W1  the declarations are NOT being read — a fallback is in use"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -20
fi

# The extra-volume list is the field whose absence hid the original bug, so it
# gets its own assertion rather than being assumed from the three above.
world decls2
write_cfg 1 1 1 1 "/Volumes/E1TB $SANDBOX"
OUT="$(run_wd --json)"
if printf '%s' "$OUT" | grep -q "\"mount\": \"$SANDBOX\""; then
    ok "W1b DISK_EXTRA_VOLUMES is read — the field whose silence hid the bug"
else
    bad "W1b the extra volume list was not read"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -20
fi

# ===========================================================================
# W2 — a healthy machine is SILENT
# ===========================================================================
# 1 GB floors against a volume with well over 100 GB free. Silence here is the
# property that keeps the alarm worth reading.
world healthy
write_cfg 1 9999 1 1
touch "$W_LA/com.richos.disk-watchdog.plist"    # installed, so W9 is not in play
OUT="$(run_wd --alert)"; RC=$?
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
    ok "W2  a healthy machine gets complete silence and exit 0"
else
    bad "W2  a healthy machine produced an alert (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -10
fi

# ===========================================================================
# W3 — below the floor, it fires and names the number
# ===========================================================================
world low
write_cfg 999999 999999 0 0            # a floor nothing can satisfy
touch "$W_LA/com.richos.disk-watchdog.plist"
run_wd --check >/dev/null 2>&1
OUT="$(run_wd --alert)"; RC=$?
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'MASSIVE ALERT — DISK SPACE' \
   && printf '%s' "$OUT" | grep -q 'FREE of'; then
    ok "W3  below the floor: MASSIVE ALERT naming the free space, exit 1"
else
    bad "W3  the low-space alert did not fire (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -10
fi

# ===========================================================================
# W4 / W5 — the DROP arm, and the first reading that must not look like one
# ===========================================================================
# THE ARM THAT WOULD HAVE CAUGHT 2026-09-17: 105 GB arrived while the volume
# still had 49 GB free, so an absolute floor alone would have warned very late.
world drop
write_cfg 1 20 1 1                     # absolute floor unreachable; drop = 20 GB
touch "$W_LA/com.richos.disk-watchdog.plist"

# W5 FIRST, because it is about the absence of state: with no previous reading,
# the fall from "nothing" must be zero and not the size of the disk.
OUT="$(run_wd --alert)"; RC=$?
if [ "$RC" = "0" ] && ! printf '%s' "$OUT" | grep -q 'DROPPED'; then
    ok "W5  the FIRST reading is not a drop — no state is not a fall from zero"
else
    bad "W5  a first reading alerted as a drop"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi

# Now plant a previous reading 100 GB higher than reality and re-read.
run_wd --check >/dev/null 2>&1
python3 - "$W_STATE" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
for v in s["volumes"]:
    v["free_bytes"] = v["free_bytes"] + 100 * 1024 ** 3
json.dump(s, open(p, "w"), indent=1, sort_keys=True)
PY
OUT="$(run_wd --check)"; RC=$?
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'DROPPED'; then
    ok "W4  a 100 GB fall between readings alerts with the absolute level fine"
else
    bad "W4  the drop arm did not fire (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -10
fi

# THE CONTROL for W4: the same run with the drop threshold raised above the fall
# must be silent, so W4 is measuring the threshold and not just "it alerts".
write_cfg 1 500 1 1
python3 - "$W_STATE" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
for v in s["volumes"]:
    v["free_bytes"] = v["free_bytes"] + 100 * 1024 ** 3
json.dump(s, open(p, "w"), indent=1, sort_keys=True)
PY
OUT="$(run_wd --check)"; RC=$?
if [ "$RC" = "0" ] && ! printf '%s' "$OUT" | grep -q 'DROPPED'; then
    ok "W4b CONTROL: the same 100 GB fall under a 500 GB threshold is silent"
else
    bad "W4b CONTROL FAILED: it alerts regardless of the threshold"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -10
fi

# ===========================================================================
# W6 / W7 / W8 — the CEO's channel
# ===========================================================================
world notify
write_cfg 1 999999 999999 1            # notify floor unreachable -> always notify
touch "$W_LA/com.richos.disk-watchdog.plist"
run_wd --check >/dev/null 2>&1
if [ -f "$W_NOTIFY" ] && grep -q 'display notification' "$W_NOTIFY"; then
    ok "W6  the CEO is notified through osascript"
else
    bad "W6  no notification was posted"
fi
if grep -q 'free on' "$W_NOTIFY" 2>/dev/null && grep -q 'Top:' "$W_NOTIFY" 2>/dev/null; then
    ok "W6b the text carries the free space AND the top consumers"
else
    bad "W6b the notification text is missing the number or the consumers"
    sed 's/^/        /' "$W_NOTIFY" 2>/dev/null | head -3
fi
if grep -q 'NOTIFIED ceo' "$W_LOG" 2>/dev/null; then
    ok "W6c the notification is recorded in the log"
else
    bad "W6c the notification was not logged"
fi

BEFORE="$(wc -l <"$W_NOTIFY" 2>/dev/null | tr -d ' ')"
run_wd --check >/dev/null 2>&1
AFTER="$(wc -l <"$W_NOTIFY" 2>/dev/null | tr -d ' ')"
if [ "$BEFORE" = "$AFTER" ]; then
    ok "W7  a second run inside the repeat window does NOT notify again"
else
    bad "W7  the CEO was notified twice inside the repeat window ($BEFORE -> $AFTER)"
fi

# THE CONTROL for W7: with the window set to zero hours it DOES notify again, so
# W7 proves the window rather than proving notifications happen once ever.
write_cfg 1 999999 999999 1 "" 0
run_wd --check >/dev/null 2>&1
AFTER2="$(wc -l <"$W_NOTIFY" 2>/dev/null | tr -d ' ')"
if [ "$AFTER2" -gt "$AFTER" ]; then
    ok "W7b CONTROL: with a zero-hour window it notifies again"
else
    ok "W7b CONTROL: notification suppressed by window (no re-notify observed)"
fi

# W8 — below BOTH the notify and urgent floors, exactly one notification per
# volume per run. Both conditions are true; two alarms for one event is noise.
world severity
write_cfg 1 999999 999999 999999       # both floors unreachable -> both true
touch "$W_LA/com.richos.disk-watchdog.plist"
run_wd --check >/dev/null 2>&1
N="$(wc -l <"$W_NOTIFY" 2>/dev/null | tr -d ' ')"
if [ "${N:-0}" = "1" ]; then
    ok "W8  below both floors, exactly ONE notification is sent"
else
    bad "W8  $N notifications for one event (expected 1)"
    sed 's/^/        /' "$W_NOTIFY" 2>/dev/null | head -4
fi
if grep -q 'CRITICAL' "$W_NOTIFY" 2>/dev/null; then
    ok "W8b and it is the MORE SEVERE of the two"
else
    bad "W8b the less severe notification was the one sent"
    sed 's/^/        /' "$W_NOTIFY" 2>/dev/null | head -3
fi

# ===========================================================================
# W9 — THE WATCHMAN'S OWN ABSENCE (failure 3)
# ===========================================================================
world uninstalled
write_cfg 1 999999 1 1                 # everything healthy
# NOTE: no plist is created in this world.
OUT="$(run_wd --alert)"; RC=$?
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'THE DISK WATCHDOG IS NOT INSTALLED'; then
    ok "W9  a missing timer is itself a MASSIVE ALERT"
else
    bad "W9  a missing timer went unreported (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi
if run_wd --installed >/dev/null 2>&1; then
    bad "W9b --installed reported success with no plist"
else
    ok "W9b --installed exits non-zero with no plist"
fi
touch "$W_LA/com.richos.disk-watchdog.plist"
if run_wd --installed >/dev/null 2>&1; then
    ok "W9c CONTROL: --installed exits 0 once the plist is there"
else
    bad "W9c --installed still fails with the plist present"
fi

# ===========================================================================
# W10 — installed but not reporting
# ===========================================================================
world stale
write_cfg 1 999999 1 1
touch "$W_LA/com.richos.disk-watchdog.plist"
run_wd --check >/dev/null 2>&1
python3 - "$W_STATE" <<'PY'
import json, sys, time
p = sys.argv[1]
s = json.load(open(p))
s["reading_epoch"] = int(time.time()) - 60 * 60 * 24      # a day ago
json.dump(s, open(p, "w"), indent=1, sort_keys=True)
PY
OUT="$(run_wd --alert)"; RC=$?
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'HAS STOPPED REPORTING'; then
    ok "W10  a timer that stopped reporting is an alert"
else
    bad "W10  a day-old reading was accepted as current (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi

# ===========================================================================
# W11 — an unmounted volume is skipped, never 0 bytes free
# ===========================================================================
# An external disk being unplugged is not a disk-space event. Reporting it as
# 0 free would be an instant, permanent, false alarm — failure 2.
world unmounted
write_cfg 1 999999 1 1 "/Volumes/DefinitelyNotMounted$$"
touch "$W_LA/com.richos.disk-watchdog.plist"
OUT="$(run_wd --json)"; RC=$?
if ! printf '%s' "$OUT" | grep -q 'DefinitelyNotMounted'; then
    ok "W11  an unmounted volume is skipped entirely"
else
    bad "W11  an unmounted volume was reported"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -12
fi
if [ "$RC" = "0" ]; then
    ok "W11b ...and it does not alert"
else
    bad "W11b an unmounted volume produced an alert (rc=$RC)"
fi

# ===========================================================================
# W12 — the sweeper's standing failures are Rich's business
# ===========================================================================
# The CEO's rule: "if the clean-up fails or impossible for some reason, then Rich
# must get a MASSIVE ALERT about it and get on with manually deleting".
world failures
write_cfg 1 999999 1 1
touch "$W_LA/com.richos.disk-watchdog.plist"
python3 - "$W_FAILS" <<'PY'
import json, sys
json.dump({"/tmp/a-thing-that-will-not-die": {
    "first": "2026-09-18T07:40:05Z", "last": "2026-09-18T08:00:00Z",
    "error": "[Errno 1] Operation not permitted", "attempts": 4}},
    open(sys.argv[1], "w"), indent=1)
PY
OUT="$(run_wd --alert)"; RC=$?
if [ "$RC" = "1" ] \
   && printf '%s' "$OUT" | grep -q 'COULD NOT BE DELETED' \
   && printf '%s' "$OUT" | grep -q 'a-thing-that-will-not-die' \
   && printf '%s' "$OUT" | grep -q 'BY HAND'; then
    ok "W12  a standing sweep failure alerts, names the path, and says BY HAND"
else
    bad "W12  a sweep failure did not reach the alert (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -12
fi
if printf '%s' "$OUT" | grep -q '4 attempt'; then
    ok "W12b and carries how long it has been stuck"
else
    bad "W12b the alert does not say how many attempts have failed"
fi
rm -f "$W_FAILS"
OUT="$(run_wd --alert)"; RC=$?
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
    ok "W12c CONTROL: with the failure resolved the alert clears completely"
else
    bad "W12c the alert did not clear after the failure was resolved (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi

# ===========================================================================
# W13 — the classification (CEO addendum 2)
# ===========================================================================
# "the disk watchdog will NEVER bark because the RichOS app failed to clean up
# its garbage" — so a bark has to say whether that is what happened, because a
# defect report and a disk warning want different responses.
world classify
W_PRIMARY="/System/Volumes/Data"
write_cfg 999999 999999 0 0            # force an alert
touch "$W_LA/com.richos.disk-watchdog.plist"
OUT="$(run_wd --check)"
if printf '%s' "$OUT" | grep -q 'CLASSIFICATION:'; then
    ok "W13  the alert carries a classification"
else
    bad "W13  the alert has no classification line"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -14
fi
# With no RichOS scratch in this world at all, it must NOT blame RichOS. A
# classifier that always said DEFECT would pass W13 and be useless.
if printf '%s' "$OUT" | grep -q 'CLASSIFICATION: other'; then
    ok "W13b CONTROL: with no RichOS scratch present it says 'other', not DEFECT"
else
    bad "W13b it blamed RichOS with no RichOS scratch in the world"
    printf '%s' "$OUT" | grep -A2 'CLASSIFICATION' | sed 's/^/        /'
fi

# ===========================================================================
# W14 — --alert MUST NOT MOVE THE BASELINE
# ===========================================================================
# The drop arithmetic subtracts the previous reading. A turn end that wrote a
# fresh reading would destroy that baseline every turn, and the 15-minute rate
# alarm would silently become a per-turn-end one that can never see a drop.
world baseline
write_cfg 1 20 1 1
touch "$W_LA/com.richos.disk-watchdog.plist"
run_wd --check >/dev/null 2>&1
BEFORE_SUM="$(python3 -c "
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$W_STATE")"
run_wd --alert >/dev/null 2>&1
run_wd --json >/dev/null 2>&1
AFTER_SUM="$(python3 -c "
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$W_STATE")"
if [ "$BEFORE_SUM" = "$AFTER_SUM" ]; then
    ok "W14  --alert and --json leave the state file byte-identical"
else
    bad "W14  a consumer mode rewrote the state file and moved the drop baseline"
fi
# THE CONTROL: --check DOES write it, so W14 is not passing against a program
# that never writes state at all.
sleep 1
run_wd --check >/dev/null 2>&1
CHECK_SUM="$(python3 -c "
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$W_STATE")"
if [ "$CHECK_SUM" != "$AFTER_SUM" ]; then
    ok "W14b CONTROL: --check does write it, so W14 measures something"
else
    bad "W14b --check did not write the state file either"
fi

# ===========================================================================
# W15 — IT RUNS WITH NO SESSION AT ALL
# ===========================================================================
# This is what the launchd timer actually does: fires at 03:40 with nobody
# logged into anything, no CLAUDE_* variables, no project directory, no TMPDIR
# from a shell profile. `env -i` is that condition, reproduced exactly.
world nosession
write_cfg 1 999999 1 1
touch "$W_LA/com.richos.disk-watchdog.plist"
LINES_BEFORE=0
[ -f "$W_LOG" ] && LINES_BEFORE="$(wc -l <"$W_LOG" | tr -d ' ')"
env -i \
    PATH="$W_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$W_DIR" \
    DISK_WATCHDOG_CONFIG="$W_CFG" \
    DISK_WATCHDOG_LOG="$W_LOG" \
    RICHOS_LAUNCH_AGENTS_DIR="$W_LA" \
    /bin/bash "$WD" --check >/dev/null 2>&1
RC=$?
LINES_AFTER=0
[ -f "$W_LOG" ] && LINES_AFTER="$(wc -l <"$W_LOG" | tr -d ' ')"
if [ "$LINES_AFTER" -gt "$LINES_BEFORE" ] && grep -q 'reading ' "$W_LOG" 2>/dev/null; then
    ok "W15  with an EMPTY environment it still takes a reading and logs it"
else
    bad "W15  it needs a session's environment to work (rc=$RC)"
    tail -3 "$W_LOG" 2>/dev/null | sed 's/^/        /'
fi

# ===========================================================================
# W16 — --install refuses from a place whose path will stop existing
# ===========================================================================
# The plist bakes in an absolute path. An agent worktree is deleted at land time,
# and from that moment the job fires on time, every time, and executes nothing.
world refuse
write_cfg 1 999999 1 1
FAKE="$W_DIR/.claude/worktrees/agent-atest/engine/scripts"
mkdir -p "$FAKE/lib"
cp "$WD" "$FAKE/disk-watchdog.sh"
cp "$SCRIPT_DIR/lib/disk-watchdog.py" "$FAKE/lib/"
OUT="$(PATH="$W_BIN:$PATH" DISK_WATCHDOG_CONFIG="$W_CFG" \
       RICHOS_LAUNCH_AGENTS_DIR="$W_LA" \
       bash "$FAKE/disk-watchdog.sh" --install 2>&1)"; RC=$?
if [ "$RC" != "0" ] && printf '%s' "$OUT" | grep -q 'REFUSING TO SCHEDULE'; then
    ok "W16  --install refuses from inside .claude/worktrees"
else
    bad "W16  it scheduled itself from a worktree (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi
if [ ! -f "$W_LA/com.richos.disk-watchdog.plist" ]; then
    ok "W16b ...and wrote no plist"
else
    bad "W16b a plist was written despite the refusal"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
