#!/usr/bin/env bash
#
# install-ref-forensics.test.sh — reachability means git can RUN the hook (P5-44).
#
# Git invokes a hook only when it is executable. --check used to say INSTALLED
# and REACHABLE for a mode-0644 hook, and for a core.hooksPath dispatcher that
# chains but is not executable. Every case uses its own throwaway repository.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/install-ref-forensics.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -4; FAIL=$((FAIL + 1)); }

[ -f "$INSTALLER" ] || { echo "FATAL: missing $INSTALLER" >&2; exit 2; }
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ref-forensics-test.XXXXXX")" || exit 2
trap 'rm -rf "$SANDBOX"' EXIT

mkrepo() { # <name>
    local r="$SANDBOX/$1"
    mkdir -p "$r"
    git -C "$r" init -q
    printf '%s' "$r"
}

# 1. installed and executable: INSTALLED + REACHABLE, exit 0.
R1="$(mkrepo plain)"
bash "$INSTALLER" "$R1" >/dev/null 2>&1
OUT="$(bash "$INSTALLER" --check "$R1" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q REACHABLE; then
    ok "1  an installed, executable recorder is INSTALLED and REACHABLE (exit 0)"
else bad "1  an installed recorder" "rc=$RC out=$OUT"; fi

# 2. the same hook made non-executable is NOT reachable.
chmod 644 "$R1/.git/hooks/reference-transaction"
OUT="$(bash "$INSTALLER" --check "$R1" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && ! printf '%s' "$OUT" | grep -q '^REACHABLE' && printf '%s' "$OUT" | grep -q 'not executable'; then
    ok "2  a mode-0644 hook is reported not executable, exit 1"
else bad "2  a non-executable hook must not be REACHABLE" "rc=$RC out=$OUT"; fi

# 3. core.hooksPath dispatcher that chains but is not executable.
R3="$(mkrepo hookspath)"
mkdir -p "$SANDBOX/dispatch"
printf '#!/bin/sh\nexec "$(git rev-parse --git-common-dir)/hooks/reference-transaction" "$@"\n' > "$SANDBOX/dispatch/reference-transaction"
chmod 755 "$SANDBOX/dispatch/reference-transaction"
git -C "$R3" config core.hooksPath "$SANDBOX/dispatch"
bash "$INSTALLER" "$R3" >/dev/null 2>&1
OUT="$(bash "$INSTALLER" --check "$R3" 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then
    ok "3  an executable chaining dispatcher is REACHABLE"
else bad "3  an executable chaining dispatcher" "rc=$RC out=$OUT"; fi
chmod 644 "$SANDBOX/dispatch/reference-transaction"
OUT="$(bash "$INSTALLER" --check "$R3" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q UNREACHABLE; then
    ok "4  a chaining dispatcher that is not executable is UNREACHABLE (exit 1)"
else bad "4  a non-executable dispatcher must be UNREACHABLE" "rc=$RC out=$OUT"; fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
