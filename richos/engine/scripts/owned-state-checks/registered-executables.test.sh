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
#   E4  an engine table that is valid and empty plus an entity settings table that
#       is corrupt JSON exits 2 (UNKNOWN), naming the file (hunt P5-08: it used
#       to exit 0 "all 0 configured script(s)").
#   E5  an entity with NO settings file at all, beside a readable engine table, is
#       fine: an absent optional table is not a corrupt one.
#   E6  a corrupt ENGINE table beside a good entity table also exits 2.
#   E7  a corrupt table beside a genuinely missing script still exits 1: a
#       definite failure is reported as one.
#   E8  a table that parses but is not an object is unreadable too.
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

fresh
printf '{"hooks":{}}\n' > "$ENG/hooks/hooks.json"
printf '{ this is not json' > "$ENT/.claude/settings.local.json"
run
if [ "$RC" = 2 ] && grep -q 'settings.local.json' <<<"$OUT"; then ok "E4  a corrupt entity table is UNKNOWN (exit 2) and named"; else bad "E4  (rc=$RC): $OUT"; fi

fresh
printf '{"hooks":{}}\n' > "$ENG/hooks/hooks.json"
run
if [ "$RC" = 0 ]; then ok "E5  an absent optional settings file is fine"; else bad "E5  (rc=$RC): $OUT"; fi

fresh
printf '{ broken' > "$ENG/hooks/hooks.json"
printf '{"hooks":{}}\n' > "$ENT/.claude/settings.local.json"
run
if [ "$RC" = 2 ] && grep -q 'hooks.json' <<<"$OUT"; then ok "E6  a corrupt engine table is UNKNOWN (exit 2)"; else bad "E6  (rc=$RC): $OUT"; fi

fresh
hooks_json "$ENG/hooks/hooks.json" '${CLAUDE_PLUGIN_ROOT}/scripts/gone.sh'
printf '{ broken' > "$ENT/.claude/settings.local.json"
run
if [ "$RC" = 1 ] && grep -q 'MISSING' <<<"$OUT"; then ok "E7  a definite failure still exits 1 beside a corrupt table"; else bad "E7  (rc=$RC): $OUT"; fi

fresh
printf '{"hooks":{}}\n' > "$ENG/hooks/hooks.json"
printf '[1, 2, 3]\n' > "$ENT/.claude/settings.local.json"
run
if [ "$RC" = 2 ]; then ok "E8  a table that is not an object is UNKNOWN (exit 2)"; else bad "E8  (rc=$RC): $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
