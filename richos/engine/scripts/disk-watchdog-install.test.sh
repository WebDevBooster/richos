#!/usr/bin/env bash
# P5-32: a plist on disk is not a scheduled job. With a launchctl that cannot
# load or print the job, --install must fail and --installed must say no.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$SCRIPT_DIR/disk-watchdog.sh"
# --install refuses from a temp dir or worktree, so the copy under test lives
# under $HOME/.cache (override: DW_INSTALL_TEST_BASE), not under TMPDIR.
BASE="${DW_INSTALL_TEST_BASE:-$HOME/.cache}"; mkdir -p "$BASE"
SB="$(cd "$(mktemp -d "$BASE/dw-install.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/home/Library/LaunchAgents" "$SB/engine/scripts/lib"
cp "$SCRIPT_DIR/disk-watchdog.sh" "$SB/engine/scripts/"
cp "$SCRIPT_DIR/lib/disk-watchdog.py" "$SB/engine/scripts/lib/"
cp "$SCRIPT_DIR/../orchestration.config" "$SB/engine/" 2>/dev/null || true
WD="$SB/engine/scripts/disk-watchdog.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
stub() { printf '#!/bin/sh\nexit %s\n' "$1" >"$SB/bin/launchctl"; chmod +x "$SB/bin/launchctl"; }
run() { env -u RICHOS_LAUNCH_AGENTS_DIR PATH="$SB/bin:$PATH" HOME="$SB/home" bash "$WD" "$@" 2>&1; }

stub 1
OUT="$(run --install)"; RC=$?
if [ "$RC" != 0 ] && grep -q 'did not load' <<<"$OUT"; then ok "I1  install fails when launchd will not load the job"; else bad "I1  install claimed success (rc=$RC): $OUT"; fi
run --installed >/dev/null; RC=$?
if [ "$RC" != 0 ]; then ok "I2  --installed is no with a plist that is not loaded"; else bad "I2  --installed said yes for an unloaded plist"; fi
stub 0
OUT="$(run --install)"; RC=$?
if [ "$RC" = 0 ] && grep -q '✓ scheduled' <<<"$OUT"; then ok "I3  CONTROL: install succeeds when launchd loads it"; else bad "I3  (rc=$RC): $OUT"; fi
run --installed >/dev/null; RC=$?
if [ "$RC" = 0 ]; then ok "I4  CONTROL: --installed yes when loaded"; else bad "I4  --installed no for a loaded job"; fi
printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
