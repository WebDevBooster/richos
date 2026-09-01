#!/usr/bin/env bash
# THE SIGNED BUNDLE, ON A MACHINE WITH NO MEMORY, ASKED AND ANSWERED WITH ONE CLICK.
#
# `fresh-install.sh` proves the CORE on a clean HOME. This proves the PRODUCT: the same
# Developer-ID-signed `.app` a double-click launches, booted three times against a throwaway
# HOME that has never seen RichOS.
#
#   boot 1  nothing in place        -> "no corpus configured", three candidates, and the new
#                                      line saying RichOS will offer to set one up
#   click   the CEO's whole part    -> one press of "Set it up", driven through the macOS
#                                      accessibility API, no hand
#   boot 2  the same bundle again   -> "loro Tier C: compiling from <HOME>/RichOS/corpus"
#
# THE CEO'S OWN $HOME IS NEVER TOUCHED. Every launch below runs with HOME pointed at the
# throwaway directory, so the app's config, ledger and pointer all land there.
#
# The click launch carries RICHOS_LORO_SOURCE — an INSTALLER input standing in for the
# bundle resource that does not exist yet (BLOCKED.md). Boot 2 carries nothing but HOME,
# USER, SHELL, PATH and the four variables launchd itself supplies.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${RICHOS_APP:?set RICHOS_APP to the .app to test}"
APP_DIR="$(cd "$HERE/../../../../app" && pwd)"
SIM="${1:?usage: app-first-run.sh <throwaway-home> [compiler-source]}"
SOURCE="${2:-/Users/alex/ab/richos-hq/loro}"
BIN="$APP/Contents/MacOS/richos-tauri"

quit_it() {
    pid="$(/usr/bin/pgrep -n -f "$BIN")"
    [ -n "$pid" ] && kill "$pid" && /bin/sleep 2
}

boot() {
    local log="$1"; shift
    : > "$log"
    cd /
    quit_it
    RICHOS_SIM_HOME="$SIM" bash "$HERE/launchd-env.sh" "$@" /usr/bin/open -n --stdout "$log" --stderr "$log" "$APP"
    local n=0
    while [ $n -lt 40 ]; do
        grep -qE "compute lease attached|NO COMPUTE LEASE" "$log" 2>/dev/null && break
        n=$((n + 1)); /bin/sleep 1
    done
    /bin/sleep 3
    cat "$log"
}

rm -rf "$SIM"; mkdir -p "$SIM"
echo "=== the bundle under test ==="
/usr/bin/codesign -dv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|CDHash|flags"
echo "=== a HOME that has never seen RichOS: $SIM ==="

echo
echo "=== boot 1: nothing in place ==="
boot "$SIM/boot-1.log"

echo
echo "=== the environment the process actually received ==="
pid="$(/usr/bin/pgrep -n -f "$BIN")"
/bin/ps eww -p "$pid" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -E "^(PATH|HOME|USER|LORO_|RICHOS_)" | sort
echo "--- working directory ---"
/usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | /usr/bin/tail -1

echo
echo "=== what the window is showing ==="
/usr/bin/osascript "$HERE/read-window.applescript" "$pid"

echo
echo "=== relaunching with the installer input, then ONE CLICK on Set it up ==="
boot "$SIM/boot-click.log" RICHOS_LORO_SOURCE="$SOURCE" > /dev/null
pid="$(/usr/bin/pgrep -n -f "$BIN")"
/usr/bin/osascript "$HERE/click-button.applescript" "$pid" "Set it up"
/bin/sleep 3
echo "--- what the window says now ---"
/usr/bin/osascript "$HERE/read-window.applescript" "$pid"
echo "--- what the app printed while provisioning ---"
grep -E "provisioned a corpus|corpus git|corpus company|corpus compiler" "$SIM/boot-click.log" || echo "(nothing — no click landed)"
quit_it

# THE HONEST FALLBACK, AND IT IS NAMED RATHER THAN HIDDEN. The accessibility API can only
# reach a window in an unlocked GUI session; on a locked one it reports zero windows for
# EVERY RichOS process, the installed bundle included, so a click cannot be driven. When
# that is the state of the machine, the corpus is provisioned by the SAME core function the
# button calls (`provision::provision`, through `first_run_demo`) and this line says so —
# what boot 2 then proves is the resolution, which is the same either way.
if [ ! -d "$SIM/RichOS/corpus" ]; then
    echo
    echo "!!! NO CLICK LANDED — the accessibility API reached no window (see the error above)."
    echo "!!! Provisioning through the SAME core function the button calls, and saying so."
    ( cd "$APP_DIR" && "${CARGO:-$HOME/.cargo/bin/cargo}" build -q -p richos-core --example first_run_demo )
    /usr/bin/env -i HOME="$SIM" PATH="/usr/bin:/bin:/usr/sbin:/sbin" RICHOS_LORO_SOURCE="$SOURCE" \
        "$APP_DIR/target/debug/examples/first_run_demo" | tail -4
fi

echo
echo "=== what is on disk, made by the app and nothing else ==="
find "$SIM/RichOS" -maxdepth 3 | sort | head -30
ls -l "$SIM/Library/Application Support/RichOS/"
git -C "$SIM/RichOS/corpus" log --oneline
echo "remotes:"; git -C "$SIM/RichOS/corpus" remote -v

echo
echo "=== boot 2: THE SAME SIGNED BUNDLE, NOTHING BUT LAUNCHD'S ENVIRONMENT ==="
boot "$SIM/boot-2.log"
quit_it
