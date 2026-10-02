#!/usr/bin/env bash
#
# guard-unguarded-rm.test.sh: the Bash rule that refuses, before Claude Code asks the CEO, an rm whose
# path starts with an unguarded variable or names a critical path (scripts/hooks/guard-unguarded-rm.sh,
# a module of dispatch-pretooluse.sh; the rule is scripts/lib/unguarded_rm.py).
#
# The CEO, 2026-10-02, bypass permissions on, was stopped by "Dangerous rm operation on possibly-empty
# variable path: $D/*.jsonl in `rm -f $D/*.jsonl`". Claude Code's own critical-path check, which
# bypassPermissions still asks about; a PreToolUse refusal runs first.
#
#   P1   POSITIVE CONTROL, the exact 2026-10-02 command, refused with the exact rewrite "${D:?}"/*.jsonl
#   P2   every unguarded spelling: $D/x, ${D}/x, "$D"/x, "$D/x", $1, $@, ${D:-x}, ${D-x}
#   P3   every position: after && ; | & newline, in ( ), { }, $( ), backticks, if/then, sh -c, bash -lc,
#        xargs rm, sudo rm, /bin/rm, rmdir, find -delete / -exec rm with a variable root
#   P4   a guarded variable assigned from $(pwd) / git rev-parse --show-toplevel; recursive rm of only a
#        command substitution; a substitution trailing a critical path
#   P5   literal critical paths: /, /usr, /tmp, ~, $HOME-resolved home, the working directory and its parents
#   N1   guarded "${D:?}"/x, ${D:?msg}, "${D:?}" pass; literal paths pass; relative paths pass
#   N2   a MENTION is not a removal: echo, a commit message, a heredoc body, a comment, `ls $D/*`
#   N3   a variable later in the word (/tmp/x/$F), a redirect target, a single-quoted literal
#   N4   an unreadable payload and a command without rm pass
#   D1   through the real dispatcher (dispatch-pretooluse.sh Bash) the refusal is exit 2 with its text
#
# Usage: scripts/hooks/guard-unguarded-rm.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-unguarded-rm.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -6; FAIL=$((FAIL + 1)); return 0; }

[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 2; }
T_HOME="/Users/tester"
T_CWD="/Users/tester/ab/richos/work/tree"

payload() { # <command> [cwd]
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"session_id":"test"}))' \
        "$1" "${2:-$T_CWD}"
}
check() { # <expected rc> <id> <description> <command> [cwd]
    local out rc
    out="$(payload "$4" "${5:-$T_CWD}" | HOME="$T_HOME" bash "$HOOK" 2>&1)"; rc=$?
    if [ "$rc" = "$1" ]; then ok "$2 $3"; else bad "$2 $3" "rc=$rc (expected $1) $out"; fi
    LAST_OUT="$out"
}

