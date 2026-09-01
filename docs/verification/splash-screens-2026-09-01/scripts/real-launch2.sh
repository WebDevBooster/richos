#!/usr/bin/env bash
#
# THE REAL THING, photographed. Launch the built RichOS.app the way LaunchServices launches
# it — `open`, so cwd=/ — three times, quitting cleanly between each, and photograph the
# app's OWN WINDOW by CGWindowID rather than capturing the CEO's display.
#
# Then a fourth launch, watched for twenty seconds past the three-second hold, one frame a
# second, to prove the animation does not come back.
#
# The launch ledger is moved aside first and put back at the end, so this runs against a
# fresh-install state and leaves his own record exactly as it found it.
set -uo pipefail

S=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
APP="/Users/alex/ab/richos-wt/echo-opus-sp1/app/src-tauri/target/release/bundle/macos/RichOS.app"
BIN="$APP/Contents/MacOS/richos-tauri"
OUT="$S/real"
PY="$S/qz-venv/bin/python"
LEDGER="$HOME/Library/Application Support/com.richos.app/launches.json"
BACKUP="$S/launches.json.backup2"

rm -rf "$OUT"; mkdir -p "$OUT"
echo "residue BEFORE: $(pgrep -f "$BIN" 2>/dev/null | wc -l | tr -d ' ')"

cleanup() {
  /usr/bin/pkill -9 -f "$BIN" 2>/dev/null
  /bin/sleep 1
  if [ -f "$BACKUP" ]; then cp "$BACKUP" "$LEDGER"; else rm -f "$LEDGER"; fi
  echo "residue AFTER cleanup: $(pgrep -f "$BIN" 2>/dev/null | wc -l | tr -d ' ')"
}
trap cleanup EXIT

if [ -f "$LEDGER" ]; then cp "$LEDGER" "$BACKUP"; echo "ledger backed up ($(wc -c < "$LEDGER" | tr -d ' ') bytes)"; fi
rm -f "$LEDGER"

wid_of () {  # wid_of <pid>
  "$PY" "$S/window-id.py" "$1" 2>/dev/null | awk -F'\t' '$2=="RichOS" && $5=="layer=0" {print $1; exit}'
}

grab () {  # grab <wid> <file>
  /usr/sbin/screencapture -x -o -l "$1" "$2" 2>/dev/null
  [ -s "$2" ] || echo "  (no frame for $(basename "$2"))"
}

ordinal () { "$PY" -c "import json;print(len(json.load(open('$LEDGER'))['starts']))" 2>/dev/null || echo '?'; }
ring ()    { "$PY" -c "import json;print(json.load(open('$LEDGER'))['recent_splashes'])" 2>/dev/null || echo '?'; }

quit_app () {
  /usr/bin/osascript -e 'tell application "RichOS" to quit' >/dev/null 2>&1
  for _ in $(seq 1 40); do pgrep -f "$BIN" >/dev/null || return 0; /bin/sleep 0.25; done
  return 1
}

for n in 1 2 3; do
  echo
  echo "---- LAUNCH $n ----"
  T0=$(/bin/date +%s.%N)
  open "$APP"
  # find the process and its window as soon as they exist
  WID=""; PID=""
  for _ in $(seq 1 60); do
    PID=$(pgrep -f "$BIN" | head -1)
    [ -n "$PID" ] && WID=$(wid_of "$PID")
    [ -n "$WID" ] && break
    /bin/sleep 0.1
  done
  echo "  pid=$PID  window=$WID  (found $(echo "$(/bin/date +%s.%N) - $T0" | bc | cut -c1-5)s after open)"
  /bin/sleep 1.0;  grab "$WID" "$OUT/launch-$n-a-mid.png"
  /bin/sleep 1.1;  grab "$WID" "$OUT/launch-$n-b-nearly.png"
  /bin/sleep 1.2;  grab "$WID" "$OUT/launch-$n-c-landed.png"
  /bin/sleep 1.5;  grab "$WID" "$OUT/launch-$n-d-handed-off.png"
  echo "  ledger: start #$(ordinal), ring $(ring)"
  quit_app && echo "  quit cleanly" || { echo "  DID NOT QUIT — killing"; pkill -f "$BIN"; /bin/sleep 1; }
done

echo
echo "---- LAUNCH 4: the no-loop watch ----"
open "$APP"
WID=""; PID=""
for _ in $(seq 1 60); do
  PID=$(pgrep -f "$BIN" | head -1)
  [ -n "$PID" ] && WID=$(wid_of "$PID")
  [ -n "$WID" ] && break
  /bin/sleep 0.1
done
echo "  pid=$PID  window=$WID"
for i in $(seq 1 20); do
  /bin/sleep 1
  grab "$WID" "$OUT/noloop-$(printf '%02d' "$i")s.png"
done
echo "  watched 20s; $(ls "$OUT"/noloop-*.png 2>/dev/null | wc -l | tr -d ' ') frames captured"
echo "  ledger: start #$(ordinal), ring $(ring)"
quit_app && echo "  quit cleanly" || { echo "  DID NOT QUIT — killing"; pkill -f "$BIN"; /bin/sleep 1; }

echo
echo "== final ledger =="
"$PY" -c "
import json
d=json.load(open('$LEDGER'))
print('starts', len(d['starts']), ' ring(newest first)', d['recent_splashes'], ' open_run', d['open_run'])
" 2>/dev/null || echo "(unreadable)"
