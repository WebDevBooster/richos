#!/usr/bin/env bash
#
# THE OTHER SIDE, IN THE REAL APP. Rebuild the same shell with the vendored faces
# taken out of the staged frontend, launch it, photograph its window, put the
# faces back and rebuild. If the two windows are identical, the faces were never
# drawing anything and the green run is a corpse.
#
# The fonts directory is COMMITTED, so the restore below is recoverable even if
# this script dies halfway: `git checkout -- app/ui/fonts` puts it back.
set -uo pipefail

S=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
W=/Users/alex/ab/richos-wt/zach-opus-ft1
BIN="$S/cargo-target/debug/richos-tauri"
OUT="$S/real-launch"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="$S/cargo-target"

PID=""
restore() {
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
  /usr/bin/pkill -9 -f "$BIN" 2>/dev/null
  if [ -d "$W/app/ui/.fonts-held" ]; then
    rm -rf "$W/app/ui/fonts"
    mv "$W/app/ui/.fonts-held" "$W/app/ui/fonts"
    echo "fonts directory RESTORED"
  fi
}
trap restore EXIT

echo "=== taking the faces out of the staged frontend ==="
mv "$W/app/ui/fonts" "$W/app/ui/.fonts-held"
cd "$W/app/src-tauri"
cargo build --bin richos-tauri 2>&1 | tail -3

echo "=== embedded font keys in the starved binary ==="
grep -a -c -- "/fonts/Inter-Variable.woff2" "$BIN" || echo "  Inter-Variable.woff2: ABSENT (as intended)"

cd /
"$BIN" > "$OUT/boot-starved.log" 2>&1 &
PID=$!
echo "launched starved pid=$PID"
/bin/sleep 9

WID="$("$S/ft-venv/bin/python" "$S/window-id.py" "$PID" | awk -F"\t" "\$3==\"RichOS\"{print \$1; exit}")"
echo "capturing CGWindowID=$WID"
/usr/sbin/screencapture -x -o -l "$WID" "$OUT/real-app-window-starved.png"
/usr/bin/file "$OUT/real-app-window-starved.png"

kill -TERM "$PID" 2>/dev/null; /bin/sleep 2; PID=""
