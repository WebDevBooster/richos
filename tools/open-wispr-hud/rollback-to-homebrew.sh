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
# launchctl kickstart -k restarts the job from launchd's IN-MEMORY definition and
# does NOT re-read the edited plist, so the old binary keeps running (measured
# 2026-08-24: after the plist said Homebrew, kickstart left PID 28010 on the
# ~/Applications build). bootout + bootstrap is what actually reloads the plist.
launchctl bootout "gui/$(id -u)/homebrew.mxcl.open-wispr" 2>/dev/null || true
sleep 2
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 6
tail -8 "$LOG"

echo
echo "==> Now running:"
pgrep -fl "open-wispr start" || echo "    (not running)"

# Hard gate: the script must NOT exit 0 while the wrong binary is live. The
# original version printed the running process and exited 0 even though the
# repoint had silently not taken effect (2026-08-24, PID 28010).
RUNNING="$(pgrep -afl "open-wispr start" | awk '{print $2}' | head -1)"
if [ "$RUNNING" != "$BREW_BIN" ]; then
  echo "FAIL: expected $BREW_BIN to be running, got: ${RUNNING:-<nothing>}" >&2
  exit 1
fi
if ! tail -8 "$LOG" | grep -q "^Ready\.$"; then
  echo "FAIL: daemon did not reach 'Ready.' — check Accessibility in the log above" >&2
  exit 1
fi
echo "==> VERIFIED: Homebrew build running and Ready."
