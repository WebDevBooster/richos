#!/usr/bin/env bash
# EVERY FAILURE PATH, AGAINST THE REAL SYSTEM — real DNS, a real 404, real tar, real codesign.
#
#   failure-paths.sh <throwaway-home>
#
# The unit suite exercises all twelve failures through injected seams, which is where they
# belong. This runs the ones that only mean something against the real thing: two defects
# found on 2026-09-01 were invisible to a fake — `codesign -R` reading its argument as a
# FILENAME (a false rejection of a genuine Anthropic binary), and `stapler` exiting 0 on a
# symlink having validated nothing.
#
# THE CEO'S MACHINE IS NOT TOUCHED. Everything happens under the throwaway HOME this script
# creates and removes; the environment is built with `env -i`, so nothing of his is inherited.
set -uo pipefail

SIM="${1:?usage: failure-paths.sh <throwaway-home>}"
APP_DIR="$(cd "$(dirname "$0")/../../../../app" && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
BIN="$APP_DIR/target/debug/examples/setup_failures"

( cd "$APP_DIR" && "$CARGO" build -q -p richos-core --example setup_failures --offline ) || exit 1

rm -rf "$SIM"
mkdir -p "$SIM"
echo "=== a throwaway HOME, and nothing else in the environment: $SIM ==="
echo

/usr/bin/env -i HOME="$SIM" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$BIN"
rc=$?
echo
echo "(exit $rc)"

echo
echo "=== what is left under the throwaway HOME ==="
find "$SIM" -maxdepth 3 | sort

rm -rf "$SIM"
echo
echo "=== throwaway HOME removed ==="
ls -d "$SIM" 2>&1 || echo "(gone)"
exit $rc
