#!/usr/bin/env bash
#
# Force a REAL `update_startup::prepare` failure and launch the result the way the CEO
# launches RichOS — through LaunchServices, so the process is launchd's child and there is
# no stderr anybody will ever read.
#
# THE FAILURE IS REAL AND NOT SIMULATED. It damages the one field
# `richos_user_update::bundle_version` reads (`CFBundleShortVersionString`, checked at
# `app/crates/richos-user-update/src/lib.rs:602-606`), which is what a partially-written or
# truncated Info.plist looks like in the wild. `prepare` then fails at
# `app/src-tauri/src/update_startup.rs:65`, BEFORE any lease is acquired — so this touches
# no update state belonging to the real installation.
#
# The bundle deliberately carries the real `CFBundleIdentifier` (`com.richos.app`) because
# `activation`'s condition B requires it; with B, D (the installed data directory) and P
# (parent pid 1, which `open` gives) all satisfied, this is an INSTALLED LAUNCH and the
# alert is armed. That is the whole point: nothing here asks for the alert, the same rule
# that decides the Dock icon decides it.
#
# Usage:  force-a-startup-failure.sh <path-to-built-richos-tauri> [workdir]
#
# It prints the pid and stops. The process is BLOCKED on the alert (600 s timeout), so:
#   * screencapture -x shot.png        to see what the person sees
#   * cat ~/Library/Logs/RichOS/startup.log
#   * kill <pid>                       when done
set -uo pipefail

BIN="${1:-}"
WORK="${2:-$(mktemp -d -t richos-startup-failure)}"
[ -x "$BIN" ] || { echo "usage: $0 <path-to-built-richos-tauri> [workdir]" >&2; exit 2; }
[ "$(uname -s)" = "Darwin" ] || { echo "$0: LaunchServices is the condition under test." >&2; exit 2; }

APP="$WORK/RichOS-startup-failure-proof.app"
mkdir -p "$APP/Contents/MacOS" || exit 1
# rm first: overwriting an executable macOS has already validated in place gets the next
# launch killed with SIGKILL and no output at all (seen once on 2026-09-10, exit 137).
rm -f "$APP/Contents/MacOS/richos-tauri"
cp "$BIN" "$APP/Contents/MacOS/richos-tauri" || exit 1

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>richos-tauri</string>
	<key>CFBundleIdentifier</key>
	<string>com.richos.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>RichOS</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>corrupt-not-a-semver</string>
	<key>CFBundleVersion</key>
	<string>1.0.3</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" || exit 1

echo "bundle : $APP"
echo "damaged: CFBundleShortVersionString = corrupt-not-a-semver"
echo ""
echo "--- the person's path: LaunchServices, parent pid 1, no stderr anywhere ---"
/usr/bin/open "$APP" || exit 1
sleep 4
ps -axo pid,ppid,comm | grep "$APP/Contents/MacOS/richos-tauri" | grep -v grep
echo ""
echo "--- the same failure with a parent holding it: no modal, and it must not hang ---"
start=$(date +%s)
"$APP/Contents/MacOS/richos-tauri"; rc=$?
echo "exit=$rc elapsed=$(( $(date +%s) - start ))s"
echo ""
echo "--- what an engineer can read afterwards ---"
cat "$HOME/Library/Logs/RichOS/startup.log"
