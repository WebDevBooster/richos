#!/usr/bin/env bash
#
# Three real launches of the SHIPPED bundle, from cwd=/ with a Finder-shaped environment,
# capturing the shell's own boot log — which is where the launch record says out loud which
# start this is. `open` throws stderr away; running the bundled binary directly keeps it,
# and it is the same binary LaunchServices runs.
set -uo pipefail

S=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
APP="/Users/alex/ab/richos-wt/echo-opus-sp1/app/src-tauri/target/release/bundle/macos/RichOS.app"
BIN="$APP/Contents/MacOS/richos-tauri"
OUT="$S/boot"
PY="$S/qz-venv/bin/python"
LEDGER="$HOME/Library/Application Support/com.richos.app/launches.json"
BACKUP="$S/launches.json.backup4"

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

for n in 1 2 3 4; do
  echo
  echo "---- REAL LAUNCH $n (cwd=/, launchd-shaped environment) ----"
  ( cd / && env -i \
      HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$BIN" > "$OUT/boot-$n.log" 2>&1 & echo $! > "$OUT/pid-$n" )
  /bin/sleep 7
  PID=$(cat "$OUT/pid-$n")
  grep -E '^\[richos\] launch:' "$OUT/boot-$n.log" | sed 's/^/  /'
  "$PY" -c "import json;d=json.load(open('$LEDGER'));print('  ledger: start',len(d['starts']),' ring(newest first)',d['recent_splashes'])" 2>/dev/null
  # A clean quit, so the next launch reads as fresh rather than as a crash-restart.
  /usr/bin/osascript -e 'tell application "RichOS" to quit' >/dev/null 2>&1
  for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; /bin/sleep 0.25; done
  if kill -0 "$PID" 2>/dev/null; then echo "  did not quit on the Apple Event; TERM"; kill -TERM "$PID" 2>/dev/null; /bin/sleep 1; fi
  echo "  process gone: $(kill -0 "$PID" 2>/dev/null && echo no || echo yes)"
done

echo
echo "== every boot log line, accounted for =="
cat "$OUT"/boot-*.log | grep -E '^\[richos\]' | sort | uniq -c | sort -rn | head -30
