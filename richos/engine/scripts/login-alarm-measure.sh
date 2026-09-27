#!/usr/bin/env bash
#
# login-alarm-measure.sh — HOW LONG, UNDER THE REAL launchd, FROM A DEAD LOGIN
#                          TO THE CEO'S NOTIFICATION.
#
# The bound is his: told "within a minute". A suite with a fake clock proves the
# logic; only launchd itself can say how long its StartInterval really takes. So
# this schedules a SECOND, sandboxed copy of the alarm (its own label, its own
# scratch transcripts, a stand-in `security` that prints an attribute, a
# recorder in place of osascript, a scratch escalation ledger), writes a
# simulated "Login expired" row at a random phase of the interval, and times the
# recorder. Then it plays his /login (the stand-in item's write time moves) and
# checks the episode closes. It never touches the real login, the real
# transcripts, the real keychain or the real ledger, and it removes its own
# launchd job and scratch however it ends.
#
#   login-alarm-measure.sh [--trials N] [--real-notification]
#
#   --real-notification  in the first trial ALSO post one macOS notification
#                        through osascript, titled "RichOS alarm test" and saying
#                        nothing is wrong, to prove the channel from launchd.
#                        osascript's exit 0 proves submission to Notification
#                        Center, not that a person saw it.
#
# Prints one line per trial: the delay in seconds.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALARM="$SCRIPT_DIR/login-alarm.sh"
TRIALS=3; REAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --trials) TRIALS="${2:-3}"; shift ;;
        --real-notification) REAL=1 ;;
        *) echo "usage: login-alarm-measure.sh [--trials N] [--real-notification]" >&2; exit 2 ;;
    esac
    shift
done
command -v launchctl >/dev/null 2>&1 || { echo "login-alarm-measure: launchd only (macOS)" >&2; exit 2; }

# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"
D="$(scratch_new login-alarm-measure)" || { echo "login-alarm-measure: no scratch" >&2; exit 2; }
LABEL="com.richos.login-alarm-measure.$$"
PLIST="$D/$LABEL.plist"
_domain="gui/$(id -u)"
cleanup() {
    launchctl bootout "$_domain/$LABEL" >/dev/null 2>&1 || true
    scratch_release "$D" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$D/projects/-measure" "$D/state"
python3 -c 'import time;print(time.strftime("%Y%m%d%H%M%S",time.gmtime(time.time()-7200)))' >"$D/mdat"
cat >"$D/security" <<'SH'
#!/bin/sh
printf '    "mdat"<timedate>=0x00  "%sZ\\000"\n' "$(cat "$(dirname "$0")/mdat")"
SH
cat >"$D/notify" <<'SH'
#!/bin/sh
d="$(dirname "$0")"
python3 -c 'import time,sys;print("%.3f %s|%s" % (time.time(), sys.argv[1], sys.argv[2]))' "$1" "$2" >>"$d/notified"
if [ -f "$d/real-once" ]; then
  rm -f "$d/real-once"
  if /usr/bin/osascript -e 'display notification "Test of the new Claude login alarm. Nothing is wrong; no action needed." with title "RichOS alarm test"'; then
    echo "osascript exit 0" >>"$d/notified-real"
  else
    echo "osascript exit $?" >>"$d/notified-real"
  fi
fi
SH
chmod +x "$D/security" "$D/notify"
[ "$REAL" -eq 1 ] && touch "$D/real-once"

cat >"$PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ALARM</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>LOGIN_ALARM_PROJECTS_DIR</key><string>$D/projects</string>
    <key>LOGIN_ALARM_STATE</key><string>$D/state/login-alarm.json</string>
    <key>LOGIN_ALARM_SECURITY</key><string>$D/security</string>
    <key>LOGIN_ALARM_NOTIFY_CMD</key><string>$D/notify</string>
    <key>RICHOS_ESCALATION_LEDGER</key><string>$D/escalations.jsonl</string>
  </dict>
  <key>StartInterval</key><integer>${LOGIN_ALARM_SECONDS:-30}</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$D/launchd.log</string>
  <key>StandardErrorPath</key><string>$D/launchd.log</string>
</dict></plist>
P
launchctl bootstrap "$_domain" "$PLIST" || { echo "login-alarm-measure: launchctl bootstrap failed" >&2; exit 2; }
for _ in $(seq 1 30); do [ -f "$D/state/login-alarm.json" ] && break; sleep 1; done
[ -f "$D/state/login-alarm.json" ] || { echo "login-alarm-measure: the scheduled job never ran" >&2; exit 2; }

RC=0
for trial in $(seq 1 "$TRIALS"); do
    sleep $(( RANDOM % 30 ))           # a random phase of the 30 s interval
    before="$(cat "$D/notified" 2>/dev/null | wc -l | tr -d ' ')"
    T0="$(python3 - "$D/projects/-measure/sess.jsonl" <<'PY'
import json, sys, time
t = time.time()
ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)
row = {"type": "assistant", "timestamp": ts, "isApiErrorMessage": True, "error": "authentication_failed",
       "message": {"model": "<synthetic>", "role": "assistant",
                   "content": [{"type": "text", "text": "Login expired · Please run /login"}]}}
open(sys.argv[1], "a").write(json.dumps(row) + "\n")
print("%.3f" % t)
PY
)"
    got=""
    for _ in $(seq 1 120); do
        n="$(cat "$D/notified" 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$n" -gt "$before" ]; then got="$(tail -1 "$D/notified")"; break; fi
        sleep 1
    done
    if [ -n "$got" ]; then
        python3 -c 'import sys;print("trial %s: simulated failure %.3f, CEO notification %.3f: %.1f s" % (sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[3]) - float(sys.argv[2])))' \
            "$trial" "$T0" "${got%% *}"
    else
        echo "trial $trial: NO NOTIFICATION within 120 s"; RC=1
    fi
    # His /login: the stand-in item is rewritten; the next tick must close the episode.
    sleep 2
    python3 -c 'import time;print(time.strftime("%Y%m%d%H%M%S",time.gmtime(time.time()+1)))' >"$D/mdat"
    for _ in $(seq 1 70); do
        [ "$(grep -c LOGIN-RENEWED "$D/launchd.log" 2>/dev/null || true)" -ge "$trial" ] && break
        sleep 1
    done
    closed="$(grep -c LOGIN-RENEWED "$D/launchd.log" 2>/dev/null || true)"
    [ "${closed:-0}" -ge "$trial" ] || { echo "trial $trial: the episode did NOT close after the simulated /login"; RC=1; }
    sleep 3
done

echo "notifications: $(cat "$D/notified" 2>/dev/null | wc -l | tr -d ' ') for $TRIALS failures (one per expiry)"
echo "escalations: $(grep -c '"event": "Escalation"' "$D/escalations.jsonl" 2>/dev/null || true) raised, $(grep -c '"event": "EscalationAck"' "$D/escalations.jsonl" 2>/dev/null || true) closed by the simulated /login"
[ "$REAL" -eq 1 ] && echo "real notification: $(cat "$D/notified-real" 2>/dev/null || echo 'not posted')"
exit "$RC"
