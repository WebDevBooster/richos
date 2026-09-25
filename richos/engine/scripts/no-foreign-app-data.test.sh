#!/usr/bin/env bash
#
# no-foreign-app-data.test.sh: THE ENGINE NEVER READS ANOTHER APP'S DATA.
#
# On 2026-09-24 and 2026-09-25 macOS kept asking the CEO: "python3.14" would like to
# access data from other apps. The disk watchdog's `du` was walking the folder where
# macOS keeps other apps' sandboxed data, and allowing it did not stick. The engine
# ships to every RichOS user, and anything the app starts is attributed to RichOS, so a
# user would see "RichOS would like to access data from other apps". The product rule:
# nothing we ship reads, walks or measures another app's data.
#
# lib/foreign_app_data.py is the rule. This suite holds the engine to it, and proves
# the check can fail before it trusts a clean result:
#
#   F1  the checker's own self-test passes (refusals and acceptances, side by side)
#   F2  the REAL engine tree is clean (test suites excluded: they build fakes in sandboxes)
#   F3  POSITIVE PROBE: the exact line that caused the prompts, planted, is REFUSED and named
#   F4  a line that names the folder in order to refuse it, with a declared reason, is allowed
#   F4b ...and the same line with a bare marker (no reason) is refused
#   F5  a recursive walk of the home folder is refused, and a walk of ~/ab beside it is not
#   F6  a missing root is exit 2, never a clean scan over nothing
#
# Exit 0 = every case passed; exit 1 = at least one failed; 2 = could not run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/lib/foreign_app_data.py"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

[ -f "$CHECK" ] || { echo "no-foreign-app-data.test.sh: no $CHECK, refusing to report a result." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/no-foreign-app-data-test.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

echo "=== no-foreign-app-data (engine) ==="

# --- F1 ---------------------------------------------------------------------------------
out="$(python3 "$CHECK" --self-test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "F1  the checker's self-test passes ($(printf '%s' "$out" | grep -c '^  ok') cases)"
else
    bad "F1  the checker's self-test failed" "$(printf '%s' "$out" | grep FAIL | head -3)"
fi

# --- F2 ---------------------------------------------------------------------------------
out="$(python3 "$CHECK" scan --exclude-tests "$ENGINE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "F2  the real engine tree reads no other app's data"
else
    bad "F2  the engine tree has lines that would prompt for other apps' data" "$(printf '%s' "$out" | head -5)"
fi

# --- F3 ---------------------------------------------------------------------------------
mkdir -p "$WORK/f3"
# The line as it stood until 2026-09-25, trimmed to the entry that caused the prompts.
# shellcheck disable=SC2016  # the $-words are the literal text under test
printf '%s\n' 'DISK_CONSUMER_CANDIDATES="$TMPDIR /private/tmp $HOME/ab $HOME/Library/Containers /Volumes/E1TB/vm"' >"$WORK/f3/orchestration.config"  # foreign-app-data-exempt: the planted defect this case must see
out="$(python3 "$CHECK" scan "$WORK/f3" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'orchestration.config:1: \[names-app-data\]'; then
    ok "F3  POSITIVE PROBE: the line that caused the prompts is refused and named"
else
    bad "F3  the planted cause was not refused (rc=$rc)" "$(printf '%s' "$out" | head -3)"
fi

# --- F4 / F4b ---------------------------------------------------------------------------
mkdir -p "$WORK/f4" "$WORK/f4b"
printf '%s\n' 'PROTECTED = "Library/Containers"  # foreign-app-data-exempt: named in order to refuse it' >"$WORK/f4/rule.py"  # foreign-app-data-exempt: fixture text
printf '%s\n' 'PROTECTED = "Library/Containers"  # foreign-app-data-exempt:' >"$WORK/f4b/rule.py"  # foreign-app-data-exempt: fixture text
python3 "$CHECK" scan "$WORK/f4" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "F4  a declared exemption with a reason is honored"
else bad "F4  a declared exemption was refused (rc=$rc)"; fi
python3 "$CHECK" scan "$WORK/f4b" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok "F4b a bare marker with no reason exempts nothing"
else bad "F4b a bare marker exempted the line (rc=$rc)"; fi

# --- F5 ---------------------------------------------------------------------------------
mkdir -p "$WORK/f5a" "$WORK/f5b"
# shellcheck disable=SC2016  # the $-words are the literal text under test
printf '%s\n' '#!/bin/sh' 'du -sk "$HOME" | sort -n' >"$WORK/f5a/measure.sh"
# shellcheck disable=SC2016  # the $-words are the literal text under test
printf '%s\n' '#!/bin/sh' 'du -sk "$HOME/ab" | sort -n' >"$WORK/f5b/measure.sh"
python3 "$CHECK" scan "$WORK/f5a" >/dev/null 2>&1; rc_a=$?
python3 "$CHECK" scan "$WORK/f5b" >/dev/null 2>&1; rc_b=$?
if [ "$rc_a" -eq 1 ] && [ "$rc_b" -eq 0 ]; then
    ok "F5  measuring the whole home folder is refused; measuring ~/ab is not"
else
    bad "F5  home-walk rule wrong (home rc=$rc_a, ~/ab rc=$rc_b)"
fi

# --- F6 ---------------------------------------------------------------------------------
python3 "$CHECK" scan "$WORK/does-not-exist" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "F6  a missing root is exit 2, not a clean pass over nothing"
else bad "F6  a missing root returned $rc"; fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
