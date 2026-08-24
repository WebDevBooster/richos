#!/usr/bin/env bash
#
# Roll dictation back to the pristine Homebrew open-wispr build.
#
# One command, offline, no rebuild: the Homebrew keg was never modified by
# install-hud.sh, so this is a LaunchAgent edit plus a service restart. The
# Microphone grant covers both binaries, and the Homebrew build's Accessibility
# grant was never revoked, so this needs no clicks at all.
#
# Usage:
#   tools/open-wispr-hud/rollback-to-homebrew.sh
#
set -euo pipefail

PLIST="${HOME}/Library/LaunchAgents/homebrew.mxcl.open-wispr.plist"
BREW_BIN="/opt/homebrew/opt/open-wispr/OpenWispr.app/Contents/MacOS/open-wispr"
LOG="/opt/homebrew/var/log/open-wispr.log"

[ -x "$BREW_BIN" ] || { echo "Homebrew build missing at $BREW_BIN — run: brew reinstall open-wispr"; exit 1; }

echo "==> Repointing the LaunchAgent at the Homebrew build"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${BREW_BIN}" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$PLIST"

echo "==> Restarting the dictation service"
launchctl kickstart -k "gui/$(id -u)/homebrew.mxcl.open-wispr"
sleep 6
tail -8 "$LOG"

echo
echo "==> Now running:"
pgrep -fl "open-wispr start" || echo "    (not running)"
