#!/bin/bash
# home-probe.sh — a stand-in for richos-tauri that records which home it was started on.
#
# Tests copy this file to <bundle>/Contents/MacOS/richos-tauri and start it exactly the way
# a harness starts the app. It records, under $HOME/.home-probe/:
#
#   env      its environment (bash adds PWD, SHLVL and _ on its own; readers drop those)
#   nshome   what Foundation answers for NSHomeDirectory(), through JXA
#
# NSHomeDirectory() is the answer WebKit's store and the URL cache are placed by, and it is
# NOT read from HOME: under HOME alone it names the account's real home. That is the whole
# reason this probe asks Foundation rather than trusting the environment it was handed.
# It then prints the app's own completion marker, so gui_boot stops waiting, and exits.
# It opens no window and touches nothing outside $HOME.
set -u
out="${HOME:?home-probe: HOME is not set}/.home-probe"
mkdir -p "$out"
/usr/bin/env > "$out/env"
/usr/bin/osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSHomeDirectory().js' \
  > "$out/nshome" 2> "$out/nshome.err"
echo "[richos] boot complete"
