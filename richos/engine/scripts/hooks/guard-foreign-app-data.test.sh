#!/usr/bin/env bash
#
# guard-foreign-app-data.test.sh: the Bash rule against reading another app's data
# (scripts/hooks/guard-foreign-app-data.sh, a module of dispatch-pretooluse.sh; the rule
# itself is bash_verdict in scripts/lib/foreign_app_data.py).
#
# The CEO, 2026-09-25: "a regular user of RichOS is not expected to keep clicking those
# things." A command an agent runs inside a RichOS session is attributed to RichOS, so
# one that opens another app's container makes macOS ask the user.
#
#   P1   POSITIVE CONTROL, the shape that prompted on 2026-09-25: `du -sk` of the
#        container folder (the watchdog's call) is refused, naming the path and telling
#        the agent to use a specific directory
#   P2   another app's container, read directly: Containers and Group Containers,
#        spelled ~, $HOME, ${HOME} and /Users/<name>
#   P3   walks of the whole home folder: find, du, ls -R, grep -r, rg, `du ~/*`,
#        `cd ~ && find .`, a payload cwd of home with `find .`, and `find /`
#   P4   depth: find -maxdepth 4 from ~ opens a container and is refused
#   N1   normal repository work is allowed
#   N2   ~/.claude is allowed
#   N3   ~/Library/Developer is allowed
#   N4   paths inside the app's own container (com.richos.*) are allowed
#   N5   a walk too shallow to open a container is allowed (find ~ -maxdepth 3, find / -maxdepth 2)
#   N6   a MENTION is not a read: echo, a commit message, prose in a quoted argument, a
#        heredoc written to a file
#   N7   `# foreign-app-data-exempt: <reason>` passes and is logged; a bare marker refuses
#   N8   an unreadable payload is not refused
#   D1   through the real dispatcher (dispatch-pretooluse.sh Bash), the refusal arrives as
#        exit 2 with its text
#   M    the mutation harness (foreign-app-data.mutation.sh)
#
# FALSE POSITIVES, MEASURED 2026-09-25. The rule was run over every Bash call in this
# Mac's Claude Code transcripts (~/.claude/projects/**/*.jsonl, 3,006 files): 171,377
# calls, 166,915 distinct (command, cwd) pairs. It refused 113, each classified by hand:
#   94  walks deep enough to open a container: find of /Users/alex, ~ or / at -maxdepth 4
#       or more (or unbounded), find ~/Library at -maxdepth 3 or more, du of home's top level
#   10  reads inside another app's container (the Docker Desktop migration: du, ls of a
#       folder, grep and json.load of group.com.docker/settings-store.json)
#    8  metadata only: `[ -f ]`, `[ -e ]`, `ls -la <file>` or `ls -d` on a path inside
#       another app's container. Refused because rule (a) names the path; whether macOS
#       prompts for a stat alone is not proven either way.
#    1  false positive: a container path inside a Python string literal (a test table)
#       fed to python3 by heredoc.
# So 1 certain false positive in 166,915 commands, and at most 9 if every metadata-only
# touch is counted against the rule. Spawn prompts are never Bash commands, so this rule
# never sees one and has no false positives there by construction.
#
# Usage: scripts/hooks/guard-foreign-app-data.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-foreign-app-data.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -6; FAIL=$((FAIL + 1)); return 0; }

[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 2; }
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/guard-foreign-app-data-test.XXXXXX")" || exit 2
trap 'rm -rf "$SANDBOX"' EXIT
T_HOME="/Users/tester"
export CLAUDE_CONFIG_DIR="$SANDBOX/cfg"
ACKS="$CLAUDE_CONFIG_DIR/state/foreign-app-data-acks.log"

payload() { # <command> [cwd]
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"session_id":"test"}))' \
        "$1" "${2:-/Users/tester/ab/richos}"
}
check() { # <expected rc> <id> <description> <command> [cwd]
    local out rc
    out="$(payload "$4" "${5:-/Users/tester/ab/richos}" | HOME="$T_HOME" bash "$HOOK" 2>&1)"; rc=$?
    if [ "$rc" = "$1" ]; then ok "$2 $3"; else bad "$2 $3" "rc=$rc (expected $1) $out"; fi
    LAST_OUT="$out"
}

