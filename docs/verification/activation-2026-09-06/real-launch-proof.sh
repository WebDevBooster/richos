#!/usr/bin/env bash
#
# real-launch-proof.sh [--real-home]
#
# THE PROPERTY TO PROTECT ABOVE ALL: a launch performed the way the CEO performs one still
# activates, still takes the keyboard and still appears in the Dock.
#
# So this does not simulate a launch — it PERFORMS one. `open` hands the bundle to
# LaunchServices, which is the same path a Finder double-click takes, and the app arrives as
# a child of launchd with no shell holding it. The binary inside the bundle is THIS BRANCH'S
# build, so what is measured is the code under test and not the published one.
#
# Without --real-home the app is given a scratch HOME, which touches none of his data.
# Condition D compares the data directory against `$HOME/Library/Application Support/<id>`,
# so it moves with HOME and the answer is identical either way — --real-home proves that
# rather than leaving it argued.
set -uo pipefail

REAL_HOME=""
[ "${1:-}" = "--real-home" ] && REAL_HOME=1

SRC_BIN=/Users/alex/ab/richos-wt/echo-opus-fc1/app/src-tauri/target/debug/richos-tauri
SRC_PLIST=/Users/alex/Applications/RichOS.app/Contents/Info.plist
ROOT=/private/tmp/richos-activation-proof
OUT=/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad/probe-real-launch
[ -n "$REAL_HOME" ] && OUT="${OUT}-realhome"
mkdir -p "$OUT"
rm -rf "$ROOT"
mkdir -p "$ROOT/RichOS.app/Contents/MacOS" "$ROOT/RichOS.app/Contents/Resources"
cp "$SRC_PLIST" "$ROOT/RichOS.app/Contents/Info.plist"
cp "$SRC_BIN" "$ROOT/RichOS.app/Contents/MacOS/richos-tauri"
/usr/bin/codesign --force --sign - "$ROOT/RichOS.app" >> "$OUT/codesign.txt" 2>&1
/usr/bin/codesign -dv "$ROOT/RichOS.app" >> "$OUT/codesign.txt" 2>&1

front() {
  local asn name
  asn="$(/usr/bin/lsappinfo front 2>/dev/null)"
  name="$(/usr/bin/lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/.*"LSDisplayName"="\([^"]*\)".*/\1/p')"
  [ -z "$name" ] && name="(none)"
  printf '%s' "$name"
}

HOMEDIR=""
if [ -z "$REAL_HOME" ]; then
  HOMEDIR="$(mktemp -d -t richos-real-launch.XXXXXX)"
fi

{
  printf 'bundle           : %s/RichOS.app\n' "$ROOT"
  printf 'binary           : %s\n' "$SRC_BIN"
  printf 'HOME given       : %s\n' "${HOMEDIR:-<the real one, $HOME>}"
  printf 'frontmost BEFORE : %s\n' "$(front)"
} > "$OUT/report.txt"

: > "$OUT/boot.log"
if [ -n "$HOMEDIR" ]; then
  /usr/bin/open -n --stderr "$OUT/boot.log" --env "HOME=$HOMEDIR" "$ROOT/RichOS.app"
else
  /usr/bin/open -n --stderr "$OUT/boot.log" "$ROOT/RichOS.app"
fi
rc=$?
printf 'open exit        : %s\n' "$rc" >> "$OUT/report.txt"

: > "$OUT/frontmost-samples.txt"
i=0
while [ "$i" -lt 32 ]; do printf '%s\n' "$(front)" >> "$OUT/frontmost-samples.txt"; sleep 0.25; i=$((i+1)); done

PID="$(pgrep -f "richos-activation-proof/RichOS.app/Contents/MacOS/richos-tauri" | head -1)"
printf 'app pid          : %s\n' "${PID:-<not found>}" >> "$OUT/report.txt"
if [ -n "$PID" ]; then
  printf 'app PPID         : %s   <- condition P: launchd is 1\n' "$(ps -o ppid= -p "$PID" | tr -d ' ')" >> "$OUT/report.txt"
fi
/usr/bin/lsappinfo list 2>/dev/null | grep -A 6 '"RichOS" ASN' > "$OUT/lsappinfo.txt" 2>&1
/usr/bin/lsappinfo list 2>/dev/null | grep -A 6 '"richos-tauri" ASN' >> "$OUT/lsappinfo.txt" 2>&1

[ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null
sleep 1
[ -n "$PID" ] && kill -KILL "$PID" 2>/dev/null

{
  printf 'frontmost AFTER  : %s\n' "$(front)"
  printf 'distinct frontmost applications while it ran:\n'
  LC_ALL=C sort "$OUT/frontmost-samples.txt" | uniq -c | LC_ALL=C sort -rn | sed 's/^/    /'
  printf 'activation line  :\n'
  grep -n 'activation:' "$OUT/boot.log" | sed 's/^/    /'
  printf 'webview IPC witness (voice_readiness, invoked by the page): '
  grep -c 'voice: not offered' "$OUT/boot.log"
  printf 'LaunchServices   :\n'
  sed 's/^/    /' "$OUT/lsappinfo.txt"
} >> "$OUT/report.txt"

[ -n "$HOMEDIR" ] && rm -rf "$HOMEDIR"
cat "$OUT/report.txt"
