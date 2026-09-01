#!/usr/bin/env bash
#
# Film ONE real launch at 4 Hz, with the app explicitly activated so its window is
# compositing, and keep only the frames that actually differ. The first attempt captured
# identical bytes four times in a row, which is what an occluded window's backing store
# gives you; this one proves whether the frames are moving before it reports anything.
set -uo pipefail

S=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
APP="/Users/alex/ab/richos-wt/echo-opus-sp1/app/src-tauri/target/release/bundle/macos/RichOS.app"
BIN="$APP/Contents/MacOS/richos-tauri"
OUT="$S/film"
PY="$S/qz-venv/bin/python"
LEDGER="$HOME/Library/Application Support/com.richos.app/launches.json"
BACKUP="$S/launches.json.backup3"

rm -rf "$OUT"; mkdir -p "$OUT"
echo "residue BEFORE: $(pgrep -f "$BIN" 2>/dev/null | wc -l | tr -d ' ')"
cleanup() {
  /usr/bin/pkill -9 -f "$BIN" 2>/dev/null; /bin/sleep 1
  if [ -f "$BACKUP" ]; then cp "$BACKUP" "$LEDGER"; else rm -f "$LEDGER"; fi
  echo "residue AFTER cleanup: $(pgrep -f "$BIN" 2>/dev/null | wc -l | tr -d ' ')"
}
trap cleanup EXIT
[ -f "$LEDGER" ] && cp "$LEDGER" "$BACKUP"
rm -f "$LEDGER"

WHICH="${1:-1}"   # 1 = first start (#1), 2 = second start (#2)
if [ "$WHICH" = "2" ]; then
  # burn one clean start so the next one is start 2
  open "$APP"; /bin/sleep 6
  /usr/bin/osascript -e 'tell application "RichOS" to quit' >/dev/null 2>&1
  for _ in $(seq 1 40); do pgrep -f "$BIN" >/dev/null || break; /bin/sleep 0.25; done
fi

open -F "$APP"
PID=""; WID=""
for _ in $(seq 1 80); do
  PID=$(pgrep -f "$BIN" | head -1)
  [ -n "$PID" ] && WID=$("$PY" "$S/window-id.py" "$PID" 2>/dev/null | awk -F'\t' '$2=="RichOS" && $5=="layer=0"{print $1;exit}')
  [ -n "$WID" ] && break
  /bin/sleep 0.05
done
/usr/bin/osascript -e 'tell application "RichOS" to activate' >/dev/null 2>&1
echo "pid=$PID wid=$WID"

for i in $(seq 0 35); do
  /usr/sbin/screencapture -x -o -l "$WID" "$OUT/f$(printf '%02d' "$i").png" 2>/dev/null
  /bin/sleep 0.25
done

echo "--- distinct frames (md5, in order) ---"
prev=""
for f in "$OUT"/f*.png; do
  h=$(md5 -q "$f")
  if [ "$h" != "$prev" ]; then echo "  $(basename "$f")  $h"; prev="$h"; fi
done
echo "captured $(ls "$OUT"/f*.png | wc -l | tr -d ' ') frames, $(md5 -q "$OUT"/f*.png | sort -u | wc -l | tr -d ' ') distinct"
"$PY" -c "import json;d=json.load(open('$LEDGER'));print('ledger: start',len(d['starts']),'ring',d['recent_splashes'])" 2>/dev/null
/usr/bin/osascript -e 'tell application "RichOS" to quit' >/dev/null 2>&1
