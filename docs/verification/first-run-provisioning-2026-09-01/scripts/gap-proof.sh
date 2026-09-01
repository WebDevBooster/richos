#!/usr/bin/env bash
# THE GAP, PROVED BY REMOVING THE THING NOTHING CREATES.
#
# `docs/verification/installed-app-2026-09-01/README.md` §6 states the operator step the
# installed app depends on: `~/Library/Application Support/RichOS/loro-root`, a symlink made
# by hand. This script removes it, boots the installed bundle under launchd's environment,
# reads the boot log back, and PUTS IT BACK — then proves the restore byte for byte.
#
# It touches the CEO's live install, so the order below is the whole safety argument:
#   1. copy his app data out (ditto) and record the pointer's target BEFORE anything moves;
#   2. remove the pointer, launch, capture, quit;
#   3. restore the pointer and the app data, and verify both against the copies from step 1.
# Step 3 runs on every exit path (trap), so an interrupted run still restores.
set -uo pipefail

APP="/Users/alex/Applications/RichOS.app"
SUPPORT="$HOME/Library/Application Support"
POINTER="$SUPPORT/RichOS/loro-root"
APPDATA="$SUPPORT/com.richos.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:?usage: gap-proof.sh <work-dir>}"
mkdir -p "$WORK"

TARGET="$(readlink "$POINTER")" || { echo "no pointer at $POINTER — nothing to prove"; exit 1; }
echo "pointer target before: $TARGET" | tee "$WORK/pointer-before.txt"
/usr/bin/ditto "$APPDATA" "$WORK/appdata-before"
( cd "$APPDATA" && find . -type f -exec shasum -a 256 {} \; | sort -k2 ) > "$WORK/appdata-before.sha256"

restore() {
    ln -sfn "$TARGET" "$POINTER"
    rm -rf "$APPDATA"
    /usr/bin/ditto "$WORK/appdata-before" "$APPDATA"
}
trap restore EXIT

rm "$POINTER"
echo "--- pointer removed; ls of $SUPPORT/RichOS ---"
ls -la "$SUPPORT/RichOS"

LOG="$WORK/boot-no-pointer.log"
: > "$LOG"
cd /
bash "$HERE/launchd-env.sh" /usr/bin/open --stdout "$LOG" --stderr "$LOG" "$APP"
n=0
while [ $n -lt 60 ]; do
    grep -qE "compute lease attached|NO COMPUTE LEASE" "$LOG" 2>/dev/null && break
    n=$((n + 1)); /bin/sleep 1
done
/bin/sleep 3
echo "--- boot log with NO pointer (after ${n}s) ---"
cat "$LOG"
pid="$(/usr/bin/pgrep -n -f "$APP/Contents/MacOS/richos-tauri")"
[ -n "$pid" ] && kill "$pid" && /bin/sleep 2

restore
trap - EXIT
echo "--- restored ---"
echo "pointer target after: $(readlink "$POINTER")"
( cd "$APPDATA" && find . -type f -exec shasum -a 256 {} \; | sort -k2 ) > "$WORK/appdata-after.sha256"
if diff -u "$WORK/appdata-before.sha256" "$WORK/appdata-after.sha256"; then
    echo "app data: byte-identical ($(wc -l < "$WORK/appdata-after.sha256" | tr -d ' ') files)"
else
    echo "APP DATA DIFFERS — read the diff above"
fi
