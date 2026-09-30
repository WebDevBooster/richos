#!/usr/bin/env bash
#
# registered-executables.test.sh — the executable checker must neither bless a
# configuration it could not read nor fail a script that needs no executable bit.
#
#   E1  a script run through an interpreter ("bash ${CLAUDE_PLUGIN_ROOT}/s.sh")
#       that is readable but not executable is fine (hunt P5-09: it used to be
#       reported NOT RUNNABLE, a false owned-state failure).
#   E2  the same file configured as a DIRECT command is still NOT RUNNABLE (the
#       control: the executable-bit rule itself is unchanged).
#   E3  an interpreter script that is not even readable is NOT RUNNABLE.
#
# CHECKER names another copy of registered-executables.py (used to show the new
# cases fail on the version before the fix).
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${CHECKER:-$SCRIPT_DIR/registered-executables.py}"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/registered-executables-test.XXXXXX")" && pwd -P)"
trap 'chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

ENG="$SANDBOX/engine"; ENT="$SANDBOX/entity"
fresh() {
    rm -rf "$ENG" "$ENT"
    mkdir -p "$ENG/hooks" "$ENG/scripts" "$ENT/.claude" "$SANDBOX/no-agents"
}
hooks_json() { # <file> <command>
    printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":%s}]}]}}\n' \
        "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")" > "$1"
}
run() {
    OUT="$(python3 "$CHECKER" --engine "$ENG" --entity "$ENT" --launch-agents "$SANDBOX/no-agents" 2>&1)"
    RC=$?
}

fresh
printf '#!/bin/sh\n' > "$ENG/scripts/s.sh"; chmod 644 "$ENG/scripts/s.sh"
hooks_json "$ENG/hooks/hooks.json" 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/s.sh'
run
if [ "$RC" = 0 ]; then ok "E1  a readable script run through bash needs no executable bit"; else bad "E1  (rc=$RC): $OUT"; fi

fresh
printf '#!/bin/sh\n' > "$ENG/scripts/s.sh"; chmod 644 "$ENG/scripts/s.sh"
hooks_json "$ENG/hooks/hooks.json" '${CLAUDE_PLUGIN_ROOT}/scripts/s.sh'
run
if [ "$RC" = 1 ] && grep -q 'NOT RUNNABLE' <<<"$OUT"; then ok "E2  a direct command without the bit is still NOT RUNNABLE"; else bad "E2  (rc=$RC): $OUT"; fi

fresh
printf '#!/bin/sh\n' > "$ENG/scripts/s.sh"; chmod 000 "$ENG/scripts/s.sh"
hooks_json "$ENG/hooks/hooks.json" 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/s.sh'
run
if [ "$RC" = 1 ] && grep -q 'NOT RUNNABLE' <<<"$OUT"; then ok "E3  an unreadable interpreter script is NOT RUNNABLE"; else bad "E3  (rc=$RC): $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
