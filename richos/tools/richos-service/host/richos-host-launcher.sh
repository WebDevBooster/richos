#!/bin/sh
# RichOS native-messaging host launcher (macOS / Linux).
#
# Chrome execs the path in the host manifest directly, so it must be a real executable. A Node
# script's shebang is not always honored when Chrome sets up the stdio pipes, so we exec node
# explicitly here. `install-host.sh` rewrites NODE_BIN + HOST_JS to absolute paths at install time.
NODE_BIN="__NODE_BIN__"
HOST_JS="__HOST_JS__"
exec "$NODE_BIN" "$HOST_JS"
