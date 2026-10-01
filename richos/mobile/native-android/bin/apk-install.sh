#!/usr/bin/env bash
# install_apk_if_changed ADB SERIAL PACKAGE APK
#
# Installs APK only when the bytes on the device differ from the build's. Prints "skipped" or
# "installed" on stdout. It never removes the app and never clears its data: `install -r` keeps
# the app's data, and an unchanged build is not touched at all (CEO 2026-10-01: no need to wipe
# and reinstall when nothing changed). When the installed bytes cannot be read, it installs,
# because "same" is then unproven.
install_apk_if_changed() {
  local adb="$1" serial="$2" package="$3" apk="$4" path want have
  want="$(shasum -a 256 "$apk" | awk '{print $1}')"
  path="$("$adb" -s "$serial" shell pm path "$package" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -1 || true)"
  have=""
  if [ -n "$path" ]; then
    have="$("$adb" -s "$serial" shell sha256sum "$path" 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)"
  fi
  if [ -n "$have" ] && [ "$have" = "$want" ]; then
    echo skipped
    return 0
  fi
  "$adb" -s "$serial" install -r -t "$apk" >/dev/null || return 1
  echo installed
}
