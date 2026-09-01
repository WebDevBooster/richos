#!/usr/bin/env bash
# The environment a Finder double-click actually gets, approximated from launchd's own set
# rather than from the caller's shell. `/usr/bin/open` FORWARDS the caller's environment on
# modern macOS — verified with `ps eww` against a running RichOS — so an `open` run from a
# developer shell is NOT a faithful double-click, and every earlier boot log taken that way
# carried a Homebrew PATH the real thing does not have.
set -uo pipefail
exec /usr/bin/env -i \
    HOME="/Users/alex" \
    USER="alex" \
    LOGNAME="alex" \
    SHELL="/bin/zsh" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)" \
    __CF_USER_TEXT_ENCODING="0x1F5:0x0:0x0" \
    XPC_FLAGS="0x0" \
    XPC_SERVICE_NAME="0" \
    "$@"
