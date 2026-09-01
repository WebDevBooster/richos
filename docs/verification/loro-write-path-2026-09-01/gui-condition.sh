#!/bin/sh
# Reproduce the GUI condition exactly: launchd's environment and nothing else, cwd=/.
# Measured from `ps eww` on a Finder double-click of RichOS.app on this machine
# (docs/verification/installed-app-2026-09-01/raw/first-send-launchd-environment.txt):
# a GUI process carries HOME, USER and PATH=/usr/bin:/bin:/usr/sbin:/sbin, nothing more.
#
# usage: gui-condition.sh <binary>
cd / || exit 1
exec /usr/bin/env -i HOME=/Users/alex USER=alex PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@"
