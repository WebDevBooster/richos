#!/usr/bin/env bash
# THE GAP, PROVED ON A MACHINE STATE WITH NO ENGINE — and without touching the CEO's.
#
#   gap-proof.sh <work-dir>
#
# `ceo-decisions.md` §19, in its own words: *"today RichOS runs on his Mac and would not run
# on anyone else's"*, because a customer needs Claude Code AND the engine directory and the
# engine *"ships in no payload and has no route onto another machine at all"*. This script
# shows the app failing exactly as a customer's would.
#
# HOW THE CUSTOMER STATE IS PRODUCED, AND WHY IT IS NOT SIMULATED
#
# It is a real process, in the real GUI condition, with all seven of `engine.rs`'s candidates
# genuinely absent:
#
#   candidate 1,2  $RICHOS_ENGINE_DIR / $RICHOS_ENGINE_ROOT   `env -i` — nothing is inherited
#   candidate 3    <bundle>/Contents/Resources/engine          the bundle is assembled empty
#   candidate 4    an `engine/` above the EXECUTABLE           the bundle is OUTSIDE the repo
#   candidate 5    an `engine/` above the WORKING DIRECTORY    cwd is `/`, as LaunchServices gives
#   candidate 6    ~/.claude/richos-engine                     HOME is a throwaway
#   candidate 7    ~/Library/Application Support/RichOS/engine HOME is a throwaway
#
# Candidate 4 is the reason the bundle is assembled in a scratch directory rather than run
# from `target/`: a binary nine levels under a repository that HAS an `engine/` would find the
# dogfood one and this would prove nothing.
#
# THE CEO'S MACHINE IS NOT TOUCHED, AND IT IS PROVED RATHER THAN PROMISED. His engine
# pointer, his loro-root and every file under `com.richos.app` are fingerprinted before and
# after and the two are diffed. Nothing here removes, moves or writes any of them — which is
# a stronger position than the provisioning proof needed to take, because that one had to
# remove his pointer and put it back. **One was left dangling by a red-run fixture on
# 2026-09-01. This script cannot repeat that, because it never touches it.**
set -uo pipefail

WORK="${1:?usage: gap-proof.sh <work-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/../../../../app" && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

rm -rf "$WORK"; mkdir -p "$WORK"
SIM="$WORK/home"; mkdir -p "$SIM"

echo "=== HIS STATE, BEFORE — read only ==="
his_state > "$WORK/his-state-before.txt"
sed -n '1,6p' "$WORK/his-state-before.txt"
echo "  (full fingerprint in his-state-before.txt)"
echo

echo "=== building the binary under test ==="
( cd "$APP_DIR/src-tauri" && "$CARGO" build -q --bin richos-tauri --offline ) || exit 1
BIN="$APP_DIR/src-tauri/target/debug/richos-tauri"
ls -l "$BIN" | awk '{print "  " $5 " bytes  " $NF}'

APP="$WORK/RichOS.app"
EXE="$(assemble_bundle "$APP" "$BIN")"
echo
echo "=== the bundle, OUTSIDE the repository, carrying no engine ==="
find "$APP" | sed "s|$WORK/||" | sort | sed 's/^/  /'
echo "  Contents/Resources holds: $(ls "$APP/Contents/Resources" | wc -l | tr -d ' ') file(s)"

echo
echo "=== a HOME that has never seen RichOS ==="
find "$SIM" -mindepth 1 | head
echo "  (empty)"

echo
echo "=== BOOT: cwd = /, environment holds nothing but HOME and PATH ==="
LOG="$WORK/boot-no-engine.log"
boot_and_capture "$EXE" "$SIM" "$LOG" "NO COMPUTE LEASE|compute lease attached" 40
echo
echo "--- what the app said ---"
grep -E "^\[richos\]" "$LOG" | head -40
echo
echo "--- the lines that ARE the gap ---"
grep -E "engine directory:|looked in|first-run setup:|NO COMPUTE LEASE|binary:|engine:|cause :" "$LOG"

kill_ours "$EXE"
echo
residue "$EXE"

echo
echo "=== HIS STATE, AFTER ==="
his_state > "$WORK/his-state-after.txt"
if diff -u "$WORK/his-state-before.txt" "$WORK/his-state-after.txt" > "$WORK/his-state.diff"; then
    echo "  BYTE-IDENTICAL. $(grep -c '^[0-9a-f]\{64\}' "$WORK/his-state-after.txt" | tr -d ' ') file(s) fingerprinted under com.richos.app, diff empty."
    sed -n '1,6p' "$WORK/his-state-after.txt" | sed 's/^/  /'
else
    echo "  HIS STATE DIFFERS — read his-state.diff"
    cat "$WORK/his-state.diff"
fi

echo
echo "=== cleaning up this run ==="
rm -rf "$SIM"
echo "  throwaway HOME removed"