echo "=== guard-unguarded-rm: refused ==="
# shellcheck disable=SC2016  # the $-words are the literal command text under test
{
check 2 P1 "the 2026-10-02 command" 'D=/Volumes/E1TB/tmp/claude/zach-opus-recordclaim1/one && mkdir -p $D && rm -f $D/*.jsonl && echo done'
if printf '%s' "$LAST_OUT" | grep -qF '"${D:?}"/*.jsonl'; then
    ok "P1 the refusal carries the exact rewrite"
else
    bad "P1 the refusal does not carry the exact rewrite" "$LAST_OUT"
fi
check 2 P2 'bare $D/x' 'rm -f $D/x'
check 2 P2 'braced ${D}/x' 'rm -rf ${D}/x'
check 2 P2 'quoted "$D"/x' 'rm -rf "$D"/x'
check 2 P2 'quoted whole "$D/x"' 'rm -rf "$D/x"'
check 2 P2 'quoted glob under variable' 'rm -rf "$DIR"/*'
check 2 P2 'positional $1' 'rm -rf "$1"/build'
check 2 P2 'positional $@' 'rm -f $@'
check 2 P2 'a default is not a guard ${D:-x}' 'rm -rf ${D:-x}/y'
check 2 P2 'an unset-only check is not a guard ${D-x}' 'rm -rf ${D?}/y'
check 2 P2 'variable as the whole argument' 'rm -rf $TMPDIR'
check 2 P2 'after options and --' 'rm -r -f -- $D/old'
check 2 P2 'second path is the unguarded one' 'rm -f /tmp/a/one.txt "$D"/two.txt'
check 2 P3 'after &&' 'cd /tmp/a && rm -rf $D/x'
check 2 P3 'after ;' 'echo hi; rm -rf $D/x'
check 2 P3 'after |' 'echo hi | rm $D/x'
check 2 P3 'after &' 'sleep 1 & rm $D/x'
check 2 P3 'after ||' 'false || rm $D/x'
check 2 P3 'after a newline' 'echo hi
rm -rf $D/x'
check 2 P3 'in a subshell' '( rm -rf $D/x )'
check 2 P3 'in a brace group' '{ rm -rf $D/x; }'
check 2 P3 'in $( )' 'echo "$(rm -rf $D/x)"'
check 2 P3 'in backticks' 'echo `rm -rf $D/x`'
check 2 P3 'in if/then' 'if [ -d "$D" ]; then rm -rf $D/x; fi'
check 2 P3 'in a loop' 'for f in a b; do rm -f $D/$f; done'
check 2 P3 'sudo rm' 'sudo rm -rf $D/x'
check 2 P3 '/bin/rm' '/bin/rm -rf $D/x'
check 2 P3 'backslash rm' '\rm -rf $D/x'
check 2 P3 'env assignment before rm' 'LC_ALL=C rm -rf $D/x'
check 2 P3 'rmdir' 'rmdir $D/x'
check 2 P3 'xargs rm with a variable argument' 'ls | xargs rm -f $D/x'
check 2 P3 'xargs -n1 rm with a variable argument' 'ls | xargs -n 1 rm $D/x'
check 2 P3 'bash -c, double quoted' 'bash -c "rm -rf $D/x"'
check 2 P3 'bash -lc, single quoted, inner variable' "bash -lc 'rm -rf \$D/x'"
check 2 P3 'sh -c double quoted with an escaped inner quote' 'sh -c "rm -rf \"$1\"/*" _ x'
check 2 P3 'find with a variable root and -delete' 'find $D -name "*.tmp" -delete'
check 2 P3 'find with a quoted variable root and -exec rm' 'find "$D" -type f -exec rm -f {} \;'
check 2 P3 'find root with a trailing path' 'find $D/sub -mtime +7 -delete'
check 2 P3 'find -exec rm with a variable argument' 'find . -name x -exec rm -f $D/y \;'
check 2 P4 'guarded but assigned from $(pwd)' 'D=$(pwd); rm -rf "${D:?}"/x'
check 2 P4 'guarded but assigned from git rev-parse' 'R="$(git rev-parse --show-toplevel)" && rm -rf "${R:?}/build"'
check 2 P4 'recursive rm of only a substitution' 'rm -rf "$(pwd)"'
check 2 P4 'recursive rm of a bare substitution' 'rm -rf $(cat list.txt)'
check 2 P4 'a substitution trailing home' 'rm -rf ~/$(cmd)'
check 2 P5 'the root' 'rm -rf /'
check 2 P5 '/*' 'rm -rf /*'
check 2 P5 'a top-level directory' 'rm -rf /usr'
check 2 P5 '/tmp itself' 'rm -rf /tmp'
check 2 P5 'the home folder (~)' 'rm -rf ~'
check 2 P5 'the home folder, absolute' 'rm -rf /Users/tester'
check 2 P5 '~/*' 'rm -rf ~/*'
check 2 P5 'the working directory, absolute' 'rm -rf /Users/tester/ab/richos/work/tree'
check 2 P5 'the working directory, as .' 'rm -rf .'
check 2 P5 'the parent of the working directory' 'rm -rf ..'
check 2 P5 'a higher parent, absolute' 'rmdir /Users/tester/ab/richos'
}

