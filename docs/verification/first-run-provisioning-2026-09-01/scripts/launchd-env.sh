#!/usr/bin/env bash
# The environment a Finder double-click actually gets, approximated from launchd's own set
# rather than from the caller's shell. `/usr/bin/open` FORWARDS the caller's environment on
# modern macOS (measured with `ps eww` against a running RichOS, 2026-09-01), so an `open`
# run from a developer shell is NOT a faithful double-click. Copied from
# `docs/verification/installed-app-2026-09-01/scripts/launchd-env.sh` so every boot log in
# this directory is taken under the same conditions as the ones in that one.
#
# HOME is a PARAMETER here, and that is the only difference: the fresh-install simulation
# needs a HOME that has never seen RichOS, and the environment has to stay otherwise
# identical for the comparison to mean anything.
set -uo pipefail
exec /usr/bin/env -i \
    HOME="${RICHOS_SIM_HOME:-/Users/alex}" \
    USER="alex" \
    LOGNAME="alex" \
    SHELL="/bin/zsh" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)" \
    __CF_USER_TEXT_ENCODING="0x1F5:0x0:0x0" \
    XPC_FLAGS="0x0" \
    XPC_SERVICE_NAME="0" \
    "$@"