echo "=== guard-foreign-app-data: refused ==="
# shellcheck disable=SC2016  # the $-words are the literal command text under test
{
check 2 P1 "du -sk of the container folder (the 2026-09-25 cause)" 'du -sk /Users/tester/Library/Containers'  # foreign-app-data-exempt: test input
if printf '%s' "$LAST_OUT" | grep -q 'Library/Containers' && printf '%s' "$LAST_OUT" | grep -q 'specific directory'; then
    ok "P1 the refusal names the path and says to use a specific directory"
else
    bad "P1 the refusal does not name the path or the remedy" "$LAST_OUT"
fi
check 2 P2 "ls inside another app's container (~)" 'ls ~/Library/Containers/com.apple.mail/Data'  # foreign-app-data-exempt: test input
check 2 P2 "sqlite3 on a Group Containers file (\$HOME, quoted)" 'sqlite3 "$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite" .tables'  # foreign-app-data-exempt: test input
check 2 P2 "cat with \${HOME}" 'cat ${HOME}/Library/Containers/com.apple.Safari/Data/x.plist'  # foreign-app-data-exempt: test input
check 2 P2 "python3 -c opening a container path" "python3 -c \"import os; os.listdir('/Users/tester/Library/Containers/com.apple.Notes')\""  # foreign-app-data-exempt: test input
check 2 P3 "find ~ -name" 'find ~ -name "*.log"'
check 2 P3 "du -sh ~/* (the top level of home)" 'du -sh ~/* 2>/dev/null | sort -h'
check 2 P3 "ls -R ~" 'ls -R ~'
check 2 P3 "grep -rn PATTERN ~" 'grep -rn secret ~'
check 2 P3 "rg PATTERN ~" 'rg secret ~'
check 2 P3 "cd ~ && find ." 'cd ~ && find . -name x'
check 2 P3 "find . with the payload cwd at home" 'find . -name x' "$T_HOME"
check 2 P3 "find / -name" 'find / -name libfoo.dylib 2>/dev/null'
check 2 P3 "find /Users/<name>" 'find /Users/tester -name app.log'
check 2 P4 "find ~ -maxdepth 4 opens a container" 'find ~ -maxdepth 4 -name x'
}

echo "=== guard-foreign-app-data: allowed ==="
# shellcheck disable=SC2016  # the $-words are the literal command text under test
{
check 0 N1 "git status in a repository" 'git -C /Users/tester/ab/richos status --short'
check 0 N1 "grep -rn in the repository" 'grep -rn TODO .'
check 0 N1 "rg in a subfolder" 'rg -n fn richos/app/src-tauri/src'
check 0 N1 "find . in the repository" "find . -name '*.rs' -newer Cargo.toml"
check 0 N1 "du of a build folder" 'du -sh target'
check 0 N2 "du -sh ~/.claude" 'du -sh ~/.claude'
check 0 N2 "grep -rn in ~/.claude/state" 'grep -rn quota ~/.claude/state'
check 0 N3 "du of ~/Library/Developer/CoreSimulator" 'du -sh ~/Library/Developer/CoreSimulator'
check 0 N3 "find in ~/Library/Developer" 'find ~/Library/Developer -maxdepth 2 -name Devices'
check 0 N4 "the app's own container" 'ls ~/Library/Containers/com.richos.app/Data'  # foreign-app-data-exempt: test input
check 0 N4 "the app's own group container" 'ls "$HOME/Library/Group Containers/group.com.richos.shared"'  # foreign-app-data-exempt: test input
check 0 N5 "find ~ -maxdepth 3" 'find ~ -maxdepth 3 -name RichOS.app'
check 0 N5 "find / -maxdepth 2" 'find / -maxdepth 2 -name dossiers 2>/dev/null'
check 0 N5 "ls of home and of the container folder itself (names only)" 'ls -la ~ ~/Library/Containers/'  # foreign-app-data-exempt: test input
check 0 N6 "echo" 'echo "never run find ~ here"'
check 0 N6m "echo of a container path as its own word" 'echo ~/Library/Containers/com.apple.mail/Data'  # foreign-app-data-exempt: test input
check 0 N6 "a commit message naming a container" "git commit -m 'drop \$HOME/Library/Containers from the list'"  # foreign-app-data-exempt: test input
check 0 N6 "prose in a quoted argument" "escalate.sh raise --tried 'ls ~/Library/Containers/io.tailscale* found nothing'"  # foreign-app-data-exempt: test input
check 0 N6 "a heredoc written to a file" "cat > notes.md <<'EOF'
see ~/Library/Containers/com.apple.mail
EOF"  # foreign-app-data-exempt: test input
}

echo "=== the declared exemption ==="
# shellcheck disable=SC2016  # the $-words are the literal command text under test
{
check 0 N7 "an exemption with a reason passes" 'find ~ -name x  # foreign-app-data-exempt: one-off audit the operator asked for'
if [ -f "$ACKS" ] && grep -q 'one-off audit' "$ACKS"; then
    ok "N7 ...and it is logged"
else
    bad "N7 the exemption was not logged at $ACKS"
fi
check 2 N7 "a bare marker exempts nothing" 'find ~ -name x  # foreign-app-data-exempt:'
}

echo "=== unreadable payload ==="
out="$(printf 'not json' | HOME="$T_HOME" bash "$HOOK" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "N8 an unreadable payload is not refused"; else bad "N8 an unreadable payload was refused" "rc=$rc $out"; fi

echo "=== through the dispatcher ==="
out="$(payload 'find ~ -name x' /tmp | bash "$SCRIPT_DIR/dispatch-pretooluse.sh" Bash 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "guard-foreign-app-data"; then
    ok "D1 dispatch-pretooluse.sh Bash runs this module and returns its refusal"
else
    bad "D1 dispatch-pretooluse.sh Bash runs this module and returns its refusal" "rc=$rc $out"
fi

if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/foreign-app-data.mutation.sh" ]; then
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/foreign-app-data.mutation.sh"; then
        ok "M. every rule above has been watched fail"
    else
        bad "M. the mutation harness found a property this suite does not actually prove"
    fi
fi

printf 'guard-foreign-app-data: %d passed, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