echo "=== guard-unguarded-rm: allowed ==="
# shellcheck disable=SC2016  # the $-words are the literal command text under test
{
check 0 N1 'guarded and glob' 'rm -f "${D:?}"/*.jsonl'
check 0 N1 'guarded with a message' 'rm -rf "${D:?D is unset}"/x'
check 0 N1 'guarded, whole word in quotes' 'rm -rf "${D:?}/x"'
check 0 N1 'guarded alone' 'rm -rf "${D:?}"'
check 0 N1 'the exact command, rewritten' 'D=/Volumes/E1TB/tmp/claude/zach-opus-recordclaim1/one && mkdir -p "${D:?}" && rm -f "${D:?}"/*.jsonl'
check 0 N1 'a literal path' 'rm -rf /Volumes/E1TB/tmp/claude/zach/one'
check 0 N1 'a relative path' 'rm -rf build dist/out'
check 0 N1 'a literal glob under a literal path' 'rm -f /tmp/zach/*.jsonl'
check 0 N1 'a child of home' 'rm -rf ~/.cache/x'
check 0 N1 'a child of the working directory' 'rm -rf /Users/tester/ab/richos/work/tree/target'
check 0 N1 'a sibling of the working directory' 'rm -rf /Users/tester/ab/richos/work/other'
check 0 N1 'xargs rm taking stdin' 'ls *.tmp | xargs rm -f'
check 0 N1 'find with a literal root' 'find /tmp/zach -name "*.tmp" -delete'
check 0 N1 'find with a guarded root' 'find "${D:?}" -type f -exec rm -f {} \;'
check 0 N1 'find with a variable root and no deletion' 'find $D -name x'
check 0 N1 'single-quoted sh -c that binds $1 to a value' "find . -name '*.tmp' -exec sh -c 'rm -rf \"\$1\"/x' _ {} \\;"
check 0 N2 'echo mentioning rm' 'echo "rm -rf $D/x"'
check 0 N2 'a commit message' "git commit -m 'never rm -rf \$D/x'"
check 0 N2 'a heredoc body' "cat > notes.sh <<'EOF'
rm -rf \$D/x
EOF"
check 0 N2 'a comment' 'echo hi # rm -rf $D/x'
check 0 N2 'ls of a variable path' 'ls $D/*'
check 0 N2 'grep for rm' 'grep -rn "rm -f $D" scripts'
check 0 N3 'a variable later in the word' 'rm -f /tmp/zach/$F'
check 0 N3 'a redirect target' 'rm -f x 2>$D/err.log'
check 0 N3 'a redirect target after >' 'rm -f x > $D/out.log'
check 0 N3 'a single-quoted literal' "rm -f '\$D/x'"
check 0 N3 'a git command containing rm' 'git rm --cached $F'
check 0 N3 'a variable name containing rm' 'echo $FORM $D'
check 0 N4 'a command with neither rm nor find' 'git status --short'
}

echo "=== unreadable payload ==="
out="$(printf 'not json' | HOME="$T_HOME" bash "$HOOK" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "N4 an unreadable payload is not refused"; else bad "N4 an unreadable payload was refused" "rc=$rc $out"; fi

echo "=== through the dispatcher ==="
out="$(payload 'rm -f $D/*.jsonl' /tmp/x | bash "$SCRIPT_DIR/dispatch-pretooluse.sh" Bash 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "guard-unguarded-rm"; then
    ok "D1 dispatch-pretooluse.sh Bash runs this module and returns its refusal"
else
    bad "D1 dispatch-pretooluse.sh Bash runs this module and returns its refusal" "rc=$rc $out"
fi

printf 'guard-unguarded-rm: %d passed, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
