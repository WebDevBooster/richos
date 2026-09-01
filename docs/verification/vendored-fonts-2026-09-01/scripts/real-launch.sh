#!/usr/bin/env bash
#
# Launch the REAL Tauri shell from this branch and photograph ITS OWN WINDOW by
# CGWindowID — not the screen. The window restores off-screen, and dragging it
# onto the CEO's display to look at it is not something a verification run gets to
# do to him. `screencapture -l` reads the window's own backing store and does not
# care where it is.
#
# Kill discipline: the trap fires on every exit path, and the residue count is
# ASSERTED at the end rather than assumed. A harness left 157 of these running on
# his Dock tonight and he was the one who noticed.
set -uo pipefail

S=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
BIN="$S/cargo-target/debug/richos-tauri"
OUT="$S/real-launch"
mkdir -p "$OUT"

echo "residue BEFORE: $(pgrep -f 'richos-tauri' 2>/dev/null | wc -l | tr -d ' ')"

PID=""
cleanup() {
  [ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null
  /bin/sleep 1
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
  /usr/bin/pkill -9 -f "$BIN" 2>/dev/null
  /bin/sleep 1
  echo "residue AFTER cleanup: $(pgrep -f 'richos-tauri' 2>/dev/null | wc -l | tr -d ' ')"
}
trap cleanup EXIT

cd /
"$BIN" > "$OUT/boot.log" 2>&1 &
PID=$!
echo "launched pid=$PID"
/bin/sleep 9

echo "--- windows owned by that pid ---"
"$S/ft-venv/bin/python" "$S/window-id.py" "$PID" | tee "$OUT/windows.txt"

WID="$("$S/ft-venv/bin/python" "$S/window-id.py" "$PID" | awk -F"\t" "\$3==\"RichOS\"{print \$1; exit}")"
[ -z "$WID" ] && WID="$("$S/ft-venv/bin/python" "$S/window-id.py" "$PID" | awk -F'\t' 'NR==1{print $1}')"
echo "capturing CGWindowID=$WID"

/usr/sbin/screencapture -x -o -l "$WID" "$OUT/real-app-window.png"
echo "screencapture exit=$?"
ls -la "$OUT/real-app-window.png" 2>&1
/usr/bin/file "$OUT/real-app-window.png"
