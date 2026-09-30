#!/usr/bin/env bash
#
# test-fixture-cleanup.test.sh — the test suites clean up what they start.
#
# Three suites allocate a directory or start a process from inside a command
# substitution (or forget a helper process), so their own cleanup record stayed
# empty and the fixture outlived the run:
#
#   C1  entrypoint-currency-lint.test.sh  leaves no ep-lint.* sandbox behind
#   C2  lib/appinstances.test.sh          kills the fake apps it launched even
#                                         when it is ended early
#   C3  pause-acceptance.test.sh          kills the one-hour lead sleeper it starts
#
# Each case runs the real suite with a private TMPDIR, then looks for survivors.
# Only directories under that TMPDIR and pids this script captured are touched.
#
# Exit 0 all green, 1 any red.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fixture-cleanup.XXXXXX")" && pwd -P)"
SUITE_PID=""
trap 'if [ -n "$SUITE_PID" ]; then kill -TERM "$SUITE_PID" 2>/dev/null; fi; rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

echo "=== test fixture cleanup ==="

# --- C1 ---------------------------------------------------------------------
# A `mktemp` shim records every path the suite allocates (it prints the real
# mktemp's answer unchanged), so the check names exactly what this run made,
# wherever mktemp chose to put it. (macOS `mktemp -t` ignores TMPDIR, so looking
# only under a private TMPDIR would miss the leak.)
T1="$WORK/c1"; mkdir -p "$T1/bin"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$T1/bin/mktemp" <<SHIM
#!/bin/sh
out=\$("$REAL_MKTEMP" "\$@") || exit \$?
echo "\$out" >> "$T1/made.list"
printf '%s\\n' "\$out"
SHIM
chmod +x "$T1/bin/mktemp"
PATH="$T1/bin:$PATH" TMPDIR="$T1" bash "$HERE/entrypoint-currency-lint.test.sh" >"$WORK/c1.log" 2>&1
left=""
if [ -s "$T1/made.list" ]; then
    while IFS= read -r d; do
        case "$d" in */ep-lint*) [ -e "$d" ] && left="$left $d" ;; esac
    done < "$T1/made.list"
fi
if [ ! -s "$T1/made.list" ]; then
    bad "C1 the entrypoint suite allocated nothing through mktemp" "$(tail -3 "$WORK/c1.log" | tr '\n' ' ')"
elif [ -z "$left" ]; then
    ok "C1 entrypoint-currency-lint removes every sandbox and ledger it allocated"
else
    bad "C1 entrypoint-currency-lint left:$left"
    for d in $left; do rm -rf "$d"; done
fi

# --- C2 ---------------------------------------------------------------------
# fakes_under <dir> — pids of richos-tauri processes whose executable is under <dir>.
fakes_under() {
    ps -axo pid=,command= | awk -v d="$1/" 'index($0, d) && $2 ~ /\/richos-tauri$/ { print $1 }'
}
T2="$WORK/c2"; mkdir -p "$T2"
TMPDIR="$T2" APP_TTL_SECONDS=40 bash "$HERE/lib/appinstances.test.sh" >"$WORK/c2.log" 2>&1 &
SUITE_PID=$!
i=0; seen=""
while [ $i -lt 600 ]; do
    seen="$(fakes_under "$T2")"
    [ -n "$seen" ] && break
    kill -0 "$SUITE_PID" 2>/dev/null || break
    sleep 0.1; i=$((i + 1))
done
if [ -z "$seen" ]; then
    bad "C2 appinstances suite never launched a fake app to end early" "$(tail -3 "$WORK/c2.log" | tr '\n' ' ')"
else
    kill -TERM "$SUITE_PID" 2>/dev/null
    wait "$SUITE_PID" 2>/dev/null
    SUITE_PID=""
    sleep 1
    alive=""
    for p in $seen; do
        if kill -0 "$p" 2>/dev/null; then alive="$alive $p"; fi
    done
    if [ -z "$alive" ]; then
        ok "C2 appinstances kills the fake apps it launched when ended early"
    else
        bad "C2 fake apps still running after the suite ended:$alive (they end by their 40 s deadline)"
    fi
fi
SUITE_PID=""

# --- C3 ---------------------------------------------------------------------
# A `sleep` shim records the pid of every `sleep 3600` the suite starts (exec
# keeps the pid), so the survivor check names pids this run created.
T3="$WORK/c3"; mkdir -p "$T3/bin"
REAL_SLEEP="$(command -v sleep)"
cat > "$T3/bin/sleep" <<SHIM
#!/bin/sh
[ "\$1" = "3600" ] && echo \$\$ >> "$T3/lead.pids"
exec "$REAL_SLEEP" "\$@"
SHIM
chmod +x "$T3/bin/sleep"
PATH="$T3/bin:$PATH" TMPDIR="$T3" bash "$HERE/pause-acceptance.test.sh" >"$WORK/c3.log" 2>&1
if [ ! -s "$T3/lead.pids" ]; then
    bad "C3 the pause suite started no lead sleeper to check" "$(tail -3 "$WORK/c3.log" | tr '\n' ' ')"
else
    alive=""
    for p in $(cat "$T3/lead.pids"); do
        if kill -0 "$p" 2>/dev/null; then alive="$alive $p"; kill -9 "$p" 2>/dev/null; fi
    done
    if [ -z "$alive" ]; then
        ok "C3 pause-acceptance kills the lead sleeper it starts"
    else
        bad "C3 lead sleeper survived the suite:$alive"
    fi
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
