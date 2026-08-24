#!/usr/bin/env bash
#
# Install our patched open-wispr HUD build as the daily dictation service,
# WITHOUT touching the Homebrew keg — so rollback is instant and offline.
#
# What it does:
#   1. installs the built OpenWispr.app to ~/Applications/OpenWispr.app
#   2. widens the Microphone TCC grant to accept BOTH binaries, so neither the
#      swap nor the rollback re-prompts for the microphone
#   3. repoints the existing Homebrew LaunchAgent at the new bundle
#   4. restarts the service and shows the log
#
# The Homebrew keg (/opt/homebrew/opt/open-wispr) is left pristine, so
# `rollback-to-homebrew.sh` is a plist edit + LaunchAgent reload: no network, no rebuild.
#
# Accessibility is keyed to the binary and lives in the SIP-protected system TCC
# database, so it cannot be carried over. Exactly one manual step remains:
#   System Settings -> Privacy & Security -> Accessibility -> enable OpenWispr
#
# Usage:
#   tools/open-wispr-hud/install-hud.sh <path-to-built-OpenWispr.app>
#
set -euo pipefail

APP_SRC="${1:?usage: install-hud.sh <path-to-built-OpenWispr.app>}"
DEST="${HOME}/Applications/OpenWispr.app"
PLIST="${HOME}/Library/LaunchAgents/homebrew.mxcl.open-wispr.plist"
LOG="/opt/homebrew/var/log/open-wispr.log"
BREW_APP="/opt/homebrew/opt/open-wispr/OpenWispr.app"
TCC_DB="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
BACKUPS="${HOME}/.config/open-wispr/hud-backups"

command -v csreq >/dev/null || { echo "csreq not found"; exit 1; }
[ -d "$APP_SRC" ] || { echo "no such app bundle: $APP_SRC"; exit 1; }
[ -f "$PLIST" ] || { echo "no LaunchAgent at $PLIST"; exit 1; }

mkdir -p "$BACKUPS" "${HOME}/Applications"

echo "==> Backing up the LaunchAgent and the user TCC database"
cp "$PLIST" "${BACKUPS}/homebrew.mxcl.open-wispr.plist.pre-hud.bak"
cp "$TCC_DB" "${BACKUPS}/TCC.db.user.pre-hud.bak"

echo "==> Installing $APP_SRC -> $DEST"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
codesign --verify --strict "$DEST"

NEW_HASH=$(codesign -dvvv "$DEST" 2>&1 | awk -F= '/^CDHash=/{print $2}')
OLD_HASH=$(codesign -dvvv "$BREW_APP" 2>&1 | awk -F= '/^CDHash=/{print $2}')
echo "    homebrew cdhash : $OLD_HASH"
echo "    hud build cdhash: $NEW_HASH"

echo "==> Widening the Microphone grant to accept both binaries"
BLOB="$(mktemp)"
csreq -r="cdhash H\"${OLD_HASH}\" or cdhash H\"${NEW_HASH}\"" -b "$BLOB"
HEX=$(xxd -p "$BLOB" | tr -d '\n')
sqlite3 "$TCC_DB" \
  "UPDATE access SET csreq = X'${HEX}' WHERE service='kTCCServiceMicrophone' AND client='com.human37.open-wispr';"
csreq -r "$BLOB" -t
rm -f "$BLOB"
killall tccd 2>/dev/null || true

echo "==> Repointing the LaunchAgent at the HUD build"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${DEST}/Contents/MacOS/open-wispr" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$PLIST"

echo "==> Restarting the dictation service"
# launchctl kickstart -k restarts the job from launchd's IN-MEMORY definition and
# does NOT re-read the edited plist, so the old binary keeps running (measured
# 2026-08-24: after the plist said Homebrew, kickstart left PID 28010 on the
# ~/Applications build). bootout + bootstrap is what actually reloads the plist.
launchctl bootout "gui/$(id -u)/homebrew.mxcl.open-wispr" 2>/dev/null || true
sleep 2
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 6
tail -12 "$LOG"

echo
echo "==> Installed. Running binary:"
pgrep -fl "open-wispr start" || echo "    (not running yet)"
echo
echo "    If the log stops at 'Accessibility: not granted', the ONE manual step is:"
echo "    System Settings -> Privacy & Security -> Accessibility -> enable OpenWispr"
echo "    Rollback at any time: tools/open-wispr-hud/rollback-to-homebrew.sh"
