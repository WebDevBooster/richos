#!/usr/bin/env bash
#
# guard-no-shell-c.test.sh: the Bash rule that refuses, before Claude Code asks the user, an inline
# `bash -c '<script>'` (scripts/hooks/guard-no-shell-c.sh, a module of dispatch-pretooluse.sh; the
# rule is scripts/lib/shell_c.py).
#
# The CEO, 2026-10-09, saw "This shell -c script runs rm and could not be checked. Do you want to
# proceed?" and hit yes.
#
#   P1   POSITIVE CONTROL: the shape that prompted him, refused with the message and the fix
#   P2   every spelling: bash/sh/zsh/dash, a path, -c, -lc, -ec, -xc, -o pipefail -c
#   P3   every position: after && ; | newline, in ( ), $( ), backticks, sudo/env/nohup/xargs, find -exec
#   N1   a script file (bash file.sh, bash -x file.sh, sh ./x.sh, bash < file) and ordinary commands pass
#   N2   a MENTION is not a call: echo, a commit message, a heredoc body
#   N3   an unreadable payload and a non-Bash tool pass
#   D1   through the real dispatcher (dispatch-pretooluse.sh Bash) the refusal is exit 2 with its text
#
# Usage: scripts/hooks/guard-no-shell-c.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-no-shell-c.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -6; FAIL=$((FAIL + 1)); return 0; }

[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 2; }

payload() { # <command>
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"session_id":"test"}))' "$1"
}
check() { # <expected rc> <id> <description> <command>
    local out rc
    out="$(payload "$4" | bash "$HOOK" 2>&1)"; rc=$?
    if [ "$rc" = "$1" ]; then ok "$2 $3"; else bad "$2 $3" "rc=$rc (expected $1) $out"; fi
    LAST_OUT="$out"
}

echo "=== guard-no-shell-c: refused ==="
check 2 P1 "the 2026-10-09 shape" "bash -c 'rm -rf /tmp/x/old && echo done'"
if printf '%s' "$LAST_OUT" | grep -qF 'write the script to a file' && printf '%s' "$LAST_OUT" | grep -qF 'bash <file>'; then
    ok "P1 the refusal says what to do instead"
else
    bad "P1 the refusal does not say what to do instead" "$LAST_OUT"
fi
check 2 P2 "sh -c" "sh -c 'echo hi'"
check 2 P2 "zsh -c" "zsh -c 'echo hi'"
check 2 P2 "dash -c" "dash -c 'echo hi'"
check 2 P2 "a path" "/bin/bash -c 'echo hi'"
check 2 P2 "-lc" "bash -lc 'echo hi'"
check 2 P2 "-ec" "bash -ec 'echo hi'"
check 2 P2 "-xc" "sh -xc 'echo hi'"
check 2 P2 "-o pipefail -c" "bash -o pipefail -c 'echo hi'"
check 2 P2 "double quotes" 'bash -c "echo hi"'
check 2 P3 "after &&" "cd /tmp && bash -c 'echo hi'"
check 2 P3 "after ;" "cd /tmp; bash -c 'echo hi'"
check 2 P3 "after a pipe" "echo hi | bash -c 'cat'"
check 2 P3 "after a newline" $'cd /tmp\nbash -c \'echo hi\''
check 2 P3 "in a subshell" "(bash -c 'echo hi')"
check 2 P3 "in a substitution" 'x=$(bash -c "echo hi")'
check 2 P3 "after sudo" "sudo bash -c 'echo hi'"
check 2 P3 "after env" "env FOO=1 bash -c 'echo hi'"
check 2 P3 "after a variable assignment" "FOO=1 bash -c 'echo hi'"
check 2 P3 "after nohup" "nohup bash -c 'sleep 1' &"
check 2 P3 "xargs" "ls | xargs -I{} bash -c 'echo {}'"
check 2 P3 "find -exec" "find . -name '*.tmp' -exec sh -c 'rm \"\$1\"' _ {} \\;"

echo "=== guard-no-shell-c: passes ==="
check 0 N1 "bash file.sh" "bash /Volumes/E1TB/tmp/claude/zach/run.sh"
check 0 N1 "bash -x file.sh" "bash -x ./run.sh arg"
check 0 N1 "sh ./x.sh" "sh ./x.sh"
check 0 N1 "bash -e file.sh with a later -c argument" "bash ./run.sh -c config"
check 0 N1 "bash reading a file" "bash < ./run.sh"
check 0 N1 "an ordinary command" "ls -la /tmp && git -C /tmp status"
check 0 N1 "a tool with -c" "python3 -c 'print(1)'"
check 0 N1 "git -c" "git -c core.editor=true commit -m x"
check 0 N2 "echo mention" "echo 'run bash -c here'"
check 0 N2 "commit message mention" 'git commit -m "refuse bash -c wrappers"'
check 0 N2 "heredoc body" $'cat > /tmp/x.md <<\'EOF\'\nbash -c \'echo hi\'\nEOF'
check 0 N3 "unreadable payload" "x"
out="$(printf 'not json' | bash "$HOOK" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "N3 unreadable payload passes" || bad "N3 unreadable payload" "rc=$rc $out"
out="$(printf '%s' '{"tool_name":"Read","tool_input":{"command":"bash -c x"}}' | bash "$HOOK" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "N3 a non-Bash tool passes" || bad "N3 a non-Bash tool" "rc=$rc $out"

echo "=== guard-no-shell-c: through the dispatcher ==="
out="$(payload "bash -c 'rm -rf /tmp/x'" | bash "$SCRIPT_DIR/dispatch-pretooluse.sh" Bash 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'guard-no-shell-c: BLOCKED'; then
    ok "D1 dispatcher refuses bash -c with the message"
else
    bad "D1 dispatcher" "rc=$rc $out"
fi
out="$(payload "bash /tmp/x.sh" | bash "$SCRIPT_DIR/dispatch-pretooluse.sh" Bash 2>&1)"; rc=$?
if printf '%s' "$out" | grep -qF 'guard-no-shell-c'; then bad "D1 dispatcher passes a script file" "$out"; else ok "D1 dispatcher lets a script file past this rule"; fi

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
